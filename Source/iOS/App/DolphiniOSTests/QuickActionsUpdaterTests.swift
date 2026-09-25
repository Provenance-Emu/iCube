// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import PVLibrarySnapshot
import XCTest
@testable import iCube

final class QuickActionsUpdaterTests: XCTestCase {
  private func fixtureGame(_ id: String, title: String, lastPlayed: Date) -> LibrarySnapshotGame {
    LibrarySnapshotGame(
      id: id, title: title, filePath: "/tmp/\(id).iso", platform: .wii,
      gametdbID: nil, region: nil, lastPlayed: lastPlayed, isFavorite: false, coverFilename: nil
    )
  }

  func testShortcutItemsUsesUpToThreeMostRecentGamesInOrder() {
    let now = Date()
    let recents = (0..<5).map { i in
      fixtureGame("G\(i)AE01", title: "Game \(i)", lastPlayed: now.addingTimeInterval(TimeInterval(-i)))
    }
    let snapshot = LibrarySnapshot(
      updatedAt: now, recentlyPlayed: recents, favorites: [],
      byGameID: Dictionary(uniqueKeysWithValues: recents.map { ($0.id, $0) })
    )
    let items = QuickActionsUpdater.shortcutItems(from: snapshot)
    XCTAssertEqual(items.count, QuickActionsUpdater.maxItems)
    XCTAssertTrue(items.allSatisfy { $0.type == QuickActionsUpdater.shortcutType })
    XCTAssertEqual(items.map { $0.userInfo?["id"] as? String }, ["G0AE01", "G1AE01", "G2AE01"])
    XCTAssertEqual(items.map(\.localizedTitle), ["Game 0", "Game 1", "Game 2"])
  }

  func testShortcutItemsEmptyWhenNoRecents() {
    XCTAssertTrue(QuickActionsUpdater.shortcutItems(from: .empty).isEmpty)
  }
}
