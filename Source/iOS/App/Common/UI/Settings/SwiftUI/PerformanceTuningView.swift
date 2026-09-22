// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import CoreHaptics
import QuartzCore
import PVWebServer
import PVHelp
#if os(iOS)
import SafariServices
import AudioToolbox
#endif
#if canImport(GameController)
import GameController
#endif
#if os(iOS)
#endif
import Foundation

// MARK: - Performance Tuning (wired)

struct PerformanceTuningView: View {
  @State private var cpuEngine: CpuEngine = .jitARM64
  /// True when the runtime acquired a JIT entitlement. On the App Store (jitless)
  /// build this is always false, so JIT engine choices are hidden and the core
  /// silently runs the Cached Interpreter (see EmulationViewController fallback).
  @State private var jitAvailable: Bool = false
  @State private var mmu: Bool = false
  // iCube perf settings — @AppStorage (same keys the ObjC++ EmulationCoordinator reads).
  @AppStorage("adaptive_clock_enable") private var adaptiveClock: Bool = false
  @AppStorage("icube_vertex_loader_mode") private var vertexLoaderMode: Int = 1 // TEMP default NEON (testing); 0=Software,1=NEON,2=Compare; applied on game (re)launch
  @State private var pauseOnPanic: Bool = false
  @State private var writeBackCache: Bool = false
  @State private var disableICache: Bool = false
  @State private var lowDCBZ: Bool = false
  // iCube perf A/B toggles. Both default ON; apply on next game launch.
  @State private var cachedInterpreterPrefetch: Bool = true
  @State private var neonTextureDecode: Bool = true
  // CIR perf A/B knobs: PIC + specialized-ops on by default; fusion + block-linking off (experimental).
  // Each experimental knob has a paired self-validation toggle (default off) for on-device A/B correctness.
  @State private var cirPicLoadStore: Bool = true
  @State private var cirSpecializedOps: Bool = true
  @State private var cirSpecializedOpsValidate: Bool = false
  @State private var cirSpecializedFpLs: Bool = false
  @State private var cirSpecializedPsq: Bool = false
  @State private var cirSpecializedFpArith: Bool = false
  @State private var cirMicroOpFusion: Bool = false
  @State private var cirMicroOpFusionValidate: Bool = false
  @State private var cirDeadFlagElim: Bool = false
  @State private var cirDeadFlagElimValidate: Bool = false
  @State private var cirDeadFprfElim: Bool = false
  @State private var cirDeadFprfElimValidate: Bool = false
  @State private var cirPsqFastPath: Bool = false
  @State private var cirPsqFastPathValidate: Bool = false
  @State private var cirStoreLoopFF: Bool = false
  @State private var cirStoreLoopFFValidate: Bool = false
  @State private var cirCacheLoopFF: Bool = false
  @State private var cirCacheLoopFFValidate: Bool = false
  @State private var cirIrConstFusion: Bool = false
  @State private var cirIrConstFusionValidate: Bool = false
  @State private var cirPsNeon: Bool = false
  @State private var cirPsNeonValidate: Bool = false
  @State private var cirIrMicroOpFusion: Bool = false
  @State private var cirIrMicroOpFusionValidate: Bool = false
  @State private var cirIrDeadFlagElim: Bool = false
  @State private var cirIrDeadFlagElimValidate: Bool = false
  @State private var cirIrPicLoadStoreValidate: Bool = false
  @State private var cirIrSpecializedOpsValidate: Bool = false
  @State private var cirBlockLinking: Bool = false
  @State private var cirBlockLinkingValidate: Bool = false
  @State private var cirDynLinking: Bool = false
  // CPU idle detection toggles
  @State private var relaxedIdleDetection: Bool = false
  @State private var fastForwardCtrIdle: Bool = false
  @State private var syncOnSkipIdle: Bool = true

  @State private var cpuClockEnabled: Bool = false
  @State private var cpuClockPercent: Int = 100
  // Resolver step #3 "Auto" badge: true when an auto controller (adaptive clock) is overriding the
  // clock key on the CurrentRun layer, shadowing the user's manual Base value. While true the manual
  // control is disabled and the displayed % is the live effective value (not a stale Base value).
  @State private var cpuClockAutoOverridden: Bool = false

  @State private var vbiEnabled: Bool = false
  @State private var vbiPercent: Int = 100
  @State private var vbiAutoOverridden: Bool = false

  // Correctness Validation disclosure (manual; DisclosureGroup is tvOS-unavailable). Collapsed by default.
  @State private var showValidation: Bool = false

