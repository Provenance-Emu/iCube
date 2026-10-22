# Plan: Siri Remote as a menu device, and labelled Wii pointer sources

Design: [2026-10-21-siri-remote-and-pointer-sources-design.md](../specs/2026-10-21-siri-remote-and-pointer-sources-design.md).
Branch `feature/siri-remote-pointer-sources`, cut from develop `f956238716`.

## Owner direction (2026-10-22)

"Finish the … pause menu and controller stuff, the siri remote on tv as wii ir cursor options."
No CI runner: every gate is local. The five open questions in the design are taken at the
design's proposed defaults (listed under "Calls" below).

## Baseline (develop f956238716, before any change)

- tvOS Debug simulator build: passes.
- Full iOS `iCubeTests`: 2,308 executed, 7 skipped, 0 failures.

## Phase 1 — the Siri Remote never takes a player slot (Swift only)

No C++ change: hiding the remote from the input backend would rebuild every core slice.

1. `GCController.isMenuRemote` (`micro != nil && extended == nil`); `LivePerformanceSession.isRemote` uses it.
2. `ControllerStateStore.State.menuRemoteQualifiers` (defaulted `var`), filled in `snapshot()`;
   `connectedQualifiers` excludes them. This feeds `decide`, `decideBoot`, `player1Takeover` and reconcile.
3. `AssignmentEngine.player1Takeover` refuses a remote qualifier.
4. `ControllerAssignmentService.reconcile` clears any GC/Wii slot whose device is a menu remote
   (a user who assigned the remote before this change still has it saved).
5. `ControllerManager`: `choosePlayer1`, `assign`, disconnect-restore and
   `updateWiimoteEmulationForExternalControllers` skip remotes.
6. Hub: `ConnectedPadState.isMenuRemote`; remotes become a caption row
   ("Siri Remote — menus and quick actions only"), never a Device option; "No controllers
   connected" counts gameplay pads only.
7. `ControllerGlyphs.detectGlyphSet` ignores remotes.
8. Tests: engine (decide/boot/takeover), service (persisted remote cleared), hub builder rows.

## Phase 2 — pointer source resolver and labelled pointer UI

1. `PointerSource` + pure `PointerSourceResolver.resolve(...)` with a table test per platform.
2. `PadCapabilities` (gyro, touchpad) on `ConnectedPadState`.
3. Hub pointer row and player screen show "Pointer: <source>" and only the applicable options;
   tvOS gains the row (today it has none, or an unlabelled gyro toggle).
4. Debug launch argument to fake capabilities, so the tvOS pointer UI can be screenshotted.

## Phase 3 — Siri Remote gyro as Wii Remote 1's pointer (tvOS)

Mechanism to be confirmed against the code before building (see "Mechanism" below), then:
pointer math lifted from `TCDeviceMotion` into a pure, tvOS-compiled function; app writes IR axes
for Wii Remote 1 from the remote's `GCMotion`; a recenter action; offered only when the remote
reports motion at runtime. On-device test owed (the simulator has no remote gyro).

## Phase 4 — no-controller notice (tvOS)

Once per boot, 3 s after the first frame, when no gameplay pad is connected: "No controller
connected. The Siri Remote only navigates menus." with Continue / Controllers.

## Calls (owner questions taken at the design's defaults)

1. Remote quick actions: none added beyond today's Menu (pause) and Menu-hold (exit).
2. No-controller notice: once per boot.
3. Touchpad pointer: absolute (profile-expressible); not part of this branch.
4. Plain pad on iOS: no phone-gyro pointer by default; offered as a choice.
5. "Aim with Controller Motion" stays as the pad-gyro entry, now labelled with the pad's name.

## Mechanism (verified against the code, 2026-10-22)

- **Bindings are not layered config.** They are `ControlReference` expressions plus each controller's
  default device, written whole by `InputConfig::SaveConfig` (every bridge assign/profile/expression
  call saves) and re-read from the INI at boot and on title change. The design's "CurrentRun only"
  binding is impossible, so the remote pointer binding is **persisted deliberately and removed
  deliberately**.
- **Binding:** Wii Remote 1's `IR/Up, Down, Left, Right` = `` `iOS/4/Touchscreen:Axis 112` ``..`115`
  (fully qualified, so it works while the slot's default device is the pad). Touchscreen device 4 always
  exists and is idle on tvOS. `RepairTouchscreenIRPointer` / `DisableCoreIMUPointerIfTouchscreen` only
  act when the slot's *default device* is the touchscreen, so they leave this alone.
- **Applier:** one function decides from the resolver: when the source is `.remoteGyro`, set those four
  expressions (after any profile load: `Physical Controller.ini` has no IR lines, so a load clears them);
  otherwise remove them **only if they are exactly these four expressions**, so a user's own IR binding is
  never touched. Run after reconcile/assign/profile load and at boot.
- **Trap:** a bound IR row makes `mappingBindsDevice` true, which makes `assign()` skip the default pad
  profile. Apply the pointer binding after the pad profile, never before.
- **Pointer math:** the remote's attitude frame is unverified and `GCMotion.attitude` is identity on
  hardware without it, so the remote pointer integrates `rotationRate` (yaw → x, pitch → y) into a
  clamped [-1, 1] cursor, written with the existing `irCursorWrites` convention through
  `TCManagerInterface.setAxisValueFor(_, controller: 4, value:)`. Recenter resets it to 0. Gated on
  `motion.hasRotationRate`. Axis signs are settings (invert X/Y), because the remote's rotation axes
  are unverified until tested on a device.
- **Handler slot:** `GCMotion.valueChangedHandler` has one slot, already set by
  `installMotionHandler` for every controller with motion; the remote branch goes inside it.
