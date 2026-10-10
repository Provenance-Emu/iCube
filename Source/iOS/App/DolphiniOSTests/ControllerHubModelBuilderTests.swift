// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

/// Covers `ControllerHubModelBuilder` (controller hub spec, "Controllers hub"): rows per system,
/// "Show All Ports" collapsing, platform differences. Pure: every action is a recorded closure,
/// every destination an `EmptyView`, as in `PauseMenuModelBuilderTests`.
final class ControllerHubModelBuilderTests: XCTestCase {

  private static let xbox = "MFi/0/Xbox Wireless Controller"
  private static let touch = "iOS/4/Touchscreen"

  private func actions(
    toggleShowAllPorts: @escaping () -> Void = {},
    setOverlayVisible: @escaping (Bool) -> Void = { _ in },
    setOverlayMode: @escaping (ControllerManager.OverlayMode) -> Void = { _ in },
    setOverlayOpacity: @escaping (Float) -> Void = { _ in },
    editLayout: @escaping () -> Void = {},
    editIRArea: @escaping () -> Void = {},
    identifyPad: @escaping (String) -> Void = { _ in },
    setDevice: @escaping (PlayerState, PlayerDeviceChoice) -> Void = { _, _ in },
    setPlaysAs: @escaping (PlayerState, PlaysAs) -> Void = { _, _ in },
    setPointerMode: @escaping (PointerMode) -> Void = { _ in },
    setMotionPointer: @escaping (PlayerState, Bool) -> Void = { _, _ in },
    setBackgroundInput: @escaping (Bool) -> Void = { _ in },
    setRumbleDestination: @escaping (RumbleDestination) -> Void = { _ in },
    setConnectTakesPlayer1: @escaping (Bool) -> Void = { _ in },
    testRumble: @escaping () -> Void = {},
    setTouchOverlayProgrammatic: @escaping (Bool) -> Void = { _ in },
    resetOverlayLayouts: @escaping () -> Void = {}
  ) -> ControllerHubActions {
    ControllerHubActions(
      playerDestination: { _ in AnyView(EmptyView()) },
      toggleShowAllPorts: toggleShowAllPorts,
      setOverlayVisible: setOverlayVisible,
      setOverlayMode: setOverlayMode,
      setOverlayOpacity: setOverlayOpacity,
      editLayout: editLayout,
      editIRArea: editIRArea,
      skinsDestination: { AnyView(EmptyView()) },
      identifyPad: identifyPad,
      dsuDestination: { AnyView(EmptyView()) },
      setDevice: setDevice,
      setPlaysAs: setPlaysAs,
      setPointerMode: setPointerMode,
      setMotionPointer: setMotionPointer,
      setBackgroundInput: setBackgroundInput,
      setRumbleDestination: setRumbleDestination,
      setConnectTakesPlayer1: setConnectTakesPlayer1,
      testRumble: testRumble,
      setTouchOverlayProgrammatic: setTouchOverlayProgrammatic,
      resetOverlayLayouts: resetOverlayLayouts,
      lightsDestination: { AnyView(EmptyView()) })
  }

  /// Every port of `system`; `bound` maps a player id ("gc-1", "wii-2") to its device qualifier.
  private func state(
    system: ControllerSetupSystem,
    bound: [String: String] = [:],
    wiiExtension: [Int: Int] = [:],
    showAllPorts: Bool = false,
    pads: [ConnectedPadState] = [],
    isGameRunning: Bool = true,
    isPinned: Set<String> = [],
    pending: PendingHubChanges = PendingHubChanges()
  ) -> ControllerHubState {
    var hub = ControllerHubState.empty(system: system)
    hub.players = ControllerHubState.slots(for: system).map { slot in
      let id = (slot.kind == .gameCube ? "gc-" : "wii-") + String(slot.port)
      return PlayerState(
        kind: slot.kind, port: slot.port, deviceQualifier: bound[id] ?? "",
        wiiExtension: slot.kind == .wiiRemote ? (wiiExtension[slot.port] ?? 0) : 0, isSideways: false,
        isPinned: isPinned.contains(id))
    }
    hub.showAllPorts = showAllPorts
    hub.pads = pads
    hub.isGameRunning = isGameRunning
    hub.pending = pending
    return hub
  }

  private func make(_ state: ControllerHubState, _ actions: ControllerHubActions? = nil, platform: PlatformKind = .ios) -> MenuModel {
    ControllerHubModelBuilder.make(state: state, actions: actions ?? self.actions(), platform: platform)
  }

