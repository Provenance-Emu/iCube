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
- Static checks run (no build): `Source/iOS/App/Project/Scripts/check_settings_wiring.py` (clean) and `scripts/icube_config_lint.py` (exits 1; see section 5).

## Column legend

- **Kind**: toggle, cycle (tap steps through choices), picker (menu / tvOS option rows), stepper, action, destructive, destination (pushes a sub-screen), custom, caption.
- **Persistence**: `` `KEY` File [Section] Key `` is a Dolphin Config key and its INI location, written through `DOLConfigBridge`; the bracketed word in parentheses is the write layer. `UD key` is `UserDefaults.standard`. The effective default is the compiled default unless a launch seed (`DolphinCoreService.seedLaunchDefaults...`) overrides it on first run.
- **Write layer** (in the Persistence cell, in parentheses): `SetBase` or `SetBaseOrCurrent`, spelled out in full (see 1.2).
- **Live / restart**: whether a running game picks the value up.
- **Reset**: whether "Reset All Settings" (About, and the toolbar on iOS/iPad) restores it.
- **Scope**: device-local, synced preference (rides `Config/*.ini` through iCloud sync), per-game (`GameSettings/*.ini` or `game_profiles.json`).

## Summary

- 21 root entries in 9 sections, about 300 table rows (a few rows stand for a family, such as one per player or per peer). The tables cover every row the root leaves' menu models and local row helpers generate (`SettingsRow.*`, `flag`/`flagRow`/`validateRow`/`percentStepper`/`status`), the hand-built leaves, the DSU, Advanced Motion and Stick Feel screens, and the pause-menu surfaces that write the same keys. The per-player controller screens are not enumerated row by row (section 5).
- Settings reach another device only as files (`Config/*.ini` whole-file, SYSCONF with Wii saves, `GameSettings/*.ini`, `Profiles/*.json`); `UserDefaults` never syncs (no KVS use). The single guard is a two-filename filter in `CloudSyncCoordinator`. Section 3 lists 23 items with evidence.
- Top findings (section 4): **F1** Reset All from the pause menu deletes the running game's per-game keys from `GameSettings/<id>.ini`; **F2** device-bound and identifying keys ride in the synced INI files; **F3** Wii Speaker Volume range 0-7 on a 0-127 key; **F4** several rows write to the CurrentRun layer in game and lose the value at game end; **F6/F7/F8** three rows do nothing (touchpad IR follow, camera overlay, tvOS background style); **F10** search opens leaves, not rows, and seven entries are unsearchable.
- Not done: no build, no device, no simulator. Section 5 lists what the code does not settle.

## 1. Inventory

### 1.1 Root entries

`SettingsRootModelBuilder.sections` (SettingsRootModelBuilder.swift:48-149) produces 9 sections and 21 entries; the header comment still says "eight sections". iPhone renders them as a grouped list pushing one leaf; iPad (regular width) and tvOS use `SettingsSidebarShell`. Search exists on iOS/iPadOS only (`searchIndex: nil` on tvOS, SettingsRootView.swift:74).

| Section | Entry id | Leaf | File | iPhone | iPad | tvOS | In APPSTORE | Rows searchable |
|---|---|---|---|---|---|---|---|---|
| General | `general` | General | Leaves/ConfigGeneral* | yes | yes | yes | yes | yes |
| General | `interface` | Interface | Leaves/ConfigInterface* | yes | yes | yes (camera, skin-store rows iOS only) | yes | yes |
| General | `advanced` | Advanced | Leaves/ConfigAdvanced* | yes | yes | yes (no RTC date row) | yes | yes |
| Graphics | `graphics-video` | Video | Leaves/GraphicsGeneral* | yes | yes | yes (no frame cap, no Recording) | yes | yes |
| Graphics | `graphics-enhancements` | Enhancements | Leaves/GraphicsEnhancements* | yes | yes | yes | yes | yes |
| Graphics | `graphics-hacks` | Hacks | Leaves/GraphicsHacks* | yes | yes | yes | yes | yes |
| Graphics | `graphics-advanced` | Graphics Advanced | Leaves/GraphicsAdvanced* | yes | yes | yes | yes | yes |
| Graphics | `shaders` | Shaders | Swift/Shaders/ShaderSettingsView.swift | yes | yes | yes | yes | no (title and description only) |
| Audio | `audio` | Audio | Leaves/ConfigAudio* | yes | yes | yes (no mute switch, AU plug-ins, microphone) | yes | yes |
| GameCube & Wii | `console-gamecube` | GameCube | Leaves/ConfigGameCube* | yes | yes | yes (no microphone) | yes | yes |
| GameCube & Wii | `console-wii` | Wii | Leaves/ConfigWii* | yes | yes | yes (no Wii Speak) | yes | yes |
| GameCube & Wii | `achievements` | Achievements | ConfigAchievementsView.swift | yes | yes | yes | yes: `USE_RETRO_ACHIEVEMENTS=1` in AppStore.xcconfig and NonJailbroken.xcconfig | no |
| Controllers | `controllers` | Controllers hub | ControllersRootView.swift, Swift/Controllers/Hub/ | yes | yes | yes (Touch Controls, rumble, take-player-1 iOS only) | yes | no (rows are built at runtime from live devices) |
| Performance | `performance-tuning` | Performance Tuning | Leaves/PerformanceTuning* | yes | yes | yes | yes, with JIT-free copy and engine list | yes (default state: IR-engine rows missing, see 2.3) |
| Performance | `debug` | Debug | Leaves/DebugRoot* | yes | yes | yes (no Recording, StikDebug) | **reduced**: `.jitOnly` (Environment section, JIT actions) when `JitManager.jitSupported`, else `.environmentOnly` (read-only) (SettingsRootModelBuilder.swift:151-161) | yes (state-gated rows missing) |
| Sync & Network | `web-ui` | Web UI & WebDAV | WebUISettingsView.swift | yes | yes | yes | yes | no |
| Sync & Network | `icloud` | iCloud Sync | CloudSyncSettingsView.swift | yes | yes | yes, **reduced** (no opt-in switches, no Recently Deleted) | yes | no |
| Sync & Network | `nearby` | Nearby Devices | Continuity/UI/ContinuityBrowseView.swift | yes | yes | yes | yes | no |
| Sync & Network | `connected-apps` | Connected Apps | Leaves/ConnectedApps* | yes | yes | **no** (needs `UIApplication.open`) | yes | partial (installed-app rows absent: model built with `apps: []`) |
| Privacy | `privacy` | Privacy | Leaves/ConfigPrivacy* | yes | yes | yes | yes (different footer) | yes |
| About | `about` | About | AboutView.swift | yes | yes | yes (tvOS renders `AboutModelBuilder`; iOS renders a hand-built ScrollView) | yes | no |

Pushed sub-screens that are not root entries and cannot be searched or deep-linked: Default ISO, Performance A/B & Snapshots, the Controllers hub's per-player screens (remapping, profiles, Advanced Motion, On-Screen Stick Feel), DSU, Skins, Controller Lights, Sync Conflicts, Recently Deleted, Blog, Help, User Folder, Motion Debug, Gallery, Shader Debug Tools.

### 1.2 How a row writes, applies and resets

- **Pattern.** Every migrated leaf is `State` (a snapshot) + `ModelBuilder` (pure: snapshot in, `apply(change)` out) + `View` (`sync()` reads Config/UserDefaults, `apply` is the only writer). `sync()` runs on appear, on `DOLConfigChanged`, on emulation start/end and on foreground (`SettingsLeafHost`).
- **Layers.** Config setters use one of: `SetBase` (always the persisted Base layer, e.g. Internal Resolution, Auto Disc Change, all SYSCONF rows, clock overrides); `SetBaseOrCurrent` (Base when no higher layer holds the key, otherwise **CurrentRun**: `Config.h:131-137`); or a game-aware pair (`setMainTouchPadOpacity`, `setMainTouchPadIRMode`: CurrentRun only when a game INI overrides the key). Column "Persistence" shows which. `CurrentRun` is replaced by an empty layer at every boot and end (`ClearCurrentRunLayer`, BootManager.cpp:239), so a write that lands there is lost at game end.
- **App code that puts keys on CurrentRun** (grep of `Config::SetCurrent` in `Source/iOS`): `MAIN_AUDIO_VOLUME`, `MAIN_AUDIO_MUTED`, `MAIN_AUDIO_MUTE_ON_DISABLED_SPEED_LIMIT`, `MAIN_EMULATION_SPEED`, `MAIN_OVERCLOCK(+_ENABLE)`, `MAIN_VI_OVERCLOCK(+_ENABLE)`, `MAIN_CPU_CORE`, `MAIN_CIR_PROFILE`, `MAIN_TOUCH_PAD_OPACITY`, `MAIN_TOUCH_PAD_IR_MODE`, `SYSCONF_SENSOR_BAR_SENSITIVITY`, `GFX_WIDESCREEN_HACK`, `GFX_EFB_SCALE`, `MAIN_DEFAULT_ISO`. A row that writes any of these with `SetBaseOrCurrent` loses its value at game end when changed in game (Finding F4).
- **Persistence.** `Config::Save` runs 0.8 s after a Config change when no game is running (`startConfigAutoSyncBridge`), on background (`flushSettingsToDisk`) and at exit. It writes the Base layer to `Dolphin.ini` and `GFX.ini` (and the pad/DSU/RA/Logger systems to their own files, `BaseConfigLoader.cpp:130-141`); SYSCONF keys go to the SYSCONF file unless a Wii title controls it (`SkipIfControlledByGuest::Yes`); LocalGame deletions go to `GameSettings/<id>.ini` (`GameConfigLoader.cpp:283-325`). Pad systems (GCPad/WiiPad/GCKeyboard) are not saved by `Config::Save` (`IsSettingSaveable.cpp`); the controller code writes `GCPadNew.ini`/`WiimoteNew.ini` itself.
- **Launch seeds.** `DolphinCoreService.seedLaunchDefaults` writes first-run values with `SetBaseIfUnspecified` (only when the key is absent from Base): game covers on, fastmem from device capability, fast disc, DSP thread, EFB/XFB skip, immediate XFB, texture cache 0, EFB format changes, VI skip mode Auto, shader thread counts, wait-for-shaders, async present, Internal Resolution 1×. "Default (effective)" in the tables shows compiled default and, after "→ seed", the first-run value.
- **Live vs restart.** The only classification in code is `DOLSettingsKeyBridge`'s `hotSwappable` flag (a debug-API table that says in its own comment it is inferred from Dolphin semantics and was not verified against the running backend, DOLSettingsKeyBridge.mm:150-185). Column "Live / restart": `live*`/`boot*` = from that table; "next boot (caption)" = the row's own caption says so; `n/c` = not classified anywhere in code (the answer needs a device).
- **Reset.** "Reset All Settings" = `DOLConfigBridge.resetAllToDefaults` = `resetGameplayConfigKeys` + `resetGameplayUserDefaults` + `Config::Save` (DOLConfigBridge.mm:1583-1592). It deletes the listed Config keys from CurrentRun, LocalGame, GlobalGame **and Base**, forces the iCube values for fast disc, DSP thread, immediate XFB, wait-for-shaders, texture cache, fastmem, and deletes ten UserDefaults keys plus the per-game adaptive-clock keys. It deliberately leaves RetroAchievements, DSU, controller assignments, input prefs, SYSCONF, `MAIN_WII_*`, GameCube language, library/recording/shader/motion/stick UserDefaults. `check_settings_wiring.py` (run on this commit) reports 200 UI-writable Config keys, 165 reset-covered, 19 exact + 4 prefix preserved: "OK". The earlier audit's note that the linter misreports CIR keys as gaps no longer applies to this commit. Reset is reachable from: iPhone Settings toolbar ("Reset All"), About (all platforms, with confirmation).
- **Scope labels used below.** *synced* = lives in `Dolphin.ini`, `GFX.ini` or SYSCONF, which the iCloud engine mirrors whole-file (section 3). *device-local* = `UserDefaults`, Keychain or a non-synced file. *per-game* = `GameSettings/<id>.ini` or `game_profiles.json`. Numbers like `#11` refer to the rows of section 3.2. **No leaf shows its scope today.**

### 1.3 Tables

Column key: see "Column legend" at the top. Rows with no Config/UD persistence (actions, destinations, captions) say so. `n/c` = not classified in code.

### 1.3.1 General

#### General (`general`)
Platforms: all. APPSTORE: same. `Default ISO` opens `DefaultISOSettingsView` (clear action; tvOS adds Done).

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Default ISO (`default-iso`) | destination |  | none | UD `icube.defaultISO.localSelection` (sandbox-relative record); set on CurrentRun `MAIN_DEFAULT_ISO` at each boot by `prepareDefaultISOForBoot` (DOLConfigBridge.mm ~388-396) | next boot | not reset by Reset All (cleared by its own "Clear Default ISO") | device-local by design (DOLConfigBridge.mm:75-76) |
| Enable Dual Core (speedup) (`dual-core`) | toggle | on/off | true (compiled `DEFAULT_CPU_THREAD`, Apple); the state placeholder is false until `sync()` | `MAIN_CPU_THREAD` Dolphin.ini [Core] CPUThread (SetBaseOrCurrent) | boot* | Reset All | synced |
| DSP Thread (speedup) (`dsp-thread`) | toggle | on/off | false → seed true | `MAIN_DSP_THREAD` Dolphin.ini [DSP] DSPThread (SetBaseOrCurrent) | boot* | Reset All | synced |
| Enable Cheats (`cheats`) — per-game cheat lists are in the pause menu and live in `GameSettings/<id>.ini` | toggle | on/off | false | `MAIN_ENABLE_CHEATS` Dolphin.ini [Core] EnableCheats (SetBaseOrCurrent) | n/c | Reset All | synced |
| Override Region Mismatch (`override-region`) | toggle | on/off | false | `MAIN_OVERRIDE_REGION_SETTINGS` Dolphin.ini [Core] OverrideRegionSettings (SetBaseOrCurrent) | n/c | Reset All | synced |
| Auto Disc Change (`auto-disc-change`) | toggle | on/off | false | `MAIN_AUTO_DISC_CHANGE` Dolphin.ini [Core] AutoDiscChange (SetBase) | n/c | Reset All | synced |
| Fast Disc Speed (speedup) (`fast-disc-speed`) — seeded ON; a shipped game INI can override it (see `Data/Sys/GameSettings/GMSE04.ini`) | toggle | on/off | false → seed true | `MAIN_FAST_DISC_SPEED` Dolphin.ini [Core] FastDiscSpeed (SetBaseOrCurrent) | n/c | Reset All | synced |
| Resume Where I Left Off (`resume-where-left-off`) | toggle | on/off | false (unset) | UD `resume_where_left_off` (read by SaveStateService, TVEmulationBridge.mm) | next quit/launch | not reset | device-local |
| Speed Limit (`speed-limit`) | cycle | Unlimited, then 10…200 % step 10 (a stored value off the ladder is appended) | 100 % | `MAIN_EMULATION_SPEED` Dolphin.ini [Core] EmulationSpeed (SetBaseOrCurrent) | live* | Reset All | synced |
| Fast Forward Speed (`fast-forward-speed`) | cycle | 0 (Unlimited), 200, 300, 400, 500, 600, 800, 1000 % | 300 % | UD `fast_forward_speed_percent` (read by TVEmulationBridge.mm and the pause menu) | live (read when fast-forward engages) | Reset All | device-local |
| Fallback Region (`fallback-region`) | cycle | NTSC-J, NTSC-U, PAL, NTSC-K | locale-derived (`GetDefaultRegion()`); an invalid stored value is rewritten on appear (`seedFallbackRegion`) | `MAIN_FALLBACK_REGION` Dolphin.ini [Core] FallbackRegion (SetBaseOrCurrent) | next boot (caption) | Reset All | synced |

