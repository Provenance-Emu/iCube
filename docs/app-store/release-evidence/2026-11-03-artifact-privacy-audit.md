# App Store artifact and privacy audit (iCube#57, R6)

Date: 2026-11-03. Base: `origin/develop` 49b114f18c. Scope: the two source-checkable bullets of iCube#57 (R6):
(a) re-audit the final APPSTORE artifacts for developer HTTP APIs, firmware download paths, JIT capability behaviour, entitlements, extension signing and bundled resources;
(b) privacy manifests, required-reason APIs, Sentry opt-out and payload, credential exclusion from sync, privacy-label answers, policy/support links, Web UI/WebDAV exposure.

Method: current source and build configuration only. No build was run and no signed artifact was inspected. Every finding is tagged:

- **PROVEN** - established from the cited source or configuration lines.
- **ARTIFACT** - cannot be settled from source; needs the exported, signed `Release (AppStore)` IPA or an Organizer Privacy Report (list in section 6).

Package versions below come from a local SwiftPM checkout of the dependency graph (`DerivedData/iCube-*/SourcePackages`, resolved versions named per package). CI resolves fresh (`Package.resolved` is gitignored), so re-check them on the release build.

Reading order: section 5 (findings, ranked) is the summary; sections 1-4 are the evidence; section 6 is what is left for the signed artifact.

## 1. Per-configuration matrix

### 1.1 How the flags reach the code

| Fact | Evidence |
|---|---|
| `Release (AppStore)` and `Debug (AppStore)` both include `AppStore.xcconfig`, which defines `APPSTORE=1` (C/ObjC) and the Swift condition `APPSTORE`, plus `DOL_BUILD_SOURCE = official`. | `Source/iOS/App/Project/Config/AppStore.xcconfig:4-6`; `Presets/Release (AppStore).xcconfig:8`; `Presets/Debug (AppStore).xcconfig:8` |
| `Debug (AppStore)` also defines `DEBUG` (it includes `Debug.xcconfig` before `AppStore.xcconfig`), so it is APPSTORE **and** DEBUG. Where the code tests `#if APPSTORE` before `#if DEBUG` the store behaviour wins. | `Presets/Debug (AppStore).xcconfig:7-8`; `Debug.xcconfig` (`DEBUG=1`) |
| `AppStore.xcconfig` is included after `Debug.xcconfig`, so `Debug (AppStore)` ends with `DOL_BUILD_SOURCE = official` and runs the launch-time update check below even though it is a debug build. | `Presets/Debug (AppStore).xcconfig:7-8`, `Project/Config/Debug.xcconfig:7` |
| `NONJAILBROKEN` is defined only by the Non-Jailbroken presets; the AppStore presets do not define it. | `Project/Config/NonJailbroken.xcconfig`; `PreprocessorCombine.xcconfig:8,13` |
| The emulator core (`PVlibDolphin.xcframework`) is built once by CMake and shared by every configuration. It sees none of these flags (`grep APPSTORE Source/Core` finds nothing), so code that is compiled into the core is in every IPA and only the app layer can hide it. | `Source/iOS/App/Project.swift:164-180` (single Build Dolphin Core phase), `BuildiOSXCFramework.py` (no APPSTORE define) |
| Dolphin's own analytics uploader (`analytics.dolphin-emu.org`) is compiled out of the core. | `BuildiOSXCFramework.py:609` (`-DENABLE_ANALYTICS=NO`); `Source/Core/Core/DolphinAnalytics.cpp:50` is the endpoint it would use |
| One `iCube` target builds every configuration; sources are directory globs, so a file is compiled into every IPA unless it carries its own `#if`. | `Project.swift:266-300` (`sources:` globs), `Project.swift:344-345` |

### 1.2 Matrix

"Compiled" means the code is in the binary. "Reachable" means a user (or a LAN peer) can get it to run. Columns: **Store** = `Release (AppStore)`; **Dbg-Store** = `Debug (AppStore)`; **Dbg-NJB** = `Debug (Non-Jailbroken)`; **Other Rel** = the Release Non-Jailbroken / Beta / Jailbroken / TrollStore sideload configurations.

