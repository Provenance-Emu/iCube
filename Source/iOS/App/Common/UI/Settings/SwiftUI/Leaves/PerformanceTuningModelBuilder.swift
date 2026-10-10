// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed.
/// `showValidation` is a parameter, not state: search builds the model with `true` so the validators are searchable.
enum PerformanceTuningModelBuilder {
  typealias Apply = (PerformanceTuningChange) -> Void

  static func make(state: PerformanceTuningState, showValidation: Bool, apply: @escaping Apply) -> MenuModel {
    var sections = [cpuOptions(state, apply)]
    if state.showEngineOpts {
      sections.append(engineOptimizations(state, apply))
      sections.append(validation(state, showValidation, apply))
    } else {
      sections.append(MenuSection(id: "engine-optimizations-hint", header: L("Engine Optimizations"), items: [
        SettingsRow.action("engine-optimizations-hint", L("Select a Cached Interpreter engine"),
                           L("Select Cached Interpreter or Cached Interpreter (IR) as the CPU engine above to configure optimizations. The plain Interpreter and JIT engines don't use these."),
                           enabled: false, run: {}),
      ]))
    }
    if state.showCIROpts {
      sections.append(MenuSection(id: "diagnostics", header: L("Diagnostics"), items: [
        flagRow("cir-profiler", L("CIR Hot-Block Profiler"), .cirProfile, state, apply,
                L("Records the hottest interpreter blocks for the running game. Turn ON, relaunch the game, play the slow scene, then tap Copy State in the perf HUD — the dump ends with a CIR HOT BLOCKS section showing where CPU time goes. Diagnostic only (no perf cost when OFF). Applies on next game launch.")),
      ]))
    }
    sections.append(MenuSection(id: "clock-override", header: L("Clock Override"), items: [
      flagRow("cpu-clock-enabled", L("Enable Emulated CPU Clock Override"), .cpuClockEnabled, state, apply,
              L("Adjusts the emulated CPU's clock rate. Higher values can raise the framerate of variable-rate games at a performance cost; lower values may trigger a game's internal frameskip. ⚠️ Changing this from 100% can and will break games — use at your own risk."),
              enabled: state.cpuClockOverride == .none),
      percentStepper("cpu-clock-percent", L("Emulated CPU Clock"), state.cpuClockPercent, on: state.cpuClockEnabled, override: state.cpuClockOverride,
                     L("The emulated CPU's clock as a percentage of normal. Only used while the override above is enabled."),
                     set: { apply(.cpuClockPercent($0)) }),
    ]))
    sections.append(MenuSection(id: "vbi-override", header: L("Override VBI Frequency"), items: [
      flagRow("vbi-enabled", L("Enable VBI Frequency Override"), .vbiEnabled, state, apply,
              L("Makes games run at a different frame rate. Lowering it makes emulation less demanding; raising it can improve smoothness. May change gameplay speed, since speed is often tied to frame rate."),
              enabled: state.vbiOverride == .none),
      percentStepper("vbi-percent", L("VBI Frequency"), state.vbiPercent, on: state.vbiEnabled, override: state.vbiOverride,
                     L("The emulated video-interface frequency as a percentage of normal. Only used while the override above is enabled."),
                     set: { apply(.vbiPercent($0)) }),
    ]))
    return MenuModel(sections: sections)
  }

  // MARK: Sections

