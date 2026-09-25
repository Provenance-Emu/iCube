// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import PVLibrarySnapshot
import XCTest
@testable import iCube

private func fixtureGame(
  _ id: String,
  title: String,
  favorite: Bool = false,
  lastPlayed: Date? = nil,
  region: String? = nil,
  gametdbID: String? = nil
) -> LibrarySnapshotGame {
  LibrarySnapshotGame(
    id: id, title: title, filePath: "/tmp/\(id).iso", platform: .gamecube,
    gametdbID: gametdbID, region: region, lastPlayed: lastPlayed, isFavorite: favorite, coverFilename: nil
  )
}

/// A seeded, deterministic `RandomNumberGenerator` for reproducible test picks — never used in
/// production code (which passes `SystemRandomNumberGenerator()`).
private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}

final class AppIntentsTests: XCTestCase {
  // MARK: - iCubeGameEntityQuery

  func testSuggestedGamesPrefersRecentsThenFavoritesNoDuplicates() {
    let recent = fixtureGame("GALE01", title: "Melee", lastPlayed: Date())
    let favoriteOnly = fixtureGame("GAFE01", title: "F-Zero", favorite: true)
    let both = fixtureGame("RSBE01", title: "Brawl", favorite: true, lastPlayed: Date().addingTimeInterval(-10))
    let snapshot = LibrarySnapshot(
      updatedAt: Date(),
      recentlyPlayed: [recent, both],
      favorites: [both, favoriteOnly],
      byGameID: [recent.id: recent, favoriteOnly.id: favoriteOnly, both.id: both]
    )
    let suggested = iCubeGameEntityQuery.suggestedGames(from: snapshot)
    XCTAssertEqual(suggested.map(\.id), ["GALE01", "RSBE01", "GAFE01"])
  }

  func testSuggestedGamesEmptyLibraryIsEmpty() {
    XCTAssertTrue(iCubeGameEntityQuery.suggestedGames(from: .empty).isEmpty)
  }

  func testMatchingGamesFiltersCaseInsensitivelyAndSortsByTitle() {
    let melee = fixtureGame("GALE01", title: "Super Smash Bros. Melee")
    let sunshine = fixtureGame("GALP01", title: "Super Mario Sunshine")
    let mkart = fixtureGame("GM4E01", title: "Mario Kart: Double Dash!!")
    let snapshot = LibrarySnapshot(
      updatedAt: Date(), recentlyPlayed: [], favorites: [],
      byGameID: [melee.id: melee, sunshine.id: sunshine, mkart.id: mkart]
    )
    let matches = iCubeGameEntityQuery.matchingGames("super", in: snapshot)
    XCTAssertEqual(matches.map(\.title), ["Super Mario Sunshine", "Super Smash Bros. Melee"])
    XCTAssertTrue(iCubeGameEntityQuery.matchingGames("zzz-no-match", in: snapshot).isEmpty)
  }

  func testGamesForIdentifiersDropsUnknownIds() {
    let melee = fixtureGame("GALE01", title: "Melee")
    let snapshot = LibrarySnapshot(updatedAt: Date(), recentlyPlayed: [], favorites: [], byGameID: [melee.id: melee])
    let games = iCubeGameEntityQuery.games(for: ["GALE01", "NOPE00"], in: snapshot)
    XCTAssertEqual(games.map(\.id), ["GALE01"])
  }

  func testEntityMapsSnapshotGameFields() {
    let melee = fixtureGame("GALE01", title: "Melee")
    let entity = iCubeGameEntity(snapshotGame: melee)
    XCTAssertEqual(entity.id, "GALE01")
    XCTAssertEqual(entity.title, "Melee")
    XCTAssertEqual(entity.platformName, "GameCube")
  }

  // MARK: - RandomGameSelector

  func testRandomGameSelectorPicksFromLibraryDeterministicallyForASeed() {
    let a = fixtureGame("AAAA01", title: "A")
    let b = fixtureGame("BBBB01", title: "B")
    let c = fixtureGame("CCCC01", title: "C")
    let snapshot = LibrarySnapshot(
      updatedAt: Date(), recentlyPlayed: [], favorites: [],
      byGameID: [a.id: a, b.id: b, c.id: c]
    )
    var gen1 = SeededGenerator(seed: 42)
    let picked1 = RandomGameSelector.pick(from: snapshot, using: &gen1)
    XCTAssertNotNil(picked1)
    XCTAssertTrue(["AAAA01", "BBBB01", "CCCC01"].contains(picked1!.id))

    var gen2 = SeededGenerator(seed: 42)
    let picked2 = RandomGameSelector.pick(from: snapshot, using: &gen2)
    XCTAssertEqual(picked1?.id, picked2?.id, "same seed picks the same game")
  }

  func testRandomGameSelectorEmptyLibraryReturnsNil() {
    var gen = SeededGenerator(seed: 1)
    XCTAssertNil(RandomGameSelector.pick(from: .empty, using: &gen))
  }
}
