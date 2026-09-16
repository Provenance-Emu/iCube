# iCube fork-patch inventory

Checklist for the next upstream Dolphin merge: every file under `Source/Core`,
`Source/UnitTests`, `CMakeLists.txt`, `CMake/`, and `Externals/` that iCube
touches relative to upstream, why, and how to carry it forward.
Base tag: **2509** (`f0519d4f6c`). Generated: **2026-09-15**.
Regenerate with:
`git diff --stat f0519d4f6c..HEAD -- Source/Core CMakeLists.txt CMake Externals Source/UnitTests`
plus `git log --format='%h %ad %s' f0519d4f6c..HEAD -- <path>` per file.

## Core/PowerPC

The centerpiece of the fork: a new IR-based "CIR" (Cached Interpreter IR)
tier registered as **CPUCore 6 ("M0")**, plus NEON paired-single fast paths
in the plain interpreter. Built up over ~35 commits (M0 → M9 milestones,
"WIN#1-3", "gate-0") from 2026-06-02 through 2026-06-14.

| File | Lines +/- | Purpose | Merge guidance |
|---|---|---|---|
| `Core/PowerPC/CachedInterpreter/CachedInterpreterIR.cpp` | +3303/-0 | New file: typed IR node layer, optimizer passes (dead CR-flag/FPRF elim, const-address fusion, micro-op fusion, block-linking, O(1) jump-table dispatch), hot-block profiler. | Carry as-is (new file); watch for upstream CachedInterpreter API renames it dispatches through. |
| `Core/PowerPC/CachedInterpreter/CachedInterpreterIR.h` | +831/-0 | Header for the above: IR node/opcode enums, pass interfaces. | Carry as-is. |
| `Core/PowerPC/CachedInterpreter/CachedInterpreter.cpp` | +5001/-79 | Wires CIR into the existing cached-interpreter block builder: specialized FP/paired-single/quantized load-store dispatch, PIC direct-pointer fast paths, cache-management-loop and counted-store-loop (memset) fast-forwarding, block linking. | Re-port onto upstream API — this file changes most per upstream release; diff against the file's own history (35 fork commits) rather than reconstructing from scratch. |
| `Core/PowerPC/CachedInterpreter/CachedInterpreter.h` | +471/-4 | Declares the new fast-path/specialization entry points and per-block metadata used by the .cpp above. | Re-port alongside CachedInterpreter.cpp. |
| `CachedInterpreterIR.h` / `.cpp` (2026-09-16) | +40/-30 | IRInst 104 → 64 bytes (one cache line, `static_assert`ed): the six per-node region base/mask fields became one `const IRMemBases*` to a struct owned by the CIR (`m_mem_bases`, refreshed in `PassPICLoadStore`), and `opinfo_flags` is `u32` (only FL_RC_BIT/FL_RC_BIT_F/FL_LOADSTORE/FL_USE_FPU are read; `static_assert`ed at the stamp site). Footprint win; the dispatcher's instruction-level profile kept the same shape, so no big throughput claim. | Carry as-is; if upstream adds flags above bit 32 that the IR needs, widen the field and re-check the size assert. |
| `Core/PowerPC/MMU.cpp` / `.h` (2026-09-16) | +12/-2 | `Memcheck` split into a `DOLPHIN_FORCE_INLINE` `HasAny()` fast check + out-of-line `MemcheckSlow`; LTO had left the whole thing out of line on every guest access (~1 % of the CPU thread → 0 samples). | Take upstream then re-apply (3-line change). |
| `CachedInterpreterIR.cpp` threaded dispatch (2026-09-16) | +170/-0 | `ExecuteOneBlock` uses computed-goto (labels-as-values) dispatch under `ICUBE_IR_THREADED_DISPATCH`; the switch loop is kept as the fallback. Each IR vector gets a sentinel `EndBlock{0,0,0}` appended in DoJit (after the M1 self-check and the passes) so the hot dispatch has no end-of-vector compare — with the compare in front of the indirect branch LLVM folded every handler's dispatch into one shared tail (3 `br` in the function); without it there are 19, one per handler. Measured: executor self time 36.4 % → 32.9 % of the CPU thread (NSMBW, core 6), no fps change. | Carry as-is; the table order must mirror the IROp enum (static_assert on first/last). Verify with `otool -tV libdolphin.dylib` and count `br` in ExecuteOneBlock ≥ 18 — bitcode objects can't be checked before the LTO link. |
| `CachedInterpreter.{h,cpp}` / `CachedInterpreterIR.{h,cpp}` lmw/stmw outlined (2026-09-16) | +130/-90 | `LoadStoreMultiplePIC<store>` (private static, `[[gnu::noinline]]`, reached by a tail call, falls back itself) takes the lmw/stmw pre-scan+copy loops out of `LoadStoreDFormPIC` (core 5) and `LoadStorePIC` (core 6). Those loops were the only high-pressure region, so LLVM saved six callee-saved pairs on the path every load/store took; now only fp/lr remain (for the generic-handler fallback call). F-Zero core 5: handler 12.9 % → 9.9 % of the emulation thread; stack-op samples inside it ~16 % → 12.6 %. | Carry as-is; if upstream changes the PIC operands layout, update the structured binding in the core 5 helper. Static check: `otool -tV`, the handler must have no `x19..x28` references. |
| `CachedInterpreter.cpp` / `CachedInterpreterIR.cpp` FP D-form PIC (2026-09-16) | +110/-4 | lfs/lfsu/lfd/lfdu/stfs/stfsu/stfd/stfdu (opcodes 48-55) admitted to the direct-pointer path on both tiers (emit gate + `PICLoadStoreApplies`), with exact cases mirroring Interpreter_LoadStore.cpp (`ConvertToDouble` fill / PS0-only / `ConvertToSingle`); X-form FP and psq_* stay generic. F-Zero core 5: `Interpreter::lfs` and the u32 MMU read path gone, MMU write path 5.9 % → 4.2 %; net ≈ 1 point of the emulation thread. | Carry as-is; if upstream changes lfs/stfs conversion semantics, mirror them here. Validate modes compare GPRs/memory only, not FPRs. |
| `Core/PowerPC/CachedInterpreter/CachedInterpreterBlockCache.cpp` | +23/-0 | Minor hook for the new IR block bookkeeping. | Take upstream then re-apply (small diff). |
| `Core/PowerPC/CachedInterpreter/CachedInterpreterEmitter.h` | +16/-0 | Small emitter additions supporting IR lowering. | Take upstream then re-apply. |
| `Core/PowerPC/CachedInterpreter/CachedInterpreter_Disassembler.cpp` | +30/-0 | Debug disassembly support for the hot-block profiler. | Take upstream then re-apply. |
| `Core/PowerPC/Interpreter/Interpreter.cpp` / `.h` | +8/-0 | Hooks the NEON paired-single arithmetic fast path into the plain interpreter's dispatch. | Take upstream then re-apply. |
| `Core/PowerPC/Interpreter/Interpreter_Paired.cpp` | +558/-0 | New file: NEON-accelerated paired-single arithmetic (`ps_add`/`ps_mul`/etc.), engaged only in non-IEEE (NI=1) mode; fixed for correctness in a same-week follow-up. | Carry as-is (new file, NEON intrinsics only — no upstream API dependency). |
| `Core/PowerPC/Interpreter/Interpreter_LoadStorePaired.cpp` | +113/-0 | New file: NEON paired-single quantized load/store fast path companion to the above. | Carry as-is. |
| `Core/PowerPC/PPCAnalyst.cpp` / `.h` | +133/-0 | Analysis-pass support needed to recover jitless (CachedInterpreter) CPU perf on the 2509 base. | Re-port onto upstream API; check `PPCAnalyst` block-analysis signature hasn't moved. |
| `Core/PowerPC/PowerPC.cpp` / `.h` | +119/-0 | Registers CPUCore 6 (CachedInterpreterIR/"M0") in the `CPUCore` enum and core-switch logic; adds `DOLPHIN_FORCE_CI` env override. | Re-port onto upstream API — upstream periodically renumbers/extends `CPUCore`. |
| `Core/PowerPC/PowerPC.{h,cpp}` UpdatePerformanceMonitor (2026-09-16) | +30/-50 | Moved to the header as a branchless inline (mask-and-add per PMC, one overflow test) — the out-of-line four-switch version was called from every block terminal when a game programs the performance monitor (F-Zero GX does) and cost 4.0 % of the emulation thread on device. Same semantics. F-Zero core 5: symbol gone, LinkBlock absorbed it, the pair 6.7 % → 4.5 %. | Take upstream then re-apply; re-derive the shift positions from UReg_MMCR0/UReg_MMCR1 if upstream changes them. |
| `Core/PowerPC/MMU.cpp` | +26/-0 | Ultra-fast aligned 32-bit RAM read fast path (perf). | Take upstream then re-apply; verify semantics against unaligned/mirrored-memory edge cases upstream may have changed. |
| `Core/PowerPC/JitInterface.cpp` | +6/-0 | Small glue so JIT-selection code is aware of CPUCore 6. | Take upstream then re-apply. |
| `Core/PowerPC/JitArm64/Jit.cpp`, `JitArm64Cache.cpp`, `JitArm64_BackPatch.cpp`, `JitAsm.cpp`, `JitCommon/JitCache.cpp` | small (2-13 lines each) | Threads the iOS "writable region" pointer (see Common/MemoryUtil below) through Arm64Emitter call sites so JIT code is written via a separate writable mapping, not the executable one (TXM/W^X compliance). | Take upstream then re-apply — these are 1-3 line touch points, cheap to redo by grepping `writable region` / `ScopedJITPageWriteAndNoExecute`. |

