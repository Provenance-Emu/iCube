// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class LibrarySectionsTests: XCTestCase {
  private func games(_ pairs: [(String, LibraryPlatformCategory)]) -> [LibraryGameRef] {
    pairs.map { LibraryGameRef(id: $0.0, platform: $0.1) }
  }

  func testHomeOrderSkipsEmptyRecentAndFavorites() {
    let shelves = LibrarySectionBuilder.homeShelves(
      games: games([("G1", .gameCube), ("W1", .wii)]),
      favoriteIDs: [],
      lastPlayed: [:]
    )
    XCTAssertEqual(shelves.map(\.id), ["all", "gameCube", "wii"])
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
    XCTAssertEqual(shelves.map(\.id), ["recent", "favorites", "all"])
    XCTAssertEqual(shelves[0].gameIDs, ["D", "B"])
    XCTAssertEqual(shelves[1].gameIDs, ["A"])
  }

  func testSinglePlatformOmitsPlatformShelves() {
    let shelves = LibrarySectionBuilder.homeShelves(
      games: games([("G1", .gameCube), ("G2", .gameCube)]),
      favoriteIDs: [],
      lastPlayed: [:]
    )
    XCTAssertEqual(shelves.map(\.id), ["all"])
  }
}
