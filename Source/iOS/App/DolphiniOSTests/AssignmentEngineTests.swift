// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

private let touchscreen = "iOS/0/Touchscreen"
private let padA = "MFi/0/Gamepad A"
private let padB = "MFi/1/Gamepad B"
private let padC = "DSUClient/0/Pad C"
private let wiiTouchscreen = "iOS/4/Touchscreen"

/// `touchscreenHoldsWiimote1` is true on iOS while the on-screen controls are shown and Wii Remote 1
/// is on the Touchscreen; tvOS always passes false.
private func state(
  gc: [String],
  wii: [String] = ["", "", "", ""],
  connected: [String],
  isWii: Bool = false,
  touchscreenHoldsWiimote1: Bool = false
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
    isWiiSystem: isWii,
    touchscreenHoldsWiimote1: touchscreenHoldsWiimote1)
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

  func test_wiiSystem_assignsWiimoteSlot2_whileTheOnScreenControlsHoldSlot1() {
    let decision = AssignmentEngine().decide(
      from: state(gc: [padA, "", "", ""], wii: [wiiTouchscreen, "", "", ""],
                  connected: [wiiTouchscreen, padA], isWii: true, touchscreenHoldsWiimote1: true))
    XCTAssertEqual(decision.assignments,
                   [ControllerAssignment(qualifier: padA, playerZeroBased: 1, system: .wii)])
  }

  func test_wiiSystem_secondControllerGetsWiimote3_whileTheOnScreenControlsHoldSlot1() {
    let decision = AssignmentEngine().decide(
      from: state(gc: [padA, padB, "", ""], wii: [wiiTouchscreen, padA, "", ""],
                  connected: [wiiTouchscreen, padA, padB], isWii: true, touchscreenHoldsWiimote1: true))
    XCTAssertEqual(decision.assignments,
                   [ControllerAssignment(qualifier: padB, playerZeroBased: 2, system: .wii)])
  }

  /// iOS with the on-screen controls hidden: Wii Remote 1 still names the Touchscreen, but
  /// nothing is using it, so a lone pad takes it instead of landing on Wii Remote 2.
  func test_wiiSystem_lonePadTakesWiimote1_whenTheOnScreenControlsAreHidden() {
    let decision = AssignmentEngine().decide(
      from: state(gc: [touchscreen, "", "", ""], wii: [wiiTouchscreen, "", "", ""],
                  connected: [touchscreen, wiiTouchscreen, padA], isWii: true, touchscreenHoldsWiimote1: false))
    XCTAssertEqual(decision.assignments,
                   [ControllerAssignment(qualifier: padA, playerZeroBased: 0, system: .wii)])
  }

  /// tvOS has no touchscreen to hold Wii Remote 1 (the snapshot always says false there).
  func test_tvOS_wiiSystem_firstPadIsWiimote1_secondIsWiimote2() {
    let decision = AssignmentEngine().decide(
      from: state(gc: ["", "", "", ""], wii: ["", "", "", ""],
                  connected: [padA, padB], isWii: true, touchscreenHoldsWiimote1: false))
    XCTAssertEqual(decision.assignments, [
      ControllerAssignment(qualifier: padA, playerZeroBased: 0, system: .wii),
      ControllerAssignment(qualifier: padB, playerZeroBased: 1, system: .wii),
    ])
  }

  func test_gameCubeSystem_neverTouchesWiimoteSlots() {
    let decision = AssignmentEngine().decide(
      from: state(gc: [padA, "", "", ""], wii: ["", "", "", ""],
                  connected: [padA], isWii: false))
    XCTAssertEqual(decision, .none)
  }

  /// One pad, one emulated controller: a Wii title gets a Wii Remote, not a GameCube port as well.
  func test_wiiSystem_bindsAFreshControllerToAWiiRemoteOnly() {
    let decision = AssignmentEngine().decide(
      from: state(gc: ["", "", "", ""], wii: ["", "", "", ""],
                  connected: [padA], isWii: true))
    XCTAssertEqual(decision.assignments, [
      ControllerAssignment(qualifier: padA, playerZeroBased: 0, system: .wii),
    ])
  }

  func test_wiiSystem_leavesAnExistingGameCubeBindingAlone() {
    let decision = AssignmentEngine().decide(
      from: state(gc: [padA, "", "", ""], wii: ["", "", "", ""],
                  connected: [padA, padB], isWii: true, touchscreenHoldsWiimote1: false))
    XCTAssertEqual(decision.assignments, [
      ControllerAssignment(qualifier: padA, playerZeroBased: 0, system: .wii),
      ControllerAssignment(qualifier: padB, playerZeroBased: 1, system: .wii),
    ], "padB gets no GameCube port in a Wii title")
  }
}
