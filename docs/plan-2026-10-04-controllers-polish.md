# Controllers polish: Wii pointer, layout editor, boot assert, mapping overhaul

Research on `origin/develop` (d9522dd02b), 2026-10-04. Every claim below has a file:line cite so the
implementing session does not need to re-explore. Paths are under `Source/iOS/App/` unless they
start with `Source/Core/` or `Data/`.

Four workstreams, in the order they should ship. A–C are bug fixes with a root cause each. D is the
"unify everything" overhaul (controller hub phase 5).

| | Workstream | Size | Suggested model |
|---|---|---|---|
| A | Wii pointer: blank IR rows, Auto-Hide, "upright = cursor gone" | M | Opus |
| B | Layout editor: landscape clamp + positions jump on resume | M | Sonnet |
| C | `BaseConfigLoader.cpp:40` assert on relaunch | S | Sonnet |
| D | Mapping system unification (phase 5) | L, split into D1–D5 | Opus for D1/D3, Sonnet for the rest |

Repo rules that apply to every PR: `make test` / `make gate-release`; new strings need identity
entries in `Common/UI/Localization/{en,ja}.lproj/Core.strings` (`check_localized_keys.py --check`);
`git checkout -- build/xcframework` before committing; conventional commits, no AI trailers.

---

## 0. How the Wii pointer works on iCube (plain English, for the Discord answer)

There are **two different pointers** in Dolphin's emulated Wii Remote and iCube uses both:

1. **IR (camera) pointer** — the `IR/Up/Down/Left/Right` controls. Absolute position, ±1. On iCube
   the touch overlay writes these as `Axis 112–115` on the device `iOS/4/Touchscreen` (Wii Remote 1;
   ids 4–7 are Wii Remotes 1–4, `Source/Core/InputCommon/ControllerInterface/iOS/iOS.mm:47-49`,
   axis ids in `ButtonType.h:54-57`). This is what "Touch – Follow" and "Touch – Drag" drive.
2. **Motion (IMU) pointer** — `IMUIR/Enabled`. The core integrates the remote's gyro/accel to aim
   the camera. iCube feeds the phone's motion into the Wiimote's IMU axes (`Axis 625–636`) whenever
   the touch overlay is up (`Common/Swift/EmulationScreen.swift:1053-1058` force-enables
   `TCDeviceMotion`), so if `IMUIR/Enabled` is True the phone's tilt moves the camera **in addition
   to** whatever IR says. Tip the phone upright and the emulated remote points at the ceiling: the
   sensor bar leaves the camera's view and the hand vanishes.

iCube's **Pointer mode** (`MAIN_TOUCH_PAD_IR_MODE`: 0 Gyro, 1 Touch – Follow, 2 Touch – Drag,
default 2, `Source/Core/Core/Config/iOSSettings.cpp:11`) only chooses *what the app writes into
IR*. In Gyro mode the app computes the pointer from device attitude itself
(`TCDeviceMotion.handleIRCursorMapping`, only when mode == 0) and writes IR; the core's own motion
pointer is supposed to stay **off** on touchscreen slots
(`DisableCoreIMUPointerOnTouchscreenWiimotes`, `Common/Emulation/EmulationCoordinator.mm:1501-1525`).

`IR/Auto-Hide` hides the pointer after 2.5 s without movement (`Source/Core/Core/HW/WiimoteEmu/
Cursor.cpp:143-163`). A blank IR mapping is constant (0,0), so Auto-Hide = True + blank IR means
"gone after 2.5 s, forever".

The strings Yousef quoted (`Touchscreen/0/Cursor X+`, `Motion Sensors/0/…`) are **Android Dolphin
names**; they do not exist in this repo. The iCube equivalents of his manual fix are:
`IR/Up..Right = Axis 112..115` on `iOS/4/Touchscreen`, `IR/Auto-Hide = False`,
`IMUIR/Enabled = False`. That is exactly what the bundled `Data/Sys/Profiles/Wiimote/Touchscreen.ini`
already contains (lines 2, 14-23, 151). So the default is right; something *replaced* it.

---

## A. Wii pointer bugs

### A1. "Touchscreen profile shows IR = — and Auto-Hide = True; MotionPlus profile = stuck in centre"

Root cause, ranked:

