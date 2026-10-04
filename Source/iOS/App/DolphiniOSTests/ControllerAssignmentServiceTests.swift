// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

private final class FakeWriter: ControllerConfigWriting {
  var calls: [String] = []

  /// Per-port answer for `mappingBindsDevice`. Absent ports default to `false`
  /// (nothing binds), matching a never-configured slot, so the tests that
  /// expect a profile load stay unaffected. Not recorded into `calls` — it's a
  /// read, not a mutation; `bindCheckedAfter` records when it was asked.
  var mappingBindsByPort: [Int: Bool] = [:]
  /// `calls` as it stood each time `mappingBindsDevice` was asked.
  var bindCheckedAfter: [[String]] = []
  /// Per-port bound device, as `defaultDevice` reads it ("" when absent). A read: not recorded.
  var deviceByPort: [Int: String] = [:]
  /// Qualifiers with a stashed mapping. `restoreStashedMapping` consumes one and records
  /// "restore=…"; asking for one that is not there records nothing.
  var stashes: Set<String> = []

  func setGCPortActive(_ a: Bool, port: Int) { calls.append("activeGC=\(a)@\(port)") }
  func setWiimoteSource(emulated: Bool, port: Int) { calls.append("wiiSrc=\(emulated)@\(port)") }
  func setDefaultDevice(_ q: String, system: EmulatedSystem, port: Int) { calls.append("bind=\(q)@\(port)") }
  func clearDefaultDevice(system: EmulatedSystem, port: Int) { calls.append("clear@\(port)") }
  func defaultDevice(system: EmulatedSystem, port: Int) -> String { deviceByPort[port] ?? "" }
  func stashMapping(forQualifier q: String, system: EmulatedSystem, port: Int) {
    calls.append("stash=\(q)@\(port)")
    stashes.insert(q)
  }
  func restoreStashedMapping(forQualifier q: String, system: EmulatedSystem, port: Int) -> Bool {
    guard stashes.remove(q) != nil else { return false }
    calls.append("restore=\(q)@\(port)")
    return true
  }
  func mappingBindsDevice(system: EmulatedSystem, port: Int) -> Bool {
    bindCheckedAfter.append(calls)
    return mappingBindsByPort[port] ?? false
  }
  func defaultProfileName(forQualifier q: String) -> String? {
    if q.hasPrefix("MFi") { return "Physical Controller" }
    if q.hasPrefix("iOS/") { return "Touchscreen" }
    return nil
  }
  func loadProfile(_ n: String, system: EmulatedSystem, port: Int, restoreDevice: Bool) { calls.append("profile=\(n)@\(port)") }
  func assignTouchscreen(system: EmulatedSystem, port: Int) { calls.append("touch@\(port)") }
  func saveConfig(system: EmulatedSystem) { calls.append("save") }
}

final class ControllerAssignmentServiceTests: XCTestCase {

  func test_assignPhysical_GCPort2_activatesBindsProfilesSaves() {
    let fake = FakeWriter()
    let svc = ControllerAssignmentService(writer: fake)
    // 0-based port 1 == Player 2
    svc.assign(qualifier: "MFi/0/Gamepad", toPlayer: 1, system: .gamecube)
    XCTAssertEqual(
      fake.calls,
      ["activeGC=true@1", "bind=MFi/0/Gamepad@1", "profile=Physical Controller@1", "save"])
  }

  func test_assignPhysical_WiiPort3_activatesViaWiimoteSource() {
    let fake = FakeWriter()
    let svc = ControllerAssignmentService(writer: fake)
    // 0-based port 2 == Player 3
    svc.assign(qualifier: "MFi/0/Gamepad", toPlayer: 2, system: .wii)
    XCTAssertEqual(
      fake.calls,
      ["wiiSrc=true@2", "bind=MFi/0/Gamepad@2", "profile=Physical Controller@2", "save"])
  }

  func test_assign_mappingThatBindsTheDevice_keepsProfile() {
    // Simulates a reconnect after No Device: the slot still holds the pad's
    // mapping (a user-picked profile), because clearing a device never touches
    // the mapping. `assign` must not reload the device-default profile over it.
    let fake = FakeWriter()
    fake.mappingBindsByPort[1] = true
    let svc = ControllerAssignmentService(writer: fake)
    svc.assign(qualifier: "MFi/0/Gamepad", toPlayer: 1, system: .gamecube)
    XCTAssertEqual(
      fake.calls,
      ["activeGC=true@1", "bind=MFi/0/Gamepad@1", "save"],
      "a mapping that binds the device must be preserved, not overwritten by the device-default profile")
  }

