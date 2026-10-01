# Controller Hub — Phase 3: Player Screen — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One screen per player, pushed from the Controllers hub's player rows in place of `RemapPlayerView`. It covers everything a port needs:
- device and profile;
- the Wii Remote's extension and sideways;
- capture rows for every control, grouped Face / D-Pad / Sticks / Triggers / System / Motion;
- Pointer & Motion;
- a collapsed Advanced section: numeric settings, and raw expressions that Dolphin's own parser checks before they are saved.

**Architecture:** The screen is built the way the hub is:
- `PlayerScreenViewModel` (`@Observable`, `@MainActor`) reads `PlayerState` through the hub's existing `ControllerHubReading` seam. Everything else it reads or writes goes through a new `PlayerScreenIO` seam. `LivePlayerScreenIO` is the only new code that touches `ControllerManager`, `TVControllerMappingBridge`, `GCController`, `PointerModeController`, `MotionSettings` and the new `DOLControllerSettingsBridge`.
- `PlayerScreenModelBuilder` is pure: it takes a `PlayerScreenState` and a `PlayerScreenActions` and returns a `MenuModel`.
- `MenuScreen` renders the model. `PlayerScreenView` hosts it, plus one alert driven by the current prompt (Save Profile As…, replace, replace built-in, reset, save error). A controller answers it through `MenuScreen`'s `modal:`.

Three screens are pushed `MenuScreen`s, each one pick, then pop: Device, Load Profile and each raw-expression editor.

Four engine additions make the screen pad-navigable in both directions:
- The A-plus-d-pad double-step guard.
- A controller's A can activate a `.custom` row.
- A one-row tvOS stepper for long pickers.
- A pad Back for pushed screens that are not `MenuScreen`s.

No core (C++) change and no prebuilt refresh. Expression validation and numeric settings go through a new app-side ObjC++ bridge, which calls symbols the core dylib already exports.

**Tech Stack:** Swift 5 mode, SwiftUI (Observation, `NavigationStack`), ObjC++ bridge over Dolphin's InputCommon, XCTest (`@testable import iCube`), a Tuist-generated project, iOS 17+ / tvOS 17+.

**Spec:** `docs/superpowers/specs/2026-09-28-controller-hub-design.md`. Read it first. This plan implements "Delivery phases → 3. Player screen" and the spec's "Player screen" section. It also builds on:
- Phase 2's plan: `docs/superpowers/plans/2026-09-28-controller-hub-phase2-hub.md`.
- The Phase 3 start handoff: `docs/handoff-2026-09-30-controller-hub-phase3-start.md`.

## Global Constraints

- Platforms: iOS 17+ and tvOS 17+. Every change must compile for both (`make gate-release`).
- tvOS focus rules: a `List` row is one focus target. SwiftUI `Menu`/`Picker` have no usable tvOS presentation. Never `.buttonStyle(.borderless)` on tvOS.
- Notification names: declare `FOUNDATION_EXPORT NSNotificationName const DOLFooNotification;` in an ObjC `.h`, define it in the `.m`, and use `.DOLFoo` from Swift. Never a string literal at a call site.
- Existing `UserDefaults` key names must not change (user values carry over). The one new key, `motion_gyro_pointer_sensitivity`, is registered by `MotionSettings` (Task 6).
- Stage explicit file paths only; never `git add -A`/`git add Source`. `build/xcframework/*` is rewritten by local builds, so never stage it (`git checkout -- build/xcframework` before committing if a build touched it).
- Adding a source file needs `cd Source/iOS/App && tuist generate --no-open` before building. A task that adds a new test file runs `tuist generate --no-open` before its first "verify it fails" run.
- Gates, run from `Source/iOS/App`:
  - Tests: `make test SIM="iPhone 17 Pro"`, which must end in `** TEST SUCCEEDED **`.
  - Release compile for both platforms: `make gate-release`, which must print `** BUILD SUCCEEDED **` twice.
  - If another `xcodebuild` is running (`pgrep -f "xcodebuild .*iCube"`), wait for it to finish; the builds share the core's CMake directories.
  - `iCubeTests` is iOS-only (`Project.swift`, the `iCubeTests` target's `destinations: [.iPhone, .iPad]`), so tvOS branches are proven only by `make gate-release`.
- Commits:
  - Conventional (`feat:`, `fix:`, `refactor:`, `test:`, `docs:`, `chore:`), subject under 72 characters.
  - No `Co-Authored-By` or other attribution trailer. This is the repo owner's rule for this phase, and it differs from Phase 2's plan.
  - Any trailer that slips in is stripped when the branch is merged.
- `MenuScreen` renders a tvOS `.picker` as one focusable row per option (and drops the item's title), unless the item sets `isCompactOnTV` (Task 3). Do not add a `Menu` or `Picker` of your own on a tvOS path.
- No sheet nested in a sheet. Below the hub everything is a push (`NavigationLink`, `.navigationDestination`). The player screen's prompts are `.alert`s on its host, answered by a pad through `MenuModal`.
- No presentation or navigation-destination modifier (`.sheet`, `.fullScreenCover`, `.navigationDestination`, `.alert`) is attached to a row or a `Section` inside a `List`. Attach it to the `List` itself or to a view outside it.
- No core (C++) source change and no `build/xcframework` refresh in this phase. The new bridge calls only symbols the core already exports (Task 5, Step 1 checks them).
- Every task compiles for iOS and tvOS (`make gate-release`) and keeps `make test` green. The hub keeps pushing `RemapPlayerView` until Task 14 swaps it.
- This checkout is shared with other sessions. DO NOT git reset / rebase / push, do not switch branches, and do not touch develop's history. The one allowed checkout is the path-limited `git checkout -- build/xcframework`. Commit only the files a task lists.

## Decisions made while planning (differences from the spec, and rulings)

The repo owner signed off decisions 1–12 on 2026-09-30. Naming (decision 8) is deferred to the Phase 4 plan. Decision 13 is confirmed and is fixed by a separate change, outside this phase. The **Ruled** entries below them are forced by the code and are low stakes.

### Signed off by the owner (2026-09-30)

1. **Signed off — the player screen owns its own view model, which reads `PlayerState` through the hub's seam.**
   - The spec says `ControllerHubViewModel` reads the bridges into `ControllerHubState` and `PlayerState`, and is the only unit that touches them.
   - The hub view model stops observing when a pushed screen covers it (`ControllerHubView.swift:38-43`). Owning the player screen too would need reference-counted `start`/`stop` across push and pop.
   - Chosen: `PlayerScreenViewModel`, owned by `PlayerScreenView` as `@State`.
     - It fills `PlayerState` through the same `ControllerHubReading` methods: `boundQualifier`, `wiiExtension`, `isSideways`, `connectedPads`.
     - Every other bridge access goes through `PlayerScreenIO`. Its live implementation is the only new code that touches the bridges.
   - Tasks 11, 12, 14.
2. **Signed off — a motion-capable pad's port: Pointer & Motion is one toggle, "Aim with Controller Motion".**
   - `PointerMode` and `MotionSettings` drive only the phone's gyro and the touch overlay (`PointerModeController.swift:39-43`; `TCDeviceMotion.swift:303-322`).
   - A pad's pointer comes from its profile instead. `Data/Sys/Profiles/Wiimote/Physical Controller.ini:29-41` binds the pad's `Gyro …` inputs to the Wii Remote's IMU groups and sets `IMUIR/Enabled = True`.
   - The toggle writes that group's `Enabled` setting:
     - `WiimoteGroup::IMUPoint` is 12 (`WiimoteEmu.h:48-64`).
     - `GetWiimoteGroup` returns `m_imu_ir` for it (`WiimoteEmu.cpp:363-364`), the `"IMUIR"` `IMUCursor` group (`WiimoteEmu.cpp:233`).
     - That group has an `enabled_setting`, because `IMUCursor` is not `AlwaysEnabled` (`IMUCursor.cpp:15-21`, `ControlGroup.cpp:28-33`).
   - "Motion-capable" means the pad has a gyro: `GCController.motion?.hasRotationRate == true`, carried as `ConnectedPadState.hasGyro`. `MFiController.mm:171-198` adds the `Gyro …` inputs only when `motion.hasRotationRate`. An accelerometer-only pad does not count.
   - Tasks 5, 8, 9, 11.
3. **Signed off — no "Off" in the pointer picker.**
   - The core has no off value: `MAIN_TOUCH_PAD_IR_MODE` is 0 Gyro, 1 Follow, 2 Drag (`PointerModeController.swift:6-7`).
   - The touchscreen port offers Touch – Follow / Touch – Drag / Gyro, the spec's order minus "Off". "Off" exists only on a pad port, as decision 2's toggle.
4. **Signed off (changed from the draft) — two Sensitivity rows, one per mode.**
   - In Touch – Drag, with the programmatic overlay on, Sensitivity is the drag gain, `touch_overlay_ir_pointer_gain`.
     - Only that overlay reads it (`TouchOverlayView.swift:182`), and the overlay is off by default (`DefaultPreferences.plist:11-12`).
     - Steps 0.25× to 4× (`TouchOverlayIRGeometry.dragGainRange`, `TouchOverlayIRGeometry.swift:55`).
   - In Gyro, Sensitivity is the new gyro pointer sensitivity, key `motion_gyro_pointer_sensitivity`.
     - Registered default 1.0 in `MotionSettings.defaults`.
     - It is a multiplier on the existing constants (`TCDeviceMotion.swift:71-72`, 2.66 horizontal and 2.0 vertical), so behaviour at the default is unchanged.
     - Steps 0.5× to 3×.
     - The multiply moves into the pure `TCDeviceMotion.gyroPointerOffsets(…, gain:)`, which is unit-tested.
   - No restart notice is needed for the gyro sensitivity: `handleIRCursorMapping` reads `MotionSettings` on every motion sample (`TCDeviceMotion.swift:303-307`).
   - `DefaultPreferences.plist` defines no `motion_*` key, so `MotionSettingsTests.testBundledDefaultPreferencesDefineNoMotionSettingsKey` keeps holding with the new default.
   - Task 6 implements the new setting; Task 9 adds the rows.
5. **Signed off — the profile name is remembered per port for the app session.**
   - Nothing records which profile a port's mapping came from. `loadProfile:` copies the ini into the live controller (`TVControllerMappingBridge.mm:419-443`). `RemapPlayerView` keeps the name in `@State` only (`RemapPlayerView.swift:38`, `:278-281`).
   - `PlayerProfileMemory` remembers it, setting it on Load, Save As, Reset and on a device change that reloads a profile. It shows "(edited)" after a change, and "Custom" when the name is unknown (Task 12).
6. **Signed off — the four Advanced Motion Settings leftovers stay in More.**
   - `EnhancedMotionControlsView.swift:64-139` offers four things the player screen does not:
     - Horizontal Movement (roll / yaw).
     - Enable 6DOF Motion Controls.
     - Wiimote / Nunchuck Motion Controls.
     - Apply Recommended Settings.
   - `EnhancedMotionControlsView` comes off Phase 4's delete list until they have a home (Task 16's handoff).
7. **Signed off — Invert X / Invert Y appear only in Gyro mode.** This differs from the spec's list. Only the gyro pointer reads `motion_invert_roll` / `motion_invert_pitch` (`TCDeviceMotion.swift:305-322`), and `EnhancedMotionControlsView.swift:64-83` gates them the same way.
8. **Deferred to the Phase 4 plan — "On-Screen Style" (hub, `ControllerHubModelBuilder.swift:101`) vs "Overlay Style" (More, `ControllerMoreSettingsView.swift:88`).** Phase 3 changes neither label. Task 16's handoff carries the question forward.
9. **Signed off — Device is a pushed pick-list, not a stepped picker.**
   - On iOS, A cycles a `.picker` (`MenuScreen.swift:213-216`) and the d-pad steps it (`:386-390`). Each step would be a real assignment, and one A could wipe a custom mapping:
     - Assigning Touchscreen to a GameCube port always loads `Touchscreen.ini` over the mapping (`TVControllerMappingBridge.mm:228-253`).
     - For a Wii Remote, `BindTouchscreen` reloads the profile on any rebind (`EmulationCoordinator.mm:1576-1586`).
     - Stepping on to a pad then keeps that mapping, because `ControllerAssignmentService.assign` skips the default profile when a mapping exists (`ControllerAssignmentService.swift:39-47`).
   - The Device row is a `.destination` that pushes `DeviceListView`, the same pattern as Load Profile. One pick is one assignment, then the list pops. The row's subtitle shows the current device, including "<name> (Disconnected)".
   - tvOS uses the same pushed list. The tvOS-only headed "Device" section workaround for the exploded picker is gone.
   - The profile-name memory treats any switch to the Touchscreen as loading the "Touchscreen" profile:
     - GameCube always reloads it.
     - On a Wii Remote, `BindTouchscreen` reloads whenever the bound device changes (`EmulationCoordinator.mm:1581-1586`). It always changes here, because picking the current device is a no-op.
   - Tasks 8, 9, 10, 12.
10. **Signed off — guard rails on Reset and Save As.**
    - Reset to Default Profile asks first: an alert on the host, which a pad answers through `MenuModal`. It is not a sheet.
    - Save Profile As… is prefilled with the bound pad's name, else the player title. It is never a device-default profile name ("Physical Controller", "Touchscreen", "DSU"):
      - A user profile with such a name shadows the bundled one for every future first bind and every Reset.
      - `loadProfile:` checks the user directory first (`TVControllerMappingBridge.mm:432-433`), and so does `LoadTouchscreenProfile` (`EmulationCoordinator.mm:1548-1563`).
    - Typing one of those names (case-insensitive) asks "Replace the Built-In Profile?" first. The message says the saved profile will be used instead of the built-in one for future first binds and Reset to Default Profile on that kind of device. Confirming saves.
    - Saving over any other existing profile name asks "Replace Profile?" first.
    - Rules live in the pure `ProfileNaming` (Task 8). The flow lives in `PlayerScreenViewModel` (Task 12), and the single alert in `PlayerScreenView` (Task 14).
11. **Signed off — capture rows where capture is impossible.**
    - `canCapture`: the port's qualifier is non-empty and not `iOS/…`, and the bound device is not a missing MFi pad. The connected check applies to `MFi/…` qualifiers only.
    - So a DSU-bound port captures, as `RemapPlayerView` allowed (`RemapPlayerView.swift:95-97`, `deviceIsPhysical`). DSU devices are enumerated and auto-assignable (`TVControllerMappingBridge.mm:169`, `:269`; `AssignmentEngine.swift:98`).
    - A DSU-bound port never reads "(Disconnected)", because DSU devices are not `GCController`s and never appear in the hub's pad list.
    - Where capture is impossible (Touchscreen, No Device, a disconnected MFi pad), the capture rows are disabled, and one enabled hint row says why. Builder tests cover each case (Task 9).
12. **Signed off — switching a Wii Remote port from the Touchscreen to a gyro pad turns its motion pointer back on.**
    - The app disables the IMU pointer on every touchscreen-bound Wii Remote (`EmulationCoordinator.mm:1501-1525`, `group->enabled.SetValue(false)`). A rebind to a pad keeps the mapping, so the pad's pointer would stay off.
    - `PlayerScreenViewModel.setDevice` re-enables `IMUPoint`'s `Enabled` through the bridge whenever it binds a gyro pad to a Wii Remote port.
    - Covered by the fake-IO test in Task 12 and checklist items 12–13. See decision 13 for the rest of this problem.
    - The write must also survive a Wii boot. `EmulationScreen` used to switch slot 0's IMU pointer off whenever there was no touch slot; Task 13 guards it (see the Ruled entry "the emulation screen only touches the touch slot's IMU pointer").

### Confirmed, fixed separately (not in this phase)

13. **Confirmed — a port switched from the Touchscreen to a pad keeps the touchscreen mapping, whose inputs the pad does not have. A separate change to the assignment rule fixes it; Phase 3 does not.**
    - The touchscreen profiles bind on-screen inputs that MFi pads do not expose. For example:
      - `GCPad/Touchscreen.ini:3` has `Buttons/A = \`Button 0\``, where `Physical Controller.ini:3` has `\`Button A\``.
      - `Wiimote/Touchscreen.ini:144-151` binds the IMU to `Axis 631…` and sets `IMUIR/Enabled = False`.
    - Why the mapping is kept:
      - `ControllerAssignmentService.assign` keeps any existing mapping (`ControllerAssignmentService.swift:39-47`, the `hasMapping` condition added by `3613078adb`).
      - `ControllerHasAnyBoundControl` only tests for a non-empty expression (`TVControllerMappingBridge.mm:122-135`), so a touchscreen mapping counts.
    - The result: after Touchscreen → pad, the pad's buttons, sticks and gyro stay bound to touchscreen inputs until Reset to Default Profile.
    - It also hits auto-assign on connect (for example GameCube port 1), so it is not a player-screen problem.
    - The fix belongs to that separate change, which owns `ControllerAssignmentService.swift`, `TVControllerMappingBridge.{h,mm}` and `BridgeControllerConfigWriter.swift`.
    - No task in this plan edits those files. `LivePlayerScreenIO` only calls them, and `PlayerScreenStateTests` calls `BridgeControllerConfigWriter().defaultProfileName`.
    - The player screen adds no fallback of its own. Decision 12's IMU re-enable stays, because it is still needed once the mapping is right.
    - Merge order: Phase 3 merges after, or together with, that fix (Task 16's handoff). Checklist item 12 passes only with it.

### Ruled

- **Ruled — expression validation needs no core change.**
  - Every symbol the new bridge calls is exported (`T`) in all four tracked slices of `PVlibDolphin.framework`, 19 in all:
    - `ciface::ExpressionParser::ParseExpression`;
    - `InputReference::State`;
    - `ControlReference::GetInputGate`, `ControlReference::SetExpression` and `ControlReference::GetExpression` (reached through the inline `IsSimpleValue`);
    - `InputConfig::GetControllerCount` and `InputConfig::SaveConfig`;
    - `EmulatedController::GetStateLock`;
    - `Pad::GetGroup` and `Pad::GetConfig`;
    - `Wiimote::GetWiimoteGroup`, `GetNunchukGroup`, `GetClassicGroup` and `Wiimote::GetConfig`;
    - the `NumericSettingBase::GetUIName` / `GetUISuffix` getters;
    - `NumericSetting<int|double|bool>::GetType`.
  - This was checked with `nm -gU … | c++filt`; Task 5 Step 1 re-runs the check.
  - The app's ObjC++ bridges already compile against InputCommon headers (`TVControllerMappingBridge.mm:7-17`, through `Common.xcconfig`'s `Core/**` paths; `Project.swift:406-412` comment).
  - `Common/Emulation/*.mm` builds for both iOS and tvOS (the `Common/**/*.{m,mm}` glob in `Project.swift`).
- **Ruled — the spec's "installs a broken expression without complaint" is true only at the bridge.**
  - `ControlReference::SetExpression` installs the text and returns the parser's error (`ControlReference.cpp:52-59`).
  - `setPadControlExpressionForPort:…` and its siblings discard that error (`TVControllerMappingBridge.mm:543`, `:589`, `:652`).
  - The UI therefore checks with `ParseExpression` before saving, and installs nothing while the user is still typing.
- **Ruled — only an edited expression is checked for Save.**
  - `ParseStatus::SyntaxError` can still yield a working bareword fallback (`ExpressionParser.h:66-73`, `ExpressionParser.cpp:1119-1124`). So Save is disabled until the text differs from the original, and an untouched expression is never re-judged or rewritten.
  - The bridges report an unbound control as `"—"` (`TVControllerMappingBridge.mm:529`). The editor starts from `RemapControlRow.editableExpression`, which maps that back to `""`.
- **Ruled — capture rows are `.custom` rows, and a pad's A reaches them through `MenuItem.onCustomActivate` (Task 2).**
  - `MenuScreen.performActivate` ignores `.custom` (`MenuScreen.swift:221-222`). The spec asks for `.custom` so the row can carry its own gestures.
  - While a capture is armed:
    - iOS: the host passes a no-op `MenuModal`, which freezes the rows while the latches keep tracking the pad (`MenuScreen.swift:21-45`, `:362-373`).
    - Both platforms: the builder disables every row except the armed one, which leaves tvOS native focus nowhere to go.
    - Both platforms: `onBack` ignores B / Menu, as `RemapPlayerView.swift:117-121` did on tvOS.
  - After a capture binds, activation and Back are ignored for `rearmDelay` (0.5 s, an injected clock, tested in Task 12):
    - A capture binds while the button is still held, but a tvOS `Button` fires on release, and B / Menu still arrives as an exit command.
    - `RemapPlayerView` has the same structure (`:117-121`, `:361-375`) without the guard. Whether it misbehaves there is device-unverified.
- **Ruled — Clear stays on the capture row as `.contextMenu` and, on iOS, `.swipeActions`, and the raw-expression editor also has Clear.**
  - These are not the presentation modifiers the lockup came from. That lockup was state-driven `.sheet`s on a `Section` whose rows were not yet built (Phase 2 decisions).
  - A context menu or swipe action is raised by a gesture on the row's own, visible cell, so it cannot be waiting on a row the lazy `List` has not built.
  - `RemapPlayerView.swift:312-319` already ships both on rows inside a `List`.
  - A pad cannot long-press, so the editor's Clear (Task 10) is the pad path.
  - Fallback if checklist items 4 or 23 fail on a device: delete both modifiers from `CaptureRowView` and keep only the editor's Clear.
- **Ruled — the tvOS compact picker is built like `TVIntStepper` / `TVFloatStepper`, not as a `Button` (Task 3).**
  - The precedents (`SettingsSharedComponents.swift:67-100`, `TVFloatStepper.swift:7-52`) are a `.focusable(true)` `HStack` with `.focused`, a drawn focus ring and `.onMoveCommand`.
  - Left/right steps the value, wrapping as the iOS d-pad adjust does (`MenuItemRole.cycled`). Up/down move focus like any row. Select does nothing, as in the precedents.
  - Device-unverified: that `.onMoveCommand` fires on a focusable row inside a `List`, and that up/down still leave it (checklist items 20–21).
  - Fallback: remove `isCompactOnTV` from the numeric and Sensitivity items. Each then explodes into one row per option, which is usable but long.
- **Ruled — the remaining tvOS picker labels its options.** `MenuScreen.tvRow` explodes a `.picker` and shows only the option titles (`MenuScreen.swift:446-463`). Extension's options therefore read "Extension: None / Nunchuk / Classic" on tvOS (the existing `"Extension: %@"` key, `RemapPlayerView.swift:253`). Device is now a pushed list, so this applies to Extension only.
- **Ruled — A plus a d-pad left/right in one tick changes a picker once (Task 1).**
  - The builders' bindings read the snapshot the model was built from. So `performActivate` and then `tick`'s adjust would write twice from the same stale value (`MenuScreen.swift:213-216`, `:386-390`).
  - `MenuFocusRouter` drops the adjust when the same tick activated the same row, in both the single-pad and the multi-pad path.
- **Ruled — pad Back for pushed screens is an explicit modifier, applied per destination (Task 4).**
  - `.padBackNavigation()` (iOS; tvOS Menu already pops) goes on More Controller Settings, Motion Source (DSU) and Edit Layout. That closes the Phase 2 gap.
  - It is not auto-wrapped around every `.destination`. The player screen and its pushed lists host their own `MenuScreen`, and scope order between a wrapper and an inner screen depends on `onAppear` order.
  - Still uncovered: screens pushed from inside More and DSU.
- **Ruled — numeric rows are stepped pickers.**
  - A slider can't be reached by a pad on iOS or focused on tvOS (Phase 2's Opacity, `ControllerHubState.swift:121-129`).
  - Each numeric setting is a `.picker` of about 20 steps (`NumericSettingSteps`, Task 7), and so are both Sensitivity rows. The steps always include the range's ends, the default and the current value.
  - Bool settings are toggles. An expression-driven setting is read-only.
- **Ruled — which controls go in which Buttons group (Task 7).**
  - Categories are keyed by owner, group id and control index, from the core's `AddInput` orders (`GCPadEmu.cpp:46-50`, `:60-63`, `WiimoteEmu.cpp:214-218`, `Nunchuk.cpp:37-38`, `Classic.cpp:56-61`, `:72-75`).
  - Rumble is an output, and capture polls inputs, so Rumble is left out of Buttons and stays editable under Advanced → Raw Bindings.
  - Sizes:
    - A Wii Remote with a Classic Controller lists 59 capture rows: Face 8, D-Pad 8, Sticks 10, Triggers 6, System 6, Motion 21 (`Cursor.cpp:27-32`, `Force.cpp:18-23`, `Tilt.cpp:18-23`, `Force.cpp:127-131`).
    - A GameCube port lists 24.
- **Ruled — Advanced lists the stick, trigger, IR and IMU-pointer groups' numeric settings (Task 7).** These are:
  - GameCube: Control Stick, C-Stick, Triggers.
  - Wii Remote: Pointer (`Point` = 3) and Motion Pointer (`IMUPoint` = 12).
  - Nunchuk: its stick. Classic: both sticks and its triggers.
  - "Stick range" is Dolphin's Gate Size (`AnalogStick.cpp:89-97`).
- **Ruled — Device, Load Profile and the expression editor are pushed hosts, not `.navigation`.** A `.navigation` child is built once at push time (`MenuScreen.swift:217-218`), and it cannot pop itself after a pick.
- **Ruled — no screen renders before its first read (Tasks 10, 12, 14).**
  - `PlayerScreenView` builds from `PlayerScreenViewModel.displayState`. Before `start()`, that is a fresh read of the bridges, and reading in `body` changes no state. So the first render, and tvOS `.defaultFocus` (computed from the first model, `MenuScreen.swift:401-425`), never see the `.empty` state.
  - The view model's `init` still reads nothing: the hub rebuilds the host on every render.
  - `ProfileListView` reads its names during its first `body` and caches them on appear. `DeviceListView` reads the view model's snapshot, which `PlayerScreenView` took at push time. Neither flashes "No profiles" or an empty list.
  - The builders stay pure.
- **Ruled — the Device list keeps itself current while the player screen is stopped (Tasks 10, 12).**
  - Pushing any leaf fires `PlayerScreenView.onDisappear` → `viewModel.stop()`, which removes the observers. Without more, a pad that connects while the list is open would not appear.
  - Of the two options, the list observing the notices itself is the one that is correct for all three leaves and for tvOS:
    - Only the Device list shows live device state. Load Profile reads files, and the editor edits one control's text.
    - The other option, not stopping while a child is on top, needs the host to tell "a child was pushed" from "I was popped". `onDisappear` fires for both, and nothing else in the engine says which. Stopping also ends an armed capture, which is wanted whenever anything covers the rows.
  - So `DeviceListView` observes `.GCControllerDidConnect`, `.GCControllerDidDisconnect`, `.TVControllerDevicesChanged` and `ControllerManager.assignmentsChanged` (all declared names, the set `PlayerScreenViewModel.start()` uses) and calls its `refresh` closure, which is `viewModel.reload()`. It also refreshes on appear.
  - `PlayerScreenViewModel.setDevice` takes a fresh snapshot (`reload()`) before its same-choice guard and before deciding `bindsGyroPad`, so it never acts on the pads it saw at push time.
  - A view-model test covers "a pad connects while the list is open, then is picked".
- **Ruled — one alert, driven by the prompt (Task 14).**
  - `PlayerScreenView` attaches a single `.alert(_:isPresented:presenting:)` to the `MenuScreen`, outside the List, instead of five chained `.alert(isPresented:)` modifiers.
  - It presents a retained copy of the last non-nil prompt (`@State shownPrompt`), so the title, which `presenting:` does not scope, and the message never blank while the alert animates out.
  - Titles, messages and button sets come from the pure `PlayerPrompt.title` / `message`, which are tested.
  - A follow-up prompt (Replace after Save As, the save error) still arrives one main-actor hop later (`present(_:)`), after the closing alert has cleared `prompt`.
  - The Save As `TextField` sits in the alert's actions as before (`RemapPlayerView.swift:158-164` precedent on both platforms). A pad answers every prompt through `MenuModal`.
- **Ruled — the emulation screen only touches the touch slot's IMU pointer (Task 13).**
  - `EmulationScreen` switches the core IMU pointer of `controllerManager.touchscreenSlot(system: .wii) ?? 0`:
    - off at every Wii boot (`EmulationScreen.swift:1087-1088`);
    - to `!active` whenever `isTouchControlsActive` changes (`:1034-1036`).
  - With a pad on Wii Remote 1 and no touchscreen slot, `touchscreenSlot` is nil (`ControllerManager.swift:360-375`). The `?? 0` then hits the pad's port and undoes decision 12 on every boot.
  - Task 13 guards both sites on a non-nil touch slot. With no touch slot, nothing on the screen drives IR, so there is nothing to keep from fighting.
  - Nothing else re-disables it:
    - Those two lines are the only `setWiiIMUPointEnabled` calls in the app (`git grep`, Swift / ObjC / ObjC++). The comment at `:1084-1085` about the pads' own `onAppear` / `onDisappear` is stale.
    - `DisableCoreIMUPointerOnTouchscreenWiimotes` (`EmulationCoordinator.mm:1501-1525`, called at `:1676` and `:1705`) skips any Wii Remote not bound to a Touchscreen.
- **Ruled — the "Aim with Controller Motion" toggle keeps the new bridge's `setGroupEnabled`, not `TVEmulationBridge.setWiiIMUPointEnabled`.**
  - Both take the same `ControllerEmu` state lock and write the same `IMUPoint` `enabled` value.
  - `setWiiIMUPointEnabled` (`TVEmulationBridge.mm:333-360`) is the emulation screen's runtime switch: it never calls `SaveConfig`, so the value is lost unless some other write saves the config.
  - The toggle is a mapping choice the user expects to persist, and `setGroupEnabled` saves the Wii Remote config (Task 5).
  - So there are two call sites with two jobs, runtime versus persisted, on one lock. Folding them together would change the boot path's persistence, which Phase 3 should not.
  - The getter `isGroupEnabled` stays; the toggle reads it.
- **Ruled — the current profile name is the Load Profile… row's subtitle.** A separate name row would be one more tvOS focus stop that does nothing.
- **Ruled — `RemapPlayerView` is superseded here but not deleted.**
  - After Task 14 its only caller is `ControllerSetupView.swift:134, 212, 242`, which has had no callers since Phase 2 Task 8.
  - Task 16 puts `RemapPlayerView.swift` on Phase 4's delete list.
  - The "`DeviceFamily.from` twice per row" note is moot. The new builder computes the family once per build.
- **Ruled — player actions get a writer seam; the hub's Phase 2 actions do not.** `PlayerScreenIO` carries every player write, so the view model tests run on a fake. The hub's closures (`ControllerHubViewModel.swift:157-195`) are left as they are.
- **Ruled — device and profile changes use `reconcile(autoAssign: false)`.**
  - Devices go through `ControllerManager`'s explicit wrappers, each ending in `reconcile(autoAssign: false)` (`ControllerManager.swift:484-542`).
  - Loading a profile calls it explicitly, as `RemapPlayerView.swift:578-598` does.
  - Extension and sideways go through `WiimoteSlotOptions` (`WiimoteSlotOptions.swift:26-40`).
- **Ruled — only Shake to Wiggle posts the motion-settings notice.**
  - `EmulationScreen` decides whether the motion system runs at all from the shake setting, at boot and on `"DOLMotionSettingsChanged"` (`EmulationScreen.swift:1079`, `:1102-1112`).
  - Invert and gyro sensitivity are read per sample (`TCDeviceMotion.swift:303-322`). The drag gain is read when the overlay renders.
  - Task 6 declares `DOLMotionSettingsChangedNotification` with the existing string. The ~56 literal call sites stay for the separate cleanup.
- **Ruled — Wii sections by port, not by title.**
  - A GameCube port never shows the Wii Remote section or Pointer & Motion.
  - The hub lists Wii Remote ports only for Wii titles, or for every system from Settings (`ControllerHubState.swift:21-34`).

## File Structure

| File | Responsibility |
|---|---|
| Modify `Source/iOS/App/Common/Swift/Menu/MenuFocusRouter.swift` | Drop an adjust that the same tick's activate already applied (Task 1) |
| Modify `Source/iOS/App/Common/Swift/Menu/MenuModel.swift` | `MenuItem.onCustomActivate` (Task 2), `MenuItem.isCompactOnTV`, `MenuItemRole.selectedTitle` (Task 3) |
| Modify `Source/iOS/App/Common/Swift/Menu/MenuScreen.swift` | `.custom` pad activation (Task 2); tvOS compact picker (Task 3) |
| Create `Source/iOS/App/Common/Swift/Menu/PadBackNavigation.swift` | `.padBackNavigation()`: B pops a pushed non-menu screen on iOS (Task 4) |
| Modify `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubViewModel.swift` | Pad Back on More / DSU / Edit Layout (Task 4); `hasGyro` (Task 8); the player screen as the player destination (Task 14) |
| Create `Source/iOS/App/Common/Emulation/DOLControllerSettingsBridge.h` / `.mm` | Parse check, numeric settings, group `Enabled` (Task 5) |
| Modify `Source/iOS/App/Common/Swift/BridgingHeader.h` | Import the new bridge (Task 5) |
| Create `Source/iOS/App/Common/Swift/Controllers/Player/ExpressionCheck.swift` | Parser verdict → editor message + canSave (Task 5) |
| Modify `Source/iOS/App/Common/Swift/Controllers/MotionSettings.swift` | Setters; gyro pointer sensitivity key and default (Task 6) |
| Modify `Source/iOS/App/DolphiniOS/UI/Emulation/TouchController/TCDeviceMotion.swift` | `gyroPointerOffsets(…, gain:)`; read the sensitivity (Task 6) |
| Modify `Source/iOS/App/Common/UI/Emulation/EmuEventVC.h` / `.m` | `DOLMotionSettingsChangedNotification` (Task 6) |
| Create `Source/iOS/App/Common/Swift/Controllers/Player/ControlCategory.swift` | Face / D-Pad / Sticks / Triggers / System / Motion and row titles (Task 7) |
| Create `Source/iOS/App/Common/Swift/Controllers/Player/PlayerAdvancedSettings.swift` | `NumericSettingState`, `NumericSettingSteps`, `AdvancedSettingGroups` (Task 7) |
| Modify `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubState.swift` | `ConnectedPadState.hasGyro` (Task 8) |
| Create `Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenState.swift` | Snapshot, device choice and options, pointer state, actions struct (Task 8) |
| Create `Source/iOS/App/Common/Swift/Controllers/Player/ProfileNaming.swift` | Save As name rules (Task 8) |
| Create `Source/iOS/App/Common/Swift/Controllers/Player/CaptureRowView.swift` | The `.custom` capture row (Task 8) |
| Create `Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenModelBuilder.swift` | Pure builder: state + actions → `MenuModel` (Task 9) |
| Create `Source/iOS/App/Common/Swift/Controllers/Player/ProfileListView.swift` | Load Profile list + pure builder (Task 10) |
| Create `Source/iOS/App/Common/Swift/Controllers/Player/DeviceListView.swift` | Device pick-list + pure builder (Task 10) |
| Create `Source/iOS/App/Common/Swift/Controllers/Player/ExpressionEditorView.swift` | Raw-expression editor + pure builder (Task 10) |
| Create `Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenIO.swift` | `PlayerScreenIO` seam and `LivePlayerScreenIO` (Task 11) |
| Create `Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenViewModel.swift` | View model, prompts, capture session, `PlayerProfileMemory` (Task 12) |
| Modify `Source/iOS/App/Common/Swift/EmulationScreen.swift` | Touch the core IMU pointer only on the touch slot (Task 13) |
| Create `Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenView.swift` | Hosts the model in a `MenuScreen`; one prompt-driven alert (Task 14) |
| Modify `Source/iOS/App/Common/UI/Localization/{en,ja}.lproj/Core.strings` | Identity entries for new keys (Task 15) |
| Create tests `Source/iOS/App/DolphiniOSTests/{ExpressionCheckTests,ControlCategoryTests,PlayerAdvancedSettingsTests,PlayerScreenStateTests,PlayerScreenModelBuilderTests,PlayerScreenLeavesTests,PlayerScreenIOTests,PlayerScreenViewModelTests}.swift` | Unit tests |
| Modify tests `Source/iOS/App/DolphiniOSTests/{MenuFocusRouterTests,MenuModelTests,MotionSettingsTests,TCDeviceMotionMappingTests}.swift` | Guard, item, pad Back, settings and gain tests |
| Create `docs/handoff-2026-09-30-controller-hub-phase3.md` | Handoff + device checklist (Task 16) |

