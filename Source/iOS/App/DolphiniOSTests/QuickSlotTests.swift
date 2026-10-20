// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class QuickSlotTests: XCTestCase {
  func testSaveOutcomeFollowsWhetherTheSaveHappened() {
    XCTAssertEqual(QuickSlot.saveOutcome(slot: 3, saved: true), .saved(slot: 3))
    XCTAssertEqual(QuickSlot.saveOutcome(slot: 3, saved: false), .saveFailed(slot: 3))
    XCTAssertTrue(QuickSlot.saveOutcome(slot: 3, saved: true).isSuccess)
    XCTAssertFalse(QuickSlot.saveOutcome(slot: 3, saved: false).isSuccess)
  }

  func testLoadNeedsAStateOnDisk() {
    XCTAssertEqual(QuickSlot.loadOutcome(slot: 4, hasState: false, coreRunning: true), .emptySlot(slot: 4))
    XCTAssertEqual(QuickSlot.loadOutcome(slot: 4, hasState: false, coreRunning: false), .emptySlot(slot: 4))
  }

  func testLoadNeedsARunningCore() {
    XCTAssertEqual(QuickSlot.loadOutcome(slot: 4, hasState: true, coreRunning: false), .loadUnavailable)
    XCTAssertEqual(QuickSlot.loadOutcome(slot: 4, hasState: true, coreRunning: true), .loadRequested(slot: 4))
  }

  func testOnlySavedAndRequestedLoadsAreSuccessfulActions() {
    XCTAssertTrue(QuickSlot.Outcome.loadRequested(slot: 1).isSuccess)
    XCTAssertFalse(QuickSlot.Outcome.emptySlot(slot: 1).isSuccess)
    XCTAssertFalse(QuickSlot.Outcome.loadUnavailable.isSuccess)
  }

  func testMessagesNameTheSlot() {
    XCTAssertEqual(QuickSlot.Outcome.saved(slot: 7).message, "Saved to Slot 7")
    XCTAssertEqual(QuickSlot.Outcome.loadRequested(slot: 7).message, "Loading Slot 7")
    XCTAssertEqual(QuickSlot.Outcome.emptySlot(slot: 7).message, "No save in Slot 7")
    XCTAssertEqual(QuickSlot.Outcome.saveFailed(slot: 7).message, "Couldn't save to Slot 7")
  }
  func testSaveCompletionKeepsTheRequestedSlotAndGame() {
    let request = SaveStateUIRequest(slot: 7, gameID: "GALE01", sessionIdentifier: 10)
    XCTAssertEqual(request.slot, 7)
    XCTAssertTrue(request.accepts(completedGameID: "GALE01", completedSessionIdentifier: nil, currentGameID: "GALE01", currentSessionIdentifier: 10, activeID: request.id))
    XCTAssertTrue(request.accepts(completedGameID: nil, completedSessionIdentifier: nil, currentGameID: "GALE01", currentSessionIdentifier: 10, activeID: request.id),
                  "A matching active request must surface a failed save too")
  }

  func testSaveCompletionCannotUpdateADismissedOrNewerRequest() {
    let old = SaveStateUIRequest(slot: 1, gameID: "GALE01", sessionIdentifier: 10)
    let newer = SaveStateUIRequest(slot: 2, gameID: "GALE01", sessionIdentifier: 10)
    XCTAssertFalse(old.accepts(completedGameID: "GALE01", completedSessionIdentifier: nil, currentGameID: "GALE01", currentSessionIdentifier: 10, activeID: nil))
    XCTAssertFalse(old.accepts(completedGameID: "GALE01", completedSessionIdentifier: nil, currentGameID: "GALE01", currentSessionIdentifier: 10, activeID: newer.id))
  }

  func testSaveCompletionCannotAffectAnotherRunningGame() {
    let request = SaveStateUIRequest(slot: 1, gameID: "GALE01", sessionIdentifier: 10)
    XCTAssertFalse(request.accepts(completedGameID: "GALE01", completedSessionIdentifier: nil, currentGameID: "RSBE01", currentSessionIdentifier: 10, activeID: request.id))
    XCTAssertFalse(request.accepts(completedGameID: "RSBE01", completedSessionIdentifier: nil, currentGameID: "GALE01", currentSessionIdentifier: 10, activeID: request.id))
    XCTAssertFalse(SaveStateUIRequest(slot: 1, gameID: "", sessionIdentifier: 10).accepts(completedGameID: nil, completedSessionIdentifier: nil, currentGameID: "", currentSessionIdentifier: 10, activeID: request.id))
  }

  func testFirstTapSameTitleRestartBeforeScheduledWorkIsRejected() {
    let request = SaveStateUIRequest(slot: 3, gameID: "GALE01", sessionIdentifier: 10)
    XCTAssertFalse(request.accepts(completedGameID: nil, completedSessionIdentifier: nil,
                                  currentGameID: "GALE01", currentSessionIdentifier: 11, activeID: request.id))
    XCTAssertFalse(request.accepts(completedGameID: "GALE01", completedSessionIdentifier: 10,
                                  currentGameID: "GALE01", currentSessionIdentifier: 11, activeID: request.id))
    XCTAssertFalse(request.accepts(completedGameID: "GALE01", completedSessionIdentifier: 11,
                                  currentGameID: "GALE01", currentSessionIdentifier: 10, activeID: request.id))
  }

}
