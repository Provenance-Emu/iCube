# Recent TestFlight performance: source audit — October 20, 2026

Read-only source/history investigation. No gameplay benchmark, physical-device reproduction, production-code change, core rebuild or commit was performed. Findings below establish code behavior and hypotheses, not measured regression magnitude.

## Shipped scope

- Current TestFlight **1.0.0 (1792472425)** is documented against source checkpoint `87b3d34ee1a6a66e72b7cc3648e22df66822fb5b`; see [archive/upload evidence](2026-10-20-release-blocker-fixes.md). The iOS archive began before the checkpoint commit, so embedded revision labels alone are insufficient artifact identity.
- Earlier build numbers `1792335230` and `1791739180`, interpreted as Unix timestamps, correspond to October 18 14:53:50 UTC and October 11 17:19:40 UTC. The latest repository commits before those times are `8bad720220` and `52f2704066`. These are **time-based candidates only**, not established archive/source mappings.
- Library/editor changes from `775757b88c` onward follow the current uploaded checkpoint. The new library metadata/editor/nearby-mirroring wave is documented as unuploaded and cannot explain the current TestFlight's behavior.
- Between candidate October 18 tip `8bad720220` and checkpoint `87b3d34ee1`, there are no implementation changes in `Source/Core/Core/PowerPC`, `MainSettings.cpp`, the Metal backend or `PerformanceMetrics.cpp`. Relevant latest core changes principally concern save APIs and adaptive-resolution removal.

## Ranked hypotheses

### 1. Saved Auto resolution survives the restored Native default

**Proven source:** `68a29c370a` (October 17) seeded Auto (Fit Window) for unspecified iOS internal resolution and both reset paths. `87b3d34ee1` restored Native defaults. However, `SetBaseIfUnspecified` deliberately preserves any stored value, including Auto (`Source/iOS/App/Common/Services/DolphinCoreService.mm:66–76,143–146`). Updating an affected install therefore does not automatically return it to Native. Game overrides can also determine the effective value.

`Source/Core/VideoCommon/Present.cpp:619–643` computes an integer scale sufficient to cover the screen. `FramebufferManager.cpp:213–225` scales both EFB dimensions; pixel area therefore grows quadratically with scale. Auto is window fitting, not FPS-adaptive resolution.

**Evidence limit:** This mechanism matches the relayed A14 iPad Air 4 report, but this audit did not measure the device, scene or slowdown. See [original report and verification](2026-10-19-testflight-user-report.md).

**Discriminating measurement:** On the same affected install, game and save/scene, record effective scale and frame/GPU times at explicit Native and Auto, holding CPU/JIT, shader settings and thermal state constant. A slowdown persisting at the same effective Native scale would require another explanation. Test fresh install/reset separately from upgrade behavior.

### 2. New default enables EFB format conversion

**Proven source:** `42310fad57` (October 17) seeds `GFX_HACK_EFB_EMULATE_FORMAT_CHANGES=true` for unspecified installs (`DolphinCoreService.mm:103–104`), whereas the compiled default was false. `Source/Core/VideoCommon/BPFunctions.cpp:356,381–416` then permits applicable format reinterpretations. `FramebufferManager.cpp:442–460` performs a conversion draw and framebuffer swap on the normal path. This is game-dependent work that can compound with higher EFB resolution.

The same commit seeds Fast texture-cache accuracy (`0` samples), which reduces sampling work and is not a strong explanation for a general slowdown.

**Discriminating measurement:** At fixed Native resolution and matched scene, compare Ignore Format Changes enabled/disabled, checking visual correctness as well as GPU/frame times. No conversion activity or no repeatable timing difference weakens this hypothesis.

### 3. Removal of automatic resolution reductions changes sustained-load behavior

**Proven source:** `87b3d34ee1` removes AutoIR and thermal EFB writes. The previous `ThermalManager.swift` reduced scale at Fair and forced Native at Serious/Critical. Users retaining high manual/Auto scale now retain that scale under load. This matters principally for users who previously enabled thermal auto-tuning or AutoIR; AutoIR was off by default. Removing these behaviors was an explicit owner decision.

CPU/VI adaptation remains, including thermal CPU ceilings (`Source/iOS/App/Common/Emulation/EmulationCoordinator.mm:875–921`).

