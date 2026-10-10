// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// `ControllerHubViewModel` against a fake reader: which ports it reads in which order, and that
/// it reloads on assignment changes only while started. Observers deliver on the main queue, so
/// the notification tests wait on expectations instead of assuming inline delivery.
final class ControllerHubViewModelTests: XCTestCase {

  @MainActor
  private final class FakeReader: ControllerHubReading {
    var gameCube: [Int: String] = [:]
    var wii: [Int: String] = [:]
    var extensions: [Int: Int] = [:]
    var sideways: Set<Int> = []
    var pads: [ConnectedPadState] = []
    var gameRunning = true
    /// Counts snapshots: `reload()` asks for the pads exactly once.
    var padReads = 0
    var onPadRead: (() -> Void)?
    var pointerModeValue: PointerMode = .touchFollow
    var pointerThisGameOnly = false
    var backgroundInputValue = false
    var rumble: RumbleDestination = .controller
    var connectTakesPlayer1Value = true
    var touchOverlayProgrammaticValue = true
    // The `...Value` names avoid clashing with the protocol's same-named methods.
  /// Player ids (`gc-1`) the user pinned.
    var pinned: Set<String> = []
    /// Wii Remote ports with the IMU pointer on.
    var motion: Set<Int> = []

    func boundQualifier(forGCPort port: Int) -> String { gameCube[port] ?? "" }
    func boundQualifier(forWiimote index: Int) -> String { wii[index] ?? "" }
    func wiiExtension(forWiimote index: Int) -> Int { extensions[index] ?? 0 }
    func isSideways(forWiimote index: Int) -> Bool { sideways.contains(index) }
    func connectedPads() -> [ConnectedPadState] {
      padReads += 1
      onPadRead?()
      return pads
    }
    func isGameRunning() -> Bool { gameRunning }
    func overlayVisible() -> Bool { true }
    func overlayMode() -> ControllerManager.OverlayMode { .wii }
    func overlayOpacity() -> Float { 0.62 }
    func dsuClientEnabled() -> Bool { true }
    func dsuServerCount() -> Int { 3 }
    func isPinned(_ slot: PlayerSlot) -> Bool { pinned.contains(slot.playerID) }
    func isMotionPointerEnabled(wiimote: Int) -> Bool { motion.contains(wiimote) }
    func pointerMode() -> PointerMode { pointerModeValue }
    func pointerIsThisGameOnly() -> Bool { pointerThisGameOnly }
    func backgroundInput() -> Bool { backgroundInputValue }
    func rumbleDestination() -> RumbleDestination { rumble }
    func connectTakesPlayer1() -> Bool { connectTakesPlayer1Value }
    func touchOverlayProgrammatic() -> Bool { touchOverlayProgrammaticValue }
  }

  @MainActor
  func test_reload_readsEveryPortInTheSystemsOrder() {
    let reader = FakeReader()
    reader.wii[1] = "iOS/4/Touchscreen"
    reader.extensions[1] = 1
    reader.sideways = [2]
    reader.gameCube[2] = "MFi/0/Xbox Wireless Controller"
    let model = ControllerHubViewModel(system: .wiiAndGameCube, reader: reader, notificationCenter: NotificationCenter())

    model.reload()

    XCTAssertEqual(model.state.players.map(\.id), ["wii-1", "wii-2", "wii-3", "wii-4", "gc-1", "gc-2", "gc-3", "gc-4"])
    XCTAssertEqual(model.state.players[0].deviceQualifier, "iOS/4/Touchscreen")
    XCTAssertEqual(model.state.players[0].wiiExtension, 1)
    XCTAssertTrue(model.state.players[1].isSideways)
    XCTAssertEqual(model.state.players[5].deviceQualifier, "MFi/0/Xbox Wireless Controller")
    XCTAssertEqual(model.state.players[5].wiiExtension, 0, "GameCube ports carry no extension")
  }