1. **A non-touch profile was loaded onto the touchscreen Wii Remote and saved.** The player screen's
   profile list offers all bundled profiles with no device filtering (`Common/Emulation/
   TVControllerMappingBridge.mm:401-449`). `Physical Controller.ini` has no `IR/*` direction keys and
   `IMUIR/Enabled = True`; `Wii Remote with MotionPlus Pointing.ini` is for `Bluetooth/0/Wii Remote`,
   has no `IR/` keys at all and `IMUIR/Enabled = True`. `ControlGroup::LoadConfig` reads missing keys
   as `""` (`Source/Core/InputCommon/ControllerEmu/ControlGroup/ControlGroup.cpp:58-82`) → rows show
   "—". `loadProfile:forWiimote:restoreDevice:` keeps the touchscreen device and calls `SaveConfig`
   (`TVControllerMappingBridge.mm:477-501`), so it persists.
2. **Nothing repairs it.** `BindTouchscreen` reloads the profile only when the device binding
   changes or `!HasAnyBoundControl` (`EmulationCoordinator.mm:1532-1539`, 1575-1590), and that
   check only asks whether *any* expression is non-empty, not whether IR resolves.
   `DisableCoreIMUPointerOnTouchscreenWiimotes` runs only at boot (1676, 1705), never after a load.
3. **Core `LoadDefaults` fallback** (`EmulationCoordinator.mm:1563`) maps IR to `` `Cursor Y-` ``
   etc. (`WiimoteEmu.cpp:749-753`), dead names on iOS, and turns `IMUIR` on (`IMUCursor.cpp:15-23`).
4. **Auto-Hide = True** is written nowhere in the repo (`git log -S`). It comes from the user's own
   `User/Config/Profiles/Wiimote/Touchscreen.ini` (which shadows the bundled one in
   `LoadTouchscreenProfile`, 1550-1561) or from the Advanced → Pointer group toggle.

### A2. "Since ae374fd: phone flat = OK, lift upright = hand disappears and never returns, gyro is OFF"

ae374fd870 is **NaN-free and only runs in Gyro mode** (`TCDeviceMotion.swift:262-294`,
`handleIRCursorMapping` gated on `irMode == 0`; unit quaternions, `atan2`, `sinHalf > 1e-12`
guard; and `irCursorWrites` clamps with Swift `min/max`, which maps even a NaN to ±1, i.e. pinned,
not hidden). It is a red herring for a user in Follow/Drag mode. Real causes, ranked:

1. **The core motion pointer (`IMUIR`) is ON for the touchscreen Wii Remote while the app always
   feeds it phone motion.** Upright → camera aims at the ceiling → no IR → hand gone. "Never
   returns" because `IMUIR/Recenter = Button 800` in Touchscreen.ini is a button the iOS device
   never creates (`Touchscreen.mm:180-200`), yaw integration is clamped and unstable near 90° pitch
   (`Dynamics.cpp:320-343`), and the IMU feed cannot be switched off while the overlay is up
   (`TCDeviceMotion.swift:216, 223, 244, 287` — the conditions are complementary).
   Ways `IMUIR` gets turned on:
   - any profile load lacking `IMUIR/Enabled` (A1);
   - **hiding the overlay turns it ON** (`EmulationScreen.swift:1066-1073`,
     `setWiiIMUPointEnabled(!active)`) and it is only set back on the next overlay show; with
     80535973be (Oct 1, same TestFlight window as ae374fd) the early return when
     `touchscreenSlot(.wii) == nil` means some paths never disable it at all;
   - core `LoadDefaults`.
2. **The pointer mode is really Gyro although the user believes it's off.** Apply Recommended
   Settings sets `.gyro` (`Common/UI/Settings/SwiftUI/EnhancedMotionControlsView.swift:108`); a
   per-game override does too (`Common/Swift/GameProfiles.swift:231-236`). Then upright pins the
   pointer at the top edge (≈π/2 × gain before clamp), a re-baseline while upright pins it at the
   bottom when laid flat, and Auto-Hide hides a pinned pointer after 2.5 s. `TCDeviceMotion.
   orientation` is only refreshed by explicit `statusBarOrientationChanged()` calls, not on
   rotation, so the orientation re-baseline (`TCDeviceMotion.swift:347-353`) fires unpredictably.

### A. Fixes (one PR, `fix(pointer): …`)