  private func ids(_ model: MenuModel, section id: String) -> [String] {
    model.sections.first { $0.id == id }?.items.map(\.id) ?? []
  }

  private func run(_ item: MenuItem?) {
    guard let item, case .action(let action) = item.role else { return XCTFail("not an action row") }
    action()
  }

  // MARK: Sections per platform

  func test_iOS_sectionOrder() {
    XCTAssertEqual(make(state(system: .gamecube)).sections.map(\.id), ["players", "touch-controls", "devices", "setup", "help"])
  }

  func test_tvOS_hasNoTouchControls() {
    XCTAssertEqual(make(state(system: .gamecube), platform: .tvos).sections.map(\.id), ["players", "devices", "setup", "help"])
  }

  // MARK: Players

  func test_slots_followTheSystem() {
    func ids(_ system: ControllerSetupSystem) -> [String] {
      ControllerHubState.slots(for: system).map { ($0.kind == .gameCube ? "gc-" : "wii-") + String($0.port) }
    }
    XCTAssertEqual(ids(.gamecube), ["gc-1", "gc-2", "gc-3", "gc-4"])
    XCTAssertEqual(ids(.wii), ["wii-1", "wii-2", "wii-3", "wii-4"])
    XCTAssertEqual(ids(.both), ["gc-1", "gc-2", "gc-3", "gc-4", "wii-1", "wii-2", "wii-3", "wii-4"])
    XCTAssertEqual(ids(.wiiAndGameCube), ["wii-1", "wii-2", "wii-3", "wii-4", "gc-1", "gc-2", "gc-3", "gc-4"])
  }

  func test_unboundPorts_collapseUnderShowAllPorts() {
    let model = make(state(system: .gamecube, bound: ["gc-1": Self.xbox]))
    XCTAssertEqual(ids(model, section: "players"), ["gc-1", "gc-1-device", "show-all-ports"])
    XCTAssertEqual(model.item(id: "show-all-ports")?.title, "Show All Ports")
    XCTAssertEqual(model.item(id: "show-all-ports")?.badge, "3")
  }

  func test_showAllPorts_listsEveryPortInTheRunningGamesOrder() {
    let model = make(state(system: .wiiAndGameCube, bound: ["wii-1": Self.touch], showAllPorts: true))
    XCTAssertEqual(
      ids(model, section: "players"),
      ["wii-1", "wii-1-device", "wii-1-plays-as", "wii-1-pointer",
       "wii-2", "wii-2-device", "wii-3", "wii-3-device", "wii-4", "wii-4-device",
       "gc-1", "gc-1-device", "gc-2", "gc-2-device", "gc-3", "gc-3-device", "gc-4", "gc-4-device", "show-all-ports"])
    XCTAssertEqual(model.item(id: "show-all-ports")?.title, "Hide Unused Ports")
    XCTAssertNil(model.item(id: "show-all-ports")?.badge)
  }

  func test_everyPortBound_hasNoShowAllRow() {
    let all = Dictionary(uniqueKeysWithValues: (1 ... 4).map { ("gc-\($0)", Self.xbox) })
    XCTAssertEqual(
      ids(make(state(system: .gamecube, bound: all)), section: "players"),
      (1 ... 4).flatMap { ["gc-\($0)", "gc-\($0)-device"] }, "a GameCube title has no Plays as row, and no Show All Ports")
  }

  func test_nothingBound_leavesOnlyShowAllPorts() {
    XCTAssertEqual(ids(make(state(system: .both)), section: "players"), ["show-all-ports"])
  }

  func test_showAllRow_runsItsAction() {
    var toggled = false
    let model = make(state(system: .gamecube), actions(toggleShowAllPorts: { toggled = true }))
    run(model.item(id: "show-all-ports"))
    XCTAssertTrue(toggled)
  }

  func test_playerRow_boundToAPadThatIsGone_saysDisconnected() {
    let model = make(state(system: .gamecube, bound: ["gc-2": "MFi/1/DualSense Wireless Controller"]))
    XCTAssertEqual(model.item(id: "gc-2-device")?.currentValueTitle, "DualSense Wireless Controller (Disconnected)")
  }