#### Interface (`interface`)
iOS-only rows are marked. Background Style is dead on tvOS (F8).

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Use Built-In Database of Game Names (`names-db`) | toggle | on/off | true | `MAIN_USE_BUILT_IN_TITLE_DATABASE` Dolphin.ini [Interface] UseBuiltinTitleDatabase (SetBaseOrCurrent) | n/c | not reset | synced |
| Download Game Covers from GameTDB.com for Use in Grid Mode (`covers`) | toggle | on/off | false compiled; first-run seed true | `MAIN_USE_GAME_COVERS` Dolphin.ini [General] UseGameCovers (SetBaseOrCurrent) | n/c | not reset | synced |
| Background Style (`background-style`) | cycle | Clean, GameCube Gradient, Animated (Full Effects) | .animated (LibraryBackgroundStyle.default) | UD `library_background_style` | n/c | not reset | device-local; **no effect on tvOS** (see Findings F8) |
| Show Game ID Subtitles (`show-subtitles`) | toggle | on/off | true (unset; helper storedShowSubtitles) | UD `library_show_subtitles` | n/c | not reset | device-local |
| Show Patched Versions as Separate Library Items (`show-patched-separately`) | toggle | on/off | true (unset; helper storedShowPatchedSeparately) | UD `library_show_patched_separately` | n/c | not reset | device-local |
| Confirm on Stop (`confirm-on-stop`) | toggle | on/off | true | `MAIN_CONFIRM_ON_STOP` Dolphin.ini [Interface] ConfirmStop (SetBaseOrCurrent) | n/c | not reset | synced |
| Use Panic Handlers (`panic-handlers`) | toggle | on/off | true | `MAIN_USE_PANIC_HANDLERS` Dolphin.ini [Interface] UsePanicHandlers (SetBaseOrCurrent) | n/c | not reset | synced |
| Show On-Screen Display Messages (`osd-messages`) | toggle | on/off | true | `MAIN_OSD_MESSAGES` Dolphin.ini [Interface] OnScreenDisplayMessages (SetBaseOrCurrent) | n/c | not reset | synced |
| Recording Watermark (`recording-watermark`) | toggle | on/off | true (unset; helper storedRecordingWatermark) | UD `recording_watermark` | n/c | not reset | device-local |
| Camera Overlay (`recording-camera`) — iOS only | toggle | on/off | false (unset) | UD `recording_camera_overlay` | n/c | not reset | device-local; **row has no reader** (Findings F7) |
| Show mature skins (`show-mature-skins`) — iOS only | toggle | on/off | false (unset) | UD `skin_store_show_mature_skins` | n/c | not reset | device-local |

#### Advanced (`advanced`)
Memory override steppers are enabled only while the override toggle is on; values are stored in bytes via `mainMem1SizeMB`.

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Enable Emulated Memory Size Override (`mem-override`) | toggle | on/off | false | `MAIN_RAM_OVERRIDE_ENABLE` Dolphin.ini [Core] RAMOverrideEnable (SetBaseOrCurrent) | boot* | Reset All | synced |
| MEM1 (`mem1`) | stepper | 24…64 step 1 | 24 MB (retail) | `MAIN_MEM1_SIZE` Dolphin.ini [Core] MEM1Size (SetBaseOrCurrent) | boot (RAM override read at boot) | Reset All | synced |
| MEM2 (`mem2`) | stepper | 64…128 step 1 | 64 MB (retail) | `MAIN_MEM2_SIZE` Dolphin.ini [Core] MEM2Size (SetBaseOrCurrent) | boot (RAM override read at boot) | Reset All | synced |
| Enable Custom RTC (`rtc-enabled`) | toggle | on/off | false | `MAIN_CUSTOM_RTC_ENABLE` Dolphin.ini [Core] EnableCustomRTC (SetBaseOrCurrent) | n/c | Reset All | synced |
| Date and Time (`rtc-date`) — iOS only (tvOS has no DatePicker) | custom (DatePicker) | any date | 2000-01-01 UTC (946684800 s) in the view; compiled default `(30*365+7)*86400` s = 2000-01-01 | `MAIN_CUSTOM_RTC_VALUE` Dolphin.ini [Core] CustomRTCValue (SetBaseOrCurrent) | n/c | Reset All | synced |

### 1.3.2 Graphics

#### Video (`graphics-video`)
iOS-only rows are marked. Backend has two copies (F9). Overscan row: external display on iOS, the TV on tvOS.

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Backend (`backend`) | cycle | Metal, OpenGL, Vulkan (all three always listed) | Metal (first-run seed `FirstRunInitializationService.mm:56`); compiled default: the platform's default backend (`VideoBackendBase::GetDefaultBackendConfigName()`) | `MAIN_GFX_BACKEND` Dolphin.ini [Core] GFXBackend (SetBaseOrCurrent) **and** UD `ui_gfx_backend` mirror; the row displays the UD copy first (Findings F9) | boot* (backend read at boot) | Reset All (both copies) | synced, device-bound #12 (Config copy); UD copy device-local |
| Aspect Ratio (`aspect-ratio`) | cycle | Auto, Stretch to Window, 4:3, 16:9 (raw 0,3,2,1) | Auto | `GFX_ASPECT_RATIO` GFX.ini [Settings] AspectRatio (SetBaseOrCurrent) | n/c | Reset All | synced |
| V-Sync (`vsync`) | toggle | on/off | false (compiled; no seed). The caption says "leave ON" (Findings F13) | `GFX_VSYNC` GFX.ini [Hardware] VSync (SetBaseOrCurrent) | live* | Reset All | synced |
| Triple Buffering (`triple-buffering`) | toggle | on/off | true (unset) | UD `gfx_triple_buffering` | n/c | Reset All | device-local |
| Force scale 1.0 on non‑ProMotion (`force-scale-one`) | toggle | on/off | false (unset) | UD `gfx_force_scale_one_non_promo` | n/c | Reset All | device-local |
| Full screen (disable overscan compensation) (`overscan-fullscreen`) | toggle | on/off | false (unset) | UD `gfx_overscan_fullscreen`, written through `EmulationCoordinator setOverscanFullscreenEnabled:` which also applies it (EmulationCoordinator.mm:445-449) | live (only while an external display is connected on iOS; the TV on tvOS) | not reset | device-local |
| Asynchronous Present (`async-present`) | toggle | on/off | true (Apple arm64) | `GFX_ASYNC_PRESENT` GFX.ini [Settings] AsyncPresent (SetBaseOrCurrent) | n/c | Reset All | synced |
| Frame Rate Cap (`frame-cap`) — iOS only | cycle | System Default (0), 30, 60, 90, 120 (+ a stored off-ladder value) | 0 (unset) | UD `ui_frame_cap` | n/c | Reset All | device-local; iOS only (applied by MainDisplaySceneDelegate) |
| Enable ReplayKit Instant Replay (`instant-replay`) — iOS only (Recording section) | toggle | on/off | false (unset) | UD `replaykit_instant_replay_enabled` | n/c | not reset | device-local |
| Save Clips to Photos (`save-clips-photos`) — iOS only | toggle | on/off | false (unset) | UD `replaykit_save_to_photos` | n/c | not reset | device-local |
| Save Only to Photos (`save-only-photos`) — iOS only | toggle | on/off | false (unset) | UD `replaykit_save_only_photos` | n/c | not reset | device-local |
| Clip Length (`clip-length`) — iOS only | cycle | 5, 10, 15, 30 s | 15 s | UD `replaykit_clip_seconds` | n/c | not reset | device-local |
| Type (`shader-compile-type`) | cycle | Specialized, Exclusive Ubershaders, Hybrid Ubershaders, Skip Drawing | Hybrid Ubershaders (iOS/tvOS compile) | `GFX_SHADER_COMPILATION_MODE` GFX.ini [Settings] ShaderCompilationMode (SetBaseOrCurrent) | boot* | Reset All | synced |
| Compile shaders before starting (`compile-before-start`) | toggle | on/off | false → seed true | `GFX_WAIT_FOR_SHADERS_BEFORE_STARTING` GFX.ini [Settings] WaitForShadersBeforeStarting (SetBaseOrCurrent) | boot* | Reset All | synced |

#### Enhancements (`graphics-enhancements`)
Internal Resolution is the only row that is **SetBase** and carries an override badge (game INI or adaptive owner).

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Internal Resolution (`efb-scale`) | cycle | 1× (Native) up to the backend max (`GFX_MAX_EFB_SCALE`, 6 in the placeholder); auto-fit is not offered | 1× (seed) | `GFX_EFB_SCALE` GFX.ini [Settings] InternalResolution (**SetBase**, always Base) | live* | Reset All | synced |
| MetalFX Upscaling (`metalfx-upscale`) | toggle | on/off | false | `GFX_MTL_METALFX_SPATIAL_UPSCALE` GFX.ini [Settings] MetalFXSpatialUpscale (SetBaseOrCurrent) | live* | Reset All | synced |
| Anisotropic Filtering (`anisotropy`) | cycle | 1×, 2×, 4×, 8×, 16× (stored as exponent 0…4) | 4× | `GFX_ENHANCE_MAX_ANISOTROPY` GFX.ini [Enhancements] MaxAnisotropy (SetBaseOrCurrent) | live* (key table: `gfxEnhanceAnisotropySamples`) | Reset All | synced |
| Anti-Aliasing (MSAA) (`msaa`) | cycle | None, 2×, 4×, 8× | 1 | `GFX_MSAA` GFX.ini [Settings] MSAA (SetBaseOrCurrent) | n/c | Reset All | synced |
| Supersampling (SSAA) (`ssaa`) | toggle | on/off | false | `GFX_SSAA` GFX.ini [Settings] SSAA (SetBaseOrCurrent) | n/c | Reset All | synced |
| Output Resampling (`output-resampling`) | cycle | Standard, Bilinear, B-Spline, Mitchell-Netravali, Catmull-Rom, Sharp Bilinear, Area Sampling | Standard | `GFX_ENHANCE_OUTPUT_RESAMPLING` GFX.ini [Enhancements] OutputResampling (SetBaseOrCurrent) | n/c | Reset All | synced |
| Force 24-bit Color (`true-color`) | toggle | on/off | true | `GFX_ENHANCE_FORCE_TRUE_COLOR` GFX.ini [Enhancements] ForceTrueColor (SetBaseOrCurrent) | n/c | Reset All | synced |
| Disable Copy Filter (`disable-copy-filter`) | toggle | on/off | true | `GFX_ENHANCE_DISABLE_COPY_FILTER` GFX.ini [Enhancements] DisableCopyFilter (SetBaseOrCurrent) | n/c | Reset All | synced |
| Widescreen Hack (`widescreen-hack`) | toggle | on/off | false | `GFX_WIDESCREEN_HACK` GFX.ini [Settings] wideScreenHack (SetBaseOrCurrent) | live* | Reset All | synced |
| HDR Output (`hdr-output`) | toggle | on/off | false | `GFX_ENHANCE_HDR_OUTPUT` GFX.ini [Enhancements] HDROutput (SetBaseOrCurrent) | n/c | Reset All | synced |
| GPU Texture Decoding (`gpu-texture-decoding`) | toggle | on/off | false | `GFX_ENABLE_GPU_TEXTURE_DECODING` GFX.ini [Settings] EnableGPUTextureDecoding (SetBaseOrCurrent) | n/c | Reset All | synced |
| Disable Fog (`disable-fog`) | toggle | on/off | false | `GFX_DISABLE_FOG` GFX.ini [Settings] DisableFog (SetBaseOrCurrent) | live* | Reset All | synced |
| Arbitrary Mipmap Detection (`arbitrary-mipmap`) | toggle | on/off | true | `GFX_ENHANCE_ARBITRARY_MIPMAP_DETECTION` GFX.ini [Enhancements] ArbitraryMipmapDetection (SetBaseOrCurrent) | n/c | Reset All | synced |
| Mipmap Detection Threshold (`arbitrary-mipmap-threshold`) | stepper | 0.0…30.0 step 0.1 | 14.0 | `GFX_ENHANCE_ARBITRARY_MIPMAP_DETECTION_THRESHOLD` GFX.ini [Enhancements] ArbitraryMipmapDetectionThreshold (SetBaseOrCurrent) | n/c | Reset All | synced |