  private static func cpuOptions(_ state: PerformanceTuningState, _ apply: @escaping Apply) -> MenuSection {
    let engines = state.jitAvailable ? CpuEngine.allCases : [.interpreter, .cachedInterpreter, .cachedInterpreterIR]
    return MenuSection(
      id: "cpu-options", header: L("CPU Options"),
      footer: state.jitAvailable
        ? L("These options control the PowerPC CPU emulation. On iCube the emulated CPU is almost always the performance bottleneck, so the CPU options below matter far more than any graphics setting.")
        : L("This build runs without JIT, so games always use the Cached Interpreter (the JIT engine choices are hidden). The emulated CPU is the performance bottleneck on iCube — these options matter far more than any graphics setting."),
      items: [
        SettingsRow.cycle("cpu-engine", L("CPU Emulation Engine"), engines.map { ($0.label, $0) }, state.effectiveEngine,
              state.jitAvailable
                ? L("Cached Interpreter and the JIT recompilers are faster; the plain Interpreter is the most accurate but far too slow for full-speed play.")
                : L("This build runs without a JIT entitlement, so only interpreter engines are available. Cached Interpreter is the recommended (and default) choice. Selecting a JIT engine on other builds would silently fall back to Cached Interpreter here."),
              set: { apply(.cpuEngine($0)) }),
        flagRow("mmu", L("Enable MMU"), .mmu, state, apply,
                L("Emulates the PowerPC memory management unit. Required by a small number of games (e.g. some Star Wars titles) but adds CPU overhead on every memory access, so it hurts the framerate on this already CPU-bound build. Leave OFF unless a specific game needs it.")),
        flagRow("adaptive-clock", L("Adaptive Clock (auto VI/CPU)"), .adaptiveClock, state, apply,
                L("Lets iCube auto-tune the emulated CPU/VI clock to trade accuracy for speed when frames run long. Experimental iCube option. Applies on next game launch.")),
        SettingsRow.cycle("vertex-loader", L("Vertex Loader"), VertexLoaderMode.allCases.map { ($0.label, $0.rawValue) }, state.vertexLoaderMode,
              L("How vertex data is decoded on the CPU. NEON SIMD is the fast default on Apple Silicon; Software is the slow reference path; Compare runs both and asserts they match (debug only — slowest). Leave on NEON SIMD. Applies on next game launch."),
              set: { apply(.vertexLoaderMode($0)) }),
        flagRow("pause-on-panic", L("Pause on Panic"), .pauseOnPanic, state, apply,
                L("Pauses emulation and shows a dialog when the core hits an internal error. Useful for debugging; leave OFF for normal play.")),
        flagRow("accurate-cpu-cache", L("Accurate CPU Cache (slower)"), .writeBackCache, state, apply,
                L("Emulates the PowerPC data cache more precisely. Fixes a few games that depend on cache timing, but noticeably slows the interpreter. Leave OFF unless a game misbehaves without it.")),
        flagRow("bypass-icache", L("Bypass Instruction Cache"), .disableICache, state, apply,
                L("Skips emulation of the PowerPC instruction cache. Can give a small CPU speedup but may cause bugs in games that rely on I-cache behavior. Usually keep OFF.")),
        flagRow("ci-prefetch", L("CachedInterpreter Prefetch (Apple Silicon)"), .cachedInterpreterPrefetch, state, apply,
                L("Adds software-prefetch hints to the Cached Interpreter hot loop on Apple Silicon. OFF by default: on A18 the hints measured slower (removing them gained about a third). A/B knob; applies on next game launch.")),
        flagRow("neon-texture-decode", L("NEON Texture Decoder"), .neonTextureDecode, state, apply,
                L("ARM64 NEON SIMD texture decoder. ON by default; turning it off falls back to the slower scalar decoder. A/B knob. Applies on next game launch.")),
        flagRow("dcbz-hack", L("DCBZ Hack"), .lowDCBZ, state, apply,
                L("Skips part of the dcbz (data-cache-block-zero) instruction. Can speed up a few games but breaks others (notably some Wii titles). Leave OFF unless you know a game needs it.")),
        flagRow("relaxed-idle", L("Relaxed Idle Loop Detection"), .relaxedIdleDetection, state, apply,
                L("Detects more idle loops so the CPU can skip busy-waiting. ON helps reclaim CPU time on the bottlenecked interpreter; very rarely affects timing. Default ON.")),
        flagRow("ff-ctr-idle", L("Fast-Forward CTR Idle Loops"), .fastForwardCtrIdle, state, apply,
                L("Fast-forwards counter-based idle loops instead of emulating every iteration. Can recover CPU headroom; may slightly affect timing-sensitive games. iCube tuning knob.")),
        flagRow("sync-on-skip-idle", L("Sync on Skip Idle"), .syncOnSkipIdle, state, apply,
                L("When the CPU fast-forwards through an idle loop, flush the GPU so it stays in sync. ON by default for correctness; turning it off skips the flush for a small CPU win but can cause graphical glitches in some games. A/B knob.")),
      ])
  }

