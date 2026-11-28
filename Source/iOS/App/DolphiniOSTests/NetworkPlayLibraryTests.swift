// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class NetworkPlayLibraryTests: XCTestCase {
  private func game(_ id: String, title: String = "Game", system: String = "GameCube", favorite: Bool = false,
                    played: Double? = nil, hint: NetworkPlayLibrary.Hint = .unknown) -> NetworkPlayLibrary.Game {
    .init(id: id, title: title, system: system, favorite: favorite,
          lastPlayed: played.map { Date(timeIntervalSince1970: $0) }, hint: hint)
  }

  func testEveryGameIsOfferedWhateverItsHint() {
    let values = [game("unknown"), game("works", hint: .works), game("broken", hint: .reportedBroken)]
    XCTAssertEqual(Set(NetworkPlayLibrary.games(values, filter: .all, search: "").map(\.id)),
                   ["unknown", "works", "broken"])
  }

  func testAReportedBrokenGameStaysInRecentAndFavorites() {
    let broken = game("broken", favorite: true, played: 10, hint: .reportedBroken)
    for filter in NetworkPlayLibrary.Filter.allCases {
      XCTAssertEqual(NetworkPlayLibrary.games([broken], filter: filter, search: "").map(\.id), ["broken"])
    }
  }

  func testNoHintIsKnownUntilASourceFeedsTheSeam() {
    XCTAssertEqual(NetworkPlayLibrary.hint(forGameID: "GALE01"), .unknown)
    XCTAssertEqual(game("default").hint, .unknown)
  }

  func testHintsDoNotChangeTheOrder() {
    let values = [game("c", title: "Charlie", hint: .works), game("a", title: "Alpha", hint: .reportedBroken),
                  game("b", title: "Bravo")]
    XCTAssertEqual(NetworkPlayLibrary.games(values, filter: .all, search: "").map(\.id), ["a", "b", "c"])
  }

  func testRecentRequiresHistoryAndFavoritesRequiresFavorite() {
    let values = [game("never"), game("older", favorite: true, played: 1), game("newer", played: 2)]
    XCTAssertEqual(NetworkPlayLibrary.games(values, filter: .recent, search: "").map(\.id), ["newer", "older"])
    XCTAssertEqual(NetworkPlayLibrary.games(values, filter: .favorites, search: "").map(\.id), ["older"])
  }

  func testSearchMatchesTitleOrSystemBeforeTheLimit() {
    let values = [game("z"), game("b"), game("wii", title: "A", system: "Wii"), game("a")]
    for order in [values, values.reversed().map { $0 }] {
      XCTAssertEqual(NetworkPlayLibrary.games(order, filter: .all, search: " gamecube ", limit: 2).map(\.id),
                     ["a", "b"])
    }
    XCTAssertEqual(NetworkPlayLibrary.games(values, filter: .all, search: "wii").map(\.id), ["wii"])
    XCTAssertTrue(NetworkPlayLibrary.games(values, filter: .all, search: "no match").isEmpty)
  }
}
