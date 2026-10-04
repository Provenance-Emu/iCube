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

  func test_noControllers_emptyPad1_bindsTouchscreenToPad1() {
    let decision = AssignmentEngine().decide(from: state(gc: ["", "", "", ""], connected: [touchscreen]))
    XCTAssertEqual(decision.assignments,
                   [ControllerAssignment(qualifier: nil, playerZeroBased: 0, system: .gamecube)])
  }

  /// The last pad drops: it keeps its binding, so Pad 1 still names it. The Touchscreen takes Pad 1
  /// so the game stays playable; `ControllerAssignmentService.assignTouchscreen` stashes the pad's
  /// mapping first (it used to be overwritten by the Touchscreen profile for good).
  func test_lastPadDrops_touchscreenTakesPad1FromItsKeptBinding() {
    let decision = AssignmentEngine().decide(from: state(gc: [padA, "", "", ""], connected: [touchscreen]))
    XCTAssertEqual(decision.assignments,
                   [ControllerAssignment(qualifier: nil, playerZeroBased: 0, system: .gamecube)])
  }

  /// tvOS enumerates no Touchscreen: nothing can take Pad 1, and its binding waits for the pad.
  func test_lastPadDrops_noTouchscreen_pad1WaitsForThePad() {
    XCTAssertEqual(AssignmentEngine().decide(from: state(gc: [padA, "", "", ""], connected: [])), .none)
  }

  /// A pad that comes back while its binding is still in place needs nothing: its mapping never left.
  func test_padComingBackToItsKeptBinding_decidesNothing() {
    XCTAssertEqual(
      AssignmentEngine().decide(from: state(gc: [padA, "", "", ""], connected: [touchscreen, padA])), .none)
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
    // Pad B drops and keeps its binding on port 2; Pad A stays on port 1. On
    // reconnect B is already where it was: nothing moves.
    XCTAssertEqual(
      AssignmentEngine().decide(from: state(gc: [padA, padB, "", ""], connected: [padA, padB])), .none)
    // Port 2 emptied in the meantime (No Device): B lands back on port 2, not port 1.
    let decision = AssignmentEngine().decide(
      from: state(gc: [padA, "", "", ""], connected: [padA, padB]))
    XCTAssertEqual(decision.assignments,
                   [ControllerAssignment(qualifier: padB, playerZeroBased: 1, system: .gamecube)])
  }

  func test_staleBinding_isReusedByANewController() {
    // Port 1 still names a device that is no longer enumerated. The service stashes that
    // device's mapping before padB takes the port.
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

/// `AssignmentEngine.decideBoot`: the pre-boot pass that used to be `EnsurePad1DefaultsToTouchscreen`
/// in EmulationCoordinator.mm.
final class AssignmentEngineBootTests: XCTestCase {
  private let touchGC = ControllerAssignment(qualifier: nil, playerZeroBased: 0, system: .gamecube)
  private let touchWii = ControllerAssignment(qualifier: nil, playerZeroBased: 0, system: .wii)

  /// `gcActive` / `wiiActive` list the 1-based ports that play; every other port is off.
  private func boot(
    gc: [String] = ["", "", "", ""], gcActive: Set<Int> = [1],
    wii: [String] = ["", "", "", ""], wiiActive: Set<Int> = [1],
    connected: [String] = [touchscreen, wiiTouchscreen], isWii: Bool = false,
    pinned: Set<PinnedSlot> = []
  ) -> BootDecision {
    func slots(_ qualifiers: [String], _ active: Set<Int>) -> [ControllerStateStore.PortAssignment] {
      qualifiers.enumerated().map {
        ControllerStateStore.PortAssignment(
          portOneBased: $0.offset + 1, defaultDeviceQualifier: $0.element, isActive: active.contains($0.offset + 1))
      }
    }
    let state = ControllerStateStore.State(
      controllers: [], portAssignments: slots(gc, gcActive), wiimoteAssignments: slots(wii, wiiActive),
      connectedQualifiers: connected, isWiiSystem: isWii, touchscreenHoldsWiimote1: false)
    return AssignmentEngine().decideBoot(from: state, pinned: pinned)
  }

  func test_gameCubeTitle_freshInstall_touchscreenOnPlayer1AndWiiRemote1() {
    XCTAssertEqual(boot(), BootDecision(
      activatesGCPort1: true, activatesWiimote1: true, deactivatedWiimotes: [1, 2, 3], assignments: [touchGC, touchWii]))
  }

  /// A pad bound to Player 1 but switched off at boot: the Touchscreen takes Player 1 so the game is
  /// playable, and the service stashes the pad's mapping on the way (it used to be overwritten).
  func test_padSwitchedOffAtBoot_touchscreenTakesPlayer1() {
    XCTAssertEqual(boot(gc: [padA, "", "", ""], wii: [padA, "", "", ""]).assignments, [touchGC, touchWii])
  }

  func test_padConnectedAtBoot_keepsItsSlots() {
    let decision = boot(gc: [padA, "", "", ""], wii: [padA, padA, "", ""], connected: [touchscreen, padA])
    XCTAssertEqual(decision.assignments, [])
    XCTAssertEqual(decision.deactivatedWiimotes, [2, 3], "Wii Remote 2 is held by a connected pad")
  }

  /// The user's explicit choice holds at boot: a pinned Player 1 waits for its pad.
  func test_pinnedSlots_areLeftAlone() {
    let pinned: Set<PinnedSlot> = [
      PinnedSlot(system: .gamecube, playerZeroBased: 0),
      PinnedSlot(system: .wii, playerZeroBased: 0),
      PinnedSlot(system: .wii, playerZeroBased: 1),
    ]
    let decision = boot(
      gc: [padA, "", "", ""], wii: [padA, wiiTouchscreen, "", ""], wiiActive: [1, 2], pinned: pinned)
    XCTAssertEqual(decision.assignments, [])
    XCTAssertEqual(decision.deactivatedWiimotes, [2, 3], "a pinned Wii Remote 2 stays on")
  }

  /// One touchscreen per system: Wii Remote 1 does not take it while a pinned Wii Remote 2 has it.
  func test_aPinnedTouchscreenWiiRemote2_keepsWiiRemote1OffTheTouchscreen() {
    let decision = boot(
      wii: ["", "iOS/5/Touchscreen", "", ""], wiiActive: [1, 2], pinned: [PinnedSlot(system: .wii, playerZeroBased: 1)])
    XCTAssertEqual(decision.assignments, [touchGC])
  }

  /// A Wii title no longer plugs GameCube port 1 in; a Player 1 the user switched off stays off.
  func test_wiiTitle_player1SwitchedOff_staysOff() {
    let decision = boot(gc: [touchscreen, "", "", ""], gcActive: [], isWii: true)
    XCTAssertFalse(decision.activatesGCPort1)
    XCTAssertEqual(decision.assignments, [touchWii])
  }

  func test_wiiTitle_player1On_keepsTheTouchscreen() {
    let decision = boot(gc: [touchscreen, "", "", ""], isWii: true)
    XCTAssertFalse(decision.activatesGCPort1)
    XCTAssertEqual(decision.assignments, [touchGC, touchWii])
  }

  /// tvOS has no Touchscreen: only GameCube port 1 is written, as the C++ pass did.
  func test_noTouchscreen_onlyPlugsInPort1() {
    XCTAssertEqual(boot(gc: [padA, "", "", ""], connected: []), BootDecision(
      activatesGCPort1: true, activatesWiimote1: false, deactivatedWiimotes: [], assignments: []))
  }

  /// The reconcile pass follows the same rule for Player 1 in a Wii title.
  func test_reconcile_wiiTitle_player1SwitchedOff_noTouchscreenFallback() {
    let state = ControllerStateStore.State(
      controllers: [],
      portAssignments: [ControllerStateStore.PortAssignment(portOneBased: 1, defaultDeviceQualifier: padA, isActive: false)],
      wiimoteAssignments: [], connectedQualifiers: [touchscreen], isWiiSystem: true, touchscreenHoldsWiimote1: false)
    XCTAssertEqual(AssignmentEngine().decide(from: state), .none)
  }
}