| Feature | Store | Dbg-Store | Dbg-NJB | Other Rel | Evidence |
|---|---|---|---|---|---|
| Debug/bench HTTP server (`NativeWebServer`, port 8723, `/api/...` routes, WebSocket events) | Compiled (about 130 KB of Swift, `Common/Swift/Debug/*`). **Not reachable**: `isEnabled` returns `false` under `APPSTORE`. | Compiled, not reachable (APPSTORE branch precedes DEBUG) | Compiled, always on, loopback only | Compiled, off until Settings > Debug > Perf Test Bench is switched on; then binds all interfaces, LAN requests need a bearer token | `Common/Swift/Debug/DebugServerManager.swift:144-153` (`#if APPSTORE return false #elseif DEBUG return true #else defaults`), `:103-109` (`isExplicitOptIn`), `:156` (`guard isEnabled`); starters `Common/MainDisplaySceneDelegate.swift:20`, `Common/Emulation/EmulationCoordinator.mm:2031` |
| Toggle and token rows for that server in Settings | Not shown. A store build gets only the environment section (`.jitOnly` or `.environmentOnly`); `perf-bench` and `bench-token` are in the diagnostics section, which only `.full` builds. | Same as Store | Shown | Shown | `Common/UI/Settings/SwiftUI/SettingsRootModelBuilder.swift:152-156` (`storeDebugLeaf`), `Leaves/DebugRootModelBuilder.swift:17-24`, `:128-135` |
| Web UI + WebDAV upload server (`PVWebServer`, `ROMUploadServer`) | **Compiled and running.** Starts on first foreground, port 80 then fallbacks, Bonjour `_http._tcp`/`_webdav._tcp`. No authentication. Serves `Documents/Software` (tvOS: `Caches/Software`). | Same | Same | Same | `Common/Services/WebServerLifecycleService.swift:125` (`.start`), `ServiceManager.swift:17,35`; policy `PVWebServer/Sources/PVWebServer/WebServerLifecyclePolicy.swift:103-110` (1.0.0); root `PVWebServer.swift:129-136`; no auth anywhere in `ROMUploadServer.swift` (only per-route bearer tokens in `WebRoute.swift` for registered routes) |
| Continuity routes mounted on that same server | Compiled, mounted | Same | Same | Same | `Common/Continuity/ContinuityService.swift:22` (`registerRoutes(on: PVWebServer.shared)`) |
| Wii online system update (NUS download UI) | UI **not compiled** (`#if !APPSTORE`) and the bridge methods are empty bodies, so a deep link cannot reach them. The downloader inside the core (`WiiUtils::DoOnlineUpdate`, `WiiUtils.cpp:463` NUS URL) **is compiled** but has no caller in the store app layer. | Same as Store | Compiled, reachable (library menu, tvOS menu) | Same as Dbg-NJB | `Common/UI/WiiSystemUpdate/WiiSystemUpdateViewController.mm:5-6,151`, `TVWiiSystemUpdateViewController.mm:5,211`, `Common/UI/SoftwareList/TVLibraryBridge.mm:183-228`, `Common/Swift/TVLibraryView.swift:179,566,1939,2335` |
| User-supplied NAND import (`keys.bin`/`nand.bin` through the Web UI) | Compiled, reachable (user's own files) | Same | Same | Same | `DolphiniOS/UI/Import/NANDImportManager.mm`, `Common/Services/UploadKind.swift` |
| JIT: code paths (`JitManager`, TXM handshake, ptrace/csops probes, StikDebug hand-off, JIT recompiler in the core) | **Compiled.** Whether JIT is used depends only on a runtime check for `get-task-allow`, so a store install is jitless. | Compiled, `get-task-allow` present from development signing, so JIT can be offered | Compiled and live | Compiled and live | `Common/Jit/JitManager.m:46-60` (`jitSupported = checkIfProcessIsJitCapable`), `:76-81` (hard stop when not supported), `Common/Services/JitAcquisitionService.swift:12-22`, `Common/Swift/EmulationScreen.swift:104-106` |
| JIT UI on a store install | Hidden unless runtime detection says JIT works (re-signed install): boot prompt, Debug leaf JIT rows, Help JIT guide | Shown when `jitSupported` | Shown | Shown | `EmulationScreen.swift:104`, `DebugRootModelBuilder.swift:18-25`, `Common/Swift/Help/WikiHelpViewModel.swift:15-33`, `PerformanceTuningModelBuilder.swift:56-80` |
| `acquireJitByAltServer()` | **Called** (the `NONJAILBROKEN || APPSTORE` branch), but returns at once because `ALTDeviceID` is the literal `NotSet`. `AltKit` is linked and `_altserver._tcp` is in `NSBonjourServices`. | Same | Called, same no-op | Called on NJB only | `JitAcquisitionService.swift:19-21`, `Common/Jit/JitManager+AltServer.m:11-20`, `DolphiniOS/Info.plist` (`ALTDeviceID`, `NSBonjourServices`) |
| `ptrace` start-up probe | Not run: needs `jitSupported` and the private `platform-application` entitlement | Not run | Not run | JB/TS only | `JitAcquisitionService.swift:15-17`, `Common/Jit/JitManager+PTrace.m:22-43` (private SecTask symbols resolved with `dlsym`) |
| `icube.js` StikDebug script in the bundle; URL schemes `stikdebug`/`stikjit` queried | **Bundled and declared in every configuration**, used only if StikDebug is installed and `jitSupported` | Same | Same | Same | `Project.swift:339` (resource), `DolphiniOS/Info.plist` (`LSApplicationQueriesSchemes`), `Common/Jit/StikDebugLauncher.swift:20-30` |
| Live Activity extension | **Not embedded** (`APP_EMBEDS_APPEX = false`). The app still contains ActivityKit calls and `NSSupportsLiveActivities = YES`. | Same | Same | Same | `Project.swift:13,404`, `Project.swift:426`, `Common/Swift/EmulationScreen.swift:741-836` |
| Top Shelf extension | tvOS only (embedded via `.when([.tvos])`) | Same | Same | Same | `Project.swift:405` |
| Thumbnail + Quick Look Preview extensions | iOS/Catalyst only | Same | Same | Same | `Project.swift:406-407`, `:541-565` |
| Home-screen widget (`RecentGamesWidget`) | **Not shipped.** The sources live inside the un-embedded Live Activity target. `WidgetCenter.reloadTimelines` is still called (no-op). | Same | Same | Same | `Project.swift:264-271`, `Project.swift:398-399` |
| Sentry SDK | Compiled, **on by default**, user opt-out; App Store scrubbing active | Compiled; APPSTORE scrubbing active; environment tag `development` | Compiled; no scrubbing; `game_id` sent | Compiled; no scrubbing; `game_id` sent | `Common/Services/SentryTelemetryService.swift:140-253`; section 4 |
| Launch-time update check (`https://icube-emu.com/api/v2/update.json`) | **Runs every launch** (`DOL_BUILD_SOURCE = official`) | Runs (see 1.1) | Skipped (`development`) | Skipped (`unofficial`) | `Common/Services/UpdateCheckService.swift:28-37`; `AppStore.xcconfig:6` |
| Dolphin analytics | Compiled out | Compiled out | Compiled out | Compiled out | `BuildiOSXCFramework.py:609` |
| RetroAchievements client | Compiled (`USE_RETRO_ACHIEVEMENTS=1`), off by default | Same | Same | Same | `AppStore.xcconfig:4`, `NonJailbroken.xcconfig:4` |
| iCloud / CloudKit sync | Compiled; opt-in, default off | Same | Same | Same | `CloudSyncCoordinator.swift:101-103` ("Opt-in, default off"), `ICubeCloudSync.swift:6` |

### 1.3 Notes on the matrix

1. **Debug server.** The store build cannot start it, so the "debug HTTP API" requirement holds at run time. It is still in the binary: route strings (`/api/debug/boot`, `/api/settings`, `/ws/events`, ...) and the handler code ship in the IPA. A reviewer running `strings` will see them. See finding F9. `NativeWebServer.swift:12-14` and `review-notes.md` ("disabled in this build and cannot be turned on") are both accurate for run time.
2. **Stale comment.** `Common/Emulation/EmulationCoordinator.mm:2022-2029` still says the server is "loopback-only" and "never reachable off-device without an explicit USB iproxy forward". In non-store release builds it is LAN-reachable (token protected). Comment only.
3. **JIT.** The project rule (keep JIT code, expose it only on detection) is implemented. Store entitlements carry no `cs.allow-jit`, no `cs.allow-unsigned-executable-memory`, no `cs.disable-*`, no `get-task-allow` (section 2). `review-notes.md` says "requests no JIT or dynamic-code-signing entitlement" and "generates no executable code at runtime": both true for an unmodified install. It also says "Do not replace it with 'the app contains no JIT code'"; that is correct.
4. **Firmware.** The shipped store UI never offers a download of Nintendo software. The downloader remains in the core binary (every configuration shares one core). Nothing in the app layer calls it under `APPSTORE`. Treat this as "unreachable", not "absent".
5. **Web UI/WebDAV** is the only network listener that is live in the store build. Its exposure is assessed in finding F2.

