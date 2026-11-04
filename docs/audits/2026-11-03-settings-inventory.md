# Settings inventory and sync-scope audit (2026-11-03)

Scope: iCube#53 (R2, settings audit for the 1.0 release), first and fourth checklist bullets.
- Inventory every settings leaf and search/deep-link entry.
- Decide the scope of each setting and audit what reaches sync.

Base commit: `49b114f18c` (origin/develop at the time). Code reading only: nothing was built or run, no device or simulator was used. "Proven" below means proven from source text; "needs device" means the source leaves the outcome open.

## Sources

- `Source/iOS/App/Common/UI/Settings/SwiftUI/` (root, sidebar, search index, deep link) and `.../Leaves/` (builders, states, views).
- `Source/iOS/App/Common/Bridging/DOLConfigBridge.{h,mm}`, `DOLSettingsKeyBridge.mm`.
- `Source/Core/Core/Config/*.cpp` for the Dolphin Config key table (section, key, compiled default).
- `Source/iOS/App/Common/Services/{CloudSyncCoordinator,DolphinCoreService}`, `Swift/{GameProfiles,LibraryStateStore}.swift`.
- External packages, read from a local DerivedData checkout: PVSyncRules 1.0.2 (`692ca3a`) and PVCloudSync 1.1.0. `Project.swift` asks for `upToNextMajor(from: 1.0.2)` and `from: 1.1.0`; the checkout is this Mac's resolution, not proof of what CI resolved.
- `Source/iOS/App/Project/Assets/DefaultPreferences.plist`.
- Prior audit: `docs/audits/2026-10-16-tvos-settings-audit.md`.

## Column legend

- **Kind**: toggle, cycle (tap steps through choices), picker (menu / tvOS option rows), stepper, action, destructive, destination (pushes a sub-screen), custom, caption.
- **Persistence**: `Cfg KEY [System:Section.Key]` is a Dolphin Config key, written through `DOLConfigBridge`. `UD key` is `UserDefaults.standard`. The effective default is the compiled default unless a launch seed (`DolphinCoreService.seedLaunchDefaults...`) overrides it on first run.
- **Layer**: `B` = `SetBase`, `BoC` = `SetBaseOrCurrent` (see "Write layers").
- **Live / restart**: whether a running game picks the value up.
- **Reset**: whether "Reset All Settings" (About, and the toolbar on iOS/iPad) restores it.
- **Scope**: device-local, synced preference (rides `Config/*.ini` through iCloud sync), per-game (`GameSettings/*.ini` or `game_profiles.json`).

<!-- BEGIN:sync -->
## 3. Sync exclusions

### 3.1 What is uploaded, and the one filter that exists

- **Preferences are not synced as such.** There is no `NSUbiquitousKeyValueStore` use anywhere in `Source/iOS` (grep, 0 hits). `UserDefaults` never leaves the device. Settings reach another device only as *files* under `User/`: `Config/*.ini`, `GameSettings/*.ini`, `Profiles/*.json`, `Skins/**`, memory cards, save states, Wii NAND saves.
- **Classification is an allow-list in the external PVSyncRules package** (`SyncClassifier.swift`, 1.0.2). The rules that carry settings:
  - `top == "config", ext == "ini", components.count == 2` (SyncClassifier.swift:145) classifies **every** `Config/<name>.ini` one level deep as `.config`: `Dolphin.ini`, `GFX.ini`, `Logger.ini`, `GCPadNew.ini`, `WiimoteNew.ini`, `GCKeyboardNew.ini`, `FreeLook.ini`, `DSUClient.ini`, `RetroAchievements.ini`. `Config/Profiles/**` and `Config/MappingStash/**` are deeper and do not match.
  - `.config` is `wholeFile` merge: last writer wins for the whole file, with the conflict UI as the only escape. No key-level merge, no key-level filter.
  - `GameSettings/<id>.ini` at depth 2 is `.gameSettings` (per-game settings **and cheats**).
  - `Profiles/game_profiles.json`, `library_state.json`, `touch_overlay_layout*.json` are `.gameProfile`, `.libraryState`, `.touchOverlayLayout`.
  - `name == "sysconf"` anywhere under `Wii/` is `.wiiSave` (SyncClassifier.swift:184).
