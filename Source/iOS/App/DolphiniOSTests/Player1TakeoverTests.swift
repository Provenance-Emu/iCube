// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// "Controllers Take Player 1" (`AssignmentEngine.player1Takeover`): a pad that connects while the
/// on-screen controls are Player 1 takes Player 1, pinned or not.
final class Player1TakeoverTests: XCTestCase {
  private let touchscreen = "iOS/0/Touchscreen"
  private let wiiTouchscreen = "iOS/4/Touchscreen"
  private let pad = "MFi/0/Gamepad A"

  private func state(
    gc: [String], wii: [String] = ["", "", "", ""], isWii: Bool = false, player1Active: Bool = true
  ) -> ControllerStateStore.State {
    func slots(_ q: [String]) -> [ControllerStateStore.PortAssignment] {
      q.enumerated().map {
        ControllerStateStore.PortAssignment(
          portOneBased: $0.offset + 1, defaultDeviceQualifier: $0.element, isActive: $0.offset > 0 || player1Active)
      }
    }
    return ControllerStateStore.State(
      controllers: [], portAssignments: slots(gc), wiimoteAssignments: slots(wii), connectedQualifiers: [touchscreen, pad],
      isWiiSystem: isWii, touchscreenHoldsWiimote1: isWii)
  }

  func test_gameCube_padTakesAPinnedTouchscreenPlayer1() {
    let s = state(gc: [touchscreen, "", "", ""])
    XCTAssertEqual(
      AssignmentEngine.player1Takeover(of: pad, in: s, pinned: [PinnedSlot(system: .gamecube, playerZeroBased: 0)]),
      Player1Takeover(system: .gamecube, vacatedPlayerZeroBased: nil))
  }

  /// The pad was put on Player 2 when the user picked the Touchscreen for Player 1: it moves, and
  /// its old slot is cleared so one press does not reach two players.
  func test_gameCube_padOnPlayer2_movesAndVacatesIt() {
    let s = state(gc: [touchscreen, pad, "", ""])
    XCTAssertEqual(
      AssignmentEngine.player1Takeover(of: pad, in: s, pinned: [PinnedSlot(system: .gamecube, playerZeroBased: 0)]),
      Player1Takeover(system: .gamecube, vacatedPlayerZeroBased: 1))
  }

  func test_aPadThePlayerPinnedToAnotherSlot_staysThere() {
    let s = state(gc: [touchscreen, pad, "", ""])
    XCTAssertNil(AssignmentEngine.player1Takeover(of: pad, in: s, pinned: [PinnedSlot(system: .gamecube, playerZeroBased: 1)]))
  }

  func test_player1OnAnotherPad_orOff_orTheTouchscreen_isLeftAlone() {
    XCTAssertNil(AssignmentEngine.player1Takeover(of: pad, in: state(gc: ["MFi/1/Gamepad B", "", "", ""]), pinned: []))
    XCTAssertNil(AssignmentEngine.player1Takeover(of: pad, in: state(gc: [touchscreen, "", "", ""], player1Active: false), pinned: []))
    XCTAssertNil(AssignmentEngine.player1Takeover(of: touchscreen, in: state(gc: [touchscreen, "", "", ""]), pinned: []))
  }

  /// In a Wii title with the controls shown, `decide` starts at Wii Remote 2; the takeover gives the
  /// pad Wii Remote 1 and leaves the GameCube ports alone.
  func test_wii_padTakesWiimote1FromTheOnScreenControls() {
    let s = state(gc: [touchscreen, "", "", ""], wii: [wiiTouchscreen, "", "", ""], isWii: true)
    XCTAssertEqual(
      AssignmentEngine.player1Takeover(of: pad, in: s, pinned: []), Player1Takeover(system: .wii, vacatedPlayerZeroBased: nil))
  }
}