  func test_assign_mappingThatBindsNothing_loadsDefaultProfile() {
    // A slot with no mapping yet (first bind), or one whose mapping was made
    // for another kind of device (the Touchscreen profile under a pad), gets
    // the device-default profile. Clearing a slot's device does not clear its
    // mapping, so "after a clear" is the second case, not the first.
    let fake = FakeWriter()
    fake.mappingBindsByPort[2] = false
    let svc = ControllerAssignmentService(writer: fake)
    svc.assign(qualifier: "MFi/0/Gamepad", toPlayer: 2, system: .wii)
    XCTAssertEqual(
      fake.calls,
      ["wiiSrc=true@2", "bind=MFi/0/Gamepad@2", "profile=Physical Controller@2", "save"])
  }

  func test_assign_asksWhetherTheMappingBindsOnlyAfterBindingTheDevice() {
    // Binding the device is what re-resolves the mapping against it; asking
    // first would judge the mapping against the previous device.
    let fake = FakeWriter()
    let svc = ControllerAssignmentService(writer: fake)
    svc.assign(qualifier: "MFi/0/Gamepad", toPlayer: 0, system: .gamecube)
    XCTAssertEqual(fake.bindCheckedAfter, [["activeGC=true@0", "bind=MFi/0/Gamepad@0"]])
  }

  func test_assign_unknownDevice_skipsProfile() {
    let fake = FakeWriter()
    let svc = ControllerAssignmentService(writer: fake)
    svc.assign(qualifier: "Mystery/0/Thing", toPlayer: 0, system: .gamecube)
    XCTAssertEqual(fake.calls, ["activeGC=true@0", "bind=Mystery/0/Thing@0", "save"])
  }

  func test_clear_clearsThenSaves() {
    let fake = FakeWriter()
    let svc = ControllerAssignmentService(writer: fake)
    svc.clear(player: 1, system: .gamecube)
    XCTAssertEqual(fake.calls, ["clear@1", "save"])
  }

  func test_assignTouchscreen_activatesThenBindsTouchscreen() {
    let fake = FakeWriter()
    let svc = ControllerAssignmentService(writer: fake)
    svc.assignTouchscreen(toPlayer: 0, system: .gamecube)
    // assignTouchscreen on the writer is responsible for its own save.
    XCTAssertEqual(fake.calls, ["activeGC=true@0", "touch@0"])
  }

  // MARK: Mapping stash

  /// The Touchscreen taking a pad's slot (the last pad disconnected, or the user picked it) keeps
  /// the pad's mapping first.
  func test_assignTouchscreen_overAPad_stashesThePadsMappingFirst() {
    let fake = FakeWriter()
    fake.deviceByPort[0] = "MFi/0/Gamepad"
    let svc = ControllerAssignmentService(writer: fake)
    svc.assignTouchscreen(toPlayer: 0, system: .gamecube)
    XCTAssertEqual(fake.calls, ["stash=MFi/0/Gamepad@0", "activeGC=true@0", "touch@0"])
  }

  /// The pad coming back gets its own mapping, not the device-default profile.
  func test_assign_aPadWithAStash_restoresItInsteadOfTheDefaultProfile() {
    let fake = FakeWriter()
    fake.deviceByPort[0] = "iOS/0/Touchscreen"
    fake.stashes = ["MFi/0/Gamepad"]
    let svc = ControllerAssignmentService(writer: fake)
    svc.assign(qualifier: "MFi/0/Gamepad", toPlayer: 0, system: .gamecube)
    XCTAssertEqual(fake.calls, ["activeGC=true@0", "bind=MFi/0/Gamepad@0", "restore=MFi/0/Gamepad@0", "save"])
    XCTAssertTrue(fake.stashes.isEmpty, "a restored stash is used up")
  }

  /// Another pad taking the slot stashes the first pad's mapping; the new pad has no stash, so the
  /// usual rule applies to it.
  func test_assign_anotherPadOverAPad_stashesTheFirstPadsMapping() {
    let fake = FakeWriter()
    fake.deviceByPort[1] = "MFi/0/Gamepad"
    let svc = ControllerAssignmentService(writer: fake)
    svc.assign(qualifier: "MFi/1/Other", toPlayer: 1, system: .wii)
    XCTAssertEqual(fake.calls, [
      "stash=MFi/0/Gamepad@1", "wiiSrc=true@1", "bind=MFi/1/Other@1", "profile=Physical Controller@1", "save",
    ])
  }

  /// Re-binding the device the slot already has stashes nothing and restores nothing: the slot holds
  /// that device's live mapping, newer than any stash.
  func test_assign_theDeviceTheSlotAlreadyHas_neitherStashesNorRestores() {
    let fake = FakeWriter()
    fake.deviceByPort[0] = "MFi/0/Gamepad"
    fake.stashes = ["MFi/0/Gamepad"]
    fake.mappingBindsByPort[0] = true
    let svc = ControllerAssignmentService(writer: fake)
    svc.assign(qualifier: "MFi/0/Gamepad", toPlayer: 0, system: .gamecube)
    XCTAssertEqual(fake.calls, ["activeGC=true@0", "bind=MFi/0/Gamepad@0", "save"])
  }