Owner test: NSMBW / a native-code-heavy title boots and runs at full speed
on device with CPUCore set to CachedInterpreterIR (Settings > CPU), then
again with each CIR feature flag (`MAIN_CIR_*`) individually forced off to
confirm no flag is load-bearing for correctness; jitless (non-JIT) fallback
path also boots a title with `DOLPHIN_FORCE_CI` set.

## DiscIO

| File | Lines +/- | Purpose | Merge guidance |
|---|---|---|---|
| `DiscIO/HttpBlobReader.cpp` / `.h` | +3020/-0 | New file: WebDAV/HTTP-backed blob reader so ISOs can stream from a remote server instead of local storage. | Carry as-is (new file, self-contained `BlobReader` implementation); re-check `BlobReader` virtual interface after upstream bumps. |
| `DiscIO/Blob.cpp` | +244/-0 | Wires `HttpBlobReader` into `Blob`'s factory/open logic (URL detection, construction). Also carries the pre-existing `Don't create DriveReaders for CD drives on iOS` patch. | Re-port onto upstream API — `Blob.cpp`'s factory function is the integration seam; small but must track upstream's blob-type dispatch. |
| `DiscIO/CMakeLists.txt` | +12/-0 | Adds `HttpBlobReader.cpp/.h` to the build and links whatever HTTP dependency it needs. | Take upstream then re-apply. |
| `DiscIO/VolumeVerifier.cpp` | +2/-2 | Cosmetic: `redump.org` http→https. | Take upstream then re-apply (trivial). |

Owner test: an HTTP/WebDAV-backed ISO (URL configured in game library) boots
and plays past the intro; local-file ISOs still boot unaffected.

## InputCommon / ControllerInterface

Almost entirely the pre-existing iOS controller backend (MFi controllers,
haptics, touchscreen, keyboard) that predates the 2509 rebase and was
carried forward wholesale in "rebaseline cluster 7"; only haptics/device
options are new since 2509.

| File | Lines +/- | Purpose | Merge guidance |
|---|---|---|---|
| `ControllerInterface/iOS/*` (ButtonType.h, MFiController.\*, MFiControllerScanner.\*, MFiKeyboard.\*, Motor.\*, StateManager.\*, Touchscreen.\*, iOS.h/.mm) | +1519/-0 total | New iOS-only `ciface::InputBackend` implementation: GCController wrapping, CoreHaptics motor, on-screen touchscreen device, keyboard, per-device state manager. Entirely additive, self-contained subtree. | Carry as-is — these files don't exist upstream; only watch `ciface::InputBackend`/`ControllerInterface` base-class signature changes. |
| `ControllerInterface/ControllerInterface.cpp` / `.h` | +10/-1 | Registers the iOS backend (`AddInputBackend`) and platform switch. | Take upstream then re-apply. |
| `ControllerInterface/DualShockUDPClient/*` | +6/-0 | Minor iOS build-availability guards carried in the cluster-7 rebaseline. | Take upstream then re-apply. |
| `InputCommon/GCAdapter.cpp` | +7/-4 | `Don't use either implementation on iOS` (no USB GC adapter support on iOS). | Take upstream then re-apply. |
| `InputCommon/CMakeLists.txt` | +34/-2 | Adds the `ControllerInterface/iOS/*` sources and Apple frameworks (GameController, CoreHaptics) to the iOS build. | Take upstream then re-apply. |

Owner test: MFi controller connects and drives a game (buttons + gyro),
on-screen touch controls respond, and controller-disconnect haptics fire
without a crash (regressions here have previously caused Sentry crashes).

## VideoBackends/Metal

Native Metal backend hardening plus a fork-specific GPU-compute path for
EFB/XFB and vertex decode ("native-Metal moat").

| File | Lines +/- | Purpose | Merge guidance |
|---|---|---|---|
| `MTLGfx.mm` / `.h` | +544/-4 | Compute-based EFB/XFB acceleration layer, offscreen-pass routing restore, deprecated-reflection-API silencing. | Re-port onto upstream API — high-churn file; the compute path is fork logic layered on top of upstream's `Gfx` implementation. |
| `MTLVertexManager.mm` / `.h` | +129/-0 | New file: GPU-compute vertex decode (direct float3 position path), flag-gated by `GFX_USE_COMPUTE_VERTEX_DECODE`. | Carry as-is; keep the feature flag OFF by default posture upstream-facing. |
| `MTLStateTracker.mm` / `.h` | +160/-5 | State-tracking support for the compute paths and bounding-box changes. | Re-port onto upstream API. |
| `MTLBoundingBox.mm` / `.h` | +31/-3 | Bounding-box metal-specific changes (paired with the cross-backend `BoundingBox.*` sync-mode work below). | Re-port onto upstream API. |
| `MTLUtil.mm` / `.h`, `MTLTexture.h`, `MTLMain.mm` | +40/-6 | Small texture-format/utility adjustments feeding the compute paths. | Take upstream then re-apply. |
| `VideoBackends/Metal/CMakeLists.txt` | +8/-0 | Adds `MTLVertexManager.*` to the build. | Take upstream then re-apply. |

Owner test: a title using EFB/XFB copies (e.g. NSMBW) renders correctly
with `GFX_USE_COMPUTE_EFBXFB`/`GFX_USE_COMPUTE_VERTEX_DECODE` both on and
off; no visual corruption switching between them mid-session.

## VideoCommon

Mix of ARM64/NEON perf paths (some predate 2509), a new adaptive
internal-resolution controller, and new stall/perf instrumentation.

| File | Lines +/- | Purpose | Merge guidance |
|---|---|---|---|
| `TextureDecoder_arm64.cpp` | +812/-0 | New file: NEON-accelerated texture decoders, part of "recover GPU perf moat on the 2509 base". | Carry as-is; re-verify against any upstream texture-format additions. |
| `VertexLoaderNEON.cpp` / `.h` | +502/-0 | New file: NEON SIMD vertex loader (predates 2509, reapplied via "rebaseline cluster 6"). | Carry as-is. |
| `VertexLoaderBase.cpp` / `.h` | +69/-1 | Chooses JIT vs. NEON vs. compute vertex loader based on `System::IsJitAvailable()`/config instead of raw availability checks; wires the GPU-compute decode hook. | Re-port onto upstream API — this is the loader-selection seam, touched by every one of these features. |
| `VertexLoaderManager.cpp` | +37/-1 | Adds the GPU-compute vertex-decode hook + gates it on the `GFX_USE_COMPUTE_VERTEX_DECODE` flag. | Take upstream then re-apply. |
| `VertexLoaderARM64.cpp` | +1/-1 | Carries the JIT-writable-region change from Common/MemoryUtil. | Take upstream then re-apply (trivial). |
| `VertexManagerBase.h` | +16/-0 | Declares the compute vertex-decode hook surface. | Take upstream then re-apply. |
| `AutoIRController.cpp` / `.h` | +346/-0 | New file: adaptive internal-resolution controller — "v2: VPS-at-native, GPU-bound only, owns probe"; decoupled from the CPU/GPU-bound classifier. | Carry as-is (new file); re-check `PerformanceMetrics` fields it reads. |
| `PerformanceMetrics.cpp` / `.h` | +212/-2 | Adaptive-controller sensor layer (dup-present/underrun/dt/GPU-bound detection), stall/wasted-time instrumentation, forces VISkip off while adaptive clock runs, DEBUG-only on-device A/B perf test bench. | Re-port onto upstream API; upstream also extends this file periodically for its own metrics. |
| `StallMetrics.cpp` / `.h` | +481/-0 | New file: stall/wasted-time instrumentation with `os_signposts` and a "STALL REPORT" dump, `MAIN_STALL_METRICS` gated. | Carry as-is (new file, debug/diagnostic only). |
| `TextureCacheBase.cpp`, `FramebufferManager.cpp` | +142/-0 | Hooks for the compute EFB/XFB acceleration layer (native-Metal moat). | Re-port onto upstream API. |
| `Fifo.cpp` | +24/-2 | Fixes a lost-wakeup wedge in the dual-core CPU/GPU thread handoff (bounded wait + QoS-inversion fix), plus stall instrumentation. | Re-port onto upstream API — touches upstream's CP/fifo synchronization directly; test dual-core mode specifically. |
| `Fifo.cpp` / `.h` (2026-09-16) | +40/-4 | Video-thread idle backoff in `RunGpuLoop`: after 16 idle payload iterations the thread naps 100 µs per poll instead of hot-spinning until the CPU thread's 1 kHz `GpuMaySleep`; the end-of-drain `Flush()`/`RefreshPeekCache()` run once per drain, not per spin. Cut video-thread samples 74 % (8779 → 2272 / 20 s, NSMBW) — the spin was a third of a P-core, i.e. heat. | Re-port onto upstream API; keep `did_work` semantics if upstream restructures the payload loop. Measure with Time Profiler: `SetCPStatusFromGPU`/`RunGpuLoop` self-time near zero when idle. |
| `AbstractGfx.h` | +52/-0 | Declares the compute EFB/XFB acceleration entry points used by the Metal backend. | Take upstream then re-apply. |
| `BoundingBox.cpp` / `.h` | +6/-3 | Cross-backend bounding-box sync-mode changes (`GFX_BBOX_SYNC_MODE`). | Take upstream then re-apply. |
| `VideoConfig.cpp` / `.h` | +19/-4 | Registers/exposes the new GFX config knobs (compute vertex decode, MSAA/SSAA/bbox-sync/Metal knobs surfaced to SwiftUI). | Take upstream then re-apply. |
| `Statistics.cpp`, `OnScreenDisplay.cpp` / `.h` | +19/-2 | Anchors Dolphin's ImGui HUD/OSD overlays below iCube's floating toolbar. | Take upstream then re-apply. |
| `AsyncRequests.h` | +6/-0 | Stall instrumentation hook. | Take upstream then re-apply. |
| `VideoCommon/CMakeLists.txt` | +7/-1 | Adds `StallMetrics.*`/`AutoIRController.*`/`TextureDecoder_arm64.cpp` etc. to the build. | Take upstream then re-apply. |
| `VideoBackends/{D3D,D3D12,Null,OGL,Software,Vulkan}/*BoundingBox.*` | 1-2 lines each | Mechanical signature follow-through from the `BoundingBox.*` sync-mode change above; these backends don't ship on iOS/tvOS but must still compile. | Take upstream then re-apply (mechanical). |
| `VideoBackends/Vulkan/VKSwapChain.cpp`, `VulkanContext.cpp`, `VulkanLoader.cpp` | +37/-2 | Pre-existing MoltenVK-on-iOS plumbing (saturation fix, dylib path, context init) — not part of the 2026 perf work. | Take upstream then re-apply. |

Owner test: Auto-IR (`GFX_AUTO_IR_ENABLE`) raises/lowers internal
resolution live during a demanding scene without stutter; dual-core mode
runs a full boot-to-menu cycle with no fifo hang; STALL REPORT
(`MAIN_STALL_METRICS`) produces sane numbers, not crashes, when enabled.

## Core/Config

`MainSettings.h`/`.cpp` and `GraphicsSettings.h`/`.cpp` are the fork's
central feature-flag registry — nearly every subsystem above adds a key
here. See "Config keys added by the fork" below for the full list.
`iOSSettings.*` predates 2509 (touch IR mode, save-state slot, pad opacity,
audio-session control) and is unaffected by the 2509 rebase.

| File | Lines +/- | Purpose | Merge guidance |
|---|---|---|---|
| `Core/Config/MainSettings.cpp` / `.h` | +534/-0 | Declares/defines every `MAIN_CIR_*`, `MAIN_STALL_METRICS`, `MAIN_FP_FAST`, `MAIN_AUDIO_USE_COMPUTE_MIXER`, idle-detection, and audio-stretch/compute-mixer keys. | Re-port onto upstream API — mechanical (each key is a `Config::Info<T>` declaration) but must be redone key-by-key against whatever `MainSettings` looks like upstream. |
| `Core/Config/GraphicsSettings.cpp` / `.h` | +103/-2 | Declares/defines Auto-IR, bbox-sync, fast-math, NEON-texture-decode, VI-skip/decimate, compute-EFB/XFB and compute-vertex-decode keys. | Re-port onto upstream API, same as above. |
| `Core/Config/iOSSettings.cpp` / `.h` | +32/-0 | Pre-existing iOS-only settings (touch IR mode/opacity, save-state slot, audio-session control). | Carry as-is (iOS-only file, no upstream equivalent). |

Owner test: Settings UI round-trips every new key (toggle in SwiftUI,
confirm the C++ `Config::Get` reads back the new value); a saved config
file from before this fork's key additions still loads without crashing
(unknown/missing keys fall back to defaults).

## AudioCommon

New AVAudioEngine-based audio backend plus the pre-existing CoreAudio
backend; recent commits fix real fork bugs (silent output, RT-callback FX
round-trip).

| File | Lines +/- | Purpose | Merge guidance |
|---|---|---|---|
| `AVAudioEngineSoundStream.h` / `.mm` | +547/-0 | New file: AVAudioEngine-backed `SoundStream` implementation (current default iOS output path); fixed for a "producing no sound" regression and an unnecessary CoreAudio FX round-trip in the RT callback. | Carry as-is (new file); re-verify against upstream `SoundStream` interface. |
| `CoreAudioSoundStream.cpp` / `.h` | +356/-0 | Pre-existing (2022) CoreAudio backend, ported from the legacy codebase; kept as a fallback/alternate backend. | Carry as-is. |
| `AudioCommon.cpp` / `.h` | +37/-0 | Registers both iOS backends in the backend list, guarded so Cubeb isn't required. | Take upstream then re-apply. |
| `Mixer.cpp` / `.h` | +20/-3 | Adds the compute-mixer path and stall-instrumentation hooks feeding the adaptive-controller sensor layer. | Take upstream then re-apply. |
| `AudioCommon/CMakeLists.txt` | +19/-0 | Builds the two new backend files, links AudioToolbox/CoreAudio frameworks. | Take upstream then re-apply. |

Owner test: audio plays cleanly through a full play session with no
crackle/underrun on both AVAudioEngine (default) and CoreAudio (fallback,
`Defaults`-gated) backends; game audio survives a pause/resume cycle.

## Common

| File | Lines +/- | Purpose | Merge guidance |
|---|---|---|---|
| `MemoryUtil_iOS_LuckTXM.cpp` | +404/-0 | New file: the primary iOS 26+ JIT-memory allocator using the "Luck" TXM (Trusted Execution Monitor) dance to get W^X-compliant executable pages without an entitlement; the fork's highest-stakes low-level file (multiple revert/re-revert cycles in its history). | Carry as-is (new file, iOS-version-specific kernel/TXM behavior — nothing to merge against upstream, which has no iOS JIT story). |
| `MemoryUtil_iOS.cpp`, `MemoryUtil_iOS_Legacy.cpp`, `MemoryUtil_iOS_LuckNoTXM.cpp` | +245/-0 | Dispatcher + two alternate allocator strategies (legacy jailbreak-style, and "Luck" without TXM) selected by JIT-availability probing at runtime. | Carry as-is (new files). |
| `MemoryUtil.cpp` / `.h` | +134/-11 | Cross-platform `AllocateExecutableMemory`/`FreeExecutableMemory` API changes: added a `JITType` enum, a size parameter to `FreeExecutableMemory`, `ScopedJITPageWriteAndNoExecute` with a region parameter (separate writable-vs-executable mapping), plus iOS panic-alert diagnostics. | Re-port onto upstream API — this header's signature changes ripple into every JIT backend file (Arm64Emitter, x64Emitter, JitArm64*, CodeBlock, VertexLoaderARM64); grep the whole tree for `ScopedJITPageWriteAndNoExecute`/`FreeExecutableMemory` call sites after taking upstream. |
| `CodeBlock.h` | +16/-0 | `GetRegionPtr()` — pointer to the writable-region mapping, threaded through every JIT emitter. | Re-port onto upstream API (see above). |
| `Arm64Emitter.cpp` / `.h`, `x64Emitter.h` | +12/-4 | Emitters write through the writable-region pointer instead of the executable mapping directly. | Re-port onto upstream API — small, mechanical, but must follow the `MemoryUtil` signature. |
| `JITMemoryTracker.cpp` / `.h` | +130/-0 | Tracks JIT region write-protection state so `mprotect`/`pthread_jit_write_protect_np` toggles don't race; was removed and reverted-back-in during the 2025-09/10 window. | Carry as-is; it's iOS-specific bookkeeping with no upstream equivalent. |
| `ArmCPUDetect.cpp` | +52/-0 | iOS CRC32/feature detection via device model instead of `getauxval`/HWCAP (unavailable in the iOS sandbox). | Carry as-is; re-check against new Apple Silicon model identifiers each cycle. |
| `HttpRequest.cpp` | +190/-0 | Restores/implements a CFNetwork-based (`CFReadStreamCreateForHTTPRequest`) HTTP fallback path for iOS/tvOS, used by `HttpBlobReader` and cover-art fetch when libcurl's networking is unavailable. | Carry as-is; re-verify against libcurl API if upstream changes `HttpRequest`'s public interface. |
| `Visibility.h` (2026-09-16) | +15/-0 | New: `DOLPHIN_HIDDEN` (`visibility("hidden")`). Under full LTO the exported cached-interpreter template handlers stayed interposable, so every call to them went through a dyld stub (~5 % of the CPU thread). Applied to `class CachedInterpreter` and `class CachedInterpreterIR` — nothing outside the dylib references them. | Carry as-is; re-apply the attribute if upstream renames the classes. Verify with `otool -Iv libdolphin.dylib \| grep LoadStorePIC` → no stub entries. |
| `Thread.cpp` / `.h` | +50/-8 | Apple-Silicon P-core/E-core QoS tagging for the emulation thread, plus a lost-wakeup fix (bounded wait) matching the `Fifo.cpp` dual-core fix. | Re-port onto upstream API; test on both P-core-heavy and E-core-throttled conditions (thermal). |
| `StallSignpost.h` | +108/-0 | New file: `os_signpost` wrapper macros used by StallMetrics/CoreTiming instrumentation. | Carry as-is. |
| `FilesystemWatcher.cpp` / `.h` | +8/-0 | Dummies out filesystem-watch functionality on iOS (no equivalent API). | Carry as-is. |
| `FileUtil.cpp` | +5/-1 | Minor iOS path handling. | Take upstream then re-apply. |
| `WindowSystemInfo.h` | +1/-0 | iOS `WindowSystemType` enum entry (predates 2509). | Take upstream then re-apply. |
| `GL/GLContext.cpp` | +1/-1 | Don't use `GLContextAGL` on iOS. | Take upstream then re-apply. |
| `Common/CMakeLists.txt` | +22/-2 | Adds the iOS `MemoryUtil_iOS*`/`JITMemoryTracker` sources, `Logging/ConsoleListenerNix.cpp` for the `IOS` platform branch, links `CFNetwork` (for `HttpRequest.cpp`'s fallback) and `lwmem`. | Take upstream then re-apply. |

Owner test: cold-launch a JIT-eligible title on a fresh install (exercises
the TXM allocator path from scratch), then force-quit/relaunch repeatedly
(exercises allocator + JITMemoryTracker teardown/re-init) with no crash;
Console.app shows no TXM/mprotect panic alerts.

## Core/HW

| File | Lines +/- | Purpose | Merge guidance |
|---|---|---|---|
| `Core/HW/VideoInterface.cpp` / `.h` | +159/-0 | Adds the "VI skip" fast-forward/adaptive-clock hooks (`GFX_HACK_VI_SKIP_MODE`, `GFX_HACK_VI_DECIMATE_INTERLACE`) and stall instrumentation; bounded Auto-VISkip gating. | Re-port onto upstream API — touches VI timing directly, test carefully for AV-sync regressions. |
| `Core/HW/Memmap.cpp` | +14/-16 | `madvise` paging hints for unified memory on iOS/Apple Silicon (net removal of an earlier `UpdateLogicalMemory` merge optimization that was reverted for a bug). | Take upstream then re-apply; note the prior revert before reapplying anything here. |
| `Core/HW/DVD/DVDThread.cpp` | +2/-0 | Names the DVD read thread for profiling (Instruments/os_signpost visibility). | Take upstream then re-apply (trivial). |
| `Core/HW/WiimoteEmu/WiimoteEmu.h`, `WiimoteReal/WiimoteReal.cpp` | 1-3 lines each | Mechanical follow-through, no iCube-specific logic beyond upstream merges. | Take upstream (essentially untouched). |

Owner test: VI-skip and adaptive-clock combination doesn't desync audio
from video over a 5+ minute play session; DVD-heavy title (frequent disc
reads) shows no stutter tied to `madvise` paging changes.

## Core (Core.cpp, CoreTiming, State, System)

| File | Lines +/- | Purpose | Merge guidance |
|---|---|---|---|
| `Core/Core.cpp` | +14/-0 | Wires the adaptive-controller sensor layer and stall instrumentation into the main run loop. | Take upstream then re-apply. |
| `Core/CoreTiming.cpp` | +39/-5 | Stall instrumentation, forces VISkip off while the adaptive clock is active, bounded Auto-VISkip gating hooks. Does **not** touch the pre-existing upstream overclock logic (`GetOverclock`/`MAIN_OVERCLOCK*`) — that code is unmodified upstream behavior, not a fork addition. | Take upstream then re-apply. |
| `Core/State.cpp` / `.h` | +8/-1 | Auto-VISkip gating hook plus the pre-existing "get current version" accessor. | Take upstream then re-apply. |
| `Core/System.cpp` / `.h` | +7/-5 | Pre-existing `IsJitAvailable()` flag consumed by `VertexLoaderBase`'s loader-selection logic. | Take upstream then re-apply. |
| `Core/CMakeLists.txt` | +4/-0 | Adds `PPCAnalyst`/CIR-related sources to the build. | Take upstream then re-apply. |
| `Core/MachineContext.h`, `Core/MemTools.cpp` | +20/-0 | tvOS API guards (3 guards) so the core compiles for tvOS as well as iOS. | Take upstream then re-apply. |

Owner test: save-state round-trip (save, quit app, relaunch, load) works
across a CPUCore-6 (CIR) session; overclock slider still behaves correctly
(sanity check only — not fork-owned logic).

## UICommon / other

| File | Lines +/- | Purpose | Merge guidance |
|---|---|---|---|
| `UICommon/GameFile.cpp` | +4/-0 | `art.gametdb.com` http→https for cover-art fetch. | Take upstream then re-apply (trivial). |
| `UICommon/UICommon.cpp` | +2/-2 | Don't create a macOS power assertion on iOS. | Take upstream then re-apply (trivial). |

Owner test: game-library cover art loads over HTTPS; no power-assertion
crash/log-spam on iOS launch.

## CMake & Externals

| File | Lines +/- | Purpose | Merge guidance |
|---|---|---|---|
| `Externals/ios-cmake/ios.toolchain.cmake` (+ LICENSE/README) | +978/-0 | Vendored `leetal/ios-cmake` toolchain file (checked in directly rather than as a submodule) for iOS/tvOS cross-compilation; fast-math disabled; CMake 4.x deprecation-warning spam silenced. | Carry as-is; periodically re-pull the upstream `ios-cmake` project for toolchain fixes rather than hand-patching. |
| `Externals/MoltenVK-iOS/*` (LICENSE, xcframework + prebuilt dylibs) | +246/-0 (+ binaries) | Prebuilt MoltenVK.xcframework (currently 1.2.8) for the Vulkan-via-Metal backend on iOS; binaries are vendored, not built from source. | Carry as-is; bump the whole xcframework wholesale when updating MoltenVK, don't hand-edit. |
| `Externals/lwmem/*` | +1985/-0 | Vendored, iOS-adapted fork of the `lwmem` allocator (custom `lwmem_sys_apple.c` backend) — used by the JIT memory-allocation subsystem (`MemoryUtil_iOS*`) for pooled allocation. | Carry as-is (self-contained vendored library with a custom Apple system layer). |
| `Externals/fmt/fmt` (submodule pointer) | +1/-1 | Points at the fork's `fmt` submodule, which carries an iOS `FMT_EXCEPTIONS=0` build fix. | Re-verify submodule SHA after taking upstream — the fork's `fmt` fork itself needs to stay in sync with whatever `fmt` version upstream Dolphin pins. |
| `Externals/zlib-ng/*` | +21/-4 (+ submodule bump) | Bumped `zlib-ng` submodule to upstream `develop` and adapted the CMake wrapper to match (`WITH_SANITIZER=OFF` guard for a build issue). | Take upstream then re-apply the CMake wrapper diff; re-check whether the sanitizer guard is still needed against the new zlib-ng version. |
| `CMakeLists.txt` (top-level) | +46/-10 | The full set of "disable desktop feature X on iOS" switches (no OpenGL/SDL/hidapi/libusb/dolphin-tool/MoltenVK-from-source on iOS; static libpng; FMT_EXCEPTIONS=0; CoreFoundation/Foundation frameworks; shared-zstd-off) plus `Externals: Add modified lwmem`. | Take upstream then re-apply — mostly independent `if(IOS)`/`if(APPLE)` branches, low risk of merge conflicts but must re-verify each guard still applies to whatever the new CMakeLists structure looks like. |

Owner test: a from-scratch `cmake` configure + Xcode build succeeds for
both iOS device and simulator, and tvOS device and simulator, with no
MoltenVK/lwmem/zlib-ng linker errors.

## Fork-only trees

`Source/iOS/**` (the SwiftUI app shell, settings UI, debug HTTP server, and
all Swift-side glue), `Data/Sys/GameSettings` (per-game `.ini` overrides
curated for iCube), `build/` (checked-in prebuilt `PVlibDolphin` xcframework
artifacts consumed by the parent Provenance workspace), and `Tools/mcp`
(the on-device debug MCP server) are entirely fork-authored additions with
no upstream counterpart — they are out of scope for merge conflicts and
are not inventoried here.

## Config keys added by the fork

**MainSettings.h** (`MAIN_*`, relative to `Config::Get()` keys present at 2509):
`MAIN_AUDIO_USE_COMPUTE_MIXER`, `MAIN_CACHED_INTERPRETER_PREFETCH`,
`MAIN_CIR_BLOCK_LINKING(_VALIDATE)`, `MAIN_CIR_CACHE_LOOP_FF(_VALIDATE)`,
`MAIN_CIR_DEAD_FLAG_ELIM(_VALIDATE)`, `MAIN_CIR_DEAD_FPRF_ELIM(_VALIDATE)`,
`MAIN_CIR_IR_CONST_FUSION(_VALIDATE)`, `MAIN_CIR_IR_DEAD_FLAG_ELIM(_VALIDATE)`,
`MAIN_CIR_IR_MICROOP_FUSION(_VALIDATE)`, `MAIN_CIR_IR_PIC_LOADSTORE_VALIDATE`,
`MAIN_CIR_IR_SPECIALIZED_OPS_VALIDATE`, `MAIN_CIR_MICROOP_FUSION(_VALIDATE)`,
`MAIN_CIR_PIC_LOADSTORE`, `MAIN_CIR_PROFILE`, `MAIN_CIR_PSQ_FASTPATH(_VALIDATE)`,
`MAIN_CIR_PS_NEON(_VALIDATE)`, `MAIN_CIR_SKIP_PERF_MONITOR`,
`MAIN_CIR_SPECIALIZED_FP_ARITH(_VALIDATE)`, `MAIN_CIR_SPECIALIZED_FP_LS`,
`MAIN_CIR_SPECIALIZED_OPS(_VALIDATE)`, `MAIN_CIR_SPECIALIZED_PSQ`,
`MAIN_CIR_STORE_LOOP_FF(_VALIDATE)`, `MAIN_CIR_TAIL_LINK`,
`MAIN_CIR_TAPE_PREFETCH_DIST`, `MAIN_CIR_TAPE_THRASH_STRIDE`,
`MAIN_FAST_FORWARD_CTR_IDLE`, `MAIN_FP_FAST`, `MAIN_RELAXED_IDLE_DETECTION`,
`MAIN_STALL_METRICS`.

**GraphicsSettings.h** (`GFX_*`): `GFX_ASYNC_PRESENT`,
`GFX_AUTO_IR_COOLDOWN_FRAMES`, `GFX_AUTO_IR_ENABLE`,
`GFX_AUTO_IR_HYSTERESIS_PERCENT`, `GFX_AUTO_IR_MAX_SCALE`,
`GFX_AUTO_IR_MIN_SCALE`, `GFX_AUTO_IR_SHOW_OSD`, `GFX_AUTO_IR_TARGET_FPS`,
`GFX_BBOX_SYNC_MODE`, `GFX_HACK_FAST_MATH`, `GFX_HACK_GPU_EFB_PEEK_RESOLVE`,
`GFX_HACK_NEON_TEXTURE_DECODE`, `GFX_HACK_VI_DECIMATE_INTERLACE`,
`GFX_HACK_VI_SKIP_MODE`, `GFX_USE_COMPUTE_EFBXFB`,
`GFX_USE_COMPUTE_VERTEX_DECODE`.