All paths below are relative to the repo root unless a step `cd`s into `Source/iOS/App`. The new `Controllers/Player/` folder is picked up by the app's `Common/**/*.swift` glob.

---

### Task 1: Menu engine — A plus a d-pad adjust in one tick changes a picker once

**Files:**
- Modify: `Source/iOS/App/Common/Swift/Menu/MenuFocusRouter.swift`: the multi-pad `update(padInputs:…)` (78-110) and `apply` (129-153)
- Test: `Source/iOS/App/DolphiniOSTests/MenuFocusRouterTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `MenuFocusUpdate.adjust` is `nil` whenever `activatedID` names the same item in the same tick. Every later `.picker` (Tasks 9 and 10) relies on it.

- [ ] **Step 1: Write the failing tests**

Append these two tests inside `MenuFocusRouterTests`, after `test_adjust_withNoFocus_reportsNothing()`:
```swift
  /// A and d-pad right in the same tick on a picker row: the activate already stepped it. The
  /// builders' bindings read the model's snapshot, so applying the adjust too would write a second
  /// time from the same stale value.
  func test_adjust_isDroppedWhenTheSameTickActivatesThatRow() {
    var router = MenuFocusRouter(config: cfg)
    let result = router.update(.init(a: true, right: true), at: 0, model: twoSectionModel(), focusedID: "b", isActive: true)
    XCTAssertEqual(result.activatedID, "b")
    XCTAssertNil(result.adjust, "the activate already changed the row")
  }

  func test_multiPad_adjustIsDroppedWhenAnotherPadActivatesThatRow() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    let p1 = AnyHashable("p1")
    let p2 = AnyHashable("p2")
    _ = router.update(padInputs: [(p1, .init()), (p2, .init())], at: 0, model: model, focusedID: "b", isActive: true)
    let result = router.update(
      padInputs: [(p1, .init(a: true)), (p2, .init(right: true))],
      at: 0.1, model: model, focusedID: "b", isActive: true)
    XCTAssertEqual(result.activatedID, "b")
    XCTAssertNil(result.adjust)
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/MenuFocusRouterTests"`
Expected: both new tests fail at `XCTAssertNil(result.adjust)` (`XCTAssertNil failed`, with the `("b", 1)` adjust in the message). Every other test in the class passes.

- [ ] **Step 3: Add the guard**

In `MenuFocusRouter.swift`, in `update(padInputs:at:model:focusedID:isActive:)`, replace
```swift
    return MenuFocusUpdate(focusedID: current, activatedID: activated, didGoBack: didGoBack, adjust: adjust)
  }

  /// Adopt the current physical input without emitting anything. `MenuScreen`
```
with
```swift
    if let activated, adjust?.id == activated { adjust = nil }
    return MenuFocusUpdate(focusedID: current, activatedID: activated, didGoBack: didGoBack, adjust: adjust)
  }

  /// Adopt the current physical input without emitting anything. `MenuScreen`
```
In `apply(_:model:focusedID:)`, replace
```swift
      case .adjust(let step):
        if let current { adjust = (current, step) }
      }
    }
    return MenuFocusUpdate(focusedID: current, activatedID: activated, didGoBack: didGoBack, adjust: adjust)
```
with
```swift
      case .adjust(let step):
        if let current { adjust = (current, step) }
      }
    }
    // A and d-pad left/right on the same row in one tick: the activate already stepped a picker.
    // The builders' bindings read the snapshot the model was built from, so applying both would
    // write twice from the same stale value.
    if let activated, adjust?.id == activated { adjust = nil }
    return MenuFocusUpdate(focusedID: current, activatedID: activated, didGoBack: didGoBack, adjust: adjust)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/MenuFocusRouterTests"`
Expected: `** TEST SUCCEEDED **`, 0 failures in `MenuFocusRouterTests`.

- [ ] **Step 5: Run the gates**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice.

- [ ] **Step 6: Commit**

```bash
git add Source/iOS/App/Common/Swift/Menu/MenuFocusRouter.swift Source/iOS/App/DolphiniOSTests/MenuFocusRouterTests.swift
git commit -m "fix(menu): A and a d-pad adjust in one tick step a picker once"
```

---

### Task 2: Menu engine — a controller's A activates a `.custom` row

**Files:**
- Modify: `Source/iOS/App/Common/Swift/Menu/MenuModel.swift`: `MenuItem` (36-75) and the `.custom` doc comment (87-90)
- Modify: `Source/iOS/App/Common/Swift/Menu/MenuScreen.swift`: `performActivate` and its doc comment (201-224)
- Test: `Source/iOS/App/DolphiniOSTests/MenuModelTests.swift` (append)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `MenuItem.onCustomActivate: (() -> Void)?`, default `nil`.
  - It is also an `init` parameter, directly after `isEnabled:`.
  - On iOS a controller's A on a `.custom` item runs it. Tasks 9 and 10 rely on this for the capture rows and the expression field.

The dispatch lives in `MenuScreen.performActivate`, a private method of a SwiftUI view driven by `GCController` polling, so it has no pure seam. It is device-checked (checklist item 2). The test below pins the item side: the closure is carried, and it is `nil` by default, so every existing `.custom` row is unchanged.

- [ ] **Step 1: Write the failing test**

Append inside `MenuModelTests`:
```swift
  /// A `.custom` row's own gestures never reach `MenuScreen`; a pad's A on iOS runs the item's
  /// `onCustomActivate` (MenuScreen.performActivate, device-checked). Nil by default, so existing
  /// custom rows (save-state cards) are unchanged.
  func test_customRow_carriesItsPadActivation() {
    var ran = false
    let item = MenuItem(id: "c", title: "C", role: .custom(AnyView(EmptyView())), onCustomActivate: { ran = true })
    item.onCustomActivate?()
    XCTAssertTrue(ran)
    XCTAssertNil(MenuItem(id: "d", title: "D", role: .custom(AnyView(EmptyView()))).onCustomActivate)
  }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/MenuModelTests"`
Expected: build failure, `extra argument 'onCustomActivate' in call`.

- [ ] **Step 3: Add the field**

In `MenuModel.swift`, replace the tail of `MenuItem` from `var isEnabled: Bool = true` through the end of its `init` with:
```swift
  var isEnabled: Bool = true
  /// `.custom` rows only: what a controller's A does on iOS. A `.custom` row carries its own touch
  /// and tvOS gestures, so `MenuScreen` cannot activate it by itself; without this a pad could focus
  /// the player screen's capture rows but never arm one.
  var onCustomActivate: (() -> Void)?

  init(
    id: String,
    title: String,
    subtitle: String? = nil,
    icon: String? = nil,
    tint: Color? = nil,
    role: MenuItemRole,
    badge: String? = nil,
    isEnabled: Bool = true,
    onCustomActivate: (() -> Void)? = nil
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.icon = icon
    self.tint = tint
    self.role = role
    self.badge = badge
    self.isEnabled = isEnabled
    self.onCustomActivate = onCustomActivate
  }
}
```
In `MenuItemRole`, replace the `.custom` doc comment
```swift
  /// Opaque leaf with its own gesture handling (a save-state filmstrip card,
  /// a shader thumbnail) — `MenuScreen` renders it and otherwise leaves it
  /// alone; it does not intercept controller-activate for this role.
  case custom(AnyView)
```
with
```swift
  /// Opaque leaf with its own gesture handling (a save-state filmstrip card,
  /// a shader thumbnail, a capture row) — `MenuScreen` renders it and
  /// otherwise leaves it alone. A controller's A reaches it only through the
  /// item's `onCustomActivate`.
  case custom(AnyView)
```

- [ ] **Step 4: Dispatch it from a pad**

In `MenuScreen.swift`, `performActivate(_:)`, replace
```swift
    case .custom:
      break
    }
  }
```
with
```swift
    case .custom:
      item.onCustomActivate?()
    }
  }
```
and replace the last sentence of its doc comment,
```swift
  /// this path is the controller's A and grid cards). `.custom` owns its own gestures, so activation
  /// is a no-op for it.
```
with
```swift
  /// this path is the controller's A and grid cards). `.custom` owns its own gestures; a controller's
  /// A runs its `onCustomActivate`, if it has one.
```

- [ ] **Step 5: Run the test to verify it passes, then the gates**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/MenuModelTests"`
Expected: 0 failures in `MenuModelTests`.
Then: `make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` and `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice.

- [ ] **Step 6: Commit**

```bash
git add Source/iOS/App/Common/Swift/Menu/MenuModel.swift Source/iOS/App/Common/Swift/Menu/MenuScreen.swift \
  Source/iOS/App/DolphiniOSTests/MenuModelTests.swift
git commit -m "feat(menu): a controller's A activates a custom row"
```

---

### Task 3: Menu engine — the tvOS compact picker

**Files:**
- Modify: `Source/iOS/App/Common/Swift/Menu/MenuModel.swift`: `MenuItem` (the fields and `init` from Task 2), and `extension MenuItemRole` (after `cycled`)
- Modify: `Source/iOS/App/Common/Swift/Menu/MenuScreen.swift`: `defaultTVFocusID` (414-425) and `tvRow` (440-489)
- Test: `Source/iOS/App/DolphiniOSTests/MenuModelTests.swift` (append)

**Interfaces:**
- Consumes: `MenuItemRole.cycled(options:current:step:)` (Phase 1); Task 2's `MenuItem` init.
- Produces:
  - `MenuItem.isCompactOnTV: Bool`, default `false`. It is also an `init` parameter, directly after `onCustomActivate:`.
  - `static func MenuItemRole.selectedTitle(options: [(String, AnyHashable)], current: AnyHashable) -> String?`.
  - On tvOS a `.picker` item with `isCompactOnTV` is ONE focusable row: its title, then "‹ value ›". Left/right (`.onMoveCommand`) step it with `MenuItemRole.cycled`. Up/down move focus as on any row. Select does nothing.
  - iOS rendering is unchanged.
  - Task 9 sets it on every numeric setting and on both Sensitivity rows.

The row is built like `TVIntStepper` (`SettingsSharedComponents.swift:67-100`) and `TVFloatStepper` (`TVFloatStepper.swift:7-52`): a `.focusable` `HStack` with `.focused`, a drawn focus ring and `.onMoveCommand`. It is not a `Button`.

Two behaviours are device-only (checklist items 20–21), because SwiftUI's tvOS focus engine has no test seam:
- `.onMoveCommand` firing on a focusable row inside a `List`.
- Up/down leaving that row.

Fallback if either fails: drop `isCompactOnTV: true` from the Task 9 items. They then explode into one row per option.

- [ ] **Step 1: Write the failing test**

Append inside `MenuModelTests`:
```swift
  /// The compact tvOS picker shows the selected option's title; an unknown selection shows nothing.
  func test_selectedTitle() {
    let options: [(String, AnyHashable)] = [("Low", AnyHashable(1)), ("High", AnyHashable(2))]
    XCTAssertEqual(MenuItemRole.selectedTitle(options: options, current: AnyHashable(2)), "High")
    XCTAssertNil(MenuItemRole.selectedTitle(options: options, current: AnyHashable(3)))
  }

  func test_compactOnTV_isOffByDefault() {
    XCTAssertFalse(MenuItem(id: "p", title: "P", role: .action({})).isCompactOnTV)
    XCTAssertTrue(MenuItem(id: "q", title: "Q", role: .action({}), isCompactOnTV: true).isCompactOnTV)
  }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/MenuModelTests"`
Expected: build failure, `type 'MenuItemRole' has no member 'selectedTitle'`.

- [ ] **Step 3: Add the field and the lookup**

In `MenuModel.swift`, in `MenuItem`, directly after the `var onCustomActivate: (() -> Void)?` declaration, add:
```swift
  /// `.picker` rows only, tvOS only: ONE row showing the title and the current value, which d-pad
  /// left/right steps through, instead of one row per option. For long value lists (the player
  /// screen's numeric settings), which would otherwise explode into ~20 rows each.
  var isCompactOnTV: Bool = false
```
Then change the `init` signature's last parameter from
```swift
    onCustomActivate: (() -> Void)? = nil
  ) {
```
to
```swift
    onCustomActivate: (() -> Void)? = nil,
    isCompactOnTV: Bool = false
  ) {
```
and add `self.isCompactOnTV = isCompactOnTV` as the init's last line.

In `extension MenuItemRole`, directly after `cycled(options:current:step:)`, add:
```swift
  /// The title of the option `current` selects, or nil when no option matches.
  static func selectedTitle(options: [(String, AnyHashable)], current: AnyHashable) -> String? {
    options.first { $0.1 == current }?.0
  }
```

- [ ] **Step 4: Render it on tvOS**

In `MenuScreen.swift`, in `defaultTVFocusID`, replace
```swift
    if case .picker(let options, _) = item.role, !options.isEmpty {
```
with
```swift
    if case .picker(let options, _) = item.role, !options.isEmpty, !item.isCompactOnTV {
```
In `tvRow(_:)`, insert a new first case directly after `switch item.role {`:
```swift
    case .picker(let options, let selection) where item.isCompactOnTV:
      tvCompactPicker(item, options: options, selection: selection)
```
Then add these two methods directly after `tvRow(_:)`, inside the same `#if os(tvOS)` block:
```swift
  /// A `.picker` flagged `isCompactOnTV`: one focusable row, title then "‹ value ›". Built like
  /// `TVIntStepper` / `TVFloatStepper` (a `.focusable` HStack with `.onMoveCommand`), not a
  /// `Button`: left/right step through the options (wrapping, as the iOS d-pad adjust does), up/down
  /// move focus like any row, and select does nothing.
  private func tvCompactPicker(
    _ item: MenuItem, options: [(String, AnyHashable)], selection: Binding<AnyHashable>
  ) -> some View {
    HStack {
      rowLabel(item)
      Image(systemName: "chevron.left")
      Text(MenuItemRole.selectedTitle(options: options, current: selection.wrappedValue) ?? "")
        .monospacedDigit()
      Image(systemName: "chevron.right")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .focusable(item.isEnabled)
    .focused($tvFocusedID, equals: item.id)
    .padding(8)
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(tvFocusedID == item.id ? Color.accentColor : Color.clear, lineWidth: 4))
    .opacity(item.isEnabled ? 1 : 0.5)
    .onMoveCommand { direction in
      guard item.isEnabled else { return }
      switch direction {
      case .left: stepPicker(selection, options: options, by: -1)
      case .right: stepPicker(selection, options: options, by: 1)
      default: break
      }
    }
  }

  private func stepPicker(_ selection: Binding<AnyHashable>, options: [(String, AnyHashable)], by step: Int) {
    if let next = MenuItemRole.cycled(options: options, current: selection.wrappedValue, step: step) {
      selection.wrappedValue = next
    }
  }
```

- [ ] **Step 5: Run the tests to verify they pass, then the gates**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/MenuModelTests"`
Expected: 0 failures in `MenuModelTests`.
Then: `make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` and `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice. The tvOS build compiles `tvCompactPicker`.

- [ ] **Step 6: Commit**

```bash
git add Source/iOS/App/Common/Swift/Menu/MenuModel.swift Source/iOS/App/Common/Swift/Menu/MenuScreen.swift \
  Source/iOS/App/DolphiniOSTests/MenuModelTests.swift
git commit -m "feat(menu): one-row tvOS stepper for long pickers"
```

---

### Task 4: Pad Back for pushed screens that are not menus (iOS)

**Files:**
- Create: `Source/iOS/App/Common/Swift/Menu/PadBackNavigation.swift`
- Modify: `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubViewModel.swift:179-194` (`editLayoutDestination`, `dsuDestination`, `moreSettingsDestination`)
- Test: `Source/iOS/App/DolphiniOSTests/MenuFocusRouterTests.swift` (append)

**Interfaces:**
- Consumes: `MenuFocusRouter.update(padInputs:at:model:focusedID:isActive:)`, `ControllerFocusCoordinator.isActiveScope(_:)`, `View.controllerScope(_:)`.
- Produces: `extension View { func padBackNavigation() -> some View }`. On iOS, B on any extended gamepad calls the environment's `dismiss()` while this view owns the controller scope. On tvOS it is a no-op.

- [ ] **Step 1: Pin the router behaviour the modifier relies on**

Append inside `MenuFocusRouterTests`:
```swift
  /// `padBackNavigation()` feeds the router an empty model: B must still report back, and nothing
  /// else may happen.
  func test_back_withAnEmptyModel_stillReportsBack() {
    var router = MenuFocusRouter(config: cfg)
    let p1 = AnyHashable("p1")
    _ = router.update(padInputs: [(p1, .init())], at: 0, model: MenuModel(), focusedID: nil, isActive: true)
    let result = router.update(padInputs: [(p1, .init(b: true))], at: 0.1, model: MenuModel(), focusedID: nil, isActive: true)
    XCTAssertTrue(result.didGoBack)
    XCTAssertNil(result.focusedID)
    XCTAssertNil(result.activatedID)
  }
```

- [ ] **Step 2: Run it**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/MenuFocusRouterTests/test_back_withAnEmptyModel_stillReportsBack"`
Expected: PASS. This test pins existing behaviour, so it passes before the modifier exists.

- [ ] **Step 3: Write the modifier**

`Source/iOS/App/Common/Swift/Menu/PadBackNavigation.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import GameController
import SwiftUI

/// B on a controller pops a pushed screen that is not a `MenuScreen` (iOS). `MenuScreen` handles B
/// itself; a plain `List`/`Form` pushed from one (More Controller Settings, Motion Source (DSU),
/// Edit Layout) had no pad Back at all, so a pad's A could push it and nothing brought the pad back.
/// tvOS needs nothing: Menu pops natively.
///
/// Same machinery as `MenuScreen`: polled at 60 Hz, one latch per pad through `MenuFocusRouter` (a
/// pad's first tick is a resync, so the A still held from the push never counts), gated on this
/// screen's own `ControllerFocusCoordinator` scope.
///
/// Apply it to the pushed view itself, never to a view that hosts its own `MenuScreen`: both would
/// then claim a scope, and which one ends up on top depends on `onAppear` order.
private struct PadBackNavigation: ViewModifier {
  #if os(iOS)
  @Environment(\.dismiss) private var dismiss
  @State private var router = MenuFocusRouter()
  @State private var scopeID = UUID()
  private static let tick = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()
  #endif

  func body(content: Content) -> some View {
    #if os(iOS)
    content
      .controllerScope(scopeID)
      .onReceive(Self.tick) { _ in poll() }
    #else
    content
    #endif
  }

  #if os(iOS)
  private func poll() {
    let pads: [(AnyHashable, MenuControllerNav.Input)] = GCController.controllers().compactMap { controller in
      guard let pad = controller.extendedGamepad else { return nil }
      return (AnyHashable(ObjectIdentifier(controller)), MenuControllerNav.Input(b: pad.buttonB.isPressed))
    }
    guard !pads.isEmpty else { return }
    let result = router.update(
      padInputs: pads, at: CACurrentMediaTime(), model: MenuModel(), focusedID: nil,
      isActive: ControllerFocusCoordinator.isActiveScope(scopeID))
    if result.didGoBack { dismiss() }
  }
  #endif
}

extension View {
  /// B pops this pushed screen on iOS. For pushed screens that are not a `MenuScreen`.
  func padBackNavigation() -> some View {
    modifier(PadBackNavigation())
  }
}
```

- [ ] **Step 4: Apply it to the hub's three non-menu destinations**

In `ControllerHubViewModel.swift`, in `actions`, replace
```swift
      editLayoutDestination: {
        #if os(iOS)
        AnyView(TouchOverlayLayoutEditorView())
        #else
        AnyView(EmptyView())
        #endif
      },
```
with
```swift
      editLayoutDestination: {
        #if os(iOS)
        AnyView(TouchOverlayLayoutEditorView().padBackNavigation())
        #else
        AnyView(EmptyView())
        #endif
      },
```
and replace
```swift
      dsuDestination: { AnyView(DSUSettingsView()) },
      moreSettingsDestination: { AnyView(ControllerMoreSettingsView()) })
```
with
```swift
      // Plain lists, not menus: they get pad Back from the modifier (Phase 2 left them touch-only).
      dsuDestination: { AnyView(DSUSettingsView().padBackNavigation()) },
      moreSettingsDestination: { AnyView(ControllerMoreSettingsView().padBackNavigation()) })
```

- [ ] **Step 5: Generate and run the gates**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice.

- [ ] **Step 6: Commit**

```bash
git add Source/iOS/App/Common/Swift/Menu/PadBackNavigation.swift \
  Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubViewModel.swift \
  Source/iOS/App/DolphiniOSTests/MenuFocusRouterTests.swift
git commit -m "feat(menu): a pad's B pops More, DSU and Edit Layout"
```

---

### Task 5: `DOLControllerSettingsBridge` — the parse check and numeric settings, with no core change

**Files:**
- Create: `Source/iOS/App/Common/Emulation/DOLControllerSettingsBridge.h`
- Create: `Source/iOS/App/Common/Emulation/DOLControllerSettingsBridge.mm`
- Modify: `Source/iOS/App/Common/Swift/BridgingHeader.h:45` (after `#import "TVControllerMappingBridge.h"`)
- Create: `Source/iOS/App/Common/Swift/Controllers/Player/ExpressionCheck.swift`
- Test: `Source/iOS/App/DolphiniOSTests/ExpressionCheckTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces (Swift names):
  - `enum ControlGroupOwner: Int { case gcPad, wiimote, nunchuk, classic }`, from `DOLControlGroupOwner`.
  - `enum ExpressionParseStatus: Int { case successful, syntaxError, empty }`, from `DOLExpressionStatus`.
  - `enum NumericSettingType: Int { case int, double, bool }`, from `DOLNumericSettingType`.
  - `class ExpressionParseResult`, with `status: ExpressionParseStatus` and `message: String?`.
  - `class NumericSettingInfo`, with `index: Int`, `name: String`, `suffix: String`, `type: NumericSettingType`, `value`, `minimum`, `maximum` and `defaultValue: Double`, and `isExpression: Bool`.
  - `DOLControllerSettingsBridge`:
    - `.parse(expression: String) -> ExpressionParseResult`
    - `.numericSettings(owner: ControlGroupOwner, port: Int, group: Int) -> [NumericSettingInfo]`
    - `.setNumericSetting(_ value: Double, index: Int, owner: ControlGroupOwner, port: Int, group: Int)`
    - `.isGroupEnabled(owner:port:group:) -> Bool`
    - `.setGroupEnabled(_ enabled: Bool, owner:port:group:)`
    - `port` is 1-based. `group` is the raw `PadGroup` / `WiimoteGroup` / `NunchukGroup` / `ClassicGroup` value, as `RemapGroup.id` uses.
  - `struct ExpressionCheck: Equatable`, with `enum Status { case valid, empty, invalid }`, `status`, `message: String`, `canSave: Bool`, `init(status:message:)` and `init(parseStatus: ExpressionParseStatus, parserMessage: String?)`.

- [ ] **Step 1: Confirm the link surface (no core change needed)**

Run from the repo root:
```bash
for s in ios ios-sim tvos tvos-sim; do
  echo "== $s"
  nm -gU build/xcframework/PVlibDolphin-$s.framework/PVlibDolphin-$s | c++filt | grep -cE \
    "ciface::ExpressionParser::ParseExpression\(|InputReference::State\(double\)|ControlReference::GetInputGate\(\)|ControlReference::SetExpression\(|ControlReference::GetExpression\(\) const|EmulatedController::GetStateLock\(\)|^[0-9a-f]+ T Pad::GetGroup\(|^[0-9a-f]+ T Pad::GetConfig\(\)|^[0-9a-f]+ T Wiimote::GetConfig\(\)|^[0-9a-f]+ T Wiimote::Get(Wiimote|Nunchuk|Classic)Group\(int|InputConfig::SaveConfig\(\)|InputConfig::GetControllerCount\(\)|NumericSettingBase::Get(UIName|UISuffix)\(\)|NumericSetting<(int|double|bool)>::GetType\(\)"
done
```
Expected: `19` for each of the four slices (checked on develop at `28f0e24fb6`). Each of these symbols is exported (`T`), and the new bridge calls only these symbols or header-inline code. The inline `SetValue` and `GetValue` reach `ControlReference::SetExpression`, `GetInputGate` and `InputReference::State`; the inline `IsSimpleValue` reaches `ControlReference::GetExpression`. If any slice prints less, stop: that slice needs a core rebuild, and this plan's "no core change" ruling no longer holds.

- [ ] **Step 2: Write the failing test**

`Source/iOS/App/DolphiniOSTests/ExpressionCheckTests.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// The raw-expression check: the core's own parser through the app-side bridge (no core change),
/// and the mapping of its answer to what the editor shows. Only backquoted forms are used: a bare
/// word can parse as a working bareword fallback even when the full parse reports a syntax error.
final class ExpressionCheckTests: XCTestCase {

  // MARK: The parser, through DOLControllerSettingsBridge

  func test_parser_aBackquotedInputParses() {
    let result = DOLControllerSettingsBridge.parse(expression: "`Button A`")
    XCTAssertEqual(result.status, .successful)
    XCTAssertNil(result.message)
  }

  func test_parser_anOrOfTwoInputsParses() {
    XCTAssertEqual(DOLControllerSettingsBridge.parse(expression: "`Button A` | `Button B`").status, .successful)
  }

  func test_parser_blankIsEmpty() {
    let result = DOLControllerSettingsBridge.parse(expression: "   ")
    XCTAssertEqual(result.status, .empty)
    XCTAssertNil(result.message)
  }

  func test_parser_anUnclosedParenIsASyntaxErrorWithTheParsersMessage() {
    let result = DOLControllerSettingsBridge.parse(expression: "(`Button A`")
    XCTAssertEqual(result.status, .syntaxError)
    XCTAssertFalse((result.message ?? "").isEmpty, "the parser explains what it expected")
  }

  // MARK: Mapping

  func test_valid_canBeSaved() {
    let check = ExpressionCheck(parseStatus: .successful, parserMessage: nil)
    XCTAssertEqual(check.status, .valid)
    XCTAssertTrue(check.canSave)
  }

  func test_empty_canBeSaved_itUnbindsTheControl() {
    let check = ExpressionCheck(parseStatus: .empty, parserMessage: nil)
    XCTAssertEqual(check.status, .empty)
    XCTAssertTrue(check.canSave)
  }

  func test_syntaxError_cannotBeSaved_andShowsTheParsersMessage() {
    let check = ExpressionCheck(parseStatus: .syntaxError, parserMessage: "Expected closing paren.")
    XCTAssertEqual(check.status, .invalid)
    XCTAssertFalse(check.canSave)
    XCTAssertEqual(check.message, "Not saved: Expected closing paren.")
  }

