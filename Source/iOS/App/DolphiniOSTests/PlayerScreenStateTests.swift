// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// The player screen's snapshot rules (which device a port has, whether it can capture, whether a
/// pad is "Disconnected") and the Save As name rules (decisions 10 and 11).
final class PlayerScreenStateTests: XCTestCase {

  private static let xbox = "MFi/0/Xbox Wireless Controller"
  private static let dsu = "DSUClient/0/Pad C"

  private func screen(_ qualifier: String, pads: [String] = []) -> PlayerScreenState {
    var state = PlayerScreenState.empty(
      PlayerState(kind: .gameCube, port: 1, deviceQualifier: qualifier, wiiExtension: 0, isSideways: false))
    state.pads = pads.map {
      ConnectedPadState(qualifier: $0, name: "Pad", batteryPercent: nil, isCharging: false, playerLabel: nil)
    }
    return state
  }

  func test_deviceChoice() {
    XCTAssertEqual(PlayerDeviceChoice(qualifier: ""), .noDevice)
    XCTAssertEqual(PlayerDeviceChoice(qualifier: "iOS/4/Touchscreen"), .touchscreen)
    XCTAssertEqual(PlayerDeviceChoice(qualifier: Self.xbox), .pad(Self.xbox))
    XCTAssertEqual(PlayerDeviceChoice(qualifier: Self.dsu), .pad(Self.dsu))
  }

  func test_connectedPad_canCapture() {
    let state = screen(Self.xbox, pads: [Self.xbox])
    XCTAssertFalse(state.isDisconnected)
    XCTAssertTrue(state.canCapture)
  }

  func test_missingMFiPad_isDisconnected_andCannotCapture() {
    let state = screen(Self.xbox)
    XCTAssertTrue(state.isDisconnected)
    XCTAssertFalse(state.canCapture)
  }

  /// DSU devices are not GCControllers, so they never appear in the pad list; they must still
  /// capture (RemapPlayerView's `deviceIsPhysical`) and never read "Disconnected".
  func test_dsuDevice_isNeverDisconnected_andCanCapture() {
    let state = screen(Self.dsu)
    XCTAssertFalse(state.isDisconnected)
    XCTAssertTrue(state.canCapture)
  }

  func test_touchscreenAndNoDevice_cannotCapture() {
    XCTAssertFalse(screen("iOS/0/Touchscreen").canCapture)
    XCTAssertFalse(screen("").canCapture)
    XCTAssertFalse(screen("").isDisconnected)
  }

  func test_snapped_picksTheNearestChoice_andOneForBrokenValues() {
    XCTAssertEqual(PointerMotionState.snapped(1.4, to: PointerMotionState.gyroSensitivityChoices), 1.5)
    XCTAssertEqual(PointerMotionState.snapped(0, to: PointerMotionState.dragGainChoices), 1)
    XCTAssertEqual(PointerMotionState.snapped(.nan, to: PointerMotionState.dragGainChoices), 1)
  }

  func test_editableExpression_neverTheUnboundDash() {
    XCTAssertEqual(RemapControlRow(owner: .gcPad, groupId: 0, index: 0, name: "A", expression: "—").editableExpression, "")
    XCTAssertEqual(RemapControlRow(owner: .gcPad, groupId: 0, index: 0, name: "A", expression: "`Button A`").editableExpression, "`Button A`")
  }

  // MARK: Save As names

  func test_sanitized_trimsAndReplacesSlashes() {
    XCTAssertEqual(ProfileNaming.sanitized("  My/Pad  "), "My-Pad")
  }

  /// A user profile with a device-default ("built-in") name is used instead of the bundled one for
  /// every future first bind and Reset (the user directory is searched first), so saving one asks.
  func test_builtInNames_areTheDeviceDefaults_caseInsensitively() {
    XCTAssertTrue(ProfileNaming.isBuiltIn("touchscreen"))
    XCTAssertTrue(ProfileNaming.isBuiltIn("Physical Controller"))
    XCTAssertFalse(ProfileNaming.isBuiltIn("My Pad"))
    for qualifier in ["MFi/0/Xbox", "iOS/0/Touchscreen", "DSUClient/0/Pad"] {
      let name = BridgeControllerConfigWriter().defaultProfileName(forQualifier: qualifier) ?? ""
      XCTAssertTrue(ProfileNaming.isBuiltIn(name), "\(name) is built in: it is what a first bind loads")
    }
  }

  func test_suggestion_isThePadName_elseThePlayerTitle_neverBuiltIn() {
    XCTAssertEqual(ProfileNaming.suggestion(padName: "Xbox Wireless Controller", playerTitle: "Player 1"), "Xbox Wireless Controller")
    XCTAssertEqual(ProfileNaming.suggestion(padName: nil, playerTitle: "Player 1"), "Player 1")
    XCTAssertEqual(ProfileNaming.suggestion(padName: "Touchscreen", playerTitle: "Wii Remote 1"), "Wii Remote 1")
  }

  func test_exists_isCaseInsensitive() {
    XCTAssertTrue(ProfileNaming.exists("my pad", in: ["My Pad", "DSU"]))
    XCTAssertFalse(ProfileNaming.exists("Other", in: ["My Pad"]))
  }
}