#### Hacks (`graphics-hacks`)
All rows BoC; none appear in the Reset exemptions.

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Texture Cache Accuracy (`texture-cache`) | cycle | Safe (512), Default (128), Fast (0) samples | 128 compiled; first-run seed 0 (Fast) | `GFX_SAFE_TEXTURE_CACHE_COLOR_SAMPLES` GFX.ini [Settings] SafeTextureCacheColorSamples (SetBaseOrCurrent) | n/c | Reset All | synced |
| Bounding Box Emulation (`bbox`) | toggle | on/off | false | `GFX_HACK_BBOX_ENABLE` GFX.ini [Hacks] BBoxEnable (SetBaseOrCurrent) | n/c | Reset All | synced |
| Bounding Box Sync (`bbox-sync`) | cycle | Latched, Force Sync | 0 | `GFX_BBOX_SYNC_MODE` GFX.ini [Settings] BBoxSyncMode (SetBaseOrCurrent) | n/c | Reset All | synced |
| Enable EFB Access (`efb-access`) | toggle | on/off | false | `GFX_HACK_EFB_ACCESS_ENABLE` GFX.ini [Hacks] EFBAccessEnable (SetBaseOrCurrent) | n/c | Reset All | synced |
| Skip EFB Copy to RAM (`skip-efb-ram`) | toggle | on/off | true → seed true | `GFX_HACK_SKIP_EFB_COPY_TO_RAM` GFX.ini [Hacks] EFBToTextureEnable (SetBaseOrCurrent) | live* | Reset All | synced |
| Skip XFB Copy to RAM (`skip-xfb-ram`) | toggle | on/off | true → seed true | `GFX_HACK_SKIP_XFB_COPY_TO_RAM` GFX.ini [Hacks] XFBToTextureEnable (SetBaseOrCurrent) | live* | Reset All | synced |
| Immediate XFB (`immediate-xfb`) | toggle | on/off | false → seed true | `GFX_HACK_IMMEDIATE_XFB` GFX.ini [Hacks] ImmediateXFBEnable (SetBaseOrCurrent) | n/c | Reset All | synced |
| Copy EFB Scaled (`copy-efb-scaled`) | toggle | on/off | true | `GFX_HACK_COPY_EFB_SCALED` GFX.ini [Hacks] EFBScaledCopy (SetBaseOrCurrent) | n/c | Reset All | synced |
| Early XFB Output (`early-xfb`) | toggle | on/off | true | `GFX_HACK_EARLY_XFB_OUTPUT` GFX.ini [Hacks] EarlyXFBOutput (SetBaseOrCurrent) | n/c | Reset All | synced |
| Skip Duplicate XFBs (`skip-duplicate-xfb`) | toggle | on/off | true | `GFX_HACK_SKIP_DUPLICATE_XFBS` GFX.ini [Hacks] SkipDuplicateXFBs (SetBaseOrCurrent) | n/c | Reset All | synced |
| Emulate EFB Format Changes (`efb-format-changes`) | toggle | on/off | false → seed true | `GFX_HACK_EFB_EMULATE_FORMAT_CHANGES` GFX.ini [Hacks] EFBEmulateFormatChanges (SetBaseOrCurrent) | n/c | Reset All | synced |
| Vertex Rounding (`vertex-rounding`) | toggle | on/off | false | `GFX_HACK_VERTEX_ROUNDING` GFX.ini [Hacks] VertexRounding (SetBaseOrCurrent) | n/c | Reset All | synced |
| Force Progressive Scan (`force-progressive`) | toggle | on/off | true | `GFX_HACK_FORCE_PROGRESSIVE` GFX.ini [Hacks] ForceProgressive (SetBaseOrCurrent) | n/c | Reset All | synced |
| Defer EFB Copies (`defer-efb-copies`) | toggle | on/off | true | `GFX_HACK_DEFER_EFB_COPIES` GFX.ini [Hacks] DeferEFBCopies (SetBaseOrCurrent) | n/c | Reset All | synced |
| VI Skip Mode (`vi-skip`) | cycle | Off, On, Auto | Auto (Apple compiled; also seeded) | `GFX_HACK_VI_SKIP_MODE` GFX.ini [Hacks] VISkipMode (SetBaseOrCurrent) | n/c | Reset All | synced |
| Fast Texture Sampling (`fast-texture-sampling`) | toggle | on/off | true | `GFX_HACK_FAST_TEXTURE_SAMPLING` GFX.ini [Hacks] FastTextureSampling (SetBaseOrCurrent) | n/c | Reset All | synced |
| Fast Math (Metal Shaders) (`fast-math`) | toggle | on/off | true | `GFX_HACK_FAST_MATH` GFX.ini [Hacks] FastMath (SetBaseOrCurrent) | live* | Reset All | synced |
| Use Compute for EFB/XFB (`compute-efb-xfb`) | toggle | on/off | false | `GFX_USE_COMPUTE_EFBXFB` GFX.ini [Hacks] UseComputeEfbXfb (SetBaseOrCurrent) | next boot (caption) | Reset All | synced |
| Use Compute for Vertex Decode (`compute-vertex-decode`) | toggle | on/off | false | `GFX_USE_COMPUTE_VERTEX_DECODE` GFX.ini [Hacks] UseComputeVertexDecode (SetBaseOrCurrent) | next boot (caption) | Reset All | synced |
| No Mipmapping (iOS) (`no-mipmapping`) | toggle | on/off | false | `GFX_HACK_NO_MIPMAPPING` GFX.ini [Hacks] NoMipmapping (SetBaseOrCurrent) | n/c | Reset All | synced |
| Interlaced Field Decimation (`vi-decimate-interlace`) | toggle | on/off | false | `GFX_HACK_VI_DECIMATE_INTERLACE` GFX.ini [Hacks] VIDecimateInterlace (SetBaseOrCurrent) | n/c | Reset All | synced |

#### Graphics Advanced (`graphics-advanced`)
Includes the performance-statistics overlays (not reset, cosmetic), debugging switches, texture-pack and Metal options. `Progressive Scan` is a Wii SYSCONF key living on this Graphics page (F17).

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Compiler Threads (`compiler-threads`) | stepper | 1…(cores−1), min range 1…1 on ≤2-core devices (slider hidden; see "Checked, no defect found") | 1 → seed min(2,cores-1) | `GFX_SHADER_COMPILER_THREADS` GFX.ini [Settings] ShaderCompilerThreads (SetBaseOrCurrent) | n/c | Reset All | synced, device-bound #11 |
| Precompiler Threads (`precompiler-threads`) | stepper | 1…(cores−1) | −1 compiled (auto) → seed min(2, cores−1) | `GFX_SHADER_PRECOMPILER_THREADS` GFX.ini [Settings] ShaderPrecompilerThreads (SetBaseOrCurrent) | n/c | Reset All | synced, device-bound #11 |
| Texture-pack memory warning (`texture-pack-warning`) | custom (read-only warning, shown when hi-res textures + prefetch are on and the pack is too large for physical memory) |  | — | — | — | — | — |
| Use Present Drawable (`use-present-drawable`) | cycle | Auto, Off, On | Auto | `GFX_MTL_USE_PRESENT_DRAWABLE` GFX.ini [Settings] MTLUsePresentDrawable (SetBaseOrCurrent) | n/c | Reset All | synced |
| Manually Upload Buffers (`manually-upload-buffers`) | cycle | Auto, Off, On | Auto | `GFX_MTL_MANUALLY_UPLOAD_BUFFERS` GFX.ini [Settings] ManuallyUploadBuffers (SetBaseOrCurrent) | n/c | Reset All | synced |
| Show FPS (`show-fps`) | toggle | on/off | false | `GFX_SHOW_FPS` GFX.ini [Settings] ShowFPS (SetBaseOrCurrent) | live* | not reset | synced |
| Show VPS (`show-vps`) | toggle | on/off | false | `GFX_SHOW_VPS` GFX.ini [Settings] ShowVPS (SetBaseOrCurrent) | n/c | not reset | synced |
| Show Speed (`show-speed`) | toggle | on/off | false | `GFX_SHOW_SPEED` GFX.ini [Settings] ShowSpeed (SetBaseOrCurrent) | n/c | not reset | synced |
| Show Frame Times (`show-frame-times`) | toggle | on/off | false | `GFX_SHOW_FTIMES` GFX.ini [Settings] ShowFTimes (SetBaseOrCurrent) | n/c | not reset | synced |
| Show VBlank Times (`show-vblank-times`) | toggle | on/off | false | `GFX_SHOW_VTIMES` GFX.ini [Settings] ShowVTimes (SetBaseOrCurrent) | n/c | not reset | synced |
| Show Graphs (`show-graphs`) | toggle | on/off | false | `GFX_SHOW_GRAPHS` GFX.ini [Settings] ShowGraphs (SetBaseOrCurrent) | n/c | not reset | synced |
| Log Render Time to File (`log-render-time`) | toggle | on/off | false | `GFX_LOG_RENDER_TIME_TO_FILE` GFX.ini [Settings] LogRenderTimeToFile (SetBaseOrCurrent) | n/c | not reset | synced |
| Speed Colors (`speed-colors`) | toggle | on/off | true | `GFX_SHOW_SPEED_COLORS` GFX.ini [Settings] ShowSpeedColors (SetBaseOrCurrent) | n/c | not reset | synced |
| Overlay Stats (`overlay-stats`) | toggle | on/off | false | `GFX_OVERLAY_STATS` GFX.ini [Settings] OverlayStats (SetBaseOrCurrent) | n/c | not reset | synced |
| API Validation Layer (`api-validation-layer`) | toggle | on/off | false | `GFX_ENABLE_VALIDATION_LAYER` GFX.ini [Settings] EnableValidationLayer (SetBaseOrCurrent) | n/c | not reset | synced |
| Load Custom Textures (`load-custom-textures`) | toggle | on/off | true | `GFX_HIRES_TEXTURES` GFX.ini [Settings] HiresTextures (SetBaseOrCurrent) | n/c | Reset All | synced |
| Prefetch Custom Textures (`prefetch-custom-textures`) | toggle | on/off | true | `GFX_CACHE_HIRES_TEXTURES` GFX.ini [Settings] CacheHiresTextures (SetBaseOrCurrent) | n/c | Reset All | synced |
| Disable EFB Copy to VRAM (`disable-efb-copy-to-vram`) | toggle | on/off | false | `GFX_HACK_DISABLE_COPY_TO_VRAM` GFX.ini [Hacks] DisableCopyToVRAM (SetBaseOrCurrent) | n/c | Reset All | synced |
| Enable Graphics Mods (`graphics-mods`) | toggle | on/off | true | `GFX_MODS_ENABLE` GFX.ini [Settings] EnableMods (SetBaseOrCurrent) | n/c | Reset All | synced |
| Crop (`crop`) | toggle | on/off | false | `GFX_CROP_TO_ASPECT_RATIO` GFX.ini [Settings] Crop (SetBaseOrCurrent) | n/c | Reset All | synced |
| Progressive Scan (`progressive-scan`) | toggle | on/off | true | `SYSCONF_PROGRESSIVE_SCAN` SYSCONF [IPL] PGS (SetBaseOrCurrent) | n/c | not reset | synced via SYSCONF (Wii save category) |
| Fast Depth Calculation (`fast-depth`) | toggle | on/off | true | `GFX_FAST_DEPTH_CALC` GFX.ini [Settings] FastDepthCalc (SetBaseOrCurrent) | n/c | Reset All | synced |
| Per-Pixel Lighting (`per-pixel-lighting`) | toggle | on/off | false | `GFX_ENABLE_PIXEL_LIGHTING` GFX.ini [Settings] EnablePixelLighting (SetBaseOrCurrent) | n/c | Reset All | synced |
| Backend Multithreading (`backend-multithreading`) | toggle | on/off | true | `GFX_BACKEND_MULTITHREADING` GFX.ini [Settings] BackendMultithreading (SetBaseOrCurrent) | boot* | Reset All | synced |
| Enable Shader Cache (`shader-cache`) | toggle | on/off | true | `GFX_SHADER_CACHE` GFX.ini [Settings] ShaderCache (SetBaseOrCurrent) | boot* | Reset All | synced |
| Save Texture Cache to State (`save-texture-cache-to-state`) | toggle | on/off | true | `GFX_SAVE_TEXTURE_CACHE_TO_STATE` GFX.ini [Settings] SaveTextureCacheToState (SetBaseOrCurrent) | n/c | Reset All | synced |
| Prefer Vertex Shader for Line/Point Expansion (`prefer-vs-for-lines`) | toggle | on/off | false | `GFX_PREFER_VS_FOR_LINE_POINT_EXPANSION` GFX.ini [Settings] PreferVSForLinePointExpansion (SetBaseOrCurrent) | n/c | Reset All | synced |
| CPU Culling (`cpu-culling`) | toggle | on/off | false | `GFX_CPU_CULL` GFX.ini [Settings] CPUCull (SetBaseOrCurrent) | live* | Reset All | synced |
| Defer EFB Cache Invalidation (`defer-efb-invalidation`) | toggle | on/off | false | `GFX_HACK_EFB_DEFER_INVALIDATION` GFX.ini [Hacks] EFBAccessDeferInvalidation (SetBaseOrCurrent) | n/c | Reset All | synced |

#### Shaders (`shaders`)
Hand-built leaf (no menu model): its rows cannot be found by search.

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Enable Shader (`enabled`) | toggle | on/off | false (unset) | UD `shader_enabled` | live (posts `DOLShaderSettingsDidChange`) | not reset | device-local |
| Preset (`preset`) | destination (picker, favorites, recents) | bundled slang/native-metal presets | none | UD `shader_preset_path` (bundle-relative via `ShaderLibrary.normalizedPath`); favorites `shader_favorites`, recents `shader_mru`; **also** `GameProfile.shaderPresetPath` per game | live | not reset (`GameProfiles.clearProfile` removes the path) | device-local; per-game copy synced (game_profiles.json) |
| Flip vertically (`flip`) | toggle | on/off | false | UD `shader_flip_vertical` | live | not reset | device-local |
| Enable pre-copy (compat) (`precopy`) | toggle | on/off | false | UD `shader_precopy_enabled` (`@AppStorage`) | n/c | not reset | device-local |
| Shader Debug Tools (`debug-tools`) — DEBUG builds only | destination | — | — | — | — | n/a | device-local |

### 1.3.3 Audio

