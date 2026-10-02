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
    XCTAssertEqual(QuickSlot.loadOutcome(slot: 4, hasState: true, coreRunning: true), .loaded(slot: 4))
  }

  func testOnlySavedAndLoadedAreSuccesses() {
    XCTAssertTrue(QuickSlot.Outcome.loaded(slot: 1).isSuccess)
    XCTAssertFalse(QuickSlot.Outcome.emptySlot(slot: 1).isSuccess)
    XCTAssertFalse(QuickSlot.Outcome.loadUnavailable.isSuccess)
  }

  func testMessagesNameTheSlot() {
    XCTAssertEqual(QuickSlot.Outcome.saved(slot: 7).message, "Saved to Slot 7")
    XCTAssertEqual(QuickSlot.Outcome.loaded(slot: 7).message, "Loaded Slot 7")
    XCTAssertEqual(QuickSlot.Outcome.emptySlot(slot: 7).message, "No save in Slot 7")
    XCTAssertEqual(QuickSlot.Outcome.saveFailed(slot: 7).message, "Couldn't save to Slot 7")
  }
}