  /// A DSU device is never a GCController, so it is never in the pad list; the hub must name it,
  /// not call it disconnected (the player screen's rule, decision 11).
  func test_playerRow_boundToADSUDevice_namesIt() {
    let model = make(state(system: .gamecube, bound: ["gc-2": "DSUClient/0/Pad C"]))
    XCTAssertEqual(model.item(id: "gc-2-device")?.currentValueTitle, "Pad C")
  }

  func test_playerRow_pushesThePlayerScreen() {
    let model = make(state(system: .gamecube, bound: ["gc-1": Self.xbox]))
    guard case .destination = model.item(id: "gc-1")?.role else { return XCTFail("a player row must push") }
  }

  // MARK: Player groups

  func test_playerGroup_titleDevicePlaysAs_andPointerOnATouchscreenWiiRow() {
    let model = make(state(system: .wiiAndGameCube, bound: ["wii-1": Self.touch, "gc-2": Self.xbox], wiiExtension: [1: 1],
                           pads: [ConnectedPadState(qualifier: Self.xbox, name: "Xbox", batteryPercent: nil, isCharging: false, playerLabel: nil)]))
    XCTAssertEqual(ids(model, section: "players"), ["wii-1", "wii-1-device", "wii-1-plays-as", "wii-1-pointer", "gc-2", "gc-2-device", "gc-2-plays-as", "show-all-ports"])
    XCTAssertEqual(model.item(id: "wii-1")?.title, "Wii Remote 1")
    XCTAssertEqual(model.item(id: "wii-1")?.badge, "Wii Remote + Nunchuk", "the title row's badge mirrors Plays as (spec 7.1)")
    XCTAssertEqual(model.item(id: "gc-2")?.badge, "GameCube Controller")
    XCTAssertEqual(model.item(id: "wii-1-plays-as")?.currentValueTitle, "Wii Remote + Nunchuk")
    XCTAssertEqual(model.item(id: "wii-1-device")?.currentValueTitle, "Touchscreen")
    XCTAssertEqual(model.item(id: "gc-2-device")?.currentValueTitle, "Xbox")
    XCTAssertEqual(model.item(id: "gc-2-plays-as")?.currentValueTitle, "GameCube Controller")
  }

  func test_unboundPorts_underShowAllPorts_getOnlyTitleAndDevice() {
    let model = make(state(system: .wiiAndGameCube, bound: ["wii-1": Self.touch], showAllPorts: true))
    let players = ids(model, section: "players")
    for unbound in ["wii-2", "wii-3", "wii-4", "gc-1", "gc-2", "gc-3", "gc-4"] {
      XCTAssertTrue(players.contains(unbound))
      XCTAssertTrue(players.contains("\(unbound)-device"))
      XCTAssertFalse(players.contains("\(unbound)-plays-as"), unbound)
      XCTAssertFalse(players.contains("\(unbound)-pointer"), unbound)
      XCTAssertNil(model.item(id: unbound)?.badge, "an unbound port plays as nothing")
    }
    XCTAssertEqual(model.item(id: "wii-2-device")?.currentValueTitle, "None")
  }

  func test_playsAs_gameCubeTitle_hasNoPlaysAsRow() {
    let model = make(state(system: .gamecube, bound: ["gc-1": Self.xbox]))
    XCTAssertEqual(ids(model, section: "players"), ["gc-1", "gc-1-device", "show-all-ports"])
  }

  func test_playsAs_wiiOnlyTitle_hasNoGameCubeOption() {
    guard case .cycle(let options, _)? = make(state(system: .wii, bound: ["wii-1": Self.touch])).item(id: "wii-1-plays-as")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Wii Remote", "Wii Remote + Nunchuk", "Wii Remote + Classic Controller", "Sideways Wii Remote"])
  }

  func test_playsAs_cycleWritesThroughTheAction() {
    var chosen: (String, PlaysAs)?
    let model = make(state(system: .wiiAndGameCube, bound: ["wii-1": Self.touch]), actions(setPlaysAs: { chosen = ($0.id, $1) }))
    guard case .cycle(let options, let selection)? = model.item(id: "wii-1-plays-as")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Wii Remote", "Wii Remote + Nunchuk", "Wii Remote + Classic Controller", "Sideways Wii Remote", "GameCube Controller"])
    selection.wrappedValue = AnyHashable(PlaysAs.gameCube)
    XCTAssertEqual(chosen?.0, "wii-1")
    XCTAssertEqual(chosen?.1, .gameCube)
  }

