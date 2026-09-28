# Controller Hub — one controller UI for every entry point

Date: 2026-09-28. Status: approved design, not yet planned.
Builds on: `2026-09-24-data-driven-menus-design.md` (D18 menu engine) and
`2026-09-24-remap-ui-design.md` (remap capture, landed as `RemapPlayerView`).

## Problem

Controller configuration is spread over screens that disagree with each other:

- The pause menu's Controllers pane and Settings → Controllers are different UIs with
  different features. Touch overlay editing, motion settings and DSU exist only in Settings.
- Pointer mode is set in three places (top bar, Settings, Advanced Motion Settings), each with
  its own options and labels.
- Motion settings have three sets of conflicting defaults (`EnhancedMotionControlsView`,
  `MotionDebugView`, `TCDeviceMotion`). None are registered at launch.
- The top bar's "Motion Controls" opens `MotionDebugView`, a developer tool.
- The remap screen shows raw Dolphin expressions (`` `Button A` ``) and internal group names
  ("Options", "Rumble").
- On both platforms, "Profiles…" and "Customize Buttons…" do not present until the list is
  scrolled. The `.sheet`s are attached to a `Section` inside a lazy `List`
  (`ControllerSetupView.swift`, the "Connected Controllers" section).
- The top-bar controls are SwiftUI `Menu`s, which have no usable tvOS presentation.

The goal is one controller UI, reached from the pause menu, from Settings and from the top
bar, that a first-time player can use without reading anything and a power user can take all
the way down to raw bindings.

## Decisions

| Question | Decision |
|---|---|
| Organizing principle | By player: one row per port, with everything for that player behind it |
| Top bar | A slim in-game menu: pointer mode, Recenter Pointer, show/hide on-screen controls, Controller Settings… |
| Novice vs expert | Progressive disclosure: a collapsed **Advanced** section at the bottom of each player screen |
| Implementation | On the D18 menu engine (`MenuModel` / `MenuScreen`), not hand-built SwiftUI lists |

## Screens

### Controllers hub

The same screen from the pause menu, Settings and the top bar.

1. **Players.** One row per active port, showing the port, the bound device and the emulated
   controller, for example "Player 1 · Xbox Wireless Controller · GameCube Pad". A Wii title
   lists Wii Remotes 1–4, with their extension, and GameCube ports 1–4. Ports with no device
   bound are collapsed under "Show all ports".
2. **On-Screen Controls** (iOS only). Show/hide, edit layout (opens the existing layout
   editor), opacity. These are shared by all players, so they are not per-player.
3. **Connected Devices.** Paired pads with battery state, continuous Wii Remote scanning, and
   the DSU motion source.
4. **Help.** One line per action, for example "Pause: View / Share / ⌂ button · Hold 2 s to
   exit". It is generated from the same routing table `PauseGestureTracker` documents.

### Player screen

One per port, pushed from the hub.

1. **Device.** A picker: None / Touchscreen (iOS) / each connected pad.
2. **Profile.** The current profile's name, then Load, Save As… and Reset to Default.
3. **Wii only.** Extension (None / Nunchuk / Classic) and Sideways.
4. **Buttons.** One row per control, grouped Face / D-Pad / Sticks / Triggers / System /
   Motion. Each row shows a friendly control name and the bound input as a glyph ("A",
   "Left Stick ↑"). Tapping a row arms "press a button now" capture (existing
   `RemapCaptureMachine`).
5. **Pointer & Motion.** Wii players only, on the port bound to the touchscreen or a
   motion-capable pad. Pointer (Touch-Follow / Touch-Drag / Gyro / Off), Recenter Pointer,
   Sensitivity, Invert X / Invert Y, Shake to Wiggle.
6. **Advanced** (collapsed by default). Dead zones, stick ranges, IR/IMU values, and each
   binding's raw Dolphin expression as editable text.

### Top bar (iOS emulation screen)

Pointer mode, Recenter Pointer, Show/Hide On-Screen Controls, Controller Settings… (opens the
hub). Nothing else controller-related stays in the top bar.

### Removed or moved

- `MotionDebugView` moves behind `#if DEBUG`; no user-facing menu opens it.
- `EnhancedMotionControlsView` folds into Pointer & Motion.
- The extra pointer-mode pickers go; pointer mode is set in exactly one place.

## Architecture

Mirrors the pause-menu and Cheats split already on the engine: snapshot, pure builder,
actions.

- **`ControllerHubViewModel`** (`@Observable`). Reads the bridges once into plain snapshot
  structs, `ControllerHubState` and `PlayerState`: port assignments, connected pads, profiles,
  Wii extension and sideways, pointer mode, motion settings. It rebuilds the snapshot on
  `ControllerManager.assignmentsChanged` and on `GCController` connect/disconnect. It is the
  only unit that touches `ControllerManager`, `TVControllerMappingBridge`, `DOLConfigBridge`
  and `GCController`.
- **`ControllerHubModelBuilder`, `PlayerScreenModelBuilder`** (pure). State plus an actions
  struct in, `MenuModel` out. They use `.navigation` to push sub-screens, `.picker` for
  Device / Extension / Pointer, `.toggle` for switches, and `.custom` for capture rows, which
  host the existing capture UI backed by `RemapModel` / `RemapCaptureMachine`. No bridge calls
  inside builders.
