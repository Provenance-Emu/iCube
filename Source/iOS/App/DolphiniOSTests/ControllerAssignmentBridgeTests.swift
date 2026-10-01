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

  // MARK: Wii

  func test_padTakingATouchscreenWiimote_getsThePadProfile() throws {
    service.assignTouchscreen(toPlayer: Self.port - 1, system: .wii)
    XCTAssertEqual(try wiiButtonA(), "`Button 100`", "precondition: the slot holds the Touchscreen mapping")

    service.assign(qualifier: Self.padQualifier, toPlayer: Self.port - 1, system: .wii)

    XCTAssertEqual(try wiiButtonA(), "`Button A`")
  }

  // MARK: Helpers

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