  private static func engineOptimizations(_ state: PerformanceTuningState, _ apply: @escaping Apply) -> MenuSection {
    var items = [
      SettingsRow.destination("performance-ab", L("Performance A/B & Snapshots"),
                              L("Snapshots + an honest benchmark preset (adaptive clock off, 100% clocks) for one-variable A/B testing."),
                              view: AnyView(PerformanceABView().padBackNavigation())),
      SettingsRow.action("reset-optimizations", L("Reset Optimizations to Recommended"),
                         L("Restores every optimization below to its shipping default, so the recommended ones are back on. Applies on next game launch."),
                         run: { apply(.resetOptimizationsToRecommended) }),
      // Shared: honored by BOTH the Cached Interpreter and the IR engine.
      flagRow("pic-load-store", L("PIC Load/Store"), .cirPicLoadStore, state, apply,
              L("Direct-pointer load/store fast path — a large CPU win on memory-heavy games. Falls back safely for MMU / non-fastmem access. Applies on next game launch."), recommended: true),
      flagRow("specialized-ops", L("Specialized Ops"), .cirSpecializedOps, state, apply,
              L("Routes hot integer ops through a direct, inlinable dispatch instead of the pointer-compare chain. The dispatched handler is the same interpreter function, so it's the safest of these knobs. Applies on next game launch."), recommended: true),
      flagRow("block-linking", L("Block Linking"), .cirBlockLinking, state, apply,
              L("Chains hot blocks directly to cut per-block dispatcher overhead — the biggest dispatch win. Any mismatch deopts safely to the dispatcher. Applies on next game launch."), recommended: true),
      flagRow("dynamic-links", L("Dynamic Links"), .cirDynLinking, state, apply,
              L("Extends Block Linking to function returns and virtual calls (blr/bctr) and to the not-taken side of conditional branches: each exit remembers the last block it went to and jumps straight there when it repeats. Big win on call-heavy games (Wind Waker, Chibi-Robo). Requires Block Linking. Applies on next game launch."), recommended: true),
      flagRow("neon-paired-single-math", L("NEON Paired-Single Math"), .cirPsNeon, state, apply,
              L("Computes GameCube paired-single FP ops (ps_mul/add/madd/…) both lanes at once with ARM NEON instead of two scalar ops — the trick the JIT uses. Results are bit-identical to the scalar path; rare values (infinities, NaNs, tiny numbers) fall back to it. Measured 2026-10-08: +4 % on Need for Speed: Underground, neutral on Wind Waker and Chibi-Robo. Applies on next game launch."), recommended: true),
    ]
    if state.showCIROpts {
      items += [
        flagRow("cir-fp-load-store-specialization", L("FP Load/Store Specialization"), .cirSpecializedFpLs, state, apply,
                L("Routes FP loads/stores (lfs/lfd/stfs/stfd + update/indexed) through the same direct jump-table dispatch the integer ops use, removing one indirect call per op. Targets FP-heavy games (e.g. Chibi-Robo). Only specializes when FP exceptions and MMU are off (so it's identical to the generic handler). Experimental; verify with Specialized Ops: Validate. Measured 2026-09-26 on Wind Waker: within noise (±2 %). Applies on next game launch.")),
        flagRow("cir-paired-single-load-store-specialization", L("Paired-Single Load/Store Specialization"), .cirSpecializedPsq, state, apply,
                L("Routes quantized paired-single loads/stores (psq_l/psq_st + update/indexed) through direct dispatch — the single hottest op class in paired-single-heavy games like Chibi-Robo. Composes with the Paired-Single Float Fast-Path (that speeds the handler body; this speeds how it's called). Experimental; verify with Specialized Ops: Validate. Measured 2026-09-26 on Wind Waker: within noise (±1 %). Applies on next game launch.")),
        flagRow("cir-fp-paired-single-arithmetic-specialization", L("FP / Paired-Single Arithmetic Specialization"), .cirSpecializedFpArith, state, apply,
                L("Routes FP and paired-single ARITHMETIC ops (fadd/fmul/fmadd…, ps_add/ps_mul/ps_madd…) through the same direct jump-table dispatch the integer ops use — one fewer indirect call per op. Composes with NEON Paired-Single Math (that speeds the math; this speeds how it's called). Targets FP/3D-heavy games (e.g. Tony Hawk). Dispatch-only, so identical to the generic handler. Experimental. Measured 2026-09-26 on Wind Waker: within noise (±3 %). Applies on next game launch.")),
        flagRow("cir-micro-op-fusion", L("Micro-Op Fusion"), .cirMicroOpFusion, state, apply,
                L("Fuses runs of integer ops into one dispatched block, cutting per-op dispatch overhead. The fused handlers are code-audited and self-validating. Applies on next game launch."), recommended: true),
        flagRow("cir-dead-flag-elimination", L("Dead Flag Elimination"), .cirDeadFlagElim, state, apply,
                L("Skips computing condition-flag (CR0/CR1) results the analyzer proves are overwritten before any branch reads them. Experimental; run its Validate pass before trusting it. Measured 2026-09-26 on Wind Waker: within noise (±1 %). Applies on next game launch.")),
        flagRow("cir-dead-fprf-elimination", L("Dead FPRF Elimination"), .cirDeadFprfElim, state, apply,
                L("Skips computing FP result flags (FPRF) for FP/paired-single ops when proven dead — a win on the FP-heavy hot path. FP accuracy is sensitive; experimental, run its Validate pass first. Measured 2026-09-26 on Wind Waker: ~2 % slower ON. Applies on next game launch.")),
        flagRow("cir-paired-single-float-fast-path", L("Paired-Single Float Fast-Path"), .cirPsqFastPath, state, apply,
                L("Speeds up quantized paired-single load/stores (psq_l/psq_st) for the common plain-float, no-scale case (the hot path in titles like Chibi-Robo). The live quantization register is checked each execution, so other cases fall back unchanged. Experimental. Measured 2026-09-26 on Wind Waker: within noise (±2 %); written for Chibi-Robo-class titles, unmeasured there. Applies on next game launch.")),
        flagRow("cir-store-loop-memset-fast-path", L("Store-Loop (memset) Fast-Path"), .cirStoreLoopFF, state, apply,
                L("Detects tight byte-fill loops (the stb + addi + bdnz memset pattern) and performs the whole fill in one bulk write. The range is verified to be contiguous normal RAM first. Experimental. Measured 2026-09-26 on Wind Waker: ~4 % slower ON. Applies on next game launch.")),
        flagRow("cir-cache-management-loop-fast-forward", L("Cache-Management Loop Fast-Forward"), .cirCacheLoopFF, state, apply,
                L("Fast-forwards tight cache-management CTR loops (dcbf/dcbi/dcbst + addi + bdnz) that just invalidate a memory range line-by-line — common before DMA. Skips the per-op dispatch and does the invalidation in one pass. Only engages when accurate CPU cache is off. Experimental. Measured 2026-09-26 on Wind Waker: no change. Applies on next game launch.")),
      ]
    }
    if state.showIROpts {
      items += [
        flagRow("ir-constant-address-fusion", L("Constant-Address Fusion"), .cirIrConstFusion, state, apply,
                L("Fuses the ubiquitous lis+addi/ori/subi base-address pairs into a single precomputed constant load, halving the dispatch on that pattern. IR engine only. Experimental. Applies on next game launch.")),
        flagRow("ir-micro-op-fusion", L("Micro-Op Fusion"), .cirIrMicroOpFusion, state, apply,
                L("Coalesces runs of flag-free, exception-free integer ALU ops into a single dispatched unit, cutting per-op dispatch overhead on straight-line code. IR engine only. Experimental. Applies on next game launch.")),
        flagRow("ir-dead-cr-flag-elimination", L("Dead CR-Flag Elimination"), .cirIrDeadFlagElim, state, apply,
                L("Skips computing condition-flag (CR) results the block-analyzer proves are overwritten before any read — the same elimination the default Cached Interpreter offers, as an IR pass. IR engine only. Experimental. Applies on next game launch.")),
      ]
    }
    return MenuSection(
      id: "engine-optimizations", header: L("Engine Optimizations"),
      footer: state.showIROpts
        ? L("Optimizations for the Cached Interpreter (IR) engine. The shared options at the top also apply to the default Cached Interpreter. \"Recommended\" options are on by default and are the proven speed wins — leave them on. The rest are experimental A/B knobs; verify one with its Validate pass before trusting it.")
        : L("Optimizations for the Cached Interpreter engine. \"Recommended\" options are on by default and are the proven speed wins — leave them on. The rest are experimental A/B knobs; verify one with its Validate pass before trusting it."),
      items: items)
  }