#### Audio (`audio`)
Rows `echo`..`crush-downsample` also appear in the pause menu Effect Settings. Spatial rows are enabled only for surround + AVAudioEngine.

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Audio Backend (`backend`) | picker | AVAudioEngine, CoreAudio (`DOLConfigBridge audioBackends`) | platform default (`GetDefaultSoundBackend()`) | `MAIN_AUDIO_BACKEND` Dolphin.ini [DSP] Backend (SetBaseOrCurrent) | n/c | Reset All | synced |
| Volume (`volume`) | stepper | 0…100 step 1 | 100 | `MAIN_AUDIO_VOLUME` Dolphin.ini [DSP] Volume (SetBaseOrCurrent) | live* | Reset All | synced |
| Surround Sound (`surround`) | toggle | on/off | false | `MAIN_DPL2_DECODER` Dolphin.ini [Core] DPL2Decoder (SetBaseOrCurrent) | n/c | Reset All | synced |
| Decoder Quality (`surround-quality`) | picker | Lowest, Low, High, Highest | `GetDefaultDPL2Quality()` | `MAIN_DPL2_QUALITY` Dolphin.ini [Core] DPL2Quality (SetBaseOrCurrent) | n/c | Reset All | synced |
| Spatial Audio on Headphones (`spatial`) | toggle | on/off | true | `MAIN_AUDIO_SPATIAL` Dolphin.ini [iOS] AudioSpatial (SetBaseOrCurrent) | live (needs AVAudioEngine + surround on) | Reset All | synced |
| Head Tracking (`head-tracking`) | toggle | on/off | true | `MAIN_AUDIO_SPATIAL_HEAD_TRACKING` Dolphin.ini [iOS] AudioSpatialHeadTracking (SetBaseOrCurrent) | n/c | Reset All | synced |
| Audio Buffer Size (`buffer`) | stepper | 16…200 step 1 | 80 | `MAIN_AUDIO_BUFFER_SIZE` Dolphin.ini [Core] AudioBufferSize (SetBaseOrCurrent) | n/c | Reset All | synced |
| Fill Audio Gaps (`fill-gaps`) | toggle | on/off | true | `MAIN_AUDIO_FILL_GAPS` Dolphin.ini [Core] AudioFillGaps (SetBaseOrCurrent) | n/c | Reset All | synced |
| Preserve Pitch (`preserve-pitch`) | toggle | on/off | false | `MAIN_AUDIO_PRESERVE_PITCH` Dolphin.ini [Core] AudioPreservePitch (SetBaseOrCurrent) | n/c | Reset All | synced |
| Mute When Disabling Speed Limit (`mute-on-no-speed-limit`) | toggle | on/off | false | `MAIN_AUDIO_MUTE_ON_DISABLED_SPEED_LIMIT` Dolphin.ini [DSP] MuteOnDisabledSpeedLimit (SetBaseOrCurrent) | n/c | Reset All | synced |
| Use Mute Hardware Switch (`obey-mute-switch`) — iOS only | toggle | on/off | off (stored 0; the row shows ON when the stored value is non-zero) | `MAIN_MUTE_SWITCH_MODE` Dolphin.ini [iOS] MuteSwitchMode (SetBaseOrCurrent) | live (session category re-applied) | Reset All | synced |
| Echo (`echo`) | toggle | on/off | false | `MAIN_AUDIO_FX_DELAY_ENABLED` Dolphin.ini [iOS] AudioFXDelayEnabled (SetBaseOrCurrent) | n/c | Reset All | synced |
| Echo Time (`echo-time`) | stepper | 10…2000 step 10 | 200 | `MAIN_AUDIO_FX_DELAY_MS` Dolphin.ini [iOS] AudioFXDelayMs (SetBaseOrCurrent) | n/c | Reset All | synced |
| Echo Feedback (`echo-feedback`) | stepper | 0…0.95 step 0.05 | 0.35f | `MAIN_AUDIO_FX_DELAY_FEEDBACK` Dolphin.ini [iOS] AudioFXDelayFeedback (SetBaseOrCurrent) | n/c | Reset All | synced |
| Equalizer (`eq`) | toggle | on/off | false | `MAIN_AUDIO_FX_EQ_ENABLED` Dolphin.ini [iOS] AudioFXEQEnabled (SetBaseOrCurrent) | n/c | Reset All | synced |
| Bass (`eq-low`) | stepper | -24…24 step 1 | 0.0f | `MAIN_AUDIO_FX_EQ_LOW_DB` Dolphin.ini [iOS] AudioFXEQLowDb (SetBaseOrCurrent) | n/c | Reset All | synced |
| Mids (`eq-mid`) | stepper | -24…24 step 1 | 0.0f | `MAIN_AUDIO_FX_EQ_MID_DB` Dolphin.ini [iOS] AudioFXEQMidDb (SetBaseOrCurrent) | n/c | Reset All | synced |
| Treble (`eq-high`) | stepper | -24…24 step 1 | 0.0f | `MAIN_AUDIO_FX_EQ_HIGH_DB` Dolphin.ini [iOS] AudioFXEQHighDb (SetBaseOrCurrent) | n/c | Reset All | synced |
| Bitcrusher (`bitcrusher`) | toggle | on/off | false | `MAIN_AUDIO_FX_CRUSH_ENABLED` Dolphin.ini [iOS] AudioFXCrushEnabled (SetBaseOrCurrent) | n/c | Reset All | synced |
| Bit Depth (`crush-bits`) | stepper | 4…16 step 1 | 16 | `MAIN_AUDIO_FX_CRUSH_BITS` Dolphin.ini [iOS] AudioFXCrushBits (SetBaseOrCurrent) | n/c | Reset All | synced |
| Downsample (`crush-downsample`) | stepper | 1…16 step 1 | 1 | `MAIN_AUDIO_FX_CRUSH_DOWNSAMPLE` Dolphin.ini [iOS] AudioFXCrushDownsample (SetBaseOrCurrent) | n/c | Reset All | synced |
| Audio Unit Plug-ins (`plugin-chain`) — iOS only, AVAudioEngine only | custom (FXChainEditor) | ordered list of AUs | empty | `MAIN_AUDIO_AU_CHAIN` Dolphin.ini [iOS] AudioAUChain (string of Audio Unit descriptors) | n/c | Reset All | synced, device-bound #12 |
| Microphone permission rows (`microphone-*`) — iOS only | action / caption | — | — | iOS system permission (TCC), not stored by the app | immediate | n/a | device-local (system) |

### 1.3.4 GameCube & Wii

#### GameCube (`console-gamecube`)
Microphone row iOS only.

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Load GameCube Main Menu (`load-main-menu`) | toggle | on/off | true | `MAIN_SKIP_IPL` Dolphin.ini [Core] SkipIPL (SetBaseOrCurrent) | n/c | Reset All | synced |
| System Language (`language`) | cycle | English, German, French, Spanish, Italian, Dutch | `GetDefaultGameCubeLanguage()` (locale) | `MAIN_GC_LANGUAGE` Dolphin.ini [Core] SelectedLanguage (SetBaseOrCurrent) | n/c | not reset (identity) | synced |
| Microphone in Slot B (`slot-b-microphone`) — iOS only | toggle | on/off | off (slot B empty) | `MAIN_SLOT_B` Dolphin.ini [Core] SlotB (SetBaseOrCurrent) | next boot (caption: "Takes effect when a game starts") | Reset All only removes the microphone assignment (DOLConfigBridge.mm ~1272-1278) | synced |

#### Wii (`console-wii`)
SYSCONF rows apply when SYSCONF is next written/read at Wii boot.

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Use PAL60 Mode (EuRGB60) (`pal60`) — SYSCONF rows write the Base layer and reach the SYSCONF file on `Config::Save`; skipped while a Wii title controls SYSCONF (BaseConfigLoader.cpp:151-176) | toggle | on/off | true | `SYSCONF_PAL60` SYSCONF [IPL] E60 (SetBase) | n/c | not reset | synced via SYSCONF (Wii save category) |
| Aspect Ratio (`aspect-ratio`) | cycle | 4:3, 16:9 | 16:9 (true) | `SYSCONF_WIDESCREEN` SYSCONF [IPL] AR (SetBase) | n/c | not reset | synced via SYSCONF (Wii save category) |
| Enable Screen Saver (`screensaver`) | toggle | on/off | false | `SYSCONF_SCREENSAVER` SYSCONF [IPL] SSV (SetBase) | n/c | not reset | synced via SYSCONF (Wii save category) |
| System Language (`language`) | cycle | Japanese, English, German, French, Spanish, Italian, Dutch, Simplified Chinese, Traditional Chinese, Korean | locale-derived (`GetDefaultLanguage()`) | `SYSCONF_LANGUAGE` SYSCONF [IPL] LNG (SetBase) | n/c | not reset | synced via SYSCONF (Wii save category) |
| Audio Settings (`sound-mode`) | cycle | Mono, Stereo, Surround | Stereo (0x01) | `SYSCONF_SOUND_MODE` SYSCONF [IPL] SND (SetBase) | n/c | not reset | synced via SYSCONF (Wii save category) |
| Sensor Bar Position (`sensor-bar-position`) | cycle | Bottom, Top | Top (0x01) | `SYSCONF_SENSOR_BAR_POSITION` SYSCONF [BT] BAR (SetBase) | n/c | not reset | synced via SYSCONF (Wii save category) |
| Sensor Bar Sensitivity (`sensor-bar-sensitivity`) | stepper | 1…5 step 1 | 3 (0x03) | `SYSCONF_SENSOR_BAR_SENSITIVITY` SYSCONF [BT] SENS (SetBase) | n/c | not reset | synced via SYSCONF (Wii save category) |
| Speaker Volume (`speaker-volume`) | stepper | 0…7 (Findings F3: desktop Dolphin range is 0…127) | 88 (0x58) compiled; state placeholder 4 | `SYSCONF_SPEAKER_VOLUME` SYSCONF [BT] SPKV (SetBase) | n/c | not reset | synced via SYSCONF (Wii save category) |
| Rumble (`rumble`) | toggle | on/off | true | `SYSCONF_WIIMOTE_MOTOR` SYSCONF [BT] MOT (SetBase) | n/c | not reset | synced via SYSCONF (Wii save category) |
| Allow Touchpad IR Follow Without Click (`touchpad-ir-follow`) | toggle | on/off | false (unset) | UD `touchpad_ir_follow_without_click` | n/c | not reset | device-local; **no reader anywhere** (Findings F6) |
| Emulate Skylander Portal (`skylander-portal`) | toggle | on/off | false | `MAIN_EMULATE_SKYLANDER_PORTAL` Dolphin.ini [EmulatedUSBDevices] EmulateSkylanderPortal (SetBaseOrCurrent) | n/c | Reset All | synced |
| Connect USB Keyboard (`usb-keyboard`) | toggle | on/off | false | `MAIN_WII_KEYBOARD` Dolphin.ini [Core] WiiKeyboard (SetBaseOrCurrent) | n/c | not reset | synced |
| Enable WiiConnect24 via WiiLink (`wiilink`) | toggle | on/off | false | `MAIN_WII_WIILINK_ENABLE` Dolphin.ini [Core] EnableWiiLink (SetBase) | n/c | not reset | synced |
| Insert SD Card (`sd-card`) | toggle | on/off | true | `MAIN_WII_SD_CARD` Dolphin.ini [Core] WiiSDCard (SetBaseOrCurrent) | n/c | not reset | synced |
| Allow Writes to SD Card (`sd-writes`) | toggle | on/off | true | `MAIN_ALLOW_SD_WRITES` Dolphin.ini [Core] WiiSDCardAllowWrites (SetBase) | n/c | not reset | synced |
| Synchronize SD Card Folder on Start/Stop (`sd-folder-sync`) | toggle | on/off | false | `MAIN_WII_SD_CARD_ENABLE_FOLDER_SYNC` Dolphin.ini [Core] WiiSDCardEnableFolderSync (SetBase) | n/c | not reset | synced |
| Emulate Wii Speak (`wii-speak`) — iOS only | toggle | on/off | false | `MAIN_EMULATE_WII_SPEAK` Dolphin.ini [EmulatedUSBDevices] EmulateWiiSpeak (SetBaseOrCurrent) | next boot (caption) | Reset All | synced |
| Mute Wii Speak (`wii-speak-muted`) — iOS only | toggle | on/off | true | `MAIN_WII_SPEAK_MUTED` Dolphin.ini [EmulatedUSBDevices] WiiSpeakMuted (SetBaseOrCurrent) | n/c | Reset All | synced |
| Wii Speak Volume (`wii-speak-volume`) — iOS only | stepper | -50…50 step 1 | 0 | `MAIN_WII_SPEAK_VOLUME_MODIFIER` Dolphin.ini [EmulatedUSBDevices] WiiSpeakVolumeModifier (SetBaseOrCurrent) | n/c | Reset All | synced |

#### Achievements (`achievements`)
Hand-built leaf; credentials never enter Dolphin.ini.

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Enable Integration (`enabled`) | toggle | on/off | false | `RA_ENABLED` RetroAchievements.ini [Achievements] Enabled (Set via `setRaEnabled`) | n/c | not reset (identity) | device-local (file excluded from sync) |
| Hardcore Mode (`hardcore`) | toggle | on/off (needs Enable) | **true** compiled (`RA_HARDCORE_ENABLED`); the view starts at false until `sync()` | RetroAchievements.ini [Achievements] HardcoreEnabled | n/c | not reset | device-local (file excluded) |
| Spectator Mode (`spectator`) | toggle | on/off | false | RetroAchievements.ini [Achievements] SpectatorEnabled | n/c | not reset | device-local (file excluded) |
| Discord Presence (`discord`) | toggle | on/off | false | RetroAchievements.ini [Achievements] DiscordPresenceEnabled | n/c | not reset | device-local (file excluded) |
| Show Progress Popups (`progress`) | toggle | on/off | false compiled (the view `@State` default is true) | RetroAchievements.ini [Achievements] ProgressEnabled | n/c | not reset | device-local (file excluded) |
| Username | text field | free text | empty | `RA_USERNAME` RetroAchievements.ini [Achievements] Username | n/c | not reset | device-local (file excluded) |
| Password | secure text field | free text | empty | **never stored**: passed to `raLogin`, the server returns a token | immediate | n/a | n/a |
| Log In / Log Out | action | — | — | `RA_API_TOKEN` RetroAchievements.ini [Achievements] ApiToken (**credential**; cleared by `raLogout`) | immediate (0.5 s later `sync()`) | not reset | device-local (file excluded; filename-only guard, section 3) |
| Enable Unofficial / Encore Mode | toggle | on/off | false / false | RetroAchievements.ini UnofficialEnabled / EncoreEnabled | n/c | not reset | device-local (file excluded) |
| Server URL | text field | URL | empty (retroachievements.org) | `RA_HOST_URL` RetroAchievements.ini [Achievements] HostUrl | next login | not reset | device-local (file excluded) |

