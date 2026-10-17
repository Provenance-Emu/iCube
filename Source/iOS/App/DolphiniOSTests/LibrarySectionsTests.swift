// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class LibrarySectionsTests: XCTestCase {
  private func games(_ pairs: [(String, LibraryPlatformCategory)]) -> [LibraryGameRef] {
    pairs.map { LibraryGameRef(id: $0.0, platform: $0.1) }
  }

  func testNoRecentOrFavoritesMeansNoShelves() {
    let shelves = LibrarySectionBuilder.homeShelves(
      games: games([("G1", .gameCube), ("W1", .wii)]),
      favoriteIDs: [],
      lastPlayed: [:]
    )
    XCTAssertEqual(shelves.map(\.id), [])
  }

  func testRecentIsNewestFirstAndCapped() {
    let played: [String: Date] = [
      "A": Date(timeIntervalSince1970: 10),
      "B": Date(timeIntervalSince1970: 30),
      "C": Date(timeIntervalSince1970: 20),
      "D": Date(timeIntervalSince1970: 40),
      "missing": Date(timeIntervalSince1970: 50)
    ]
    let shelves = LibrarySectionBuilder.homeShelves(
      games: games([("A", .wii), ("B", .wii), ("C", .wii), ("D", .wii)]),
      favoriteIDs: ["A"],
      lastPlayed: played,
      recentLimit: 2
    )
    XCTAssertEqual(shelves.map(\.id), ["recent", "favorites"])
    XCTAssertEqual(shelves[0].gameIDs, ["D", "B"])
    XCTAssertEqual(shelves[1].gameIDs, ["A"])
  }

  func testShelvesNeverListTheLibraryOrItsPlatforms() {
    let shelves = LibrarySectionBuilder.homeShelves(
      games: games([("G1", .gameCube), ("W1", .wii), ("C1", .wiiWare)]),
      favoriteIDs: ["W1"],
      lastPlayed: ["G1": Date(timeIntervalSince1970: 1)]
    )
    XCTAssertEqual(shelves.map(\.id), ["recent", "favorites"])
  }

  func testIndexLabelFoldsCaseAndAccents() {
    XCTAssertEqual(LibraryScrollIndex.label(for: "zelda"), "Z")
    XCTAssertEqual(LibraryScrollIndex.label(for: "Énigma"), "E")
    XCTAssertEqual(LibraryScrollIndex.label(for: "  Metroid"), "M")
  }

  func testIndexLabelFilesDigitsSymbolsAndOtherScriptsUnderHash() {
    XCTAssertEqual(LibraryScrollIndex.label(for: "1080° Avalanche"), "#")
    XCTAssertEqual(LibraryScrollIndex.label(for: "¡Pikmin!"), "#")
    XCTAssertEqual(LibraryScrollIndex.label(for: "ゼルダの伝説"), "#")
    XCTAssertEqual(LibraryScrollIndex.label(for: ""), "#")
  }

  func testBucketsMarkWhereEachLetterStarts() {
    let buckets = LibraryScrollIndex.buckets(titles: ["1080°", "Animal Crossing", "Amazing", "Bomberman", "Zelda"])
    XCTAssertEqual(buckets.map(\.label), ["#", "A", "B", "Z"])
    XCTAssertEqual(buckets.map(\.firstIndex), [0, 1, 3, 4])
  }

  func testBucketsFollowADescendingSort() {
    let buckets = LibraryScrollIndex.buckets(titles: ["Zelda", "Mario", "Metroid", "Animal Crossing"])
    XCTAssertEqual(buckets.map(\.label), ["Z", "M", "A"])
    XCTAssertEqual(buckets.map(\.firstIndex), [0, 1, 3])
  }

  func testALabelMetAgainKeepsItsFirstPosition() {
    let buckets = LibraryScrollIndex.buckets(titles: ["Alpha", "#hash", "Beta", "Another"])
    XCTAssertEqual(buckets.map(\.label), ["A", "#", "B"])
    XCTAssertEqual(buckets.map(\.firstIndex), [0, 1, 2])
  }

#if os(tvOS)
  func testHeaderSubtitleHomeHasNoCount() {
    XCTAssertEqual(TVLibraryView.libraryHeaderSubtitle(destination: .home, count: 12), L("My Library"))
  }

  func testHeaderSubtitleGridViewsCarryTheCount() {
    XCTAssertEqual(TVLibraryView.libraryHeaderSubtitle(destination: .all, count: 7), "\(L("All Games")) · 7")
    XCTAssertEqual(TVLibraryView.libraryHeaderSubtitle(destination: .platform(.gameCube), count: 3), "\(L("GameCube")) · 3")
    XCTAssertEqual(TVLibraryView.libraryHeaderSubtitle(destination: .platform(.wii), count: 0), "\(L("Wii")) · 0")
  }
#endif
}
