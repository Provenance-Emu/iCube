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
    identifyPad: @escaping (String) -> Void = { _ in },
    setContinuousScanning: @escaping (Bool) -> Void = { _ in }
  ) -> ControllerHubActions {
    ControllerHubActions(
      playerDestination: { _ in AnyView(EmptyView()) },
      toggleShowAllPorts: toggleShowAllPorts,
      setOverlayVisible: setOverlayVisible,
      setOverlayMode: setOverlayMode,
      setOverlayOpacity: setOverlayOpacity,
      editLayoutDestination: { AnyView(EmptyView()) },
      identifyPad: identifyPad,
      setContinuousScanning: setContinuousScanning,
      dsuDestination: { AnyView(EmptyView()) },
      moreSettingsDestination: { AnyView(EmptyView()) })
  }

  /// Every port of `system`; `bound` maps a player id ("gc-1", "wii-2") to its device qualifier.
  private func state(
    system: ControllerSetupSystem,
    bound: [String: String] = [:],
    wiiExtension: [Int: Int] = [:],
    showAllPorts: Bool = false,
    pads: [ConnectedPadState] = [],
    isGameRunning: Bool = true
  ) -> ControllerHubState {
    var hub = ControllerHubState.empty(system: system)
    hub.players = ControllerHubState.slots(for: system).map { slot in
      let id = (slot.kind == .gameCube ? "gc-" : "wii-") + String(slot.port)
      return PlayerState(
        kind: slot.kind, port: slot.port, deviceQualifier: bound[id] ?? "",
        wiiExtension: slot.kind == .wiiRemote ? (wiiExtension[slot.port] ?? 0) : 0, isSideways: false)
    }
    hub.showAllPorts = showAllPorts
    hub.pads = pads
    hub.isGameRunning = isGameRunning
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
    XCTAssertEqual(make(state(system: .gamecube)).sections.map(\.id), ["players", "on-screen", "devices", "more", "help"])
  }

  func test_tvOS_hasNoOnScreenControls() {
    XCTAssertEqual(make(state(system: .gamecube), platform: .tvos).sections.map(\.id), ["players", "devices", "more", "help"])
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
    XCTAssertEqual(ids(model, section: "players"), ["gc-1", "show-all-ports"])
    XCTAssertEqual(model.item(id: "show-all-ports")?.title, "Show All Ports")
    XCTAssertEqual(model.item(id: "show-all-ports")?.badge, "3")
  }

  func test_showAllPorts_listsEveryPortInTheRunningGamesOrder() {
    let model = make(state(system: .wiiAndGameCube, bound: ["wii-1": Self.touch], showAllPorts: true))
    XCTAssertEqual(
      ids(model, section: "players"),
      ["wii-1", "wii-2", "wii-3", "wii-4", "gc-1", "gc-2", "gc-3", "gc-4", "show-all-ports"])
    XCTAssertEqual(model.item(id: "show-all-ports")?.title, "Hide Unused Ports")
    XCTAssertNil(model.item(id: "show-all-ports")?.badge)
  }

  func test_everyPortBound_hasNoShowAllRow() {
    let all = Dictionary(uniqueKeysWithValues: (1 ... 4).map { ("gc-\($0)", Self.xbox) })
    XCTAssertEqual(ids(make(state(system: .gamecube, bound: all)), section: "players"), ["gc-1", "gc-2", "gc-3", "gc-4"])
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

  func test_playerRow_namesThePortTheDeviceAndTheEmulatedController() {
    let pad = ConnectedPadState(qualifier: Self.xbox, name: "Xbox Wireless Controller", batteryPercent: nil, isCharging: false, playerLabel: "P1")
    let model = make(state(system: .wiiAndGameCube, bound: ["gc-1": Self.xbox, "wii-1": Self.touch], wiiExtension: [1: 1], pads: [pad]))
    XCTAssertEqual(model.item(id: "gc-1")?.title, "Player 1")
    XCTAssertEqual(model.item(id: "gc-1")?.subtitle, "Xbox Wireless Controller · GameCube Controller")
    XCTAssertEqual(model.item(id: "wii-1")?.title, "Wii Remote 1")
    XCTAssertEqual(model.item(id: "wii-1")?.subtitle, "Touchscreen · Wii Remote + Nunchuk")
  }

  func test_playerRow_boundToAPadThatIsGone_saysDisconnected() {
    let model = make(state(system: .gamecube, bound: ["gc-2": "MFi/1/DualSense Wireless Controller"]))
    XCTAssertEqual(model.item(id: "gc-2")?.subtitle, "DualSense Wireless Controller (Disconnected) · GameCube Controller")
  }

  func test_playerRow_pushesThePlayerScreen() {
    let model = make(state(system: .gamecube, bound: ["gc-1": Self.xbox]))
    guard case .destination = model.item(id: "gc-1")?.role else { return XCTFail("a player row must push") }
  }

  // MARK: On-Screen Controls (iOS)

  func test_showHideAndStyleRows_onlyWhileAGameRuns() {
    let running = ids(make(state(system: .gamecube, isGameRunning: true)), section: "on-screen")
    XCTAssertTrue(running.contains("osc-visible"))
    XCTAssertTrue(running.contains("osc-style"))
    XCTAssertEqual(
      ids(make(state(system: .gamecube, isGameRunning: false)), section: "on-screen"),
      ["osc-opacity", "osc-edit-layout"])
  }

  func test_showHideToggle_writesThroughTheAction() {
    var written: Bool?
    let model = make(state(system: .gamecube), actions(setOverlayVisible: { written = $0 }))
    guard case .toggle(let binding)? = model.item(id: "osc-visible")?.role else { return XCTFail("not a toggle") }
    binding.wrappedValue = true
    XCTAssertEqual(written, true)
  }

  func test_stylePicker_offersAutoGameCubeWii_andWritesThroughTheAction() {
    var written: ControllerManager.OverlayMode?
    let model = make(state(system: .gamecube), actions(setOverlayMode: { written = $0 }))
    guard case .picker(let options, let selection)? = model.item(id: "osc-style")?.role else { return XCTFail("not a picker") }
    XCTAssertEqual(options.map { $0.0 }, ["Auto", "GameCube", "Wii"])
    XCTAssertEqual(selection.wrappedValue, AnyHashable(ControllerManager.OverlayMode.auto))
    selection.wrappedValue = AnyHashable(ControllerManager.OverlayMode.wii)
    XCTAssertEqual(written, .wii)
  }

  func test_opacityPicker_offersQuarterSteps_andWritesAFraction() {
    var written: Float?
    let model = make(state(system: .gamecube), actions(setOverlayOpacity: { written = $0 }))
    guard case .picker(let options, let selection)? = model.item(id: "osc-opacity")?.role else { return XCTFail("not a picker") }
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

  func test_editLayout_pushes() {
    guard case .destination = make(state(system: .gamecube)).item(id: "osc-edit-layout")?.role else {
      return XCTFail("Edit Layout must push, not present")
    }
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

  func test_continuousScanning_onlyWhenTheSystemHasWiiRemotes() {
    XCTAssertFalse(ids(make(state(system: .gamecube)), section: "devices").contains("wiimote-scan"))
    XCTAssertTrue(ids(make(state(system: .wiiAndGameCube)), section: "devices").contains("wiimote-scan"))
    XCTAssertTrue(ids(make(state(system: .both), platform: .tvos), section: "devices").contains("wiimote-scan"))
  }

  func test_continuousScanning_writesThroughTheAction() {
    var written: Bool?
    let model = make(state(system: .wii), actions(setContinuousScanning: { written = $0 }))
    guard case .toggle(let binding)? = model.item(id: "wiimote-scan")?.role else { return XCTFail("not a toggle") }
    binding.wrappedValue = true
    XCTAssertEqual(written, true)
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

  // MARK: More and Help

  func test_moreSettings_pushes() {
    guard case .destination = make(state(system: .gamecube)).item(id: "more-settings")?.role else {
      return XCTFail("More Controller Settings must push")
    }
  }

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
