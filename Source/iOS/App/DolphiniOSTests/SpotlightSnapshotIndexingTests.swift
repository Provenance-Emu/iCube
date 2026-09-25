// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import PVLibrarySnapshot
import XCTest
@testable import iCube

final class SpotlightSnapshotIndexingTests: XCTestCase {
  func testSearchableItemsUseTheGameIdIdentifierAndRichDescription() {
    let game = LibrarySnapshotGame(
      id: "GALE01", title: "Melee", filePath: "/tmp/GALE01.iso", platform: .gamecube,
      gametdbID: "GALE01", region: "USA", lastPlayed: nil, isFavorite: false, coverFilename: nil
    )
    let snapshot = LibrarySnapshot(updatedAt: Date(), recentlyPlayed: [], favorites: [], byGameID: [game.id: game])
    let items = SpotlightSnapshotIndexer.searchableItems(from: snapshot)
    XCTAssertEqual(items.count, 1)
    let item = items[0]
    XCTAssertEqual(item.uniqueIdentifier, "dios.game.GALE01")
    XCTAssertEqual(item.domainIdentifier, "dios.games")
    XCTAssertEqual(item.attributeSet.title, "Melee")
    XCTAssertEqual(item.attributeSet.contentDescription, "GameCube • USA • GALE01")
  }

  func testSearchableItemsOmitBlankRegionAndGametdbID() {
    let game = LibrarySnapshotGame(
      id: "GAFE01", title: "F-Zero GX", filePath: "/tmp/GAFE01.iso", platform: .gamecube,
      gametdbID: nil, region: nil, lastPlayed: nil, isFavorite: false, coverFilename: nil
    )
    let snapshot = LibrarySnapshot(updatedAt: Date(), recentlyPlayed: [], favorites: [], byGameID: [game.id: game])
    let items = SpotlightSnapshotIndexer.searchableItems(from: snapshot)
    XCTAssertEqual(items.first?.attributeSet.contentDescription, "GameCube")
  }
}