  func test_clear_aPad_stashesItsMapping() {
    let fake = FakeWriter()
    fake.deviceByPort[1] = "DSUClient/0/Pad C"
    let svc = ControllerAssignmentService(writer: fake)
    svc.clear(player: 1, system: .gamecube)
    XCTAssertEqual(fake.calls, ["stash=DSUClient/0/Pad C@1", "clear@1", "save"])
  }

  /// The Touchscreen's mapping comes back from its own profile; only real controllers are stashed.
  func test_replacingTheTouchscreen_stashesNothing() {
    let fake = FakeWriter()
    fake.deviceByPort[0] = "iOS/0/Touchscreen"
    let svc = ControllerAssignmentService(writer: fake)
    svc.clear(player: 0, system: .gamecube)
    svc.assign(qualifier: "MFi/0/Gamepad", toPlayer: 0, system: .gamecube)
    XCTAssertFalse(fake.calls.contains { $0.hasPrefix("stash=") }, "\(fake.calls)")
  }
}

/// `ControllerManager.reconcile()`'s writes (`ControllerAssignmentService.reconcile`, the engine's
/// decisions) against a config that remembers what each slot holds: a pad with a custom mapping
/// that disconnects and reconnects must get that mapping back.
private final class SimulatedConfig: ControllerConfigWriting {
  struct Slot: Equatable {
    var device = ""
    /// "touch:…" binds on the Touchscreen, "pad:…" on any pad, "" binds nothing.
    var mapping = ""
    var active = false
  }

  var gc = [Slot](repeating: Slot(), count: 4)
  var wii = [Slot](repeating: Slot(), count: 4)
  var stash: [String: String] = [:]

  static let touchscreen = "iOS/0/Touchscreen"

  func slot(_ system: EmulatedSystem, _ port: Int) -> Slot { system == .gamecube ? gc[port] : wii[port] }

  private func update(_ system: EmulatedSystem, _ port: Int, _ change: (inout Slot) -> Void) {
    switch system {
    case .gamecube: change(&gc[port])
    case .wii: change(&wii[port])
    }
  }

  /// What `ControllerStateStore.snapshot()` would read with `pads` connected.
  func state(pads: [String], isWii: Bool = false) -> ControllerStateStore.State {
    func assignments(_ slots: [Slot]) -> [ControllerStateStore.PortAssignment] {
      slots.enumerated().map { ControllerStateStore.PortAssignment(portOneBased: $0.offset + 1, defaultDeviceQualifier: $0.element.device) }
    }
    return ControllerStateStore.State(
      controllers: [], portAssignments: assignments(gc), wiimoteAssignments: assignments(wii),
      connectedQualifiers: [Self.touchscreen, "iOS/4/Touchscreen"] + pads, isWiiSystem: isWii,
      touchscreenHoldsWiimote1: false)
  }

  func setGCPortActive(_ active: Bool, port: Int) { gc[port].active = active }
  func setWiimoteSource(emulated: Bool, port: Int) { wii[port].active = emulated }
  func setDefaultDevice(_ qualifier: String, system: EmulatedSystem, port: Int) { update(system, port) { $0.device = qualifier } }
  func clearDefaultDevice(system: EmulatedSystem, port: Int) { update(system, port) { $0.device = "" } }
  func defaultDevice(system: EmulatedSystem, port: Int) -> String { slot(system, port).device }

  func mappingBindsDevice(system: EmulatedSystem, port: Int) -> Bool {
    let current = slot(system, port)
    guard !current.mapping.isEmpty else { return false }
    return current.device.hasPrefix("iOS/") == current.mapping.hasPrefix("touch:")
  }

  func defaultProfileName(forQualifier qualifier: String) -> String? {
    qualifier.hasPrefix("iOS/") ? "Touchscreen" : "Physical Controller"
  }

  func loadProfile(_ name: String, system: EmulatedSystem, port: Int, restoreDevice: Bool) {
    update(system, port) { $0.mapping = (name == "Touchscreen" ? "touch:" : "pad:") + name }
  }

  func stashMapping(forQualifier qualifier: String, system: EmulatedSystem, port: Int) {
    stash[qualifier] = slot(system, port).mapping
  }

  func restoreStashedMapping(forQualifier qualifier: String, system: EmulatedSystem, port: Int) -> Bool {
    guard let mapping = stash.removeValue(forKey: qualifier) else { return false }
    update(system, port) { $0.mapping = mapping }
    return true
  }