1. **`IMUIR` off on touchscreen slots, always.** Call `DisableCoreIMUPointerOnTouchscreenWiimotes()`
   (or a per-slot `SetIMUPointerEnabled(false)`) after every Wii profile load whose device is
   `iOS/*/Touchscreen` (`TVControllerMappingBridge.mm:477-501`, `LoadTouchscreenProfile`
   including the `LoadDefaults` branch at 1563) and in `EmulationScreen.swift:1066-1073` only
   enable it when the slot's device is **not** a touchscreen (a gyro pad owns it). Decide: do we
   want "phone as Wii Remote" motion aiming at all while the overlay is hidden? If yes, it must
   recenter on show and have a working Recenter (bind `IMUIR/Recenter` to a real touchscreen
   button, e.g. a new `Button 800` in `Touchscreen.mm`, written by the Recenter Pointer actions).
2. **Repair the IR rows on touchscreen slots.** Extend `HasAnyBoundControl` → `HasUsableIRBinding`
   (IR/Up..Right non-empty and resolvable on the bound device); when false on a touchscreen slot,
   re-apply the IR block from the bundled Touchscreen.ini (`Axis 112–115`, Auto-Hide False) without
   touching the user's other bindings. Run it in `BindTouchscreen` and after a profile load.
3. **Filter the profile list by device** (`profilesForWiimote`, `TVControllerMappingBridge.mm:
   401-449`): on a touchscreen slot show Touchscreen + user profiles whose `Device =` is a
   touchscreen; hide `Wii Remote with MotionPlus Pointing` and `SDL Gamepad` on iOS entirely (no
   Bluetooth/SDL backend is built, `CMakeLists.txt:755-757`). Loading an incompatible profile
   should at minimum keep the slot's IR/IMU blocks.
4. **Make Pointer mode honest.** Apply Recommended should not silently switch the mode to Gyro
   (or must say so in its confirmation). Pointer mode writes from the player screen / top bar go
   to Base when no per-game override is active and the UI must label a CurrentRun write as
   "this game only" (`DOLConfigBridge.mm:243-245`, `PointerModeController.swift:65-75`).
5. **Gyro-mode hardening (ae374fd follow-up):** update `TCDeviceMotion.orientation` on rotation
   (observe `UIDevice.orientationDidChangeNotification` or hook `HostView.onOrientationChange`,
   `EmulationScreen+TouchAndMotion.swift:155-172`); add tests for flat↔upright 90° swings, the
   re-baseline/recenter logic, and `.portraitUpsideDown`. Verify the CoreMotion accelerometer sign
   assumed by `TCDeviceMotionMappingTests.swift:18-40` (face-up = +1 g) on a phone; CoreMotion
   documents gravity as −1 g on z face-up, which would make the core see an upside-down remote.
6. **Remove the 2× pair write?** `TouchOverlayIRPad.sendIR` writes the same value to both halves
   of each pair (`TouchOverlayIRPad.swift:272-281`, by design, "§6.4"), so a finger halfway to the
   game-rect edge already pins the pointer. Leave as is in this PR; note it for D (it's why
   "sensitivity" feels odd in Follow mode).

Tests: `DolphiniOSTests` — profile-load-on-touchscreen keeps IR/IMU blocks; `IMUIR` stays false
across overlay hide/show on a touchscreen slot; TCDeviceMotion rotation re-baseline.
Device check: Angry Birds Trilogy, Touchscreen profile, Follow and Drag; load Physical Controller
then back; hide/show overlay; tip the phone upright in each mode.

---

## B. Layout editor: landscape

Two editors exist and they lay out against different rectangles:

- **In-game editor** (long-press empty overlay space): canvas = full screen incl. safe areas
  (`TouchOverlay/TouchOverlayView.swift:51-57`, drawn edge-to-edge 115-116). Same `bounds` for
  draw, drop, resize, clamp. Leaving edit mode cannot move anything.
- **Settings editor** `TouchOverlayLayoutEditorView` (`Common/UI/Settings/SwiftUI/
  ControllersRootView.swift:127-157`, pushed from the hub: pause menu / top bar → Controllers → Edit
  Layout…): the same `TouchOverlayView` inside a `VStack` under a nav bar and a segmented picker,
  inside the safe area. On a 17 Pro Max landscape its canvas is ≈832×315 instead of 956×440.

