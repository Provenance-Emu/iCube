# TestFlight user report triage — 2026-10-19

Source: owner-relayed user report, concerning the last two days of TestFlight builds. Exact build numbers, game/scene and measured frame times are not yet supplied. Related release gates: R1 #52, R2 #53 and R5 #56.

## Resolution and performance

Reported: two iPad Air 4 (A14) devices, iOS 18.5 and 27.0, run dramatically slower with Auto (fit window) than 1× Native.

Confirmed source change: `68a29c370a` (October 17) seeds `GFX_EFB_SCALE = EFB_SCALE_AUTO_INTEGRAL` on iOS when unspecified, and after both graphics-page and global reset. The core default is 1; tvOS was excluded from the new Auto default. Auto computes an integer internal resolution that covers the display; it is not the adaptive FPS-targeting Auto-IR controller. That controller is separately off by default.

The earlier performance note (`docs/perf/2026-10-17-metalfx-spatial.md`) measured two scenes on A12Z and A18 Pro and found no FPS loss at those loads. It does not establish safety on A14, other scenes, long sessions or these TestFlight builds. Its own GPU timings show higher cost at higher resolution. Treat the new report as a credible release regression; its magnitude is not independently reproduced yet.

Local reviewed fix: restore Native for new/unspecified settings and both reset paths. Keep Auto opt-in and preserve explicit existing scale choices. Existing stored Auto cannot be distinguished from a deliberate user selection; do not silently overwrite it. Immediate workaround: Settings → Enhancements → Internal Resolution → 1x (Native). Check for game overrides or adaptive Auto-IR if the row is disabled.

Verification so far: compiled pre-fix resolution-reset test failed with actual 0 versus expected 1. The same run passed 44 other tests, including the read-only environment scope/store-routing tests and the singleton-stepper rendering regression. The fixed app compiled; its first test launch was rejected because CoreSimulator reported installation busy. A direct rerun of the rebuilt bundle passed all 80 targeted tests (settings writeback, shared controls, root routing, debug model, enhancements model), exit0. Native-reset regression now passes. Logs: `settings-green.log` (build/launch issue), `settings-direct-green.log` (green execution). No TestFlight publication is claimed. Logs: `/tmp/icube-tvos-audit-2026-10-19/direct-red.log` and `direct-red-tests.json`.

Acceptance: fresh install and graphics/global reset select Native; explicitly selected Auto/fixed scales survive relaunch; per-game overrides keep working. A14 device comparison must use the same game, scene/save, CPU engine, shader settings, thermal state and build, at 1× and Auto, recording effective scale and FPS/frame times.

## Missing User Folder / Fastmem information

Confirmed source cause: `SettingsRootModelBuilder.storeDebugLeaf` returns nil in APPSTORE builds when `jitSupported` is false. TestFlight archives the AppStore scheme/configuration. Both User Folder and Fastmem availability are inside that hidden Debug leaf. NJB Debug simulator checks do not test this visibility.

The information still exists in `DebugRootModelBuilder.environment`, hydrated by `DebugRootView`; it was not removed from the data model. The initial User Folder row was a disabled status row with a truncated path and no copy action. The follow-up now provides a read-only full-path details destination, Copy on iOS and Done on tvOS; empty paths remain disabled. A visible, readable/copyable support-information surface should be available independently of JIT support, while bench servers and developer controls retain their build restrictions. Local reviewed fix adds `.environmentOnly` for store installs without JIT: fact/status rows and read-only User Folder details, no recovery/setup guide or developer actions. Store installs that support JIT retain the existing limited JIT scope. Populated-state model tests pass, including the state that would otherwise expose recovery actions. Full-path readability and Menu/Done return now pass on the NJB tvOS simulator. Actual APPSTORE screen visibility and iOS clipboard interaction still need runtime checks; see the settings-context follow-up in the audit.

The sandbox path contains an installation UUID; that is not a stable device identity and should not become a cross-install sync identifier.

## Set as Default ISO — [release issue #60](https://github.com/Provenance-Emu/iCube/issues/60)

Confirmed source gap: no current iOS/tvOS app action or bridge for `MAIN_DEFAULT_ISO` was found. The localization keys remain, and Dolphin's core still reads the setting when booting a title. Therefore the presence of the English string is not evidence the feature is reachable.

Primary case: non-Riivolution homebrew/mod launchers need a base-game disc mounted at executable/WAD boot. The owner reports manual DefaultISO configuration works; Boot.cpp confirms SetDefaultDisc on executable, WAD and NAND-title paths.

Track restoring a library-context action plus a visible current selection/clear action. Acceptance must include persistence, Wii System Menu disc-channel behavior, selected-file removal/rename, and paths imported or shared across devices. Do not sync a sandbox-absolute path as a portable game identity. This is a missing app feature; no runtime fix is claimed here.


## Manual disc swapping — [release issue #61](https://github.com/Provenance-Emu/iCube/issues/61)

Core DVDInterface::ChangeDisc exists, including lid/eject/insertion timing, but no current iCube manual action/bridge was found. General exposes Auto Disc Change, which depends on a multi-disc path list; it is not a manual picker. Restore a pause-menu action without rebooting the running game or resuming behind the menu. Verify actual Disc 1→2 continuation, cancellation, invalid files and pending insertion with correct CPU-thread/PauseArbiter discipline.

## Owner decision: remove adaptive resolution

The owner explicitly requested removing the performance-driven controller that changes scale during gameplay, preserving fixed scales and Auto (Fit Window). Native remains the release default. The [removal plan](../../superpowers/plans/2026-10-19-remove-adaptive-resolution.md) includes the independent thermal EFB writer so dynamic scaling is not left active through another route. Other thermal tuning and adaptive CPU/VI clocks remain.

The source removes the AutoIR controller TU/CMake entries, seven config keys, app bridge/UI controls and side effects. Bottleneck classification is unconditional. Old saved enable flags have no source reader to reactivate the feature. Before removal, the installed-app UI red test failed on all five old controls and baseline simulator-core nm confirmed the old bootstrap/class symbols.

Post-removal verification: all four rebuilt packaged iOS/tvOS device/simulator cores pass the artifact check (retired controller/config content absent, normal `GFX_EFB_SCALE` identified). Fresh NJB Debug iOS/tvOS apps build; their embedded and installed simulator frameworks also pass. The iOS fresh-core bundle passes all 97 targeted settings tests. The tvOS UI sweep passes 25 tests (19 page captures plus six behavioral checks), followed by three passing fresh-core tests: Video control absence, CPU-engine persistence/restoration and rail-menu focus/cancellation. Zero failures/skips. [Durable hashes/counts](2026-10-19-resolution-verification.json); full logs/results remain in the session artifact root.

Release (AppStore) build/screens and physical legacy-config/load/thermal gameplay probes remain pending. The A14 slowdown magnitude has not been independently measured. No new TestFlight is published. Existing saved Auto choices are preserved; affected installs can explicitly choose Native or reset graphics settings.