**Discriminating measurement:** Compare matched sustained sessions while recording thermal state, effective EFB scale, CPU/VI clocks, emulation speed and GPU timing. A cool-device slowdown at unchanged scale does not establish a missing thermal fallback as its cause.

## Secondary candidates and exclusions

- **Cloud scan at boot:** At shipped checkpoint `87b3d34ee1`, `CloudSyncCoordinator.swift:500` awaits `scanner.scanLocalFiles` before checking `canContinueTransfer` at line 502; the scan is not wrapped in `withLocalIO`. A scan already running may overlap boot even though subsequent transfers are guarded and lifecycle events defer work during emulation. This is a possible transient contention path, not demonstrated continuous gameplay overhead. Compare startup Files/CPU traces with sync enabled/disabled and a large versus small user-data inventory.
- **MetalFX:** Its default is false (`Source/Core/Core/Config/GraphicsSettings.cpp:263`), and `Present.cpp:919` exits when disabled. The October 17 instrumentation adds GPU timestamp reads and an atomic add inside an already-existing command-buffer completion callback (`Source/Core/VideoBackends/Metal/MTLStateTracker.mm:440–442`); reporting occurs every 120 presents (`MTLGfx.mm:51–88`). This is a weaker suspect than resolution/default changes. Compare explicit MetalFX off/on at fixed scale; isolate instrumentation only if profiling points there.
- **Input pump:** The 8-ms Host input timer (`EmulationCoordinator.mm:1487–1496`) dates to `58a7763cc2` on June 2 and is unchanged across the recent window. No recent polling-frequency regression was identified.
- **Save/lifecycle:** Current UI save/quit dispatches work to `saveQueue` (`Source/iOS/App/Common/Swift/SaveStateService.swift:48–66`). Save completion can change action latency, but this review found no source basis for attributing continuous gameplay slowdown to that change. Profile an actual save/quit separately from an uninterrupted scene.

## Telemetry blind spot

**Proven source ordering:** `SentryTelemetryService.swift:156–157` returns a zero trace sample rate during active emulation. Boot sets that gate before creating `emulation.boot` (lines 292–309). End-of-session reporting runs before clearing it (lines 340–342), and `EmulationPerfSessionRecorder.swift:82–85` creates `emulation.session` using ordinary `startTransaction`. All three gate/order behaviors date to `460316f107` on June 9, not the recent TestFlights.

The recorder admits 10% of enabled Release sessions and samples every two seconds (`EmulationPerfSessionRecorder.swift:36,49`), but its summary transaction meets the zero-rate sampler. This explains a source-level path to missing FPS/boot summaries; observed Sentry event counts must be checked independently. Its sparse sampling and App Store file/network instrumentation being disabled make telemetry a weak new gameplay-overhead hypothesis.

**Suggested follow-up, not implemented:** Permit only explicitly identified boot/session-summary transactions through the emulation sampler, with intentional sampling and deterministic coverage of lifecycle ordering. Preserve consent and App Store privacy scrubbing. The existing generic trace-helper `force` flag only bypasses the helper's guard; it does not override `tracesSampler`. Validate that one deliberately sampled completed session reaches Sentry before relying on release FPS comparisons. Aggregate FPS across different games/scenes is insufficient to establish a build regression.

## Next evidence to collect

### Owner's physical iPad spot check

Read-only inspection of the owner's iPad Pro (12.9-inch, 4th generation), iPadOS 26.6.2, confirmed installed TestFlight `1.0.0 (1792472425)`. Its `Documents/Config/GFX.ini` has `InternalResolution = 1`, `AutoInternalResolution = False`, and `EFBEmulateFormatChanges = True`. Its two current per-game INI files are empty, so neither supplies a resolution override. No configuration was changed. This device's observed configuration does not support retained Auto as the explanation for its current performance. This does not disprove the separate A14 user report or measure FPS. Local raw settings and screenshots remain under gitignored `build/release-audit/2026-10-20-performance/` and `2026-10-20-pause-exit/`; do not publish device identifiers or personal home-screen content.

1. Establish earlier build-to-archive/source mappings from actual build records.
2. Run the matched A14 Native/Auto comparison first, including upgrade-preserved settings and per-game effective values.
3. At fixed scale, isolate EFB-format behavior and MetalFX; then collect a sustained thermal trace.
4. Profile boot sync contention and save/quit latency only as separate, reproducible cases.
5. Repair and verify summary delivery before using Sentry to quantify emulator performance changes. Device acceptance remains open.