  var body: some View {
    List {
      Section(header: Text(L("CPU Options")),
              footer: Text(jitAvailable
                           ? L("These options control the PowerPC CPU emulation. On iCube the emulated CPU is almost always the performance bottleneck, so the CPU options below matter far more than any graphics setting.")
                           : L("This build runs without JIT, so games always use the Cached Interpreter (the JIT engine choices are hidden). The emulated CPU is the performance bottleneck on iCube — these options matter far more than any graphics setting."))) {
        NavigationLink("\(L("CPU Emulation Engine")): \(effectiveCpuEngineLabel)", destination: CpuEnginePicker(selected: $cpuEngine, jitAvailable: jitAvailable))
          .onChange(of: cpuEngine) { DOLConfigBridge.setMainCpuCore($0.rawValue) }
        rowWithCaption(
          Toggle(L("Enable MMU"), isOn: $mmu)
            .onChange(of: mmu) { DOLConfigBridge.setMainMMU($0) },
          L("Emulates the PowerPC memory management unit. Required by a small number of games (e.g. some Star Wars titles) but adds CPU overhead on every memory access, so it hurts the framerate on this already CPU-bound build. Leave OFF unless a specific game needs it."))
        rowWithCaption(
          Toggle(L("Adaptive Clock (auto VI/CPU)"), isOn: $adaptiveClock),
          L("Lets iCube auto-tune the emulated CPU/VI clock to trade accuracy for speed when frames run long. Experimental iCube option. Applies on next game launch."))
        VStack(alignment: .leading, spacing: 4) {
          Picker(L("Vertex Loader"), selection: $vertexLoaderMode) {
            Text(L("Software")).tag(0)
            Text(L("NEON SIMD (default)")).tag(1)
            Text(L("Compare (validate)")).tag(2)
          }
          Text(L("How vertex data is decoded on the CPU. NEON SIMD is the fast default on Apple Silicon; Software is the slow reference path; Compare runs both and asserts they match (debug only — slowest). Leave on NEON SIMD. Applies on next game launch."))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        rowWithCaption(
          Toggle(L("Pause on Panic"), isOn: $pauseOnPanic)
            .onChange(of: pauseOnPanic) { DOLConfigBridge.setMainPauseOnPanic($0) },
          L("Pauses emulation and shows a dialog when the core hits an internal error. Useful for debugging; leave OFF for normal play."))
        rowWithCaption(
          Toggle(L("Accurate CPU Cache (slower)"), isOn: $writeBackCache)
            .onChange(of: writeBackCache) { DOLConfigBridge.setMainAccurateCpuCache($0) },
          L("Emulates the PowerPC data cache more precisely. Fixes a few games that depend on cache timing, but noticeably slows the interpreter. Leave OFF unless a game misbehaves without it."))
        rowWithCaption(
          Toggle(L("Bypass Instruction Cache"), isOn: $disableICache)
            .onChange(of: disableICache) { DOLConfigBridge.setMainDisableICache($0) },
          L("Skips emulation of the PowerPC instruction cache. Can give a small CPU speedup but may cause bugs in games that rely on I-cache behavior. Usually keep OFF."))
        // "Fast FP" (MAIN_FP_FAST) toggle removed: it's vestigial — the config key gates nothing
        // in this interpreter build and can't be wired without a large architecture port. Config key
        // stays defined so the bridge/config layer doesn't break; only the dead UI row is dropped.
        rowWithCaption(
          Toggle(L("CachedInterpreter Prefetch (Apple Silicon)"), isOn: $cachedInterpreterPrefetch)
            .onChange(of: cachedInterpreterPrefetch) { DOLConfigBridge.setMainCachedInterpreterPrefetch($0) },
          L("Adds software-prefetch hints to the Cached Interpreter hot loop on Apple Silicon. ON by default and generally a small win on the CPU-bound path; an A/B knob you can turn off to compare. Applies on next game launch."))
        rowWithCaption(
          Toggle(L("NEON Texture Decoder"), isOn: $neonTextureDecode)
            .onChange(of: neonTextureDecode) { DOLConfigBridge.setGfxHackNeonTextureDecode($0) },
          L("ARM64 NEON SIMD texture decoder. ON by default; turning it off falls back to the slower scalar decoder. A/B knob. Applies on next game launch."))
        // Engine-specific optimizations (PIC, specialized ops, fusion, etc.) and their
        // correctness-validation twins now live in their own engine-aware sections below
        // (see "Engine Optimizations" + "Correctness Validation"), so this list only carries
        // the general, engine-agnostic CPU options.
        rowWithCaption(
          Toggle(L("DCBZ Hack"), isOn: $lowDCBZ)
            .onChange(of: lowDCBZ) { DOLConfigBridge.setMainLowDCBZHack($0) },
          L("Skips part of the dcbz (data-cache-block-zero) instruction. Can speed up a few games but breaks others (notably some Wii titles). Leave OFF unless you know a game needs it."))
        // CPU Idle Detection / Fast-Forward
        rowWithCaption(
          Toggle(L("Relaxed Idle Loop Detection"), isOn: $relaxedIdleDetection)
            .onChange(of: relaxedIdleDetection) { DOLConfigBridge.setMainRelaxedIdleDetection($0) },
          L("Detects more idle loops so the CPU can skip busy-waiting. ON helps reclaim CPU time on the bottlenecked interpreter; very rarely affects timing. Default ON."))
        rowWithCaption(
          Toggle(L("Fast-Forward CTR Idle Loops"), isOn: $fastForwardCtrIdle)
            .onChange(of: fastForwardCtrIdle) { DOLConfigBridge.setMainFastForwardCtrIdle($0) },
          L("Fast-forwards counter-based idle loops instead of emulating every iteration. Can recover CPU headroom; may slightly affect timing-sensitive games. iCube tuning knob."))
        rowWithCaption(
          Toggle(L("Sync on Skip Idle"), isOn: $syncOnSkipIdle)
            .onChange(of: syncOnSkipIdle) { DOLConfigBridge.setMainSyncOnSkipIdle($0) },
          L("When the CPU fast-forwards through an idle loop, flush the GPU so it stays in sync. ON by default for correctness; turning it off skips the flush for a small CPU win but can cause graphical glitches in some games. A/B knob."))
      }

      // MARK: Engine Optimizations (engine-aware: only the toggles that affect the
      // currently selected Cached Interpreter engine are shown; experimental ones are
      // unmarked, the proven default-on wins carry a "Recommended" badge).
      if showEngineOpts {
        Section(header: Text(L("Engine Optimizations")),
                footer: Text(engineOptsFooter)) {
          settingsNavCaption(
            destination: PerformanceABView(),
            L("Snapshots + an honest benchmark preset (adaptive clock off, 100% clocks) for one-variable A/B testing.")) {
            Text(L("Performance A/B & Snapshots"))
          }
          Button(L("Reset Optimizations to Recommended")) { resetOptimizationsToRecommended() }
          // Shared — honored by BOTH the Cached Interpreter and the IR engine.
          optRow("PIC Load/Store", recommended: true, isOn: $cirPicLoadStore,
                 set: { DOLConfigBridge.setCirPicLoadStore($0) },
                 caption: "Direct-pointer load/store fast path — a large CPU win on memory-heavy games. Falls back safely for MMU / non-fastmem access. Applies on next game launch.")
          optRow("Specialized Ops", recommended: true, isOn: $cirSpecializedOps,
                 set: { DOLConfigBridge.setCirSpecializedOps($0) },
                 caption: "Routes hot integer ops through a direct, inlinable dispatch instead of the pointer-compare chain. The dispatched handler is the same interpreter function, so it's the safest of these knobs. Applies on next game launch.")
          optRow("Block Linking", recommended: true, isOn: $cirBlockLinking,
                 set: { DOLConfigBridge.setCirBlockLinking($0) },
                 caption: "Chains hot blocks directly to cut per-block dispatcher overhead — the biggest dispatch win. Any mismatch deopts safely to the dispatcher. Applies on next game launch.")
          optRow("Dynamic Links", recommended: true, isOn: $cirDynLinking,
                 set: { DOLConfigBridge.setCirDynLinking($0) },
                 caption: "Extends Block Linking to function returns and virtual calls (blr/bctr) and to the not-taken side of conditional branches: each exit remembers the last block it went to and jumps straight there when it repeats. Big win on call-heavy games (Wind Waker, Chibi-Robo). Requires Block Linking. Applies on next game launch.")
          optRow("NEON Paired-Single Math", isOn: $cirPsNeon,
                 set: { DOLConfigBridge.setCirPsNeon($0) },
                 caption: "Computes GameCube paired-single FP ops (ps_mul/add/madd/…) both lanes at once with ARM NEON instead of two scalar ops — the trick the JIT uses. Only fires for finite/normal values in IEEE mode; otherwise falls back to scalar. Experimental. Applies on next game launch.")

          if showCIROpts {
            optRow("FP Load/Store Specialization", isOn: $cirSpecializedFpLs,
                   set: { DOLConfigBridge.setCirSpecializedFpLs($0) },
                   caption: "Routes FP loads/stores (lfs/lfd/stfs/stfd + update/indexed) through the same direct jump-table dispatch the integer ops use, removing one indirect call per op. Targets FP-heavy games (e.g. Chibi-Robo). Only specializes when FP exceptions and MMU are off (so it's identical to the generic handler). Experimental; verify with Specialized Ops: Validate. Applies on next game launch.")
            optRow("Paired-Single Load/Store Specialization", isOn: $cirSpecializedPsq,
                   set: { DOLConfigBridge.setCirSpecializedPsq($0) },
                   caption: "Routes quantized paired-single loads/stores (psq_l/psq_st + update/indexed) through direct dispatch — the single hottest op class in paired-single-heavy games like Chibi-Robo. Composes with the Paired-Single Float Fast-Path (that speeds the handler body; this speeds how it's called). Experimental; verify with Specialized Ops: Validate. Applies on next game launch.")
            optRow("FP / Paired-Single Arithmetic Specialization", isOn: $cirSpecializedFpArith,
                   set: { DOLConfigBridge.setCirSpecializedFpArith($0) },
                   caption: "Routes FP and paired-single ARITHMETIC ops (fadd/fmul/fmadd…, ps_add/ps_mul/ps_madd…) through the same direct jump-table dispatch the integer ops use — one fewer indirect call per op. Composes with NEON Paired-Single Math (that speeds the math; this speeds how it's called). Targets FP/3D-heavy games (e.g. Tony Hawk). Dispatch-only, so identical to the generic handler. Experimental. Applies on next game launch.")
            optRow("Micro-Op Fusion", recommended: true, isOn: $cirMicroOpFusion,
                   set: { DOLConfigBridge.setCirMicroOpFusion($0) },
                   caption: "Fuses runs of integer ops into one dispatched block, cutting per-op dispatch overhead. The fused handlers are code-audited and self-validating. Applies on next game launch.")
            optRow("Dead Flag Elimination", isOn: $cirDeadFlagElim,
                   set: { DOLConfigBridge.setCirDeadFlagElim($0) },
                   caption: "Skips computing condition-flag (CR0/CR1) results the analyzer proves are overwritten before any branch reads them. Experimental; run its Validate pass before trusting it. Applies on next game launch.")
            optRow("Dead FPRF Elimination", isOn: $cirDeadFprfElim,
                   set: { DOLConfigBridge.setCirDeadFprfElim($0) },
                   caption: "Skips computing FP result flags (FPRF) for FP/paired-single ops when proven dead — a win on the FP-heavy hot path. FP accuracy is sensitive; experimental, run its Validate pass first. Applies on next game launch.")
            optRow("Paired-Single Float Fast-Path", isOn: $cirPsqFastPath,
                   set: { DOLConfigBridge.setCirPsqFastPath($0) },
                   caption: "Speeds up quantized paired-single load/stores (psq_l/psq_st) for the common plain-float, no-scale case (the hot path in titles like Chibi-Robo). The live quantization register is checked each execution, so other cases fall back unchanged. Experimental. Applies on next game launch.")
            optRow("Store-Loop (memset) Fast-Path", isOn: $cirStoreLoopFF,
                   set: { DOLConfigBridge.setCirStoreLoopFF($0) },
                   caption: "Detects tight byte-fill loops (the stb + addi + bdnz memset pattern) and performs the whole fill in one bulk write. The range is verified to be contiguous normal RAM first. Experimental. Applies on next game launch.")
            optRow("Cache-Management Loop Fast-Forward", isOn: $cirCacheLoopFF,
                   set: { DOLConfigBridge.setCirCacheLoopFF($0) },
                   caption: "Fast-forwards tight cache-management CTR loops (dcbf/dcbi/dcbst + addi + bdnz) that just invalidate a memory range line-by-line — common before DMA. Skips the per-op dispatch and does the invalidation in one pass. Only engages when accurate CPU cache is off. Experimental. Applies on next game launch.")
          }

          if showIROpts {
            optRow("Constant-Address Fusion", isOn: $cirIrConstFusion,
                   set: { DOLConfigBridge.setCirIrConstFusion($0) },
                   caption: "Fuses the ubiquitous lis+addi/ori/subi base-address pairs into a single precomputed constant load, halving the dispatch on that pattern. IR engine only. Experimental. Applies on next game launch.")
            optRow("Micro-Op Fusion", isOn: $cirIrMicroOpFusion,
                   set: { DOLConfigBridge.setCirIrMicroOpFusion($0) },
                   caption: "Coalesces runs of flag-free, exception-free integer ALU ops into a single dispatched unit, cutting per-op dispatch overhead on straight-line code. IR engine only. Experimental. Applies on next game launch.")
            optRow("Dead CR-Flag Elimination", isOn: $cirIrDeadFlagElim,
                   set: { DOLConfigBridge.setCirIrDeadFlagElim($0) },
                   caption: "Skips computing condition-flag (CR) results the block-analyzer proves are overwritten before any read — the same elimination the default Cached Interpreter offers, as an IR pass. IR engine only. Experimental. Applies on next game launch.")
          }
        }

        // MARK: Correctness Validation — collapsed by default. These re-run each
        // optimization against the reference interpreter and assert bit-identical
        // results (much slower). Each row is disabled until its parent optimization
        // is ON, so the "requires X" relationship is enforced, not just documented.
        Section {
          // Manual collapsible (DisclosureGroup is unavailable on tvOS): a header button
          // toggles a @State flag that gates the validator rows.
          Button {
            withAnimation { showValidation.toggle() }
          } label: {
            HStack {
              Text(L("Correctness Validation (developer, slow)"))
              Spacer()
              Image(systemName: showValidation ? "chevron.down" : "chevron.right")
                .font(.caption).foregroundStyle(.secondary)
            }
          }
          if showValidation {
            // Shared
            validateRow("NEON Paired-Single Math: Validate", isOn: $cirPsNeonValidate,
                        set: { DOLConfigBridge.setCirPsNeonValidate($0) }, parentOn: cirPsNeon,
                        caption: "Double-runs each NEON paired-single op against the scalar computation and asserts both lanes are bit-identical. Requires NEON Paired-Single Math ON.")
            if showCIROpts {
              validateRow("Specialized Ops: Validate", isOn: $cirSpecializedOpsValidate,
                          set: { DOLConfigBridge.setCirSpecializedOpsValidate($0) }, parentOn: cirSpecializedOps,
                          caption: "Double-runs every specialized op against the generic interpreter and flags any divergence. Requires Specialized Ops ON.")
              validateRow("Block Linking: Validate", isOn: $cirBlockLinkingValidate,
                          set: { DOLConfigBridge.setCirBlockLinkingValidate($0) }, parentOn: cirBlockLinking,
                          caption: "Re-resolves each linked block through the dispatcher and flags stale or wrong-target links. Requires Block Linking ON.")
              validateRow("Micro-Op Fusion: Validate", isOn: $cirMicroOpFusionValidate,
                          set: { DOLConfigBridge.setCirMicroOpFusionValidate($0) }, parentOn: cirMicroOpFusion,
                          caption: "Runs the real interpreter alongside each fused block and flags any divergence in registers, flags, or condition codes. Requires Micro-Op Fusion ON.")
              validateRow("Dead Flag Elimination: Validate", isOn: $cirDeadFlagElimValidate,
                          set: { DOLConfigBridge.setCirDeadFlagElimValidate($0) }, parentOn: cirDeadFlagElim,
                          caption: "Double-runs every eliminated op (flag computed vs skipped) and flags any divergence in a live condition field. Requires Dead Flag Elimination ON.")
              validateRow("Dead FPRF Elimination: Validate", isOn: $cirDeadFprfElimValidate,
                          set: { DOLConfigBridge.setCirDeadFprfElimValidate($0) }, parentOn: cirDeadFprfElim,
                          caption: "Double-runs every eliminated FP op (FPRF computed vs skipped) and flags any divergence in a result register or non-FPRF FPSCR bit. Requires Dead FPRF Elimination ON.")
              validateRow("Paired-Single Float Fast-Path: Validate", isOn: $cirPsqFastPathValidate,
                          set: { DOLConfigBridge.setCirPsqFastPathValidate($0) }, parentOn: cirPsqFastPath,
                          caption: "For every psq op that takes the fast path, derives the result both ways and flags any divergence (a mis-handled type, scale, or single-vs-paired case). Requires Paired-Single Float Fast-Path ON.")
              validateRow("Store-Loop Fast-Path: Validate", isOn: $cirStoreLoopFFValidate,
                          set: { DOLConfigBridge.setCirStoreLoopFFValidate($0) }, parentOn: cirStoreLoopFF,
                          caption: "Runs the real per-store loop on a snapshot and asserts the filled memory and post-loop registers match the bulk fill. Requires Store-Loop Fast-Path ON.")
              validateRow("Cache-Loop Fast-Forward: Validate", isOn: $cirCacheLoopFFValidate,
                          set: { DOLConfigBridge.setCirCacheLoopFFValidate($0) }, parentOn: cirCacheLoopFF,
                          caption: "Runs the real per-line cache loop on a snapshot and asserts the post-loop registers and CTR match the fast-forward. Requires Cache-Management Loop Fast-Forward ON.")
            }
            if showIROpts {
              validateRow("PIC Load/Store: Validate", isOn: $cirIrPicLoadStoreValidate,
                          set: { DOLConfigBridge.setCirIrPicLoadStoreValidate($0) }, parentOn: cirPicLoadStore,
                          caption: "For every load/store that takes the PIC fast path, runs the plain interpreter access on a snapshot and asserts the loaded register / stored memory / update-form writeback are bit-identical. Requires PIC Load/Store ON.")
              validateRow("Specialized Ops: Validate", isOn: $cirIrSpecializedOpsValidate,
                          set: { DOLConfigBridge.setCirIrSpecializedOpsValidate($0) }, parentOn: cirSpecializedOps,
                          caption: "Dual-runs each specialized op vs the plain interpreter op and asserts bit-identical state. Requires Specialized Ops ON.")
              validateRow("Constant-Address Fusion: Validate", isOn: $cirIrConstFusionValidate,
                          set: { DOLConfigBridge.setCirIrConstFusionValidate($0) }, parentOn: cirIrConstFusion,
                          caption: "For every fused pair, runs the original two ops and asserts the destination register matches the precomputed constant. Requires Constant-Address Fusion ON.")
              validateRow("Micro-Op Fusion: Validate", isOn: $cirIrMicroOpFusionValidate,
                          set: { DOLConfigBridge.setCirIrMicroOpFusionValidate($0) }, parentOn: cirIrMicroOpFusion,
                          caption: "For every fused run, runs the ops un-fused and asserts the resulting registers match. Requires Micro-Op Fusion ON.")
              validateRow("Dead CR-Flag Elimination: Validate", isOn: $cirIrDeadFlagElimValidate,
                          set: { DOLConfigBridge.setCirIrDeadFlagElimValidate($0) }, parentOn: cirIrDeadFlagElim,
                          caption: "Double-runs every eliminated op (CR computed vs skipped) and asserts the live CR fields match. Requires Dead CR-Flag Elimination ON.")
            }
          }
        }

        // Diagnostics — the hot-block profiler is a Cached Interpreter feature.
        if showCIROpts {
          Section(header: Text(L("Diagnostics"))) {
            rowWithCaption(
              Toggle(L("CIR Hot-Block Profiler"), isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: "icube.cirProfile") },
                set: { UserDefaults.standard.set($0, forKey: "icube.cirProfile") })),
              L("Records the hottest interpreter blocks for the running game. Turn ON, relaunch the game, play the slow scene, then tap Copy State in the perf HUD — the dump ends with a CIR HOT BLOCKS section showing where CPU time goes. Diagnostic only (no perf cost when OFF). Applies on next game launch."))
          }
        }
      } else {
        Section(header: Text(L("Engine Optimizations"))) {
          Text(L("Select Cached Interpreter or Cached Interpreter (IR) as the CPU engine above to configure optimizations. The plain Interpreter and JIT engines don't use these."))
            .font(.caption).foregroundStyle(.secondary)
        }
      }