  /// As `assignTouchscreen(toGCPort:)` / BindTouchscreen: the profile loads when the device changes.
  func assignTouchscreen(system: EmulatedSystem, port: Int) {
    let touchscreen = "iOS/\(system == .gamecube ? port : 4 + port)/Touchscreen"
    update(system, port) { slot in
      if slot.device != touchscreen || slot.mapping.isEmpty { slot.mapping = "touch:Touchscreen" }
      slot.device = touchscreen
    }
  }

  func saveConfig(system: EmulatedSystem) {}
}

final class ControllerReconnectTests: XCTestCase {
  private let pad = "MFi/0/Gamepad"

  /// The reported bug: a custom GameCube mapping became "Physical Controller" after the pad's
  /// battery died, because the Touchscreen profile was loaded over it and nothing brought it back.
  func test_padDisconnectAndReconnect_keepsItsCustomMapping() {
    let config = SimulatedConfig()
    let service = ControllerAssignmentService(writer: config)

    service.reconcile(config.state(pads: [pad]), pinned: [], autoAssign: true)
    XCTAssertEqual(config.gc[0], SimulatedConfig.Slot(device: pad, mapping: "pad:Physical Controller", active: true))
    config.gc[0].mapping = "pad:custom"

    // Disconnect: the Touchscreen takes Player 1 so the game stays playable.
    service.reconcile(config.state(pads: []), pinned: [], autoAssign: true)
    XCTAssertEqual(config.gc[0].device, SimulatedConfig.touchscreen)
    XCTAssertEqual(config.gc[0].mapping, "touch:Touchscreen")

    // Reconnect: the pad takes Player 1 back with its own mapping.
    service.reconcile(config.state(pads: [pad]), pinned: [], autoAssign: true)
    XCTAssertEqual(config.gc[0], SimulatedConfig.Slot(device: pad, mapping: "pad:custom", active: true))
    XCTAssertTrue(config.stash.isEmpty)
  }

  /// With another pad still playing, the Touchscreen does not step in: the dropped pad keeps its
  /// binding and its mapping and simply comes back to them.
  func test_padDropsWhileAnotherPlays_comesBackToItsOwnSlot() {
    let config = SimulatedConfig()
    let service = ControllerAssignmentService(writer: config)
    let other = "MFi/1/Other"
    service.reconcile(config.state(pads: [pad, other]), pinned: [], autoAssign: true)
    config.gc[0].mapping = "pad:custom"

    service.reconcile(config.state(pads: [other]), pinned: [], autoAssign: true)
    XCTAssertEqual(config.gc[0].device, pad, "the binding waits for the pad")

    service.reconcile(config.state(pads: [pad, other]), pinned: [], autoAssign: true)
    XCTAssertEqual(config.gc[0], SimulatedConfig.Slot(device: pad, mapping: "pad:custom", active: true))
    XCTAssertEqual(config.gc[1].device, other)
  }

  /// The user gives Player 1 to the Touchscreen (pinned) while the pad is connected: the pad moves
  /// to the next free player and takes its mapping with it.
  func test_userPicksTheTouchscreen_thePadsMappingFollowsItToPlayer2() {
    let config = SimulatedConfig()
    let service = ControllerAssignmentService(writer: config)
    service.reconcile(config.state(pads: [pad]), pinned: [], autoAssign: true)
    config.gc[0].mapping = "pad:custom"

    service.assignTouchscreen(toPlayer: 0, system: .gamecube)
    let pinned: Set<PinnedSlot> = [PinnedSlot(system: .gamecube, playerZeroBased: 0)]
    service.reconcile(config.state(pads: [pad]), pinned: pinned, autoAssign: true)

    XCTAssertEqual(config.gc[0].device, SimulatedConfig.touchscreen)
    XCTAssertEqual(config.gc[1], SimulatedConfig.Slot(device: pad, mapping: "pad:custom", active: true))
  }

  /// Wii titles: the pad's Wii Remote mapping survives the same round trip through No Device.
  func test_wiiRemote_clearedThenReassigned_getsItsMappingBack() {
    let config = SimulatedConfig()
    let service = ControllerAssignmentService(writer: config)
    service.reconcile(config.state(pads: [pad], isWii: true), pinned: [], autoAssign: true)
    XCTAssertEqual(config.wii[0].device, pad)
    config.wii[0].mapping = "pad:custom"

    service.clear(player: 0, system: .wii)
    service.assignTouchscreen(toPlayer: 0, system: .wii)
    service.assign(qualifier: pad, toPlayer: 0, system: .wii)

    XCTAssertEqual(config.wii[0].mapping, "pad:custom")
  }
}