Positions are stored as centre fractions of whatever canvas was used (`TouchOverlayLayoutStore.
swift:150-181`), re-clamped on load (`resolvedBox`, 125-142). Sizes are scale × a default that is
recomputed from the canvas (`u = clamp(min(w,h)/390, 1...1.35)`, `TouchOverlayDefaults.swift:147`).

### Root causes

1. **Report 2 (controls jump on resume):** the Settings editor normalizes against the smaller,
   offset rectangle; gameplay maps the fraction onto the full screen:
   `x_game ≈ (x_screen − 62) × 1.149`, `y_game ≈ (y_screen − ~104) × ~1.4`, then re-clamps. A stick
   centred on the left goes left+up ("top corner"); an enlarged A/B pushed to the bottom lands
   ~36 pt above the real bottom ("snapped higher"). Group sizes are also ~13% bigger in game
   (`u` 1.0 vs 1.128). The live overlay behind the hub sheet re-renders on every store write
   (`revision`, `TouchOverlayView.swift:66`), so the user sees the jump when the sheet closes.
   `TouchOverlayLayoutTests.swift:226-228` currently *asserts* this remapping.
2. **Report 1, Settings editor:** the editable rectangle is inset 62 pt each side and ~100 pt at
   the top (nav bar + picker ≈ 0.7"), but the dark backdrop extends into the side safe-area strips,
   so the clamp looks like it fires early. The Dynamic Island hides one strip → "left is fine".
3. **Report 1, in-game editor:** the 80 pt top reveal strip (`EmulationScreen.swift:348, 393-398,
   818-830`, zIndex 1) and the 64 pt top bar (zIndex 2) sit above `touchPadsContainer` (zIndex 0,
   1049). In landscape (top inset 0) the Reset/Done capsule (`TouchOverlayView.swift:209-241`,
   y≈16-70) is entirely under the strip: tapping it reveals the top bar instead. Drags starting in
   the top 80 pt never reach the overlay. In portrait the 62 pt inset pushes the capsule below the
   strip, which is why portrait works. Side effect in play: controls placed in the top 80 pt get no
   touches while the bar is hidden.
4. The live drag preview is unclamped (`PositionedTouchGroup.swift:105`) and the clamp is applied on
   release (107-108) → visible snap-back. Low confidence: `DragGesture` in `.local` space inside a
   view moved by `.position` (66, 76, 92) can under-track.

### Fixes (one PR, `fix(overlay): …`)

1. **One canvas.** When a game is running, "Edit Layout…" dismisses the hub/pause menu and puts the
   live in-game `TouchOverlayView` into `.layout` (notification or a `ControllerManager` flag the
   overlay observes); the picker's pad kind should default to the running pad, not `.gameCube`
   (`ControllersRootView.swift:128`). Outside a game, present the editor full-screen with
   `.ignoresSafeArea()` and floating chrome so `geo.safeAreaInsets` are the real ones and the
   canvas equals the screen. Add a test that editor and gameplay canvases are equal for a given
   device, and flip `TouchOverlayLayoutTests.swift:226-228` to assert positions are stable.
   Longer term: store an edge-anchored offset in points rather than a 0–1 fraction so a layout
   survives canvas changes.
2. **Edit mode owns the screen.** Lift an `isEditingLayout` flag into `EmulationScreen`; while set,
   hide the top bar and the reveal strip (or give `touchPadsContainer` a higher zIndex in edit
   mode). Move the Reset/Done capsule to bottom-centre or below 80 pt in landscape.
3. **Clamp the live preview** in `onChanged` with the same `resolve`, and use
   `DragGesture(coordinateSpace: .named("overlay"))`.
4. Decide one clamp rectangle for both editors (full canvas; the defaults already stay inside the
   safe area, `TouchOverlayDefaultLayoutTests`). Draw the safe-area edges faintly in edit mode so
   the user sees why a control stops.
5. The upright Wii Remote IR pad fills everything but a 24 pt margin (`TouchOverlayDefaults.swift:
   52`), which makes the in-game long-press practically unreachable; give edit mode an explicit
   entry (top bar / pause menu row) rather than relying on the long-press.

Device check (17 Pro Max landscape): drag a stick to each edge and corner, resize A/B at the
bottom, Done, resume — nothing moves; portrait unchanged; Reset.

---

## C. `BaseConfigLoader.cpp:40` assert (`TransferSYSCONFControlToGuest`)

`ASSERT(!s_sysconf_controlled_by_guest)`. Sequence:

- `BootManager::BootCore` transfers SYSCONF to the guest (`Source/Core/Core/BootManager.cpp:163`)
  **before** `Core::Init`.
- `Core::Init` fails early with "Emu Thread already running" when the state is not `Uninitialized`
  (`Source/Core/Core/Core.cpp:236-242`), i.e. the previous game is still `Stopping`.
- `RestoreConfig()` (which transfers control back) lives in the emu thread's HW teardown guard
  (`Core.cpp:675`), so on an early `Init` failure it never runs → the flag stays set → every later
  boot asserts. "Ignore" can't help: `Core::Init` fails again.
- iOS trigger: the launch loop waits only while `Core::IsRunning` (`EmulationCoordinator.mm:1910`),
  which is false during `Stopping`, so exiting a game and quickly launching another races the
  teardown. The user's Discord thread says it happened right after editing controls (hub sheet →
  game exit/relaunch), which fits. Joe's "micro-op fusion / signals and pending timers" guess is
  about something else; this one is plain boot ordering.

