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
| The emulator core (`PVlibDolphin.xcframework`) is built once by CMake and shared by every configuration. It sees none of these flags (`grep APPSTORE Source/Core` finds nothing), so code that is compiled into the core is in every IPA and only the app layer can hide it. | `Source/iOS/App/Project.swift:198` (single Build Dolphin Core phase), `BuildiOSXCFramework.py` (no APPSTORE define) |
| Dolphin's own analytics uploader (`analytics.dolphin-emu.org`) is compiled out of the core. | `BuildiOSXCFramework.py:609` (`-DENABLE_ANALYTICS=NO`); `Source/Core/Core/DolphinAnalytics.cpp:50` is the endpoint it would use |
| One `iCube` target builds every configuration; sources are directory globs, so a file is compiled into every IPA unless it carries its own `#if`. | `Project.swift:271-306` (`sources:` globs) |

### 1.2 Matrix

"Compiled" means the code is in the binary. "Reachable" means a user (or a LAN peer) can get it to run. Columns: **Store** = `Release (AppStore)`; **Dbg-Store** = `Debug (AppStore)`; **Dbg-NJB** = `Debug (Non-Jailbroken)`; **Other Rel** = the Release Non-Jailbroken / Beta / Jailbroken / TrollStore sideload configurations.

| Feature | Store | Dbg-Store | Dbg-NJB | Other Rel | Evidence |
|---|---|---|---|---|---|
| Debug/bench HTTP server (`NativeWebServer`, port 8723, `/api/...` routes, WebSocket events) | Compiled (about 130 KB of Swift, `Common/Swift/Debug/*`). **Not reachable**: `isEnabled` returns `false` under `APPSTORE`. | Compiled, not reachable (APPSTORE branch precedes DEBUG) | Compiled, always on, loopback only | Compiled, off until Settings > Debug > Perf Test Bench is switched on; then binds all interfaces, LAN requests need a bearer token | `Common/Swift/Debug/DebugServerManager.swift:144-153` (`#if APPSTORE return false #elseif DEBUG return true #else defaults`), `:103-109` (`isExplicitOptIn`), `:156` (`guard isEnabled`); starters `Common/MainDisplaySceneDelegate.swift:20`, `Common/Emulation/EmulationCoordinator.mm:2031` |
| Toggle and token rows for that server in Settings | Not shown. A store build gets only the environment section (`.jitOnly` or `.environmentOnly`); `perf-bench` and `bench-token` are in the diagnostics section, which only `.full` builds. | Same as Store | Shown | Shown | `Common/UI/Settings/SwiftUI/SettingsRootModelBuilder.swift:152-161` (`debugLeaf`, `storeDebugLeaf`), `SettingsRootView.swift:60`, `Leaves/DebugRootModelBuilder.swift:17-24`, `:128-135` |
| Web UI + WebDAV upload server (`PVWebServer`, `ROMUploadServer`) | **Compiled and running.** Starts on first foreground, port 80 then fallbacks, Bonjour `_http._tcp`/`_webdav._tcp`. No authentication. Serves `Documents/Software` (tvOS: `Caches/Software`). | Same | Same | Same | `Common/Services/WebServerLifecycleService.swift:125` (`.start`), `ServiceManager.swift:17,35`; policy `PVWebServer/Sources/PVWebServer/WebServerLifecyclePolicy.swift:103-110` (1.0.0); root `PVWebServer.swift:129-136`; no auth anywhere in `ROMUploadServer.swift` (only per-route bearer tokens in `WebRoute.swift` for registered routes) |
| Continuity routes mounted on that same server | Compiled, mounted | Same | Same | Same | `Common/Continuity/ContinuityService.swift:22` (`registerRoutes(on: PVWebServer.shared)`) |
| Wii online system update (NUS download UI) | UI **not compiled** (`#if !APPSTORE`) and the bridge methods are empty bodies, so a deep link cannot reach them. The downloader inside the core (`WiiUtils::DoOnlineUpdate`, `WiiUtils.cpp:463` NUS URL) **is compiled** but has no caller in the store app layer. | Same as Store | Compiled, reachable (library menu, tvOS menu) | Same as Dbg-NJB | `Common/UI/WiiSystemUpdate/WiiSystemUpdateViewController.mm:5-6,151`, `TVWiiSystemUpdateViewController.mm:5,211`, `Common/UI/SoftwareList/TVLibraryBridge.mm:183-228`, `Common/Swift/TVLibraryView.swift:179,566,1939,2335` |
| User-supplied NAND import (`keys.bin`/`nand.bin` through the Web UI) | Compiled, reachable (user's own files) | Same | Same | Same | `DolphiniOS/UI/Import/NANDImportManager.mm`, `Common/Services/UploadKind.swift` |
| JIT: code paths (`JitManager`, TXM handshake, ptrace/csops probes, StikDebug hand-off, JIT recompiler in the core) | **Compiled.** Whether JIT is used depends only on a runtime check for `get-task-allow`, so a store install is jitless. | Compiled, `get-task-allow` present from development signing, so JIT can be offered | Compiled and live | Compiled and live | `Common/Jit/JitManager.m:46-60` (`jitSupported = checkIfProcessIsJitCapable`), `:76-81` (hard stop when not supported), `Common/Services/JitAcquisitionService.swift:12-22`, `Common/Swift/EmulationScreen.swift:104-106` |
| JIT UI on a store install | Hidden unless runtime detection says JIT works (re-signed install): boot prompt, Debug leaf JIT rows, Help JIT guide | Shown when `jitSupported` | Shown | Shown | `EmulationScreen.swift:104`, `DebugRootModelBuilder.swift:18-25`, `Common/Swift/Help/WikiHelpViewModel.swift:15-33`, `PerformanceTuningModelBuilder.swift:56-80` |
| `acquireJitByAltServer()` | **Called** (the `NONJAILBROKEN || APPSTORE` branch), but returns at once because `ALTDeviceID` is the literal `NotSet`. `AltKit` is linked and `_altserver._tcp` is in `NSBonjourServices`. | Same | Called, same no-op | Called on NJB only | `JitAcquisitionService.swift:19-21`, `Common/Jit/JitManager+AltServer.m:11-20`, `DolphiniOS/Info.plist` (`ALTDeviceID`, `NSBonjourServices`) |
| `ptrace` start-up probe | Not run: needs `jitSupported` and the private `platform-application` entitlement | Not run | Not run | JB/TS only | `JitAcquisitionService.swift:15-17`, `Common/Jit/JitManager+PTrace.m:22-43` (private SecTask symbols resolved with `dlsym`) |
| `icube.js` StikDebug script in the bundle; URL schemes `stikdebug`/`stikjit` queried | **Bundled and declared in every configuration**, used only if StikDebug is installed and `jitSupported` | Same | Same | Same | `Project.swift:339` (resource), `DolphiniOS/Info.plist` (`LSApplicationQueriesSchemes`), `Common/Jit/StikDebugLauncher.swift:20-30` |
| Live Activity extension | **Not embedded** (`APP_EMBEDS_APPEX = false`). The app still contains ActivityKit calls and `NSSupportsLiveActivities = YES`. | Same | Same | Same | `Project.swift:13,404`, `Project.swift:426` (`NSSupportsLiveActivities`), `Common/Swift/EmulationScreen.swift:741-836` |
| Top Shelf extension | tvOS only (embedded via `.when([.tvos])`) | Same | Same | Same | `Project.swift:405` |
| Thumbnail + Quick Look Preview extensions | iOS/Catalyst only | Same | Same | Same | `Project.swift:406-407`, extension targets `:656-690` |
| Home-screen widget (`RecentGamesWidget`) | **Not shipped.** The sources live inside the un-embedded Live Activity target. `WidgetCenter.reloadTimelines` is still called (no-op). | Same | Same | Same | `Project.swift:484-503` (widget sources in the un-embedded target), `:400-402` (WidgetKit link) |
| Sentry SDK | Compiled, **on by default**, user opt-out; App Store scrubbing active | Compiled; APPSTORE scrubbing active; environment tag `development` | Compiled; no scrubbing; `game_id` sent | Compiled; no scrubbing; `game_id` sent | `Common/Services/SentryTelemetryService.swift:140-253`; section 4 |
| Launch-time update check (`https://icube-emu.com/api/v2/update.json`) | **Runs every launch** (`DOL_BUILD_SOURCE = official`) | Runs (see 1.1) | Skipped (`development`) | Skipped (`unofficial`) | `Common/Services/UpdateCheckService.swift:28-37`; `AppStore.xcconfig:6` |
| Dolphin analytics | Compiled out | Compiled out | Compiled out | Compiled out | `BuildiOSXCFramework.py:609` |
| RetroAchievements client | Compiled (`USE_RETRO_ACHIEVEMENTS=1`), off by default | Same | Same | Same | `AppStore.xcconfig:4`, `NonJailbroken.xcconfig:4` |
| iCloud / CloudKit sync | Compiled; opt-in, default off | Same | Same | Same | `CloudSyncCoordinator.swift:96` ("Opt-in, default off"), `ICubeCloudSync.swift:6` |

### 1.3 Notes on the matrix

1. **Debug server.** The store build cannot start it, so the "debug HTTP API" requirement holds at run time. It is still in the binary: route strings (`/api/debug/boot`, `/api/settings`, `/ws/events`, ...) and the handler code ship in the IPA. A reviewer running `strings` will see them. See finding F9. `NativeWebServer.swift:12-14` and `review-notes.md` ("disabled in this build and cannot be turned on") are both accurate for run time.
2. **Stale comment.** `Common/Emulation/EmulationCoordinator.mm:2022-2029` still says the server is "loopback-only" and "never reachable off-device without an explicit USB iproxy forward". In non-store release builds it is LAN-reachable (token protected). Comment only.
3. **JIT.** The project rule (keep JIT code, expose it only on detection) is implemented. Store entitlements carry no `cs.allow-jit`, no `cs.allow-unsigned-executable-memory`, no `cs.disable-*`, no `get-task-allow` (section 2). `review-notes.md` says "requests no JIT or dynamic-code-signing entitlement" and "generates no executable code at runtime": both true for an unmodified install. It also says "Do not replace it with 'the app contains no JIT code'"; that is correct.
4. **Firmware.** The shipped store UI never offers a download of Nintendo software. The downloader remains in the core binary (every configuration shares one core). Nothing in the app layer calls it under `APPSTORE`. Treat this as "unreachable", not "absent".
5. **Web UI/WebDAV** is the only network listener that is live in the store build. Its exposure is assessed in finding F2.

## 2. Entitlements review

Which file signs which configuration (`Project.swift:39-78`, `appCfg`): `Debug (AppStore)` and `Release (AppStore)` use `DolphiniOS/iCube AppStore.entitlements`. Every other configuration uses `DolphiniOS/DolphiniOS.entitlements`. `Project/Entitlements/{Public,Private}.entitlements` are applied by CI re-signing of sideload artifacts only (`.github/workflows/build.yml:300-306`, `release.yml:164-170`) and never reach the store build. `Live ActivityExtension.entitlements` signs a target that is not embedded (`Project.swift:13`, `:404`). `Project/Entitlements/Extension.entitlements` signs all three shipping extensions in every configuration.

What a store archive carries is the AppStore file plus whatever the distribution profile and Xcode add at export (`aps-environment` value, `icloud-container-environment`, `application-identifier`, `team-identifier`, `beta-reports-active`). Those added values need the signed IPA (section 6).

### 2.1 `iCube AppStore.entitlements` (the store entitlements), key by key

| Key | Needed by the store build? | What the code does | Verdict |
|---|---|---|---|
| `aps-environment` = `development` | Required by Apple once CloudKit is enabled (the tvOS export failed without it, see `memory: icube-testflight-aps-environment`). | No `registerForRemoteNotifications`, no `CKSubscription` in the app or `PVCloudSync` 1.1.0. CloudKit registers for pushes itself. No `UIBackgroundModes` in either Info.plist, so a silent push cannot wake the app. | Keep. Distribution signing replaces `development` with `production`. **ARTIFACT**: confirm the signed value is `production`. |
| `com.apple.developer.associated-domains` = `applinks:icube-emu.com` | Not needed today. | Nothing consumes universal links: `scene(_:continue:)` handles only `CSSearchableItemActionType` (`Common/MainDisplaySceneDelegate.swift:141-150`); there is no `NSUserActivityTypeBrowsingWeb` or `webpageURL` handler anywhere in the app sources. `GameTagPayload.swift:55,123` parses `https://icube-emu.com/play?id=` out of NFC tags but nothing receives the link when it is opened. The AASA file is **404 live** (`/.well-known/apple-app-site-association` and `/apple-app-site-association`, checked 2026-11-03). | Mismatch (no review risk). Either deploy the AASA and add the handler, or drop the entitlement for 1.0. See F8. |
| `com.apple.developer.icloud-container-identifiers` = `iCloud.com.joemattiello.iCube`, `iCloud.com.joemattiello.iFly`, `iCloud.org.provenance-emu.provenance` | Only the first. | `ICubeCloudSync.swift:6` is the only container the app opens. The iFly and Provenance containers are referenced by no iCube source (grep across `Source/iOS` finds the strings only in entitlements and docs). | Two unused containers. They must be on the App ID and in the profile (TestFlight uploads pass, so they are). Harmless; remove if the cross-app work is not in 1.0. |
| `com.apple.developer.icloud-services` = `CloudDocuments`, `CloudKit` | `CloudKit` only. | `CloudSyncCoordinator.providerKind = .iCloud` (`:395`), i.e. CloudKit. The iCloud Drive provider (`SyncProviderKind.iCloudDrive`) is not used by iCube. | `CloudDocuments` unused. |
| `com.apple.developer.ubiquity-container-identifiers` (the same three) | No. | No `url(forUbiquityContainerIdentifier:)`, no `NSMetadataQuery` in app sources. | Unused. Same note as above. |
| `com.apple.developer.ubiquity-kvstore-identifier` = `$(TeamIdentifierPrefix)$(CFBundleIdentifier)` | No. | No `NSUbiquitousKeyValueStore` in app sources. | Unused. |
| `com.apple.developer.kernel.extended-virtual-addressing` | Yes | JIT-less fastmem arena and guest memory mapping | Keep. iOS and tvOS. |
| `com.apple.developer.kernel.increased-memory-limit` | Yes | 32-bit guest address space, MEM1/MEM2 | Keep. |
| `com.apple.developer.sustained-execution` | Wanted (thermal headroom) | No code references it; effect is by entitlement only. iOS 17+, not tvOS. | Keep; ignored on tvOS (Apple accepted the 2026-10-26 tvOS TestFlight build with it, per `memory: icube-testflight-processing-rejection`). |
| `com.apple.developer.nfc.readersession.formats` = `TAG` | Yes | `NFCNDEFReaderSession` in `Common/Ecosystem/NFC/GameTagCenter.swift:113`; `NFCReaderUsageDescription` present in `DolphiniOS/Info.plist` | Keep. `TAG` is the correct value (the `NDEF` value triggers ITMS-90778). iOS only; the same file also signs the tvOS slice. **ARTIFACT**: confirm the tvOS slice's profile accepts it (it did for the last TestFlight). |
| `com.apple.security.application-groups` = `group.com.joemattiello.icube`, `group.org.provenance-emu.provenance` | The first. | `Common/SharedDefaults.m:5`, `Shared/Snapshot/ICubeSnapshot.swift:8`; extensions read the same group. The Provenance group is referenced by no iCube source. | Second group unused. |
| `keychain-access-groups` = `$(AppIdentifierPrefix)com.joemattiello.shared` | Yes | `Common/Swift/SharedPlusEntitlement.swift:7-8,101` (explicit `kSecAttrAccessGroup`) | Keep. **Side effect** in F7: it is the *only* group, so it is also the default group for Keychain items that name none. |
| `com.apple.security.app-sandbox` | Inert on iOS/tvOS | Mac Catalyst only | Keep only if Catalyst ships. |
| `com.apple.security.network.client` / `network.server` | Inert on iOS/tvOS | `network.server` matches the Web UI/WebDAV listener on Catalyst | Keep for Catalyst. |
| `com.apple.security.device.audio-input` | Inert on iOS/tvOS | Wii Speak / GameCube microphone use `AVAudioSession`; `NSMicrophoneUsageDescription` present | Fine. |
| `com.apple.security.device.bluetooth` | Inert on iOS/tvOS | No `CoreBluetooth` use in app or packages | Unused (Catalyst only). |
| `com.apple.security.assets.{movies,music,pictures}.read-only`, `files.downloads.read-only` | Inert on iOS/tvOS | The app imports through the document picker (`files.user-selected.read-only`); nothing reads those libraries or Downloads | Unused Catalyst keys; remove if Catalyst keeps the sandbox minimal. |
| `com.apple.security.files.user-selected.read-only` | Inert on iOS/tvOS | Import via picker, `LSSupportsOpeningDocumentsInPlace` | Fine (Catalyst). |
| `com.apple.security.personal-information.photos-library` | Inert on iOS/tvOS | Photos use is add-only (`PHPhotoLibrary.requestAuthorization(for: .addOnly)`, `Common/Swift/Recording/RecordingManager.swift:188`, `ReplayKitManager.swift:104`) | Broader than needed for Catalyst. |

Absent on purpose and confirmed absent: `com.apple.security.cs.allow-jit`, `cs.allow-unsigned-executable-memory`, `cs.disable-executable-page-protection`, `cs.disable-library-validation`, `cs.allow-dyld-environment-variables`, `inter-app-audio`, `get-task-allow`, `kernel.increased-debugging-memory-limit`, `com.apple.developer.activities`, `platform-application`. (`grep -c "cs\.\|inter-app"` on the file is 0, as the checklist states.) `get-task-allow` is added by Xcode only for development signing, which is what lets `Debug (AppStore)` offer JIT; the distribution profile does not carry it, so `JitManager.jitSupported` is false on a store install. **ARTIFACT**: `codesign -d --entitlements :-` on the exported app must not contain `get-task-allow`.

Capabilities the code relies on that need **no** entitlement: Local Network (Info.plist `NSLocalNetworkUsageDescription` via `INFOPLIST_KEY`, `Project.swift:~423`; `NSBonjourServices`), motion (`NSMotionUsageDescription`), photo add-only (`NSPhotoLibraryAddUsageDescription`), microphone, Game Controller, App Intents, Spotlight, Keychain. No camera, location, Bluetooth, contacts, Siri-kit, Game Center, HealthKit or background-mode code was found, and none is declared.

One possible gap, not provable from source: Dolphin's built-in BBA broadcasts UDP on the host network (`Source/Core/Core/HW/EXI/BBA/BuiltIn.cpp`, `IOS/Network/Socket.cpp`, `SO_BROADCAST`). iOS requires `com.apple.developer.networking.multicast` for multicast/broadcast sends. It is absent. Only emulated-network games that broadcast are affected, and it is not a review item. Needs an on-device test if online play is in the 1.0 claims.

### 2.2 The other entitlement files (not shipped in the store build)

| File | Used by | Contents of note | Store relevance |
|---|---|---|---|
| `DolphiniOS/DolphiniOS.entitlements` | Debug/Release Non-Jailbroken, Jailbroken, TrollStore, Beta | Everything in the store file **plus** `cs.allow-jit`, `cs.allow-unsigned-executable-memory`, `cs.disable-executable-page-protection`, `cs.disable-library-validation`, `cs.allow-dyld-environment-variables`, `inter-app-audio`, `increased-debugging-memory-limit` (and without `aps-environment`, `associated-domains`, NFC) | None. Must never be pointed at an AppStore configuration; `Project.swift:64-77` keeps the two apart (checked per row). |
| `Project/Entitlements/Public.entitlements` | CI re-sign of the sideload IPA | `com.apple.developer.activities` = `com.apple.activitykit`, `cs.allow-jit`, `cs.allow-unsigned-executable-memory`, `get-task-allow` | None. |
| `Project/Entitlements/Private.entitlements` | CI re-sign for TrollStore and the jailbreak `.deb` | `platform-application`, `com.apple.private.security.no-sandbox`, `com.apple.private.security.storage.AppDataContainers`, IOKit user clients, `get-task-allow` | None. Private entitlements; a store upload of this would be rejected. Not referenced by any Xcode configuration. |
| `Project/Entitlements/Extension.entitlements` | Top Shelf, Thumbnail, Quick Look Preview, every configuration | `app-sandbox`, `application-groups` = `group.com.joemattiello.icube` | Correct and minimal. **ARTIFACT**: the three extension App IDs (`com.joemattiello.iCube.topshelf|thumbnail|preview`) must carry App Groups in the profile, or the extensions load with no data (`docs/app-group-entitlements.md`). |
| `Live ActivityExtension.entitlements` | `LiveActivityExtension` target only | `app-sandbox`, group, `network.client` | Not embedded (`Project.swift:13`, `:404`). |

### 2.3 Extension signing and bundle identity (store configuration)

- Bundle ids are `<app id>.<suffix>` for every configuration (`Project.swift:88-95`, `extensionConfigs`), so the store ids are `com.joemattiello.iCube.topshelf|thumbnail|preview`, prefixed by the parent id as validation requires.
- Extensions use automatic signing with team `S32Z3HMYVQ` (`Project.swift:~632-640`), `SKIP_INSTALL = YES`, deployment target iOS/tvOS 17 (matches the app), `UIRequiredDeviceCapabilities = arm64`, and each ships its own `PrivacyInfo.xcprivacy` (`Project.swift:~662,675,687`).
- Version strings: extensions hard-code `MARKETING_VERSION = 1.0.0` and `CURRENT_PROJECT_VERSION = 13`, the same literals as the app (`Project.swift:~420-425,~634-635`). They agree only while the release pipeline overrides both identically; **ARTIFACT**: compare `CFBundleShortVersionString`/`CFBundleVersion` of the app and the three appex in the exported IPA.
- Extensions link only `PVLibrarySnapshot` and system frameworks (`Project.swift:~626`); no Sentry, no core. Extension crash/timing signal reaches Sentry only through the app-side `ExtensionMetricsReporter` (`Common/Services/ExtensionMetricsReporter.swift`).
- Extension privacy manifests are wrong for app-group UserDefaults: see section 3.2 (fixed in a separate commit).
- Not shipped: `RecentGamesWidget`/Live Activity (not embedded), `NSSupportsLiveActivities` and `NSSupportsLiveActivitiesFrequentUpdates` are still set on the app (`Project.swift:426-427`). ActivityKit requests will fail without an extension; harmless, but Info.plist claims a feature that has no UI. No review risk expected; remove the two keys or embed the extension when the widget ships.