  func test_pendingChoices_areShownAtOnce_whileTheGroupStaysPut() {
    var pending = PendingHubChanges()
    pending.playsAs["wii-1"] = .gameCube
    pending.devices["wii-1"] = .noDevice
    let model = make(state(system: .wiiAndGameCube, bound: ["wii-1": Self.touch], pending: pending))
    XCTAssertEqual(model.item(id: "wii-1-plays-as")?.currentValueTitle, "GameCube Controller")
    XCTAssertEqual(model.item(id: "wii-1-device")?.currentValueTitle, "None")
    XCTAssertEqual(model.item(id: "wii-1")?.badge, "GameCube Controller")
    XCTAssertNotNil(model.item(id: "wii-1-plays-as"), "the row keeps its id until the change is committed")
  }

  func test_device_cycleOffersNoneTouchscreenAndPads_andAutoOnAPinnedPort_andWritesTheChoice() {
    var chosen: (String, PlayerDeviceChoice)?
    let pads = [ConnectedPadState(qualifier: Self.xbox, name: "Xbox", batteryPercent: nil, isCharging: false, playerLabel: nil)]
    let hub = state(system: .gamecube, bound: ["gc-1": Self.xbox], pads: pads, isPinned: ["gc-1"])
    let model = make(hub, actions(setDevice: { chosen = ($0.id, $1) }))
    guard case .cycle(let options, let selection)? = model.item(id: "gc-1-device")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Auto", "None", "Touchscreen", "Xbox"])
    selection.wrappedValue = AnyHashable(PlayerDeviceChoice.touchscreen)
    XCTAssertEqual(chosen?.0, "gc-1")
    XCTAssertEqual(chosen?.1, .touchscreen)
    guard case .cycle(let tvOptions, _)? = make(hub, platform: .tvos).item(id: "gc-1-device")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(tvOptions.map(\.0), ["Auto", "None", "Xbox"], "no touchscreen on tvOS")
    XCTAssertEqual(model.item(id: "gc-1-device")?.description, PlayerScreenHelp.devicePinned, "a pinned port explains itself")
  }

  func test_pointerRow_touchscreenWii_cyclesPointerMode_gyroPad_togglesMotion_padWithoutGyro_none() {
    var mode: PointerMode?
    var motion: (String, Bool)?
    var hub = state(system: .wiiAndGameCube, bound: ["wii-1": Self.touch, "wii-2": Self.xbox, "wii-3": "MFi/1/Plain Pad"],
                    pads: [ConnectedPadState(qualifier: Self.xbox, name: "Xbox", batteryPercent: nil, isCharging: false, playerLabel: nil, hasGyro: true),
                           ConnectedPadState(qualifier: "MFi/1/Plain Pad", name: "Plain", batteryPercent: nil, isCharging: false, playerLabel: nil)])
    hub.pointerMode = .gyro
    hub.pointerIsThisGameOnly = true
    let model = make(hub, actions(setPointerMode: { mode = $0 }, setMotionPointer: { motion = ($0.id, $1) }))
    guard case .cycle(let options, let selection)? = model.item(id: "wii-1-pointer")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Touch – Follow", "Touch – Drag", "Gyro"])
    XCTAssertEqual(model.item(id: "wii-1-pointer")?.badge, "This game", "a per-game override shows on the cycle row")
    selection.wrappedValue = AnyHashable(PointerMode.touchDrag)
    XCTAssertEqual(mode, .touchDrag)
    guard case .toggle(let binding)? = model.item(id: "wii-2-pointer")?.role else { return XCTFail("toggle") }
    binding.wrappedValue = true
    XCTAssertEqual(motion?.0, "wii-2")
    XCTAssertEqual(motion?.1, true)
    XCTAssertNil(model.item(id: "wii-3-pointer"))
    XCTAssertNil(make(hub, platform: .tvos).item(id: "wii-1-pointer"), "no touchscreen pointer on tvOS")
  }

  func test_touchControls_layoutRow_isNamedLayout_withAutoGameCubeWiiRemote_andTheRightDescription() throws {
    let model = make(state(system: .wii))
    XCTAssertEqual(ids(model, section: "touch-controls"), ["touch-visible", "touch-layout", "touch-opacity", "touch-editable", "touch-edit-layout", "touch-edit-ir-area", "touch-skins", "touch-reset-layouts"])
    let layout = try XCTUnwrap(model.item(id: "touch-layout"))
    XCTAssertEqual(layout.title, "Layout")
    guard case .cycle(let options, _) = layout.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Auto", "GameCube", "Wii Remote"])
    let description = try XCTUnwrap(layout.description)
    XCTAssertTrue(description.contains("running game's system"))
    XCTAssertFalse(description.contains("Player 1"), "Auto follows the game, not Player 1's Plays as (EmulationScreen.isWiiSystem)")
  }