  func test_syntaxErrorWithoutAMessage_stillExplains() {
    XCTAssertEqual(
      ExpressionCheck(parseStatus: .syntaxError, parserMessage: nil).message,
      "Not saved: the expression does not parse.")
  }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/ExpressionCheckTests"`
Expected: build failure, `cannot find 'DOLControllerSettingsBridge' in scope` and `cannot find 'ExpressionCheck' in scope`.

- [ ] **Step 4: Write the bridge header**

`Source/iOS/App/Common/Emulation/DOLControllerSettingsBridge.h`:
```objc
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Which emulated controller a control group belongs to: the same four owners as Swift's
/// `RemapGroupOwner`. `group` is then a raw `PadGroup` (GCPadEmu.h), `WiimoteEmu::WiimoteGroup`
/// (WiimoteEmu.h), `WiimoteEmu::NunchukGroup` (Nunchuk.h) or `WiimoteEmu::ClassicGroup` (Classic.h).
typedef NS_ENUM(NSInteger, DOLControlGroupOwner) {
  DOLControlGroupOwnerGCPad = 0,
  DOLControlGroupOwnerWiimote = 1,
  DOLControlGroupOwnerNunchuk = 2,
  DOLControlGroupOwnerClassic = 3,
} NS_SWIFT_NAME(ControlGroupOwner);

/// `ciface::ExpressionParser::ParseStatus` (ExpressionParser.h).
typedef NS_ENUM(NSInteger, DOLExpressionStatus) {
  DOLExpressionStatusSuccessful = 0,
  DOLExpressionStatusSyntaxError = 1,
  DOLExpressionStatusEmpty = 2,
} NS_SWIFT_NAME(ExpressionParseStatus);

/// `ControllerEmu::SettingType` (NumericSetting.h).
typedef NS_ENUM(NSInteger, DOLNumericSettingType) {
  DOLNumericSettingTypeInt = 0,
  DOLNumericSettingTypeDouble = 1,
  DOLNumericSettingTypeBool = 2,
} NS_SWIFT_NAME(NumericSettingType);

NS_SWIFT_NAME(ExpressionParseResult)
@interface DOLExpressionParseResult : NSObject
@property (nonatomic, readonly) DOLExpressionStatus status;
/// The parser's (translated) explanation of a syntax error; nil otherwise.
@property (nonatomic, readonly, copy, nullable) NSString* message;
@end

/// One `ControllerEmu::NumericSetting` of a control group, as plain values. Bool settings report
/// 0/1 with a 0...1 range.
NS_SWIFT_NAME(NumericSettingInfo)
@interface DOLNumericSettingInfo : NSObject
/// Position in the group's `numeric_settings`: what `setNumericSetting…` takes.
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly, copy) NSString* name;
/// Unit shown after the value ("%", "°", "cm"); empty when none.
@property (nonatomic, readonly, copy) NSString* suffix;
@property (nonatomic, readonly) DOLNumericSettingType type;
@property (nonatomic, readonly) double value;
@property (nonatomic, readonly) double minimum;
@property (nonatomic, readonly) double maximum;
@property (nonatomic, readonly) double defaultValue;
/// The value is driven by an expression, not a plain number; the player screen shows it read-only.
@property (nonatomic, readonly) BOOL isExpression;
@end

/// The player screen's Advanced section: Dolphin's expression parser, used as a check that installs
/// nothing, and the numeric settings (dead zones, gate sizes, IR and IMU values) of a control group.
/// App-side only: every call is to a symbol the core library already exports.
@interface DOLControllerSettingsBridge : NSObject

/// Parses `expression` with `ciface::ExpressionParser::ParseExpression`, the parser
/// `ControlReference::SetExpression` runs, WITHOUT installing it. `SetExpression` installs a text
/// that does not parse and only returns the error, which the mapping bridge discards.
+ (DOLExpressionParseResult*)parseExpression:(NSString*)expression NS_SWIFT_NAME(parse(expression:));

/// Every numeric setting of one group of one port (1-based), in the group's order. Empty when the
/// controller config is not loaded.
+ (NSArray<DOLNumericSettingInfo*>*)numericSettingsForOwner:(DOLControlGroupOwner)owner
                                                       port:(NSInteger)portOneBased
                                                      group:(NSInteger)groupId
    NS_SWIFT_NAME(numericSettings(owner:port:group:));

/// Sets one setting (clamped to its range; bools read non-zero as true), replacing any expression
/// that drove it, and saves the controller config.
+ (void)setNumericSettingValue:(double)value
                         index:(NSInteger)settingIndex
                         owner:(DOLControlGroupOwner)owner
                          port:(NSInteger)portOneBased
                         group:(NSInteger)groupId
    NS_SWIFT_NAME(setNumericSetting(_:index:owner:port:group:));

/// A group's "Enabled" setting (`ControlGroup::enabled`), for groups that have one (the Wii Remote's
/// IMU pointer). NO when the group has none.
+ (BOOL)isGroupEnabledForOwner:(DOLControlGroupOwner)owner
                          port:(NSInteger)portOneBased
                         group:(NSInteger)groupId
    NS_SWIFT_NAME(isGroupEnabled(owner:port:group:));

+ (void)setGroupEnabled:(BOOL)enabled
                  owner:(DOLControlGroupOwner)owner
                   port:(NSInteger)portOneBased
                  group:(NSInteger)groupId
    NS_SWIFT_NAME(setGroupEnabled(_:owner:port:group:));

@end

NS_ASSUME_NONNULL_END
```

- [ ] **Step 5: Write the bridge implementation**

`Source/iOS/App/Common/Emulation/DOLControllerSettingsBridge.mm`:
```objc
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "DOLControllerSettingsBridge.h"

#include <algorithm>
#include <cmath>
#include <string>

#include "Core/HW/GCPad.h"
#include "Core/HW/GCPadEmu.h"
#include "Core/HW/Wiimote.h"
#include "Core/HW/WiimoteEmu/Extension/Classic.h"
#include "Core/HW/WiimoteEmu/Extension/Nunchuk.h"
#include "Core/HW/WiimoteEmu/WiimoteEmu.h"
#include "InputCommon/ControlReference/ExpressionParser.h"
#include "InputCommon/ControllerEmu/ControlGroup/ControlGroup.h"
#include "InputCommon/ControllerEmu/ControllerEmu.h"
#include "InputCommon/ControllerEmu/Setting/NumericSetting.h"
#include "InputCommon/InputConfig.h"
#include "FoundationStringUtil.h"
#include "LocalizationUtil.h"

@interface DOLExpressionParseResult ()
@property (nonatomic, readwrite) DOLExpressionStatus status;
@property (nonatomic, readwrite, copy, nullable) NSString* message;
@end

@implementation DOLExpressionParseResult
@end

@interface DOLNumericSettingInfo ()
@property (nonatomic, readwrite) NSInteger index;
@property (nonatomic, readwrite, copy) NSString* name;
@property (nonatomic, readwrite, copy) NSString* suffix;
@property (nonatomic, readwrite) DOLNumericSettingType type;
@property (nonatomic, readwrite) double value;
@property (nonatomic, readwrite) double minimum;
@property (nonatomic, readwrite) double maximum;
@property (nonatomic, readwrite) double defaultValue;
@property (nonatomic, readwrite) BOOL isExpression;
@end

@implementation DOLNumericSettingInfo
@end

// The owner's input config, or nullptr before it is loaded or for a port it does not have.
static InputConfig* ConfigFor(DOLControlGroupOwner owner, int index)
{
  InputConfig* config = owner == DOLControlGroupOwnerGCPad ? Pad::GetConfig() : Wiimote::GetConfig();
  if (!config || index < 0 || index >= config->GetControllerCount())
    return nullptr;
  return config;
}

// Same dispatch as TVControllerMappingBridge's group lookups, for all four owners.
static ControllerEmu::ControlGroup* GroupFor(DOLControlGroupOwner owner, NSInteger portOneBased, NSInteger groupId)
{
  const int index = static_cast<int>(portOneBased - 1);
  if (!ConfigFor(owner, index))
    return nullptr;
  switch (owner)
  {
  case DOLControlGroupOwnerGCPad:
    return Pad::GetGroup(index, static_cast<PadGroup>(groupId));
  case DOLControlGroupOwnerWiimote:
    return Wiimote::GetWiimoteGroup(index, static_cast<WiimoteEmu::WiimoteGroup>(groupId));
  case DOLControlGroupOwnerNunchuk:
    return Wiimote::GetNunchukGroup(index, static_cast<WiimoteEmu::NunchukGroup>(groupId));
  case DOLControlGroupOwnerClassic:
    return Wiimote::GetClassicGroup(index, static_cast<WiimoteEmu::ClassicGroup>(groupId));
  }
  return nullptr;
}

static void SaveConfigFor(DOLControlGroupOwner owner)
{
  InputConfig* config = owner == DOLControlGroupOwnerGCPad ? Pad::GetConfig() : Wiimote::GetConfig();
  if (config)
    config->SaveConfig();
}

@implementation DOLControllerSettingsBridge

+ (DOLExpressionParseResult*)parseExpression:(NSString*)expression
{
  DOLExpressionParseResult* result = [[DOLExpressionParseResult alloc] init];
  const auto parsed = ciface::ExpressionParser::ParseExpression(FoundationToCppString(expression));
  switch (parsed.status)
  {
  case ciface::ExpressionParser::ParseStatus::Successful:
    result.status = DOLExpressionStatusSuccessful;
    break;
  case ciface::ExpressionParser::ParseStatus::SyntaxError:
    result.status = DOLExpressionStatusSyntaxError;
    if (parsed.description)
      result.message = CToFoundationString(parsed.description->c_str());
    break;
  case ciface::ExpressionParser::ParseStatus::EmptyExpression:
    result.status = DOLExpressionStatusEmpty;
    break;
  }
  return result;
}

+ (NSArray<DOLNumericSettingInfo*>*)numericSettingsForOwner:(DOLControlGroupOwner)owner
                                                       port:(NSInteger)portOneBased
                                                      group:(NSInteger)groupId
{
  NSMutableArray<DOLNumericSettingInfo*>* result = [NSMutableArray array];
  auto* group = GroupFor(owner, portOneBased, groupId);
  if (!group)
    return result;
  const auto lock = ControllerEmu::EmulatedController::GetStateLock();
  NSInteger index = 0;
  for (const auto& setting : group->numeric_settings)
  {
    DOLNumericSettingInfo* info = [[DOLNumericSettingInfo alloc] init];
    info.index = index++;
    info.name = DOLCoreLocalizedString(CToFoundationString(setting->GetUIName()));
    const char* suffix = setting->GetUISuffix();
    info.suffix = suffix ? DOLCoreLocalizedString(CToFoundationString(suffix)) : @"";
    info.isExpression = !setting->IsSimpleValue();
    switch (setting->GetType())
    {
    case ControllerEmu::SettingType::Int:
    {
      const auto* typed = static_cast<const ControllerEmu::NumericSetting<int>*>(setting.get());
      info.type = DOLNumericSettingTypeInt;
      info.value = typed->GetValue();
      info.minimum = typed->GetMinValue();
      info.maximum = typed->GetMaxValue();
      info.defaultValue = typed->GetDefaultValue();
      break;
    }
    case ControllerEmu::SettingType::Double:
    {
      const auto* typed = static_cast<const ControllerEmu::NumericSetting<double>*>(setting.get());
      info.type = DOLNumericSettingTypeDouble;
      info.value = typed->GetValue();
      info.minimum = typed->GetMinValue();
      info.maximum = typed->GetMaxValue();
      info.defaultValue = typed->GetDefaultValue();
      break;
    }
    case ControllerEmu::SettingType::Bool:
    {
      const auto* typed = static_cast<const ControllerEmu::NumericSetting<bool>*>(setting.get());
      info.type = DOLNumericSettingTypeBool;
      info.value = typed->GetValue() ? 1 : 0;
      info.minimum = 0;
      info.maximum = 1;
      info.defaultValue = typed->GetDefaultValue() ? 1 : 0;
      break;
    }
    }
    [result addObject:info];
  }
  return result;
}

+ (void)setNumericSettingValue:(double)value
                         index:(NSInteger)settingIndex
                         owner:(DOLControlGroupOwner)owner
                          port:(NSInteger)portOneBased
                         group:(NSInteger)groupId
{
  auto* group = GroupFor(owner, portOneBased, groupId);
  if (!group || settingIndex < 0 || static_cast<size_t>(settingIndex) >= group->numeric_settings.size())
    return;
  {
    // The CPU thread reads these settings; Dolphin's own UI holds the state lock to change them.
    const auto lock = ControllerEmu::EmulatedController::GetStateLock();
    auto* setting = group->numeric_settings[settingIndex].get();
    switch (setting->GetType())
    {
    case ControllerEmu::SettingType::Int:
    {
      auto* typed = static_cast<ControllerEmu::NumericSetting<int>*>(setting);
      typed->SetValue(std::clamp(static_cast<int>(std::lround(value)), typed->GetMinValue(), typed->GetMaxValue()));
      break;
    }
    case ControllerEmu::SettingType::Double:
    {
      auto* typed = static_cast<ControllerEmu::NumericSetting<double>*>(setting);
      typed->SetValue(std::clamp(value, typed->GetMinValue(), typed->GetMaxValue()));
      break;
    }
    case ControllerEmu::SettingType::Bool:
      static_cast<ControllerEmu::NumericSetting<bool>*>(setting)->SetValue(value != 0);
      break;
    }
  }
  SaveConfigFor(owner);
}

+ (BOOL)isGroupEnabledForOwner:(DOLControlGroupOwner)owner port:(NSInteger)portOneBased group:(NSInteger)groupId
{
  auto* group = GroupFor(owner, portOneBased, groupId);
  if (!group || !group->enabled_setting)
    return NO;
  const auto lock = ControllerEmu::EmulatedController::GetStateLock();
  return group->enabled.GetValue() ? YES : NO;
}

+ (void)setGroupEnabled:(BOOL)enabled owner:(DOLControlGroupOwner)owner port:(NSInteger)portOneBased group:(NSInteger)groupId
{
  auto* group = GroupFor(owner, portOneBased, groupId);
  if (!group || !group->enabled_setting)
    return;
  {
    const auto lock = ControllerEmu::EmulatedController::GetStateLock();
    group->enabled_setting->SetValue(enabled == YES);
  }
  SaveConfigFor(owner);
}

@end
```

- [ ] **Step 6: Expose it to Swift**

In `Source/iOS/App/Common/Swift/BridgingHeader.h`, directly after `#import "TVControllerMappingBridge.h"`, add:
```objc
#import "DOLControllerSettingsBridge.h"
```

- [ ] **Step 7: Write the Swift mapping**

`Source/iOS/App/Common/Swift/Controllers/Player/ExpressionCheck.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The raw-expression editor's verdict on its text (controller hub spec, edge case "An Advanced
/// expression does not parse"): what it shows and whether Save is allowed. The parse itself is the
/// core's (`DOLControllerSettingsBridge.parse(expression:)`); this only maps its answer.
///
/// The check has to happen before saving: `ControlReference::SetExpression` installs a text that
/// does not parse and only returns the error (ControlReference.cpp:52-59), and the mapping bridge
/// discards that return value (TVControllerMappingBridge.mm:543).
struct ExpressionCheck: Equatable {
  enum Status: Equatable {
    case valid
    /// Blank: saving it unbinds the control.
    case empty
    case invalid
  }

  let status: Status
  let message: String

  var canSave: Bool { status != .invalid }

  init(status: Status, message: String) {
    self.status = status
    self.message = message
  }

  init(parseStatus: ExpressionParseStatus, parserMessage: String?) {
    switch parseStatus {
    case .successful:
      self.init(status: .valid, message: L("The expression is valid."))
    case .empty:
      self.init(status: .empty, message: L("Empty: saving unbinds this control."))
    case .syntaxError:
      self.init(
        status: .invalid,
        message: parserMessage.map { String(format: L("Not saved: %@"), $0) } ?? L("Not saved: the expression does not parse."))
    @unknown default:
      self.init(status: .invalid, message: L("Not saved: the expression does not parse."))
    }
  }
}
```

- [ ] **Step 8: Generate and run the test to verify it passes**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/ExpressionCheckTests"`
Expected: `Executed 8 tests, with 0 failures`. The four parser tests run the real parser in the core dylib the test host links, which proves the link.

- [ ] **Step 9: Run the gates**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice. The tvOS build links the bridge against the tvOS slice.
Then run `git status --short build/xcframework`. If the builds touched the tracked prebuilts, run `git checkout -- build/xcframework`.

- [ ] **Step 10: Commit**

```bash
git add Source/iOS/App/Common/Emulation/DOLControllerSettingsBridge.h Source/iOS/App/Common/Emulation/DOLControllerSettingsBridge.mm \
  Source/iOS/App/Common/Swift/BridgingHeader.h Source/iOS/App/Common/Swift/Controllers/Player/ExpressionCheck.swift \
  Source/iOS/App/DolphiniOSTests/ExpressionCheckTests.swift
git commit -m "feat(input): parse check and numeric settings bridge, app-side"
```

---

### Task 6: Motion settings — setters, gyro pointer sensitivity, the motion-settings notice

**Files:**
- Modify: `Source/iOS/App/Common/Swift/Controllers/MotionSettings.swift` (whole file)
- Modify: `Source/iOS/App/DolphiniOS/UI/Emulation/TouchController/TCDeviceMotion.swift:118-128` (`gyroPointerOffsets`), `:318-319` (its call in `handleIRCursorMapping`)
- Modify: `Source/iOS/App/Common/UI/Emulation/EmuEventVC.h:27` (after `DOLOnScreenControlsChosenNotification`)
- Modify: `Source/iOS/App/Common/UI/Emulation/EmuEventVC.m:10`
- Test: `Source/iOS/App/DolphiniOSTests/MotionSettingsTests.swift` (append)
- Test: `Source/iOS/App/DolphiniOSTests/TCDeviceMotionMappingTests.swift` (append)

**Interfaces:**
- Consumes: `MotionSettings.Key`, `TCDeviceMotion.gyroPointerOffsets`.
- Produces:
  - `MotionSettings.Key.gyroPointerSensitivity` (`"motion_gyro_pointer_sensitivity"`), registered default `1.0`.
  - `MotionSettings.gyroPointerSensitivity(in:) -> Double`. A missing, non-finite or non-positive stored value reads as 1.
  - `MotionSettings.setInvertRoll(_:in:)`, `setInvertPitch(_:in:)`, `setEnhancedShakeDetection(_:in:)` (Bool), and `setIRPointerGain(_:in:)`, `setGyroPointerSensitivity(_:in:)` (Double). Each takes `in store: UserDefaults = .standard`.
  - `TCDeviceMotion.gyroPointerOffsets(current:baseline:useYawForHorizontal:gain:)`, where `gain: Double = 1` multiplies both axes.
  - `Notification.Name.DOLMotionSettingsChanged`, raw value `"DOLMotionSettingsChanged"`: the string `EmulationScreen.swift:1102` observes.

- [ ] **Step 1: Write the failing tests**

Append inside `MotionSettingsTests`:
```swift
  /// Decision 4: a multiplier on TCDeviceMotion's constants, 1.0 by default so nothing changes.
  func testGyroPointerSensitivityDefaultsToOne() {
    XCTAssertEqual(MotionSettings.gyroPointerSensitivity(in: store), 1.0, "unregistered reads as 1")
    MotionSettings.registerDefaults(in: store)
    XCTAssertEqual(MotionSettings.gyroPointerSensitivity(in: store), 1.0)
    store.set(-2.0, forKey: MotionSettings.Key.gyroPointerSensitivity)
    XCTAssertEqual(MotionSettings.gyroPointerSensitivity(in: store), 1.0, "a broken value reads as 1")
    XCTAssertEqual(MotionSettings.Key.gyroPointerSensitivity, "motion_gyro_pointer_sensitivity")
  }

  func testSettersWriteTheExistingKeys() {
    MotionSettings.setInvertRoll(true, in: store)
    MotionSettings.setInvertPitch(true, in: store)
    MotionSettings.setEnhancedShakeDetection(false, in: store)
    MotionSettings.setIRPointerGain(2.0, in: store)
    MotionSettings.setGyroPointerSensitivity(1.5, in: store)
    XCTAssertTrue(store.bool(forKey: "motion_invert_roll"))
    XCTAssertTrue(store.bool(forKey: "motion_invert_pitch"))
    XCTAssertEqual(store.object(forKey: "motion_enhanced_shake_detection") as? Bool, false)
    XCTAssertEqual(store.double(forKey: "touch_overlay_ir_pointer_gain"), 2.0)
    XCTAssertEqual(MotionSettings.gyroPointerSensitivity(in: store), 1.5)
  }

  /// The observers in EmulationScreen and the existing posters use the literal string; the declared
  /// name must be the same string or the new posters would restart nothing.
  func testMotionSettingsChangedIsTheStringTheObserversUse() {
    XCTAssertEqual(Notification.Name.DOLMotionSettingsChanged.rawValue, "DOLMotionSettingsChanged")
  }
```
The existing `testBundledDefaultPreferencesDefineNoMotionSettingsKey` iterates `MotionSettings.defaults`. That now includes the new key, which `DefaultPreferences.plist` does not define (`Project/Assets/DefaultPreferences.plist` has no `motion_*` key), so the test keeps holding unchanged.

Append inside `TCDeviceMotionMappingTests`, after the existing gyro-pointer tests:
```swift
  /// Gyro pointer sensitivity (decision 4) scales both axes on top of the fixed constants; 1 is
  /// today's behaviour.
  func testGyroPointerSensitivityScalesBothAxes() {
    let start = TCDeviceMotion.PointerAttitude(roll: 0, pitch: 0, yaw: 0)
    let moved = TCDeviceMotion.PointerAttitude(roll: 0.1, pitch: 0.1, yaw: 0)
    let unscaled = TCDeviceMotion.gyroPointerOffsets(current: moved, baseline: start, useYawForHorizontal: false)
    let scaled = TCDeviceMotion.gyroPointerOffsets(current: moved, baseline: start, useYawForHorizontal: false, gain: 1.5)
    XCTAssertEqual(unscaled.horizontal, 0.1 * TCDeviceMotion.gyroPointerHorizontalSensitivity, accuracy: 0.0001)
    XCTAssertEqual(scaled.horizontal, 1.5 * unscaled.horizontal, accuracy: 0.0001)
    XCTAssertEqual(scaled.vertical, 1.5 * unscaled.vertical, accuracy: 0.0001)
  }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/MotionSettingsTests -only-testing:iCubeTests/TCDeviceMotionMappingTests"`
Expected: build failure. The compiler reports, among others:
- `type 'MotionSettings' has no member 'gyroPointerSensitivity'`;
- `type 'Notification.Name' has no member 'DOLMotionSettingsChanged'`;
- `extra argument 'gain' in call`.

- [ ] **Step 3: Write `MotionSettings`**

Replace `Source/iOS/App/Common/Swift/Controllers/MotionSettings.swift` with:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The single source of truth for the motion and pointer defaults, read by `TCDeviceMotion` and the
/// settings screens. `MotionSettings.defaults` replaced the equivalent entries that used to live in
/// `DefaultPreferences.plist` (commit 2691df551c): the values here are exactly what that plist
/// shipped, so no user sees a behaviour change. Defaults are registered on every launch (registered
/// values are not persisted); `DefaultPreferences.plist` must not define any of these keys, or its
/// registration (which runs after this one) would silently win.
enum MotionSettings {
  enum Key {
    static let useYawForHorizontal = "motion_use_yaw_for_horizontal"
    static let invertRoll = "motion_invert_roll"
    static let invertPitch = "motion_invert_pitch"
    static let enhancedShakeDetection = "motion_enhanced_shake_detection"
    static let full6DOF = "motion_enable_full_6dof"
    static let wiimoteIMU = "motion_wiimote_imu_enabled"
    static let nunchukIMU = "motion_nunchuck_imu_enabled"
    static let irPointerGain = "touch_overlay_ir_pointer_gain"
    /// New in controller hub Phase 3: a multiplier on `TCDeviceMotion`'s gyro pointer constants.
    static let gyroPointerSensitivity = "motion_gyro_pointer_sensitivity"
  }

  static let defaults: [String: Any] = [
    Key.useYawForHorizontal: false,
    Key.invertRoll: false,
    Key.invertPitch: false,
    // `setupEnhancedMotionControls()` used to force this on for every touchscreen Wii boot.
    Key.enhancedShakeDetection: true,
    Key.full6DOF: true,
    Key.wiimoteIMU: true,
    Key.nunchukIMU: false,
    Key.irPointerGain: 1.0,
    // 1.0 keeps the gyro pointer exactly as it was before the setting existed.
    Key.gyroPointerSensitivity: 1.0,
  ]

  static func registerDefaults(in store: UserDefaults = .standard) {
    store.register(defaults: defaults)
  }