      Section(header: Text(L("Clock Override"))) {
        rowWithCaption(
          Toggle(L("Enable Emulated CPU Clock Override"), isOn: $cpuClockEnabled)
            .disabled(cpuClockAutoOverridden)
            .onChange(of: cpuClockEnabled) { DOLConfigBridge.setMainOverclockEnable($0) },
          L("Adjusts the emulated CPU's clock rate. Higher values can raise the framerate of variable-rate games at a performance cost; lower values may trigger a game's internal frameskip. ⚠️ Changing this from 100% can and will break games — use at your own risk."))
        HStack {
#if os(tvOS)
          TVIntStepper(value: $cpuClockPercent, range: 1...400, step: 1)
#else
          Slider(value: Binding(get: { Double(cpuClockPercent) }, set: { cpuClockPercent = Int($0) }), in: 1...400)
            .frame(width: 260)
#endif
          Spacer()
          // Resolver step #3: "Auto" badge when the adaptive clock is overriding this key.
          if cpuClockAutoOverridden {
            Text(L("Auto"))
              .font(.caption).bold()
              .foregroundStyle(.secondary)
              .padding(.horizontal, 8).padding(.vertical, 4)
              .background(Color.blue.opacity(0.1), in: Capsule())
          }
          Text("\(cpuClockPercent)%")
            .foregroundStyle(.secondary)
        }
        // While the adaptive clock drives this key (CurrentRun), disable the manual control so the
        // displayed effective % can't be silently shadowed by a stale Base value authored here.
        .disabled(!cpuClockEnabled || cpuClockAutoOverridden)
        .onChange(of: cpuClockPercent) { DOLConfigBridge.setMainOverclockPercent($0) }
      }

