// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The games Network Play offers: every game in the library. Nothing here decides whether a game "supports"
/// network play; a game carries at most a hint, and a hint never hides it.
enum NetworkPlayLibrary {
  enum Filter: String, CaseIterable { case all, recent, favorites }

  /// What is known about a game in network play. A label only: it never hides a game or blocks hosting.
  enum Hint: String, Equatable {
    case unknown
    case works
    case reportedBroken
  }

  struct Game: Equatable, Identifiable {
    let id: String // Library path, for ordering only; never a room-join identity.
    let title: String
    let system: String
    let favorite: Bool
    let lastPlayed: Date?
    var hint: Hint = .unknown
  }

  /// The one place hints come from. Nothing feeds it yet, so every game is `.unknown`; a community
  /// database of "works" and "reported broken" reports would answer here, by disc or title ID.
  static func hint(forGameID gameID: String) -> Hint {
    .unknown
  }

  /// Search first, then the filter's own order, then the limit.
  static func games(_ games: [Game], filter: Filter, search: String, limit: Int? = nil) -> [Game] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = games.filter { game in
      if filter == .favorites, !game.favorite { return false }
      if filter == .recent, game.lastPlayed == nil { return false }
      return query.isEmpty || game.title.localizedStandardContains(query) || game.system.localizedStandardContains(query)
    }.sorted { lhs, rhs in
      if filter == .recent {
        let leftDate = lhs.lastPlayed ?? .distantPast, rightDate = rhs.lastPlayed ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
      }
      let title = lhs.title.compare(rhs.title, options: [.caseInsensitive, .numeric], locale: Locale(identifier: "en_US_POSIX"))
      if title != .orderedSame { return title == .orderedAscending }
      if lhs.system != rhs.system { return lhs.system < rhs.system }
      return lhs.id < rhs.id
    }
    return limit.map { Array(filtered.prefix(max(0, $0))) } ?? filtered
  }
}

extension Notification.Name {
  static let iCubeShowNetworkPlay = Notification.Name("iCubeShowNetworkPlay")
}