  static func useYawForHorizontal(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.useYawForHorizontal) }
  static func invertRoll(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.invertRoll) }
  static func invertPitch(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.invertPitch) }
  static func enhancedShakeDetection(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.enhancedShakeDetection) }
  static func full6DOF(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.full6DOF) }
  static func wiimoteIMU(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.wiimoteIMU) }
  static func nunchukIMU(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.nunchukIMU) }
  static func irPointerGain(in store: UserDefaults = .standard) -> Double { store.double(forKey: Key.irPointerGain) }

  /// A missing (unregistered reads 0), non-finite or non-positive value reads as 1, the neutral gain.
  static func gyroPointerSensitivity(in store: UserDefaults = .standard) -> Double {
    let value = store.double(forKey: Key.gyroPointerSensitivity)
    return value.isFinite && value > 0 ? value : 1
  }

  // Writers for the player screen's Pointer & Motion rows. The same keys, so `TCDeviceMotion`, the
  // touch overlay and the older screens all see the change. `TCDeviceMotion` reads invert and gyro
  // sensitivity on every motion sample; only the shake setting needs `.DOLMotionSettingsChanged`,
  // because the emulation screen decides from it whether motion runs at all.
  static func setInvertRoll(_ value: Bool, in store: UserDefaults = .standard) { store.set(value, forKey: Key.invertRoll) }
  static func setInvertPitch(_ value: Bool, in store: UserDefaults = .standard) { store.set(value, forKey: Key.invertPitch) }
  static func setEnhancedShakeDetection(_ value: Bool, in store: UserDefaults = .standard) {
    store.set(value, forKey: Key.enhancedShakeDetection)
  }
  static func setIRPointerGain(_ value: Double, in store: UserDefaults = .standard) { store.set(value, forKey: Key.irPointerGain) }
  static func setGyroPointerSensitivity(_ value: Double, in store: UserDefaults = .standard) {
    store.set(value, forKey: Key.gyroPointerSensitivity)
  }
}
```

- [ ] **Step 4: Apply the gain in `TCDeviceMotion`**

In `TCDeviceMotion.swift`, replace `gyroPointerOffsets` (from `static func gyroPointerOffsets(` through its closing brace) with:
```swift
  static func gyroPointerOffsets(
    current: PointerAttitude,
    baseline: PointerAttitude,
    useYawForHorizontal: Bool,
    gain: Double = 1
  ) -> (horizontal: Double, vertical: Double) {
    let horizontalDelta = useYawForHorizontal
      ? wrappedAngle(current.yaw - baseline.yaw)
      : wrappedAngle(current.roll - baseline.roll)
    let verticalDelta = wrappedAngle(current.pitch - baseline.pitch)
    // `gain` is the user's gyro pointer sensitivity (`MotionSettings.gyroPointerSensitivity`, 1 by
    // default) on top of the fixed per-axis constants.
    return (
      horizontalDelta * gyroPointerHorizontalSensitivity * gain,
      verticalDelta * gyroPointerVerticalSensitivity * gain)
  }
```
In `handleIRCursorMapping(motion:)`, replace
```swift
    var (horizontalValue, verticalValue) = Self.gyroPointerOffsets(
      current: attitude, baseline: baseline, useYawForHorizontal: useYawForHorizontal)
```
with
```swift
    // Read per sample, like the invert keys above, so a change applies without a restart.
    var (horizontalValue, verticalValue) = Self.gyroPointerOffsets(
      current: attitude, baseline: baseline, useYawForHorizontal: useYawForHorizontal,
      gain: MotionSettings.gyroPointerSensitivity())
```

- [ ] **Step 5: Declare the notification**

In `EmuEventVC.h`, directly after the `DOLOnScreenControlsChosenNotification` declaration, add:
```objc

/// Posted after a motion setting changes that decides whether the motion system runs (shake
/// detection), so the running emulation restarts it (`EmulationScreen`'s observer). Older posters
/// still use the literal string; this declares the same name for new code.
FOUNDATION_EXPORT NSNotificationName const DOLMotionSettingsChangedNotification;
```
In `EmuEventVC.m`, directly after the `DOLOnScreenControlsChosenNotification` definition, add:
```objc
NSNotificationName const DOLMotionSettingsChangedNotification = @"DOLMotionSettingsChanged";
```

- [ ] **Step 6: Run the tests to verify they pass, then the gates**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/MotionSettingsTests -only-testing:iCubeTests/TCDeviceMotionMappingTests"`
Expected: 0 failures. `MotionSettingsTests` runs 7 tests, including the unchanged `testBundledDefaultPreferencesDefineNoMotionSettingsKey`.
Then: `make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` and `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice.

- [ ] **Step 7: Commit**

```bash
git add Source/iOS/App/Common/Swift/Controllers/MotionSettings.swift \
  Source/iOS/App/DolphiniOS/UI/Emulation/TouchController/TCDeviceMotion.swift \
  Source/iOS/App/Common/UI/Emulation/EmuEventVC.h Source/iOS/App/Common/UI/Emulation/EmuEventVC.m \
  Source/iOS/App/DolphiniOSTests/MotionSettingsTests.swift Source/iOS/App/DolphiniOSTests/TCDeviceMotionMappingTests.swift
git commit -m "feat(motion): gyro pointer sensitivity, setters, declared notice"
```

---

### Task 7: Pure units — control categories, numeric steps, Advanced groups

**Files:**
- Create: `Source/iOS/App/Common/Swift/Controllers/Player/ControlCategory.swift`
- Create: `Source/iOS/App/Common/Swift/Controllers/Player/PlayerAdvancedSettings.swift`
- Test: `Source/iOS/App/DolphiniOSTests/ControlCategoryTests.swift`
- Test: `Source/iOS/App/DolphiniOSTests/PlayerAdvancedSettingsTests.swift`

**Interfaces:**
- Consumes: `RemapGroupOwner`, `RemapControlRow`, `RemapSystem` (`RemapModel.swift`).
- Produces:
  - `enum ControlCategory: CaseIterable { case face, dPad, sticks, triggers, system, motion }`, with:
    - `var id: String`, `var title: String`.
    - `static func of(owner: RemapGroupOwner, groupId: Int, index: Int) -> ControlCategory?` (nil means not listed under Buttons).
    - `static func title(for row: RemapControlRow) -> String`.
    - `static func grouped(_ controls: [RemapControlRow]) -> [(category: ControlCategory, rows: [RemapControlRow])]`.
  - `struct NumericSettingState: Equatable`, with `owner`, `groupId`, `index`, `name`, `suffix`, `isToggle`, `isInteger`, `value`, `minimum`, `maximum`, `defaultValue`, `isExpression` and `var id: String` (`"setting-<owner>-<group>-<index>"`).
  - `enum NumericSettingSteps`, with:
    - `static func stepSize(minimum: Double, maximum: Double, isInteger: Bool) -> Double`
    - `static func values(for setting: NumericSettingState) -> [Double]`
    - `static func nearest(to value: Double, in values: [Double]) -> Double`
    - `static func label(_ value: Double, suffix: String) -> String`
  - `enum AdvancedSettingGroups`, with `struct Entry: Equatable { owner, groupId, title }`, `static let imuPointGroup = 12` and `static func entries(for system: RemapSystem, attachment: Int) -> [Entry]`.

- [ ] **Step 1: Write the failing tests**

`Source/iOS/App/DolphiniOSTests/ControlCategoryTests.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// Which Buttons section each control lands in, and the titles that say which group a row belongs
/// to. Control orders are the core's `AddInput` lists (GCPadEmu.cpp, WiimoteEmu.cpp, Nunchuk.cpp,
/// Classic.cpp), as the bridges report them.
final class ControlCategoryTests: XCTestCase {

  private func rows(_ owner: RemapGroupOwner, _ group: Int, _ names: [String]) -> [RemapControlRow] {
    names.enumerated().map { RemapControlRow(owner: owner, groupId: group, index: $0.offset, name: $0.element, expression: "") }
  }

  private func categories(_ rows: [RemapControlRow]) -> [ControlCategory?] {
    rows.map { ControlCategory.of(owner: $0.owner, groupId: $0.groupId, index: $0.index) }
  }

  func test_gameCubeButtons_faceThenZThenStart() {
    XCTAssertEqual(
      categories(rows(.gcPad, 0, ["A", "B", "X", "Y", "Z", "START"])),
      [.face, .face, .face, .face, .triggers, .system])
  }

  func test_gameCubeGroups() {
    XCTAssertEqual(ControlCategory.of(owner: .gcPad, groupId: 1, index: 0), .sticks)
    XCTAssertEqual(ControlCategory.of(owner: .gcPad, groupId: 2, index: 0), .sticks)
    XCTAssertEqual(ControlCategory.of(owner: .gcPad, groupId: 3, index: 0), .dPad)
    XCTAssertEqual(ControlCategory.of(owner: .gcPad, groupId: 4, index: 2), .triggers)
  }

  /// Rumble is an output: capture polls inputs, so it has nothing to bind there. Options groups
  /// hold settings only. Both stay editable as raw expressions under Advanced.
  func test_rumbleAndOptionsAreNotButtons() {
    XCTAssertNil(ControlCategory.of(owner: .gcPad, groupId: 5, index: 0))
    XCTAssertNil(ControlCategory.of(owner: .gcPad, groupId: 7, index: 0))
    XCTAssertNil(ControlCategory.of(owner: .wiimote, groupId: 6, index: 0))
    XCTAssertNil(ControlCategory.of(owner: .wiimote, groupId: 8, index: 0))
  }

  func test_wiiRemoteButtons_faceThenMinusPlusHome() {
    XCTAssertEqual(
      categories(rows(.wiimote, 0, ["A", "B", "1", "2", "-", "+", "HOME"])),
      [.face, .face, .face, .face, .system, .system, .system])
  }

  func test_wiiRemoteMotionGroups() {
    for group in [2, 3, 4, 5] {
      XCTAssertEqual(ControlCategory.of(owner: .wiimote, groupId: group, index: 0), .motion, "group \(group)")
    }
  }

  func test_nunchuk_cAndZAreTriggers_stickIsSticks_restIsMotion() {
    XCTAssertEqual(categories(rows(.nunchuk, 0, ["C", "Z"])), [.triggers, .triggers])
    XCTAssertEqual(ControlCategory.of(owner: .nunchuk, groupId: 1, index: 0), .sticks)
    XCTAssertEqual(ControlCategory.of(owner: .nunchuk, groupId: 4, index: 0), .motion)
  }

  func test_classicButtons() {
    XCTAssertEqual(
      categories(rows(.classic, 0, ["A", "B", "X", "Y", "ZL", "ZR", "-", "+", "HOME"])),
      [.face, .face, .face, .face, .triggers, .triggers, .system, .system, .system])
    XCTAssertEqual(ControlCategory.of(owner: .classic, groupId: 1, index: 0), .triggers)
    XCTAssertEqual(ControlCategory.of(owner: .classic, groupId: 2, index: 0), .dPad)
    XCTAssertEqual(ControlCategory.of(owner: .classic, groupId: 4, index: 0), .sticks)
  }

  func test_titlesNameTheirGroup() {
    XCTAssertEqual(ControlCategory.title(for: rows(.gcPad, 1, ["Up"])[0]), "Control Stick Up")
    XCTAssertEqual(ControlCategory.title(for: rows(.gcPad, 2, ["Up"])[0]), "C-Stick Up")
    XCTAssertEqual(ControlCategory.title(for: rows(.wiimote, 3, ["Recenter"])[0]), "Pointer Recenter")
    XCTAssertEqual(ControlCategory.title(for: rows(.classic, 0, ["A"])[0]), "Classic A", "a Wii Remote + Classic has two A buttons")
    XCTAssertEqual(ControlCategory.title(for: rows(.nunchuk, 0, ["C"])[0]), "Nunchuk C")
    XCTAssertEqual(ControlCategory.title(for: rows(.wiimote, 0, ["A"])[0]), "A", "the Wii Remote's own buttons keep their printed name")
  }

  /// The size the spec's "one row per control" reaches for a Wii Remote + Classic Controller, with
  /// the real control counts: 59 capture rows, plus Rumble only under Advanced.
  func test_wiiRemotePlusClassic_groupsInto59Rows() {
    let names = { (count: Int) in (0 ..< count).map { "c\($0)" } }
    let wii = rows(.wiimote, 0, names(7)) + rows(.wiimote, 1, names(4)) + rows(.wiimote, 3, names(7))
      + rows(.wiimote, 5, names(6)) + rows(.wiimote, 4, names(5)) + rows(.wiimote, 2, names(3)) + rows(.wiimote, 6, names(1))
    let classic = rows(.classic, 0, names(9)) + rows(.classic, 2, names(4)) + rows(.classic, 3, names(5))
      + rows(.classic, 4, names(5)) + rows(.classic, 1, names(4))
    let grouped = ControlCategory.grouped(wii + classic)
    XCTAssertEqual(grouped.map { $0.category }, [.face, .dPad, .sticks, .triggers, .system, .motion])
    XCTAssertEqual(grouped.map { $0.rows.count }, [8, 8, 10, 6, 6, 21])
    XCTAssertEqual(grouped.map { $0.rows.count }.reduce(0, +), 59)
  }

  func test_grouped_keepsTheGivenOrderInsideACategory_andDropsEmptyOnes() {
    let controls = rows(.gcPad, 3, ["Up", "Down"]) + rows(.gcPad, 0, ["A"])
    let grouped = ControlCategory.grouped(controls)
    XCTAssertEqual(grouped.map { $0.category }, [.face, .dPad])
    XCTAssertEqual(grouped[1].rows.map(\.name), ["Up", "Down"])
  }
}
```

`Source/iOS/App/DolphiniOSTests/PlayerAdvancedSettingsTests.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// The stepped values a numeric setting's picker offers (a slider cannot be reached by a pad on iOS
/// or focused on tvOS), their labels, and which groups Advanced lists.
final class PlayerAdvancedSettingsTests: XCTestCase {

  private func setting(
    min: Double, max: Double, value: Double, defaultValue: Double, isInteger: Bool = false, suffix: String = "%"
  ) -> NumericSettingState {
    NumericSettingState(
      owner: .gcPad, groupId: 1, index: 0, name: "Dead Zone", suffix: suffix, isToggle: false, isInteger: isInteger,
      value: value, minimum: min, maximum: max, defaultValue: defaultValue, isExpression: false)
  }

  /// `AddDeadzoneSetting` (ControlGroup.cpp): 0...50 %.
  func test_deadZone_stepsOfFive() {
    let values = NumericSettingSteps.values(for: setting(min: 0, max: 50, value: 0, defaultValue: 0))
    XCTAssertEqual(values, [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50])
  }

  /// Gate Size (AnalogStick.cpp:89-97): 0.01...100 %, default the stick's gate radius.
  func test_gateSize_includesTheEndsTheDefaultAndTheCurrentValue() {
    let values = NumericSettingSteps.values(for: setting(min: 0.01, max: 100, value: 64.2, defaultValue: 79.37125))
    XCTAssertEqual(values.first, 0.01)
    XCTAssertEqual(values.last, 100)
    XCTAssertTrue(values.contains(79.37125), "the default is always offered")
    XCTAssertTrue(values.contains(64.2), "the current value is always offered, so the picker shows a selection")
    XCTAssertTrue(values.contains(50))
    XCTAssertEqual(values, values.sorted())
  }

  func test_integerSettings_stepByWholeNumbers() {
    XCTAssertEqual(NumericSettingSteps.values(for: setting(min: 0, max: 3, value: 1, defaultValue: 1, isInteger: true)), [0, 1, 2, 3])
  }

  func test_nearest() {
    XCTAssertEqual(NumericSettingSteps.nearest(to: 12.4, in: [0, 5, 10, 15]), 10)
    XCTAssertEqual(NumericSettingSteps.nearest(to: 13, in: [0, 5, 10, 15]), 15)
  }

  func test_labels() {
    XCTAssertEqual(NumericSettingSteps.label(25, suffix: "%"), "25%")
    XCTAssertEqual(NumericSettingSteps.label(79.37125, suffix: "%"), "79.37%")
    XCTAssertEqual(NumericSettingSteps.label(45, suffix: "°"), "45°")
    XCTAssertEqual(NumericSettingSteps.label(10, suffix: "cm"), "10 cm")
    XCTAssertEqual(NumericSettingSteps.label(0.5, suffix: ""), "0.5")
    XCTAssertEqual(NumericSettingSteps.label(0, suffix: ""), "0")
  }

  func test_advancedGroups_gameCube() {
    XCTAssertEqual(
      AdvancedSettingGroups.entries(for: .gamecube, attachment: 0).map(\.groupId), [1, 2, 4])
  }

  func test_advancedGroups_wiiFollowTheExtension() {
    func keys(_ attachment: Int) -> [String] {
      AdvancedSettingGroups.entries(for: .wii, attachment: attachment).map { "\($0.owner)-\($0.groupId)" }
    }
    XCTAssertEqual(keys(0), ["wiimote-3", "wiimote-12"])
    XCTAssertEqual(keys(1), ["wiimote-3", "wiimote-12", "nunchuk-1"])
    XCTAssertEqual(keys(2), ["wiimote-3", "wiimote-12", "classic-3", "classic-4", "classic-1"])
  }

  /// `WiimoteEmu::WiimoteGroup`: …, IMUAccelerometer = 10, IMUGyroscope = 11, IMUPoint = 12.
  func test_imuPointIsGroupTwelve() {
    XCTAssertEqual(AdvancedSettingGroups.imuPointGroup, 12)
  }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/ControlCategoryTests -only-testing:iCubeTests/PlayerAdvancedSettingsTests"`
Expected: build failure, `cannot find 'ControlCategory' in scope`, `cannot find 'NumericSettingState' in scope`.

- [ ] **Step 3: Write `ControlCategory`**

`Source/iOS/App/Common/Swift/Controllers/Player/ControlCategory.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The player screen's Buttons sections (controller hub spec, "Player screen" item 4): every
/// capturable control, grouped by what it is on the controller rather than by Dolphin's internal
/// group. Keyed by owner, raw group id and the control's index in its group; the indices follow the
/// core's `AddInput` order (GCPadEmu.cpp:46-50, WiimoteEmu.cpp:214-218, Nunchuk.cpp:37-38,
/// Classic.cpp:56-61).
enum ControlCategory: CaseIterable {
  case face
  case dPad
  case sticks
  case triggers
  case system
  case motion

  var id: String {
    switch self {
    case .face: return "face"
    case .dPad: return "dpad"
    case .sticks: return "sticks"
    case .triggers: return "triggers"
    case .system: return "system"
    case .motion: return "motion"
    }
  }

  var title: String {
    switch self {
    case .face: return L("Face Buttons")
    case .dPad: return L("D-Pad")
    case .sticks: return L("Sticks")
    case .triggers: return L("Triggers")
    case .system: return L("System")
    case .motion: return L("Motion")
    }
  }

  /// nil: not listed under Buttons. Rumble is an output, and capture only listens to inputs; the
  /// Options groups hold settings and no controls. Both stay editable as raw expressions under
  /// Advanced.
  static func of(owner: RemapGroupOwner, groupId: Int, index: Int) -> ControlCategory? {
    switch owner {
    case .gcPad:
      // PadGroup: Buttons=0 (A B X Y Z START), MainStick=1, CStick=2, DPad=3, Triggers=4, Rumble=5.
      switch groupId {
      case 0: return index < 4 ? .face : (index == 4 ? .triggers : .system)
      case 1, 2: return .sticks
      case 3: return .dPad
      case 4: return .triggers
      default: return nil
      }
    case .wiimote:
      // WiimoteGroup: Buttons=0 (A B 1 2 - + HOME), DPad=1, Shake=2, Point=3, Tilt=4, Swing=5, Rumble=6.
      switch groupId {
      case 0: return index < 4 ? .face : .system
      case 1: return .dPad
      case 2, 3, 4, 5: return .motion
      default: return nil
      }
    case .nunchuk:
      // NunchukGroup: Buttons=0 (C Z), Stick=1, Tilt=2, Swing=3, Shake=4.
      switch groupId {
      case 0: return .triggers
      case 1: return .sticks
      case 2, 3, 4: return .motion
      default: return nil
      }
    case .classic:
      // ClassicGroup: Buttons=0 (A B X Y ZL ZR - + HOME), Triggers=1, DPad=2, LeftStick=3, RightStick=4.
      switch groupId {
      case 0: return index < 4 ? .face : (index < 6 ? .triggers : .system)
      case 1: return .triggers
      case 2: return .dPad
      case 3, 4: return .sticks
      default: return nil
      }
    }
  }

  /// A row title that says which group the control belongs to: under Sticks, a bare "Up" could be
  /// either stick. The Wii Remote's and the GameCube pad's own buttons keep their printed name; an
  /// extension's say which extension, because a Wii Remote + Classic has two "A" buttons.
  static func title(for row: RemapControlRow) -> String {
    guard let format = titleFormat(owner: row.owner, groupId: row.groupId) else { return row.name }
    return String(format: format, row.name)
  }

  private static func titleFormat(owner: RemapGroupOwner, groupId: Int) -> String? {
    switch (owner, groupId) {
    case (.gcPad, 1): return L("Control Stick %@")
    case (.gcPad, 2): return L("C-Stick %@")
    case (.gcPad, 3): return L("D-Pad %@")
    case (.gcPad, 5): return L("Rumble %@")
    case (.wiimote, 1): return L("D-Pad %@")
    case (.wiimote, 2): return L("Shake %@")
    case (.wiimote, 3): return L("Pointer %@")
    case (.wiimote, 4): return L("Tilt %@")
    case (.wiimote, 5): return L("Swing %@")
    case (.wiimote, 6): return L("Rumble %@")
    case (.nunchuk, 0): return L("Nunchuk %@")
    case (.nunchuk, 1): return L("Nunchuk Stick %@")
    case (.nunchuk, 2): return L("Nunchuk Tilt %@")
    case (.nunchuk, 3): return L("Nunchuk Swing %@")
    case (.nunchuk, 4): return L("Nunchuk Shake %@")
    case (.classic, 0), (.classic, 1): return L("Classic %@")
    case (.classic, 2): return L("Classic D-Pad %@")
    case (.classic, 3): return L("Classic Left Stick %@")
    case (.classic, 4): return L("Classic Right Stick %@")
    default: return nil
    }
  }

  /// The Buttons sections: categories in `allCases` order, each with its rows in the order
  /// `controls` lists them (the `RemapGroup` order). Empty categories are left out.
  static func grouped(_ controls: [RemapControlRow]) -> [(category: ControlCategory, rows: [RemapControlRow])] {
    allCases.compactMap { category in
      let rows = controls.filter { of(owner: $0.owner, groupId: $0.groupId, index: $0.index) == category }
      return rows.isEmpty ? nil : (category, rows)
    }
  }
}
```

- [ ] **Step 4: Write the numeric settings units**

`Source/iOS/App/Common/Swift/Controllers/Player/PlayerAdvancedSettings.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One numeric setting of a control group (dead zone, gate size, IR or IMU value), as plain values
/// read through `DOLControllerSettingsBridge`.
struct NumericSettingState: Equatable {
  let owner: RemapGroupOwner
  let groupId: Int
  /// Position in the group's settings: what the bridge's setter takes.
  let index: Int
  let name: String
  /// "%", "°", "cm" or "".
  let suffix: String
  let isToggle: Bool
  let isInteger: Bool
  let value: Double
  let minimum: Double
  let maximum: Double
  let defaultValue: Double
  /// Driven by an expression rather than a number: shown, not edited.
  let isExpression: Bool

  var id: String { "setting-\(owner)-\(groupId)-\(index)" }
}

/// The values a numeric setting's picker offers. A slider cannot be reached by a pad on iOS or
/// focused on tvOS (the reason Phase 2 made Opacity a stepped picker), so every number is a picker
/// of about `targetStepCount` steps, which d-pad left/right walks through.
enum NumericSettingSteps {
  /// Step sizes, smallest first. A range is cut into steps of the first size that gives at most
  /// about `targetStepCount` of them.
  private static let stepSizes: [Double] = [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 20, 25, 50, 100]
  static let targetStepCount = 20.0
  private static let tolerance = 1e-6

  static func stepSize(minimum: Double, maximum: Double, isInteger: Bool) -> Double {
    let wanted = max(maximum - minimum, 0) / targetStepCount
    let size = stepSizes.first { $0 >= wanted } ?? stepSizes[stepSizes.count - 1]
    return isInteger ? max(1, size.rounded(.up)) : size
  }

  /// Every multiple of the step inside the range, plus the range's ends, the default and the current
  /// value: the picker always shows a selection and always offers the default back.
  static func values(for setting: NumericSettingState) -> [Double] {
    let size = stepSize(minimum: setting.minimum, maximum: setting.maximum, isInteger: setting.isInteger)
    var candidates = [setting.minimum, setting.maximum, setting.defaultValue, setting.value]
    let first = Int((setting.minimum / size).rounded(.up))
    let last = Int((setting.maximum / size).rounded(.down))
    if first <= last {
      candidates += (first ... last).map { Double($0) * size }
    }
    var values: [Double] = []
    for value in candidates.sorted() {
      if let previous = values.last, value - previous <= tolerance { continue }
      values.append(value)
    }
    return values
  }

  /// The offered value closest to `value`: what the picker shows as selected.
  static func nearest(to value: Double, in values: [Double]) -> Double {
    values.min { abs($0 - value) < abs($1 - value) } ?? value
  }

  /// "25%", "45°", "10 cm", "0.5".
  static func label(_ value: Double, suffix: String) -> String {
    var number = String(format: "%.2f", value)
    while number.hasSuffix("0") { number.removeLast() }
    if number.hasSuffix(".") { number.removeLast() }
    if number == "-0" { number = "0" }
    if suffix.isEmpty { return number }
    return suffix == "%" || suffix == "°" ? number + suffix : number + " " + suffix
  }
}

/// The control groups whose numeric settings Advanced lists (spec: "dead zones, stick ranges, IR/IMU
/// values"): every stick and trigger group, the Wii Remote's pointer (IR) and its motion pointer
/// (IMU). Group ids are the raw core enums, as in `RemapGroup`.
enum AdvancedSettingGroups {
  struct Entry: Equatable {
    let owner: RemapGroupOwner
    let groupId: Int
    let title: String
  }

  /// `WiimoteEmu::WiimoteGroup::IMUPoint` (WiimoteEmu.h:48-64). Its `Enabled` setting is the pad
  /// port's "Aim with Controller Motion"; the Physical Controller profile turns it on.
  static let imuPointGroup = 12

  static func entries(for system: RemapSystem, attachment: Int) -> [Entry] {
    switch system {
    case .gamecube:
      return [
        Entry(owner: .gcPad, groupId: 1, title: L("Control Stick")),
        Entry(owner: .gcPad, groupId: 2, title: L("C-Stick")),
        Entry(owner: .gcPad, groupId: 4, title: L("Triggers")),
      ]
    case .wii:
      var entries = [
        Entry(owner: .wiimote, groupId: 3, title: L("Pointer")),
        Entry(owner: .wiimote, groupId: imuPointGroup, title: L("Motion Pointer")),
      ]
      switch attachment {
      case 1:
        entries.append(Entry(owner: .nunchuk, groupId: 1, title: L("Nunchuk Stick")))
      case 2:
        entries += [
          Entry(owner: .classic, groupId: 3, title: L("Classic Left Stick")),
          Entry(owner: .classic, groupId: 4, title: L("Classic Right Stick")),
          Entry(owner: .classic, groupId: 1, title: L("Classic Triggers")),
        ]
      default:
        break
      }
      return entries
    }
  }
}
```

- [ ] **Step 5: Generate and run the tests to verify they pass**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/ControlCategoryTests -only-testing:iCubeTests/PlayerAdvancedSettingsTests"`
Expected: `Executed 18 tests, with 0 failures` (10 + 8).

- [ ] **Step 6: Run the gates**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice.

- [ ] **Step 7: Commit**

```bash
git add Source/iOS/App/Common/Swift/Controllers/Player/ControlCategory.swift \
  Source/iOS/App/Common/Swift/Controllers/Player/PlayerAdvancedSettings.swift \
  Source/iOS/App/DolphiniOSTests/ControlCategoryTests.swift Source/iOS/App/DolphiniOSTests/PlayerAdvancedSettingsTests.swift
git commit -m "feat(controllers): control categories and numeric setting steps"
```

---

### Task 8: Player screen state, actions, name rules and the capture row

**Files:**
- Modify: `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubState.swift:74-83` (`ConnectedPadState`)
- Modify: `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubViewModel.swift:50-61` (`LiveControllerHubReader.connectedPads()` fills `hasGyro`)
- Create: `Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenState.swift`
- Create: `Source/iOS/App/Common/Swift/Controllers/Player/ProfileNaming.swift`
- Create: `Source/iOS/App/Common/Swift/Controllers/Player/CaptureRowView.swift`
- Test: `Source/iOS/App/DolphiniOSTests/PlayerScreenStateTests.swift`

**Interfaces:**
- Consumes:
  - Task 7: `NumericSettingState`.
  - Phase 2: `PlayerState`, `PlayerSlot`, `ConnectedPadState`.
  - Phase 1: `PointerMode`, `DeviceFamily`.
  - Existing: `RemapControlRow`, `RemapExpression`, `BridgeControllerConfigWriter` (test only).
- Produces:
  - `ConnectedPadState.hasGyro: Bool`. Defaulted, so existing memberwise inits compile. The live reader sets it from `controller.motion?.hasRotationRate == true`.
  - `enum PlayerDeviceChoice: Hashable { case noDevice, touchscreen, pad(String) }`, with `init(qualifier:)`.
  - `struct DeviceOption: Equatable { let choice: PlayerDeviceChoice; let title: String }`.
  - `PlayerSlot.playerID: String`, `PlayerSlot.title: String`.
  - `RemapControlRow.editableExpression: String`.
  - `struct PointerMotionState: Equatable`, with:
    - fields `pointerMode`, `invertX`, `invertY`, `shakeToWiggle`, `dragGain`, `gyroSensitivity`, `usesProgrammaticOverlay`;
    - statics `programmaticOverlayKey`, `dragGainChoices`, `gyroSensitivityChoices`, `standard`, `snapped(_:to:)`.
  - `struct AdvancedGroupState: Equatable { owner, groupId, title, settings }`.
  - `struct PlayerScreenState: Equatable`, with:
    - fields `player`, `pads`, `profileName`, `profileEdited`, `controls`, `armedControlID`, `pointerMotion`, `motionPointerEnabled`, `showsAdvanced`, `advanced`;
    - statics `empty(_:)`, `mfiPrefix`, `isMissing(_:pads:)`;
    - computed `deviceChoice`, `boundPad`, `isTouchscreen`, `isDisconnected`, `canCapture`, `isCapturing`.
  - `struct PlayerScreenActions`, 19 closures:
    - `deviceListDestination`, `profileListDestination`, `saveProfileAs`, `resetProfile`;
    - `setExtension`, `setSideways`, `toggleCapture`, `clearBinding`;
    - `setPointerMode`, `recenterPointer`, `setDragGain`, `setGyroSensitivity`, `setInvertX`, `setInvertY`, `setShakeToWiggle`, `setMotionPointer`;
    - `toggleAdvanced`, `setNumericSetting`, `expressionDestination`.
  - `enum ProfileNaming`, with `builtInNames`, `sanitized(_:)`, `isBuiltIn(_:)`, `suggestion(padName:playerTitle:)`, `exists(_:in:)`.
  - `struct CaptureRowView: View`, `init(title:binding:isArmed:isEnabled:onActivate:onClear:)`.

- [ ] **Step 1: Write the failing tests**

`Source/iOS/App/DolphiniOSTests/PlayerScreenStateTests.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// The player screen's snapshot rules (which device a port has, whether it can capture, whether a
/// pad is "Disconnected") and the Save As name rules (decisions 10 and 11).
final class PlayerScreenStateTests: XCTestCase {

  private static let xbox = "MFi/0/Xbox Wireless Controller"
  private static let dsu = "DSUClient/0/Pad C"

  private func screen(_ qualifier: String, pads: [String] = []) -> PlayerScreenState {
    var state = PlayerScreenState.empty(
      PlayerState(kind: .gameCube, port: 1, deviceQualifier: qualifier, wiiExtension: 0, isSideways: false))
    state.pads = pads.map {
      ConnectedPadState(qualifier: $0, name: "Pad", batteryPercent: nil, isCharging: false, playerLabel: nil)
    }
    return state
  }

  func test_deviceChoice() {
    XCTAssertEqual(PlayerDeviceChoice(qualifier: ""), .noDevice)
    XCTAssertEqual(PlayerDeviceChoice(qualifier: "iOS/4/Touchscreen"), .touchscreen)
    XCTAssertEqual(PlayerDeviceChoice(qualifier: Self.xbox), .pad(Self.xbox))
    XCTAssertEqual(PlayerDeviceChoice(qualifier: Self.dsu), .pad(Self.dsu))
  }

  func test_connectedPad_canCapture() {
    let state = screen(Self.xbox, pads: [Self.xbox])
    XCTAssertFalse(state.isDisconnected)
    XCTAssertTrue(state.canCapture)
  }

  func test_missingMFiPad_isDisconnected_andCannotCapture() {
    let state = screen(Self.xbox)
    XCTAssertTrue(state.isDisconnected)
    XCTAssertFalse(state.canCapture)
  }

  /// DSU devices are not GCControllers, so they never appear in the pad list; they must still
  /// capture (RemapPlayerView's `deviceIsPhysical`) and never read "Disconnected".
  func test_dsuDevice_isNeverDisconnected_andCanCapture() {
    let state = screen(Self.dsu)
    XCTAssertFalse(state.isDisconnected)
    XCTAssertTrue(state.canCapture)
  }

  func test_touchscreenAndNoDevice_cannotCapture() {
    XCTAssertFalse(screen("iOS/0/Touchscreen").canCapture)
    XCTAssertFalse(screen("").canCapture)
    XCTAssertFalse(screen("").isDisconnected)
  }

  func test_snapped_picksTheNearestChoice_andOneForBrokenValues() {
    XCTAssertEqual(PointerMotionState.snapped(1.4, to: PointerMotionState.gyroSensitivityChoices), 1.5)
    XCTAssertEqual(PointerMotionState.snapped(0, to: PointerMotionState.dragGainChoices), 1)
    XCTAssertEqual(PointerMotionState.snapped(.nan, to: PointerMotionState.dragGainChoices), 1)
  }

  func test_editableExpression_neverTheUnboundDash() {
    XCTAssertEqual(RemapControlRow(owner: .gcPad, groupId: 0, index: 0, name: "A", expression: "—").editableExpression, "")
    XCTAssertEqual(RemapControlRow(owner: .gcPad, groupId: 0, index: 0, name: "A", expression: "`Button A`").editableExpression, "`Button A`")
  }

  // MARK: Save As names

  func test_sanitized_trimsAndReplacesSlashes() {
    XCTAssertEqual(ProfileNaming.sanitized("  My/Pad  "), "My-Pad")
  }

  /// A user profile with a device-default ("built-in") name is used instead of the bundled one for
  /// every future first bind and Reset (the user directory is searched first), so saving one asks.
  func test_builtInNames_areTheDeviceDefaults_caseInsensitively() {
    XCTAssertTrue(ProfileNaming.isBuiltIn("touchscreen"))
    XCTAssertTrue(ProfileNaming.isBuiltIn("Physical Controller"))
    XCTAssertFalse(ProfileNaming.isBuiltIn("My Pad"))
    for qualifier in ["MFi/0/Xbox", "iOS/0/Touchscreen", "DSUClient/0/Pad"] {
      let name = BridgeControllerConfigWriter().defaultProfileName(forQualifier: qualifier) ?? ""
      XCTAssertTrue(ProfileNaming.isBuiltIn(name), "\(name) is built in: it is what a first bind loads")
    }
  }

  func test_suggestion_isThePadName_elseThePlayerTitle_neverBuiltIn() {
    XCTAssertEqual(ProfileNaming.suggestion(padName: "Xbox Wireless Controller", playerTitle: "Player 1"), "Xbox Wireless Controller")
    XCTAssertEqual(ProfileNaming.suggestion(padName: nil, playerTitle: "Player 1"), "Player 1")
    XCTAssertEqual(ProfileNaming.suggestion(padName: "Touchscreen", playerTitle: "Wii Remote 1"), "Wii Remote 1")
  }

  func test_exists_isCaseInsensitive() {
    XCTAssertTrue(ProfileNaming.exists("my pad", in: ["My Pad", "DSU"]))
    XCTAssertFalse(ProfileNaming.exists("Other", in: ["My Pad"]))
  }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/PlayerScreenStateTests"`
Expected: build failure, `cannot find 'PlayerDeviceChoice' in scope`.

- [ ] **Step 3: Add `hasGyro`**

In `ControllerHubState.swift`, `ConnectedPadState`, add after `let playerLabel: String?`:
```swift
  /// The pad has a gyroscope (`GCController.motion?.hasRotationRate`). Only then does Dolphin's MFi
  /// backend expose its `Gyro …` inputs (MFiController.mm:189-198), so only then can it drive the
  /// Wii pointer. Defaulted so existing memberwise inits compile.
  var hasGyro: Bool = false
```
In `ControllerHubViewModel.swift`, `LiveControllerHubReader.connectedPads()`, replace
```swift
        playerLabel: controller.playerIndex == .indexUnset ? nil : "P\(controller.playerIndex.rawValue + 1)")
```
with
```swift
        playerLabel: controller.playerIndex == .indexUnset ? nil : "P\(controller.playerIndex.rawValue + 1)",
        hasGyro: controller.motion?.hasRotationRate == true)
```

- [ ] **Step 4: Write the state types**

`Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenState.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// What the Device list offers and selects.
enum PlayerDeviceChoice: Hashable {
  case noDevice
  case touchscreen
  /// A pad's Dolphin qualifier (`MFi/0/Xbox Wireless Controller`, `DSUClient/0/Pad C`).
  case pad(String)

  init(qualifier: String) {
    if qualifier.isEmpty {
      self = .noDevice
    } else if DeviceFamily.from(qualifier: qualifier) == .touchscreen {
      self = .touchscreen
    } else {
      self = .pad(qualifier)
    }
  }
}

/// One row of the Device list.
struct DeviceOption: Equatable {
  let choice: PlayerDeviceChoice
  let title: String
}

extension PlayerSlot {
  /// Same value as `PlayerState.id`.
  var playerID: String { (kind == .gameCube ? "gc-" : "wii-") + String(port) }
  /// "Player 1" / "Wii Remote 1": the hub's row titles.
  var title: String { String(format: kind == .gameCube ? L("Player %d") : L("Wii Remote %d"), port) }
}

extension RemapControlRow {
  /// The expression as editable text. The bridges report an unbound control as "—"
  /// (TVControllerMappingBridge.mm:529), which must never be saved back as a literal.
  var editableExpression: String { expression == RemapExpression.unboundDisplay ? "" : expression }
}

/// Pointer & Motion on the touchscreen's port, read from `PointerModeController` and
/// `MotionSettings`.
struct PointerMotionState: Equatable {
  var pointerMode: PointerMode
  /// `motion_invert_roll`: the gyro pointer's left/right.
  var invertX: Bool
  /// `motion_invert_pitch`: the gyro pointer's up/down.
  var invertY: Bool
  /// `motion_enhanced_shake_detection`: shaking the device shakes the Wii Remote.
  var shakeToWiggle: Bool
  /// `touch_overlay_ir_pointer_gain`, snapped to one of `dragGainChoices`.
  var dragGain: Double
  /// `motion_gyro_pointer_sensitivity`, snapped to one of `gyroSensitivityChoices`.
  var gyroSensitivity: Double
  /// The drag gain is read only by the programmatic overlay (`TouchOverlayView.swift:182`), which
  /// is off by default.
  var usesProgrammaticOverlay: Bool

  /// Registered as false by `DefaultPreferences.plist`; toggled in More Controller Settings.
  static let programmaticOverlayKey = "touch_overlay_programmatic"
  /// Steps across `TouchOverlayIRGeometry.dragGainRange` (0.25...4).
  static let dragGainChoices: [Double] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4]
  /// Multipliers on the gyro pointer's fixed constants; 1 is the behaviour before the setting.
  static let gyroSensitivityChoices: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3]

  static let standard = PointerMotionState(
    pointerMode: .touchFollow, invertX: false, invertY: false, shakeToWiggle: true, dragGain: 1,
    gyroSensitivity: 1, usesProgrammaticOverlay: false)

  /// The nearest choice. A missing or broken stored value reads as 1×, as
  /// `TouchOverlayIRGeometry.clampDragGain` does.
  static func snapped(_ raw: Double, to choices: [Double]) -> Double {
    guard raw.isFinite, raw > 0 else { return 1 }
    return choices.min { abs($0 - raw) < abs($1 - raw) } ?? 1
  }
}

/// One Advanced group: its title and numeric settings.
struct AdvancedGroupState: Equatable {
  let owner: RemapGroupOwner
  let groupId: Int
  let title: String
  let settings: [NumericSettingState]
}

/// Plain snapshot of one player's screen. `PlayerScreenViewModel` rebuilds it; the builder reads
/// nothing else.
struct PlayerScreenState: Equatable {
  /// Filled through the hub's `ControllerHubReading`, exactly as the hub's own row is.
  var player: PlayerState
  var pads: [ConnectedPadState]
  /// nil: not known this session ("Custom").
  var profileName: String?
  var profileEdited: Bool
  /// Every control of the port's groups (`RemapGroup.groups(for:attachment:)`), in group order.
  var controls: [RemapControlRow]
  /// The armed capture row's `RemapControlRow.id`.
  var armedControlID: String?
  var pointerMotion: PointerMotionState
  /// The Wii Remote's IMU pointer (`IMUIR/Enabled`), for a gyro pad's port.
  var motionPointerEnabled: Bool
  /// UI state, kept across reloads.
  var showsAdvanced: Bool
  var advanced: [AdvancedGroupState]

  static func empty(_ player: PlayerState) -> PlayerScreenState {
    PlayerScreenState(
      player: player, pads: [], profileName: nil, profileEdited: false, controls: [], armedControlID: nil,
      pointerMotion: .standard, motionPointerEnabled: false, showsAdvanced: false, advanced: [])
  }

  /// Dolphin's MFi qualifier prefix: the only devices that come and go with `GCController`.
  static let mfiPrefix = "MFi/"

  /// A bound MFi pad that is not connected. DSU devices are not `GCController`s, so the pad list
  /// never holds them, and they are never "missing" here (decision 11).
  static func isMissing(_ qualifier: String, pads: [ConnectedPadState]) -> Bool {
    qualifier.hasPrefix(mfiPrefix) && !pads.contains { $0.qualifier == qualifier }
  }

  var deviceChoice: PlayerDeviceChoice { PlayerDeviceChoice(qualifier: player.deviceQualifier) }
  var boundPad: ConnectedPadState? { pads.first { $0.qualifier == player.deviceQualifier } }
  var isTouchscreen: Bool { deviceChoice == .touchscreen }

  /// Bound to an MFi pad that is not connected. The binding is kept and comes back with the pad.
  var isDisconnected: Bool { Self.isMissing(player.deviceQualifier, pads: pads) }

  /// Capture listens to a real device: any non-touchscreen qualifier (MFi or DSU, as
  /// `RemapPlayerView.deviceIsPhysical`), except an MFi pad that is not connected.
  var canCapture: Bool {
    if case .pad = deviceChoice { return !isDisconnected }
    return false
  }

  var isCapturing: Bool { armedControlID != nil }
}

/// Plain closures: no bridge calls inside `PlayerScreenModelBuilder`. Destinations are factories so
/// the builder never names a bridge-backed view.
struct PlayerScreenActions {
  /// Pushes the Device list (decision 9).
  var deviceListDestination: () -> AnyView
  var profileListDestination: () -> AnyView
  /// Opens the host's Save Profile As… prompt.
  var saveProfileAs: () -> Void
  /// Asks to reset (decision 10); the host's confirmation does the load.
  var resetProfile: () -> Void
  var setExtension: (Int) -> Void
  var setSideways: (Bool) -> Void
  /// Arms the row's capture, or cancels it when that row is the armed one.
  var toggleCapture: (RemapControlRow) -> Void
  var clearBinding: (RemapControlRow) -> Void
  var setPointerMode: (PointerMode) -> Void
  var recenterPointer: () -> Void
  var setDragGain: (Double) -> Void
  var setGyroSensitivity: (Double) -> Void
  var setInvertX: (Bool) -> Void
  var setInvertY: (Bool) -> Void
  var setShakeToWiggle: (Bool) -> Void
  /// The gyro pad port's "Aim with Controller Motion".
  var setMotionPointer: (Bool) -> Void
  var toggleAdvanced: () -> Void
  var setNumericSetting: (NumericSettingState, Double) -> Void
  var expressionDestination: (RemapControlRow) -> AnyView
}
```

- [ ] **Step 5: Write the name rules**

`Source/iOS/App/Common/Swift/Controllers/Player/ProfileNaming.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The names Save Profile As… writes (decision 10). A user profile named like a device-default
/// ("built-in") profile is used instead of the bundled one for every future first bind and every
/// Reset, because `loadProfile:` and `LoadTouchscreenProfile` search the user directory first (TVControllerMappingBridge.mm:432-433,
/// EmulationCoordinator.mm:1548-1563).
enum ProfileNaming {
  /// What `BridgeControllerConfigWriter.defaultProfileName(forQualifier:)` returns
  /// (BridgeControllerConfigWriter.swift:60-68); a test ties the two together.
  static let builtInNames = ["Physical Controller", "Touchscreen", "DSU"]

  /// Trimmed; a "/" would make a sub-path of the profile directory, so it becomes "-".
  static func sanitized(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
  }

  /// Case-insensitive: the profile directory is on a case-insensitive file system.
  static func isBuiltIn(_ name: String) -> Bool {
    builtInNames.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
  }

  /// The prompt's prefill: the bound pad's name, else the player title, never a built-in name.
  /// (Typing a built-in name is allowed; the view model asks first.)
  static func suggestion(padName: String?, playerTitle: String) -> String {
    if let padName, !padName.isEmpty, !isBuiltIn(padName) { return sanitized(padName) }
    return playerTitle
  }

  static func exists(_ name: String, in profiles: [String]) -> Bool {
    profiles.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
  }
}
```

- [ ] **Step 6: Write the capture row**

`Source/iOS/App/Common/Swift/Controllers/Player/CaptureRowView.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One Buttons row: the control's name and its binding, or "Press a button…" while armed. It is a
/// `.custom` menu row, so it carries its own gestures:
/// - Tap or select arms the capture, or cancels it on the armed row.
/// - Long-press (and swipe on iOS) clears the binding. These are gesture-raised on the row's own,
///   visible cell, so they are not the lazily-built-row presentations the hub removed; the
///   raw-expression editor's Clear is the pad path.
/// - A controller's A on iOS reaches it through the row's `MenuItem.onCustomActivate`.
///
/// One `Button`, so on tvOS it is one focus target.
struct CaptureRowView: View {
  let title: String
  let binding: String
  let isArmed: Bool
  let isEnabled: Bool
  let onActivate: () -> Void
  let onClear: () -> Void

  var body: some View {
    Button(action: onActivate) {
      HStack {
        Text(title)
        Spacer()
        Text(isArmed ? L("Press a button…") : binding)
          .font(.callout)
          .foregroundStyle(isArmed ? Color.accentColor : Color.secondary)
          .lineLimit(1)
      }
    }
    .disabled(!isEnabled)
    .contextMenu {
      Button(L("Clear"), role: .destructive, action: onClear)
    }
    #if os(iOS)
    .swipeActions(edge: .trailing) {
      Button(L("Clear"), role: .destructive, action: onClear)
    }
    #endif
    .accessibilityLabel("\(title), \(isArmed ? L("Press a button…") : binding)")
  }
}
```

- [ ] **Step 7: Run the tests to verify they pass, then the gates**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/PlayerScreenStateTests"`
Expected: `Executed 11 tests, with 0 failures`.
Then: `make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` and `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `ControllerHubModelBuilderTests` and `ControllerHubViewModelTests` still compile because `hasGyro` is defaulted. Then `** BUILD SUCCEEDED **` twice.

- [ ] **Step 8: Commit**

```bash
git add Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubState.swift \
  Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubViewModel.swift \
  Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenState.swift \
  Source/iOS/App/Common/Swift/Controllers/Player/ProfileNaming.swift \
  Source/iOS/App/Common/Swift/Controllers/Player/CaptureRowView.swift \
  Source/iOS/App/DolphiniOSTests/PlayerScreenStateTests.swift
git commit -m "feat(controllers): player screen state, name rules, capture row"
```

---

### Task 9: The pure `PlayerScreenModelBuilder`

**Files:**
- Create: `Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenModelBuilder.swift`
- Test: `Source/iOS/App/DolphiniOSTests/PlayerScreenModelBuilderTests.swift`

**Interfaces:**
- Consumes:
  - Task 2: `MenuItem.onCustomActivate`. Task 3: `MenuItem.isCompactOnTV`.
  - Task 7: `ControlCategory.grouped(_:)`, `ControlCategory.title(for:)`, `NumericSettingSteps`.
  - Task 8: `PlayerScreenState`, `PlayerScreenActions`, `PlayerDeviceChoice`, `DeviceOption`, `PointerMotionState`, `CaptureRowView`.
  - Phase 1/2: `PointerMode`, `BindingDisplay`, `DeviceFamily`, `PlatformKind`, `WiimoteSlotOptions.extensionCount/extensionName(_:)`.
- Produces:
  - `enum PlayerScreenModelBuilder`, with:
    - `static func make(state:actions:platform:) -> MenuModel`
    - `static func deviceOptions(state:platform:) -> [DeviceOption]`
    - `static func deviceSummary(_:) -> String`
    - `static func showsPointerAndMotion(state:platform:) -> Bool`
    - `static func profileDisplayName(_:) -> String`
    - `static func captureRowID(_:) -> String`
  - Section ids: `device`, `profile`, `wii`, `buttons-hint`, `buttons-<category id>`, `pointer`, `advanced`, `advanced-<owner>-<group>`, `advanced-expressions`.
  - Item ids:
    - `device`, `profile-load`, `profile-save`, `profile-reset`, `wii-extension`, `wii-sideways`, `buttons-hint`, `control-<row id>`;
    - `pointer-mode`, `pointer-recenter`, `pointer-sensitivity`, `pointer-invert-x`, `pointer-invert-y`, `pointer-shake`, `pointer-motion`;
    - `advanced-toggle`, `<setting id>`, `expression-<row id>`.

- [ ] **Step 1: Write the failing tests**

`Source/iOS/App/DolphiniOSTests/PlayerScreenModelBuilderTests.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

/// Covers `PlayerScreenModelBuilder` (controller hub spec, Testing: "sections per system and
/// device; Advanced collapsed by default; Pointer & Motion only where it applies"), plus the
/// signed-off decisions 4, 7, 9 and 11. Pure: every action is a recorded closure, every
/// destination an `EmptyView`.
final class PlayerScreenModelBuilderTests: XCTestCase {

  private static let xbox = "MFi/0/Xbox Wireless Controller"
  private static let dualSense = "MFi/1/DualSense Wireless Controller"
  private static let dsu = "DSUClient/0/Pad C"
  private static let touch = "iOS/4/Touchscreen"

  private final class Recorder {
    var calls: [String] = []
  }

  private func actions(_ recorder: Recorder = Recorder()) -> PlayerScreenActions {
    PlayerScreenActions(
      deviceListDestination: { AnyView(EmptyView()) },
      profileListDestination: { AnyView(EmptyView()) },
      saveProfileAs: { recorder.calls.append("save-as") },
      resetProfile: { recorder.calls.append("reset") },
      setExtension: { recorder.calls.append("extension:\($0)") },
      setSideways: { recorder.calls.append("sideways:\($0)") },
      toggleCapture: { recorder.calls.append("capture:\($0.id)") },
      clearBinding: { recorder.calls.append("clear:\($0.id)") },
      setPointerMode: { recorder.calls.append("pointer:\($0)") },
      recenterPointer: { recorder.calls.append("recenter") },
      setDragGain: { recorder.calls.append("gain:\($0)") },
      setGyroSensitivity: { recorder.calls.append("gyro-sensitivity:\($0)") },
      setInvertX: { recorder.calls.append("invert-x:\($0)") },
      setInvertY: { recorder.calls.append("invert-y:\($0)") },
      setShakeToWiggle: { recorder.calls.append("shake:\($0)") },
      setMotionPointer: { recorder.calls.append("motion-pointer:\($0)") },
      toggleAdvanced: { recorder.calls.append("advanced") },
      setNumericSetting: { recorder.calls.append("setting:\($0.id)=\($1)") },
      expressionDestination: { _ in AnyView(EmptyView()) })
  }

  private func pad(_ qualifier: String, _ name: String, gyro: Bool = false) -> ConnectedPadState {
    ConnectedPadState(qualifier: qualifier, name: name, batteryPercent: nil, isCharging: false, playerLabel: nil, hasGyro: gyro)
  }

  private func rows(_ owner: RemapGroupOwner, _ group: Int, _ names: [String]) -> [RemapControlRow] {
    names.enumerated().map {
      RemapControlRow(owner: owner, groupId: group, index: $0.offset, name: $0.element, expression: "`Button \($0.element)`")
    }
  }

  /// A GameCube port's controls in `RemapGroup.gamecube` order, Rumble included.
  private var gameCubeControls: [RemapControlRow] {
    rows(.gcPad, 0, ["A", "B", "X", "Y", "Z", "START"]) + rows(.gcPad, 3, ["Up", "Down", "Left", "Right"])
      + rows(.gcPad, 1, ["Up", "Down", "Left", "Right", "Modifier"]) + rows(.gcPad, 4, ["L", "R", "L-Analog", "R-Analog"])
      + rows(.gcPad, 5, ["Motor"])
  }

  private func state(
    _ kind: PlayerState.Kind, device: String = "", pads: [ConnectedPadState] = [], controls: [RemapControlRow] = []
  ) -> PlayerScreenState {
    var screen = PlayerScreenState.empty(
      PlayerState(kind: kind, port: 1, deviceQualifier: device, wiiExtension: 0, isSideways: false))
    screen.pads = pads
    screen.controls = controls
    return screen
  }

  /// GameCube port 1 on a connected Xbox pad, every control listed.
  private var boundGameCube: PlayerScreenState {
    state(.gameCube, device: Self.xbox, pads: [pad(Self.xbox, "Xbox Wireless Controller")], controls: gameCubeControls)
  }

  private func make(_ state: PlayerScreenState, _ recorder: Recorder = Recorder(), platform: PlatformKind = .ios) -> MenuModel {
    PlayerScreenModelBuilder.make(state: state, actions: actions(recorder), platform: platform)
  }

  private func sectionIDs(_ model: MenuModel) -> [String] { model.sections.map(\.id) }

  private func ids(_ model: MenuModel, section id: String) -> [String] {
    model.sections.first { $0.id == id }?.items.map(\.id) ?? []
  }

  private func optionTitles(_ item: MenuItem?) -> [String] {
    guard let item, case .picker(let options, _) = item.role else { return [] }
    return options.map { $0.0 }
  }

  private func select(_ value: AnyHashable, on item: MenuItem?) {
    guard let item, case .picker(_, let selection) = item.role else { return XCTFail("not a picker") }
    selection.wrappedValue = value
  }

  private func run(_ item: MenuItem?) {
    guard let item, case .action(let action) = item.role else { return XCTFail("not an action row") }
    action()
  }

  // MARK: Sections per system and device

  func test_gameCubePort_withAPad() {
    XCTAssertEqual(
      sectionIDs(make(boundGameCube)),
      ["device", "profile", "buttons-face", "buttons-dpad", "buttons-sticks", "buttons-triggers", "buttons-system", "advanced"])
  }

  func test_gameCubePort_neverShowsWiiSections_evenOnTheTouchscreen() {
    let ids = sectionIDs(make(state(.gameCube, device: "iOS/0/Touchscreen")))
    XCTAssertFalse(ids.contains("wii"))
    XCTAssertFalse(ids.contains("pointer"))
  }

  func test_wiiPort_onTheTouchscreen_iOS() {
    XCTAssertEqual(
      sectionIDs(make(state(.wiiRemote, device: Self.touch))),
      ["device", "profile", "wii", "buttons-hint", "pointer", "advanced"])
  }

  // MARK: Device (decision 9)

  func test_deviceRow_pushesTheDeviceList() {
    guard let item = make(boundGameCube).item(id: "device"), case .destination = item.role else {
      return XCTFail("Device must be a pushed list, never a stepped picker")
    }
  }

  func test_deviceSummary() {
    XCTAssertEqual(PlayerScreenModelBuilder.deviceSummary(state(.gameCube)), "No Device")
    XCTAssertEqual(PlayerScreenModelBuilder.deviceSummary(state(.wiiRemote, device: Self.touch)), "Touchscreen")
    XCTAssertEqual(PlayerScreenModelBuilder.deviceSummary(boundGameCube), "Xbox Wireless Controller")
    XCTAssertEqual(
      PlayerScreenModelBuilder.deviceSummary(state(.gameCube, device: Self.xbox)), "Xbox Wireless Controller (Disconnected)")
    XCTAssertEqual(PlayerScreenModelBuilder.deviceSummary(state(.gameCube, device: Self.dsu)), "Pad C", "DSU is never Disconnected")
  }

  func test_deviceOptions_iOS() {
    let options = PlayerScreenModelBuilder.deviceOptions(
      state: state(.gameCube, pads: [pad(Self.xbox, "Xbox Wireless Controller")]), platform: .ios)
    XCTAssertEqual(options.map(\.title), ["None", "Touchscreen", "Xbox Wireless Controller"])
    XCTAssertEqual(options.map(\.choice), [.noDevice, .touchscreen, .pad(Self.xbox)])
  }

  func test_deviceOptions_tvOS_haveNoTouchscreen() {
    let options = PlayerScreenModelBuilder.deviceOptions(
      state: state(.gameCube, pads: [pad(Self.xbox, "Xbox Wireless Controller")]), platform: .tvos)
    XCTAssertEqual(options.map(\.title), ["None", "Xbox Wireless Controller"])
  }

  /// The bound device is always listed, so the list can mark it current.
  func test_deviceOptions_listTheBoundDeviceWhenItIsNotAConnectedPad() {
    let disconnected = PlayerScreenModelBuilder.deviceOptions(state: state(.gameCube, device: Self.xbox), platform: .ios)
    XCTAssertEqual(disconnected.last?.title, "Xbox Wireless Controller (Disconnected)")
    let dsu = PlayerScreenModelBuilder.deviceOptions(state: state(.gameCube, device: Self.dsu), platform: .ios)
    XCTAssertEqual(dsu.last, DeviceOption(choice: .pad(Self.dsu), title: "Pad C"))
  }

  // MARK: Pointer & Motion only where it applies (decisions 2, 4, 7)

  func test_tvOS_hasNoPointerAndMotion() {
    let model = make(
      state(.wiiRemote, device: Self.dualSense, pads: [pad(Self.dualSense, "DualSense", gyro: true)]), platform: .tvos)
    XCTAssertFalse(sectionIDs(model).contains("pointer"))
  }

  func test_wiiPort_gyroPad_iOS_getsOnlyTheMotionPointerToggle() {
    let model = make(state(.wiiRemote, device: Self.dualSense, pads: [pad(Self.dualSense, "DualSense", gyro: true)]))
    XCTAssertEqual(ids(model, section: "pointer"), ["pointer-motion"])
  }

  func test_wiiPort_padWithoutAGyro_hasNoPointerSection() {
    let model = make(state(.wiiRemote, device: Self.xbox, pads: [pad(Self.xbox, "Xbox")]))
    XCTAssertFalse(sectionIDs(model).contains("pointer"))
  }

  func test_pointer_follow_showsModeRecenterAndShake() {
    XCTAssertEqual(
      ids(make(state(.wiiRemote, device: Self.touch)), section: "pointer"),
      ["pointer-mode", "pointer-recenter", "pointer-shake"])
  }

  func test_pointer_gyro_addsGyroSensitivityAndInvert() {
    let recorder = Recorder()
    var screen = state(.wiiRemote, device: Self.touch)
    screen.pointerMotion.pointerMode = .gyro
    let model = make(screen, recorder)
    XCTAssertEqual(
      ids(model, section: "pointer"),
      ["pointer-mode", "pointer-recenter", "pointer-sensitivity", "pointer-invert-x", "pointer-invert-y", "pointer-shake"])
    XCTAssertTrue(model.item(id: "pointer-sensitivity")?.isCompactOnTV == true)
    XCTAssertEqual(optionTitles(model.item(id: "pointer-sensitivity")).count, PointerMotionState.gyroSensitivityChoices.count)
    select(AnyHashable(1.5), on: model.item(id: "pointer-sensitivity"))
    XCTAssertEqual(recorder.calls, ["gyro-sensitivity:1.5"])
  }

  func test_pointer_dragAddsTheDragGain_onlyOnTheProgrammaticOverlay() {
    let recorder = Recorder()
    var screen = state(.wiiRemote, device: Self.touch)
    screen.pointerMotion.pointerMode = .touchDrag
    XCTAssertEqual(ids(make(screen), section: "pointer"), ["pointer-mode", "pointer-recenter", "pointer-shake"])
    screen.pointerMotion.usesProgrammaticOverlay = true
    let model = make(screen, recorder)
    XCTAssertEqual(ids(model, section: "pointer"), ["pointer-mode", "pointer-recenter", "pointer-sensitivity", "pointer-shake"])
    select(AnyHashable(2.0), on: model.item(id: "pointer-sensitivity"))
    XCTAssertEqual(recorder.calls, ["gain:2.0"])
  }

  func test_pointerModes_inTheSpecsOrder() {
    XCTAssertEqual(
      optionTitles(make(state(.wiiRemote, device: Self.touch)).item(id: "pointer-mode")),
      ["Touch – Follow", "Touch – Drag", "Gyro"])
  }

  // MARK: Advanced

  func test_advanced_isCollapsedByDefault() {
    let recorder = Recorder()
    let model = make(boundGameCube, recorder)
    XCTAssertEqual(sectionIDs(model).filter { $0.hasPrefix("advanced") }, ["advanced"])
    XCTAssertEqual(model.item(id: "advanced-toggle")?.title, "Show Advanced")
    run(model.item(id: "advanced-toggle"))
    XCTAssertEqual(recorder.calls, ["advanced"])
  }

  func test_advanced_expanded_listsSettingsAndEveryRawBinding() {
    var screen = boundGameCube
    screen.showsAdvanced = true
    let deadZone = NumericSettingState(
      owner: .gcPad, groupId: 1, index: 0, name: "Dead Zone", suffix: "%", isToggle: false, isInteger: false,
      value: 15, minimum: 0, maximum: 50, defaultValue: 0, isExpression: false)
    let scripted = NumericSettingState(
      owner: .gcPad, groupId: 1, index: 1, name: "Virtual Notches", suffix: "°", isToggle: false, isInteger: false,
      value: 0, minimum: 0, maximum: 45, defaultValue: 0, isExpression: true)
    screen.advanced = [AdvancedGroupState(owner: .gcPad, groupId: 1, title: "Control Stick", settings: [deadZone, scripted])]
    let model = make(screen)
    XCTAssertEqual(sectionIDs(model).filter { $0.hasPrefix("advanced") }, ["advanced", "advanced-gcPad-1", "advanced-expressions"])
    XCTAssertEqual(model.item(id: "advanced-toggle")?.title, "Hide Advanced")
    XCTAssertTrue(model.item(id: deadZone.id)?.isCompactOnTV == true)
    XCTAssertEqual(optionTitles(model.item(id: deadZone.id)).count, 11)
    XCTAssertEqual(model.item(id: scripted.id)?.subtitle, "Set by an expression")
    XCTAssertEqual(ids(model, section: "advanced-expressions").count, gameCubeControls.count, "Rumble too: outputs are edited here")
  }

  func test_advanced_settingPickerReportsTheValue() {
    let recorder = Recorder()
    var screen = state(.gameCube)
    screen.showsAdvanced = true
    let deadZone = NumericSettingState(
      owner: .gcPad, groupId: 1, index: 0, name: "Dead Zone", suffix: "%", isToggle: false, isInteger: false,
      value: 15, minimum: 0, maximum: 50, defaultValue: 0, isExpression: false)
    screen.advanced = [AdvancedGroupState(owner: .gcPad, groupId: 1, title: "Control Stick", settings: [deadZone])]
    select(AnyHashable(25.0), on: make(screen, recorder).item(id: deadZone.id))
    XCTAssertEqual(recorder.calls, ["setting:\(deadZone.id)=25.0"])
  }

  // MARK: Buttons and capture (decision 11)

  func test_rumbleIsNotACaptureRow() {
    let model = make(boundGameCube)
    XCTAssertNil(model.item(id: "control-gcPad-5-0"))
    XCTAssertEqual(ids(model, section: "buttons-face"), ["control-gcPad-0-0", "control-gcPad-0-1", "control-gcPad-0-2", "control-gcPad-0-3"])
  }

  func test_captureRow_padActivateTogglesThatControl() {
    let recorder = Recorder()
    make(boundGameCube, recorder).item(id: "control-gcPad-0-1")?.onCustomActivate?()
    XCTAssertEqual(recorder.calls, ["capture:gcPad-0-1"])
  }

  func test_armedCapture_leavesOnlyTheArmedRowEnabled() {
    var screen = boundGameCube
    screen.armedControlID = "gcPad-0-0"
    XCTAssertEqual(make(screen).focusableIDs, ["control-gcPad-0-0"])
  }

  func test_touchscreen_disablesCapture_withAHint() {
    let model = make(state(.gameCube, device: "iOS/0/Touchscreen", controls: gameCubeControls))
    XCTAssertEqual(model.item(id: "buttons-hint")?.title, "Touchscreen controls are laid out by the on-screen overlay.")
    XCTAssertEqual(model.item(id: "control-gcPad-0-0")?.isEnabled, false)
  }

  func test_noDevice_disablesCapture_withAHint() {
    let model = make(state(.gameCube, controls: gameCubeControls))
    XCTAssertEqual(model.item(id: "buttons-hint")?.title, "Choose a device to bind its buttons.")
    XCTAssertEqual(model.item(id: "control-gcPad-0-0")?.isEnabled, false)
  }

  func test_disconnectedPad_disablesCapture_withAHint() {
    let model = make(state(.gameCube, device: Self.xbox, controls: gameCubeControls))
    XCTAssertEqual(model.item(id: "buttons-hint")?.title, "Connect this controller to capture buttons.")
    XCTAssertEqual(model.item(id: "control-gcPad-0-0")?.isEnabled, false)
    XCTAssertEqual(model.item(id: "device")?.subtitle, "Xbox Wireless Controller (Disconnected)")
  }

  func test_dsuPort_captures_andIsNotDisconnected() {
    let model = make(state(.gameCube, device: Self.dsu, controls: gameCubeControls))
    XCTAssertNil(model.item(id: "buttons-hint"))
    XCTAssertEqual(model.item(id: "control-gcPad-0-0")?.isEnabled, true)
    XCTAssertEqual(model.item(id: "device")?.subtitle, "Pad C")
  }

  // MARK: Profile and Wii rows

  func test_profileName_customThenEdited() {
    var screen = boundGameCube
    XCTAssertEqual(make(screen).item(id: "profile-load")?.subtitle, "Custom")
    screen.profileName = "Physical Controller"
    screen.profileEdited = true
    XCTAssertEqual(make(screen).item(id: "profile-load")?.subtitle, "Physical Controller (edited)")
  }

  func test_saveAndReset_runTheirActions_resetNeedsADevice() {
    let recorder = Recorder()
    let model = make(boundGameCube, recorder)
    run(model.item(id: "profile-save"))
    run(model.item(id: "profile-reset"))
    XCTAssertEqual(recorder.calls, ["save-as", "reset"])
    XCTAssertEqual(make(state(.gameCube)).item(id: "profile-reset")?.isEnabled, false)
  }

  func test_extensionOptions_sayExtensionOnTVOS() {
    XCTAssertEqual(optionTitles(make(state(.wiiRemote)).item(id: "wii-extension")), ["None", "Nunchuk", "Classic"])
    XCTAssertEqual(
      optionTitles(make(state(.wiiRemote), platform: .tvos).item(id: "wii-extension")),
      ["Extension: None", "Extension: Nunchuk", "Extension: Classic"])
  }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/PlayerScreenModelBuilderTests"`
Expected: build failure, `cannot find 'PlayerScreenModelBuilder' in scope`.

- [ ] **Step 3: Write the builder**

`Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenModelBuilder.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Builds one player's screen (controller hub spec, "Player screen"):
/// - Device (a pushed list), then Profile.
/// - Wii Remote (Wii ports): Extension, Sideways.
/// - Buttons: capture rows under Face / D-Pad / Sticks / Triggers / System / Motion.
/// - Pointer & Motion: iOS, Wii ports bound to the touchscreen or a gyro pad.
/// - Advanced, collapsed: numeric settings and raw expressions.
///
/// Pure: state and actions in, `MenuModel` out, no bridge calls, like `ControllerHubModelBuilder`.
/// Rows that open something push (`.destination`); nothing here presents.
enum PlayerScreenModelBuilder {
  static func make(state: PlayerScreenState, actions: PlayerScreenActions, platform: PlatformKind) -> MenuModel {
    var sections = [deviceSection(state: state, actions: actions), profileSection(state: state, actions: actions)]
    if state.player.kind == .wiiRemote {
      sections.append(wiiSection(state: state, actions: actions, platform: platform))
    }
    sections += buttonSections(state: state, actions: actions)
    if showsPointerAndMotion(state: state, platform: platform) {
      sections.append(pointerSection(state: state, actions: actions))
    }
    sections += advancedSections(state: state, actions: actions)
    return lockedToTheArmedRow(MenuModel(sections: sections), armedControlID: state.armedControlID)
  }

  /// Wii ports, iOS only (tvOS has no touchscreen and no Pointer & Motion), and only where something
  /// drives the pointer: the device's motion or touch, or a pad's own gyro.
  static func showsPointerAndMotion(state: PlayerScreenState, platform: PlatformKind) -> Bool {
    platform == .ios && state.player.kind == .wiiRemote && (state.isTouchscreen || state.boundPad?.hasGyro == true)
  }

  /// "Physical Controller", "Physical Controller (edited)", or "Custom" when not known.
  static func profileDisplayName(_ state: PlayerScreenState) -> String {
    guard let name = state.profileName else { return L("Custom") }
    return state.profileEdited ? String(format: L("%@ (edited)"), name) : name
  }

  static func captureRowID(_ row: RemapControlRow) -> String { "control-\(row.id)" }

  // MARK: Device (decision 9: a pushed list, one pick = one assignment)

  /// What the Device row shows.
  static func deviceSummary(_ state: PlayerScreenState) -> String {
    switch state.deviceChoice {
    case .noDevice:
      return L("No Device")
    case .touchscreen:
      return L("Touchscreen")
    case .pad(let qualifier):
      if let pad = state.boundPad { return pad.name }
      let name = qualifierName(qualifier)
      // Only an MFi pad can be "Disconnected"; a DSU device is never in the pad list (decision 11).
      return state.isDisconnected ? String(format: L("%@ (Disconnected)"), name) : name
    }
  }

  /// The Device list: None, Touchscreen (iOS), each connected pad, and the bound device when it is
  /// none of those (a disconnected pad, a DSU device), so the list can mark it current.
  static func deviceOptions(state: PlayerScreenState, platform: PlatformKind) -> [DeviceOption] {
    var options = [DeviceOption(choice: .noDevice, title: L("None"))]
    if platform == .ios {
      options.append(DeviceOption(choice: .touchscreen, title: L("Touchscreen")))
    }
    options += state.pads.map { DeviceOption(choice: .pad($0.qualifier), title: $0.name) }
    if case .pad = state.deviceChoice, state.boundPad == nil {
      options.append(DeviceOption(choice: state.deviceChoice, title: deviceSummary(state)))
    }
    return options
  }

  /// "Xbox Wireless Controller" from `MFi/0/Xbox Wireless Controller`, as the hub shows it.
  private static func qualifierName(_ qualifier: String) -> String {
    qualifier.split(separator: "/", maxSplits: 2).last.map(String.init) ?? qualifier
  }

  private static func deviceSection(state: PlayerScreenState, actions: PlayerScreenActions) -> MenuSection {
    MenuSection(id: "device", items: [
      MenuItem(
        id: "device", title: L("Device"), subtitle: deviceSummary(state), icon: "gamecontroller",
        role: .destination(actions.deviceListDestination())),
    ])
  }

  // MARK: Profile

  private static func profileSection(state: PlayerScreenState, actions: PlayerScreenActions) -> MenuSection {
    MenuSection(id: "profile", header: L("Profile"), items: [
      MenuItem(
        id: "profile-load", title: L("Load Profile…"), subtitle: profileDisplayName(state), icon: "tray.and.arrow.down",
        role: .destination(actions.profileListDestination())),
      MenuItem(id: "profile-save", title: L("Save Profile As…"), icon: "square.and.arrow.down", role: .action(actions.saveProfileAs)),
      MenuItem(
        id: "profile-reset", title: L("Reset to Default Profile"), icon: "arrow.counterclockwise",
        role: .action(actions.resetProfile), isEnabled: state.deviceChoice != .noDevice),
    ])
  }

  // MARK: Wii Remote

  private static func wiiSection(state: PlayerScreenState, actions: PlayerScreenActions, platform: PlatformKind) -> MenuSection {
    let extensions = (0 ..< WiimoteSlotOptions.extensionCount).map { value -> (String, AnyHashable) in
      let name = WiimoteSlotOptions.extensionName(value)
      // tvOS shows only the option titles, so they say what they are.
      return (platform == .tvos ? String(format: L("Extension: %@"), name) : name, AnyHashable(value))
    }
    return MenuSection(id: "wii", header: L("Wii Remote"), items: [
      MenuItem(
        id: "wii-extension", title: L("Extension"), icon: "puzzlepiece.extension",
        role: .picker(options: extensions, selection: Binding(
          get: { AnyHashable(state.player.wiiExtension) },
          set: { if let value = $0.base as? Int { actions.setExtension(value) } }))),
      MenuItem(
        id: "wii-sideways", title: L("Sideways"), icon: "rotate.right",
        role: .toggle(Binding(get: { state.player.isSideways }, set: { actions.setSideways($0) }))),
    ])
  }

  // MARK: Buttons

  private static func buttonSections(state: PlayerScreenState, actions: PlayerScreenActions) -> [MenuSection] {
    var sections: [MenuSection] = []
    if let hint = captureHint(state) {
      // Enabled no-op: a tvOS List scrolls only by focus, and a disabled row takes none.
      sections.append(MenuSection(id: "buttons-hint", items: [MenuItem(id: "buttons-hint", title: hint, role: .action({}))]))
    }
    // Once per build, not per row.
    let family = DeviceFamily.from(qualifier: state.player.deviceQualifier)
    for (category, rows) in ControlCategory.grouped(state.controls) {
      sections.append(MenuSection(id: "buttons-\(category.id)", header: category.title, items: rows.map { row in
        let title = ControlCategory.title(for: row)
        let isArmed = state.armedControlID == row.id
        let isEnabled = state.canCapture && (!state.isCapturing || isArmed)
        return MenuItem(
          id: captureRowID(row), title: title,
          role: .custom(AnyView(CaptureRowView(
            title: title, binding: BindingDisplay.text(for: row.expression, family: family), isArmed: isArmed,
            isEnabled: isEnabled, onActivate: { actions.toggleCapture(row) }, onClear: { actions.clearBinding(row) }))),
          isEnabled: isEnabled,
          onCustomActivate: { actions.toggleCapture(row) })
      }))
    }
    return sections
  }

  /// Why capture is impossible, or nil when it is possible (decision 11).
  private static func captureHint(_ state: PlayerScreenState) -> String? {
    switch state.deviceChoice {
    case .noDevice: return L("Choose a device to bind its buttons.")
    case .touchscreen: return L("Touchscreen controls are laid out by the on-screen overlay.")
    case .pad: return state.isDisconnected ? L("Connect this controller to capture buttons.") : nil
    }
  }

  // MARK: Pointer & Motion

  private static func pointerSection(state: PlayerScreenState, actions: PlayerScreenActions) -> MenuSection {
    guard state.isTouchscreen else {
      // A pad's pointer comes from its own gyro through its profile; the only switch is the Wii
      // Remote's IMU pointer (decision 2).
      return MenuSection(id: "pointer", header: L("Pointer & Motion"), items: [
        MenuItem(
          id: "pointer-motion", title: L("Aim with Controller Motion"), subtitle: L("The controller's gyro moves the Wii pointer."),
          icon: "gyroscope",
          role: .toggle(Binding(get: { state.motionPointerEnabled }, set: { actions.setMotionPointer($0) }))),
      ])
    }
    let motion = state.pointerMotion
    let modes: [PointerMode] = [.touchFollow, .touchDrag, .gyro]
    var items = [
      MenuItem(
        id: "pointer-mode", title: L("Pointer"), icon: motion.pointerMode.systemImage,
        role: .picker(options: modes.map { ($0.title, AnyHashable($0)) }, selection: Binding(
          get: { AnyHashable(motion.pointerMode) },
          set: { if let mode = $0.base as? PointerMode { actions.setPointerMode(mode) } }))),
      MenuItem(id: "pointer-recenter", title: L("Recenter Pointer"), icon: "scope", role: .action(actions.recenterPointer)),
    ]
    if motion.pointerMode == .touchDrag, motion.usesProgrammaticOverlay {
      items.append(sensitivityItem(
        choices: PointerMotionState.dragGainChoices, current: motion.dragGain, set: actions.setDragGain))
    }
    if motion.pointerMode == .gyro {
      // Decision 4: a multiplier on the gyro pointer's constants. Decision 7: invert only here,
      // because only the gyro pointer reads the invert keys.
      items.append(sensitivityItem(
        choices: PointerMotionState.gyroSensitivityChoices, current: motion.gyroSensitivity, set: actions.setGyroSensitivity))
      items.append(MenuItem(
        id: "pointer-invert-x", title: L("Invert X"), icon: "arrow.left.and.right",
        role: .toggle(Binding(get: { motion.invertX }, set: { actions.setInvertX($0) }))))
      items.append(MenuItem(
        id: "pointer-invert-y", title: L("Invert Y"), icon: "arrow.up.and.down",
        role: .toggle(Binding(get: { motion.invertY }, set: { actions.setInvertY($0) }))))
    }
    items.append(MenuItem(
      id: "pointer-shake", title: L("Shake to Wiggle"), subtitle: L("Shaking the device shakes the Wii Remote."),
      icon: "iphone.radiowaves.left.and.right",
      role: .toggle(Binding(get: { motion.shakeToWiggle }, set: { actions.setShakeToWiggle($0) }))))
    return MenuSection(id: "pointer", header: L("Pointer & Motion"), items: items)
  }

  /// The mode's Sensitivity row: a stepped multiplier, one compact row on tvOS.
  private static func sensitivityItem(choices: [Double], current: Double, set: @escaping (Double) -> Void) -> MenuItem {
    MenuItem(
      id: "pointer-sensitivity", title: L("Sensitivity"), icon: "dial.medium",
      role: .picker(
        options: choices.map { ("×" + NumericSettingSteps.label($0, suffix: ""), AnyHashable($0)) },
        selection: Binding(
          get: { AnyHashable(PointerMotionState.snapped(current, to: choices)) },
          set: { if let value = $0.base as? Double { set(value) } })),
      isCompactOnTV: true)
  }

  // MARK: Advanced

  private static func advancedSections(state: PlayerScreenState, actions: PlayerScreenActions) -> [MenuSection] {
    var sections = [MenuSection(id: "advanced", header: L("Advanced"), items: [
      MenuItem(
        id: "advanced-toggle", title: state.showsAdvanced ? L("Hide Advanced") : L("Show Advanced"),
        icon: state.showsAdvanced ? "chevron.up" : "chevron.down", role: .action(actions.toggleAdvanced)),
    ])]
    guard state.showsAdvanced else { return sections }
    for group in state.advanced where !group.settings.isEmpty {
      sections.append(MenuSection(
        id: "advanced-\(group.owner)-\(group.groupId)", header: group.title,
        items: group.settings.map { settingItem($0, actions: actions) }))
    }
    if !state.controls.isEmpty {
      sections.append(MenuSection(id: "advanced-expressions", header: L("Raw Bindings"), items: state.controls.map { row in
        MenuItem(
          id: "expression-\(row.id)", title: ControlCategory.title(for: row), subtitle: row.expression,
          role: .destination(actions.expressionDestination(row)))
      }))
    }
    return sections
  }

  private static func settingItem(_ setting: NumericSettingState, actions: PlayerScreenActions) -> MenuItem {
    if setting.isExpression {
      // Enabled no-op so tvOS focus can reach it; editing an expression-driven value here would
      // silently replace the expression.
      return MenuItem(id: setting.id, title: setting.name, subtitle: L("Set by an expression"), role: .action({}))
    }
    if setting.isToggle {
      return MenuItem(
        id: setting.id, title: setting.name,
        role: .toggle(Binding(get: { setting.value != 0 }, set: { actions.setNumericSetting(setting, $0 ? 1 : 0) })))
    }
    let values = NumericSettingSteps.values(for: setting)
    let selected = NumericSettingSteps.nearest(to: setting.value, in: values)
    return MenuItem(
      id: setting.id, title: setting.name,
      role: .picker(
        options: values.map { (NumericSettingSteps.label($0, suffix: setting.suffix), AnyHashable($0)) },
        selection: Binding(
          get: { AnyHashable(selected) },
          set: { if let value = $0.base as? Double { actions.setNumericSetting(setting, value) } })),
      isCompactOnTV: true)
  }

  // MARK: Capture lock

  /// While a capture is armed only the armed row responds. On tvOS a pad's d-pad drives native
  /// focus, which then has nowhere to go; touch cannot change the device under a running capture.
  private static func lockedToTheArmedRow(_ model: MenuModel, armedControlID: String?) -> MenuModel {
    guard let armedControlID else { return model }
    let armedItemID = "control-\(armedControlID)"
    var locked = model
    for section in locked.sections.indices {
      for item in locked.sections[section].items.indices where locked.sections[section].items[item].id != armedItemID {
        locked.sections[section].items[item].isEnabled = false
      }
    }
    return locked
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass, then the gates**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/PlayerScreenModelBuilderTests"`
Expected: `Executed 28 tests, with 0 failures`.
Then: `make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` and `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice.

- [ ] **Step 5: Commit**

```bash
git add Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenModelBuilder.swift \
  Source/iOS/App/DolphiniOSTests/PlayerScreenModelBuilderTests.swift
git commit -m "feat(controllers): pure player screen model builder"
```

---

### Task 10: Pushed leaves — Device, Load Profile and the raw-expression editor

**Files:**
- Create: `Source/iOS/App/Common/Swift/Controllers/Player/DeviceListView.swift`
- Create: `Source/iOS/App/Common/Swift/Controllers/Player/ProfileListView.swift`
- Create: `Source/iOS/App/Common/Swift/Controllers/Player/ExpressionEditorView.swift`
- Test: `Source/iOS/App/DolphiniOSTests/PlayerScreenLeavesTests.swift`

**Interfaces:**
- Consumes: Task 5's `ExpressionCheck`; Task 8's `DeviceOption` and `PlayerDeviceChoice`; `MenuScreen`, `MenuModel`.
- Produces:
  - Device list:
    - `enum DeviceListModelBuilder`, with `static func make(options: [DeviceOption], current: PlayerDeviceChoice, onPick: @escaping (PlayerDeviceChoice) -> Void) -> MenuModel` and `static func itemID(for: PlayerDeviceChoice) -> String`. Item ids: `device-none`, `device-touchscreen`, `device-<qualifier>`.
    - `struct DeviceListView: View`, `init(options: @escaping () -> [DeviceOption], current: @escaping () -> PlayerDeviceChoice, refresh: @escaping () -> Void, onPick: @escaping (PlayerDeviceChoice) -> Void)`. A pick runs `onPick` once, then pops. While on top it calls `refresh` on appear and on `.GCControllerDidConnect`, `.GCControllerDidDisconnect`, `.TVControllerDevicesChanged` and `ControllerManager.assignmentsChanged`, because the player screen stops observing when the list is pushed.
  - Load Profile:
    - `enum ProfileListModelBuilder { static func make(names: [String], current: String?, onPick: @escaping (String) -> Void) -> MenuModel }`. Item ids: `profile-<name>`, or `no-profiles` when there are none.
    - `struct ProfileListView: View`, `init(current: String?, loadNames: @escaping () -> [String], onPick: @escaping (String) -> Void)`.
  - Raw-expression editor:
    - `enum ExpressionEditorModelBuilder { static func make(text: Binding<String>, original: String, check: ExpressionCheck, onSave: @escaping () -> Void, onRevert: @escaping () -> Void, onClear: @escaping () -> Void) -> MenuModel }`. Item ids: `expression-text`, `expression-check`, `expression-save`, `expression-revert`, `expression-clear`.
    - `struct ExpressionEditorView: View`, `init(title: String, original: String, check: @escaping (String) -> ExpressionCheck, save: @escaping (String) -> Bool)`.

All three lists show real content on their first render. Neither flashes empty:
- The device list reads the view model's observable snapshot on every render. It keeps that snapshot current itself through `refresh`, because the player screen stops observing while covered. Only this leaf shows live device state, so only it observes.
- The profile list reads its names during its first `body`, then caches them on appear. Reading changes no state, so it is safe in `body`.
- The editor starts from the text it was given.

- [ ] **Step 1: Write the failing tests**

`Source/iOS/App/DolphiniOSTests/PlayerScreenLeavesTests.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

/// The three screens the player screen pushes: Device, Load Profile and the raw-expression editor.
/// Each is a `MenuScreen` over a pure builder, so Back works from a pad (B) and the Siri Remote
/// (Menu), and one pick is one action.
final class PlayerScreenLeavesTests: XCTestCase {

  private static let xbox = "MFi/0/Xbox Wireless Controller"

  // MARK: Device (decision 9)

  private var deviceOptions: [DeviceOption] {
    [
      DeviceOption(choice: .noDevice, title: "None"),
      DeviceOption(choice: .touchscreen, title: "Touchscreen"),
      DeviceOption(choice: .pad(Self.xbox), title: "Xbox Wireless Controller"),
    ]
  }

  func test_devices_markTheCurrentOne() {
    let model = DeviceListModelBuilder.make(options: deviceOptions, current: .touchscreen, onPick: { _ in })
    XCTAssertEqual(model.allItems.map(\.id), ["device-none", "device-touchscreen", "device-\(Self.xbox)"])
    XCTAssertEqual(model.item(id: "device-touchscreen")?.badge, "Current")
    XCTAssertNil(model.item(id: "device-none")?.badge)
  }

  /// One pick, one assignment: the row's action reports exactly the choice it shows.
  func test_devices_pickReportsThatChoiceOnce() {
    var picks: [PlayerDeviceChoice] = []
    let model = DeviceListModelBuilder.make(options: deviceOptions, current: .noDevice, onPick: { picks.append($0) })
    guard let item = model.item(id: "device-\(Self.xbox)"), case .action(let action) = item.role else {
      return XCTFail("not an action")
    }
    action()
    XCTAssertEqual(picks, [.pad(Self.xbox)])
  }

  /// Rows, not a picker: a pad's A or d-pad never steps through devices.
  func test_devices_areActionRows() {
    let model = DeviceListModelBuilder.make(options: deviceOptions, current: .noDevice, onPick: { _ in })
    for item in model.allItems {
      guard case .action = item.role else { return XCTFail("\(item.id) is not a plain action row") }
    }
  }

  // MARK: Load Profile

  func test_profiles_sortedCaseInsensitively_currentMarked() {
    let model = ProfileListModelBuilder.make(names: ["touchscreen", "Physical Controller", "DSU"], current: "DSU", onPick: { _ in })
    XCTAssertEqual(model.allItems.map(\.id), ["profile-DSU", "profile-Physical Controller", "profile-touchscreen"])
    XCTAssertEqual(model.item(id: "profile-DSU")?.badge, "Current")
    XCTAssertNil(model.item(id: "profile-touchscreen")?.badge)
  }

  func test_profiles_pickRunsOnPickWithThatName() {
    var picked: String?
    let model = ProfileListModelBuilder.make(names: ["DSU"], current: nil, onPick: { picked = $0 })
    guard let item = model.item(id: "profile-DSU"), case .action(let action) = item.role else { return XCTFail("not an action") }
    action()
    XCTAssertEqual(picked, "DSU")
  }

  /// An enabled no-op row, so tvOS focus has somewhere to land and Menu still pops.
  func test_profiles_noneSaysSo() {
    let model = ProfileListModelBuilder.make(names: [], current: nil, onPick: { _ in })
    XCTAssertEqual(model.focusableIDs, ["no-profiles"])
  }

  // MARK: Expression editor

  private let valid = ExpressionCheck(status: .valid, message: "The expression is valid.")
  private let invalid = ExpressionCheck(status: .invalid, message: "Not saved: Expected closing paren.")

  private func editor(text: String, original: String, check: ExpressionCheck) -> MenuModel {
    ExpressionEditorModelBuilder.make(
      text: .constant(text), original: original, check: check, onSave: {}, onRevert: {}, onClear: {})
  }

  /// An untouched expression is never re-validated or rewritten: a legacy bareword can parse as a
  /// syntax error yet still work (ExpressionParser.cpp:1119-1124).
  func test_untouched_cannotBeSavedOrReverted_andIsNotJudged() {
    let model = editor(text: "`Button A`", original: "`Button A`", check: invalid)
    XCTAssertEqual(model.item(id: "expression-save")?.isEnabled, false)
    XCTAssertEqual(model.item(id: "expression-revert")?.isEnabled, false)
    XCTAssertEqual(model.item(id: "expression-check")?.title, "Edit the expression, then Save.")
  }

  func test_editedAndValid_canBeSaved() {
    let model = editor(text: "`Button B`", original: "`Button A`", check: valid)
    XCTAssertEqual(model.item(id: "expression-save")?.isEnabled, true)
    XCTAssertEqual(model.item(id: "expression-revert")?.isEnabled, true)
    XCTAssertEqual(model.item(id: "expression-check")?.title, "The expression is valid.")
  }

  /// Spec edge case: "Show the parser's error inline and do not save."
  func test_editedAndInvalid_showsTheErrorAndCannotBeSaved() {
    let model = editor(text: "(`Button B`", original: "`Button A`", check: invalid)
    XCTAssertEqual(model.item(id: "expression-save")?.isEnabled, false)
    XCTAssertEqual(model.item(id: "expression-check")?.title, "Not saved: Expected closing paren.")
  }

  /// Clear is the pad's way to unbind (a pad cannot long-press a capture row).
  func test_clear_isOffWhenTheTextIsAlreadyEmpty() {
    XCTAssertEqual(editor(text: "", original: "`Button A`", check: valid).item(id: "expression-clear")?.isEnabled, false)
    XCTAssertEqual(editor(text: "`Button A`", original: "`Button A`", check: valid).item(id: "expression-clear")?.isEnabled, true)
  }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/PlayerScreenLeavesTests"`
Expected: build failure, `cannot find 'DeviceListModelBuilder' in scope`.

- [ ] **Step 3: Write the Device list**

`Source/iOS/App/Common/Swift/Controllers/Player/DeviceListView.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The player screen's Device list (decision 9), pushed on both platforms. One pick is one
/// assignment, then the list pops. A stepped picker would assign on every A or d-pad press, and one
/// such step through Touchscreen reloads the Touchscreen profile over the port's mapping.
struct DeviceListView: View {
  /// Read on every render, from the view model's observable snapshot, so the first render is never
  /// empty and every `refresh` shows at once.
  let options: () -> [DeviceOption]
  let current: () -> PlayerDeviceChoice
  /// Re-reads the snapshot (`PlayerScreenViewModel.reload()`). Needed because pushing this list
  /// stops the player screen's own observers (its `onDisappear`), so this list watches the device
  /// notices itself while it is on top.
  let refresh: () -> Void
  let onPick: (PlayerDeviceChoice) -> Void

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    MenuScreen(
      model: DeviceListModelBuilder.make(options: options(), current: current(), onPick: { choice in
        onPick(choice)
        dismiss()
      }),
      style: .list,
      onBack: { dismiss() })
      .navigationTitle(L("Device"))
      .onAppear { refresh() }
      // The same notices `PlayerScreenViewModel.start()` observes; all declared names.
      .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in refresh() }
      .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in refresh() }
      .onReceive(NotificationCenter.default.publisher(for: .TVControllerDevicesChanged)) { _ in refresh() }
      .onReceive(NotificationCenter.default.publisher(for: ControllerManager.assignmentsChanged)) { _ in refresh() }
  }
}

/// Pure: one action row per option, the current one marked. Plain rows, not a picker, so a pad's A
/// or d-pad never steps through devices.
enum DeviceListModelBuilder {
  static func itemID(for choice: PlayerDeviceChoice) -> String {
    switch choice {
    case .noDevice: return "device-none"
    case .touchscreen: return "device-touchscreen"
    case .pad(let qualifier): return "device-\(qualifier)"
    }
  }

  static func make(options: [DeviceOption], current: PlayerDeviceChoice, onPick: @escaping (PlayerDeviceChoice) -> Void) -> MenuModel {
    MenuModel(sections: [
      MenuSection(id: "devices", header: L("Device"), items: options.map { option in
        MenuItem(
          id: itemID(for: option.choice), title: option.title, icon: icon(for: option.choice),
          role: .action { onPick(option.choice) }, badge: option.choice == current ? L("Current") : nil)
      }),
    ])
  }

  private static func icon(for choice: PlayerDeviceChoice) -> String {
    switch choice {
    case .noDevice: return "xmark.circle"
    case .touchscreen: return "hand.tap"
    case .pad: return "gamecontroller"
    }
  }
}
```

- [ ] **Step 4: Write Load Profile**

`Source/iOS/App/Common/Swift/Controllers/Player/ProfileListView.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Load Profile…, pushed from the player screen (everything below the hub is a push). Picking a
/// profile loads it and pops back. Its own host, not a `.navigation` row: a `.navigation` child is
/// built once at push time and cannot pop itself after a pick.
struct ProfileListView: View {
  let current: String?
  /// Read during the first `body`, then cached on appear, never in `init`: the parent rebuilds this
  /// view on every render, and the list must not flash "No profiles" before its first read.
  let loadNames: () -> [String]
  let onPick: (String) -> Void

  @State private var names: [String]?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    MenuScreen(
      model: ProfileListModelBuilder.make(names: names ?? loadNames(), current: current, onPick: { name in
        onPick(name)
        dismiss()
      }),
      style: .list,
      onBack: { dismiss() })
      .navigationTitle(L("Load Profile"))
      .onAppear { if names == nil { names = loadNames() } }
  }
}

/// Pure: the profile names (user and bundled, as `TVControllerMappingBridge.profiles(forGCPort:)`
/// lists them) in case-insensitive order, the current one marked.
enum ProfileListModelBuilder {
  static func make(names: [String], current: String?, onPick: @escaping (String) -> Void) -> MenuModel {
    let sorted = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    guard !sorted.isEmpty else {
      // Enabled no-op: tvOS focus needs a row to land on.
      return MenuModel(sections: [
        MenuSection(id: "profiles", items: [MenuItem(id: "no-profiles", title: L("No profiles"), role: .action({}))]),
      ])
    }
    return MenuModel(sections: [
      MenuSection(id: "profiles", header: L("Profiles"), items: sorted.map { name in
        MenuItem(
          id: "profile-\(name)", title: name, icon: "doc.text",
          role: .action { onPick(name) }, badge: name == current ? L("Current") : nil)
      }),
    ])
  }
}
```

- [ ] **Step 5: Write the expression editor**

`Source/iOS/App/Common/Swift/Controllers/Player/ExpressionEditorView.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Advanced → Raw Bindings → one control: its Dolphin expression as editable text, pushed from the
/// player screen. The core's parser checks the text as it is typed. Text that does not parse shows
/// the parser's message and cannot be saved (controller hub spec, Edge cases).
///
/// Typing needs touch, a keyboard or the tvOS keyboard (select the field on tvOS). A pad can still
/// reach Save, Revert and Clear (the pad's way to unbind), and Back pops.
struct ExpressionEditorView: View {
  let title: String
  /// `RemapControlRow.editableExpression`: never the bridges' "—".
  let original: String
  let check: (String) -> ExpressionCheck
  /// Writes the text; false when it was refused.
  let save: (String) -> Bool

  @State private var text: String
  @Environment(\.dismiss) private var dismiss

  init(title: String, original: String, check: @escaping (String) -> ExpressionCheck, save: @escaping (String) -> Bool) {
    self.title = title
    self.original = original
    self.check = check
    self.save = save
    _text = State(initialValue: original)
  }

  var body: some View {
    MenuScreen(
      model: ExpressionEditorModelBuilder.make(
        text: $text, original: original, check: check(text),
        onSave: { if save(text) { dismiss() } },
        onRevert: { text = original },
        onClear: { text = "" }),
      style: .list,
      onBack: { dismiss() })
      .navigationTitle(title)
  }
}

/// Pure: the editor's rows for the current text and its check.
enum ExpressionEditorModelBuilder {
  static func make(
    text: Binding<String>, original: String, check: ExpressionCheck,
    onSave: @escaping () -> Void, onRevert: @escaping () -> Void, onClear: @escaping () -> Void
  ) -> MenuModel {
    // Only an edit is judged: a legacy expression that reports a syntax error can still work through
    // the parser's bareword fallback, and it must never be rejected or rewritten untouched.
    let isEdited = text.wrappedValue != original
    return MenuModel(sections: [
      MenuSection(id: "expression", header: L("Expression"), items: [
        MenuItem(id: "expression-text", title: L("Expression"), role: .custom(AnyView(ExpressionTextField(text: text)))),
      ]),
      MenuSection(id: "check", items: [
        // Enabled no-op so tvOS focus can reach it.
        MenuItem(
          id: "expression-check", title: isEdited ? check.message : L("Edit the expression, then Save."),
          icon: !isEdited || check.canSave ? "checkmark.circle" : "exclamationmark.triangle",
          tint: !isEdited || check.canSave ? nil : .orange, role: .action({})),
      ]),
      MenuSection(id: "actions", items: [
        MenuItem(
          id: "expression-save", title: L("Save"), icon: "square.and.arrow.down", role: .action(onSave),
          isEnabled: isEdited && check.canSave),
        MenuItem(
          id: "expression-revert", title: L("Revert"), icon: "arrow.uturn.backward", role: .action(onRevert),
          isEnabled: isEdited),
        MenuItem(
          id: "expression-clear", title: L("Clear"), icon: "xmark.circle", role: .destructive(onClear),
          isEnabled: !text.wrappedValue.isEmpty),
      ]),
    ])
  }
}

/// The text row: one `TextField`, so on tvOS it is one focus target that opens the keyboard.
private struct ExpressionTextField: View {
  @Binding var text: String

  var body: some View {
    TextField(L("Expression"), text: $text)
      .font(.body.monospaced())
      .autocorrectionDisabled()
      .textInputAutocapitalization(.never)
  }
}
```

- [ ] **Step 6: Run the tests to verify they pass, then the gates**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/PlayerScreenLeavesTests"`
Expected: `Executed 10 tests, with 0 failures`.
Then: `make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` and `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice.

- [ ] **Step 7: Commit**

```bash
git add Source/iOS/App/Common/Swift/Controllers/Player/DeviceListView.swift \
  Source/iOS/App/Common/Swift/Controllers/Player/ProfileListView.swift \
  Source/iOS/App/Common/Swift/Controllers/Player/ExpressionEditorView.swift \
  Source/iOS/App/DolphiniOSTests/PlayerScreenLeavesTests.swift
git commit -m "feat(controllers): device list, profile list, expression editor"
```

---

### Task 11: The `PlayerScreenIO` seam and `LivePlayerScreenIO`

**Files:**
- Create: `Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenIO.swift`
- Test: `Source/iOS/App/DolphiniOSTests/PlayerScreenIOTests.swift`

**Interfaces:**
- Consumes:
  - Task 5: `DOLControllerSettingsBridge`, `ControlGroupOwner`, `ExpressionCheck`.
  - Task 6: the `MotionSettings` setters and `gyroPointerSensitivity()`, `.DOLMotionSettingsChanged`.
  - Task 7: `NumericSettingState`, `AdvancedSettingGroups.imuPointGroup`.
  - Task 8: `PlayerDeviceChoice`, `PointerMotionState`.
  - Existing: `RemapControlRow`, `RemapExpression`, `WiimoteSlotOptions`, `ControllerManager`, `TVControllerMappingBridge`, `BridgeControllerConfigWriter`, `PointerModeController`, `TCDeviceMotion`.
- Produces:
  - `@MainActor protocol PlayerScreenIO`, with 25 members:
    - Reads (10): `controlRows(owner:group:port:)`, `numericSettings(owner:group:port:)`, `profiles(for:)`, `defaultProfileName(forQualifier:)`, `hasAnyBinding(_:)`, `isMotionPointerEnabled(wiimote:)`, `pointerMotion()`, `inputNames(forQualifier:)`, `inputStates(forQualifier:)`, `check(_:)`.
    - Writes (15): `setDevice(_:slot:)`, `loadProfile(_:slot:) -> Bool`, `saveProfile(_:slot:) -> Bool`, `setExtension(_:wiimote:)`, `setSideways(_:wiimote:)`, `setExpression(_:for:port:)`, `setNumericSetting(_:value:port:)`, `setMotionPointerEnabled(_:wiimote:)`, `setPointerMode(_:)`, `recenterPointer()`, `setInvertX(_:)`, `setInvertY(_:)`, `setShakeToWiggle(_:)`, `setDragGain(_:)`, `setGyroSensitivity(_:)`.
  - `struct LivePlayerScreenIO: PlayerScreenIO`, with a `nonisolated init()`.
  - `extension RemapGroupOwner { var controlGroupOwner: ControlGroupOwner }`.

This task stands alone: nothing calls the seam until Task 12. Its tests pin the owner mapping and that the live check runs the core's parser. The bridge-backed calls are exercised on a device (Task 16).

- [ ] **Step 1: Write the failing tests**

`Source/iOS/App/DolphiniOSTests/PlayerScreenIOTests.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// The live seam's pure parts: the owner mapping the bridge calls rely on, and that `check` runs
/// the core's parser (the app-side bridge, no core change).
final class PlayerScreenIOTests: XCTestCase {

  func test_ownerMapping() {
    XCTAssertEqual(RemapGroupOwner.gcPad.controlGroupOwner, .gcPad)
    XCTAssertEqual(RemapGroupOwner.wiimote.controlGroupOwner, .wiimote)
    XCTAssertEqual(RemapGroupOwner.nunchuk.controlGroupOwner, .nunchuk)
    XCTAssertEqual(RemapGroupOwner.classic.controlGroupOwner, .classic)
  }

  @MainActor
  func test_liveCheck_usesTheCoresParser() {
    let io = LivePlayerScreenIO()
    XCTAssertTrue(io.check("`Button A`").canSave)
    XCTAssertTrue(io.check("").canSave, "blank unbinds")
    XCTAssertFalse(io.check("(`Button A`").canSave)
  }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/PlayerScreenIOTests"`
Expected: build failure, `cannot find 'LivePlayerScreenIO' in scope`.

- [ ] **Step 3: Write the seam**

`Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenIO.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import GameController
import SwiftUI

/// Everything the player screen reads and writes beyond `ControllerHubReading`, behind one seam, so
/// `PlayerScreenViewModel` is testable without the core, the bridges or real pads. Ports are 1-based.
@MainActor
protocol PlayerScreenIO {
  // Reads
  func controlRows(owner: RemapGroupOwner, group: Int, port: Int) -> [RemapControlRow]
  func numericSettings(owner: RemapGroupOwner, group: Int, port: Int) -> [NumericSettingState]
  func profiles(for slot: PlayerSlot) -> [String]
  /// The profile a device gets when first bound ("Physical Controller", "Touchscreen", "DSU").
  func defaultProfileName(forQualifier qualifier: String) -> String?
  /// The port already has a mapping, so binding a device keeps it (`ControllerAssignmentService`).
  func hasAnyBinding(_ slot: PlayerSlot) -> Bool
  func isMotionPointerEnabled(wiimote: Int) -> Bool
  func pointerMotion() -> PointerMotionState
  func inputNames(forQualifier qualifier: String) -> [String]
  func inputStates(forQualifier qualifier: String) -> [Float]
  func check(_ expression: String) -> ExpressionCheck

  // Writes
  func setDevice(_ choice: PlayerDeviceChoice, slot: PlayerSlot)
  func loadProfile(_ name: String, slot: PlayerSlot) -> Bool
  func saveProfile(_ name: String, slot: PlayerSlot) -> Bool
  func setExtension(_ value: Int, wiimote: Int)
  func setSideways(_ enabled: Bool, wiimote: Int)
  func setExpression(_ expression: String, for row: RemapControlRow, port: Int)
  func setNumericSetting(_ setting: NumericSettingState, value: Double, port: Int)
  func setMotionPointerEnabled(_ enabled: Bool, wiimote: Int)
  func setPointerMode(_ mode: PointerMode)
  func recenterPointer()
  func setInvertX(_ enabled: Bool)
  func setInvertY(_ enabled: Bool)
  func setShakeToWiggle(_ enabled: Bool)
  func setDragGain(_ gain: Double)
  func setGyroSensitivity(_ gain: Double)
}

extension RemapGroupOwner {
  /// The bridge's spelling of the same owner.
  var controlGroupOwner: ControlGroupOwner {
    switch self {
    case .gcPad: return .gcPad
    case .wiimote: return .wiimote
    case .nunchuk: return .nunchuk
    case .classic: return .classic
    }
  }
}

/// The live seam. Together with `LiveControllerHubReader`, the only player-screen code that touches
/// `ControllerManager`, `TVControllerMappingBridge`, `DOLControllerSettingsBridge`,
/// `PointerModeController`, `MotionSettings`, `TCDeviceMotion` and `GCController`.
struct LivePlayerScreenIO: PlayerScreenIO {
  /// Explicit and `nonisolated`, as `LiveControllerHubReader.init` is, so it can be a default
  /// argument of the main-actor view model's `init`.
  nonisolated init() {} // swiftlint:disable:this unneeded_synthesized_initializer

  // MARK: Reads

  func controlRows(owner: RemapGroupOwner, group: Int, port: Int) -> [RemapControlRow] {
    let names: [String]
    let expressions: [String]
    switch owner {
    case .gcPad:
      names = TVControllerMappingBridge.padControlNames(forGroup: port, group: group) as [String]
      expressions = TVControllerMappingBridge.padControlExpressions(forGroup: port, group: group) as [String]
    case .wiimote:
      names = TVControllerMappingBridge.wiimoteControlNames(forGroup: port, group: group) as [String]
      expressions = TVControllerMappingBridge.wiimoteControlExpressions(forGroup: port, group: group) as [String]
    case .nunchuk:
      names = TVControllerMappingBridge.wiimoteExtensionControlNames(forIndex: port, kind: .nunchuk, group: group) as [String]
      expressions = TVControllerMappingBridge.wiimoteExtensionControlExpressions(forIndex: port, kind: .nunchuk, group: group) as [String]
    case .classic:
      names = TVControllerMappingBridge.wiimoteExtensionControlNames(forIndex: port, kind: .classic, group: group) as [String]
      expressions = TVControllerMappingBridge.wiimoteExtensionControlExpressions(forIndex: port, kind: .classic, group: group) as [String]
    }
    return names.enumerated().map { index, name in
      RemapControlRow(
        owner: owner, groupId: group, index: index, name: name,
        expression: index < expressions.count ? expressions[index] : RemapExpression.unboundDisplay)
    }
  }

  func numericSettings(owner: RemapGroupOwner, group: Int, port: Int) -> [NumericSettingState] {
    DOLControllerSettingsBridge.numericSettings(owner: owner.controlGroupOwner, port: port, group: group).map { info in
      NumericSettingState(
        owner: owner, groupId: group, index: info.index, name: info.name, suffix: info.suffix,
        isToggle: info.type == .bool, isInteger: info.type == .int, value: info.value, minimum: info.minimum,
        maximum: info.maximum, defaultValue: info.defaultValue, isExpression: info.isExpression)
    }
  }

  func profiles(for slot: PlayerSlot) -> [String] {
    slot.kind == .gameCube
      ? TVControllerMappingBridge.profiles(forGCPort: slot.port) as [String]
      : TVControllerMappingBridge.profiles(forWiimote: slot.port) as [String]
  }

  func defaultProfileName(forQualifier qualifier: String) -> String? {
    BridgeControllerConfigWriter().defaultProfileName(forQualifier: qualifier)
  }

  func hasAnyBinding(_ slot: PlayerSlot) -> Bool {
    slot.kind == .gameCube
      ? TVControllerMappingBridge.padHasAnyBinding(forGCPort: slot.port)
      : TVControllerMappingBridge.wiimoteHasAnyBinding(forWiimote: slot.port)
  }

  func isMotionPointerEnabled(wiimote: Int) -> Bool {
    DOLControllerSettingsBridge.isGroupEnabled(owner: .wiimote, port: wiimote, group: AdvancedSettingGroups.imuPointGroup)
  }

  func pointerMotion() -> PointerMotionState {
    PointerMotionState(
      pointerMode: PointerModeController.shared.mode,
      invertX: MotionSettings.invertRoll(),
      invertY: MotionSettings.invertPitch(),
      shakeToWiggle: MotionSettings.enhancedShakeDetection(),
      dragGain: PointerMotionState.snapped(MotionSettings.irPointerGain(), to: PointerMotionState.dragGainChoices),
      gyroSensitivity: PointerMotionState.snapped(
        MotionSettings.gyroPointerSensitivity(), to: PointerMotionState.gyroSensitivityChoices),
      usesProgrammaticOverlay: UserDefaults.standard.bool(forKey: PointerMotionState.programmaticOverlayKey))
  }

  func inputNames(forQualifier qualifier: String) -> [String] {
    TVControllerMappingBridge.inputs(forQualifiedDevice: qualifier) as [String]
  }

  func inputStates(forQualifier qualifier: String) -> [Float] {
    TVControllerMappingBridge.inputStates(forQualifiedDevice: qualifier).map { $0.floatValue }
  }

  func check(_ expression: String) -> ExpressionCheck {
    let result = DOLControllerSettingsBridge.parse(expression: expression)
    return ExpressionCheck(parseStatus: result.status, parserMessage: result.message)
  }

  // MARK: Writes

  /// Through `ControllerManager`'s explicit-choice wrappers, each of which ends in
  /// `reconcile(autoAssign: false)` (ControllerManager.swift:484-542): changing this port never
  /// re-assigns the others.
  func setDevice(_ choice: PlayerDeviceChoice, slot: PlayerSlot) {
    let manager = ControllerManager.shared
    switch choice {
    case .noDevice:
      if slot.kind == .gameCube {
        manager.clearDefaultDevice(forGCPort: slot.port)
      } else {
        manager.clearDefaultDevice(forWiimote: slot.port)
      }
    case .touchscreen:
      if slot.kind == .gameCube {
        manager.assignTouchscreen(toGCPort: slot.port)
      } else {
        manager.assignTouchscreen(toWiimote: slot.port)
      }
    case .pad(let qualifier):
      // Only a connected GCController can be picked; the list shows a DSU or disconnected device
      // only as the current one, and picking the current device is a no-op upstream.
      guard let controller = GCController.controllers().first(where: {
        (TVControllerMappingBridge.qualifiedName(for: $0) as String) == qualifier
      }) else { return }
      if slot.kind == .gameCube {
        manager.assign(controller, toGCPort: slot.port)
      } else {
        manager.assign(controller, toWiimote: slot.port)
      }
    }
  }

  func loadProfile(_ name: String, slot: PlayerSlot) -> Bool {
    let loaded = slot.kind == .gameCube
      ? TVControllerMappingBridge.loadProfile(name, forGCPort: slot.port, restoreDevice: true)
      : TVControllerMappingBridge.loadProfile(name, forWiimote: slot.port, restoreDevice: true)
    // autoAssign: false — loading a profile for THIS port must not re-decide every other port's
    // device (the "profiles loading weird" bug, RemapPlayerView.swift:586-591).
    ControllerManager.shared.reconcile(autoAssign: false)
    return loaded
  }

  func saveProfile(_ name: String, slot: PlayerSlot) -> Bool {
    slot.kind == .gameCube
      ? TVControllerMappingBridge.saveProfile(name, forGCPort: slot.port)
      : TVControllerMappingBridge.saveProfile(name, forWiimote: slot.port)
  }

  /// `WiimoteSlotOptions` already ends in `reconcile(autoAssign: false)`.
  func setExtension(_ value: Int, wiimote: Int) { WiimoteSlotOptions.setExtension(value, forWiimote: wiimote) }
  func setSideways(_ enabled: Bool, wiimote: Int) { WiimoteSlotOptions.setSideways(enabled, forWiimote: wiimote) }

  func setExpression(_ expression: String, for row: RemapControlRow, port: Int) {
    switch row.owner {
    case .gcPad:
      TVControllerMappingBridge.setPadControlExpressionForPort(port, group: row.groupId, index: row.index, expression: expression)
    case .wiimote:
      TVControllerMappingBridge.setWiimoteControlExpressionFor(port, group: row.groupId, index: row.index, expression: expression)
    case .nunchuk:
      TVControllerMappingBridge.setWiimoteExtensionControlExpressionFor(
        port, kind: .nunchuk, group: row.groupId, index: row.index, expression: expression)
    case .classic:
      TVControllerMappingBridge.setWiimoteExtensionControlExpressionFor(
        port, kind: .classic, group: row.groupId, index: row.index, expression: expression)
    }
  }

  func setNumericSetting(_ setting: NumericSettingState, value: Double, port: Int) {
    DOLControllerSettingsBridge.setNumericSetting(
      value, index: setting.index, owner: setting.owner.controlGroupOwner, port: port, group: setting.groupId)
  }

  func setMotionPointerEnabled(_ enabled: Bool, wiimote: Int) {
    DOLControllerSettingsBridge.setGroupEnabled(enabled, owner: .wiimote, port: wiimote, group: AdvancedSettingGroups.imuPointGroup)
  }

  func setPointerMode(_ mode: PointerMode) { PointerModeController.shared.set(mode) }

  func recenterPointer() {
    #if os(iOS)
    TCDeviceMotion.requestPointerRecenter()
    #endif
  }

  /// Read on every motion sample (TCDeviceMotion.handleIRCursorMapping): no restart needed.
  func setInvertX(_ enabled: Bool) { MotionSettings.setInvertRoll(enabled) }
  func setInvertY(_ enabled: Bool) { MotionSettings.setInvertPitch(enabled) }

  /// The emulation screen decides from this whether the motion system runs at all, at boot and on
  /// `.DOLMotionSettingsChanged` (EmulationScreen.swift:1079, :1102-1112).
  func setShakeToWiggle(_ enabled: Bool) {
    MotionSettings.setEnhancedShakeDetection(enabled)
    NotificationCenter.default.post(name: .DOLMotionSettingsChanged, object: nil)
  }

  /// Read by the programmatic overlay each time it renders; nothing to restart.
  func setDragGain(_ gain: Double) { MotionSettings.setIRPointerGain(gain) }

  /// Read on every motion sample (Task 6): nothing to restart.
  func setGyroSensitivity(_ gain: Double) { MotionSettings.setGyroPointerSensitivity(gain) }
}
```

- [ ] **Step 4: Run the tests to verify they pass, then the gates**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/PlayerScreenIOTests"`
Expected: `Executed 2 tests, with 0 failures`.
Then: `make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` and `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice. The tvOS build compiles `recenterPointer()` without `TCDeviceMotion`.
If the compiler reports `call to main actor-isolated … in a synchronous nonisolated context`, wrap only that call in `MainActor.assumeIsolated { … }`, as Phase 2 Task 1 Step 5 did. Every such call runs on the main thread. Do not add `nonisolated` or `DispatchQueue.main.async`.

- [ ] **Step 5: Commit**

```bash
git add Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenIO.swift Source/iOS/App/DolphiniOSTests/PlayerScreenIOTests.swift
git commit -m "feat(controllers): player screen IO seam and live implementation"
```

---

### Task 12: `PlayerScreenViewModel`

**Files:**
- Create: `Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenViewModel.swift`
- Test: `Source/iOS/App/DolphiniOSTests/PlayerScreenViewModelTests.swift`

**Interfaces:**
- Consumes:
  - Task 7: `AdvancedSettingGroups`, `ControlCategory.title(for:)`.
  - Task 8: `PlayerScreenState`, `PlayerScreenActions`, `PlayerDeviceChoice`, `AdvancedGroupState`, `ProfileNaming`, `PlayerSlot.playerID/title`, `RemapControlRow.editableExpression`.
  - Task 9: `PlayerScreenModelBuilder.deviceOptions(state:platform:)`.
  - Task 10: `DeviceListView`, `ProfileListView`, `ExpressionEditorView`.
  - Task 11: `PlayerScreenIO`, `LivePlayerScreenIO`.
  - Phase 2: `ControllerHubReading`, `LiveControllerHubReader`, `PlatformKind.current`.
  - Existing: `RemapGroup.groups(for:attachment:)`, `RemapCaptureMachine`, `RemapExpression`.
- Produces:
  - `enum PlayerPrompt: Equatable { case saveAs, confirmOverwrite(name: String), confirmBuiltIn(name: String), confirmReset(profile: String), saveFailed }`, with `var title: String` and `var message: String`.
  - `final class PlayerProfileMemory`, with `shared`, `entry(for:) -> Entry?`, `remember(_:for:)` and `markEdited(_:)`.
  - `@MainActor @Observable final class PlayerScreenViewModel`, with:
    - `init(slot:reader:io:memory:notificationCenter:clock:pollsCapture:)`; every argument after `slot` is defaulted (`clock: () -> TimeInterval`, default `ProcessInfo.processInfo.systemUptime`).
    - `let slot`, `private(set) var state: PlayerScreenState`, `var displayState: PlayerScreenState`, `var prompt: PlayerPrompt?`, `var saveName: String`.
    - `static let rearmDelay: TimeInterval` (0.5), `var isCaptureSettling: Bool`.
    - `func reload()`, `start()`, `stop()`, `var actions: PlayerScreenActions`.
    - `func setDevice(_:)`, which reloads first; `profileNames()`, `loadProfile(_:)`, `requestReset()`, `openSavePrompt()`, `confirmPrompt()`, `cancelPrompt()`.
    - `func setExtension(_:)`, `setSideways(_:)`, `setMotionPointer(_:)`, `setNumericSetting(_:value:)`.
    - `func toggleCapture(_:)`, `pollCapture()`, `clear(_:)`, `@discardableResult saveExpression(_:for:) -> Bool`.

- [ ] **Step 1: Write the failing tests**

`Source/iOS/App/DolphiniOSTests/PlayerScreenViewModelTests.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

@MainActor
private final class FakeHubReader: ControllerHubReading {
  var gameCube: [Int: String] = [:]
  var wii: [Int: String] = [:]
  var extensions: [Int: Int] = [:]
  var pads: [ConnectedPadState] = []

  func boundQualifier(forGCPort port: Int) -> String { gameCube[port] ?? "" }
  func boundQualifier(forWiimote index: Int) -> String { wii[index] ?? "" }
  func wiiExtension(forWiimote index: Int) -> Int { extensions[index] ?? 0 }
  func isSideways(forWiimote index: Int) -> Bool { false }
  func connectedPads() -> [ConnectedPadState] { pads }
  func isGameRunning() -> Bool { false }
  func overlayVisible() -> Bool { false }
  func overlayMode() -> ControllerManager.OverlayMode { .auto }
  func overlayOpacity() -> Float { 1 }
  func continuousScanning() -> Bool { false }
  func dsuClientEnabled() -> Bool { false }
  func dsuServerCount() -> Int { 0 }
}

@MainActor
private final class FakeIO: PlayerScreenIO {
  /// "owner-group" for each `controlRows` read, in order.
  var groupReads: [String] = []
  /// Every write, as "kind:detail".
  var writes: [String] = []
  var deviceInputs = ["Button A", "Button B"]
  var inputValues: [Float] = [0, 0]
  var hasMapping = false
  var saveSucceeds = true
  var existingProfiles = ["Physical Controller", "Mine"]
  var parsable: Set<String> = ["`Button B`", ""]
  /// Lets a test make the reader follow a device change, as the real config does.
  var onSetDevice: ((PlayerDeviceChoice) -> Void)?

  func controlRows(owner: RemapGroupOwner, group: Int, port: Int) -> [RemapControlRow] {
    groupReads.append("\(owner)-\(group)")
    return [RemapControlRow(owner: owner, groupId: group, index: 0, name: "Control", expression: "`Button A`")]
  }

  func numericSettings(owner: RemapGroupOwner, group: Int, port: Int) -> [NumericSettingState] { [] }
  func profiles(for slot: PlayerSlot) -> [String] { existingProfiles }

  func defaultProfileName(forQualifier qualifier: String) -> String? {
    qualifier.hasPrefix("iOS/") ? "Touchscreen" : "Physical Controller"
  }

  func hasAnyBinding(_ slot: PlayerSlot) -> Bool { hasMapping }
  func isMotionPointerEnabled(wiimote: Int) -> Bool { true }
  func pointerMotion() -> PointerMotionState { .standard }
  func inputNames(forQualifier qualifier: String) -> [String] { deviceInputs }
  func inputStates(forQualifier qualifier: String) -> [Float] { inputValues }

  func check(_ expression: String) -> ExpressionCheck {
    parsable.contains(expression)
      ? ExpressionCheck(status: .valid, message: "ok")
      : ExpressionCheck(status: .invalid, message: "bad")
  }

  func setDevice(_ choice: PlayerDeviceChoice, slot: PlayerSlot) {
    writes.append("device:\(choice)")
    onSetDevice?(choice)
  }

  func loadProfile(_ name: String, slot: PlayerSlot) -> Bool {
    writes.append("load:\(name)")
    return true
  }

  func saveProfile(_ name: String, slot: PlayerSlot) -> Bool {
    writes.append("save:\(name)")
    return saveSucceeds
  }

  func setExtension(_ value: Int, wiimote: Int) { writes.append("extension:\(value)") }
  func setSideways(_ enabled: Bool, wiimote: Int) { writes.append("sideways:\(enabled)") }
  func setExpression(_ expression: String, for row: RemapControlRow, port: Int) { writes.append("expression:\(row.id)=\(expression)") }
  func setNumericSetting(_ setting: NumericSettingState, value: Double, port: Int) { writes.append("setting:\(setting.id)=\(value)") }
  func setMotionPointerEnabled(_ enabled: Bool, wiimote: Int) { writes.append("motion-pointer:\(enabled)") }
  func setPointerMode(_ mode: PointerMode) { writes.append("pointer:\(mode)") }
  func recenterPointer() { writes.append("recenter") }
  func setInvertX(_ enabled: Bool) { writes.append("invert-x:\(enabled)") }
  func setInvertY(_ enabled: Bool) { writes.append("invert-y:\(enabled)") }
  func setShakeToWiggle(_ enabled: Bool) { writes.append("shake:\(enabled)") }
  func setDragGain(_ gain: Double) { writes.append("gain:\(gain)") }
  func setGyroSensitivity(_ gain: Double) { writes.append("gyro-sensitivity:\(gain)") }
}

/// `PlayerScreenViewModel` against fakes: what it reads in which order, the capture session, the
/// spec's edge cases (disconnect while armed, timeout, a broken expression), the signed-off
/// decisions 5, 9, 10, 11 and 12, and the first-render read.
final class PlayerScreenViewModelTests: XCTestCase {

  private static let xbox = "MFi/0/Xbox Wireless Controller"
  private static let dualSense = "MFi/1/DualSense Wireless Controller"
  private static let dsu = "DSUClient/0/Pad C"

  private func pad(_ qualifier: String, _ name: String, gyro: Bool = false) -> ConnectedPadState {
    ConnectedPadState(qualifier: qualifier, name: name, batteryPercent: nil, isCharging: false, playerLabel: nil, hasGyro: gyro)
  }

  @MainActor
  private func make(
    _ reader: FakeHubReader, _ io: FakeIO,
    slot: PlayerSlot = PlayerSlot(kind: .gameCube, port: 1),
    memory: PlayerProfileMemory = PlayerProfileMemory(),
    center: NotificationCenter = NotificationCenter(),
    // A frozen clock: after any capture binds, `isCaptureSettling` stays true forever. A test that
    // re-arms after a bind must pass a `Clock` it can step (see the rearm test).
    clock: @escaping () -> TimeInterval = { 0 }
  ) -> PlayerScreenViewModel {
    PlayerScreenViewModel(
      slot: slot, reader: reader, io: io, memory: memory, notificationCenter: center, clock: clock, pollsCapture: false)
  }

  /// A clock a test can step.
  private final class Clock {
    var now: TimeInterval = 0
  }

  /// GameCube port 1 bound to a connected Xbox pad.
  @MainActor
  private func boundGameCube() -> (FakeHubReader, FakeIO) {
    let reader = FakeHubReader()
    reader.gameCube[1] = Self.xbox
    reader.pads = [pad(Self.xbox, "Xbox Wireless Controller")]
    return (reader, FakeIO())
  }

  /// Lets the "a turn later" prompt task run.
  private func drainMainQueue() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
  }

  // MARK: Snapshot

  @MainActor
  func test_reload_readsThePlayerThroughTheHubSeam_andEveryGroupInRemapOrder() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    XCTAssertEqual(model.state.player.id, "gc-1")
    XCTAssertEqual(model.state.player.deviceQualifier, Self.xbox)
    XCTAssertEqual(io.groupReads, ["gcPad-0", "gcPad-3", "gcPad-1", "gcPad-2", "gcPad-4", "gcPad-5", "gcPad-7"])
    XCTAssertEqual(model.state.advanced.map(\.groupId), [1, 2, 4])
  }

  @MainActor
  func test_reload_wiiRemoteWithClassic_readsTheClassicGroups() {
    let reader = FakeHubReader()
    reader.wii[2] = Self.xbox
    reader.extensions[2] = 2
    let io = FakeIO()
    let model = make(reader, io, slot: PlayerSlot(kind: .wiiRemote, port: 2))
    model.reload()
    XCTAssertEqual(io.groupReads, [
      "wiimote-0", "wiimote-1", "wiimote-3", "wiimote-5", "wiimote-4", "wiimote-2", "wiimote-6", "wiimote-8",
      "classic-0", "classic-2", "classic-3", "classic-4", "classic-1",
    ])
    XCTAssertEqual(
      model.state.advanced.map { "\($0.owner)-\($0.groupId)" },
      ["wiimote-3", "wiimote-12", "classic-3", "classic-4", "classic-1"])
    XCTAssertTrue(model.state.motionPointerEnabled)
  }

  /// The first render must not see `.empty`: before `start()`, `displayState` is a fresh read.
  @MainActor
  func test_displayState_beforeStart_isAFreshRead() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    XCTAssertEqual(model.state.player.deviceQualifier, "", "init reads nothing")
    XCTAssertEqual(model.displayState.player.deviceQualifier, Self.xbox)
    XCTAssertFalse(model.displayState.controls.isEmpty)
  }

  @MainActor
  func test_showsAdvanced_survivesAReload() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    model.actions.toggleAdvanced()
    model.reload()
    XCTAssertTrue(model.state.showsAdvanced)
  }

  // MARK: Capture

  @MainActor
  func test_capture_bindsThePressedInput() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    let row = model.state.controls[0]
    model.toggleCapture(row)
    XCTAssertEqual(model.state.armedControlID, row.id)
    model.pollCapture()  // nothing was held at arm time: listening starts
    io.inputValues = [1, 0]
    model.pollCapture()
    model.pollCapture()
    XCTAssertEqual(io.writes, [], "a press must hold for three polls")
    model.pollCapture()
    XCTAssertEqual(io.writes, ["expression:gcPad-0-0=`Button A`"])
    XCTAssertNil(model.state.armedControlID)
  }

  /// A capture binds while the button is still held, but a tvOS `Button` fires on release and B /
  /// Menu arrive as an exit command: right after binding, neither may re-arm the row or pop.
  @MainActor
  func test_capture_ignoresARearmAndBackRightAfterItBinds() {
    let (reader, io) = boundGameCube()
    let clock = Clock()
    let model = make(reader, io, clock: { clock.now })
    model.reload()
    let row = model.state.controls[0]
    model.toggleCapture(row)
    model.pollCapture()
    io.inputValues = [1, 0]
    for _ in 0 ..< 3 { model.pollCapture() }
    XCTAssertNil(model.state.armedControlID, "bound")
    io.inputValues = [0, 0]
    clock.now = 0.1
    XCTAssertTrue(model.isCaptureSettling, "the host ignores Back now")
    model.toggleCapture(row)
    XCTAssertNil(model.state.armedControlID, "the bound press's release must not re-arm the row")
    clock.now = 1
    XCTAssertFalse(model.isCaptureSettling)
    model.toggleCapture(row)
    XCTAssertEqual(model.state.armedControlID, row.id)
  }

  /// Spec edge case: "Capture times out. The row returns to its previous binding."
  @MainActor
  func test_capture_timeoutKeepsTheBinding() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    model.toggleCapture(model.state.controls[0])
    for _ in 0 ... 300 { model.pollCapture() }
    XCTAssertEqual(io.writes, [])
    XCTAssertNil(model.state.armedControlID)
  }

  /// Spec edge case: the pad disconnects while its screen is open. The capture cancels and the
  /// binding is kept.
  @MainActor
  func test_capture_padDisconnecting_cancelsAndKeepsTheBinding() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    model.toggleCapture(model.state.controls[0])
    reader.pads = []
    model.reload()
    XCTAssertNil(model.state.armedControlID)
    XCTAssertTrue(model.state.isDisconnected)
    io.inputValues = [1, 0]
    for _ in 0 ..< 4 { model.pollCapture() }
    XCTAssertEqual(io.writes, [])
  }

  /// Decision 11: a DSU-bound port captures, and a reload never cancels it for "not in the pad list".
  @MainActor
  func test_capture_dsuPort_armsAndSurvivesAReload() {
    let reader = FakeHubReader()
    reader.gameCube[1] = Self.dsu
    let model = make(reader, FakeIO())
    model.reload()
    let row = model.state.controls[0]
    model.toggleCapture(row)
    model.reload()
    XCTAssertEqual(model.state.armedControlID, row.id)
  }

  @MainActor
  func test_capture_needsAConnectedPad() {
    let reader = FakeHubReader()
    reader.gameCube[1] = Self.xbox
    let model = make(reader, FakeIO())
    model.reload()
    model.toggleCapture(model.state.controls[0])
    XCTAssertNil(model.state.armedControlID)
  }

  @MainActor
  func test_capture_activatingTheArmedRowAgainCancels() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    let row = model.state.controls[0]
    model.toggleCapture(row)
    model.toggleCapture(row)
    XCTAssertNil(model.state.armedControlID)
    XCTAssertEqual(io.writes, [])
  }

  @MainActor
  func test_clear_isIgnoredWhileAnotherRowIsArmed() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    let rows = model.state.controls
    model.toggleCapture(rows[0])
    model.clear(rows[1])
    XCTAssertEqual(io.writes, [])
    XCTAssertEqual(model.state.armedControlID, rows[0].id)
  }

  @MainActor
  func test_stop_endsAnArmedCapture() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.start()
    model.toggleCapture(model.state.controls[0])
    model.stop()
    XCTAssertNil(model.state.armedControlID)
  }

  // MARK: Device (decisions 9 and 12)

  @MainActor
  func test_setDevice_firstBindRemembersTheDefaultProfile() {
    let reader = FakeHubReader()
    reader.pads = [pad(Self.xbox, "Xbox Wireless Controller")]
    let io = FakeIO()
    io.onSetDevice = { choice in
      if case .pad(let qualifier) = choice { reader.gameCube[1] = qualifier }
    }
    let model = make(reader, io)
    model.reload()
    model.setDevice(.pad(Self.xbox))
    XCTAssertEqual(io.writes, ["device:pad(\"\(Self.xbox)\")"])
    XCTAssertEqual(model.state.profileName, "Physical Controller")
  }

  /// `ControllerAssignmentService.assign` keeps an existing mapping, so the name stays.
  @MainActor
  func test_setDevice_rebindKeepsTheRememberedName() {
    let reader = FakeHubReader()
    reader.pads = [pad(Self.xbox, "Xbox Wireless Controller")]
    let io = FakeIO()
    io.hasMapping = true
    io.onSetDevice = { choice in
      if case .pad(let qualifier) = choice { reader.gameCube[1] = qualifier }
    }
    let memory = PlayerProfileMemory()
    memory.remember("Mine", for: "gc-1")
    let model = make(reader, io, memory: memory)
    model.reload()
    model.setDevice(.pad(Self.xbox))
    XCTAssertEqual(model.state.profileName, "Mine")
  }

  /// Both kinds reload the Touchscreen profile when they switch to the touchscreen, mapping or not
  /// (GameCube always; a Wii Remote's BindTouchscreen whenever the bound device changes).
  @MainActor
  func test_setDevice_touchscreenOnAWiiRemote_remembersTheTouchscreenProfile() {
    let reader = FakeHubReader()
    reader.wii[1] = Self.xbox
    reader.pads = [pad(Self.xbox, "Xbox Wireless Controller")]
    let io = FakeIO()
    io.hasMapping = true
    io.onSetDevice = { choice in
      if choice == .touchscreen { reader.wii[1] = "iOS/4/Touchscreen" }
    }
    let memory = PlayerProfileMemory()
    memory.remember("Mine", for: "wii-1")
    let model = make(reader, io, slot: PlayerSlot(kind: .wiiRemote, port: 1), memory: memory)
    model.reload()
    model.setDevice(.touchscreen)
    XCTAssertEqual(model.state.profileName, "Touchscreen")
  }

  /// Decision 12: the app turns the IMU pointer off on touchscreen-bound Wii Remotes and a rebind
  /// keeps the mapping, so binding a gyro pad turns it back on.
  @MainActor
  func test_setDevice_gyroPadOnAWiiRemote_turnsTheMotionPointerOn() {
    let reader = FakeHubReader()
    reader.wii[1] = "iOS/4/Touchscreen"
    reader.pads = [pad(Self.dualSense, "DualSense", gyro: true), pad(Self.xbox, "Xbox")]
    let io = FakeIO()
    io.hasMapping = true
    io.onSetDevice = { choice in
      if case .pad(let qualifier) = choice { reader.wii[1] = qualifier }
    }
    let model = make(reader, io, slot: PlayerSlot(kind: .wiiRemote, port: 1))
    model.reload()
    model.setDevice(.pad(Self.dualSense))
    XCTAssertEqual(io.writes, ["device:pad(\"\(Self.dualSense)\")", "motion-pointer:true"])
    io.writes = []
    model.setDevice(.pad(Self.xbox))
    XCTAssertEqual(io.writes, ["device:pad(\"\(Self.xbox)\")"], "a pad without a gyro leaves it alone")
  }

  @MainActor
  func test_setDevice_theCurrentChoiceWritesNothing() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    model.setDevice(.pad(Self.xbox))
    XCTAssertEqual(io.writes, [])
  }

  /// Pushing the Device list stops the screen (its `onDisappear`). A pad that connects while the
  /// list is open must appear (the list's refresh is `reload()`) and must be pickable with its gyro
  /// seen, i.e. `setDevice` must not act on the pads it saw at push time.
  @MainActor
  func test_deviceList_aPadConnectingWhileOpen_isListedAndPicked() {
    let reader = FakeHubReader()
    reader.wii[1] = "iOS/4/Touchscreen"
    let io = FakeIO()
    io.hasMapping = true
    io.onSetDevice = { choice in
      if case .pad(let qualifier) = choice { reader.wii[1] = qualifier }
    }
    let model = make(reader, io, slot: PlayerSlot(kind: .wiiRemote, port: 1))
    model.start()
    model.stop()  // the Device list was pushed
    reader.pads = [pad(Self.dualSense, "DualSense", gyro: true)]
    model.reload()  // what DeviceListView's refresh does on .GCControllerDidConnect
    let options = PlayerScreenModelBuilder.deviceOptions(state: model.displayState, platform: .ios)
    XCTAssertTrue(options.contains { $0.choice == .pad(Self.dualSense) })
    model.setDevice(.pad(Self.dualSense))
    XCTAssertEqual(io.writes, ["device:pad(\"\(Self.dualSense)\")", "motion-pointer:true"])
  }

  /// Even without the list's refresh, `setDevice` reads a fresh snapshot first.
  @MainActor
  func test_setDevice_readsAFreshSnapshot() {
    let reader = FakeHubReader()
    reader.wii[1] = "iOS/4/Touchscreen"
    let io = FakeIO()
    io.hasMapping = true
    io.onSetDevice = { choice in
      if case .pad(let qualifier) = choice { reader.wii[1] = qualifier }
    }
    let model = make(reader, io, slot: PlayerSlot(kind: .wiiRemote, port: 1))
    model.reload()
    reader.pads = [pad(Self.dualSense, "DualSense", gyro: true)]
    model.setDevice(.pad(Self.dualSense))
    XCTAssertEqual(io.writes, ["device:pad(\"\(Self.dualSense)\")", "motion-pointer:true"])
  }

  // MARK: Profile (decisions 5 and 10)

  @MainActor
  func test_loadProfile_remembersTheName() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    model.loadProfile("Mine")
    XCTAssertEqual(io.writes, ["load:Mine"])
    XCTAssertEqual(model.state.profileName, "Mine")
    XCTAssertFalse(model.state.profileEdited)
  }

  @MainActor
  func test_reset_asksFirst_thenLoadsTheDefault() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    model.requestReset()
    XCTAssertEqual(model.prompt, .confirmReset(profile: "Physical Controller"))
    XCTAssertEqual(io.writes, [], "nothing until confirmed")
    model.confirmPrompt()
    XCTAssertEqual(io.writes, ["load:Physical Controller"])
    XCTAssertNil(model.prompt)
  }

  @MainActor
  func test_reset_cancelLoadsNothing() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    model.requestReset()
    model.cancelPrompt()
    XCTAssertNil(model.prompt)
    XCTAssertEqual(io.writes, [])
  }

  /// Prefilled with the pad's name so a pad user saves with A, never a device-default name.
  @MainActor
  func test_openSavePrompt_prefillsThePadName() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    model.openSavePrompt()
    XCTAssertEqual(model.prompt, .saveAs)
    XCTAssertEqual(model.saveName, "Xbox Wireless Controller")
  }

  @MainActor
  func test_save_aNewName_writesTrimmed() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    model.openSavePrompt()
    model.saveName = "  My/Pad  "
    model.confirmPrompt()
    XCTAssertEqual(io.writes, ["save:My-Pad"])
    XCTAssertEqual(model.state.profileName, "My-Pad")
  }

  @MainActor
  func test_save_anExistingName_asksBeforeReplacing() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    model.openSavePrompt()
    model.saveName = "mine"
    model.confirmPrompt()
    XCTAssertEqual(io.writes, [], "nothing written yet")
    drainMainQueue()
    XCTAssertEqual(model.prompt, .confirmOverwrite(name: "mine"))
    model.confirmPrompt()
    XCTAssertEqual(io.writes, ["save:mine"])
  }

  /// Decision 10: a built-in name (any case) asks first, because the saved profile will be used
  /// instead of the built-in one for future first binds and Reset; confirming saves it.
  @MainActor
  func test_save_aBuiltInName_asksThenSaves() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    model.openSavePrompt()
    model.saveName = "touchscreen"
    model.confirmPrompt()
    XCTAssertEqual(io.writes, [], "nothing written yet")
    drainMainQueue()
    XCTAssertEqual(model.prompt, .confirmBuiltIn(name: "touchscreen"))
    model.confirmPrompt()
    XCTAssertEqual(io.writes, ["save:touchscreen"])
    XCTAssertEqual(model.state.profileName, "touchscreen")
  }

  @MainActor
  func test_save_aBuiltInName_cancelWritesNothing() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    model.openSavePrompt()
    model.saveName = "Physical Controller"
    model.confirmPrompt()
    drainMainQueue()
    model.cancelPrompt()
    XCTAssertNil(model.prompt)
    XCTAssertEqual(io.writes, [])
  }

  /// The single alert's title and message come from the prompt; none is blank.
  func test_promptTexts() {
    let prompts: [PlayerPrompt] = [
      .saveAs, .confirmOverwrite(name: "Mine"), .confirmBuiltIn(name: "Touchscreen"),
      .confirmReset(profile: "Physical Controller"), .saveFailed,
    ]
    for prompt in prompts {
      XCTAssertFalse(prompt.title.isEmpty, "\(prompt)")
      XCTAssertFalse(prompt.message.isEmpty, "\(prompt)")
    }
    XCTAssertTrue(PlayerPrompt.confirmBuiltIn(name: "Touchscreen").message.contains("Touchscreen"))
    XCTAssertTrue(PlayerPrompt.confirmOverwrite(name: "Mine").message.contains("Mine"))
    XCTAssertTrue(PlayerPrompt.confirmReset(profile: "Physical Controller").message.contains("Physical Controller"))
  }

  @MainActor
  func test_save_failureShowsTheErrorATurnLater() {
    let (reader, io) = boundGameCube()
    io.saveSucceeds = false
    let model = make(reader, io)
    model.reload()
    model.openSavePrompt()
    model.saveName = "New"
    model.confirmPrompt()
    XCTAssertNil(model.prompt, "not on the turn the prompt is dismissing")
    drainMainQueue()
    XCTAssertEqual(model.prompt, .saveFailed)
  }

  // MARK: Raw expressions and settings

  /// Spec edge case: an expression that does not parse is not saved.
  @MainActor
  func test_saveExpression_refusesTextThatDoesNotParse() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    XCTAssertFalse(model.saveExpression("(`Button B`", for: model.state.controls[0]))
    XCTAssertEqual(io.writes, [])
  }

  @MainActor
  func test_saveExpression_writesValidText_andMarksTheProfileEdited() {
    let (reader, io) = boundGameCube()
    let memory = PlayerProfileMemory()
    memory.remember("Mine", for: "gc-1")
    let model = make(reader, io, memory: memory)
    model.reload()
    XCTAssertTrue(model.saveExpression("`Button B`", for: model.state.controls[0]))
    XCTAssertEqual(io.writes, ["expression:gcPad-0-0=`Button B`"])
    XCTAssertTrue(model.state.profileEdited)
  }

  @MainActor
  func test_pointerSettingsWriteThroughTheSeam() {
    let reader = FakeHubReader()
    reader.wii[1] = "iOS/4/Touchscreen"
    let io = FakeIO()
    let model = make(reader, io, slot: PlayerSlot(kind: .wiiRemote, port: 1))
    model.reload()
    model.actions.setPointerMode(.gyro)
    model.actions.setGyroSensitivity(1.5)
    model.actions.setInvertX(true)
    model.actions.setShakeToWiggle(false)
    model.actions.recenterPointer()
    XCTAssertEqual(io.writes, ["pointer:gyro", "gyro-sensitivity:1.5", "invert-x:true", "shake:false", "recenter"])
  }

  @MainActor
  func test_start_reloadsWhenAssignmentsChange() {
    let (reader, io) = boundGameCube()
    let center = NotificationCenter()
    let model = make(reader, io, center: center)
    model.start()
    reader.gameCube[1] = ""
    center.post(name: ControllerManager.assignmentsChanged, object: nil)
    drainMainQueue()
    XCTAssertEqual(model.state.player.deviceQualifier, "")
    model.stop()
  }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/PlayerScreenViewModelTests"`