### 1.3.5 Controllers

#### Controllers hub (`controllers`)
Rows are generated from live device state, so none is in the search index. Port/device writes go through `ControllerHubWriting` (the "Plays as"/"Device" writers) and the controller mapping bridge.

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Player N (`player.id`) — one destination per bound port | destination | GC ports 1-4, Wii Remotes 1-4 (+ "Show All Ports") | port 1 = GC controller, others none (SIDevice1-3 compiled NONE) | per-player screen (remap, profile, Advanced Motion, On-Screen Stick Feel): not traced row by row. Port type: `SIDevice0..3` Dolphin.ini [Core]; Wii source: WiimoteNew.ini [WiimoteN] Source; device binding: `Device =` lines in GCPadNew.ini / WiimoteNew.ini; profile names: UD `player_profile_name.*` | n/c | not reset (assignments are deliberately preserved) | synced via whole `Config/*.ini` files (#16); UD parts device-local |
| Plays as (`<player>-plays-as`) | cycle | GameCube Controller / Wii Remote variants for the running system | current binding | moves the binding between a GC port and a Wii Remote slot (same files as above) | immediate | not reset | as above |
| Device (`<player>-device`) | cycle | connected pads, Touchscreen, No Device | current binding | `Device` in GCPadNew.ini / WiimoteNew.ini via `ControllerHubWriting.setDevice` | immediate | not reset | as above (#16) |
| Aim with Controller Motion (`<player>-pointer`) | toggle | on/off | per pad capability | `setMotionPointerEnabled` (PlayerScreenIO; storage not traced) | n/c | not reset | n/c |
| Show Touch Controls (`touch-visible`) — iOS, in-game only | toggle | on/off | on | `ControllerManager.overlayVisible` (in memory) | live | n/a | device-local |
| Layout (`touch-layout`) — iOS, in-game only | cycle | Auto, GameCube, Wii Remote | Auto | UD `controller_overlay_mode` | live | not reset | device-local |
| Opacity (`touch-opacity`) — iOS | cycle | `ControllerHubState.opacityChoices` percentages | 50 % | `MAIN_TOUCH_PAD_OPACITY` Dolphin.ini [iOS] TouchPadOpacity (game-aware setter: CurrentRun only when a game INI overrides it) | live | not reset | synced |
| Editable Controls (`touch-editable`) — iOS | toggle | on/off | true (`DefaultPreferences.plist` and `TouchOverlayFlag` fallback) | UD `touch_overlay_programmatic` | n/c | not reset | device-local |
| Edit Layout… / Edit IR Area… (`touch-edit-layout`, `touch-edit-ir-area`) — iOS | action | — | — | `TouchOverlayLayoutStore` Profiles/touch_overlay_layout_v2.json (anchored centre + scale per pad kind and orientation) | immediate | Reset All Layouts only | synced whole-file (#21) |
| Skins… (`touch-skins`) — iOS | destination | installed skins, Skin Store | none | Skins/selection.json + Skins/<id>/** (SkinKit); Skin Store flags `skin_store_show_*` UD | next game | not reset | synced (`.skin`, 32 MB cap) |
| Reset All Layouts (`touch-reset-layouts`) — iOS | destructive | — | — | clears the layout JSON per pad kind | immediate | n/a | synced |
| Background Input (`background-input`) | toggle | on/off | false | `MAIN_INPUT_BACKGROUND_INPUT` Dolphin.ini [Input] BackgroundInput (SetBaseOrCurrent) | n/c | not reset (input pref, allow-listed) | synced |
| Controllers Take Player 1 (`takes-player-1`) — iOS | toggle | on/off | **on** (registered default in `ControllerManager.connectTakesPlayer1(in:)`) | UD `controller_connect_takes_player1` | live | not reset | device-local |
| Rumble Output (`rumble`) — iOS | cycle | `RumbleDestination` cases | Controller (`RumbleDestination.default`) | UD `rumble_destination` | live | not reset | device-local |
| Test Rumble (`rumble-test`) — iOS | action | — | — | — | immediate | n/a | n/a |
| Motion Source (DSU) (`dsu`) | destination | see DSU table | — | — | — | — | — |
| Controller Lights (`lights`) — iOS, only when a pad has a light | destination | colour per pad | device state | `GCDeviceLight.color` on the controller (not stored) | live | n/a | device-local |
| Phones (`phone-<pid>`) / Help rows | action / caption | — | — | `phone_controller_session_snapshot` UD for the phone session | immediate | n/a | device-local |
| Siri Remote Menu Button (`remote-menu-action`) — tvOS | picker | Pause Menu, Live Performance | Pause Menu | UD `tv_siri_remote_menu_action` (`@AppStorage`, ControllerHubView.swift:18, :78) | n/c | not reset | device-local |

#### Motion Source (DSU), pushed from the hub and the DSU deep link

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Role (`dsu_role`) | picker | Receiver, Sender | Sender (registered default, DSUSettings.swift) | UD `dsu_role` (`@AppStorage`) | live | not reset | device-local |
| Enable DSU Client | toggle | on/off | false | `ciface::DualShockUDPClient::SERVERS_ENABLED` DSUClient.ini (SetBaseOrCurrent + Save) | n/c | not reset (explicitly preserved) | device-local (file excluded from sync) |
| Show DSU Debug HUD | toggle | on/off | false (hard-wired true in DEBUG builds) | UD `ui_show_dsu_debug_hud` | live | not reset | device-local |
| Send DSU Gyro/Accel | toggle | on/off | true (unset) | UD `dsu_enable_gyro` | live | not reset | device-local |
| Servers (add / remove) | list + text fields | desc : IPv4 : port 1-65535 | none | `SERVERS` string `desc:ip:port;` in DSUClient.ini ("@" stripped, port validated in `addDsuServer`) | n/c | not reset | device-local (file excluded) |

#### Advanced Motion, pushed from a player screen (not a root entry)

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Horizontal Movement (`horizontal-movement`) | cycle | Roll (tilt), Yaw (turn) | Roll (false) | UD `motion_use_yaw_for_horizontal` | live (`DOLMotionSettingsChanged` posted) | not reset | device-local |
| Wiimote Motion Controls (`wiimote-imu`) | toggle | on/off | true (registered) | UD `motion_wiimote_imu_enabled` | live | not reset | device-local |
| Enable 6DOF Motion Controls (`six-dof`) | toggle | on/off | true (registered) | UD `motion_enable_full_6dof` | live | not reset | device-local |
| Nunchuck Motion Controls (`nunchuk-imu`) — only while 6DOF is on | toggle | on/off | false (registered) | UD `motion_nunchuck_imu_enabled` | live | not reset | device-local |
| Recommended Motion Settings (`recommended`) | action |  | — | `MotionSettings.applyRecommended()` (writes the four keys above plus shake and invert keys) | immediate | n/a | device-local |

#### On-Screen Stick Feel, pushed from a player screen (not a root entry)

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Analog Stick Gain (`gain`) | stepper | 0.1…3.0 step 0.05 | 1.0 | UD `dsu_gyro_gain` (key name kept for `TCManagerInterface`) | n/c (read in `TCManagerInterface setAxisValueFor:`) | not reset | device-local |
| Analog Stick Deadzone (`deadzone`) | stepper | 0.0…0.49 step 0.01 | 0.05 | UD `dsu_deadzone` | n/c (read in `TCManagerInterface setAxisValueFor:`) | not reset | device-local |
| Analog Stick Smoothing (`smoothing`) | stepper | 0.0…0.9 step 0.05 | 0.0 | UD `dsu_smoothing` | n/c (read in `TCManagerInterface setAxisValueFor:`) | not reset | device-local |

### 1.3.6 Performance

#### Performance Tuning (`performance-tuning`)
Engine rows depend on `JitManager.acquiredJit`: JIT engines are listed only when JIT is acquired (APPSTORE builds normally never). "Show Validation Options" (host state, not persisted) gates the `*: Validate` rows. IR-only rows appear when the effective engine is Cached Interpreter IR. A/B & Snapshots (`PerformanceABView`) is a pushed screen that stores snapshots in UserDefaults.

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| CPU Emulation Engine (`cpu-engine`) | cycle | Interpreter, Cached Interpreter, Cached Interpreter IR; plus JIT Recompiler x86-64 / ARM64 only when JIT is acquired | ARM64 JIT compiled (`DefaultCPUCore()`); every jitless boot runs Cached Interpreter (core 5) on CurrentRun | `MAIN_CPU_CORE` Dolphin.ini [Core] CPUCore (`setMainCpuCore`: always Base, also in game; deletes a CurrentRun copy outside a game) | boot* | Reset All | synced, device-bound #12 |
| Vertex Loader (`vertex-loader`) | cycle | Software, NEON SIMD (default), Compare (validate) | NEON SIMD (unset) | UD `icube_vertex_loader_mode` | n/c | Reset All | device-local |
| Reset Optimizations to Recommended (`reset-optimizations`) | action |  | — | deletes every `CIR*` key from Base and CurrentRun (`resetCirOptimizationsToDefaults`) | next game launch (caption) | n/a | n/a |
| CIR Hot-Block Profiler (`cir-profiler`) | toggle | on/off | false (unset) | UD `icube.cirProfile` | n/c | not reset | device-local |
| Enable Emulated CPU Clock Override (`cpu-clock-enabled`) | toggle | on/off | false | `MAIN_OVERCLOCK_ENABLE` Dolphin.ini [Core] OverclockEnable (SetBase) | live* | Reset All | synced, device-tuned #13 |
| Emulated CPU Clock (`cpu-clock-percent`) | stepper | 1…400 % step 1 | 100 % | `MAIN_OVERCLOCK` Dolphin.ini [Core] Overclock (`setMainOverclockPercent`: SetBase; stored as a float fraction) | live* | Reset All | synced, device-tuned #13. Disabled with a badge while the adaptive clock (CurrentRun) or a game INI owns the key; shows the Base value |
| Enable VBI Frequency Override (`vbi-enabled`) | toggle | on/off | false | `MAIN_VI_OVERCLOCK_ENABLE` Dolphin.ini [Core] VIOverclockEnable (SetBase) | live* | Reset All | synced, device-tuned #13 |
| VBI Frequency (`vbi-percent`) | stepper | 1…400 % step 1 | 100 % | `MAIN_VI_OVERCLOCK` Dolphin.ini [Core] VIOverclock (`setMainViOverclockPercent`: SetBase) | live* | Reset All | synced, device-tuned #13. Same override rule as the CPU clock |
| Enable MMU (`mmu`) | toggle | on/off | false | `MAIN_MMU` Dolphin.ini [Core] MMU (SetBaseOrCurrent) | boot* | Reset All | synced |
| Adaptive Clock (auto VI/CPU) (`adaptive-clock`) | toggle | on/off | true (registered in DolphinCoreService; unset = on) | UD `adaptive_clock_enable` | next boot (caption) | Reset All | device-local |
| Pause on Panic (`pause-on-panic`) | toggle | on/off | false | `MAIN_PAUSE_ON_PANIC` Dolphin.ini [Core] PauseOnPanic (SetBaseOrCurrent) | n/c | not reset | synced |
| Accurate CPU Cache (slower) (`accurate-cpu-cache`) | toggle | on/off | false | `MAIN_ACCURATE_CPU_CACHE` Dolphin.ini [Core] AccurateCPUCache (SetBaseOrCurrent) | boot* | Reset All | synced |
| Bypass Instruction Cache (`bypass-icache`) | toggle | on/off | false | `MAIN_DISABLE_ICACHE` Dolphin.ini [Core] DisableICache (SetBaseOrCurrent) | n/c | Reset All | synced |
| CachedInterpreter Prefetch (Apple Silicon) (`ci-prefetch`) | toggle | on/off | false | `MAIN_CACHED_INTERPRETER_PREFETCH` Dolphin.ini [Core] CachedInterpreterPrefetch (SetBaseOrCurrent) | boot* | Reset All | synced, device-tuned #13 |
| NEON Texture Decoder (`neon-texture-decode`) | toggle | on/off | true | `GFX_HACK_NEON_TEXTURE_DECODE` GFX.ini [Hacks] NEONTextureDecode (SetBaseOrCurrent) | live* | Reset All | synced |
| DCBZ Hack (`dcbz-hack`) | toggle | on/off | false | `MAIN_LOW_DCBZ_HACK` Dolphin.ini [Core] LowDCBZHack (SetBaseOrCurrent) | n/c | Reset All | synced |
| Relaxed Idle Loop Detection (`relaxed-idle`) | toggle | on/off | true | `MAIN_RELAXED_IDLE_DETECTION` Dolphin.ini [Core] RelaxedIdleDetection (SetBaseOrCurrent) | n/c | Reset All | synced |
| Fast-Forward CTR Idle Loops (`ff-ctr-idle`) | toggle | on/off | true | `MAIN_FAST_FORWARD_CTR_IDLE` Dolphin.ini [Core] FastForwardCtrIdle (SetBaseOrCurrent) | n/c | Reset All | synced |
| Sync on Skip Idle (`sync-on-skip-idle`) | toggle | on/off | true | `MAIN_SYNC_ON_SKIP_IDLE` Dolphin.ini [Core] SyncOnSkipIdle (SetBaseOrCurrent) | n/c | Reset All | synced |
| PIC Load/Store (`pic-load-store`) | toggle | on/off | true | `MAIN_CIR_PIC_LOADSTORE` Dolphin.ini [Core] CIRPICLoadStore (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Specialized Ops (`specialized-ops`) | toggle | on/off | true | `MAIN_CIR_SPECIALIZED_OPS` Dolphin.ini [Core] CIRSpecializedOps (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Block Linking (`block-linking`) | toggle | on/off | true | `MAIN_CIR_BLOCK_LINKING` Dolphin.ini [Core] CIRBlockLinking (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Dynamic Links (`dynamic-links`) | toggle | on/off | true | `MAIN_CIR_DYN_LINKING` Dolphin.ini [Core] CIRDynLinking (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| NEON Paired-Single Math (`neon-paired-single-math`) | toggle | on/off | true | `MAIN_CIR_PS_NEON` Dolphin.ini [Core] CIRPsNeon (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| FP Load/Store Specialization (`cir-fp-load-store-specialization`) | toggle | on/off | false | `MAIN_CIR_SPECIALIZED_FP_LS` Dolphin.ini [Core] CIRSpecializedFpLs (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Paired-Single Load/Store Specialization (`cir-paired-single-load-store-specialization`) | toggle | on/off | false | `MAIN_CIR_SPECIALIZED_PSQ` Dolphin.ini [Core] CIRSpecializedPsq (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| FP / Paired-Single Arithmetic Specialization (`cir-fp-paired-single-arithmetic-specialization`) | toggle | on/off | false | `MAIN_CIR_SPECIALIZED_FP_ARITH` Dolphin.ini [Core] CIRSpecializedFpArith (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Micro-Op Fusion (`cir-micro-op-fusion`) | toggle | on/off | true | `MAIN_CIR_MICROOP_FUSION` Dolphin.ini [Core] CIRMicroOpFusion (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Dead Flag Elimination (`cir-dead-flag-elimination`) | toggle | on/off | false | `MAIN_CIR_DEAD_FLAG_ELIM` Dolphin.ini [Core] CIRDeadFlagElim (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Dead FPRF Elimination (`cir-dead-fprf-elimination`) | toggle | on/off | false | `MAIN_CIR_DEAD_FPRF_ELIM` Dolphin.ini [Core] CIRDeadFprfElim (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Paired-Single Float Fast-Path (`cir-paired-single-float-fast-path`) | toggle | on/off | false | `MAIN_CIR_PSQ_FASTPATH` Dolphin.ini [Core] CIRPsqFastPath (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Store-Loop (memset) Fast-Path (`cir-store-loop-memset-fast-path`) | toggle | on/off | false | `MAIN_CIR_STORE_LOOP_FF` Dolphin.ini [Core] CIRStoreLoopFF (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Cache-Management Loop Fast-Forward (`cir-cache-management-loop-fast-forward`) | toggle | on/off | false | `MAIN_CIR_CACHE_LOOP_FF` Dolphin.ini [Core] CIRCacheLoopFF (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Constant-Address Fusion (`ir-constant-address-fusion`) | toggle | on/off | false | `MAIN_CIR_IR_CONST_FUSION` Dolphin.ini [Core] CIRIRConstFusion (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Micro-Op Fusion (`ir-micro-op-fusion`) | toggle | on/off | false | `MAIN_CIR_IR_MICROOP_FUSION` Dolphin.ini [Core] CIRIRMicroOpFusion (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Dead CR-Flag Elimination (`ir-dead-cr-flag-elimination`) | toggle | on/off | false | `MAIN_CIR_IR_DEAD_FLAG_ELIM` Dolphin.ini [Core] CIRIRDeadFlagElim (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| NEON Paired-Single Math: Validate (`validate-neon-paired-single-math`) | toggle | on/off | false | `MAIN_CIR_PS_NEON_VALIDATE` Dolphin.ini [Core] CIRPsNeonValidate (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Specialized Ops: Validate (`cir-validate-specialized-ops`) | toggle | on/off | false | `MAIN_CIR_SPECIALIZED_OPS_VALIDATE` Dolphin.ini [Core] CIRSpecializedOpsValidate (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Block Linking: Validate (`cir-validate-block-linking`) | toggle | on/off | false | `MAIN_CIR_BLOCK_LINKING_VALIDATE` Dolphin.ini [Core] CIRBlockLinkingValidate (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Micro-Op Fusion: Validate (`cir-validate-micro-op-fusion`) | toggle | on/off | false | `MAIN_CIR_MICROOP_FUSION_VALIDATE` Dolphin.ini [Core] CIRMicroOpFusionValidate (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Dead Flag Elimination: Validate (`cir-validate-dead-flag-elimination`) | toggle | on/off | false | `MAIN_CIR_DEAD_FLAG_ELIM_VALIDATE` Dolphin.ini [Core] CIRDeadFlagElimValidate (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Dead FPRF Elimination: Validate (`cir-validate-dead-fprf-elimination`) | toggle | on/off | false | `MAIN_CIR_DEAD_FPRF_ELIM_VALIDATE` Dolphin.ini [Core] CIRDeadFprfElimValidate (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Paired-Single Float Fast-Path: Validate (`cir-validate-paired-single-float-fast-path`) | toggle | on/off | false | `MAIN_CIR_PSQ_FASTPATH_VALIDATE` Dolphin.ini [Core] CIRPsqFastPathValidate (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Store-Loop Fast-Path: Validate (`cir-validate-store-loop-fast-path`) | toggle | on/off | false | `MAIN_CIR_STORE_LOOP_FF_VALIDATE` Dolphin.ini [Core] CIRStoreLoopFFValidate (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Cache-Loop Fast-Forward: Validate (`cir-validate-cache-loop-fast-forward`) | toggle | on/off | false | `MAIN_CIR_CACHE_LOOP_FF_VALIDATE` Dolphin.ini [Core] CIRCacheLoopFFValidate (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| PIC Load/Store: Validate (`ir-validate-pic-load-store`) | toggle | on/off | false | `MAIN_CIR_IR_PIC_LOADSTORE_VALIDATE` Dolphin.ini [Core] CIRIRPICLoadStoreValidate (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Specialized Ops: Validate (`ir-validate-specialized-ops`) | toggle | on/off | false | `MAIN_CIR_IR_SPECIALIZED_OPS_VALIDATE` Dolphin.ini [Core] CIRIRSpecializedOpsValidate (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Constant-Address Fusion: Validate (`ir-validate-constant-address-fusion`) | toggle | on/off | false | `MAIN_CIR_IR_CONST_FUSION_VALIDATE` Dolphin.ini [Core] CIRIRConstFusionValidate (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Micro-Op Fusion: Validate (`ir-validate-micro-op-fusion`) | toggle | on/off | false | `MAIN_CIR_IR_MICROOP_FUSION_VALIDATE` Dolphin.ini [Core] CIRIRMicroOpFusionValidate (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |
| Dead CR-Flag Elimination: Validate (`ir-validate-dead-cr-flag-elimination`) | toggle | on/off | false | `MAIN_CIR_IR_DEAD_FLAG_ELIM_VALIDATE` Dolphin.ini [Core] CIRIRDeadFlagElimValidate (SetBaseOrCurrent) | boot* (CachedInterpreter::Init) | Reset All; Reset Optimizations | synced, device-tuned #13 |

#### Debug (`debug`)
In APPSTORE only the Environment section exists, and with no JIT support it is read-only (`debugLeaf(isStore:)`). Everything else here is non-store only.

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Fastmem (`fastmem`) [full only] | toggle | on/off (disabled unless this device reports fastmem available) | device capability (seed `fastmemAvailable`) | `MAIN_FASTMEM` Dolphin.ini [Core] Fastmem (SetBaseOrCurrent) | boot* | Reset All | synced, device-bound #11 |
| User Folder (`user-folder`) [APPSTORE: all scopes] | status or destination |  | — | file path of the User directory (not stored) | — | n/a | device-local |
| JIT (`jit-status`) [APPSTORE: all scopes] | read-only status | Acquired / Not Acquired | — | `JitManager.acquiredJit` (read once on appear) | — | n/a | device-local |
| Debugger (`debugger-status`) [APPSTORE: all scopes] | read-only status | Attached / Not Attached | — | `JitManager.debuggerAttached` | — | n/a | device-local |
| TXM JIT Region (`txm-region`) [APPSTORE: all scopes; only on TXM devices] | read-only status | Authorized / Not Authorized | — | `JitManager.txmAuthorized` | — | n/a | device-local |
| JIT Error (`jit-error`) [APPSTORE: all scopes] | read-only status | text or (none) | — | `JitManager.acquisitionError` | — | n/a | device-local |
| Fastmem availability (`fastmem-available`) [APPSTORE: all scopes] | read-only status | Available / Not Available | — | `FastmemManager.fastmemAvailable` | — | n/a | device-local |
| StikDebug help (`stikdebug-help`) [APPSTORE: jitOnly and full; iOS] | caption | — | — | shown only after StikDebug was asked and did not attach | — | n/a | n/a |
| Launch Times (`launch-times`) [full only] | read-only status | count | 0 | UD `launch_times` (also registered in `DefaultPreferences.plist`) | — | n/a | device-local |
| Enable ReplayKit Instant Replay (`instant-replay`) [full only] — iOS only | toggle | on/off | false (unset) | UD `replaykit_instant_replay_enabled` | n/c | not reset | device-local |
| Retry JIT Authorization (`retry-jit-authorization`) [APPSTORE: jitOnly and full] | action |  | — | JIT crash cookie (JitManager) | immediate | n/a | device-local |
| Enable JIT via StikDebug (`enable-jit-stikdebug`) [APPSTORE: jitOnly and full] | action |  | — | — | immediate (relaunches the app) | n/a | device-local |
| JIT Setup Guide (`jit-guide`) [APPSTORE: jitOnly and full] | destination |  | — | — | — | — | — |
| Reset Launch Times (`reset-launch-times`) [full only] | action |  | 0 | UD `launch_times` | immediate | not reset | device-local |
| Motion Debug (`motion-debug`) [DEBUG builds only] — DEBUG builds only | destination |  | — | — | — | — | — |
| Gallery (`gallery`) [DEBUG builds only] — DEBUG builds only, iOS | destination |  | — | — | — | — | — |
| Stall Metrics (`stall-metrics`) [full only] | toggle | on/off | **true** (compiled) | `MAIN_STALL_METRICS` Dolphin.ini [Core] StallMetrics (SetBaseOrCurrent/SetCurrent) | n/c | Reset All | synced |
| Show Test Skins (`show-test-skins`) [full only] — iOS only | toggle | on/off | false (unset) | UD `skin_store_show_test_skins` | n/c | not reset | device-local |
| Perf Test Bench (HTTP) (`perf-bench`) [full only] | toggle | on/off | false (unset) | UD `ICubeBenchServerEnabled` | next game boot (caption) | not reset | device-local |
| Bench Token (`bench-token`) [full only] — **credential shown in clear** | custom |  | — | UD (DebugServerManager.tokenDefaultsKey); minted on first LAN start | — | not reset | device-local |
| Forget N Approved Device(s) (`forget-approved-devices`) [full only] | destructive |  | — | BenchAccessApproval (remembered client addresses) | immediate | not reset | device-local |
| Wireframe (`wireframe`) [full only] | toggle | on/off | false | `GFX_ENABLE_WIREFRAME` GFX.ini [Settings] WireFrame (SetBaseOrCurrent) | n/c | Reset All | synced |
| Enable Console Logging (`console-logging`) [full only] | toggle | on/off | false (unset) | UD `logger_console_enabled` | next launch | not reset | device-local |
| Verbosity (`logging-verbosity`) [full only] | cycle | 1…5 | `LoggerIniMigration.defaultVerbosity` | UD `logger_console_verbosity` | next launch (applied to Logger.ini in `didFinishLaunching`) | not reset | device-local |
| Input Event Debug (`input-debug`) [full only] | toggle | on/off | false (unset) | UD `input_debug` | n/c | not reset | device-local |
| Use Template Covers (Disable Artwork) (`template-covers`) [full only] | toggle | on/off | false (unset) | UD `library_disable_artwork` | n/c | not reset | device-local |

### 1.3.7 Sync & Network

#### Web UI & WebDAV (`web-ui`)

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Web UI (`web-ui`) | read-only value | — | server-assigned URL or "Not Running" | `PVWebServer.shared.urlString` (runtime) | refreshed on appear (iOS polls 20×100 ms; tvOS reads once) | n/a | device-local |
| Finder / WebDAV (`webdav`) | read-only value | — | server-assigned | `PVWebServer.shared.webDavURLString` | as above | n/a | device-local |
| Learn more (`learn-more`) | action | — | — | opens https://icube-emu.com/help/web-import | immediate | n/a | n/a |

#### iCloud Sync (`icloud`)
tvOS renders `CloudSyncModelBuilder` (fewer controls), iOS/iPadOS a hand-built Form.

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Sync This Device (`enabled`) | toggle | on/off | off | UD `icube.cloudSync.enabled` | immediate (`apply(.enabledChanged)`) | not reset | device-local |
| Sync Now (`sync-now`) | action | — | — | — | immediate | n/a | n/a |
| Conflicts (`conflicts`) | destination | Keep Both / Keep This Device's Copy / Keep iCloud's Copy; for remote deletes Keep It / Delete It Here Too; plus "everywhere" bulk buttons | — | pending conflicts held by `CloudSyncCoordinator` (index in Application Support/…/index.json) | immediate | n/a | device-local |
| Clear iCloud Data (`clear`) | destructive (confirmation) | — | — | deletes the CloudKit zone `iCubeUserData`; local files untouched | immediate | n/a | n/a |
| GameCube Firmware / Wii Channels & DLC / Full Wii NAND — **iOS/iPadOS only** | toggle ×3 | on/off | off | `SyncPolicy` JSON in UD `icube.cloudSync.policy` (firmwareEnabled, wiiChannelsEnabled, fullWiiNANDEnabled) | next sync (policy change triggers a rescan) | not reset | device-local |
| Large Files Over Wi-Fi Only — **iOS/iPadOS only** | toggle | on/off | on | `SyncPolicy.largeFilesOverWiFiOnly` | next sync | not reset | device-local |
| Recently Deleted — **iOS/iPadOS only** | destination (restore) | 30-day trash | — | `SyncTrash` under Application Support | immediate | n/a | device-local |
| What Is Synced / Always Synced (caption list) | caption | — | — | static text; tvOS and iOS lists differ (Findings F11) | — | — | — |

#### Nearby Devices (`nearby`)
Models in Continuity/UI/*ModelBuilder.swift.

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Share My Library (`share-library`) | destination → toggle | on/off | off (opt-in) | UD `continuity_shares_library` | immediate (starts/stops the library server hold) | not reset | device-local |
| Paired device (`peer-<id>`) / Trusted (`trusted-<id>`) | destination | per-peer grant (browse / copy), forget | — | `User/Continuity/trusted-peers.json`, `library-grants.json` (not sync-classified); pairing key in Keychain (ThisDeviceOnly) | immediate | not reset | device-local |
| Automatic Game Copying (`automatic-copy`, per peer `mirror-<id>`) | destination → toggles | on/off per paired device | off | UD string array of enabled peer ids (NearbyLibraryMirrorService.swift:76, :95) | foreground only | not reset | device-local |

#### Connected Apps (`connected-apps`)

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Provenance / iFly (`provenance`, `ifly`) | action | Installed / Get | probe via URL scheme | none (runtime `canOpenURL`) | on appear / foreground | n/a | n/a |
| Scan NFC Tag (`scan-tag`) | action | — | hidden where NFC cannot be read | none | immediate | n/a | n/a |

### 1.3.8 Privacy

#### Privacy (`privacy`)

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Share Crash Reports (`crash-reports`) | toggle | on/off | **on** (`TelemetryConsent.isEnabled`: unset = true) | UD `icube.telemetry.crashReports`; `SentryTelemetryService.applyConsent` starts/stops the SDK and deletes its disk queue | immediate | not reset (privacy choice) | device-local |

### 1.3.9 About

#### About (`about`)

| Row (id) | Kind | Choices / range | Default (effective) | Persistence (layer) | Live / restart | Reset | Scope |
|---|---|---|---|---|---|---|---|
| Version / Core | read-only | — | — | `VersionManager` | — | n/a | n/a |
| Shared Plus Membership | read-only | — | — | `SharedPlusEntitlement` | on appear | n/a | n/a |
| Links (icube-emu.com, Source Code, author pages, DolphiniOS, dolphin-emu.org) | action | — | — | opens URLs | immediate | n/a | n/a |
| Dolphin Blog / Help | destination | — | — | network / bundled wiki | — | n/a | n/a |
| Reset All Settings (`reset-all`) | destructive (confirmation) | — | — | see 1.2 | immediate; "May require restarting emulation" | — | — |

### 1.3.10 Surfaces outside the Settings root that write the same settings

| Surface | Row | Persistence (layer) | Notes |
|---|---|---|---|
| Pause › Performance tile (`PerformanceControlsModelBuilder`) | CPU Clock Override (toggle + 1…400 % stepper), VI Frequency Override (toggle + stepper), Adaptive Clock, VI Skip, Internal Resolution, Anisotropic Filtering, Performance HUD + per-statistic toggles | clocks and resolution: **SetBase** (`PerformanceControlsLiveBackend`); anisotropy and VI Skip: `setGfxEnhanceAnisotropySamples`, `setGfxHackViSkipMode` (BoC); adaptive clock: UD `adaptive_clock_enable`; HUD: `GFX_SHOW_*`, `GFX_OVERLAY_STATS` | same keys as Performance Tuning / Enhancements / Graphics Advanced; ownership of a clock by the adaptive controller or a game INI disables the row and shows a badge (`DOLConfigOverride`). |
| Pause › Audio tile (`PauseAudioModelBuilder`) | Volume, Backend, Surround, Wii Sound, Remote Speaker (0…7 choices), effect toggles, Effect Settings | tile volume: `TVEmulationBridge.setAudioVolumePercent` = `Config::SetCurrent(MAIN_AUDIO_VOLUME)` (**CurrentRun, game-scoped**, TVEmulationBridge.mm:644-646); top bar volume and the Audio leaf use `setAudioVolume` (BoC). Wii Sound / Remote Speaker: SYSCONF SetBase | Volume changed through the tile never reaches Dolphin.ini; the Audio leaf row can end up on CurrentRun too once the tile has written it (F4). |
| Pause › Cheats (`CheatsMenuModelBuilder`) | per-game cheat list, categories, Refresh | `GameSettings/<id>.ini` (ActionReplay / Gecko sections) via `TVCheatsBridge`; global switch is General › Enable Cheats | per-game; synced as `.gameSettings`. |
| Pause › Shaders, Save States, Controllers, Continue Elsewhere | open the Shaders leaf, the save-state pane, the hub, Nearby | as the leaves above | |
| Top bar (in-game) | Volume / quick mute, Fast Forward, Instant Replay, overlay visibility | `setAudioVolume` (BoC); `fast_forward_speed_percent`; `replaykit_instant_replay_enabled`; `ControllerManager.overlayVisible` | fast-forward writes `MAIN_EMULATION_SPEED` on CurrentRun (follow-up in the 2026-10-16 audit). |

## 2. Search and deep-link coverage

### 2.1 Search

- **Platforms.** iPhone list and iPad sidebar only. tvOS builds no index (`searchIndex: nil`, SettingsRootView.swift:74), so Apple TV has no settings search at all.
- **What is indexed** (`SettingsSearchIndex`, built once per appearance in `.task`): each entry's title, description and `keywords`; and, for entries with a `makeModel`, every top-level row's title and description. `keywords:` is never passed anywhere (grep of `Source/iOS/App/Common/UI/Settings`: 0 uses), so hand-built leaves are findable by title and description only. Matching folds case, punctuation and diacritics; there is no ranking and no de-duplication of equal row titles across leaves ("Micro-Op Fusion" appears twice, as do "Specialized Ops", "Backend", "Instant Replay").
- **A row hit opens the leaf, not the row.** `SettingsSearchResults` shows the row title as a caption but calls `onSelect(entry)` with no row id (SettingsSearchIndex.swift, `SettingsSearchResults`); the phone list sets `pushed = entry` and the sidebar selects the entry. `SettingsRowTarget`/`settingsRowTarget` already exists for pause-menu deep links and could carry the row (Findings F10).
- **Entries with a model (rows searchable):** General, Interface, Advanced, Video, Enhancements, Hacks, Graphics Advanced, Audio, GameCube, Wii, Performance Tuning, Debug, Connected Apps, Privacy: 14 of 21 entries.
- **Entries without a model (rows not searchable; leaf found by title and description only):**

| Entry | Rows a user would search for and cannot find |
|---|---|
| Shaders | Enable Shader, Preset, Flip vertically, Pre-copy |
| Achievements | Hardcore, Spectator, Username, Log In, Server URL |
| Controllers | every hub row (Plays as, Device, Opacity, Skins, Background Input, Rumble, Siri Remote menu action, DSU) |
| Web UI & WebDAV | Web UI, Finder / WebDAV |
| iCloud Sync | Sync Now, Clear iCloud Data, GameCube Firmware, Wii Channels, Full Wii NAND, Large Files Over Wi-Fi Only, Recently Deleted |
| Nearby Devices | Share My Library, Automatic Game Copying |
| About | Reset All Settings (found only through the entry description "…and Reset All Settings."), Dolphin Blog, Help |

- **Rows missing even in indexed leaves.** The index calls each builder with a default `State()` (the `makeModel` closures in SettingsRootModelBuilder.swift), so any row gated on state is absent:
  - Performance Tuning: all Cached Interpreter IR rows (`ir-constant-address-fusion`, `ir-micro-op-fusion`, `ir-dead-cr-flag-elimination` and the five `ir-validate-*` rows) because the default engine resolves to the plain Cached Interpreter (`jitAvailable == false`, `effectiveEngine`); the JIT engine choices.
  - Debug: `retry-jit-authorization`, `enable-jit-stikdebug`, `txm-region`, `bench-token`, `forget-approved-devices`; in APPSTORE only the Environment section exists at all.
  - Connected Apps: the Provenance and iFly rows (the model is built with `apps: []`) and the NFC row.
  - Audio: the Audio Unit Plug-ins section (needs AVAudioEngine), microphone rows (permission state), spatial rows are present but disabled.
  - Graphics Advanced: the texture-pack warning. Advanced Motion and On-Screen Stick Feel are not root entries at all.
- **Existing tests** (`SettingsSearchIndexTests`, 16 tests) pin that each indexed leaf's row titles are found and that a hand-built leaf is found by description; none pins which entries lack a model, and none exercises tvOS.

### 2.2 Deep links

Producers found (grep of `SettingsDeepLink(`, `initialRowID:`, `initialLeafID:`, `dolSettingsSelectControllers`):

| Producer | Leaf id | Row id | Resolves? |
|---|---|---|---|
| Pause tile "Upscaling", long-press (PauseMenuView.swift:1151) | `graphics-enhancements` | `efb-scale` | yes (Enhancements builder) |
| Pause tile "Audio", long-press (:1152) | `audio` | `volume` | yes |
| Pause tile "Performance", long-press (:1153) | `performance-tuning` | `cpu-engine` | yes |
| Pause › Audio › "All Audio Settings" (:252) | `audio` | none | yes |
| Pause › Audio › "Wii Sound" (:256) | `console-wii` | `sound-mode` | yes |
| `dolphinios://dsu/add` and legacy `dsu://` (URLRouterService.swift:77) → `.dolSettingsSelectControllers` | `controllers` | none | iPhone: pushes the DSU server list. iPad/tvOS: only selects the Controllers hub; the DSU list is one level down (Findings F15) |
| DEBUG launch args `-ICubeSettingsPreview <leaf>` / `-ICubeSettingsRow <row>` (TVRootView.swift:25) | any | any | n/a (debug only) |

- Every row id above exists in its builder, and `PauseSettingsDeepLinkTests.test_everyLink_resolvesToALeafAndRow_onIOSAndTVOS` pins that; no mismatch found.
- There is no `settings` URL route and no App Intent that opens a leaf or row.
- A deep link to a leaf that is not listed on the platform (Connected Apps on tvOS, Achievements without `USE_RETRO_ACHIEVEMENTS`, Debug when `storeDebugLeaf` is nil) silently opens the root: `pushed = sections.flatMap(\.entries).first { $0.id == id }` is nil.
- Leaves and rows that no deep link or search can reach: everything in the table of 2.1, the sub-screens listed in 1.1, and every row hidden by default state.

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

### 3.3a Proposed scope per setting class (for the "Scope" column and a visible label)

| Class | Examples (from section 1.3) | Proposed scope | Today |
|---|---|---|---|
| Gameplay preferences a person expects to follow them | Speed Limit, Aspect Ratio, Internal Resolution, MSAA, hacks, audio balance, Interface toggles, Wii SYSCONF choices | **Synced preference** | synced (whole file) |
| Hardware or install bound Config keys | Fastmem, shader thread counts, CPU engine, GFX backend, AU chain, CIR/overclock tuning, Analytics ID, Wireless MAC, absolute paths, NetPlay identity, BT/USB passthrough | **Device-local** (strip from upload, ignore on download) | synced (#7-#15) |
| Controller bindings and device strings | `GCPadNew.ini`, `WiimoteNew.ini`, Plays as, Device | **Device-local** (or keyed by controller family) | synced (#16) |
| Credentials and tokens | RetroAchievements token, Bench Token, WebDAV passwords, pairing key | **Device-local, Keychain where possible** | RA file excluded by name; others never in a synced file |
| Pairing grants and endpoints | `trusted-peers.json`, `library-grants.json`, `DSUClient.ini` | **Device-local** | not classified / excluded |
| App presentation and diagnostics | `UserDefaults` rows: library look, recording, motion, stick feel, logging, debug | **Device-local** | never synced |
| Per-game settings | `GameSettings/<id>.ini`, `game_profiles.json` (shader preset, IR mode, widescreen, opacity, sensor-bar sensitivity, nearby-sharing exclusion) | **Per-game profile, synced** | synced (merge by game for the JSON) |
| Screen-size dependent layout | `touch_overlay_layout_v2.json`, skins | **Per device class** (iPhone, iPad) or synced with a check | synced whole-file (#21) |
| Cloud opt-ins | `icube.cloudSync.enabled`, `SyncPolicy` | **Device-local** | UserDefaults |

### 3.4 Not determined from code in this section

- Whether the WebDAV/HTTP upload server serves `User/` (and therefore `Continuity/trusted-peers.json`). The source comment at ContinuityIdentityStore.swift:6-8 says it does; the server code lives in the external PVWebServer package, not read here.
- What a real `Dolphin.ini` on a long-lived install contains. This audit lists keys that can reach the file; the actual set needs a device `Config/` listing.
- Whether Dolphin's INI writer persists a key only when it differs from its default (it persists any key present in the Base layer; `SetBaseIfUnspecified` seeds therefore always land).
- Production CloudKit behaviour (R3).

## 4. Findings

Ranked by release impact. "Proven" = follows from the cited source; "device" = the source leaves the outcome open and a device check is needed. No code was changed and nothing was run except `check_settings_wiring.py` (clean: 200 UI-writable Config keys, 165 reset-covered, 19 + 4 prefixes preserved) and `scripts/icube_config_lint.py` (exits 1; every flag checked or listed as a false positive in section 5).

### High

**F1. Reset All Settings, opened from the pause menu, can delete the running game's per-game settings from `GameSettings/<id>.ini`.** *Proven (code); reachable in a game: device.*
- `resetGameplayConfigKeys` deletes every listed key from CurrentRun, LocalGame, GlobalGame **and** Base (DOLConfigBridge.mm:1207-1230); `resetAllToDefaults` then calls `Config::Save()` (:1583-1595).
- `Layer::DeleteKey` marks the entry as removed and the layer dirty (Layer.cpp:40-50); `INIGameConfigLayerLoader::Save` writes removed keys as `ini.DeleteKey` into `GameSettings/<id>.ini` for the LocalGame layer (GameConfigLoader.cpp:283-325). The comment above the function (DOLConfigBridge.mm:1195-1199) assumes Reset is tapped "from root Settings" with no game running.
- Settings is hosted by the pause menu (`SettingsRootView` inside PauseMenuView.swift:525 and :540, `onClose` doc in SettingsRootView.swift), and Reset All sits in the iPhone toolbar and in About on every platform.
- Result: one tap in a game removes that game's saved overrides (and the file is a synced `.gameSettings` document, so the deletion propagates). Cheat sections are not config-mapped and survive.
- The same pass also deletes `MAIN_CPU_CORE` from CurrentRun (which is where a jitless boot parks its Cached Interpreter fallback) and the shipped GlobalGame keys in memory (for example GMSE04's `FastDiscSpeed = False`) until the next boot: *device check*.
- Rule: skip LocalGame, GlobalGame and CurrentRun in the layer loop, or disable Reset All while a core is running (`EmulationState`).

**F2. The iCloud engine mirrors device-bound and identifying keys, and the only exclusions are two file names.** *Proven.* Full list with evidence and a proposed rule in section 3.2 and 3.3. Highest items: `Logger.ini` is rewritten per device at launch yet synced as a shared file (#17); `[Analytics] ID` and `[General] WirelessMac` are created per install and ride in `Dolphin.ini` (#7, #8); `Fastmem`, shader thread counts, `CPUCore`, `GFXBackend`, the CIR/overclock tuning (#11-#13) and the controller `Device =` files (#16) are hardware-specific and last-writer-wins. The tvOS and iOS iCloud screens both tell the user "Settings … sync" without scope (F11).

### Medium

**F3. Wii "Speaker Volume" uses a 0…7 range on a 0…127 key.** *Proven; audible effect: device.* `SYSCONF_SPEAKER_VOLUME` defaults to 0x58 (88) (SYSCONFSettings.cpp:25) and Dolphin's own slider is `ConfigSliderU32(0, 127, …)` (WiiPane.cpp:322). The Wii leaf uses `ConfigWiiLimits.speakerVolume = 0…7` (ConfigWiiState.swift:9) with state default 4, passes the raw number to `setSysconfSpeakerVolume` (DOLConfigBridge.mm:941-942, no scaling) and the pause menu's "Remote Speaker" cycle offers the same 0…7 (PauseAudioModelBuilder.swift:18). On a fresh install the row shows 88 outside its own range, and the first change writes at most 7/127. `ConfigWiiModelBuilderTests.swift:136` pins the 0…7 range.

**F4. Rows that write with `SetBaseOrCurrent` lose the change at game end when the key is already on CurrentRun.** *Proven; user-visible frequency: device.* Generalises the "Not changed" note in the 2026-10-16 audit. App code puts these keys on CurrentRun (section 1.2): the Settings rows that write them with `SetBaseOrCurrent` are **Audio › Volume** (`setAudioVolume`, DOLConfigBridge.mm:672), **General › Speed Limit** (:422), **Audio › Mute When Disabling Speed Limit** (:701) and **Enhancements › Widescreen Hack** (:285). The pause Audio tile writes volume on CurrentRun by design (`TVEmulationBridge.mm:644-646`), so after using it the Audio row's next write also lands on CurrentRun (the layer that now holds the key) and is dropped at game end; fast-forward puts the speed limit on CurrentRun too (`TVEmulationBridge.mm:78`, restored at :666). Any row whose key a game INI sets behaves the same: shipped INIs under `Data/Sys/GameSettings/` set Overclock keys for many titles (those two rows have an override badge) and `FastDiscSpeed = False` for GMSE04 (General › Fast Disc Speed has no badge). Rule: pick, per key, "Base always" (`SetBase`) or "per-run" and show which in the row.

**F5. After "Reset All", two first-run seeds read differently from a fresh install until the next launch.** *Proven.* `resetGameplayConfigKeys` deletes `GFX_HACK_EFB_EMULATE_FORMAT_CHANGES` (compiled false; fresh install seeds true), `GFX_SHADER_COMPILER_THREADS` and `GFX_SHADER_PRECOMPILER_THREADS` (compiled 1 / −1; fresh install seeds min(2, cores−1)) and does not re-seed them (DOLConfigBridge.mm:1260-1420; `DolphinCoreService.mm:104`, :129-131). The adjacent comment lists the keys that needed forcing and misses these. `MAIN_USE_GAME_COVERS` (seed true) is not reset at all. `SetBaseIfUnspecified` re-applies the seeds at the next launch.

**F6. Dead row: Wii › "Allow Touchpad IR Follow Without Click".** *Proven.* The key `touchpad_ir_follow_without_click` is written and read only by the Wii leaf itself (grep of `Source`: ConfigWiiState/View/ModelBuilder only; `docs/superpowers/specs/2026-10-21-siri-remote-and-pointer-sources-design.md:54` says the same). It is also shown on tvOS, where there is no touch IR.

**F7. Dead row: Interface › "Camera Overlay" (iOS).** *Proven.* `recording_camera_overlay` has a writer and no reader: `RecordingManager`/`RecordingWatermarkView` contain no camera code (grep `camera` in `Common/Swift/Recording`: none) and `ConfigInterfaceDefaultsKey.recordingCamera` is referenced only by the leaf.

**F8. Interface › "Background Style" does nothing on tvOS.** *Proven.* `TVLibraryView` uses `ICubeRoom(style: .animated)` on tvOS regardless (TVLibraryView.swift:867-869); the row (no `#if`) is shown in the tvOS Interface leaf.

**F9. Video › Backend has two stores and a display that prefers the one the engine does not read.** *Proven; backend availability: device.* The row writes `MAIN_GFX_BACKEND` and the UD mirror `ui_gfx_backend` (GraphicsGeneralView.swift:41-45) but displays the UD copy first (`effectiveBackendKey`, :21); the core activates the backend from Config only (`UICommon.cpp:141`, `VideoBackendBase.cpp:265`), and nothing else reads `ui_gfx_backend`. A Config-only change (synced `Dolphin.ini`, per-game INI, debug API) leaves the row showing the stale UD value. Reset clears both. The picker always lists Metal, OpenGL and Vulkan; no code decides which backends this build ships (`DOLConfigBridge` has no backend list, unlike `audioBackends()`), so whether OpenGL/Vulkan work on iOS/tvOS is undetermined.

**F10. Search finds rows but never opens them, tvOS has no search, and 7 of 21 entries have no searchable rows.** *Proven.* Section 2.

**F11. The tvOS iCloud screen has fewer controls than iOS and both describe scope loosely.** *Proven.* `CloudSyncModelBuilder` (tvOS) has no "Also Sync" switches (firmware, channels, NAND), no "Large Files Over Wi-Fi Only", no Recently Deleted. These opt-ins are not inherited from iOS: `CloudSyncCoordinator.loadPolicy()` / `store(_:)` (CloudSyncCoordinator.swift:1122-1132) keep `icube.cloudSync.policy` in local, unsynced `UserDefaults.standard`, so enabling firmware/channels/NAND on an iPhone changes nothing on an Apple TV. A tvOS install stays at the local defaults (off) with no UI to change them, so those categories never sync from or to Apple TV. Acceptance checks for cross-device firmware/channel/NAND sync must expect that. The "What Is Synced" lists differ between platforms (the iOS list adds touch layout/skins and favorites/play time). Neither mentions that RetroAchievements and DSU files are excluded, or that some keys inside the synced files are device-bound. The file header (CloudSyncSettingsView.swift:11-14) still says the container is not provisioned. Add per-row scope labels and a short "never synced" list.

**F12. Hardcore Mode defaults ON once RetroAchievements is enabled.** *Proven (default); behaviour: device.* `RA_HARDCORE_ENABLED` compiles to true (AchievementSettings.cpp) while the row caption says it disables save states, cheats and speed changes; the view's `@State` starts false until `sync()`. A user who flips "Enable Integration" therefore loses save states and cheats without choosing to.

### Low

**F13. V-Sync caption contradicts its default.** *Proven.* The caption says "leave ON" (GraphicsGeneralModelBuilder.swift) while `GFX_VSYNC` defaults to false, nothing seeds it, and Reset returns it to false.

**F14. `resetPageToDefaults:` has no production caller and its controllers page indexes out of range.** *Proven.* Swift name `resetPage(toDefaults:)` (DOLConfigBridge.h:596); the only caller is `SettingsWriteBackTests.swift:49`, which exercises page 1 only, so the page-2 path is untested; page 2 loops `p = 1…4` into `GetInfoForSIDevice(p)` / `GetInfoForWiimoteSource(p)`, which index zero-based arrays (four SI entries; the same trap `gcPortDeviceForPort:` documents at DOLConfigBridge.mm ~228-240), so for the four-entry SI array `p == 4` reads past the end and `p == 1…3` address the wrong port (DOLConfigBridge.mm:1639-1642). Delete the method (and the test call), or fix the loop to `0…3`.

**F15. DSU "add" deep link lands one level too high on iPad and tvOS.** *Proven.* `jumpToControllersRequested` pushes `DSUSettingsView` only in the phone list; the sidebar reaches only the Controllers hub (SettingsRootView.swift:89-92, :125-127).

**F16. tvOS Web UI & WebDAV reads its addresses once.** *Proven.* The 20 × 100 ms polling loop is `#if os(iOS)` (WebUISettingsView.swift `refresh()`); on tvOS the screen can show "Not Running" while the server is still binding.

**F17. "Progressive Scan" is a Wii SYSCONF key shown under Graphics Advanced beside "Force Progressive Scan" (Hacks).** *Proven.* Two similarly named rows with different keys (`SYSCONF_PROGRESSIVE_SCAN`, `GFX_HACK_FORCE_PROGRESSIVE`), on different pages; SYSCONF is the only one that is not reset.

**F18. Hidden switches.** *Proven.* `profiles_enabled` (GameProfiles.swift:228, :249) gates per-game profiles and has no row; `Show DSU Debug HUD` is a developer toggle in the shipping DSU screen; `Stall Metrics` is on by default (`MAIN_STALL_METRICS` compiled true) and its only switch is in the non-store Debug leaf.

**F19. Bench Token is shown in clear.** *Proven.* Debug › Bench Token (DebugRootModelBuilder.swift:132-136) prints the bearer token and offers selection. Hidden in APPSTORE builds, present in other configurations that enable the bench.

### Checked, no defect found

- **Zero-width ranges.** Compiler/Precompiler Threads use `1…max(1, max(2,cores)−1)` (GraphicsAdvancedState.swift:102-104): a 1…1 range is possible on a ≤2-core device and `ValueStepper` draws no slider for it (ValueStepper.swift); tvOS `MenuStepper.stepped` returns the upper bound. No other stepper has equal bounds (ranges in the tables).
- **Defaults vs `defaultValue:` hints.** All 30 `defaultValue:` annotations in the builders match the compiled or seeded default (Texture Cache 0 = seed, Internal Resolution 1 = seed, VI Skip Auto, hack toggles as compiled). The `State()` placeholders (dual core false, sensor bar 2, etc.) differ from the real defaults but are replaced by `sync()` before display and matter only to the search index.
- **Deep-link ids.** All five pause-menu links resolve (section 2.2) and are pinned by a test.
- **Engine silently switching.** The Performance engine row shows `effectiveEngine`, writes only when the user changes it, and writes Base even in a game (`setMainCpuCore`, fixed by the 2026-10-16 audit). A stored JIT core on a jitless build is shown as Cached Interpreter and not rewritten.
- **Library background default.** The Interface leaf, `LibraryBackgroundStyle.default` and `TVLibraryView`'s `@AppStorage` all default to Animated.
- **DefaultPreferences.plist** registers four keys (`launch_times`, `touch_overlay_programmatic`, `update_required`, `last_version`); only `touch_overlay_programmatic` (Controllers › Editable Controls, true) has a row and it agrees with the code fallback.

## 5. Not determined from code

- **Live versus restart for most Config rows.** Only the ~55 keys in `DOLSettingsKeyBridge` carry a hot/boot classification, and its own comment says it was inferred, not probed. Rows marked `n/c` need an in-game check (change the value, observe the picture/sound/timing). This covers the whole Graphics Hacks and Enhancements pages apart from the six keys marked `live*`.
- **What the other scripts' output means.** `scripts/icube_config_lint.py` exits 1 on this commit: 8 "dangling" keys, 2 "iOS-dangling", 5 "defaults-disagree", 15 "competing". Each dangling key was checked and is a false positive for Settings: the SYSCONF keys are read through `SYSCONF_SETTINGS` in `SaveToSYSCONF`; `MAIN_TOUCH_PAD_OPACITY` and `MAIN_TOUCH_PAD_IR_MODE` are read through the bridge getters by the overlay; `MAIN_ENABLE_CHEATS` is read through `Config::AreCheatsEnabled()` (ActionReplay.cpp, GeckoCode.cpp); `MAIN_CONFIRM_ON_STOP` is read by `EmulationScreen.swift:1664` and `PauseMenuView.swift:987`. `MAIN_FP_FAST` and `GFX_HACK_GPU_EFB_PEEK_RESOLVE` have bridge setters but no Settings row. The "reset DE-TUNES" lines for Fast Disc, DSP Thread, Immediate XFB and Wait-for-Shaders are also false positives: `resetGameplayConfigKeys` forces those values with `SetBase` after the delete (DOLConfigBridge.mm ~1393-1411). `check_settings_wiring.py` passes. Not examined: the 15 "competing" and 5 "defaults-disagree" entries beyond the ones already listed (Findings F5).
- **Config keys with a bridge setter but no Settings row** (debug API only): `cirDynTargetCache`, `cirGatherPipeCopyFusion`, `cirLongBlocks`, `cirMemMicroOps`, `cirMicroPairs`, `cirRecordChaining`, `mainFpFast`, `connectWiimotesForControllerInterface`. They are removed by Reset (the CIR sweep) and synced like any `[Core]` key.
- **Controller hub internals.** The per-player screens (`PlayerScreenModelBuilder`, ~4000 lines across `Hub/` and `Player/`) generate rows from live devices and capture state; only the hub-level rows and their writers are inventoried. Where the persistence of a control row was not traced it says so.
- **Whether OpenGL and Vulkan are built and usable on iOS and tvOS.** The Backend picker lists them unconditionally.
- **Real device contents.** What `Dolphin.ini`, `GFX.ini`, `SYSCONF` and the Controller INIs actually contain on a long-lived install, whether a real Wii Remote link key can ever land in `BT.DINF`, and what the Production CloudKit zone holds (R3).
- **The WebDAV/HTTP upload server's root.** Whether `User/Continuity/trusted-peers.json` is reachable through it (PVWebServer is an external package).
- **Pushed-version risk for the sync packages.** The classifier rules were read from the local DerivedData checkout of PVSyncRules 1.0.2 (`692ca3a`) and PVCloudSync 1.1.0; `Project.swift` allows any 1.x ≥ that, so CI could resolve newer rules.
- **Behaviour on tvOS focus and VoiceOver**, localisation of every row/footer, and the readability of footers: not audited here (R2 bullets 2 and 5).
- **Anything that depends on Xcode-only build configurations** other than `APPSTORE`/`USE_RETRO_ACHIEVEMENTS` (read from `AppStore.xcconfig`, `NonJailbroken.xcconfig`); the `Debug`, `Release` and sideload configurations may add or remove rows.
- **Hardware-specific values in `GameSettings/<id>.ini`.** Not inventoried; the file also carries cheats, so a per-game INI written on one device is applied whole on another.