  @MainActor
  func test_reload_snapshotsTheOverlayAndDevices() {
    let model = ControllerHubViewModel(system: .gamecube, reader: FakeReader(), notificationCenter: NotificationCenter())
    model.reload()
    XCTAssertTrue(model.state.isGameRunning)
    XCTAssertEqual(model.state.overlayMode, .wii)
    XCTAssertEqual(model.state.overlayOpacityPercent, 50, "0.62 snaps to 50 %")
    XCTAssertTrue(model.state.dsuClientEnabled)
    XCTAssertEqual(model.state.dsuServerCount, 3)
  }

  @MainActor
  func test_editLayout_inAGame_handsOffToTheGameScreen() {
    let center = NotificationCenter()
    let model = ControllerHubViewModel(system: .gamecube, reader: FakeReader(), notificationCenter: center)
    let posted = expectation(forNotification: .DOLEditTouchLayout, object: nil, notificationCenter: center)
    model.actions.editLayout()
    wait(for: [posted], timeout: 1)
    XCTAssertFalse(model.isLayoutEditorPresented, "the game screen edits its own overlay")
  }

  @MainActor
  func test_editLayout_outsideAGame_presentsTheEditor() {
    let reader = FakeReader()
    reader.gameRunning = false
    let center = NotificationCenter()
    let model = ControllerHubViewModel(system: .both, reader: reader, notificationCenter: center)
    let posted = expectation(forNotification: .DOLEditTouchLayout, object: nil, notificationCenter: center)
    posted.isInverted = true
    model.actions.editLayout()
    wait(for: [posted], timeout: 0.3)
    XCTAssertTrue(model.isLayoutEditorPresented)
  }

  @MainActor
  func test_showAllPorts_survivesAReload() {
    let model = ControllerHubViewModel(system: .gamecube, reader: FakeReader(), notificationCenter: NotificationCenter())
    model.reload()
    model.actions.toggleShowAllPorts()
    model.reload()
    XCTAssertTrue(model.state.showAllPorts)
  }

  @MainActor
  func test_start_reloadsWhenAssignmentsChange() {
    let reader = FakeReader()
    let center = NotificationCenter()
    let model = ControllerHubViewModel(system: .gamecube, reader: reader, notificationCenter: center)
    model.start()
    XCTAssertEqual(reader.padReads, 1, "start() takes the first snapshot")

    let reloaded = expectation(description: "reloaded on assignmentsChanged")
    reader.onPadRead = { reloaded.fulfill() }
    center.post(name: ControllerManager.assignmentsChanged, object: nil)
    wait(for: [reloaded], timeout: 1)
    model.stop()
  }

  @MainActor
  func test_stop_removesTheObservers() {
    let reader = FakeReader()
    let center = NotificationCenter()
    let model = ControllerHubViewModel(system: .gamecube, reader: reader, notificationCenter: center)
    model.start()
    model.stop()

    let reloaded = expectation(description: "no reload after stop()")
    reloaded.isInverted = true
    reader.onPadRead = { reloaded.fulfill() }
    center.post(name: ControllerManager.assignmentsChanged, object: nil)
    wait(for: [reloaded], timeout: 0.3)
  }

  @MainActor
  func test_start_twice_installsOneSetOfObservers() {
    let reader = FakeReader()
    let center = NotificationCenter()
    let model = ControllerHubViewModel(system: .gamecube, reader: reader, notificationCenter: center)
    model.start()
    model.start()
    reader.padReads = 0

    center.post(name: ControllerManager.assignmentsChanged, object: nil)
    // Drain the main queue: delivery may be deferred, and a second observer would add a read.
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(reader.padReads, 1, "exactly one reload per notice")
    model.stop()
  }