  func test_pendingLayout_isShownAtOnce() {
    var pending = PendingHubChanges()
    pending.overlayMode = .gamecube
    XCTAssertEqual(make(state(system: .gamecube, pending: pending)).item(id: "touch-layout")?.currentValueTitle, "GameCube")
  }

  func test_touchControls_toggles_and_resetRun_theirActions() {
    var programmatic: Bool?
    var resets = 0
    let model = make(state(system: .gamecube), actions(setTouchOverlayProgrammatic: { programmatic = $0 }, resetOverlayLayouts: { resets += 1 }))
    guard case .toggle(let binding)? = model.item(id: "touch-editable")?.role else { return XCTFail("toggle") }
    binding.wrappedValue = false
    XCTAssertEqual(programmatic, false)
    guard case .destructive(let reset)? = model.item(id: "touch-reset-layouts")?.role else { return XCTFail("destructive") }
    reset()
    XCTAssertEqual(resets, 1)
  }

  // MARK: Setup and lights

  func test_setup_rows_iOS_and_tvOS() {
    XCTAssertEqual(ids(make(state(system: .gamecube)), section: "setup"), ["background-input", "takes-player-1", "rumble", "rumble-test", "dsu"])
    XCTAssertEqual(ids(make(state(system: .gamecube), platform: .tvos), section: "setup"), ["background-input", "dsu"])
  }

  func test_setup_rowsWriteThroughTheirActions() {
    var log: [String] = []
    let model = make(state(system: .gamecube), actions(
      setBackgroundInput: { log.append("bg \($0)") }, setRumbleDestination: { log.append("rumble \($0)") },
      setConnectTakesPlayer1: { log.append("takes \($0)") }, testRumble: { log.append("test") }))
    guard case .toggle(let background)? = model.item(id: "background-input")?.role,
          case .toggle(let takes)? = model.item(id: "takes-player-1")?.role,
          case .cycle(let options, let rumble)? = model.item(id: "rumble")?.role else { return XCTFail("roles") }
    background.wrappedValue = true
    takes.wrappedValue = false
    XCTAssertEqual(options.map(\.0), ["Device Haptics", "Controller", "Both"])
    XCTAssertEqual(rumble.wrappedValue, AnyHashable(RumbleDestination.controller))
    rumble.wrappedValue = AnyHashable(RumbleDestination.both)
    run(model.item(id: "rumble-test"))
    XCTAssertEqual(log, ["bg true", "takes false", "rumble both", "test"])
  }

  func test_lightsRow_onlyWithALitPad() {
    var pad = ConnectedPadState(qualifier: Self.xbox, name: "Xbox", batteryPercent: nil, isCharging: false, playerLabel: nil)
    XCTAssertFalse(ids(make(state(system: .gamecube, pads: [pad])), section: "devices").contains("lights"))
    pad.hasLight = true
    XCTAssertTrue(ids(make(state(system: .gamecube, pads: [pad])), section: "devices").contains("lights"))
    XCTAssertFalse(ids(make(state(system: .gamecube, pads: [pad]), platform: .tvos), section: "devices").contains("lights"))
  }

  func test_focusRequest_isPassedToTheModel() {
    var hub = state(system: .wiiAndGameCube, bound: ["gc-1": Self.xbox])
    hub.focusRequest = "gc-1-plays-as"
    XCTAssertEqual(make(hub).focusRequest, "gc-1-plays-as")
    XCTAssertNil(make(state(system: .gamecube)).focusRequest)
  }

  // MARK: Touch Controls (iOS)

  func test_showHideAndLayoutRows_onlyWhileAGameRuns() {
    let running = ids(make(state(system: .gamecube, isGameRunning: true)), section: "touch-controls")
    XCTAssertTrue(running.contains("touch-visible"))
    XCTAssertTrue(running.contains("touch-layout"))
    XCTAssertEqual(
      ids(make(state(system: .gamecube, isGameRunning: false)), section: "touch-controls"),
      ["touch-opacity", "touch-editable", "touch-edit-layout", "touch-skins", "touch-reset-layouts"])
  }

