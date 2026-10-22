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

## Mechanism

Filled in from the code read before Phase 3 starts.