- **The only credential/endpoint filter is app-side**, `CloudSyncCoordinator.isEligibleForCloudSync` (CloudSyncCoordinator.swift:74-83): it rejects exactly `config/retroachievements.ini` and `config/dsuclient.ini`, applied to the local scan, the remote plan, the index, tombstones and conflicts (call sites :86, :238, :556, :578, :610, :921, :1142). The package classifier is unchanged, so **anything else in a depth-2 `Config/*.ini` uploads**.
- **Defaults** (`SyncPolicy.default`): sync itself is opt-in (`icube.cloudSync.enabled`, default off). With it on, the always-on categories include `.config`, `.gameSettings`, `.gameProfile`, `.libraryState`, `.touchOverlayLayout`, `.skin`, `.wiiSave`, memory cards, save states. Firmware, Wii channels and the rest of the NAND are opt-in and default off. `largeFilesOverWiFiOnly` defaults on.
- **Continuity (paired-device handoff) does not send config.** `ICubeContinuityFileProvider.enumerate(kind: .config)` returns `[]` (ICubeContinuityFileProvider.swift:59-61). It does send `GameSettings/<id>.ini` (:119-127, includes that game's cheats), every `GC/**` memory card for the region and every Wii save (including `SYSCONF`, via `walk("Wii", .wiiSave)` at :53). The provider's own header comment (lines 11-23) already records the "hands over every game's saves" consequence.

### 3.2 Material that can or does reach the INI upload

"Reaches upload" = lives in a file the classifier accepts and the app filter does not reject. Severity is by what an attacker or a second device could do with it, not by how likely it is to be present.

| # | Item | Where it lands | Evidence | Reaches upload today? | Proposed rule |
|---|---|---|---|---|---|
| 1 | RetroAchievements username, API token, host URL | `Config/RetroAchievements.ini` (`System::Achievements`) | Written by `AchievementManager.cpp:966` (`SetBaseOrCurrent(RA_API_TOKEN, user->token)`); file map `BaseConfigLoader.cpp:136` | **No.** Filtered at CloudSyncCoordinator.swift:82. | Keep. Move the token to the Keychain (`ThisDeviceOnly`) so the file filter is not the only guard. |
| 2 | DSU server list (LAN host:port of a phone or PC) and enable flag | `Config/DSUClient.ini` | `DOLConfigBridge.mm` `setDsuServersString` ; file map `BaseConfigLoader.cpp:135` | **No.** Filtered at CloudSyncCoordinator.swift:82. | Keep; device-local by definition (addresses are LAN-specific). |
| 3 | Pairing key | Keychain `com.joemattiello.icube.continuity` / `peer-identity`, `AfterFirstUnlockThisDeviceOnly` | ContinuityIdentityStore.swift:11-19, :82 | No. Not a file. | Keep. |
| 4 | Trusted peers and library grants | `User/Continuity/trusted-peers.json`, `library-grants.json` | ContinuityManager.swift:116-118 | **No.** `continuity/` matches no allow-list rule, so the classifier returns nil. | Keep; add a classifier test that pins `Continuity/**` as unclassified. Not proven: whether the WebDAV/HTTP upload server can read `User/` (see 3.4). |
| 5 | Remote-source (WebDAV) passwords | Keychain via `KeychainService` | RemoteSourcesStore.swift:49-52 | No. Source list (url, username, no password) is `UserDefaults` `RemoteSourcesStore.sources`. | Keep device-local. |
| 6 | Debug bench bearer token | `UserDefaults` (`DebugServerManager.tokenDefaultsKey`) | DebugRootState.swift:12, DebugRootModelBuilder.swift:132-136 | No (UserDefaults). Displayed in clear in the Debug leaf. | Device-local. Not a sync issue; see Findings for the on-screen exposure. |
| 7 | **Analytics ID** (128-bit random id, generated even though analytics is off) | `Dolphin.ini` `[Analytics] ID` | `DolphinAnalytics.cpp:101-117` (`GenerateNewIdentity` -> `SetBase` + `Config::Save()`), called from `DolphinCoreService.mm` (`ReportDolphinStart`) | **Yes** (Dolphin.ini). A persistent per-install identifier would be copied to every device sharing the file, then rewritten. | Deny-list the key, or delete it after init (analytics is disabled: `MAIN_ANALYTICS_ENABLED` default false). |
| 8 | **Wii wireless MAC** | `Dolphin.ini` `[General] WirelessMac` | `IOS/Network/MACUtils.cpp:19-20` generates and saves it on first Wii network use | **Yes.** Two devices end up emulating the same console MAC. | Device-local: deny-list. |
| 9 | **Default ISO absolute path** | Was `Dolphin.ini` `[Core] DefaultISO` | Now stored as sandbox-relative record in `UserDefaults` `icube.defaultISO.localSelection`; `migrateLegacyDefaultISO` deletes the Base key and saves (DOLConfigBridge.mm:~365-388); boot sets it on CurrentRun only (`prepareDefaultISOForBoot`) | **Fixed for new writes.** A pre-fix `Dolphin.ini` synced in from another device brings the key back; the migration deletes it again at the next launch (`DolphinCoreService.mm:190`) but only after the file may already have been re-uploaded. | Keep the deletion; add `DefaultISO` to the deny-list so a remote copy is never applied. |
| 10 | **Other absolute paths in Dolphin.ini** (`WiiSDCardPath`, `NANDRootPath`, `ISOPaths`/`ISOPath0..`, `DumpPath`, `LoadPath`, `GBA BIOS`/`SavesPath`, `MemcardAPath`/`BPath`, `GCIFolder*`, `SkylandersCollectionPath`, `CurrentStatePath`, `PerfMapDir`) and `GFX.ini` `DumpPath` | `Dolphin.ini`, `GFX.ini` | Key table `Source/Core/Core/Config/MainSettings.cpp`, `GraphicsSettings.cpp`. No iCube UI or bridge writes them (grep of `Source/iOS` for these Config symbols: 0 hits besides the SD-card booleans), so they are present only if the user imported a Dolphin.ini or a debug tool wrote them. | **Yes if present**; sandbox UUIDs differ per install, so a synced absolute path points nowhere on the receiver. | Deny-list by key pattern: any `std::string` value that starts with `/`. |
| 11 | **Hardware-derived values seeded at first launch** | `Dolphin.ini` `[Core] Fastmem`, `FastmemArena` (from `FastmemManager.fastmemAvailable`); `GFX.ini` `[Settings] ShaderCompilerThreads`, `ShaderPrecompilerThreads` (from `processorCount`) | `DolphinCoreService.mm:87-88`, `:129-131`; reset re-seeds them too (DOLConfigBridge.mm ~1405-1411) | **Yes.** A TestFlight device with fastmem synced from a sideloaded device (or the reverse) picks up the wrong capability. `SettingsRepair` deletes a stored `Fastmem=false` only when this device has fastmem and only once (`whenFalseWithFastmem`, version 1). | Device-local: deny-list `Fastmem`, `FastmemArena`, both thread counts. |
| 12 | **CPU engine, GFX backend, audio backend** | `Dolphin.ini` `[Core] CPUCore`, `GFXBackend`, `[DSP] Backend`, `[iOS] AudioAUChain` | Written by Performance Tuning, Video, Audio leaves | **Yes.** `CPUCore = 4` (JIT ARM64) from a JIT-capable sideload would arrive on a store install; the jitless boot forces core 5 on CurrentRun (EmulationCoordinator.mm "Enforce CPU-core fallback") so it is not fatal, but the Performance row then shows the wrong Base value. Audio Unit chain ids are device-specific. | Treat `CPUCore`, `GFXBackend` and `AudioAUChain` as device-local; the rest of the audio settings are fine to sync. |
| 13 | **Performance A/B and CIR knobs** | `Dolphin.ini` `[Core] CIR*`, `StallMetrics`, overclock keys | Performance Tuning leaf | **Yes.** Measured on one device, applied to another. `SettingsRepair` already deletes leaked CIR keys, once per install, so a synced file can re-introduce them after the repair ran. | Device-local (they are per-hardware tuning). |
| 14 | **NetPlay nickname, address, host code, index password** | `Dolphin.ini` `[NetPlay]` | Key table `NetplaySettings.cpp`; No Settings leaf has NetPlay rows and no `Source/iOS` code writes these keys (grep, 0 hits), so present only if written by Dolphin netplay code or an imported file | **Yes if present.** `IndexPassword` is a credential. | Deny-list the whole `[NetPlay]` section; nickname is a per-device choice. |
| 15 | **Bluetooth passthrough link keys, Wiimote auto-connect addresses, USB passthrough device list** | `Dolphin.ini` `[BluetoothPassthrough] LinkKeys`, `[Core] WiimoteAutoConnectAddresses`, `[USBPassthrough] Devices` | Key table `MainSettings.cpp` | **Yes if present.** The iOS build has no UI writing them, so presence needs an imported file. Link keys are pairing grants. | Deny-list the three keys. |
| 16 | **Controller device strings** | `GCPadNew.ini`, `WiimoteNew.ini`, `GCKeyboardNew.ini` (`Device = MFi/0/<model>`, `DSUClient/0/<server>`, `iOS/0/Touchscreen`) | `AssignmentEngine.swift:208` (comment names the three families); mapping writer `TVControllerMappingBridge.mm`, `BridgeControllerConfigWriter.swift:71` | **Yes.** Hardware identity strings: a map saved against a DualSense on the phone is applied to an Apple TV with a different pad. The 2026-10-02 controller hub already re-derives player assignment, which limits the damage but not the file overwrite. | Device-local for the three `*New.ini` files (they are what the controller hub regenerates per device). |
| 17 | **Logger.ini** | `Config/Logger.ini` | `LoggerIniMigration.applyLaunchOptions` rewrites `[Options]` from `UserDefaults` (`logger_console_enabled`, `logger_console_verbosity`) at every launch whenever the file differs from the local preference (DolphinCoreService.mm:183; `applyLaunchOptions` skips the write when nothing changed) | **Yes.** Each device rewrites the file at launch from its own local preference, so two devices with different debug settings keep producing competing versions. | Device-local: add `config/logger.ini` to the app filter. |
| 18 | **`SYSCONF` (Wii)** | `Wii/shared2/sys/SYSCONF`, classified `.wiiSave` | SyncClassifier.swift:184; contents built in `SysConf.cpp:254-295`; `BTEmu.cpp:73-78` writes `BT.DINF` | **Yes** (always-on category). Holds: console nickname (`IPL.NIK`), language/country, and `BT.DINF`, the table of **emulated** paired Wii Remotes (generated BD addresses). Only emulated remotes appear in it on iOS; whether a real remote's link key can land there is not determined from code. Also `NET.*` network config. | Acceptable as-is for the emulated table. Re-check if real Wii Remote passthrough is ever enabled; then split `BT.DINF` out before upload. |
| 19 | **`setting.txt`** (Wii serial, model, region) | `Wii/title/00000001/00000002/data/setting.txt`, which matches the `.wiiSave` rule (`data` path component) | SyncClassifier.swift `classifyWii` | **Yes.** Console serial identity. Not a credential. | Note only; decide whether two devices should share a Wii serial. |
| 20 | **Wii Connect24 / NWC24 credentials** | `Wii/shared2/wc24/nwc24msg.cfg` | Falls in `classifyWii` default branch -> `.wiiSystem` | **Only with "Full Wii NAND" on** (opt-in, default off). Holds the emulated friend code and password. | Keep opt-in; the toggle copy should say it includes network identity. |
| 21 | **Touch layout** | `Profiles/touch_overlay_layout_v2.json` (and v1) | TouchOverlayLayoutStore.swift:61-91: anchored centre + scale per pad kind and orientation | **Yes**, whole-file. Not a credential, but screen-size specific: positions saved on a 6.9-inch phone are applied to an iPad. Needs a device check for how the anchors resolve across sizes. | Decide scope: per device class, or key the file by device class. |
| 22 | **Per-game profile** | `Profiles/game_profiles.json` | GameProfiles.swift:4-33: shader preset path (stored bundle-relative, `ShaderLibrary.normalizedPath`, ShaderSettingsView.swift:22), IR mode, widescreen, touch opacity, sensor-bar sensitivity, `excludedFromNearbySharing`, `updatedAt` | Yes, merged per game (`KeyedTimestampDocumentMerger`). No path or credential. | Fine. This is the one place a setting has an intentional per-game scope that follows the user. |
| 23 | **Library state device id** | `Profiles/library_state.json` | `launches[deviceID]`, `playSeconds[deviceID]` (LibraryStateStore.swift:99, :108); `SyncDeviceIdentity` is a random UUID in `UserDefaults` | Yes. A random per-install id, not derived from hardware. | Fine; document that it is an install id. |

### 3.3 Proposed rule

1. **Move from "which file" to "which key".** The unit of sync for `Config/Dolphin.ini` and `Config/GFX.ini` should be an allow-list of keys (the preferences a person would expect to follow them), not the whole file. Everything not on the list stays device-local. This also fixes last-writer-wins clobbering of unrelated keys (a V-Sync toggle on one device overwriting a fastmem value on another).
2. **Minimum change without an engine rewrite:** extend `isEligibleForCloudSync` from two paths to a predicate plus a sanitiser:
   - Whole files to exclude: `config/retroachievements.ini`, `config/dsuclient.ini` (today), plus `config/logger.ini`, `config/gcpadnew.ini`, `config/wiimotenew.ini`, `config/gckeyboardnew.ini`.
   - Keys to strip on upload and ignore on download from `Dolphin.ini` / `GFX.ini`: items 7, 8, 9, 10, 11, 12, 13, 14, 15 above.
   - Both directions, as the existing filter does.
3. **Credentials stay out of INI altogether.** The RetroAchievements token is the only live credential; it is protected today by a filename exclusion only.
4. **Display the scope.** The settings UI shows no scope today (grep of the leaf builders: none of the 200+ rows carries a scope badge or footer). The tables in section 1 are the proposed labelling.
5. **Test.** Pin each exclusion with a unit test next to `CloudSyncSafetyTests` (the existing app-level tests) so a PVSyncRules bump cannot silently widen the set.

### 3.4 Not determined from code in this section

- Whether the WebDAV/HTTP upload server serves `User/` (and therefore `Continuity/trusted-peers.json`). The source comment at ContinuityIdentityStore.swift:6-8 says it does; the server code lives in the external PVWebServer package, not read here.
- What a real `Dolphin.ini` on a long-lived install contains. This audit lists keys that can reach the file; the actual set needs a device `Config/` listing.
- Whether Dolphin's INI writer persists a key only when it differs from its default (it persists any key present in the Base layer; `SetBaseIfUnspecified` seeds therefore always land).
- Production CloudKit behaviour (R3).
<!-- END:sync -->