Fix (`fix(core): …`, S):
1. In `BootCore`, if `Core::Init` returns false, call `RestoreConfig()` (or move the transfer
   after a successful `Init`) so a failed boot leaves SYSCONF with the host.
2. In `EmulationCoordinator`, wait for `State::Uninitialized` (the state callback already signals it,
   1879-1884) before `BootCore`, and return a user-facing error instead of `PanicAlertFmt("Failed
   to init core!")` (1872-1874).
3. Since this is in the core, it needs an xcframework rebuild (`BuildiOSXCFramework.py`) and a
   `build: refresh the prebuilt core` commit per repo convention (see 5343a78f39).

---

## D. Mapping system unification (controller hub phase 5)

Phases 1–4 (docs/handoff-2026-09-28…10-02) are all on develop. What is left is listed below from a
full inventory; the "Known gaps" from phase 4 are folded in. Suggested split into five PRs.

### D1. Stop wiping the user's mappings; make choices stick (L, Opus)

Where a choice is overwritten today:
- Pad disconnect with no other pad → `assignTouchscreenToGCPort` loads Touchscreen.ini over the
  custom GC P1 mapping (`AssignmentEngine.swift:72-74`, `TVControllerMappingBridge.mm:235-289`); on
  reconnect "Physical Controller" loads because nothing binds the device.
- Boot: `EnsurePad1DefaultsToTouchscreen` ignores pins and reloads Touchscreen.ini when the pad is
  switched off at boot (`EmulationCoordinator.mm:1576-1592, 1639-1677`); SIDevice 0 is forced to a
  GC controller even in Wii titles / when P1 was turned off (1859-1862).
- Hub Overlay Style → Wii: `ensureWiimote1EmulatedTouchscreen` runs twice (`ControllerManager.
  swift:12`, `EmulationScreen.swift:1312-1316`) and loads Touchscreen.ini over a pad's Wii Remote 1.
- `Physical Controller.ini` and `Touchscreen.ini` both carry `Extension = Nunchuk`, so any default
  load forces Nunchuk over the user's extension.
- A profile named "Touchscreen" flips the port's device (`assignTouchscreenToGCPort` never re-sets
  the device after load, unlike `BindTouchscreen` at 1585-1589).
- In memory only, lost on relaunch: Extension/Sideways (`DOLWiimoteBridge.mm:43-73`, no
  `SaveConfig`), `overlayMode`, the loaded profile's name (`PlayerScreenViewModel.swift:50-70`,
  reads "Custom" after relaunch). `BridgeControllerConfigWriter.saveConfig`'s "flush" only writes
  Dolphin.ini, not the input inis (`DOLConfigBridge.mm:968-976`).
- In-game Pointer/opacity writes land in CurrentRun when a per-game override exists and vanish at
  game end (`DOLConfigBridge.mm:243-245`).
- Pins are permanent and invisible (`controller_pinned_slots`, `ControllerManager.swift:33-67`).

