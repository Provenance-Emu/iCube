// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Multiplayer documentation, app integration and played-session evidence are independent facts.
/// This adapter never treats Dolphin's compiled protocol as an installed iCube session integration.
enum NetworkPlayLibrary {
  enum Filter: String, CaseIterable { case suggested, supported, recent, favorites, unverified }
  enum Mode: String, Hashable { case sharedConsole, alternating, linked, nativeNetwork }
  struct Documentation: Equatable {
    let modes: Set<Mode>
    let source: String
    let singlePlayerOnly: Bool
  }
  struct Game: Equatable, Identifiable {
    let id: String // Library path for ordering only, never a ROM digest or a room-join identity.
    let title: String
    let system: String
    let local: Bool
    let favorite: Bool
    let lastPlayed: Date?
    let documentation: Documentation?
  }
  struct Backend {
    let available: Bool
    let modes: Set<Mode>
    let joinableGameIDs: Set<String>

    /// Source audit: there is no app session, discovery or NetPlay launch adapter in iCube yet.
    static let installed = Backend(available: false, modes: [], joinableGameIDs: [])
  }
  enum Eligibility: Equatable { case eligible, unverified, excluded }

  static func eligibility(_ game: Game, backend: Backend) -> Eligibility {
    guard game.local else { return .excluded }
    guard let facts = game.documentation, !facts.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return .unverified
    }
    if facts.singlePlayerOnly { return .excluded }
    guard !facts.modes.isEmpty else { return .unverified }
    guard backend.available, !facts.modes.isDisjoint(with: backend.modes) else { return .excluded }
    return .eligible
  }

  /// Eligibility/search precede sorting and pagination. Unknowns never enter ordinary recommendations.
  static func games(_ games: [Game], filter: Filter, showUnverified: Bool, search: String,
                    backend: Backend = .installed, limit: Int? = nil) -> [Game] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = games.filter { game in
      let status = eligibility(game, backend: backend)
      if filter == .unverified {
        guard showUnverified, status == .unverified else { return false }
      } else {
        guard status == .eligible else { return false }
      }
      if filter == .favorites, !game.favorite { return false }
      if filter == .recent, game.lastPlayed == nil { return false }
      return query.isEmpty || game.title.localizedStandardContains(query) || game.system.localizedStandardContains(query)
    }.sorted { lhs, rhs in
      if filter == .suggested {
        let leftRoom = backend.joinableGameIDs.contains(lhs.id), rightRoom = backend.joinableGameIDs.contains(rhs.id)
        if leftRoom != rightRoom { return leftRoom }
        if lhs.favorite != rhs.favorite { return lhs.favorite }
      }
      if filter == .suggested || filter == .recent {
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
