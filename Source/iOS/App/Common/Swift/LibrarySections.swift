// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A library game reduced to the fields the home shelves need.
struct LibraryGameRef: Equatable, Identifiable {
  /// Game ID, such as `GSRE01`.
  var id: String
  var platform: LibraryPlatformCategory
}

/// One horizontal shelf on the tvOS library home.
struct LibraryShelfSpec: Equatable, Identifiable {
  var id: String
  /// `L()` key for the shelf title.
  var titleKey: String
  var gameIDs: [String]
}

/// Builds the tvOS library home shelves from plain values so tests do not need the UI.
enum LibrarySectionBuilder {
  /// Cap for Recently Played.
  static let recentLimit = 12

  /// Recently Played, Favorites, All Games, then one shelf per platform when more than one platform is present.
  /// Empty shelves are omitted. Recently Played is newest first.
  static func homeShelves(
    games: [LibraryGameRef],
    favoriteIDs: Set<String>,
    lastPlayed: [String: Date],
    recentLimit: Int = recentLimit
  ) -> [LibraryShelfSpec] {
    let order = games.map(\.id).filter { !$0.isEmpty }
    let known = Set(order)
    var shelves: [LibraryShelfSpec] = []

    let recent = lastPlayed
      .filter { known.contains($0.key) }
      .sorted { lhs, rhs in
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        return lhs.key < rhs.key
      }
      .prefix(max(0, recentLimit))
      .map(\.key)
    if !recent.isEmpty {
      shelves.append(LibraryShelfSpec(id: "recent", titleKey: "Recently Played", gameIDs: Array(recent)))
    }

    let favorites = order.filter { favoriteIDs.contains($0) }
    if !favorites.isEmpty {
      shelves.append(LibraryShelfSpec(id: "favorites", titleKey: "Favorites", gameIDs: favorites))
    }

    if !order.isEmpty {
      shelves.append(LibraryShelfSpec(id: "all", titleKey: "All Games", gameIDs: order))
    }

    let present = LibraryPlatformCategory.filterCases.filter { platform in
      games.contains { $0.platform == platform }
    }
    if present.count > 1 {
      for platform in present {
        let ids = games.filter { $0.platform == platform && !$0.id.isEmpty }.map(\.id)
        if !ids.isEmpty {
          shelves.append(LibraryShelfSpec(id: platform.rawValue, titleKey: titleKey(for: platform), gameIDs: ids))
        }
      }
    }
    return shelves
  }

  private static func titleKey(for platform: LibraryPlatformCategory) -> String {
    switch platform {
    case .all: return "All"
    case .gameCube: return "GameCube"
    case .wii: return "Wii"
    case .wiiWare: return "WiiWare"
    }
  }
}