      Section(header: Text(L("Override VBI Frequency"))) {
        rowWithCaption(
          Toggle(L("Enable VBI Frequency Override"), isOn: $vbiEnabled)
            .disabled(vbiAutoOverridden)
            .onChange(of: vbiEnabled) { DOLConfigBridge.setMainViOverclockEnable($0) },
          L("Makes games run at a different frame rate. Lowering it makes emulation less demanding; raising it can improve smoothness. May change gameplay speed, since speed is often tied to frame rate."))
        HStack {
#if os(tvOS)
          TVIntStepper(value: $vbiPercent, range: 1...400, step: 1)
#else
          Slider(value: Binding(get: { Double(vbiPercent) }, set: { vbiPercent = Int($0) }), in: 1...400)
            .frame(width: 260)
#endif
          Spacer()
          // Resolver step #3: "Auto" badge when the adaptive clock is overriding this key.
          if vbiAutoOverridden {
            Text(L("Auto"))
              .font(.caption).bold()
              .foregroundStyle(.secondary)
              .padding(.horizontal, 8).padding(.vertical, 4)
              .background(Color.blue.opacity(0.1), in: Capsule())
          }
          Text("\(vbiPercent)%")
            .foregroundStyle(.secondary)
        }
        .disabled(!vbiEnabled || vbiAutoOverridden)
        .onChange(of: vbiPercent) { DOLConfigBridge.setMainViOverclockPercent($0) }
      }
    }
    .navigationTitle(L("Performance Tuning"))
    .configSynced { syncPerformanceTuning() }
  }

  /// The engine label to display. On jitless builds a stored JIT core actually
  /// runs as Cached Interpreter, so show that truth instead of the misleading
  /// "JIT (recommended)" the raw config would imply.
  private var effectiveCpuEngineLabel: String {
    if !jitAvailable && (cpuEngine == .jit64 || cpuEngine == .jitARM64) {
      return CpuEngine.cachedInterpreter.label
    }
    return cpuEngine.label
  }

  /// Inline secondary-text description under a row. Forwards to the canonical
  /// file-scope `settingsCaption` so there is one description style everywhere.
  @ViewBuilder
  private func rowWithCaption<Content: View>(_ content: Content, _ caption: String) -> some View {
    settingsCaption(content, caption)
  }

  /// The engine that ACTUALLY runs. On a jitless build a stored JIT core silently
  /// runs as the Cached Interpreter, so optimization applicability follows that
  /// truth (mirrors `effectiveCpuEngineLabel`).
  private var effectiveEngine: CpuEngine {
    if !jitAvailable && (cpuEngine == .jit64 || cpuEngine == .jitARM64) {
      return .cachedInterpreter
    }
    return cpuEngine
  }
  /// Optimizations apply only to the two Cached Interpreter engines.
  private var showCIROpts: Bool { effectiveEngine == .cachedInterpreter }
  private var showIROpts: Bool { effectiveEngine == .cachedInterpreterIR }
  private var showEngineOpts: Bool { showCIROpts || showIROpts }

  private var engineOptsFooter: String {
    showIROpts
      ? L("Optimizations for the Cached Interpreter (IR) engine. The shared options at the top also apply to the default Cached Interpreter. \"Recommended\" options are on by default and are the proven speed wins — leave them on. The rest are experimental A/B knobs; verify one with its Validate pass before trusting it.")
      : L("Optimizations for the Cached Interpreter engine. \"Recommended\" options are on by default and are the proven speed wins — leave them on. The rest are experimental A/B knobs; verify one with its Validate pass before trusting it.")
  }

  /// A standard optimization toggle row. `recommended` adds the green badge for the
  /// proven default-on wins so their on/off state is impossible to miss.
  @ViewBuilder
  private func optRow(_ title: String, recommended: Bool = false, isOn: Binding<Bool>,
                      set: @escaping (Bool) -> Void, caption: String) -> some View {
    rowWithCaption(
      Toggle(isOn: isOn) {
        if recommended {
          HStack(spacing: 6) { Text(L(title)); RecommendedBadge() }
        } else {
          Text(L(title))
        }
      }
      .onChange(of: isOn.wrappedValue) { set($0) },
      L(caption))
  }

  /// A correctness-validation toggle, disabled until its parent optimization is ON.
  @ViewBuilder
  private func validateRow(_ title: String, isOn: Binding<Bool>,
                           set: @escaping (Bool) -> Void, parentOn: Bool, caption: String) -> some View {
    rowWithCaption(
      Toggle(L(title), isOn: isOn)
        .disabled(!parentOn)
        .onChange(of: isOn.wrappedValue) { set($0) },
      L(caption))
  }

  /// Restore every optimization flag to its shipping default: the proven wins ON,
  /// every experimental knob and every Validate twin OFF. This is the fix for the
  /// "no gains" reports that turned out to be runs with the recommended opts toggled off.
  private func resetOptimizationsToRecommended() {
    // Shared + CIR proven wins -> ON.
    cirBlockLinking = true; DOLConfigBridge.setCirBlockLinking(true)
    cirDynLinking = true; DOLConfigBridge.setCirDynLinking(true)
    cirPicLoadStore = true; DOLConfigBridge.setCirPicLoadStore(true)
    cirSpecializedOps = true; DOLConfigBridge.setCirSpecializedOps(true)
    cirMicroOpFusion = true; DOLConfigBridge.setCirMicroOpFusion(true)
    // Experimental -> OFF.
    cirPsNeon = false; DOLConfigBridge.setCirPsNeon(false)
    cirSpecializedFpLs = false; DOLConfigBridge.setCirSpecializedFpLs(false)
    cirSpecializedPsq = false; DOLConfigBridge.setCirSpecializedPsq(false)
    cirSpecializedFpArith = false; DOLConfigBridge.setCirSpecializedFpArith(false)
    cirDeadFlagElim = false; DOLConfigBridge.setCirDeadFlagElim(false)
    cirDeadFprfElim = false; DOLConfigBridge.setCirDeadFprfElim(false)
    cirPsqFastPath = false; DOLConfigBridge.setCirPsqFastPath(false)
    cirStoreLoopFF = false; DOLConfigBridge.setCirStoreLoopFF(false)
    cirCacheLoopFF = false; DOLConfigBridge.setCirCacheLoopFF(false)
    cirIrConstFusion = false; DOLConfigBridge.setCirIrConstFusion(false)
    cirIrMicroOpFusion = false; DOLConfigBridge.setCirIrMicroOpFusion(false)
    cirIrDeadFlagElim = false; DOLConfigBridge.setCirIrDeadFlagElim(false)
    // All Validate twins -> OFF.
    cirSpecializedOpsValidate = false; DOLConfigBridge.setCirSpecializedOpsValidate(false)
    cirMicroOpFusionValidate = false; DOLConfigBridge.setCirMicroOpFusionValidate(false)
    cirDeadFlagElimValidate = false; DOLConfigBridge.setCirDeadFlagElimValidate(false)
    cirDeadFprfElimValidate = false; DOLConfigBridge.setCirDeadFprfElimValidate(false)
    cirPsqFastPathValidate = false; DOLConfigBridge.setCirPsqFastPathValidate(false)
    cirStoreLoopFFValidate = false; DOLConfigBridge.setCirStoreLoopFFValidate(false)
    cirCacheLoopFFValidate = false; DOLConfigBridge.setCirCacheLoopFFValidate(false)
    cirIrConstFusionValidate = false; DOLConfigBridge.setCirIrConstFusionValidate(false)
    cirPsNeonValidate = false; DOLConfigBridge.setCirPsNeonValidate(false)
    cirIrMicroOpFusionValidate = false; DOLConfigBridge.setCirIrMicroOpFusionValidate(false)
    cirIrDeadFlagElimValidate = false; DOLConfigBridge.setCirIrDeadFlagElimValidate(false)
    cirIrPicLoadStoreValidate = false; DOLConfigBridge.setCirIrPicLoadStoreValidate(false)
    cirIrSpecializedOpsValidate = false; DOLConfigBridge.setCirIrSpecializedOpsValidate(false)
    cirBlockLinkingValidate = false; DOLConfigBridge.setCirBlockLinkingValidate(false)
  }

  private func syncPerformanceTuning() {
    jitAvailable = JitManager.shared().acquiredJit
    cpuEngine = CpuEngine.from(raw: DOLConfigBridge.mainCpuCore())
    mmu = DOLConfigBridge.mainMMU()
    // adaptiveClock / vertexLoaderMode are @AppStorage now — auto-loaded, no manual sync needed.
    pauseOnPanic = DOLConfigBridge.mainPauseOnPanic()
    writeBackCache = DOLConfigBridge.mainAccurateCpuCache()
    disableICache = DOLConfigBridge.mainDisableICache()
    lowDCBZ = DOLConfigBridge.mainLowDCBZHack()
    cachedInterpreterPrefetch = DOLConfigBridge.mainCachedInterpreterPrefetch()
    neonTextureDecode = DOLConfigBridge.gfxHackNeonTextureDecode()
    cirPicLoadStore = DOLConfigBridge.cirPicLoadStore()
    cirSpecializedOps = DOLConfigBridge.cirSpecializedOps()
    cirSpecializedOpsValidate = DOLConfigBridge.cirSpecializedOpsValidate()
    cirSpecializedFpLs = DOLConfigBridge.cirSpecializedFpLs()
    cirSpecializedPsq = DOLConfigBridge.cirSpecializedPsq()
    cirSpecializedFpArith = DOLConfigBridge.cirSpecializedFpArith()
    cirMicroOpFusion = DOLConfigBridge.cirMicroOpFusion()
    cirMicroOpFusionValidate = DOLConfigBridge.cirMicroOpFusionValidate()
    cirDeadFlagElim = DOLConfigBridge.cirDeadFlagElim()
    cirDeadFlagElimValidate = DOLConfigBridge.cirDeadFlagElimValidate()
    cirDeadFprfElim = DOLConfigBridge.cirDeadFprfElim()
    cirDeadFprfElimValidate = DOLConfigBridge.cirDeadFprfElimValidate()
    cirPsqFastPath = DOLConfigBridge.cirPsqFastPath()
    cirPsqFastPathValidate = DOLConfigBridge.cirPsqFastPathValidate()
    cirStoreLoopFF = DOLConfigBridge.cirStoreLoopFF()
    cirStoreLoopFFValidate = DOLConfigBridge.cirStoreLoopFFValidate()
    cirCacheLoopFF = DOLConfigBridge.cirCacheLoopFF()
    cirCacheLoopFFValidate = DOLConfigBridge.cirCacheLoopFFValidate()
    cirIrConstFusion = DOLConfigBridge.cirIrConstFusion()
    cirIrConstFusionValidate = DOLConfigBridge.cirIrConstFusionValidate()
    cirPsNeon = DOLConfigBridge.cirPsNeon()
    cirPsNeonValidate = DOLConfigBridge.cirPsNeonValidate()
    cirIrMicroOpFusion = DOLConfigBridge.cirIrMicroOpFusion()
    cirIrMicroOpFusionValidate = DOLConfigBridge.cirIrMicroOpFusionValidate()
    cirIrDeadFlagElim = DOLConfigBridge.cirIrDeadFlagElim()
    cirIrDeadFlagElimValidate = DOLConfigBridge.cirIrDeadFlagElimValidate()
    cirIrPicLoadStoreValidate = DOLConfigBridge.cirIrPicLoadStoreValidate()
    cirIrSpecializedOpsValidate = DOLConfigBridge.cirIrSpecializedOpsValidate()
    cirBlockLinking = DOLConfigBridge.cirBlockLinking()
    cirDynLinking = DOLConfigBridge.cirDynLinking()
    cirBlockLinkingValidate = DOLConfigBridge.cirBlockLinkingValidate()
    // Ensure idle detection toggles persist
    relaxedIdleDetection = DOLConfigBridge.mainRelaxedIdleDetection()
    fastForwardCtrIdle = DOLConfigBridge.mainFastForwardCtrIdle()
    syncOnSkipIdle = DOLConfigBridge.mainSyncOnSkipIdle()
    // CI block linking toggle does not need local state; bound directly
    cpuClockEnabled = DOLConfigBridge.mainOverclockEnable()
    cpuClockPercent = DOLConfigBridge.mainOverclockPercent()
    vbiEnabled = DOLConfigBridge.mainViOverclockEnable()
    vbiPercent = DOLConfigBridge.mainViOverclockPercent()
    // Resolver step #3: is an auto controller currently overriding these clock keys (CurrentRun)?
    cpuClockAutoOverridden = DOLConfigBridge.isOverclockAutoOverridden()
    vbiAutoOverridden = DOLConfigBridge.isViOverclockAutoOverridden()
  }
}