Expected: build failure, `cannot find 'PlayerScreenViewModel' in scope`.

- [ ] **Step 3: Write the view model**

`Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenViewModel.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation
import SwiftUI

/// The player screen's prompts (decision 10), shown one at a time by the host's single alert and
/// answered by a pad through `MenuModal`.
enum PlayerPrompt: Equatable {
  case saveAs
  /// The typed name matches an existing (user or bundled) profile.
  case confirmOverwrite(name: String)
  /// The typed name is a device-default profile name (`ProfileNaming.builtInNames`).
  case confirmBuiltIn(name: String)
  case confirmReset(profile: String)
  case saveFailed

  var title: String {
    switch self {
    case .saveAs: return L("Save Profile")
    case .confirmOverwrite: return L("Replace Profile?")
    case .confirmBuiltIn: return L("Replace the Built-In Profile?")
    case .confirmReset: return L("Reset to Default Profile?")
    case .saveFailed: return L("Could Not Save Profile")
    }
  }

  var message: String {
    switch self {
    case .saveAs:
      return L("Saves this player's current mapping as a profile you can load on any port.")
    case .confirmOverwrite(let name):
      return String(format: L("A profile named %@ already exists. Replace it?"), name)
    case .confirmBuiltIn(let name):
      return String(
        format: L("Your profile named %@ will be used instead of the built-in one whenever a device of this kind is first bound, and by Reset to Default Profile."),
        name)
    case .confirmReset(let profile):
      return String(format: L("Loads %@ for this player and replaces its current buttons."), profile)
    case .saveFailed:
      return L("The profile file could not be written.")
    }
  }
}

/// The profile last loaded, saved or applied on each port during this app session (decision 5).
/// Dolphin does not record which profile a port's mapping came from (`loadProfile:` copies the ini
/// into the live controller), so this is the only source of the name. Main thread only.
final class PlayerProfileMemory {
  static let shared = PlayerProfileMemory()

  struct Entry: Equatable {
    var name: String
    var edited: Bool
  }

  private var entries: [String: Entry] = [:]

  func entry(for playerID: String) -> Entry? { entries[playerID] }

  func remember(_ name: String, for playerID: String) {
    entries[playerID] = Entry(name: name, edited: false)
  }

  /// The mapping changed after the remembered profile was applied.
  func markEdited(_ playerID: String) {
    entries[playerID]?.edited = true
  }
}

/// One player's screen state (controller hub spec, "Player screen"; decision 1). It fills
/// `PlayerState` through the hub's `ControllerHubReading`, exactly as `ControllerHubViewModel` fills
/// the hub's rows, and reaches everything else through `PlayerScreenIO`.
///
/// `init` reads nothing and installs nothing: the hub rebuilds this screen's host on every render.
/// The host renders `displayState`, which is a fresh read until `start()` stores the first snapshot.
@MainActor
@Observable
final class PlayerScreenViewModel {
  let slot: PlayerSlot
  private(set) var state: PlayerScreenState
  /// The prompt the host shows, if any.
  var prompt: PlayerPrompt?
  /// Save Profile As…'s text field.
  var saveName = ""

  /// ~60 Hz while a capture is armed, as `RemapPlayerView` polled.
  static let captureTickInterval: TimeInterval = 1.0 / 60
  /// After a capture binds, activation and Back are ignored this long. A capture binds while the
  /// button is still held (three polls), but a tvOS `Button` fires on release, and B / Menu still
  /// arrive as an exit command. Without this, binding A re-arms the row on release and binding B
  /// pops the screen.
  static let rearmDelay: TimeInterval = 0.5

  private let reader: any ControllerHubReading
  private let io: any PlayerScreenIO
  private let memory: PlayerProfileMemory
  private let notificationCenter: NotificationCenter
  /// Seconds, monotonic. Injected so a test can step past `rearmDelay`.
  private let clock: () -> TimeInterval
  /// False in tests, which call `pollCapture()` themselves.
  private let pollsCapture: Bool
  @ObservationIgnored private var isLoaded = false
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var capture: Capture?
  @ObservationIgnored private var ticker: Timer?
  @ObservationIgnored private var captureEndedAt: TimeInterval?

  private struct Capture {
    let row: RemapControlRow
    /// The device being listened to; the capture ends if the port loses it.
    let qualifier: String
    let inputNames: [String]
    var machine: RemapCaptureMachine
  }

  init(
    slot: PlayerSlot,
    reader: any ControllerHubReading = LiveControllerHubReader(),
    io: any PlayerScreenIO = LivePlayerScreenIO(),
    memory: PlayerProfileMemory = .shared,
    notificationCenter: NotificationCenter = .default,
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    pollsCapture: Bool = true
  ) {
    self.slot = slot
    self.reader = reader
    self.io = io
    self.memory = memory
    self.notificationCenter = notificationCenter
    self.clock = clock
    self.pollsCapture = pollsCapture
    state = .empty(PlayerState(kind: slot.kind, port: slot.port, deviceQualifier: "", wiiExtension: 0, isSideways: false))
  }

  // MARK: Snapshot

  /// What the screen shows. Before `start()` it is a fresh read, so the first render (and tvOS's
  /// default focus, computed from the first model) never sees the empty state. A read changes no
  /// state, so this is safe inside `body`.
  var displayState: PlayerScreenState { isLoaded ? state : makeSnapshot() }

  func reload() {
    var snapshot = makeSnapshot()
    // Spec edge case: the pad left mid-capture, or the port changed device. The capture cancels;
    // the binding is kept. A DSU device is never "missing" (decision 11).
    if let capture,
       capture.qualifier != snapshot.player.deviceQualifier || PlayerScreenState.isMissing(capture.qualifier, pads: snapshot.pads) {
      endCapture()
      snapshot.armedControlID = nil
    }
    state = snapshot
    isLoaded = true
  }

  private func makeSnapshot() -> PlayerScreenState {
    let player = readPlayer()
    let system: RemapSystem = slot.kind == .gameCube ? .gamecube : .wii
    let remembered = memory.entry(for: slot.playerID)
    return PlayerScreenState(
      player: player,
      pads: reader.connectedPads(),
      profileName: remembered?.name,
      profileEdited: remembered?.edited ?? false,
      controls: RemapGroup.groups(for: system, attachment: player.wiiExtension).flatMap {
        io.controlRows(owner: $0.owner, group: $0.id, port: slot.port)
      },
      armedControlID: capture?.row.id,
      pointerMotion: io.pointerMotion(),
      motionPointerEnabled: slot.kind == .wiiRemote && io.isMotionPointerEnabled(wiimote: slot.port),
      showsAdvanced: state.showsAdvanced,
      advanced: AdvancedSettingGroups.entries(for: system, attachment: player.wiiExtension).map { entry in
        AdvancedGroupState(
          owner: entry.owner, groupId: entry.groupId, title: entry.title,
          settings: io.numericSettings(owner: entry.owner, group: entry.groupId, port: slot.port))
      })
  }

  /// The same reads, in the same shape, as `ControllerHubViewModel.reload()` makes for this port.
  private func readPlayer() -> PlayerState {
    switch slot.kind {
    case .gameCube:
      return PlayerState(
        kind: .gameCube, port: slot.port, deviceQualifier: reader.boundQualifier(forGCPort: slot.port),
        wiiExtension: 0, isSideways: false)
    case .wiiRemote:
      return PlayerState(
        kind: .wiiRemote, port: slot.port, deviceQualifier: reader.boundQualifier(forWiimote: slot.port),
        wiiExtension: reader.wiiExtension(forWiimote: slot.port), isSideways: reader.isSideways(forWiimote: slot.port))
    }
  }

  /// Takes a snapshot and follows assignment and device changes until `stop()`. Idempotent.
  func start() {
    reload()
    guard observers.isEmpty else { return }
    let names: [Notification.Name] = [
      ControllerManager.assignmentsChanged,
      .GCControllerDidConnect,
      .GCControllerDidDisconnect,
      .TVControllerDevicesChanged,
    ]
    observers = names.map { name in
      notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.reload() }
      }
    }
  }

  /// Also ends an armed capture: a pushed list or editor covers this screen.
  func stop() {
    endCapture()
    observers.forEach { notificationCenter.removeObserver($0) }
    observers.removeAll()
  }

  // MARK: Actions

  var actions: PlayerScreenActions {
    PlayerScreenActions(
      deviceListDestination: { [weak self] in
        AnyView(DeviceListView(
          options: { [weak self] in
            guard let self else { return [] }
            return PlayerScreenModelBuilder.deviceOptions(state: self.displayState, platform: .current)
          },
          current: { [weak self] in self?.displayState.deviceChoice ?? .noDevice },
          refresh: { [weak self] in self?.reload() },
          onPick: { [weak self] in self?.setDevice($0) }))
      },
      profileListDestination: { [weak self] in
        AnyView(ProfileListView(
          current: self?.state.profileName,
          loadNames: { [weak self] in self?.profileNames() ?? [] },
          onPick: { [weak self] in self?.loadProfile($0) }))
      },
      saveProfileAs: { [weak self] in self?.openSavePrompt() },
      resetProfile: { [weak self] in self?.requestReset() },
      setExtension: { [weak self] in self?.setExtension($0) },
      setSideways: { [weak self] in self?.setSideways($0) },
      toggleCapture: { [weak self] in self?.toggleCapture($0) },
      clearBinding: { [weak self] in self?.clear($0) },
      setPointerMode: { [weak self] mode in self?.write { $0.setPointerMode(mode) } },
      recenterPointer: { [weak self] in self?.io.recenterPointer() },
      setDragGain: { [weak self] gain in self?.write { $0.setDragGain(gain) } },
      setGyroSensitivity: { [weak self] gain in self?.write { $0.setGyroSensitivity(gain) } },
      setInvertX: { [weak self] enabled in self?.write { $0.setInvertX(enabled) } },
      setInvertY: { [weak self] enabled in self?.write { $0.setInvertY(enabled) } },
      setShakeToWiggle: { [weak self] enabled in self?.write { $0.setShakeToWiggle(enabled) } },
      setMotionPointer: { [weak self] in self?.setMotionPointer($0) },
      toggleAdvanced: { [weak self] in self?.state.showsAdvanced.toggle() },
      setNumericSetting: { [weak self] setting, value in self?.setNumericSetting(setting, value: value) },
      expressionDestination: { [weak self] row in
        AnyView(ExpressionEditorView(
          title: ControlCategory.title(for: row),
          original: row.editableExpression,
          check: { [weak self] in self?.io.check($0) ?? ExpressionCheck(status: .invalid, message: "") },
          save: { [weak self] in self?.saveExpression($0, for: row) ?? false }))
      })
  }

  /// A setting that is not part of the port's mapping (pointer, motion): write, then re-read.
  private func write(_ change: (any PlayerScreenIO) -> Void) {
    change(io)
    reload()
  }

  // MARK: Device (decisions 9 and 12)

  /// One pick from the Device list: one assignment. Reads a fresh snapshot first: the screen stopped
  /// observing when the list was pushed, so `state` may predate a pad that connected since.
  func setDevice(_ choice: PlayerDeviceChoice) {
    reload()
    guard choice != state.deviceChoice else { return }
    endCapture()
    let hadMapping = io.hasAnyBinding(slot)
    var bindsGyroPad = false
    if case .pad(let qualifier) = choice {
      bindsGyroPad = state.pads.first { $0.qualifier == qualifier }?.hasGyro == true
    }
    io.setDevice(choice, slot: slot)
    // Which profile the port holds now, as far as the app can know (Dolphin does not record it):
    // - Touchscreen: both kinds reload the "Touchscreen" profile. GameCube always does
    //   (TVControllerMappingBridge.mm:228-253); a Wii Remote's BindTouchscreen does whenever the bound
    //   device changes (EmulationCoordinator.mm:1581-1586), and it always changes here.
    // - A pad: a first bind loads its default profile; a re-bind keeps the port's mapping
    //   (ControllerAssignmentService.swift:39-47), so the remembered name stays.
    // - No Device unbinds the device only; the mapping and its name stay.
    let qualifier = readPlayer().deviceQualifier
    let reloadedDefault = choice == .touchscreen || (choice != .noDevice && !hadMapping)
    if reloadedDefault, !qualifier.isEmpty, let name = io.defaultProfileName(forQualifier: qualifier) {
      memory.remember(name, for: slot.playerID)
    }
    // Decision 12: the app turns the IMU pointer off on every touchscreen-bound Wii Remote
    // (EmulationCoordinator.mm:1501-1525), and a re-bind keeps the mapping, so a gyro pad taking
    // over would leave its pointer off.
    if slot.kind == .wiiRemote, bindsGyroPad {
      io.setMotionPointerEnabled(true, wiimote: slot.port)
    }
    reload()
  }

  // MARK: Profile (decisions 5 and 10)

  func profileNames() -> [String] { io.profiles(for: slot) }

  func loadProfile(_ name: String) {
    endCapture()
    if io.loadProfile(name, slot: slot) {
      memory.remember(name, for: slot.playerID)
    }
    reload()
  }

  /// Asks before loading the device's default profile over this port's mapping.
  func requestReset() {
    let qualifier = state.player.deviceQualifier
    guard !qualifier.isEmpty, let name = io.defaultProfileName(forQualifier: qualifier) else { return }
    prompt = .confirmReset(profile: name)
  }

  /// Prefilled so a pad user can save with A without typing; never a device-default name.
  func openSavePrompt() {
    saveName = ProfileNaming.suggestion(padName: state.boundPad?.name, playerTitle: slot.title)
    prompt = .saveAs
  }

  /// A pad's A, or the alert's own confirming button.
  func confirmPrompt() {
    guard let current = prompt else { return }
    prompt = nil
    switch current {
    case .saveAs:
      let name = ProfileNaming.sanitized(saveName)
      guard !name.isEmpty else { return }
      if ProfileNaming.isBuiltIn(name) {
        present(.confirmBuiltIn(name: name))
      } else if ProfileNaming.exists(name, in: io.profiles(for: slot)) {
        present(.confirmOverwrite(name: name))
      } else {
        save(name)
      }
    case .confirmOverwrite(let name), .confirmBuiltIn(let name):
      save(name)
    case .confirmReset(let profile):
      loadProfile(profile)
    case .saveFailed:
      break
    }
  }

  /// A pad's B, or the alert's Cancel.
  func cancelPrompt() {
    prompt = nil
  }

  private func save(_ name: String) {
    if io.saveProfile(name, slot: slot) {
      memory.remember(name, for: slot.playerID)
      reload()
    } else {
      present(.saveFailed)
    }
  }

  /// A follow-up prompt, a turn later: the alert that led here is still being dismissed, and
  /// presenting on the same turn can silently fail (RemapPlayerView.swift:617-624).
  private func present(_ next: PlayerPrompt) {
    Task { @MainActor [weak self] in self?.prompt = next }
  }

  // MARK: Wii Remote and settings

  func setExtension(_ value: Int) {
    guard slot.kind == .wiiRemote, value != state.player.wiiExtension else { return }
    endCapture()
    io.setExtension(value, wiimote: slot.port)
    memory.markEdited(slot.playerID)
    reload()
  }

  func setSideways(_ enabled: Bool) {
    guard slot.kind == .wiiRemote else { return }
    io.setSideways(enabled, wiimote: slot.port)
    memory.markEdited(slot.playerID)
    reload()
  }

  func setMotionPointer(_ enabled: Bool) {
    guard slot.kind == .wiiRemote else { return }
    io.setMotionPointerEnabled(enabled, wiimote: slot.port)
    memory.markEdited(slot.playerID)
    reload()
  }

  func setNumericSetting(_ setting: NumericSettingState, value: Double) {
    io.setNumericSetting(setting, value: value, port: slot.port)
    memory.markEdited(slot.playerID)
    reload()
  }

  // MARK: Capture

  /// True for `rearmDelay` after a capture bound or timed out: the press that was just bound may
  /// still be on its way up. The host ignores Back while this is true.
  var isCaptureSettling: Bool {
    captureEndedAt.map { clock() - $0 < Self.rearmDelay } ?? false
  }

  /// Arms `row`, or cancels when it is the armed row. While one row is armed the builder disables
  /// the others, so another row's activation never gets here mid-capture.
  func toggleCapture(_ row: RemapControlRow) {
    if let capture {
      if capture.row.id == row.id {
        endCapture()
        reload()
      }
      return
    }
    guard !isCaptureSettling, state.canCapture else { return }
    let qualifier = state.player.deviceQualifier
    let names = io.inputNames(forQualifier: qualifier)
    guard !names.isEmpty else { return }
    capture = Capture(
      row: row, qualifier: qualifier, inputNames: names,
      machine: RemapCaptureMachine(
        baseline: io.inputStates(forQualifier: qualifier), capturable: names.map(RemapExpression.isCapturable(inputName:))))
    state.armedControlID = row.id
    if pollsCapture { startTicker() }
  }

  /// One capture tick. A captured input becomes the row's expression; a timeout leaves the binding
  /// as it was (spec edge case "Capture times out").
  func pollCapture() {
    guard var session = capture else { return }
    guard let result = session.machine.poll(io.inputStates(forQualifier: session.qualifier)) else {
      capture = session
      return
    }
    if case .captured(let index) = result, index < session.inputNames.count {
      io.setExpression(RemapExpression.expression(forInputName: session.inputNames[index]), for: session.row, port: slot.port)
      memory.markEdited(slot.playerID)
    }
    captureEndedAt = clock()
    endCapture()
    reload()
  }

  /// Long-press or swipe Clear. Never races a capture armed on a different row.
  func clear(_ row: RemapControlRow) {
    if let capture, capture.row.id != row.id { return }
    endCapture()
    io.setExpression("", for: row, port: slot.port)
    memory.markEdited(slot.playerID)
    reload()
  }

  /// Advanced → Raw Bindings. Text that does not parse is never written (spec edge case); the
  /// editor already disables Save for it, and this is the backstop.
  @discardableResult
  func saveExpression(_ text: String, for row: RemapControlRow) -> Bool {
    guard io.check(text).canSave else { return false }
    io.setExpression(text, for: row, port: slot.port)
    memory.markEdited(slot.playerID)
    reload()
    return true
  }

  private func startTicker() {
    ticker?.invalidate()
    // `.common`, not `.default`: a `.default` timer starves while the List scrolls, which would
    // freeze an armed capture mid-scroll (RemapPlayerView.swift:430-434).
    let timer = Timer(timeInterval: Self.captureTickInterval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.pollCapture() }
    }
    RunLoop.main.add(timer, forMode: .common)
    ticker = timer
  }

  private func endCapture() {
    ticker?.invalidate()
    ticker = nil
    capture = nil
    state.armedControlID = nil
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass, then the gates**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/PlayerScreenViewModelTests"`
Expected: `Executed 34 tests, with 0 failures`.
Then: `make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` and `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice.
If the compiler reports `call to main actor-isolated … in a synchronous nonisolated context` inside a closure, wrap only that call in `MainActor.assumeIsolated { … }`. Every such closure runs on the main thread.

- [ ] **Step 5: Commit**

```bash
git add Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenViewModel.swift \
  Source/iOS/App/DolphiniOSTests/PlayerScreenViewModelTests.swift