- **Actions.** Closures that call the existing bridge methods. Device and profile changes use
  `ControllerManager.reconcile(autoAssign: false)`, so changing one port never re-assigns the
  others. No core changes.
- **`BindingDisplay`** (pure). Turns a Dolphin control expression plus the bound device's
  family (Xbox / PlayStation / Switch / generic MFi / touchscreen) into display text:
  `` `Button A` `` shows "A" on Xbox and "✕" on DualSense. An expression it cannot reduce to
  one input falls back to the raw text.
- **`PointerModeController`**. The one place pointer mode changes. It writes
  `MAIN_TOUCH_PAD_IR_MODE` and updates the live touch IR pad. The hub and the top bar both call
  it. `TCDeviceMotion` already recenters the gyro pointer when the mode switches into gyro
  (`f24ca8741b`).
- **`MotionSettings`**. Typed properties over the existing `UserDefaults` keys
  (`motion_use_yaw_for_horizontal`, `motion_invert_roll`, `motion_invert_pitch`,
  `motion_enhanced_shake_detection`, `motion_enable_full_6dof`, `touch_overlay_ir_pointer_gain`,
  `dsu_*`). `MotionSettings.registerDefaults()` calls `UserDefaults.register(defaults:)` on
  every launch from `AppDelegate`, next to `SentryTelemetryService.configure()`. Registered
  defaults are not persisted, so this cannot live in the first-run-only
  `FirstRunInitializationService`. Both `TCDeviceMotion` and the UI read `MotionSettings`, and
  the key names do not change, so existing user values carry over.

### Presentation

- iOS. The hub is a `MenuScreen` in a `NavigationStack`. It is presented as a sheet from the
  pause menu and from the top bar, and pushed from Settings.
- tvOS. The same view, pushed from the pause menu pane and from Settings.
- Everything below the hub is a push. Save Profile As… uses `MenuModal`. No sheet is attached
  inside a `List`/`Section` or presented from inside another sheet; that removes the root cause
  of both the scroll-to-present lockup and the tvOS remap bounce fixed in `e569588f4b`.

### Engine work required

From the D18 round-3 notes:

- Scroll-to-focus in `.list` style, so controller focus on a row below the fold scrolls it
  into view.
- D-pad left/right on a focused `.picker` row cycles its options in place.

## Edge cases

- **A pad disconnects while its player screen is open.** The Device row shows "Disconnected"
  and an armed capture cancels. The binding is kept, and reconnecting restores it.
- **An Advanced expression does not parse.** Show the parser's error inline and do not save.
  Dolphin's `ControlReference::SetExpression` installs a syntactically broken expression
  without complaint, so the check has to happen in the UI.
- **Capture times out.** The row returns to its previous binding (existing behaviour).
- **tvOS.** No Touchscreen device option, no Pointer & Motion section and no On-Screen
  Controls section. Every row is its own focus target, per the engine; no `Menu` and no
  `.buttonStyle(.borderless)`.
- **GameCube title.** Only GameCube ports, no Wii sections.

## Testing

- Unit tests:
  - `ControllerHubModelBuilder`: rows per system, "Show all ports" collapsing, platform
    differences.
  - `PlayerScreenModelBuilder`: sections per system and device; Advanced collapsed by
    default; Pointer & Motion only where it applies.
  - `BindingDisplay`: Xbox, PlayStation, Switch and MFi glyphs, touchscreen, and the raw
    fallback.
  - `MotionSettings`: defaults.
  - `PointerModeController`: writes and notifications.
- The existing `RemapModelTests`, `PauseMenuModelBuilderTests` and menu-engine tests keep
  passing.
- Every phase passes `make test`, and `make gate-release` for iOS and tvOS.
- Device checklist per phase, on the iPhone 16 Pro Max and the Apple TV: focus reaches every
  row, capture binds on a real pad, nothing needs a scroll to present, and Back from any
  depth returns one level.

## Delivery phases

Each phase leaves the app working.

1. **Foundation.** `MotionSettings` with its defaults registered on every launch, `PointerModeController`,
   `BindingDisplay`, the two engine gaps, and the slim top bar.
2. **Hub.** `ControllerHubViewModel`, `ControllerHubModelBuilder`, and the hub wired into the
   pause menu, Settings and the top bar. After this phase the pause-menu and Settings controller
   screens are the same screen.
3. **Player screen.** `PlayerScreenModelBuilder`, covering device, profile, the Wii rows,
   capture rows hosting the existing capture UI, Pointer & Motion, and Advanced.
4. **Removal.** Delete `ControllerSetupView` and the parts of `ControllersRootView` the hub
   replaces. Delete `EnhancedMotionControlsView` and the extra pointer-mode pickers. Move
   `MotionDebugView` behind DEBUG.

## Out of scope

- DualSense-specific options (touchpad-as-pointer tuning, adaptive triggers, haptics).
- Per-game controller overrides.
- A redesign of the on-screen overlay layout editor; the hub links to the existing one.