  func test_showHideToggle_writesThroughTheAction() {
    var written: Bool?
    let model = make(state(system: .gamecube), actions(setOverlayVisible: { written = $0 }))
    guard case .toggle(let binding)? = model.item(id: "touch-visible")?.role else { return XCTFail("not a toggle") }
    binding.wrappedValue = true
    XCTAssertEqual(written, true)
  }

  func test_layoutCycle_offersAutoGameCubeWiiRemote_andWritesThroughTheAction() {
    var written: ControllerManager.OverlayMode?
    let model = make(state(system: .gamecube), actions(setOverlayMode: { written = $0 }))
    guard case .cycle(let options, let selection)? = model.item(id: "touch-layout")?.role else { return XCTFail("not a cycle") }
    XCTAssertEqual(model.item(id: "touch-layout")?.title, "Layout")
    XCTAssertEqual(options.map { $0.0 }, ["Auto", "GameCube", "Wii Remote"])
    XCTAssertEqual(selection.wrappedValue, AnyHashable(ControllerManager.OverlayMode.auto))
    selection.wrappedValue = AnyHashable(ControllerManager.OverlayMode.wii)
    XCTAssertEqual(written, .wii)
  }

  func test_opacityCycle_offersQuarterSteps_andWritesAFraction() {
    var written: Float?
    let model = make(state(system: .gamecube), actions(setOverlayOpacity: { written = $0 }))
    guard case .cycle(let options, let selection)? = model.item(id: "touch-opacity")?.role else { return XCTFail("not a cycle") }
    XCTAssertEqual(options.map { $0.0 }, ["25%", "50%", "75%", "100%"])
    selection.wrappedValue = AnyHashable(75)
    XCTAssertEqual(written, 0.75)
  }

  func test_opacitySnapsToTheNearestChoice() {
    XCTAssertEqual(ControllerHubState.snappedOpacityPercent(0.5), 50)
    XCTAssertEqual(ControllerHubState.snappedOpacityPercent(0.62), 50)
    XCTAssertEqual(ControllerHubState.snappedOpacityPercent(0.9), 100)
    XCTAssertEqual(ControllerHubState.snappedOpacityPercent(0.0), 25)
    XCTAssertEqual(ControllerHubState.snappedOpacityPercent(1.0), 100)
  }

  /// The editor covers the whole screen (the game's own canvas), so the row runs an action instead of
  /// pushing under the hub's navigation bar.
  func test_editLayout_runsAnAction() {
    for running in [true, false] {
      var asked = 0
      run(make(state(system: .gamecube, isGameRunning: running), actions(editLayout: { asked += 1 })).item(id: "touch-edit-layout"))
      XCTAssertEqual(asked, 1, "game running: \(running)")
    }
  }

  func test_skins_pushes_nextToEditLayout() {
    let model = make(state(system: .gamecube))
    guard case .destination = model.item(id: "touch-skins")?.role else {
      return XCTFail("Skins must push, not present")
    }
    let ids = model.sections.first { $0.id == "touch-controls" }?.items.map(\.id) ?? []
    let editLayout = ids.firstIndex(of: "touch-edit-layout")
    XCTAssertNotNil(editLayout)
    XCTAssertEqual(ids.firstIndex(of: "touch-skins"), editLayout.map { $0 + 1 }, "Skins sits right after Edit Layout")
  }

  func test_editIRArea_runsAnAction_rightAfterEditLayout_whenTheSystemHasAPointer() {
    var asked = 0
    let model = make(state(system: .wiiAndGameCube), actions(editIRArea: { asked += 1 }))
    XCTAssertEqual(
      Array(ids(model, section: "touch-controls").suffix(4)),
      ["touch-edit-layout", "touch-edit-ir-area", "touch-skins", "touch-reset-layouts"])
    run(model.item(id: "touch-edit-ir-area"))
    XCTAssertEqual(asked, 1)
    XCTAssertNotNil(make(state(system: .both, isGameRunning: false)).item(id: "touch-edit-ir-area"))
  }

  func test_editIRArea_hiddenInAGameCubeGame() {
    XCTAssertNil(make(state(system: .gamecube)).item(id: "touch-edit-ir-area"))
  }

  func test_skins_hiddenOnTvOS_andSoIsTheWholeSection() {
    let model = make(state(system: .gamecube), platform: .tvos)
    XCTAssertNil(model.item(id: "touch-skins"))
    XCTAssertNil(model.sections.first { $0.id == "touch-controls" })
  }