git commit -m "feat(controllers): player screen view model"
```

---

### Task 13: The emulation screen only touches the touch slot's IMU pointer

**Files:**
- Modify: `Source/iOS/App/Common/Swift/EmulationScreen.swift:1033-1037` (the `isTouchControlsActive` `onChange`) and `:1083-1088` (the Wii boot path in `onAppear`)

**Interfaces:**
- Consumes: `ControllerManager.touchscreenSlot(system:)` (returns nil when no active Wii Remote is on the Touchscreen, `ControllerManager.swift:360-375`); `TVEmulationBridge.setWiiIMUPointEnabled(_:forWiimote:)`.
- Produces: with no touchscreen Wii Remote, the emulation screen leaves every Wii Remote's IMU pointer alone, so decision 12's re-enable for a gyro pad survives a Wii boot and an overlay show/hide. With a touchscreen slot, nothing changes.

There is no unit test. Both sites are inside `EmulationScreen`'s SwiftUI modifiers, and `touchscreenSlot` reads the live config through `DOLConfigBridge` and `TVControllerMappingBridge`, so there is no pure seam to test. Device checklist item 13 covers it.

These are the only two `setWiiIMUPointEnabled` calls in the app (`git grep -n setWiiIMUPointEnabled -- '*.swift' '*.m' '*.mm'` lists only `EmulationScreen.swift:1036` and `:1088`). Nothing else re-disables a pad's pointer:
- The comment's "the Wii pad's own onAppear / onDisappear" no longer calls it.
- `DisableCoreIMUPointerOnTouchscreenWiimotes` (`EmulationCoordinator.mm:1501-1525`) skips any Wii Remote not bound to a Touchscreen.

- [ ] **Step 1: Guard the overlay show/hide switch**

In `EmulationScreen.swift`, replace
```swift
    .onChange(of: isTouchControlsActive) { active in
      guard isWiiSystem else { return }
      let touchSlot = controllerManager.touchscreenSlot(system: .wii) ?? 0
      TVEmulationBridge.setWiiIMUPointEnabled(!active, forWiimote: touchSlot)
    }
