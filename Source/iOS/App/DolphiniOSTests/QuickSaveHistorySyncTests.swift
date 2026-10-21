// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
import PVSyncRules

final class QuickSaveHistorySyncTests: XCTestCase {
  func testHistoryStateAndBothSidecarsUseExistingSyncCategories() {
    for gameID in ["GALE01", "ID-Slot-3", "ID-Homebrew 日本語.quick-demo", "HBW"] {
      let path = "StateSaves/\(gameID).quick-\(UUID().uuidString).s01"
      XCTAssertEqual(SyncClassifier.classify(relativePath: path), .saveState)
      XCTAssertEqual(SyncClassifier.classify(relativePath: path + ".json"), .saveStateMetadata)
      XCTAssertEqual(SyncClassifier.classify(relativePath: path + ".png"), .saveStateThumbnail)
    }
  }
}