  func test_skins_listedWhenNoGameRuns() {
    XCTAssertNotNil(make(state(system: .both, isGameRunning: false)).item(id: "touch-skins"))
  }

  // MARK: Connected Devices

  func test_padRow_showsBatteryAndPlayer_andIdentifies() {
    var identified: String?
    let pads = [
      ConnectedPadState(qualifier: Self.xbox, name: "Xbox Wireless Controller", batteryPercent: 80, isCharging: false, playerLabel: "P1"),
      ConnectedPadState(qualifier: "MFi/1/DualSense Wireless Controller", name: "DualSense Wireless Controller", batteryPercent: 40, isCharging: true, playerLabel: nil),
    ]
    let model = make(state(system: .gamecube, pads: pads), actions(identifyPad: { identified = $0 }))
    let xbox = model.item(id: "pad-\(Self.xbox)")
    XCTAssertEqual(xbox?.title, "Xbox Wireless Controller")
    XCTAssertEqual(xbox?.subtitle, "Battery 80%")
    XCTAssertEqual(xbox?.badge, "P1")
    XCTAssertEqual(model.item(id: "pad-MFi/1/DualSense Wireless Controller")?.subtitle, "Battery 40% · Charging")
    run(xbox)
    XCTAssertEqual(identified, Self.xbox)
  }

  func test_noPads_showsADisabledPlaceholder() {
    let model = make(state(system: .gamecube))
    XCTAssertEqual(model.item(id: "no-pads")?.isEnabled, false)
    XCTAssertFalse(model.focusableIDs.contains("no-pads"))
  }

  /// Real Wii Remotes have no backend on iOS/tvOS, so the hub offers no scanning toggle.
  func test_devices_offerNoWiiRemoteScanning() {
    XCTAssertFalse(ids(make(state(system: .wiiAndGameCube)), section: "devices").contains("wiimote-scan"))
    XCTAssertFalse(ids(make(state(system: .both), platform: .tvos), section: "devices").contains("wiimote-scan"))
  }

  func test_dsuRow_summarisesTheClient_andPushes() {
    var hub = state(system: .gamecube)
    XCTAssertEqual(make(hub).item(id: "dsu")?.subtitle, "Off")
    hub.dsuClientEnabled = true
    hub.dsuServerCount = 2
    let model = make(hub)
    XCTAssertEqual(model.item(id: "dsu")?.subtitle, "On · 2 servers")
    guard case .destination = model.item(id: "dsu")?.role else { return XCTFail("DSU must push") }
  }

  func test_dsuRow_summarisesOneServerAsSingular() {
    var hub = state(system: .gamecube)
    hub.dsuClientEnabled = true
    hub.dsuServerCount = 1
    XCTAssertEqual(make(hub).item(id: "dsu")?.subtitle, "On · 1 server")
  }

  // MARK: Help

  /// A tvOS List scrolls only by moving focus, and a disabled row takes no focus, so Help rows are
  /// enabled no-op actions, or they would be unreachable below the fold.
  func test_helpRows_areEnabledSoTVOSCanReachThem() {
    let model = make(state(system: .gamecube), platform: .tvos)
    let help = ids(model, section: "help")
    XCTAssertFalse(help.isEmpty)
    XCTAssertTrue(help.allSatisfy { model.focusableIDs.contains($0) })
    XCTAssertEqual(model.sections.last?.id, "help")
  }

  func test_help_iOSListsPadRoutesOnly() {
    XCTAssertEqual(ControllerHelp.lines(platform: .ios).map(\.id), ["pause", "pause-chord", "fast-forward", "start"])
  }

  func test_help_tvOSAddsTheSiriRemote_withTheLongPressDuration() {
    let lines = ControllerHelp.lines(platform: .tvos)
    XCTAssertEqual(lines.map(\.id), ["pause", "pause-chord", "fast-forward", "start", "remote-pause", "remote-exit"])
    XCTAssertEqual(lines.last?.how, "Hold Back / Menu for \(Int(DOLMenuLongPressDuration)) s")
  }

  /// Settings with no game running lists every GameCube port and Wii Remote, GameCube first.
  func test_settingsWithoutAGame_listsBothSystems() {
    XCTAssertEqual(ControllerSetupSystem.forSettings, .both, "the test host runs no game")
  }
}