Plan: a per-port mapping stash keyed by device qualifier, restored on reconnect instead of loading
the default; move the boot policy out of `EmulationCoordinator.mm` into `AssignmentEngine` (the C++
side keeps only bind/load/save, as its own comment at 1528-1532 asks); `EnsurePad1…` respects
pins; strip `Extension =` from the two defaults (or apply it only when the slot has no extension
yet); save after extension/sideways changes; persist `overlayMode` and the per-port profile name;
show pinned state with an "Auto" device option. Tests: `ControllerManager` connect/disconnect,
`EnsurePad1DefaultsToTouchscreen`, extension persistence, the disconnect→Touchscreen case
(`test_noControllers_bindsTouchscreenToPad1` currently asserts the bad behaviour).

### D2. Smarter auto-select (M)

- Wii title: a lone pad lands on Wii Remote **2** because slot 1 is always reserved for the overlay
  (`AssignmentEngine.swift:50, 84-90`); on tvOS there is no overlay at all. Put the first pad on
  Wii Remote 1 when no touch use is possible (tvOS) or the overlay is hidden; verify tvOS on device.
- Don't bind one pad to both a GC port and a Wii Remote in the same session unless the title needs it.
- Ship a `Data/Sys/Profiles/{GCPad,Wiimote}/DSU.ini` (today the "DSU" default load and Reset fail
  silently, `BridgeControllerConfigWriter.swift:58-65`).
- `FirstRunInitializationService.mm:20-47` loads Touchscreen.ini on tvOS too; skip it there.

### D3. One vocabulary, one writer per setting (M, Opus for the model, Sonnet for the UI)

Duplicates today:
- Pointer mode, 5 writers: player screen (`PlayerScreenModelBuilder.swift:171-177`), top bar
  (`EmulationTopBar.swift:382-386`), DSU controller (`DSUControllerView.swift:179-197`), Properties
  "IR Mode" (`TVSoftwarePropertiesView.swift:100`, labels raw 0 "None"/1 "Absolute" — wrong, 0 is
  Gyro and 1 is Follow; also the "Per-Game IR Mode" picker at 132-142 bypasses
  `PointerModeController`), Apply Recommended. Keep: player screen + top bar, both via
  `PointerModeController`; delete the rest or route them through it with `PointerMode.title`.
- Overlay style, 4 controls, 3 dead: hub "Overlay Style" works (memory only); More "Auto-select
  On-Screen Controller by System" (`auto_touchpad_by_system`, no reader), Properties "On-Screen
  Controller" and the library "Force GameCube/Wii Pad" (`GameProfile.touchControllerOverride`,
  nothing reads it) do nothing. Either wire `touchControllerOverride` into `overlayMode` at boot
  or delete all three.
- Analog stick gain/deadzone/smoothing: More → Analog Stick Settings **and** the DSU controller
  "Sticks" sheet (`DSUControllerView.swift:444-475`), same `dsu_*` keys, which only affect on-screen
  sticks (`TCManagerInterface.mm:97-99`). Keep one, rename it "On-Screen Stick Feel".
- Programmatic overlay toggle in More (`ControllerMoreSettingsView.swift:68-72`) and top bar "New
  On-Screen Controller (Beta)" (`EmulationTopBar.swift:391`); it is default-on. Drop the top-bar one.
- Wii extension/sideways: player screen (via `WiimoteSlotOptions`) and Properties "Wii Controller"
  (writes Wiimote 1 directly, global, unsaved, no "None"). Delete the Properties one.
- Recenter Pointer in 3 places (fine, but one implementation).

Names to settle (pick one each, apply everywhere incl. `TCWiiTouchIRMode.none` → `.gyro`):
- Pointer: "Pointer" with modes Gyro / Touch – Follow / Touch – Drag. Retire "IR Mode", "Touch IR
  Mode", "Motion IR Cursor", DSU's "Gyro/Follow/Drag" snackbar, and "Motion Pointer" vs "Aim with
  Controller Motion" (same `IMUIR/Enabled`).
- "Sensitivity" currently means drag gain, gyro multiplier, SYSCONF sensor-bar sensitivity, or
  stick gain depending on screen. Label each by what it is.
- "Profile" = Dolphin input profile. Rename Properties "Profiles (MVP)" → "Game Settings" and
  "Apply Recommended Settings" → "Recommended Motion Settings". Delete the word "preset".
