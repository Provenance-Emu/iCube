// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

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
    _ reader: FakePlayerHubReader, _ io: FakePlayerScreenIO,
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
  private func boundGameCube() -> (FakePlayerHubReader, FakePlayerScreenIO) {
    let reader = FakePlayerHubReader()
    reader.gameCube[1] = Self.xbox
    reader.pads = [pad(Self.xbox, "Xbox Wireless Controller")]
    return (reader, FakePlayerScreenIO())
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
    let reader = FakePlayerHubReader()
    reader.wii[2] = Self.xbox
    reader.extensions[2] = 2
    let io = FakePlayerScreenIO()
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
    // A press must hold for `holdPolls` polls: one short of it writes nothing, the last binds.
    let holdPolls = RemapCaptureMachine.Config().holdPolls
    for _ in 0 ..< holdPolls - 1 { model.pollCapture() }
    XCTAssertEqual(io.writes, [], "a press must hold for \(holdPolls) polls")
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
    for _ in 0 ..< RemapCaptureMachine.Config().holdPolls { model.pollCapture() }
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

  /// Binds input 0 (Button A) on `model`, leaving it HELD (`io.inputValues == [1, 0]`), as a player
  /// who is still holding the button does. Returns the armed row.
  @MainActor
  private func bindAndKeepHolding(_ model: PlayerScreenViewModel, _ io: FakePlayerScreenIO) -> RemapControlRow {
    let row = model.state.controls[0]
    model.toggleCapture(row)
    model.pollCapture()  // nothing was held at arm time: listening starts
    io.inputValues = [1, 0]
    for _ in 0 ..< RemapCaptureMachine.Config().holdPolls { model.pollCapture() }
    XCTAssertNil(model.state.armedControlID, "bound")
    return row
  }

  /// tvOS: a `Button` fires on release, so a player who holds A past `rearmDelay` releases after the
  /// window closed. The row must stay settled until the bound input is released, not only until the
  /// delay passes.
  @MainActor
  func test_capture_staysSettlingWhileTheBoundInputIsStillHeld_pastTheDelay() {
    let (reader, io) = boundGameCube()
    let clock = Clock()
    let model = make(reader, io, clock: { clock.now })
    model.reload()
    let row = bindAndKeepHolding(model, io)
    clock.now = PlayerScreenViewModel.rearmDelay + 5
    XCTAssertTrue(model.isCaptureSettling, "still held: the delay passing is not enough")
    model.toggleCapture(row)
    XCTAssertNil(model.state.armedControlID, "the release of a long hold must not re-arm the row")
    io.inputValues = [0, 0]
    XCTAssertFalse(model.isCaptureSettling, "released and past the delay")
    model.toggleCapture(row)
    XCTAssertEqual(model.state.armedControlID, row.id)
  }

  /// iOS: a pad's A arms a row on its PRESS. After binding A and releasing it, the next A press must
  /// arm a row even though the bound input reads held again: the release was sampled by a tick, not
  /// only inferred when asked (an answer-time-only check would stall iOS for good).
  @MainActor
  func test_capture_aReleaseSeenByATick_letsTheSameInputArmTheNextRowOnItsPress() {
    let (reader, io) = boundGameCube()
    let clock = Clock()
    let model = make(reader, io, clock: { clock.now })
    model.reload()
    let row = bindAndKeepHolding(model, io)
    io.inputValues = [0, 0]
    model.pollCapture()  // the settle tick sees the release
    clock.now = PlayerScreenViewModel.rearmDelay + 1
    io.inputValues = [1, 0]  // A pressed again, to arm a row
    XCTAssertFalse(model.isCaptureSettling)
    model.toggleCapture(row)
    XCTAssertEqual(model.state.armedControlID, row.id)
  }

  /// Released after the delay passed, or before it: settling ends when BOTH are over.
  @MainActor
  func test_capture_settlingEndsAtTheLaterOfReleaseAndDelay() {
    let (reader, io) = boundGameCube()
    let clock = Clock()
    let model = make(reader, io, clock: { clock.now })
    model.reload()
    let row = bindAndKeepHolding(model, io)
    io.inputValues = [0, 0]
    clock.now = PlayerScreenViewModel.rearmDelay / 2
    XCTAssertTrue(model.isCaptureSettling, "a quick tap: released, but the delay has not passed")
    model.toggleCapture(row)
    XCTAssertNil(model.state.armedControlID)
    clock.now = PlayerScreenViewModel.rearmDelay + 0.1
    XCTAssertFalse(model.isCaptureSettling, "a quick tap: the delay passing ends it")
    model.toggleCapture(row)
    XCTAssertEqual(model.state.armedControlID, row.id)
  }

  /// A timeout captured no input, so only the plain delay applies, whatever is held.
  @MainActor
  func test_capture_timeoutSettlesForThePlainDelay() {
    let (reader, io) = boundGameCube()
    let clock = Clock()
    let model = make(reader, io, clock: { clock.now })
    model.reload()
    let row = model.state.controls[0]
    model.toggleCapture(row)
    for _ in 0 ... RemapCaptureMachine.Config().timeoutPolls { model.pollCapture() }
    XCTAssertNil(model.state.armedControlID, "timed out")
    io.inputValues = [1, 0]  // something is held, but nothing was captured
    clock.now = PlayerScreenViewModel.rearmDelay + 0.1
    XCTAssertFalse(model.isCaptureSettling)
  }

  /// The remembered input is dropped on `stop()`: a pushed list covered the screen.
  @MainActor
  func test_capture_theHeldInputIsForgottenOnStop() {
    let (reader, io) = boundGameCube()
    let clock = Clock()
    let model = make(reader, io, clock: { clock.now })
    model.start()
    _ = bindAndKeepHolding(model, io)
    clock.now = PlayerScreenViewModel.rearmDelay + 1
    XCTAssertTrue(model.isCaptureSettling)
    model.stop()
    XCTAssertFalse(model.isCaptureSettling, "a pushed list covered the screen: nothing is held against it")
  }

  /// Spec edge case: "Capture times out. The row returns to its previous binding."
  @MainActor
  func test_capture_timeoutKeepsTheBinding() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    model.toggleCapture(model.state.controls[0])
    // One poll releases the arm-time hold, then `timeoutPolls` listening polls end the session.
    for _ in 0 ... RemapCaptureMachine.Config().timeoutPolls { model.pollCapture() }
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

  /// The armed row can vanish under a reload (the extension changed elsewhere). The capture
  /// cancels, or the builder's lock would leave no enabled row.
  @MainActor
  func test_capture_armedRowLeavingTheList_cancelsTheCapture() {
    let reader = FakePlayerHubReader()
    reader.wii[2] = Self.xbox
    reader.extensions[2] = 2
    reader.pads = [pad(Self.xbox, "Xbox Wireless Controller")]
    let io = FakePlayerScreenIO()
    let model = make(reader, io, slot: PlayerSlot(kind: .wiiRemote, port: 2))
    model.reload()
    let classicRow = model.state.controls.last { $0.owner == .classic }
    XCTAssertNotNil(classicRow)
    model.toggleCapture(classicRow!)
    XCTAssertEqual(model.state.armedControlID, classicRow?.id)
    reader.extensions[2] = 0
    model.reload()
    XCTAssertNil(model.state.armedControlID)
    io.inputValues = [1, 0]
    for _ in 0 ..< 4 { model.pollCapture() }
    XCTAssertEqual(io.writes, [])
  }

  /// Decision 11: a DSU-bound port captures, and a reload never cancels it for "not in the pad list".
  @MainActor
  func test_capture_dsuPort_armsAndSurvivesAReload() {
    let reader = FakePlayerHubReader()
    reader.gameCube[1] = Self.dsu
    let model = make(reader, FakePlayerScreenIO())
    model.reload()
    let row = model.state.controls[0]
    model.toggleCapture(row)
    model.reload()
    XCTAssertEqual(model.state.armedControlID, row.id)
  }

  @MainActor
  func test_capture_needsAConnectedPad() {
    let reader = FakePlayerHubReader()
    reader.gameCube[1] = Self.xbox
    let model = make(reader, FakePlayerScreenIO())
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

  /// Clear is only reachable on a port that can capture: a Touchscreen port's overlay controls
  /// cannot be rebound there, so unbinding one would strand the user.
  @MainActor
  func test_clear_onATouchscreenPort_writesNothing() {
    let reader = FakePlayerHubReader()
    reader.gameCube[1] = "iOS/4/Touchscreen"
    let io = FakePlayerScreenIO()
    let model = make(reader, io)
    model.reload()
    XCTAssertFalse(model.state.canCapture)
    model.clear(model.state.controls[0])
    XCTAssertEqual(io.writes, [])
  }

  /// Clear on a disconnected pad's port, and on No Device, writes nothing either.
  @MainActor
  func test_clear_onNoDeviceOrADisconnectedPad_writesNothing() {
    let reader = FakePlayerHubReader()
    let io = FakePlayerScreenIO()
    let model = make(reader, io)
    model.reload()
    model.clear(model.state.controls[0])
    reader.gameCube[1] = Self.xbox  // bound, but the pad is not connected
    model.reload()
    XCTAssertTrue(model.state.isDisconnected)
    model.clear(model.state.controls[0])
    XCTAssertEqual(io.writes, [])
  }

  @MainActor
  func test_clear_onACapturingPort_unbindsTheRow() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    model.clear(model.state.controls[0])
    XCTAssertEqual(io.writes, ["expression:gcPad-0-0="])
  }

  /// The port changed device under an armed capture (not a disconnect): the capture cancels and
  /// the binding is kept.
  @MainActor
  func test_reload_cancelsAnArmedCapture_whenTheBoundDeviceChanges() {
    let (reader, io) = boundGameCube()
    reader.pads.append(pad(Self.dualSense, "DualSense Wireless Controller"))
    let model = make(reader, io)
    model.reload()
    model.toggleCapture(model.state.controls[0])
    XCTAssertNotNil(model.state.armedControlID)
    reader.gameCube[1] = Self.dualSense  // both pads stay connected: only the qualifier differs
    model.reload()
    XCTAssertNil(model.state.armedControlID)
    io.inputValues = [1, 0]
    for _ in 0 ..< 4 { model.pollCapture() }
    XCTAssertEqual(io.writes, [])
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
    let reader = FakePlayerHubReader()
    reader.pads = [pad(Self.xbox, "Xbox Wireless Controller")]
    let io = FakePlayerScreenIO()
    io.assignmentReplacesMapping = true
    io.onSetDevice = { choice in
      if case .pad(let qualifier) = choice { reader.gameCube[1] = qualifier }
    }
    let model = make(reader, io)
    model.reload()
    model.setDevice(.pad(Self.xbox))
    XCTAssertEqual(io.writes, ["device:pad(\"\(Self.xbox)\")"])
    XCTAssertEqual(model.state.profileName, "Physical Controller")
  }

  /// `ControllerAssignmentService.assign` keeps a mapping that binds on the device just bound, so
  /// the name stays: the port's controls are the same after the assignment.
  @MainActor
  func test_setDevice_rebindKeepsTheRememberedName() {
    let reader = FakePlayerHubReader()
    reader.pads = [pad(Self.xbox, "Xbox Wireless Controller")]
    let io = FakePlayerScreenIO()
    io.assignmentReplacesMapping = false
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

  /// The Touchscreen's mapping (`Button 0`, `Axis 11`) binds nothing on a physical pad, so the
  /// assignment loads the pad's default profile over it and the remembered name must follow.
  @MainActor
  func test_setDevice_touchscreenToAPad_remembersThePadsDefaultProfile() {
    let reader = FakePlayerHubReader()
    reader.gameCube[1] = "iOS/4/Touchscreen"
    reader.pads = [pad(Self.xbox, "Xbox Wireless Controller")]
    let io = FakePlayerScreenIO()
    io.assignmentReplacesMapping = true
    io.onSetDevice = { choice in
      if case .pad(let qualifier) = choice { reader.gameCube[1] = qualifier }
    }
    let memory = PlayerProfileMemory()
    memory.remember("Touchscreen", for: "gc-1", qualifier: "iOS/4/Touchscreen")
    let model = make(reader, io, memory: memory)
    model.reload()
    model.setDevice(.pad(Self.xbox))
    XCTAssertEqual(model.state.profileName, "Physical Controller")
  }

  /// Both kinds reload the Touchscreen profile when they switch to the touchscreen, mapping or not
  /// (GameCube always; a Wii Remote's BindTouchscreen whenever the bound device changes).
  @MainActor
  func test_setDevice_touchscreenOnAWiiRemote_remembersTheTouchscreenProfile() {
    let reader = FakePlayerHubReader()
    reader.wii[1] = Self.xbox
    reader.pads = [pad(Self.xbox, "Xbox Wireless Controller")]
    let io = FakePlayerScreenIO()
    io.assignmentReplacesMapping = false  // the touchscreen reloads its profile whatever the mapping
    io.onSetDevice = { choice in
      if choice == .touchscreen { reader.wii[1] = "iOS/4/Touchscreen" }
    }
    let memory = PlayerProfileMemory()
    memory.remember("Mine", for: "wii-1", qualifier: Self.xbox)
    let model = make(reader, io, slot: PlayerSlot(kind: .wiiRemote, port: 1), memory: memory)
    model.reload()
    model.setDevice(.touchscreen)
    XCTAssertEqual(model.state.profileName, "Touchscreen")
  }

  /// Decision 12: the app turns the IMU pointer off on touchscreen-bound Wii Remotes and a rebind
  /// keeps the mapping, so binding a gyro pad turns it back on.
  @MainActor
  func test_setDevice_gyroPadOnAWiiRemote_turnsTheMotionPointerOn() {
    let reader = FakePlayerHubReader()
    reader.wii[1] = "iOS/4/Touchscreen"
    reader.pads = [pad(Self.dualSense, "DualSense", gyro: true), pad(Self.xbox, "Xbox")]
    let io = FakePlayerScreenIO()
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
    let reader = FakePlayerHubReader()
    reader.wii[1] = "iOS/4/Touchscreen"
    let io = FakePlayerScreenIO()
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
    let reader = FakePlayerHubReader()
    reader.wii[1] = "iOS/4/Touchscreen"
    let io = FakePlayerScreenIO()
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

  /// A whitespace-only pad name makes `ProfileNaming.suggestion` return ""; the prompt must not
  /// open on a name that cannot be saved, and a blank typed name writes nothing.
  @MainActor
  func test_openSavePrompt_aBlankPadName_fallsBackToThePlayerTitle() {
    let reader = FakePlayerHubReader()
    reader.gameCube[1] = Self.xbox
    reader.pads = [pad(Self.xbox, "   ")]
    let io = FakePlayerScreenIO()
    let model = make(reader, io)
    model.reload()
    model.openSavePrompt()
    XCTAssertEqual(model.saveName, "Player 1")
    model.saveName = "   "
    model.confirmPrompt()
    XCTAssertEqual(io.writes, [], "a blank name is never written")
    XCTAssertNil(model.prompt)
  }

  /// A pad named like a built-in profile, padded with a space, trims to the built-in name: the
  /// prompt must not prefill it.
  @MainActor
  func test_openSavePrompt_aPaddedBuiltInPadName_fallsBackToThePlayerTitle() {
    let reader = FakePlayerHubReader()
    reader.gameCube[1] = Self.xbox
    reader.pads = [pad(Self.xbox, "Touchscreen ")]
    let model = make(reader, FakePlayerScreenIO())
    model.reload()
    model.openSavePrompt()
    XCTAssertEqual(model.saveName, "Player 1")
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

  /// The list hides profiles that cannot work on the bound device, but saving over one still
  /// replaces the file, so it still asks.
  @MainActor
  func test_save_aNameTheListHides_stillAsksBeforeReplacing() {
    let (reader, io) = boundGameCube()
    io.hiddenProfiles = ["Pad Setup"]
    let model = make(reader, io)
    model.reload()
    model.openSavePrompt()
    model.saveName = "pad setup"
    model.confirmPrompt()
    XCTAssertEqual(io.writes, [], "nothing written yet")
    drainMainQueue()
    XCTAssertEqual(model.prompt, .confirmOverwrite(name: "pad setup"))
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
      .confirmReset(profile: "Physical Controller"), .confirmClearAll, .saveFailed,
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
    memory.remember("Mine", for: "gc-1", qualifier: Self.xbox)
    let model = make(reader, io, memory: memory)
    model.reload()
    XCTAssertTrue(model.saveExpression("`Button B`", for: model.state.controls[0]))
    XCTAssertEqual(io.writes, ["expression:gcPad-0-0=`Button B`"])
    XCTAssertTrue(model.state.profileEdited)
  }

  // MARK: Clear all

  /// Asks first through the one prompt; confirming unbinds every bound control of the port.
  @MainActor
  func test_clearAll_asksFirst_thenUnbindsEveryControl() {
    let (reader, io) = boundGameCube()
    let memory = PlayerProfileMemory()
    memory.remember("Mine", for: "gc-1", qualifier: Self.xbox)
    let model = make(reader, io, memory: memory)
    model.reload()
    model.requestClearAll()
    XCTAssertEqual(model.prompt, .confirmClearAll)
    XCTAssertEqual(io.writes, [], "nothing until confirmed")
    let rows = model.state.controls
    model.confirmPrompt()
    XCTAssertNil(model.prompt)
    XCTAssertEqual(io.writes, rows.map { "expression:\($0.id)=" })
    XCTAssertTrue(model.state.profileEdited)
  }

  @MainActor
  func test_clearAll_cancelWritesNothing() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    model.requestClearAll()
    model.cancelPrompt()
    XCTAssertEqual(io.writes, [])
  }

  /// Like a row's Clear: a port that cannot capture could not bind anything again.
  @MainActor
  func test_clearAll_notOfferedWhereCaptureIsImpossible() {
    let reader = FakePlayerHubReader()
    reader.gameCube[1] = "iOS/0/Touchscreen"
    let model = make(reader, FakePlayerScreenIO())
    model.reload()
    model.requestClearAll()
    XCTAssertNil(model.prompt)
  }

  // MARK: Pins

  /// The snapshot says whether the port is pinned, and Auto from the Device list unpins it.
  @MainActor
  func test_auto_unpinsThePort() {
    let (reader, io) = boundGameCube()
    io.pinned = true
    let model = make(reader, io)
    model.reload()
    XCTAssertTrue(model.state.isPinned)
    XCTAssertEqual(PlayerScreenModelBuilder.deviceOptions(state: model.state, platform: .ios).first?.choice, .automatic)

    model.setDevice(.automatic)

    XCTAssertEqual(io.writes, ["device:automatic"])
    XCTAssertFalse(model.state.isPinned)
  }

  // MARK: Profile name across launches

  /// The loaded profile's name outlives the session for the same port and device (it read "Custom"
  /// after every relaunch); another device on the port has its own, and an edit drops it.
  @MainActor
  func test_profileName_isKeptAcrossLaunches_untilTheMappingIsEdited() throws {
    let suite = "PlayerProfileMemoryTests"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let (reader, io) = boundGameCube()
    let model = make(reader, io, memory: PlayerProfileMemory(defaults: defaults))
    model.reload()
    model.loadProfile("Mine")

    let relaunched = make(reader, io, memory: PlayerProfileMemory(defaults: defaults))
    relaunched.reload()
    XCTAssertEqual(relaunched.state.profileName, "Mine")
    XCTAssertFalse(relaunched.state.profileEdited)

    reader.gameCube[1] = Self.dualSense
    let otherDevice = make(reader, io, memory: PlayerProfileMemory(defaults: defaults))
    otherDevice.reload()
    XCTAssertNil(otherDevice.state.profileName, "the name belongs to the device it was applied on")

    reader.gameCube[1] = Self.xbox
    relaunched.reload()
    XCTAssertTrue(relaunched.saveExpression("`Button B`", for: relaunched.state.controls[0]))
    XCTAssertEqual(relaunched.state.profileName, "Mine")
    XCTAssertTrue(relaunched.state.profileEdited, "this session still says what the edit started from")
    let afterEdit = make(reader, io, memory: PlayerProfileMemory(defaults: defaults))
    afterEdit.reload()
    XCTAssertNil(afterEdit.state.profileName, "an edited mapping is no longer that profile")
  }

  /// The session's name belongs to the device it was applied on: when the port's device changes
  /// without this screen (automatic assignment), the old device's name is not shown, and it comes
  /// back with the device.
  @MainActor
  func test_profileName_followsTheDevice_whenThePortIsReassignedElsewhere() {
    let (reader, io) = boundGameCube()
    let memory = PlayerProfileMemory()
    let model = make(reader, io, memory: memory)
    model.reload()
    model.loadProfile("Mine")
    XCTAssertEqual(model.state.profileName, "Mine")

    reader.gameCube[1] = "iOS/4/Touchscreen"
    model.reload()
    XCTAssertNil(model.state.profileName)

    reader.gameCube[1] = Self.xbox
    model.reload()
    XCTAssertEqual(model.state.profileName, "Mine")
  }

  // MARK: Delete a profile

  @MainActor
  func test_deleteProfile_deletesAUserProfile_andKeepsTheMapping() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    let controlsBefore = model.state.controls
    XCTAssertEqual(model.deletableProfileNames(), ["Mine"])
    XCTAssertTrue(model.deleteProfile("Mine"))
    XCTAssertEqual(io.writes, ["delete:Mine"])
    XCTAssertEqual(model.profileNames(), ["Physical Controller"])
    XCTAssertEqual(model.state.controls, controlsBefore, "deleting a file changes no binding")
  }

  /// The bundled profiles are never the user's, so the seam refuses them.
  @MainActor
  func test_deleteProfile_aBundledProfileIsRefused() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    XCTAssertFalse(model.deleteProfile("Physical Controller"))
    XCTAssertEqual(model.profileNames(), ["Physical Controller", "Mine"])
  }

  /// The port that remembers the deleted profile reads "Custom" afterwards; another name stays.
  @MainActor
  func test_deleteProfile_forgetsTheRememberedName() {
    let (reader, io) = boundGameCube()
    let memory = PlayerProfileMemory()
    memory.remember("Mine", for: "gc-1", qualifier: Self.xbox)
    let model = make(reader, io, memory: memory)
    model.reload()
    model.deleteProfile("Mine")
    XCTAssertNil(model.state.profileName)

    let (otherReader, otherIO) = boundGameCube()
    let otherMemory = PlayerProfileMemory()
    otherMemory.remember("Physical Controller", for: "gc-1", qualifier: Self.xbox)
    let other = make(otherReader, otherIO, memory: otherMemory)
    other.reload()
    other.deleteProfile("Mine")
    XCTAssertEqual(other.state.profileName, "Physical Controller")
  }

  /// Deleting a profile forgets it on every port and device of the system, kept or in session;
  /// another name and the Wii Remotes (their profiles are separate files) keep theirs.
  @MainActor
  func test_deleteProfile_forgetsTheNameOnEveryPortAndDevice() throws {
    let suite = "PlayerProfileMemoryDeleteTests"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let (reader, io) = boundGameCube()
    let memory = PlayerProfileMemory(defaults: defaults)
    memory.remember("Mine", for: "gc-1", qualifier: Self.xbox)
    memory.remember("Mine", for: "gc-1", qualifier: Self.dualSense)
    memory.remember("mine", for: "gc-2", qualifier: Self.xbox)
    memory.remember("Other", for: "gc-3", qualifier: Self.xbox)
    memory.remember("Mine", for: "wii-1", qualifier: Self.xbox)
    let model = make(reader, io, memory: memory)
    model.reload()

    XCTAssertTrue(model.deleteProfile("Mine"))

    XCTAssertNil(memory.entry(for: "gc-1", qualifier: Self.dualSense))
    XCTAssertNil(memory.entry(for: "gc-2", qualifier: Self.xbox))
    XCTAssertEqual(memory.entry(for: "gc-3", qualifier: Self.xbox)?.name, "Other")
    XCTAssertEqual(memory.entry(for: "wii-1", qualifier: Self.xbox)?.name, "Mine")
    let relaunched = PlayerProfileMemory(defaults: defaults)
    XCTAssertNil(relaunched.entry(for: "gc-1", qualifier: Self.dualSense), "the kept name goes too")
    XCTAssertNil(relaunched.entry(for: "gc-2", qualifier: Self.xbox))
    XCTAssertEqual(relaunched.entry(for: "gc-3", qualifier: Self.xbox)?.name, "Other")
    XCTAssertEqual(relaunched.entry(for: "wii-1", qualifier: Self.xbox)?.name, "Mine")
  }

  // MARK: Reset one control to the default

  /// Reads the bound device's default profile's expression for that one control and writes it.
  @MainActor
  func test_resetToDefault_writesTheDefaultProfilesExpression() {
    let (reader, io) = boundGameCube()
    let memory = PlayerProfileMemory()
    memory.remember("Physical Controller", for: "gc-1", qualifier: Self.xbox)
    let model = make(reader, io, memory: memory)
    model.reload()
    let row = model.state.controls[0]
    XCTAssertEqual(model.defaultExpression(for: row), "`Button B`")
    model.resetToDefault(row)
    XCTAssertEqual(io.profileReads.last, "Physical Controller:\(row.id)")
    XCTAssertEqual(io.writes, ["expression:\(row.id)=`Button B`"])
    XCTAssertTrue(model.state.profileEdited)
  }

  /// A default profile that cannot be read (no bundled DSU profile yet) writes nothing.
  @MainActor
  func test_resetToDefault_anUnreadableProfileWritesNothing() {
    let (reader, io) = boundGameCube()
    io.profileExpressions = [:]
    let model = make(reader, io)
    model.reload()
    model.resetToDefault(model.state.controls[0])
    XCTAssertEqual(io.writes, [])
  }

  /// The same guards as Clear: not where capture is impossible, not while another row is armed.
  @MainActor
  func test_resetToDefault_followsClearsGuards() {
    let reader = FakePlayerHubReader()
    reader.gameCube[1] = "iOS/0/Touchscreen"
    let io = FakePlayerScreenIO()
    let model = make(reader, io)
    model.reload()
    model.resetToDefault(model.state.controls[0])
    XCTAssertEqual(io.writes, [], "the Touchscreen cannot capture, so it cannot reset a row either")

    let (padReader, padIO) = boundGameCube()
    let armed = make(padReader, padIO)
    armed.reload()
    armed.toggleCapture(armed.state.controls[0])
    armed.resetToDefault(armed.state.controls[1])
    XCTAssertEqual(padIO.writes, [])
    armed.stop()
  }

  /// No device: no default profile, so nothing to read.
  @MainActor
  func test_defaultExpression_needsADevice() {
    let model = make(FakePlayerHubReader(), FakePlayerScreenIO())
    model.reload()
    XCTAssertNil(model.defaultExpression(for: model.state.controls[0]))
  }

  /// The editor's input picker lists the bound device's inputs, and nothing without a device.
  @MainActor
  func test_editorInputs_areTheBoundDevicesInputs() {
    let (reader, io) = boundGameCube()
    let model = make(reader, io)
    model.reload()
    XCTAssertEqual(model.editorInputs(forQualifier: Self.xbox), ["Button A", "Button B"])
    XCTAssertEqual(model.editorInputs(forQualifier: ""), [])
  }

  @MainActor
  func test_pointerSettingsWriteThroughTheSeam() {
    let reader = FakePlayerHubReader()
    reader.wii[1] = "iOS/4/Touchscreen"
    let io = FakePlayerScreenIO()
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