  @MainActor
  private final class FakeScheduler: ControllerHubScheduling {
    private final class Job {
      let delay: TimeInterval
      let work: @MainActor () -> Void
      var isCancelled = false
      init(delay: TimeInterval, work: @escaping @MainActor () -> Void) { self.delay = delay; self.work = work }
    }
    private var jobs: [Job] = []
    /// Delays of the jobs that are scheduled and not cancelled.
    var liveDelays: [TimeInterval] { jobs.filter { !$0.isCancelled }.map(\.delay) }
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
      let job = Job(delay: delay, work: work)
      jobs.append(job)
      return { job.isCancelled = true }
    }
    /// Runs every live job once, as the settle delay elapsing would.
    func fire() {
      let due = jobs.filter { !$0.isCancelled }
      jobs.removeAll()
      due.forEach { $0.work() }
    }
  }

  /// Writes land in the fake reader, as the real config does, so `reload()` shows them.
  @MainActor
  private final class FakeWriter: ControllerHubWriting {
    private let reader: FakeReader
    var log: [String] = []
    var refuseAssign = false
    /// The real binding picks the Touchscreen instance for the slot's kind (GameCube 0-3, Wii 4-7).
    var resolvesTouchscreenPerKind = false
    init(reader: FakeReader) { self.reader = reader }

    private func bind(_ qualifier: String, _ slot: PlayerSlot) {
      var bound = qualifier
      if resolvesTouchscreenPerKind, PlayerDeviceChoice(qualifier: qualifier) == .touchscreen {
        bound = slot.kind == .gameCube ? "iOS/\(slot.port - 1)/Touchscreen" : "iOS/\(slot.port + 3)/Touchscreen"
      }
      if slot.kind == .gameCube { reader.gameCube[slot.port] = bound } else { reader.wii[slot.port] = bound }
    }
    func setDevice(_ choice: PlayerDeviceChoice, slot: PlayerSlot) {
      log.append("setDevice \(choice) \(slot.playerID)")
      switch choice {
      case .noDevice: bind("", slot)
      case .touchscreen: bind("iOS/4/Touchscreen", slot)
      case .pad(let qualifier): bind(qualifier, slot)
      case .automatic: break
      }
    }
    func assign(qualifier: String, slot: PlayerSlot) -> Bool {
      log.append("assign \(qualifier) \(slot.playerID)")
      guard !refuseAssign else { return false }
      bind(qualifier, slot)
      return true
    }
    func clear(slot: PlayerSlot) { log.append("clear \(slot.playerID)"); bind("", slot) }
    func setExtension(_ value: Int, wiimote: Int) { log.append("ext \(wiimote) \(value)") }
    func setSideways(_ enabled: Bool, wiimote: Int) { log.append("side \(wiimote) \(enabled)") }
    func setPointerMode(_ mode: PointerMode) { log.append("pointer \(mode)") }
    func setMotionPointer(_ enabled: Bool, wiimote: Int) { log.append("motion \(wiimote) \(enabled)") }
    func setOverlayMode(_ mode: ControllerManager.OverlayMode) { log.append("layout \(mode)") }
    func setBackgroundInput(_ enabled: Bool) { log.append("bg \(enabled)") }
    func setRumbleDestination(_ value: RumbleDestination) { log.append("rumble \(value)") }
    func setConnectTakesPlayer1(_ enabled: Bool) { log.append("takes \(enabled)") }
    func testRumble() { log.append("testRumble") }
    func resetOverlayLayouts() { log.append("resetLayouts") }
    func setTouchOverlayProgrammatic(_ enabled: Bool) { log.append("programmatic \(enabled)") }
  }

  private static let xbox = "MFi/0/Xbox Wireless Controller"
  private static let touch = "iOS/4/Touchscreen"

  @MainActor
  private func makeModel(
    system: ControllerSetupSystem = .wiiAndGameCube, reader: FakeReader, writer: FakeWriter, scheduler: FakeScheduler? = nil,
    memory: PlayerProfileMemory = PlayerProfileMemory()
  ) -> ControllerHubViewModel {
    let model = ControllerHubViewModel(
      system: system, reader: reader, writer: writer, scheduler: scheduler ?? FakeScheduler(), memory: memory, notificationCenter: NotificationCenter())
    model.reload()
    return model
  }

  /// The texts posted as toasts while `body` runs.
  @MainActor
  private func toasts(during body: () -> Void) -> [String] {
    var seen: [String] = []
    let token = NotificationCenter.default.addObserver(forName: .dolShowSnackbar, object: nil, queue: nil) { note in
      seen.append(note.userInfo?[EmulationToast.textKey] as? String ?? "")
    }
    defer { NotificationCenter.default.removeObserver(token) }
    body()
    return seen
  }

  // MARK: Plays as

  @MainActor
  func test_setPlaysAs_wiiToGameCube_assignsThenClears_andReloads() {
    let reader = FakeReader()
    reader.wii[1] = Self.xbox
    let writer = FakeWriter(reader: reader)
    let model = makeModel(reader: reader, writer: writer)
    model.setPlaysAs(model.state.players[0], .gameCube)
    XCTAssertEqual(writer.log, ["assign \(Self.xbox) gc-1", "clear wii-1"])
    XCTAssertEqual(model.state.players.first { $0.id == "gc-1" }?.deviceQualifier, Self.xbox, "reloaded: the pad now sits on the GameCube port")
    XCTAssertEqual(model.state.players.first { $0.id == "wii-1" }?.deviceQualifier, "")
  }

  /// The move step carries the SOURCE qualifier, but Touchscreen instance ids are per kind
  /// (GameCube 0-3, Wii 4-7): the writer must bind the destination kind's instance.
  @MainActor
  func test_setPlaysAs_touchscreenMovingBetweenWiiAndGameCube_takesTheDestinationKindsInstance() {
    let reader = FakeReader()
    reader.wii[1] = "iOS/4/Touchscreen"
    let writer = FakeWriter(reader: reader)
    writer.resolvesTouchscreenPerKind = true
    let model = makeModel(reader: reader, writer: writer)
    model.setPlaysAs(model.state.players[0], .gameCube)
    XCTAssertEqual(writer.log, ["assign iOS/4/Touchscreen gc-1", "clear wii-1"])
    XCTAssertEqual(model.state.players.first { $0.id == "gc-1" }?.deviceQualifier, "iOS/0/Touchscreen", "GameCube instance, not the Wii one")

    reader.gameCube[2] = "iOS/1/Touchscreen"
    model.reload()
    model.setPlaysAs(model.state.players.first { $0.id == "gc-2" }!, .wiiRemote)
    XCTAssertEqual(model.state.players.first { $0.id == "wii-2" }?.deviceQualifier, "iOS/5/Touchscreen", "Wii instance, not the GameCube one")
  }

  /// The live writer judges "did the binding take" by device, not by string: the instance id changes
  /// with the slot's kind, a pad's does not.
  @MainActor
  func test_liveWriter_bindingTook_comparesDevicesNotStrings() {
    XCTAssertTrue(LiveControllerHubWriter.bindingTook(requested: "iOS/4/Touchscreen", bound: "iOS/0/Touchscreen"))
    XCTAssertTrue(LiveControllerHubWriter.bindingTook(requested: "iOS/1/Touchscreen", bound: "iOS/5/Touchscreen"))
    XCTAssertTrue(LiveControllerHubWriter.bindingTook(requested: Self.xbox, bound: Self.xbox))
    XCTAssertFalse(LiveControllerHubWriter.bindingTook(requested: Self.xbox, bound: "MFi/1/DualSense Wireless Controller"))
    XCTAssertFalse(LiveControllerHubWriter.bindingTook(requested: Self.xbox, bound: ""), "an unbindable pad leaves the slot off")
    XCTAssertFalse(LiveControllerHubWriter.bindingTook(requested: Self.touch, bound: ""))
    XCTAssertFalse(LiveControllerHubWriter.bindingTook(requested: Self.xbox, bound: Self.touch))
  }

  @MainActor
  func test_setPlaysAs_movingBetweenWiiAndGameCube_requestsFocusOnTheMovedRow() {
    let reader = FakeReader()
    reader.wii[1] = Self.xbox
    let model = makeModel(reader: reader, writer: FakeWriter(reader: reader))
    model.setPlaysAs(model.state.players[0], .gameCube)
    XCTAssertEqual(model.state.focusRequest, "gc-1-plays-as")
    let moved = model.state.players.first { $0.id == "gc-1" }!
    model.setPlaysAs(moved, .wiiClassic)
    XCTAssertEqual(model.state.focusRequest, "wii-1-plays-as")
    model.reload()
    XCTAssertNil(model.state.focusRequest, "a request is one-shot: the next reload drops it")
  }

  @MainActor
  func test_setPlaysAs_wiiToWii_requestsNoFocusMove() {
    let reader = FakeReader()
    reader.wii[1] = Self.xbox
    let model = makeModel(reader: reader, writer: FakeWriter(reader: reader))
    model.setPlaysAs(model.state.players[0], .wiiNunchuk)
    XCTAssertNil(model.state.focusRequest, "the row keeps its id")
  }

  @MainActor
  func test_setPlaysAs_refusedAssign_leavesTheOldSlotAlone_andToasts() {
    let reader = FakeReader()
    reader.wii[1] = Self.xbox
    let writer = FakeWriter(reader: reader)
    writer.refuseAssign = true
    let model = makeModel(reader: reader, writer: writer)
    let seen = toasts { model.setPlaysAs(model.state.players[0], .gameCube) }
    XCTAssertEqual(writer.log, ["assign \(Self.xbox) gc-1"], "no clear after a refused assignment")
    XCTAssertEqual(model.state.players[0].deviceQualifier, Self.xbox, "state re-read: the Wii Remote still has the pad")
    XCTAssertEqual(seen, ["Couldn't move the controller"])
    XCTAssertNil(model.state.focusRequest)
  }

  @MainActor
  func test_setPlaysAs_intoAnOccupiedPort_isRefusedBeforeAnyWrite() {
    let reader = FakeReader()
    reader.wii[1] = Self.xbox
    reader.gameCube[1] = "MFi/1/DualSense Wireless Controller"
    let writer = FakeWriter(reader: reader)
    let model = makeModel(reader: reader, writer: writer)
    let seen = toasts { model.setPlaysAs(model.state.players[0], .gameCube) }
    XCTAssertEqual(writer.log, [], "moving would overwrite Player 1's device")
    XCTAssertEqual(seen, ["Player 1 is in use"])
    XCTAssertEqual(model.state.players.first { $0.id == "gc-1" }?.deviceQualifier, "MFi/1/DualSense Wireless Controller")
  }

  @MainActor
  func test_setPlaysAs_gameCubeToNunchuk_movesThenSetsExtension() {
    let reader = FakeReader()
    reader.gameCube[2] = Self.touch
    let writer = FakeWriter(reader: reader)
    let model = makeModel(reader: reader, writer: writer)
    let gc2 = model.state.players.first { $0.id == "gc-2" }!
    model.setPlaysAs(gc2, .wiiNunchuk)
    XCTAssertEqual(writer.log, ["assign \(Self.touch) wii-2", "clear gc-2", "ext 2 1", "side 2 false"])
  }

  /// Ruling H9: the profile shows "(edited)" after an extension change, as on the player screen.
  @MainActor
  func test_setPlaysAs_extensionChange_marksTheProfileEdited() {
    let reader = FakeReader()
    reader.wii[1] = Self.xbox
    let memory = PlayerProfileMemory()
    memory.remember("Physical Controller", for: "wii-1", qualifier: Self.xbox)
    let model = makeModel(reader: reader, writer: FakeWriter(reader: reader), memory: memory)
    model.setPlaysAs(model.state.players[0], .wiiNunchuk)
    XCTAssertEqual(memory.entry(for: "wii-1", qualifier: Self.xbox)?.edited, true)
  }

  // MARK: Settle (ruling H4)

  @MainActor
  func test_chooseDevice_writesNothingUntilTheSettleDelayElapses_andShowsTheChoiceAtOnce() {
    let reader = FakeReader()
    reader.gameCube[1] = Self.xbox
    let writer = FakeWriter(reader: reader)
    let scheduler = FakeScheduler()
    let model = makeModel(system: .gamecube, reader: reader, writer: writer, scheduler: scheduler)
    model.chooseDevice(model.state.players[0], .touchscreen)
    XCTAssertEqual(writer.log, [])
    XCTAssertEqual(model.state.pending.devices["gc-1"], .touchscreen, "the row shows the pending value")
    XCTAssertEqual(scheduler.liveDelays, [ControllerHubViewModel.settleDelay])
    scheduler.fire()
    XCTAssertEqual(writer.log, ["setDevice touchscreen gc-1"])
    XCTAssertTrue(model.state.pending.isEmpty)
    XCTAssertEqual(model.state.players[0].deviceQualifier, Self.touch, "reloaded after the commit")
  }

  @MainActor
  func test_pendingChanges_surviveAReload() {
    let reader = FakeReader()
    reader.gameCube[1] = Self.xbox
    let model = makeModel(system: .gamecube, reader: reader, writer: FakeWriter(reader: reader))
    model.chooseDevice(model.state.players[0], .touchscreen)
    model.reload()
    XCTAssertEqual(model.state.pending.devices["gc-1"], .touchscreen, "a pad connecting must not drop the choice")
  }

  @MainActor
  func test_rapidChoices_commitOnlyTheLast_andRestartTheDelay() {
    let reader = FakeReader()
    reader.gameCube[1] = Self.xbox
    let writer = FakeWriter(reader: reader)
    let scheduler = FakeScheduler()
    let model = makeModel(system: .gamecube, reader: reader, writer: writer, scheduler: scheduler)
    let player = model.state.players[0]
    model.chooseDevice(player, .noDevice)
    model.chooseDevice(player, .touchscreen)
    model.chooseDevice(player, .pad("MFi/1/DualSense Wireless Controller"))
    XCTAssertEqual(scheduler.liveDelays.count, 1, "each choice cancels the previous timer")
    scheduler.fire()
    XCTAssertEqual(writer.log, ["setDevice pad(\"MFi/1/DualSense Wireless Controller\") gc-1"], "None and Touchscreen were never written")
  }

  @MainActor
  func test_choosingTheCommittedValueAgain_cancelsThePendingChange() {
    let reader = FakeReader()
    reader.gameCube[1] = Self.xbox
    let writer = FakeWriter(reader: reader)
    let scheduler = FakeScheduler()
    let model = makeModel(system: .gamecube, reader: reader, writer: writer, scheduler: scheduler)
    let player = model.state.players[0]
    model.chooseDevice(player, .touchscreen)
    model.chooseDevice(player, .pad(Self.xbox))
    XCTAssertTrue(model.state.pending.isEmpty)
    XCTAssertEqual(scheduler.liveDelays, [])
    scheduler.fire()
    XCTAssertEqual(writer.log, [])
  }

  /// The Layout GameCube-to-Auto trap: Wii must never be written on the way.
  @MainActor
  func test_layoutCycledThroughWii_writesOnlyTheFinalMode() {
    let reader = FakeReader()   // committed mode: .wii
    let writer = FakeWriter(reader: reader)
    let scheduler = FakeScheduler()
    let model = makeModel(system: .wii, reader: reader, writer: writer, scheduler: scheduler)
    model.chooseOverlayMode(.auto)
    model.chooseOverlayMode(.gamecube)
    model.chooseOverlayMode(.auto)
    XCTAssertEqual(model.state.pending.overlayMode, .auto)
    scheduler.fire()
    XCTAssertEqual(writer.log, ["layout auto"])
  }

  /// A pad that moves to Touchscreen and then plays as GameCube: the plays-as commit must see the
  /// device the first commit wrote, not the snapshot taken when the player was chosen.
  @MainActor
  func test_commit_runsDeviceBeforePlaysAs_andPlaysAsSeesTheNewDevice() {
    let reader = FakeReader()
    reader.wii[1] = Self.xbox
    let writer = FakeWriter(reader: reader)
    let scheduler = FakeScheduler()
    let model = makeModel(reader: reader, writer: writer, scheduler: scheduler)
    let player = model.state.players[0]
    model.chooseDevice(player, .touchscreen)
    model.choosePlaysAs(player, .gameCube)
    scheduler.fire()
    XCTAssertEqual(writer.log, ["setDevice touchscreen wii-1", "assign \(Self.touch) gc-1", "clear wii-1"])
  }

  @MainActor
  func test_stop_flushesAPendingChange() {
    let reader = FakeReader()
    reader.gameCube[1] = Self.xbox
    let writer = FakeWriter(reader: reader)
    let model = makeModel(system: .gamecube, reader: reader, writer: writer)
    model.chooseDevice(model.state.players[0], .touchscreen)
    model.stop()
    XCTAssertEqual(writer.log, ["setDevice touchscreen gc-1"], "a pushed player screen must see the committed device")
    XCTAssertTrue(model.state.pending.isEmpty)
  }

  // MARK: Reads and setup writes

  @MainActor
  func test_setDevice_goesThroughTheWriter_andReloads() {
    let reader = FakeReader()
    let writer = FakeWriter(reader: reader)
    let model = makeModel(system: .gamecube, reader: reader, writer: writer)
    XCTAssertEqual(model.state.players[0].deviceQualifier, "")
    model.setDevice(model.state.players[0], .touchscreen)
    XCTAssertEqual(writer.log, ["setDevice touchscreen gc-1"])
    XCTAssertEqual(model.state.players[0].deviceQualifier, Self.touch, "the snapshot was re-read after the write")
  }

  @MainActor
  func test_reload_snapshotsPointerAndSetup() {
    let reader = FakeReader()
    reader.pointerModeValue = .gyro
    reader.pointerThisGameOnly = true
    reader.motion = [2]
    reader.pinned = ["gc-1"]
    reader.rumble = .both
    reader.backgroundInputValue = true
    let model = makeModel(reader: reader, writer: FakeWriter(reader: reader))
    XCTAssertEqual(model.state.pointerMode, .gyro)
    XCTAssertTrue(model.state.pointerIsThisGameOnly)
    XCTAssertTrue(model.state.players.first { $0.id == "wii-2" }!.motionPointerEnabled)
    XCTAssertFalse(model.state.players.first { $0.id == "wii-3" }!.motionPointerEnabled)
    XCTAssertTrue(model.state.players.first { $0.id == "gc-1" }!.isPinned)
    XCTAssertEqual(model.state.rumbleDestination, .both)
    XCTAssertTrue(model.state.backgroundInput)
  }

  @MainActor
  func test_setupAndPointerActions_writeThroughTheWriter() {
    let reader = FakeReader()
    let writer = FakeWriter(reader: reader)
    let model = makeModel(reader: reader, writer: writer)
    let wii2 = model.state.players.first { $0.id == "wii-2" }!
    model.actions.setPointerMode(.gyro)
    model.actions.setMotionPointer(wii2, true)
    model.actions.setBackgroundInput(true)
    model.actions.setRumbleDestination(.both)
    model.actions.setConnectTakesPlayer1(false)
    model.actions.setTouchOverlayProgrammatic(false)
    model.actions.testRumble()
    model.actions.resetOverlayLayouts()
    XCTAssertEqual(writer.log, ["pointer gyro", "motion 2 true", "bg true", "rumble both", "takes false", "programmatic false", "testRumble", "resetLayouts"])
  }

  func test_rumbleDestination_defaultsToController_andReadsTheStoredValue() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "RumbleDestinationTests"))
    defaults.removePersistentDomain(forName: "RumbleDestinationTests")
    XCTAssertEqual(RumbleDestination.stored(in: defaults), .controller)
    defaults.set(2, forKey: RumbleDestination.defaultsKey)
    XCTAssertEqual(RumbleDestination.stored(in: defaults), .both)
    defaults.set(9, forKey: RumbleDestination.defaultsKey)
    XCTAssertEqual(RumbleDestination.stored(in: defaults), .controller, "an unknown value falls back to the default")
    defaults.removePersistentDomain(forName: "RumbleDestinationTests")
  }
}