private struct RecommendedBadge: View {
  var body: some View {
    Text(L("Recommended"))
      .font(.caption2).bold()
      .foregroundStyle(.green)
      .padding(.horizontal, 6).padding(.vertical, 2)
      .background(Color.green.opacity(0.12), in: Capsule())
  }
}

/// Shared inline-description helper. Wraps any control with a `.caption` secondary
/// line directly under it. This is the single canonical row style for the whole
/// settings surface — every page uses it instead of section footers or tap-to-open
/// info popovers, so descriptions are always visible inline.
@ViewBuilder
func settingsCaption<Content: View>(_ content: Content, _ caption: String) -> some View {
  VStack(alignment: .leading, spacing: 4) {
    content
    Text(caption)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// NavigationLink row with an inline caption *inside* the link's label, so the row
/// keeps its disclosure chevron and full-row tap target (wrapping a NavigationLink
/// in an external VStack would strip both). `label` is the normal row content
/// (e.g. an HStack with title + trailing value).
@ViewBuilder
func settingsNavCaption<Destination: View, Label: View>(
  destination: Destination,
  _ caption: String,
  @ViewBuilder label: () -> Label
) -> some View {
  NavigationLink(destination: destination) {
    VStack(alignment: .leading, spacing: 4) {
      label()
      Text(caption)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

// Raw values MUST match PowerPC::CPUCore (PowerPC.h): Interpreter=0, JIT64=1,
// JITARM64=4, CachedInterpreter=5. The enum is gapped (2 and 3 are retired cores),
// so naive sequential raw values would write/read the wrong core — e.g. a stored
// Cached Interpreter (5) would read back as JIT, and selecting Cached Interpreter
// would actually store JIT64. Declaration order (not raw value) drives the picker
// display order, so the user-facing list is unchanged.
private enum CpuEngine: Int, CaseIterable {
  case interpreter = 0
  case cachedInterpreter = 5
  case cachedInterpreterIR = 6
  case jit64 = 1
  case jitARM64 = 4
  var label: String {
    switch self {
    case .interpreter: return L("Interpreter (slowest)")
    // "(slower)" was upstream's wording relative to the JIT, which non-jailbroken iOS never gets;
    // on device this engine measured ~1.7x faster than the IR one (2026-09-16 A/B).
    case .cachedInterpreter: return L("Cached Interpreter (recommended)")
    case .cachedInterpreterIR: return L("Cached Interpreter IR (experimental, usually slower)")
    case .jit64: return L("JIT Recompiler for x86-64 (recommended)")
    case .jitARM64: return L("JIT Recompiler for ARM64 (recommended)")
    }
  }
  static func from(raw: Int) -> CpuEngine { CpuEngine(rawValue: raw) ?? .jitARM64 }
}

private struct CpuEnginePicker: View {
  @Binding var selected: CpuEngine
  /// When false (App Store / jitless build), JIT engine choices are hidden
  /// because the core cannot run them and silently falls back to the Cached
  /// Interpreter at launch.
  var jitAvailable: Bool = true
  private var choices: [CpuEngine] {
    // The IR core (CPUCore 6) is data-interpreted and App-Store-legal, so it must
    // appear in the jitless list too — not just when JIT is available.
    jitAvailable ? CpuEngine.allCases : [.interpreter, .cachedInterpreter, .cachedInterpreterIR]
  }
  /// The row to check. On a jitless build a stored JIT core (the arm64 default) actually
  /// runs as Cached Interpreter and isn't in `choices`, so checking `value == selected`
  /// would leave NO row checked. Map a JIT core to Cached Interpreter so the checkmark
  /// lands on the engine that actually runs (mirrors the parent's effectiveCpuEngineLabel).
  private var effectiveSelected: CpuEngine {
    if !jitAvailable && (selected == .jit64 || selected == .jitARM64) {
      return .cachedInterpreter
    }
    return selected
  }
  var body: some View {
    List {
      Section(footer: Text(jitAvailable
                           ? L("Cached Interpreter and the JIT recompilers are faster; the plain Interpreter is the most accurate but far too slow for full-speed play.")
                           : L("This build runs without a JIT entitlement, so only interpreter engines are available. Cached Interpreter is the recommended (and default) choice. Selecting a JIT engine on other builds would silently fall back to Cached Interpreter here."))) {
        ForEach(Array(choices.enumerated()), id: \.offset) { _, value in
          SettingsSelectRow(label: value.label, checked: value == effectiveSelected) { selected = value; DOLConfigBridge.setMainCpuCore(value.rawValue) }
        }
      }
    }
    .navigationTitle(L("CPU Emulation Engine"))
  }
}

