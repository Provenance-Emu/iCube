// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

private let touchscreen = "iOS/0/Touchscreen"
private let padA = "MFi/0/Gamepad A"
private let padB = "MFi/1/Gamepad B"
private let padC = "DSUClient/0/Pad C"

private func state(
  gc: [String],
  wii: [String] = ["", "", "", ""],
  connected: [String],
  isWii: Bool = false
) -> ControllerStateStore.State {
  func slots(_ qualifiers: [String]) -> [ControllerStateStore.PortAssignment] {
    qualifiers.enumerated().map {
      ControllerStateStore.PortAssignment(portOneBased: $0.offset + 1, defaultDeviceQualifier: $0.element)
    }
  }
  return ControllerStateStore.State(
    controllers: [],
    portAssignments: slots(gc),
    wiimoteAssignments: slots(wii),
    connectedQualifiers: connected,
    isWiiSystem: isWii)
}

final class AssignmentEngineTests: XCTestCase {

  // MARK: Touchscreen fallback

  func test_noControllers_bindsTouchscreenToPad1() {
    let decision = AssignmentEngine().decide(from: state(gc: ["", "", "", ""], connected: [touchscreen]))
    XCTAssertEqual(decision.assignments,
                   [ControllerAssignment(qualifier: nil, playerZeroBased: 0, system: .gamecube)])
  }

  func test_touchscreenAlreadyOnPad1_decidesNothing() {
    let decision = AssignmentEngine().decide(
      from: state(gc: [touchscreen, "", "", ""], connected: [touchscreen]))
    XCTAssertEqual(decision, .none)
  }

  // MARK: Auto-assign

  func test_firstController_takesPad1FromTouchscreen() {
    let decision = AssignmentEngine().decide(
      from: state(gc: [touchscreen, "", "", ""], connected: [touchscreen, padA]))
    XCTAssertEqual(decision.assignments,
                   [ControllerAssignment(qualifier: padA, playerZeroBased: 0, system: .gamecube)])
  }

  func test_secondController_takesPad2_leavingPad1Alone() {
    let decision = AssignmentEngine().decide(
      from: state(gc: [padA, "", "", ""], connected: [padA, padB]))
    XCTAssertEqual(decision.assignments,
                   [ControllerAssignment(qualifier: padB, playerZeroBased: 1, system: .gamecube)])
  }

  func test_threeControllers_fillPads1to3_inEnumerationOrder() {
    let decision = AssignmentEngine().decide(
      from: state(gc: ["", "", "", ""], connected: [padA, padB, padC]))
    XCTAssertEqual(decision.assignments, [
      ControllerAssignment(qualifier: padA, playerZeroBased: 0, system: .gamecube),
      ControllerAssignment(qualifier: padB, playerZeroBased: 1, system: .gamecube),
      ControllerAssignment(qualifier: padC, playerZeroBased: 2, system: .gamecube),
    ])
  }

  // MARK: Stability — the point of collapsing six writers into one

  func test_isIdempotent_everythingAlreadyAssigned() {
    let decision = AssignmentEngine().decide(
      from: state(gc: [padA, padB, "", ""], connected: [padA, padB]))
    XCTAssertEqual(decision, .none)
  }

  func test_userPlacedControllerOnPad2_isNotMovedToPad1() {
    let decision = AssignmentEngine().decide(
      from: state(gc: ["", padA, "", ""], connected: [padA]))
    XCTAssertEqual(decision, .none)
  }

  func test_reconnectAfterDrop_returnsToTheSamePort() {
    // Pad B drops: its binding is cleared by the mechanical C++ pass, Pad A
    // stays on port 1. On reconnect B must land back on port 2, not port 1.
    let decision = AssignmentEngine().decide(
      from: state(gc: [padA, "", "", ""], connected: [padA, padB]))
    XCTAssertEqual(decision.assignments,
                   [ControllerAssignment(qualifier: padB, playerZeroBased: 1, system: .gamecube)])
  }

  func test_staleBinding_isReusedByANewController() {
    // Port 1 still names a device that is no longer enumerated.
    let decision = AssignmentEngine().decide(
      from: state(gc: [padA, "", "", ""], connected: [padB]))
    XCTAssertEqual(decision.assignments,
                   [ControllerAssignment(qualifier: padB, playerZeroBased: 0, system: .gamecube)])
  }

  func test_allPortsTakenByConnectedDevices_extraControllerIsDropped() {
    let decision = AssignmentEngine().decide(
      from: state(gc: [padA, padB, padC, padA], connected: [padA, padB, padC, "MFi/9/Extra"]))
    XCTAssertEqual(decision, .none)
  }

  // MARK: Wii

  func test_wiiSystem_assignsWiimoteSlot2_reservingSlot1ForTouchOverlay() {
    let decision = AssignmentEngine().decide(
      from: state(gc: [padA, "", "", ""], wii: ["", "", "", ""],
                  connected: [padA], isWii: true))
    XCTAssertEqual(decision.assignments,
                   [ControllerAssignment(qualifier: padA, playerZeroBased: 1, system: .wii)])
  }

  func test_wiiSystem_secondControllerGetsWiimote3() {
    let decision = AssignmentEngine().decide(
      from: state(gc: [padA, padB, "", ""], wii: ["", padA, "", ""],
                  connected: [padA, padB], isWii: true))
    XCTAssertEqual(decision.assignments,
                   [ControllerAssignment(qualifier: padB, playerZeroBased: 2, system: .wii)])
  }

  func test_gameCubeSystem_neverTouchesWiimoteSlots() {
    let decision = AssignmentEngine().decide(
      from: state(gc: [padA, "", "", ""], wii: ["", "", "", ""],
                  connected: [padA], isWii: false))
    XCTAssertEqual(decision, .none)
  }

  func test_wiiSystem_assignsBothGCPortAndWiimote_forAFreshController() {
    let decision = AssignmentEngine().decide(
      from: state(gc: ["", "", "", ""], wii: ["", "", "", ""],
                  connected: [padA], isWii: true))
    XCTAssertEqual(decision.assignments, [
      ControllerAssignment(qualifier: padA, playerZeroBased: 0, system: .gamecube),
      ControllerAssignment(qualifier: padA, playerZeroBased: 1, system: .wii),
    ])
  }
}