  /// Re-runs each optimisation against the reference interpreter. Each row is disabled until its parent optimisation is
  /// ON, so the "requires X" relationship is enforced, not just documented.
  private static func validation(_ state: PerformanceTuningState, _ showValidation: Bool, _ apply: @escaping Apply) -> MenuSection {
    var items = [
      SettingsRow.toggle("show-validation", L("Show Validation Options"), showValidation,
                         L("Shows the developer validation toggles. Each one re-runs an optimization against the reference interpreter and asserts bit-identical results, which is much slower."),
                         set: { apply(.showValidation($0)) }),
    ]
    if showValidation {
      items.append(validateRow("validate-neon-paired-single-math", L("NEON Paired-Single Math: Validate"), .cirPsNeonValidate, parent: .cirPsNeon, state, apply,
                               L("Double-runs each NEON paired-single op against the scalar computation and asserts both lanes are bit-identical. Requires NEON Paired-Single Math ON.")))
      if state.showCIROpts {
        items += [
          validateRow("cir-validate-specialized-ops", L("Specialized Ops: Validate"), .cirSpecializedOpsValidate, parent: .cirSpecializedOps, state, apply,
                      L("Double-runs every specialized op against the generic interpreter and flags any divergence. Requires Specialized Ops ON.")),
          validateRow("cir-validate-block-linking", L("Block Linking: Validate"), .cirBlockLinkingValidate, parent: .cirBlockLinking, state, apply,
                      L("Re-resolves each linked block through the dispatcher and flags stale or wrong-target links. Requires Block Linking ON.")),
          validateRow("cir-validate-micro-op-fusion", L("Micro-Op Fusion: Validate"), .cirMicroOpFusionValidate, parent: .cirMicroOpFusion, state, apply,
                      L("Runs the real interpreter alongside each fused block and flags any divergence in registers, flags, or condition codes. Requires Micro-Op Fusion ON.")),
          validateRow("cir-validate-dead-flag-elimination", L("Dead Flag Elimination: Validate"), .cirDeadFlagElimValidate, parent: .cirDeadFlagElim, state, apply,
                      L("Double-runs every eliminated op (flag computed vs skipped) and flags any divergence in a live condition field. Requires Dead Flag Elimination ON.")),
          validateRow("cir-validate-dead-fprf-elimination", L("Dead FPRF Elimination: Validate"), .cirDeadFprfElimValidate, parent: .cirDeadFprfElim, state, apply,
                      L("Double-runs every eliminated FP op (FPRF computed vs skipped) and flags any divergence in a result register or non-FPRF FPSCR bit. Requires Dead FPRF Elimination ON.")),
          validateRow("cir-validate-paired-single-float-fast-path", L("Paired-Single Float Fast-Path: Validate"), .cirPsqFastPathValidate, parent: .cirPsqFastPath, state, apply,
                      L("For every psq op that takes the fast path, derives the result both ways and flags any divergence (a mis-handled type, scale, or single-vs-paired case). Requires Paired-Single Float Fast-Path ON.")),
          validateRow("cir-validate-store-loop-fast-path", L("Store-Loop Fast-Path: Validate"), .cirStoreLoopFFValidate, parent: .cirStoreLoopFF, state, apply,
                      L("Runs the real per-store loop on a snapshot and asserts the filled memory and post-loop registers match the bulk fill. Requires Store-Loop Fast-Path ON.")),
          validateRow("cir-validate-cache-loop-fast-forward", L("Cache-Loop Fast-Forward: Validate"), .cirCacheLoopFFValidate, parent: .cirCacheLoopFF, state, apply,
                      L("Runs the real per-line cache loop on a snapshot and asserts the post-loop registers and CTR match the fast-forward. Requires Cache-Management Loop Fast-Forward ON.")),
        ]
      }
      if state.showIROpts {
        items += [
          validateRow("ir-validate-pic-load-store", L("PIC Load/Store: Validate"), .cirIrPicLoadStoreValidate, parent: .cirPicLoadStore, state, apply,
                      L("For every load/store that takes the PIC fast path, runs the plain interpreter access on a snapshot and asserts the loaded register / stored memory / update-form writeback are bit-identical. Requires PIC Load/Store ON.")),
          validateRow("ir-validate-specialized-ops", L("Specialized Ops: Validate"), .cirIrSpecializedOpsValidate, parent: .cirSpecializedOps, state, apply,
                      L("Dual-runs each specialized op vs the plain interpreter op and asserts bit-identical state. Requires Specialized Ops ON.")),
          validateRow("ir-validate-constant-address-fusion", L("Constant-Address Fusion: Validate"), .cirIrConstFusionValidate, parent: .cirIrConstFusion, state, apply,
                      L("For every fused pair, runs the original two ops and asserts the destination register matches the precomputed constant. Requires Constant-Address Fusion ON.")),
          validateRow("ir-validate-micro-op-fusion", L("Micro-Op Fusion: Validate"), .cirIrMicroOpFusionValidate, parent: .cirIrMicroOpFusion, state, apply,
                      L("For every fused run, runs the ops un-fused and asserts the resulting registers match. Requires Micro-Op Fusion ON.")),
          validateRow("ir-validate-dead-cr-flag-elimination", L("Dead CR-Flag Elimination: Validate"), .cirIrDeadFlagElimValidate, parent: .cirIrDeadFlagElim, state, apply,
                      L("Double-runs every eliminated op (CR computed vs skipped) and asserts the live CR fields match. Requires Dead CR-Flag Elimination ON.")),
        ]
      }
    }
    return MenuSection(id: "validation", header: L("Correctness Validation (developer, slow)"), items: items)
  }

