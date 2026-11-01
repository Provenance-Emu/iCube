// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class NetworkPlayLibraryTests: XCTestCase {
  private let shared = NetworkPlayLibrary.Backend(available: true, modes: [.sharedConsole], joinableGameIDs: ["room"])

  private func game(_ id: String, title: String = "Game", favorite: Bool = false, played: Double? = nil,
                    local: Bool = true, modes: Set<NetworkPlayLibrary.Mode>? = [.sharedConsole],
                    single: Bool = false, source: String = "https://example.org/manual") -> NetworkPlayLibrary.Game {
    .init(id: id, title: title, system: "GameCube", local: local, favorite: favorite,
          lastPlayed: played.map { Date(timeIntervalSince1970: $0) },
          documentation: modes.map { .init(modes: $0, source: source, singlePlayerOnly: single) })
  }

  func testInstalledAppDoesNotClaimDolphinProtocolIsAnAvailableBackend() {
    XCTAssertFalse(NetworkPlayLibrary.Backend.installed.available)
    XCTAssertTrue(NetworkPlayLibrary.Backend.installed.modes.isEmpty)
    XCTAssertTrue(NetworkPlayLibrary.games([game("documented")], filter: .suggested,
                                           showUnverified: true, search: "").isEmpty)
  }

  func testUnknownGamesNeverLeakIntoRecommendationsEvenWhenOptedIn() {
    let unknown = game("unknown", favorite: true, played: 100, modes: nil)
    for filter in NetworkPlayLibrary.Filter.allCases where filter != .unverified {
      XCTAssertTrue(NetworkPlayLibrary.games([unknown], filter: filter, showUnverified: true,
                                             search: "", backend: shared).isEmpty)
    }
    XCTAssertTrue(NetworkPlayLibrary.games([unknown], filter: .unverified, showUnverified: false,
                                           search: "", backend: shared).isEmpty)
    XCTAssertEqual(NetworkPlayLibrary.games([unknown], filter: .unverified, showUnverified: true,
                                            search: "").map(\.id), ["unknown"])
  }

  func testMetadataSourceIsRequiredAndOnePlayerIsNotAssumedSinglePlayerOnly() {
    XCTAssertEqual(NetworkPlayLibrary.eligibility(game("missing", source: "  "), backend: shared), .unverified)
    XCTAssertEqual(NetworkPlayLibrary.eligibility(game("unknown", modes: []), backend: shared), .unverified)
    let linked = NetworkPlayLibrary.Backend(available: true, modes: [.linked], joinableGameIDs: [])
    XCTAssertEqual(NetworkPlayLibrary.eligibility(game("link", modes: [.linked]), backend: linked), .eligible)
  }

  func testNonLocalSinglePlayerAndUnsupportedModesAreExcluded() {
    let values = [game("remote", local: false), game("single", single: true), game("native", modes: [.nativeNetwork])]
    for value in values { XCTAssertEqual(NetworkPlayLibrary.eligibility(value, backend: shared), .excluded) }
    XCTAssertTrue(NetworkPlayLibrary.games(values, filter: .supported, showUnverified: true,
                                           search: "", backend: shared).isEmpty)
  }

  func testSuggestedRanksRoomThenFavoriteThenHistoryAndIncludesUnplayedGames() {
    let values = [game("new", title: "Alpha"), game("recent", played: 500),
                  game("fav", favorite: true), game("room", played: 1)]
    XCTAssertEqual(NetworkPlayLibrary.games(values, filter: .suggested, showUnverified: false,
                                            search: "", backend: shared).map(\.id), ["room", "fav", "recent", "new"])
  }

  func testStableIdentityTieBreakAndSearchBeforePagination() {
    let values = [game("z"), game("b"), game("excluded", title: "A", local: false),
                  game("unknown", title: "A", modes: nil), game("a")]
    for order in [values, values.reversed().map { $0 }] {
      XCTAssertEqual(NetworkPlayLibrary.games(order, filter: .supported, showUnverified: true,
                                              search: " gamecube ", backend: shared, limit: 2).map(\.id), ["a", "b"])
    }
    XCTAssertTrue(NetworkPlayLibrary.games(values, filter: .supported, showUnverified: true,
                                           search: "no match", backend: shared).isEmpty)
  }

  func testRecentRequiresHistoryAndFavoritesRequiresFavorite() {
    let values = [game("never"), game("older", favorite: true, played: 1), game("newer", played: 2)]
    XCTAssertEqual(NetworkPlayLibrary.games(values, filter: .recent, showUnverified: false,
                                            search: "", backend: shared).map(\.id), ["newer", "older"])
    XCTAssertEqual(NetworkPlayLibrary.games(values, filter: .favorites, showUnverified: false,
                                            search: "", backend: shared).map(\.id), ["older"])
  }
}
