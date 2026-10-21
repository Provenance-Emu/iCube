// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

@MainActor
final class QuickSaveActionsTests: XCTestCase {
  func testModdedBootUsesExplicitClassicSlotRegardlessOfSavedMode() {
    XCTAssertEqual(QuickSaveActions.effectiveMode(.history, modded: true), .slots)
    XCTAssertEqual(QuickSaveActions.effectiveMode(.slots, modded: true), .slots)
    XCTAssertEqual(QuickSaveActions.effectiveMode(.history, modded: false), .history)
  }
  func testStaleCompletionHasNoSuccessOrToast() {
    XCTAssertFalse(QuickSaveActions.Outcome.cancelled.isSuccess)
    XCTAssertTrue(QuickSaveActions.Outcome.cancelled.message.isEmpty)
  }
  func testCleanupWarningStillRepresentsSuccessfulSave() {
    let url = URL(fileURLWithPath: "/StateSaves/GALE01.quick-\(UUID().uuidString).s01")
    XCTAssertTrue(QuickSaveActions.Outcome.savedWithCleanupWarning(url).isSuccess)
    XCTAssertFalse(QuickSaveActions.Outcome.saveFailed.isSuccess)
    XCTAssertTrue(QuickSaveActions.Outcome.savedWithCleanupWarning(url).message.contains("couldn't remove"))
  }
  func testHistoryPayloadWithSlotExtensionStillSaysQuickSave() {
    let history = URL(fileURLWithPath: "/StateSaves/GALE01.quick-\(UUID().uuidString).s01")
    let classic = URL(fileURLWithPath: "/StateSaves/GALE01.s01")
    XCTAssertEqual(QuickSaveActions.Outcome.saved(history).message, "Quick save created")
    XCTAssertEqual(QuickSaveActions.Outcome.saved(classic).message, "Saved to Slot 1")
  }
  func testIncompatibleAndEmptyOutcomesNeverReportLoadSuccess() {
    XCTAssertFalse(QuickSaveActions.Outcome.incompatible(URL(fileURLWithPath: "/state")).isSuccess)
    XCTAssertFalse(QuickSaveActions.Outcome.empty.isSuccess)
    XCTAssertTrue(QuickSaveActions.Outcome.loadRequested(URL(fileURLWithPath: "/state")).isSuccess)
    XCTAssertEqual(QuickSaveActions.Outcome.loadRequested(URL(fileURLWithPath: "/state")).message, "Loading save state")
  }
}