- "On-Screen Controls" everywhere; "Touchscreen" only as the device name.

### D4. Delete dead code and controls (S, Sonnet)

- Unreachable: `DolphiniOS/UI/Settings/Controllers/ControllersTouchscreen{,IRMode}ViewController.mm`
  (excluded from the build, `Project.swift:270-271`; headers still compile). Delete with headers.
- `ControllerPresets.swift` + `ControllerStyleManager.applyPresetDefaults` and its non-localized
  "Applied X preset" toast, which fires 2–3× per connect (`ControllerManager.swift:160-200`,
  `EmulationScreen.swift:1300-1304`, `TVLibraryView.swift:1307-1310`); keep glyph detection.
- `TouchControlsViewModel` / `overlayIsWii()` (`EmulationScreen+TouchAndMotion.swift:10-24`),
  `ControllerManager.overlayIsWii` / `overlayModeRaw` / `overlayVisibleObjc` (70-78, 309),
  `VirtualMFiControllerManager` (`virtual_mfi_connect` has no reader).
- Real-Wii-Remote options with no backend on iOS/tvOS: "Continuous Wii Remote Scanning" (hub,
  `ControllerHubModelBuilder.swift:134-138`), "Enable Speaker", "Connect Wiimotes for Controller
  Interface" (More :54-63).
- Settings → Controllers writing SIDevice on appear (`ControllersRootView.swift:109-112`).
- Stale comments: `PlayerScreenState.swift:57-62` says the programmatic overlay is off (it is on,
  `DefaultPreferences.plist`); `PlayerScreenIO.swift:119` should use `TouchOverlayFlag.isProgrammatic`.
- Remove the dead `IR/Hide = Button 118` and `IMUIR/Recenter = Button 800` lines from
  Touchscreen.ini unless A1 gives them real buttons.

### D5. Help text and a better editor (M–L)

Help today: `ControllerHelp.swift:18-33` covers pause/fast-forward/Start only; none of the six
`ControlCategory` cases (Face, D-Pad, Sticks, Triggers, System, Motion); on the player screen only
two rows have subtitles; the 6DOF caption contradicts Apply Recommended (it turns 6DOF on and sets
Gyro, under which 6DOF is inactive, `EnhancedMotionControlsView.swift:63-65, 104-118`).

- Surface `NumericSetting::GetUIDescription()` (`Source/Core/InputCommon/ControllerEmu/Setting/
  NumericSetting.h:91`) through `DOLControllerSettingsBridge.mm:119` as row subtitles — the
  core already has the explanations for Total Pitch/Yaw, Vertical Offset, Dead Zone, etc.
- Per-category help for Motion rows (Shake, Pointer, Tilt, Swing), and captions for
  Device/Profile/Extension/Sideways/Reset and the More rows.
- Raw Bindings rows show expressions verbatim (`PlayerScreenModelBuilder.swift:229-235`) and
  touchscreen rows read "On-screen Button 100" (`BindingDisplay.swift:30`). Map `Axis 112–115` etc.
  to names ("Pointer Up") in `BindingDisplay`.
- Editor gaps vs desktop (`Player/CaptureRowView`, `ExpressionEditorView`): no input picker (the
  bridge has `inputs(forQualifiedDevice:)`), no live value, no per-control Default/Clear-all, no
  profile delete/rename, no device-filtered profile list, no IMU rows. Do the input picker +
  per-control default + profile delete first; a stick/IR visualiser last.
- Localize `TVSoftwarePropertiesView` labels, "DSU Client" (`DSUSettingsView.swift:33`), and the
  `GameProfiles` diff labels.

---

## Order and hand-off

1. **C** first (tiny, core, needs the xcframework refresh; unblocks testing everything else).
2. **A** — the TestFlight blocker. Ship with a one-line TestFlight note: "Load Profile →
   Touchscreen" repairs an already-broken slot until the auto-repair lands.
3. **B**.
4. **D4 → D3 → D2 → D1 → D5**: delete first so the unification touches less code; D1 is the risky
   one and benefits from D2/D3 having settled the names and writers.

Each PR: `make test DEST=… TEST_ARGS=…`, `make gate-release`, `check_localized_keys.py --check`,
device checklist from its section, and a `docs/handoff-…` note in the style of the phase 4 one.