  // MARK: Rows

  /// A Bool setting: its value is read from the snapshot through the flag, and a change emits that same flag.
  private static func flagRow(_ id: String, _ title: String, _ flag: PerformanceTuningFlag, _ state: PerformanceTuningState,
                              _ apply: @escaping Apply, _ description: String,
                              recommended: Bool = false, enabled: Bool = true) -> MenuItem {
    SettingsRow.toggle(id, title, state[keyPath: flag.keyPath], description, enabled: enabled,
                       badge: recommended ? L("Recommended") : nil, set: { apply(.flag(flag, $0)) })
  }

  /// A validation toggle, disabled until the optimisation it checks (`parent`) is ON.
  private static func validateRow(_ id: String, _ title: String, _ flag: PerformanceTuningFlag, parent: PerformanceTuningFlag,
                                  _ state: PerformanceTuningState, _ apply: @escaping Apply, _ description: String) -> MenuItem {
    flagRow(id, title, flag, state, apply, description, enabled: state[keyPath: parent.keyPath])
  }

  /// A clock percentage. While the adaptive clock or the game drives the key, the control is disabled and badged: a
  /// value set here would not apply until the override clears.
  private static func percentStepper(_ id: String, _ title: String, _ percent: Int, on: Bool, override: DOLConfigOverride,
                                     _ description: String, set: @escaping (Int) -> Void) -> MenuItem {
    SettingsRow.stepper(id, title, Double(percent), range: PerformanceTuningLimits.clockPercentRange, step: 1,
                        format: { "\(Int($0))%" }, description,
                        enabled: on && override == .none, badge: ConfigOverrideBadge.title(for: override), set: { set(Int($0)) })
  }
}
