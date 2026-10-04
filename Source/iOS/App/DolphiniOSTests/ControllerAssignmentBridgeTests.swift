// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// `ControllerAssignmentService` over the real `BridgeControllerConfigWriter`, so the rule
/// "keep a mapping only when it binds on the device now bound" is proven against Dolphin's own
/// expression binding rather than a fake's idea of it.
///
/// Everything runs on GameCube port 4 / Wii Remote 4, which the test host never drives, and the
/// port's device, type and Buttons mapping are put back afterwards.
final class ControllerAssignmentBridgeTests: XCTestCase {
  /// 1-based, as the bridges take it.
  private static let port = 4
  private static let buttonsGroup = 0
  /// A pad that is not connected: nothing can bind on it, like a touch mapping on a real pad.
  private static let padQualifier = "MFi/0/Gamepad"
  /// A second pad that is not connected either.
  private static let otherPadQualifier = "MFi/1/Other Gamepad"
  private static let unboundMarker = "—"

  private let service = ControllerAssignmentService(writer: BridgeControllerConfigWriter())
  private var savedGC: SavedSlot?
  private var savedWii: SavedSlot?

  private struct SavedSlot {
    let device: String
    let type: Int
    let buttons: [String]
  }

  override func setUp() {
    super.setUp()
    removeStashes()
    savedGC = SavedSlot(
      device: TVControllerMappingBridge.defaultDevice(forGCPort: Self.port) as String,
      type: DOLConfigBridge.gcPortDevice(forPort: Self.port),
      buttons: gcButtons())
    savedWii = SavedSlot(
      device: TVControllerMappingBridge.defaultDevice(forWiimote: Self.port) as String,
      type: DOLConfigBridge.wiimoteSource(for: Self.port),
      buttons: wiiButtons())
  }

  override func tearDown() {
    if let saved = savedGC {
      for (index, expression) in saved.buttons.enumerated() {
        TVControllerMappingBridge.setPadControlExpressionForPort(
          Self.port, group: Self.buttonsGroup, index: index,
          expression: expression == Self.unboundMarker ? "" : expression)
      }
      TVControllerMappingBridge.setDefaultDevice(saved.device, forGCPort: Self.port)
      DOLConfigBridge.setGCPortDeviceForPort(Self.port, device: saved.type)
    }
    if let saved = savedWii {
      for (index, expression) in saved.buttons.enumerated() {
        TVControllerMappingBridge.setWiimoteControlExpressionFor(
          Self.port, group: Self.buttonsGroup, index: index,
          expression: expression == Self.unboundMarker ? "" : expression)
      }
      TVControllerMappingBridge.setDefaultDevice(saved.device, forWiimote: Self.port)
      DOLConfigBridge.setWiimoteSourceFor(Self.port, source: saved.type)
    }
    // Replacing a pad's binding stashes its mapping; a stash left behind would be restored by the
    // next test that binds the same pad.
    removeStashes()
    super.tearDown()
  }

  // MARK: GameCube

  func test_padTakingATouchscreenPort_getsThePadProfile() throws {
    service.assignTouchscreen(toPlayer: Self.port - 1, system: .gamecube)
    XCTAssertEqual(try gcButtonA(), "`Button 0`", "precondition: the port holds the Touchscreen mapping")

    service.assign(qualifier: Self.padQualifier, toPlayer: Self.port - 1, system: .gamecube)

    XCTAssertEqual(try gcButtonA(), "`Button A`",
                   "a touch mapping binds nothing on a pad, so the pad's default profile must replace it")
  }

  func test_padTakingAClearedTouchscreenPort_getsThePadProfile() throws {
    service.assignTouchscreen(toPlayer: Self.port - 1, system: .gamecube)
    service.clear(player: Self.port - 1, system: .gamecube)
    XCTAssertEqual(try gcButtonA(), "`Button 0`", "precondition: clearing the device keeps the mapping")

    service.assign(qualifier: Self.padQualifier, toPlayer: Self.port - 1, system: .gamecube)

    XCTAssertEqual(try gcButtonA(), "`Button A`")
  }

  func test_deviceReturningToItsOwnMapping_keepsACustomBinding() throws {
    // The reconnect case 3613078adb protects, with the one device the simulator enumerates:
    // a mapping that binds on the device being bound is the user's, and stays.
    let touchscreen = try XCTUnwrap(
      (TVControllerMappingBridge.allQualifiedDevices() as [String]).first { $0.hasPrefix("iOS/") },
      "the test host enumerates no Touchscreen device")
    service.assignTouchscreen(toPlayer: Self.port - 1, system: .gamecube)
    TVControllerMappingBridge.setPadControlExpressionForPort(
      Self.port, group: Self.buttonsGroup, index: try gcIndexOfA(), expression: "`Button 1`")
    service.clear(player: Self.port - 1, system: .gamecube)

    service.assign(qualifier: touchscreen, toPlayer: Self.port - 1, system: .gamecube)

    XCTAssertEqual(try gcButtonA(), "`Button 1`", "a mapping that binds on the device must not be reloaded")
  }

