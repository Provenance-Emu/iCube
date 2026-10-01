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

  func setGCPortActive(_ a: Bool, port: Int) { calls.append("activeGC=\(a)@\(port)") }
  func setWiimoteSource(emulated: Bool, port: Int) { calls.append("wiiSrc=\(emulated)@\(port)") }
  func setDefaultDevice(_ q: String, system: EmulatedSystem, port: Int) { calls.append("bind=\(q)@\(port)") }
  func clearDefaultDevice(system: EmulatedSystem, port: Int) { calls.append("clear@\(port)") }
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
    // Simulates a reconnect: the slot still holds the pad's mapping (a
    // user-picked profile) because `reconcileAssignments` only clears the
    // default-device binding on disconnect, never the mapping itself.
    // `assign` must not reload the device-default profile over it.
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
}