```
with
```swift
    .onChange(of: isTouchControlsActive) { active in
      // No touchscreen Wii Remote: the overlay drives no pointer, so there is nothing to keep from
      // fighting. `?? 0` used to flip Wii Remote 1's IMU pointer here even when a gyro pad owns it
      // (controller hub decision 12).
      guard isWiiSystem, let touchSlot = controllerManager.touchscreenSlot(system: .wii) else { return }
      TVEmulationBridge.setWiiIMUPointEnabled(!active, forWiimote: touchSlot)
    }
```

- [ ] **Step 2: Guard the Wii boot path**

In `EmulationScreen.swift`, in `onAppear`'s Wii setup, replace
```swift
      // the core fold the phone's real tilt into the IR transform on top of the app's pointer,
      // which is the "touch pointer stopped working" report. The Wii pad's own onAppear /
      // onDisappear (false / true) remains the single runtime owner of this flag.
      // Target whichever Wii Remote the overlay is actually bound to, not always slot 0.
      let imuTouchSlot = controllerManager.touchscreenSlot(system: .wii) ?? 0
      TVEmulationBridge.setWiiIMUPointEnabled(false, forWiimote: imuTouchSlot)
```
with
```swift
      // the core fold the phone's real tilt into the IR transform on top of the app's pointer,
      // which is the "touch pointer stopped working" report. The `isTouchControlsActive` onChange
      // below is the runtime owner of this flag afterwards.
      // Target whichever Wii Remote the overlay is actually bound to, and none when no Wii Remote is
      // on the Touchscreen: `?? 0` used to switch a gyro pad's IMU pointer off on Wii Remote 1 at
      // every Wii boot (controller hub decision 12).
      if let imuTouchSlot = controllerManager.touchscreenSlot(system: .wii) {
        TVEmulationBridge.setWiiIMUPointEnabled(false, forWiimote: imuTouchSlot)
      }
