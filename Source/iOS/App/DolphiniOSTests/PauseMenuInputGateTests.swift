// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// Covers `PauseMenuInputGate`, the pure decision logic behind
/// `PauseMenuView.setupPauseControllerNav`'s raw `GCController` handler: it
/// decides whether a `buttonA` reading is a fresh activate edge, given
/// whether a child sheet (Save States, Shaders, Continuity, Controllers,
/// Settings) currently owns the controller via `ControllerFocusCoordinator`.
final class PauseMenuInputGateTests: XCTestCase {

  // MARK: Baseline (unclaimed) behavior

  func test_unclaimed_pressEdge_activatesOnce() {
    var gate = PauseMenuInputGate()
    XCTAssertTrue(gate.consumeButtonA(claimed: false, isPressed: true), "the down edge should activate")
    XCTAssertFalse(gate.consumeButtonA(claimed: false, isPressed: true), "holding the button must not re-activate")
    XCTAssertFalse(gate.consumeButtonA(claimed: false, isPressed: false), "release should not activate")
  }

  func test_unclaimed_pressReleasePress_activatesTwice() {
    var gate = PauseMenuInputGate()
    XCTAssertTrue(gate.consumeButtonA(claimed: false, isPressed: true))
    XCTAssertFalse(gate.consumeButtonA(claimed: false, isPressed: false))
    XCTAssertTrue(gate.consumeButtonA(claimed: false, isPressed: true), "a fresh press after release should re-arm")
  }

  func test_unclaimed_noPress_neverActivates() {
    var gate = PauseMenuInputGate()
    XCTAssertFalse(gate.consumeButtonA(claimed: false, isPressed: false))
    XCTAssertFalse(gate.consumeButtonA(claimed: false, isPressed: false))
  }

  // MARK: Claimed (child sheet up) behavior

  func test_claimed_neverActivates_regardlessOfPhysicalState() {
    var gate = PauseMenuInputGate()
    XCTAssertFalse(gate.consumeButtonA(claimed: true, isPressed: true))
    XCTAssertFalse(gate.consumeButtonA(claimed: true, isPressed: true))
    XCTAssertFalse(gate.consumeButtonA(claimed: true, isPressed: false))
  }

  // MARK: Reclaim race -- the actual leak this gate exists to close

  /// The scenario from the bug report: pressing A on a pause-menu row opens a
  /// child sheet (claiming the controller) while the physical button is still
  /// down. The child sheet then releases its claim (e.g. dismissed by a
  /// non-controller action) while A is STILL down. That held press must not
  /// replay as a fresh activate the instant this menu regains the controller.
  func test_reclaimWhileButtonStillDown_doesNotReplayAsActivate() {
    var gate = PauseMenuInputGate()
    // The press that opened the child sheet.
    XCTAssertTrue(gate.consumeButtonA(claimed: false, isPressed: true))
    // Child sheet claims the controller; A is still physically down.
    XCTAssertFalse(gate.consumeButtonA(claimed: true, isPressed: true))
    // Child sheet releases the claim; A is STILL down (not yet released).
    XCTAssertFalse(gate.consumeButtonA(claimed: false, isPressed: true), "held press must be swallowed on reclaim")
    XCTAssertFalse(gate.consumeButtonA(claimed: false, isPressed: true), "still swallowed while held")
    // Only once the user actually releases the button does it re-arm.
    XCTAssertFalse(gate.consumeButtonA(claimed: false, isPressed: false))
    XCTAssertTrue(gate.consumeButtonA(claimed: false, isPressed: true), "a genuine new press after release activates")
  }

  /// If A is released while the child sheet still owns the controller, no
  /// stale state should leak into the next activation once reclaimed.
  func test_releasedWhileClaimed_thenReclaimed_freshPressActivates() {
    var gate = PauseMenuInputGate()
    XCTAssertTrue(gate.consumeButtonA(claimed: false, isPressed: true))
    XCTAssertFalse(gate.consumeButtonA(claimed: true, isPressed: true))
    XCTAssertFalse(gate.consumeButtonA(claimed: true, isPressed: false))
    XCTAssertFalse(gate.consumeButtonA(claimed: false, isPressed: false))
    XCTAssertTrue(gate.consumeButtonA(claimed: false, isPressed: true))
  }

  /// A completely unrelated press-release cycle that happens entirely while
  /// claimed must never surface once control returns.
  func test_pressAndReleaseEntirelyWhileClaimed_noActivateOnReclaim() {
    var gate = PauseMenuInputGate()
    XCTAssertFalse(gate.consumeButtonA(claimed: true, isPressed: false))
    XCTAssertFalse(gate.consumeButtonA(claimed: true, isPressed: true))
    XCTAssertFalse(gate.consumeButtonA(claimed: true, isPressed: false))
    XCTAssertFalse(gate.consumeButtonA(claimed: false, isPressed: false), "nothing to replay; button is up")
  }

  // MARK: resync

  /// `setupPauseControllerNav` calls this with the live reading before
  /// (re)installing the handler, guarding against a reassigned
  /// `valueChangedHandler` treating an already-held button as a fresh edge.
  func test_resync_adoptsHeldState_withoutEmittingAnEdge() {
    var gate = PauseMenuInputGate()
    gate.resync(isPressed: true)
    XCTAssertFalse(gate.consumeButtonA(claimed: false, isPressed: true), "still held -- not a new edge")
    XCTAssertFalse(gate.consumeButtonA(claimed: false, isPressed: false))
    XCTAssertTrue(gate.consumeButtonA(claimed: false, isPressed: true), "genuine press after release activates")
  }

  func test_resync_adoptsReleasedState_soNextPressActivates() {
    var gate = PauseMenuInputGate()
    gate.resync(isPressed: false)
    XCTAssertTrue(gate.consumeButtonA(claimed: false, isPressed: true))
  }

  // MARK: Per-controller independence

  /// `PauseMenuView` keeps one gate per controller (`[ObjectIdentifier:
  /// PauseMenuInputGate]`) precisely so this can't happen: one pad's callback
  /// must never clear or set another pad's latch.
  func test_independentGates_oneControllerHoldingDoesNotAffectAnother() {
    var gate1 = PauseMenuInputGate()
    var gate2 = PauseMenuInputGate()
    XCTAssertTrue(gate1.consumeButtonA(claimed: false, isPressed: true), "controller 1 presses and holds A")
    XCTAssertTrue(gate2.consumeButtonA(claimed: false, isPressed: true), "controller 2's independent press also activates")
    XCTAssertFalse(gate2.consumeButtonA(claimed: false, isPressed: false), "controller 2 releases")
    // Controller 1 is still held; its own gate is unaffected by controller 2's release.
    XCTAssertFalse(gate1.consumeButtonA(claimed: false, isPressed: true), "controller 1's hold must not re-fire")
  }
}