  /// Phase 3 checklist item 9: a profile saved as "Touchscreen" from a pad's port carries that pad's
  /// `Device =` line and shadows the bundled Touchscreen profile. Binding the Touchscreen loads it,
  /// and the port must still end up on the Touchscreen.
  func test_aUserProfileNamedTouchscreen_doesNotMoveThePortOffTheTouchscreen() throws {
    let touchscreen = "iOS/\(Self.port - 1)/Touchscreen"
    try XCTSkipUnless((TVControllerMappingBridge.allQualifiedDevices() as [String]).contains(touchscreen),
                      "the test host enumerates no \(touchscreen)")
    try XCTSkipIf((TVControllerMappingBridge.userProfiles(forGCPort: Self.port) as [String]).contains("Touchscreen"),
                  "the test host has its own Touchscreen profile")
    TVControllerMappingBridge.setDefaultDevice(Self.padQualifier, forGCPort: Self.port)
    XCTAssertTrue(TVControllerMappingBridge.saveProfile("Touchscreen", forGCPort: Self.port))
    defer { _ = TVControllerMappingBridge.deleteProfile("Touchscreen", forGCPort: Self.port) }

    service.assignTouchscreen(toPlayer: Self.port - 1, system: .gamecube)

    XCTAssertEqual(TVControllerMappingBridge.defaultDevice(forGCPort: Self.port) as String, touchscreen,
                   "the profile's Device line must not take the port off the Touchscreen")
  }

  /// A pad's custom binding survives another pad taking its port: it is stashed under the pad and
  /// restored, not replaced by "Physical Controller", when the pad is bound again.
  func test_aPadsCustomMapping_comesBackAfterAnotherPadHadThePort() throws {
    service.assign(qualifier: Self.padQualifier, toPlayer: Self.port - 1, system: .gamecube)
    TVControllerMappingBridge.setPadControlExpressionForPort(
      Self.port, group: Self.buttonsGroup, index: try gcIndexOfA(), expression: "`Button X`")

    service.assign(qualifier: Self.otherPadQualifier, toPlayer: Self.port - 1, system: .gamecube)
    XCTAssertEqual(try gcButtonA(), "`Button A`", "precondition: the other pad gets its default profile")

    service.assign(qualifier: Self.padQualifier, toPlayer: Self.port - 1, system: .gamecube)

    XCTAssertEqual(try gcButtonA(), "`Button X`", "the first pad gets its own mapping back")
    XCTAssertEqual(TVControllerMappingBridge.defaultDevice(forGCPort: Self.port) as String, Self.padQualifier,
                   "the stash's Device line does not override the binding")
    XCTAssertFalse(TVControllerMappingBridge.restoreStashedMapping(forGCPort: Self.port, qualifier: Self.padQualifier),
                   "a restored stash is used up")
  }

  // MARK: Wii

  func test_padTakingATouchscreenWiimote_getsThePadProfile() throws {
    service.assignTouchscreen(toPlayer: Self.port - 1, system: .wii)
    XCTAssertEqual(try wiiButtonA(), "`Button 100`", "precondition: the slot holds the Touchscreen mapping")

    service.assign(qualifier: Self.padQualifier, toPlayer: Self.port - 1, system: .wii)

    XCTAssertEqual(try wiiButtonA(), "`Button A`")
  }

  // MARK: Helpers

  /// The test pads' stash files (`Config/MappingStash/<GCPad|Wiimote>/<qualifier, '/' as '_'>.ini`).
  private func removeStashes() {
    guard let root = DolphinPaths.userDirectoryURL()?.appendingPathComponent("Config/MappingStash") else { return }
    for directory in ["GCPad", "Wiimote"] {
      for qualifier in [Self.padQualifier, Self.otherPadQualifier] {
        let file = qualifier.replacingOccurrences(of: "/", with: "_") + ".ini"
        try? FileManager.default.removeItem(at: root.appendingPathComponent(directory).appendingPathComponent(file))
      }
    }
  }

  private func gcButtons() -> [String] {
    TVControllerMappingBridge.padControlExpressions(forGroup: Self.port, group: Self.buttonsGroup) as [String]
  }

  private func wiiButtons() -> [String] {
    TVControllerMappingBridge.wiimoteControlExpressions(forGroup: Self.port, group: Self.buttonsGroup) as [String]
  }

  private func gcIndexOfA() throws -> Int {
    let names = TVControllerMappingBridge.padControlNames(forGroup: Self.port, group: Self.buttonsGroup) as [String]
    return try XCTUnwrap(names.firstIndex(of: "A"), "GameCube Buttons group has no A: \(names)")
  }

  private func gcButtonA() throws -> String {
    gcButtons()[try gcIndexOfA()]
  }

  private func wiiButtonA() throws -> String {
    let names = TVControllerMappingBridge.wiimoteControlNames(forGroup: Self.port, group: Self.buttonsGroup) as [String]
    let index = try XCTUnwrap(names.firstIndex(of: "A"), "Wii Remote Buttons group has no A: \(names)")
    return wiiButtons()[index]
  }
}
