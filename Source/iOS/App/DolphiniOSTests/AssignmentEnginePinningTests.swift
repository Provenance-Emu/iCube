// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// Pinned slots are the user's explicit choices; the engine must never auto-assign over them.
final class AssignmentEnginePinningTests: XCTestCase {
  private let touchscreen = "iOS/0/Touchscreen"
  private let pad = "MFi/0/Gamepad A"

  private func state(
    gc: [String], wii: [String] = ["", "", "", ""], connected: [String], isWii: Bool = false,
    touchscreenHoldsWiimote1: Bool = false
  ) -> ControllerStateStore.State {
    func slots(_ q: [String]) -> [ControllerStateStore.PortAssignment] {
      q.enumerated().map { ControllerStateStore.PortAssignment(portOneBased: $0.offset + 1, defaultDeviceQualifier: $0.element) }
    }
    return ControllerStateStore.State(controllers: [], portAssignments: slots(gc), wiimoteAssignments: slots(wii),
                                      connectedQualifiers: connected, isWiiSystem: isWii,
                                      touchscreenHoldsWiimote1: touchscreenHoldsWiimote1)
  }

  func test_connectedPad_doesNotTakeAPinnedTouchscreenSlot() {
    let s = state(gc: [touchscreen, "", "", ""], connected: [touchscreen, pad])
    let unpinned = AssignmentEngine().decide(from: s)
    XCTAssertEqual(unpinned.assignments, [ControllerAssignment(qualifier: pad, playerZeroBased: 0, system: .gamecube)])
    let pinned = AssignmentEngine().decide(from: s, pinned: [PinnedSlot(system: .gamecube, playerZeroBased: 0)])
    XCTAssertEqual(pinned.assignments, [ControllerAssignment(qualifier: pad, playerZeroBased: 1, system: .gamecube)],
                   "the pad goes to the next free slot instead")
  }

  func test_touchscreenFallback_respectsAPinnedPort1() {
    let s = state(gc: ["", "", "", ""], connected: [touchscreen])
    XCTAssertEqual(AssignmentEngine().decide(from: s).assignments,
                   [ControllerAssignment(qualifier: nil, playerZeroBased: 0, system: .gamecube)])
    XCTAssertTrue(AssignmentEngine().decide(from: s, pinned: [PinnedSlot(system: .gamecube, playerZeroBased: 0)]).assignments.isEmpty)
  }

  func test_pinsAreSystemSpecific() {
    let s = state(gc: [touchscreen, "", "", ""], wii: ["iOS/4/Touchscreen", "", "", ""], connected: [touchscreen, pad],
                  isWii: true, touchscreenHoldsWiimote1: true)
    let decision = AssignmentEngine().decide(
      from: s, pinned: [PinnedSlot(system: .wii, playerZeroBased: 1), PinnedSlot(system: .gamecube, playerZeroBased: 2)])
    XCTAssertEqual(decision.assignments, [
      ControllerAssignment(qualifier: pad, playerZeroBased: 2, system: .wii),
    ], "Wii slot 2 is pinned, so the pad lands on Wii slot 3; the GameCube pin on port 3 does not block it")
  }

  /// The Device list's Auto unpins the slot (`ControllerManager.unpinAndReassign`): the next
  /// controller may take it again. A pad already playing on another slot stays where it is.
  func test_unpinnedByAuto_theNextControllerTakesTheSlot() {
    let padB = "MFi/1/Gamepad B"
    let s = state(gc: [touchscreen, pad, "", ""], connected: [touchscreen, pad, padB])
    let pinned = AssignmentEngine().decide(from: s, pinned: [PinnedSlot(system: .gamecube, playerZeroBased: 0)])
    XCTAssertEqual(pinned.assignments, [ControllerAssignment(qualifier: padB, playerZeroBased: 2, system: .gamecube)])
    XCTAssertEqual(AssignmentEngine().decide(from: s).assignments,
                   [ControllerAssignment(qualifier: padB, playerZeroBased: 0, system: .gamecube)])
  }

  /// A pinned slot whose pad is switched off waits for that pad: no Touchscreen fallback, and the pad
  /// is already bound there when it comes back (its binding is kept across a disconnect).
  func test_aPinnedPlayer1_waitsForItsPad() {
    let pin: Set<PinnedSlot> = [PinnedSlot(system: .gamecube, playerZeroBased: 0)]
    XCTAssertEqual(AssignmentEngine().decide(from: state(gc: [pad, "", "", ""], connected: [touchscreen]), pinned: pin), .none)
    XCTAssertEqual(
      AssignmentEngine().decide(from: state(gc: [pad, "", "", ""], connected: [touchscreen, pad]), pinned: pin), .none)
  }

  func test_aPinnedWiimote1_isSkippedEvenWhenTheTouchscreenDoesNotHoldIt() {
    let s = state(gc: ["", "", "", ""], wii: ["iOS/4/Touchscreen", "", "", ""], connected: [touchscreen, pad], isWii: true)
    let decision = AssignmentEngine().decide(from: s, pinned: [PinnedSlot(system: .wii, playerZeroBased: 0)])
    XCTAssertEqual(decision.assignments, [ControllerAssignment(qualifier: pad, playerZeroBased: 1, system: .wii)])
  }
}