```

- [ ] **Step 3: Check that no other site switches it**

Run: `git grep -n "setWiiIMUPointEnabled" -- 'Source/iOS/App/*.swift' 'Source/iOS/App/*.m' 'Source/iOS/App/*.mm'`
Expected:
- The two guarded calls in `EmulationScreen.swift`.
- The bridge's own definition in `TVEmulationBridge.mm`. That file is unchanged by this phase.

- [ ] **Step 4: Run the gates**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice.

- [ ] **Step 5: Commit**

```bash
git add Source/iOS/App/Common/Swift/EmulationScreen.swift
git commit -m "fix(input): leave a pad's Wii pointer on when no touch slot exists"
```

---

### Task 14: `PlayerScreenView`, and the hub's player rows push it

**Files:**
- Create: `Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenView.swift`
- Modify: `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubViewModel.swift:159-161` (`playerDestination`)

**Interfaces:**
- Consumes: `MenuModal` (unchanged); Task 9's `PlayerScreenModelBuilder.make`; Task 8's `PlayerSlot.title`; Task 12's `PlayerScreenViewModel` and `PlayerPrompt`.
- Produces: `struct PlayerScreenView: View`, `init(slot: PlayerSlot)`. `ControllerHubActions.playerDestination` now returns it for every player row.

There is no unit test: this is a SwiftUI host with no pure seam. The prompt logic it delegates to (`confirmPrompt` / `cancelPrompt`), its first-render read (`displayState`) and its Back guard (`isCaptureSettling`) are covered in Task 12. The device checklist (Task 16) covers the host itself.

- [ ] **Step 1: Write the host**

`Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenView.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One player's controller screen (controller hub spec, "Player screen"), pushed from the hub's
/// player rows in place of `RemapPlayerView`. It hosts `PlayerScreenModelBuilder`'s model in a
/// `MenuScreen`, and everything below it pushes. Its only presentation is ONE alert, driven by the
/// view model's prompt and attached here, outside the List. A controller answers it through
/// `MenuScreen`'s `modal:`.
@MainActor
struct PlayerScreenView: View {
  @State private var viewModel: PlayerScreenViewModel
  /// The last non-nil prompt, kept while the alert animates out after `viewModel.prompt` clears, so
  /// its title (which `presenting:` does not scope) and message never blank.
  @State private var shownPrompt: PlayerPrompt?
  @Environment(\.dismiss) private var dismiss

  init(slot: PlayerSlot) {
    _viewModel = State(initialValue: PlayerScreenViewModel(slot: slot))
  }

  var body: some View {
    // The live prompt while there is one; the retained one while the alert closes.
    let alertPrompt = viewModel.prompt ?? shownPrompt
    MenuScreen(
      // `displayState`, not `state`: the first render (and tvOS's default focus) must not see the
      // empty snapshot that `start()` has not replaced yet.
      model: PlayerScreenModelBuilder.make(state: viewModel.displayState, actions: viewModel.actions, platform: .current),
      style: .list,
      onBack: {
        // While a capture is armed, B / Menu must reach the capture (so `Button B` stays bindable);
        // the 5 s timeout or the armed row cancels it. Just after a capture binds B, the same press
        // must not pop the screen either.
        if !viewModel.displayState.isCapturing && !viewModel.isCaptureSettling { dismiss() }
      },
      modal: modal)
      .navigationTitle(viewModel.slot.title)
      .alert(alertPrompt?.title ?? "", isPresented: isPromptShown, presenting: alertPrompt) { prompt in
        promptActions(prompt)
      } message: { prompt in
        Text(prompt.message)
      }
      .onChange(of: viewModel.prompt) { _, prompt in
        if let prompt { shownPrompt = prompt }
      }
      // A pushed list or editor covers this screen: stop on disappear, reload on the way back.
      .onAppear { viewModel.start() }
      .onDisappear { viewModel.stop() }
  }

  /// Shown while there is a prompt. An alert's own button runs `confirmPrompt` / `cancelPrompt`
  /// before SwiftUI sets this to false; the setter then cancels only the prompt this render showed,
  /// so a follow-up prompt (Replace, the save error), which arrives one main-actor hop later, is
  /// never cleared by the closing alert.
  private var isPromptShown: Binding<Bool> {
    let current = viewModel.prompt
    return Binding(
      get: { viewModel.prompt != nil },
      set: { if !$0, viewModel.prompt == current { viewModel.cancelPrompt() } })
  }

  @ViewBuilder
  private func promptActions(_ prompt: PlayerPrompt) -> some View {
    switch prompt {
    case .saveAs:
      // Prefilled (`openSavePrompt`), so a pad can save with A without typing.
      TextField(L("Name"), text: $viewModel.saveName)
      Button(L("Save")) { viewModel.confirmPrompt() }
      Button(L("Cancel"), role: .cancel) { viewModel.cancelPrompt() }
    case .confirmOverwrite, .confirmBuiltIn:
      Button(L("Replace"), role: .destructive) { viewModel.confirmPrompt() }
      Button(L("Cancel"), role: .cancel) { viewModel.cancelPrompt() }
    case .confirmReset:
      Button(L("Reset"), role: .destructive) { viewModel.confirmPrompt() }
      Button(L("Cancel"), role: .cancel) { viewModel.cancelPrompt() }
    case .saveFailed:
      Button(L("OK"), role: .cancel) { viewModel.cancelPrompt() }
    }
  }

  /// iOS controller input while something sits over the rows:
  /// - Any prompt: A confirms, B cancels (`MenuModal`).
  /// - An armed capture: the rows freeze and A/B do nothing to the menu, so the capture can bind
  ///   them. The latches keep tracking the pad, so the captured press never replays onto a row.
  private var modal: MenuModal? {
    if viewModel.prompt != nil {
      return MenuModal(onConfirm: { viewModel.confirmPrompt() }, onCancel: { viewModel.cancelPrompt() })
    }
    if viewModel.displayState.isCapturing {
      return MenuModal(onConfirm: {}, onCancel: {})
    }
    return nil
  }
}
```

- [ ] **Step 2: Push it from the hub**

In `ControllerHubViewModel.swift`, `actions`, replace
```swift
      playerDestination: { player in
        AnyView(RemapPlayerView(isGC: player.kind == .gameCube, portOneBased: player.port))
      },
```
with
```swift
      playerDestination: { player in
        AnyView(PlayerScreenView(slot: PlayerSlot(kind: player.kind, port: player.port)))
      },
```

- [ ] **Step 3: Check that `RemapPlayerView` is now only reached from dead code**

Run: `git grep -n "RemapPlayerView(" -- 'Source/iOS/App/*.swift'`
Expected: only `Source/iOS/App/Common/Swift/Controllers/ControllerSetupView.swift` lines 134, 212 and 242. `ControllerSetupView` has had no callers since Phase 2 Task 8, and Phase 4 deletes both files.

- [ ] **Step 4: Generate and run the gates**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice.

- [ ] **Step 5: Smoke-test in the simulator**

Run the Debug app in the iPhone 17 Pro simulator from Xcode. (`make dev` only generates and opens the workspace; it builds nothing.)

Open Settings → Controllers, then a player row (Show All Ports first if every port is unbound). Expected:
- The first frame already shows the port's device and its Buttons sections (or the hint row), never an empty list.
- Device pushes a list, and picking a row pops back.
- Show Advanced lists the stick dead zones.
- Back returns to the hub.

This is a smoke test only; Task 16's device checklist is the real gate.

- [ ] **Step 6: Commit**

```bash
git add Source/iOS/App/Common/Swift/Controllers/Player/PlayerScreenView.swift \
  Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubViewModel.swift
git commit -m "feat(controllers): the hub's player rows push the player screen"
```

---

### Task 15: Localize the Phase 3 strings

`L()` reads the `Core` table (`Common/Swift/Localized.swift`). The "Update Core Strings" build pre-script (`Project.swift`, `Project/Scripts/UpdateCoreStrings.py`) merges `Languages/po/<lang>.po` into `<lang>.lproj/Core.strings`, and it preserves keys the `.po` does not have. App-only strings are therefore added as identity entries. `Project/Scripts/check_localized_keys.py` is the audit. Japanese entries stay English until translated.

**Files:**
- Modify: `Source/iOS/App/Common/UI/Localization/en.lproj/Core.strings`
- Modify: `Source/iOS/App/Common/UI/Localization/ja.lproj/Core.strings`

**Interfaces:**
- Consumes: every `L("…")` key added by Tasks 1–14.
- Produces: `python3 Source/iOS/App/Project/Scripts/check_localized_keys.py --check` exits 0.

- [ ] **Step 1: See what is missing**

Run: `python3 Source/iOS/App/Project/Scripts/check_localized_keys.py`
Expected: a "Missing from en.lproj/Core.strings" list holding the 52 keys below.
- While planning, every `L("…")` key in this plan's code was extracted and checked against `en.lproj/Core.strings` at `28f0e24fb6`. These 52 were missing.
- Every other key the new code uses already exists ("Device", "No Device", "Reset", "Extension: %@", "%@ (Disconnected)", "Recenter Pointer", …).
- New since the first draft: the alert strings (including "Replace the Built-In Profile?" and its message), the capture hints, "Current", the Device list, and Sensitivity for the gyro pointer.
- If the script lists a key not in this block, add it too; if a key below is not listed, skip it.

- [ ] **Step 2: Append the identity entries to both tables**

Append these lines to the end of `en.lproj/Core.strings` AND of `ja.lproj/Core.strings`. Add no comments: the pre-script strips comments, so the committed form has none. `…`, `&` and the straight apostrophe are literal characters, exactly as in the Swift source.
```
"A profile named %@ already exists. Replace it?" = "A profile named %@ already exists. Replace it?";
"Aim with Controller Motion" = "Aim with Controller Motion";
"C-Stick %@" = "C-Stick %@";
"Choose a device to bind its buttons." = "Choose a device to bind its buttons.";
"Classic %@" = "Classic %@";
"Classic D-Pad %@" = "Classic D-Pad %@";
"Classic Left Stick %@" = "Classic Left Stick %@";
"Classic Right Stick %@" = "Classic Right Stick %@";
"Connect this controller to capture buttons." = "Connect this controller to capture buttons.";
"Control Stick %@" = "Control Stick %@";
"Current" = "Current";
"D-Pad %@" = "D-Pad %@";
"Edit the expression, then Save." = "Edit the expression, then Save.";
"Empty: saving unbinds this control." = "Empty: saving unbinds this control.";
"Expression" = "Expression";
"Face Buttons" = "Face Buttons";
"Hide Advanced" = "Hide Advanced";
"Invert X" = "Invert X";
"Invert Y" = "Invert Y";
"Load Profile" = "Load Profile";
"Load Profile…" = "Load Profile…";
"Loads %@ for this player and replaces its current buttons." = "Loads %@ for this player and replaces its current buttons.";
"Motion Pointer" = "Motion Pointer";
"Not saved: %@" = "Not saved: %@";
"Not saved: the expression does not parse." = "Not saved: the expression does not parse.";
"Nunchuk %@" = "Nunchuk %@";
"Nunchuk Shake %@" = "Nunchuk Shake %@";
"Nunchuk Stick %@" = "Nunchuk Stick %@";
"Nunchuk Swing %@" = "Nunchuk Swing %@";
"Nunchuk Tilt %@" = "Nunchuk Tilt %@";
"Pointer %@" = "Pointer %@";
"Pointer & Motion" = "Pointer & Motion";
"Profiles" = "Profiles";
"Raw Bindings" = "Raw Bindings";
"Replace" = "Replace";
"Replace Profile?" = "Replace Profile?";
"Replace the Built-In Profile?" = "Replace the Built-In Profile?";
"Reset to Default Profile?" = "Reset to Default Profile?";
"Revert" = "Revert";
"Rumble %@" = "Rumble %@";
"Sensitivity" = "Sensitivity";
"Set by an expression" = "Set by an expression";
"Shake %@" = "Shake %@";
"Shake to Wiggle" = "Shake to Wiggle";
"Shaking the device shakes the Wii Remote." = "Shaking the device shakes the Wii Remote.";
"Show Advanced" = "Show Advanced";
"Swing %@" = "Swing %@";
"The controller's gyro moves the Wii pointer." = "The controller's gyro moves the Wii pointer.";
"The expression is valid." = "The expression is valid.";
"Tilt %@" = "Tilt %@";
"Touchscreen controls are laid out by the on-screen overlay." = "Touchscreen controls are laid out by the on-screen overlay.";
"Your profile named %@ will be used instead of the built-in one whenever a device of this kind is first bound, and by Reset to Default Profile." = "Your profile named %@ will be used instead of the built-in one whenever a device of this kind is first bound, and by Reset to Default Profile.";
```
Before appending a key, check it is not already present, so no key is defined twice: `grep -c '^"<key>" = ' Source/iOS/App/Common/UI/Localization/en.lproj/Core.strings` must print `0`. A `.po` refresh may already have added some of these.

- [ ] **Step 3: Verify**

Run: `python3 Source/iOS/App/Project/Scripts/check_localized_keys.py --check; echo "exit $?"`
Expected: `Missing keys: 0` and `exit 0`.
Run: `plutil -lint Source/iOS/App/Common/UI/Localization/en.lproj/Core.strings Source/iOS/App/Common/UI/Localization/ja.lproj/Core.strings`
Expected: both `OK`.

- [ ] **Step 4: Build once, so the pre-script's merge is what you commit**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected:
- `** TEST SUCCEEDED **`. The builder tests compare English titles, which identity entries keep.
- `** BUILD SUCCEEDED **` twice.
- `git diff --stat -- Source/iOS/App/Common/UI/Localization` shows only the appended lines. Re-run Step 3 if the pre-script rewrote either file.

- [ ] **Step 5: Commit**

```bash
git add Source/iOS/App/Common/UI/Localization/en.lproj/Core.strings Source/iOS/App/Common/UI/Localization/ja.lproj/Core.strings
git commit -m "chore(l10n): catalogue the player screen strings"
```

---

### Task 16: Device checklist and handoff

**Files:**
- Create: `docs/handoff-2026-09-30-controller-hub-phase3.md`

- [ ] **Step 1: Write the handoff**

```markdown
# Controller Hub Phase 3 — handoff (2026-09-30)

Plan: docs/superpowers/plans/2026-09-30-controller-hub-phase3-player-screen.md
Spec: docs/superpowers/specs/2026-09-28-controller-hub-design.md

## Landed
<one line per task commit: SHA + subject, from `git log --oneline -15`>

## Merge order
Merge Phase 3 after, or together with, the separate assignment-rule fix for decision 13: a
Touchscreen → pad switch keeps the touchscreen mapping (the `hasMapping` condition from 3613078adb;
`ControllerHasAnyBoundControl` only tests for a non-empty expression). That change owns
ControllerAssignmentService.swift, TVControllerMappingBridge.{h,mm} and BridgeControllerConfigWriter.swift;
Phase 3 edits none of them. Checklist item 12 passes only with that fix on develop.

## Decisions worth knowing (signed off 2026-09-30)
- Ownership and plumbing:
  - The player screen owns its own view model. It reads PlayerState through the hub's
    ControllerHubReading and everything else through PlayerScreenIO.
  - Expression checks and numeric settings go through DOLControllerSettingsBridge, app-side. There
    was no core change and no prebuilt refresh.
- Device:
  - Device is a pushed list: one pick, one assignment, then pop.
  - The list refreshes itself while it is open, because the player screen stops observing when
    covered. `setDevice` re-reads before acting.
  - Binding a gyro pad to a Wii Remote turns its motion pointer (IMUIR Enabled) back on.
  - The emulation screen now switches the core IMU pointer only for a Wii Remote that is on the
    Touchscreen. It used to hit Wii Remote 1 whenever no slot was.
- Capture:
  - Rows are disabled, with a hint, on the Touchscreen, on No Device and on a disconnected MFi pad.
  - DSU-bound ports capture and never read "(Disconnected)".
  - For 0.5 s after a capture binds, the screen ignores activation and Back (`rearmDelay`).
- Pointer & Motion:
  - Touchscreen port: Touch – Follow / Touch – Drag / Gyro. There is no "Off".
  - Gyro pad port: one "Aim with Controller Motion" toggle.
  - Invert X / Invert Y show only in Gyro.
  - Sensitivity is the drag gain in Drag (programmatic overlay on), and the new gyro pointer
    sensitivity (`motion_gyro_pointer_sensitivity`, default 1.0) in Gyro.
- Profiles:
  - The current profile name is remembered for the app session only. It shows "Custom" when unknown.
  - Reset to Default Profile asks first.
  - Save As is prefilled with the pad name or the player title, never a built-in name.
  - Saving under a built-in name ("Physical Controller", "Touchscreen", "DSU") asks "Replace the
    Built-In Profile?" first. Saving over any other existing name asks "Replace Profile?".
  - All prompts share ONE alert.
- Commits carry no attribution trailer. The merge step strips any that slipped in; it does not
  reword commits to a model trailer.

## Device checklist

iPhone 16 Pro Max, with an Xbox pad, a DualSense, a DSU server, a Wii title with the touch overlay,
and a GameCube title:
1. From the pause menu, the top bar's Controller Settings… and Settings → Controllers, a player row
   pushes the player screen.
   - The first frame already shows the port's device and rows (never an empty list).
   - A GameCube port shows Device, Profile, Face Buttons / D-Pad / Sticks / Triggers / System and a
     collapsed Advanced.
   - Wii Remote 1 on the touchscreen also shows Wii Remote and Pointer & Motion.
   - A GameCube title shows no Wii sections.
2. With the pad:
   - The d-pad reaches every row, and the highlight scrolls with it.
   - A on a Buttons row arms it; this is the `.custom` activation.
   - B returns to the hub.
3. Capture with the pad:
   - Pressing B binds "B". The screen does not pop, neither on the press nor on the release.
   - Binding A: the row does not re-arm when A is released.
   - While armed, the d-pad does not move the highlight.
   - Leaving it idle 5 s puts the previous binding back.
4. Touch: tap arms, and a second tap cancels.
   - Long-press → Clear and swipe → Clear unbind a row.
   - On a row near the bottom of a freshly opened screen, scroll to it by hand: its menu appears at
     once.
   - If either gesture misbehaves, apply the plan's fallback: remove both modifiers. The editor's
     Clear stays.
5. Turn the pad off while a row is armed:
   - The capture ends. Device reads "<name> (Disconnected)". The capture rows are disabled, with the
     "Connect this controller…" hint. The binding is kept.
   - Turning the pad on restores everything.
6. Device pushes a list:
   - One pick assigns once and pops. Picking the current device only pops.
   - With a custom pad mapping, opening the list and pressing A or d-pad left/right changes nothing
     until a row is picked.
   - With the list open, turn the DualSense on: it appears in the list without leaving it. Picking it
     assigns it.
7. The Touchscreen makes the rows read "On-screen …" and shows the hint; the capture rows are disabled.
   No Device shows its hint and turns the port off in the hub.
8. A port bound to a DSU device shows the device's name, never "(Disconnected)", and captures a DSU
   button.
9. Profile, all through the one alert:
   - Load Profile… pushes at once. A pick pops back, and the row's subtitle shows the name.
   - Save Profile As… opens prefilled with the pad's name; A saves and B cancels.
   - An existing name asks "Replace Profile?". After Save closes, the follow-up appears with its own
     title and message, and neither blanks while it animates.
   - "touchscreen" asks "Replace the Built-In Profile?". Confirm, then bind a fresh pad to a port
     with no mapping: the saved Touchscreen profile is used instead of the built-in one. Delete the
     file afterwards.
   - After a capture the subtitle reads "(edited)".
10. Reset to Default Profile asks first. A confirms. B (or Cancel) leaves the mapping unchanged.
11. Wii: Extension → Classic adds Classic rows under Face Buttons, D-Pad, Sticks, Triggers and System.
    Sideways toggles.
12. Wii Remote 1, switched from the Touchscreen to the DualSense, then a Wii title is booted.
    - Expected to PASS once the separate decision-13 fix is on develop: the pad's buttons work, its
      gyro aims, and "Aim with Controller Motion" reads On.
    - Without that fix it fails: the pad's buttons, sticks and gyro do nothing until Reset to Default
      Profile, because the kept touchscreen mapping binds `Button 0` / `Axis 6xx`.
13. A gyro pad on Wii Remote 1 survives a boot (Task 13):
    - Bind the DualSense to Wii Remote 1, with the Touchscreen on no Wii Remote, and turn
      "Aim with Controller Motion" On.
    - Boot a Wii title: the toggle still reads On (reopen the player screen to check) and the pad
      aims.
    - Show and hide the on-screen controls: it still aims.
14. Pointer & Motion on Wii Remote 1 (touchscreen), in a game:
    - Follow / Drag / Gyro changes the live pointer.
    - Gyro adds Sensitivity (×0.5–×3), which changes the pointer's speed at once (no restart), plus
      Invert X / Invert Y.
    - Recenter Pointer recenters.
    - Drag, with the programmatic overlay on, adds its own Sensitivity.
    - Shake to Wiggle off stops a device shake reaching the game.
15. Gyro pads:
    - A DualSense on Wii Remote 2 shows only "Aim with Controller Motion". Off stops its gyro moving
      the pointer; on brings it back.
    - An Xbox pad (no gyro) shows no Pointer & Motion.
16. Advanced:
    - Show Advanced lists the stick and trigger settings. D-pad left/right steps Dead Zone one step
      per press.
    - In Raw Bindings, typing "(" shows "Not saved: …" and disables Save.
    - A valid edit saves and pops.
    - Clear in the editor unbinds the control; this is the pad's path.
17. Pad Back, the Phase 2 gap: A on More Controller Settings, Motion Source (DSU) and Edit Layout
    pushes each one, and B pops it.
18. Nothing needs a scroll to present. From a fresh, unscrolled player screen, these appear at once:
    - Device.
    - Load Profile….
    - The last Raw Bindings row, after Show Advanced.
    - Each prompt.

Apple TV, with a Siri Remote and a pad, on a Wii title:
19. The player screen pushes from the pause pane and from Settings.
    - Focus starts on the Device row, so default focus is set on the first frame.
    - Focus reaches every row, including "Extension: None / Nunchuk / Classic".
    - The Device list has no Touchscreen, and there is no Pointer & Motion.
    - Menu from any depth pops one level.
20. Each Advanced numeric setting is ONE row. Left/right on the Siri Remote and on a pad's d-pad
    steps its value; select does nothing.
21. Up/down leave a compact row normally; focus is never trapped. If item 20 or 21 fails, apply the
    plan's fallback: drop `isCompactOnTV`, so the rows explode into one row per option.
22. Capture:
    - Selecting a Buttons row then pressing a pad button binds it.
    - Menu (or B) while armed binds B and does not pop, neither on the press nor on the release.
    - Binding A does not re-arm the row.
    - Focus stays on the armed row.
23. A long press of select on a capture row shows Clear, and Clear unbinds the row.
24. Save Profile As… shows a prefilled text field in the one alert (tvOS keyboard).
    - The Replace and Replace-built-in follow-ups appear after it closes, and can be answered with
      the remote.
25. The raw-binding editor's field opens the keyboard. A parse error shows inline, and Save is
    disabled. Clear works.
26. Device and Load Profile lists: they are not empty on the first frame, focus lands on the first
    row, and select picks and pops. A pad turned on while the Device list is open appears in it.

## Known gaps
- No pad Back on screens pushed from inside More or DSU (Add DSU Server, Analog Stick Settings,
  Advanced Motion Settings, Edit IR Area, Touch IR Pointer); use touch there.
- The hub's own player row still reads "(Disconnected)" for a DSU-bound port
  (ControllerHubModelBuilder.deviceName). The player screen does not; align the hub in Phase 4.
- Decision 13 (Touchscreen → pad keeps the touchscreen mapping) is confirmed and fixed by a separate
  change to the assignment rule, not by Phase 3. Until it lands, checklist item 12 fails as described.
- One alert serves every prompt. If a follow-up prompt ever fails to appear after the previous one
  closes (checklist items 9 and 24), the cause is SwiftUI re-presenting the same `.alert` too soon:
  - The plan keeps the one-main-actor-hop gap.
  - The next step would be a longer gap, or presenting the follow-up from the alert's dismissal.

## Next (Phase 4)
- Delete:
  - `ControllerSetupView.swift`, which has had no callers since Phase 2.
  - `RemapPlayerView.swift`, which is NEW on the list: its only caller is ControllerSetupView. Keep
    `RemapModel.swift`; the player screen uses it.
- Take `EnhancedMotionControlsView` (Advanced Motion Settings) OFF the delete list (decision 6). These
  options have no other home yet:
  - Horizontal Movement (roll / yaw).
  - Enable 6DOF Motion Controls.
  - Wiimote Motion Controls and Nunchuck Motion Controls.
  - Apply Recommended Settings.
- `ControllerMoreSettingsView` rows the player screen makes redundant:
  - Touch IR Pointer (`TouchIRModePicker`, with `TouchIRMode` in ControllersRootView.swift), replaced
    by Pointer.
  - Pointer Sensitivity, replaced by Sensitivity in Touch – Drag.
  - Advanced Motion Settings stays, per decision 6.
  - Analog Stick Settings (`dsu_*`) stays. It is the app's on-screen stick processing, not Dolphin's
    dead zones.
- Carry forward the naming question (decision 8): "On-Screen Style" (hub) vs "Overlay Style" (More).
- Move `MotionDebugView` behind DEBUG.
- Merging: strip any attribution trailer. Do not reword commits to a model trailer.
```
Fill in the "Landed" lines from `git log --oneline -15`.

- [ ] **Step 2: Commit**

```bash
git add docs/handoff-2026-09-30-controller-hub-phase3.md
git commit -m "docs: controller hub phase 3 handoff and device checklist"
```

---

## Self-review against the spec

| Spec requirement (Phase 3 scope) | Where |
|---|---|
| `PlayerScreenModelBuilder`, pure: state + actions struct in, `MenuModel` out, no bridge calls | Task 9 |
| `PlayerState` filled by the view model that touches the bridges; hub rows push the player screen instead of `RemapPlayerView` | Tasks 11, 12, 14 (decision 1) |
| Device: None / Touchscreen (iOS) / each connected pad | Task 9 (`deviceOptions`), Task 10 (`DeviceListView`, self-refreshing), Task 12 (`setDevice`, fresh read); decision 9 |
| Profile: current name, Load, Save As… via `MenuModal`, Reset to Default | Tasks 8 (`ProfileNaming`), 10 (`ProfileListView`), 12 (prompts, `PlayerPrompt.title`/`message`), 14 (one alert + `modal:`); decision 10 |
| Wii only: Extension (None / Nunchuk / Classic), Sideways | Task 9 (`wiiSection`), Task 12 |
| Buttons: one row per control, Face / D-Pad / Sticks / Triggers / System / Motion, `BindingDisplay` text, capture via `RemapCaptureMachine` as `.custom` rows | Task 7 (`ControlCategory`), Task 8 (`CaptureRowView`), Task 9, Task 12 (capture session), Task 2 (pad A on `.custom`) |
| Pointer & Motion: Wii, touchscreen or motion-capable pad; Pointer, Recenter, Sensitivity, Invert X/Y, Shake | Tasks 6, 9, 11, 12, 13 (pad pointer survives boot); decisions 2, 3, 4, 7 (Invert only in Gyro, signed off), 12 |
| Advanced, collapsed by default: dead zones, stick ranges, IR/IMU values, raw expressions as editable text | Tasks 5, 7, 9, 10, 12 |
| Edge case: a parse error is shown inline and not saved | Task 5 (bridge + `ExpressionCheck`), Task 10 (editor), Task 12 (`saveExpression` backstop) |
| Edge case: pad disconnects (Device "Disconnected", armed capture cancels, binding kept) | Task 8 (`isDisconnected`, MFi only), Task 9 (summary, hint), Task 12 (`reload` cancels) |
| Edge case: capture times out (previous binding) | Task 12 (`pollCapture`, test) |
| Edge case: tvOS (no Touchscreen, no Pointer & Motion, every row one focus target, no `Menu`, no `.borderless`) | Task 3 (compact picker), Task 9 (platform branches, "Extension: …" labels), Task 10 (pushed lists) |
| Edge case: GameCube title has no Wii sections | Task 9 (kind-based sections, test) |
| Device and profile changes use `reconcile(autoAssign: false)` | Task 11 (`LivePlayerScreenIO.setDevice` / `loadProfile`) |
| Everything below the hub is a push; no sheet in a List/Section or in a sheet | Tasks 10, 14; the single alert sits on the host |
| Engine: pad-navigable both ways | Tasks 1, 2, 3, 4; Task 14 (`onBack`) |
| Tests: `PlayerScreenModelBuilder` sections per system and device, Advanced collapsed, Pointer & Motion only where it applies | Task 9 (28 tests) |
| Tests: new pure units, the view model through the seams | Tasks 2, 3, 5, 6, 7, 8, 10, 11, 12 (34 view-model tests) |
| Existing tests keep passing; `make test` + `make gate-release` every task | Every task's gate step |
| Device checklist (iPhone 16 Pro Max + Apple TV) | Task 16 (items 1–26) |

Open items from the Phase 3 start handoff:
1. iOS pad-Back gap: Task 4. The modifier is engine-level and applied per destination, which closes Phase 2's gap; nested pushes stay touch-only.
2. A plus d-pad double-step: Task 1, guarded in the router and tested.
3. `RemapPlayerView`'s double `DeviceFamily.from`: moot. The view is superseded (Task 14), and Task 16 lists it for Phase 4's deletion.
4. The hub's actions have no writer seam: the player gets `PlayerScreenIO` (Task 11); the hub is left alone.
5. Notification-name literals: only new posters use the declared name (Task 6).
6. Naming: deferred to Phase 4 (decision 8).

Placeholder scan: no "TBD", "TODO" or "similar to Task N". Every code step has full code, and every run step has its command and expected result. The only fill-in is the handoff's "Landed" list, which can only exist after the commits.

Type consistency, checked across the renumbered tasks:
- `PlayerScreenActions` has 19 closures, with the same names in Task 8, the Task 9 builder test and the Task 12 view model.
- `PlayerScreenIO` has 25 members, the same in Task 11, the Task 12 `FakeIO` and `LivePlayerScreenIO`. That includes `setGyroSensitivity`.
- `PlayerDeviceChoice.noDevice/.touchscreen/.pad`; `DeviceOption(choice:title:)`.
- `ConnectedPadState.hasGyro`, the same in Task 8, the tests and the live reader.
- `PointerMotionState.snapped(_:to:)`, `gyroSensitivityChoices` and `dragGainChoices`.
- `PlayerPrompt` (five cases incl. `confirmBuiltIn`, `title`, `message`); `ProfileNaming.sanitized/isBuiltIn/suggestion/exists`.
- `DeviceListView(options:current:refresh:onPick:)`, the same in Task 10 and the Task 12 view model.
- `MenuItem(… isEnabled:onCustomActivate:isCompactOnTV:)`; `MenuItemRole.selectedTitle`.
- `MotionSettings.gyroPointerSensitivity` / `setGyroPointerSensitivity`; `TCDeviceMotion.gyroPointerOffsets(…, gain:)`.
- `AdvancedSettingGroups.imuPointGroup`.

Decision 13 (Touchscreen → pad keeps the touch mapping) is out of this phase by owner ruling: a separate assignment-rule change fixes it, and no task edits `ControllerAssignmentService.swift`, `TVControllerMappingBridge.{h,mm}` or `BridgeControllerConfigWriter.swift` (checked: no Files entry names them).

Out of this phase by the spec: deleting `ControllerSetupView`, `RemapPlayerView` and the extra pointer pickers, and moving `MotionDebugView` behind DEBUG (Phase 4). `EnhancedMotionControlsView` stays (decision 6).
