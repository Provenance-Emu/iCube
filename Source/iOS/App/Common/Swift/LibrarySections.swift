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

  /// Recently Played, then Favorites. Empty shelves are omitted. Recently Played is newest first.
  /// The whole library follows them as a grid, and the rail switches platforms, so neither is a shelf.
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
    return shelves
  }
}

/// One stop on the tvOS grid's fast-scroll index: a letter and the first game filed under it.
struct LibraryIndexBucket: Equatable, Identifiable {
  var id: String { label }
  /// `A` to `Z`, or `#` for a title that starts with anything else.
  var label: String
  /// Position of the bucket's first game in the displayed order.
  var firstIndex: Int
}

/// The letter index beside a title-sorted tvOS grid.
enum LibraryScrollIndex {
  /// The bucket for titles that do not start with a Latin letter.
  static let otherLabel = "#"

  private static let latin: ClosedRange<Unicode.Scalar> = "a"..."z"

  /// The bucket `title` files under. Case and accents are folded, so "Énigma" files under E.
  static func label(for title: String) -> String {
    let folded = title
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    guard let first = folded.unicodeScalars.first, latin.contains(first) else { return otherLabel }
    return String(first).uppercased()
  }

  /// Buckets in displayed order. Walks `titles` once and records where each label first appears, so the
  /// index follows the grid in either sort direction. A label met again later (the sort and the folding
  /// disagree, as with "#" titles among letters) keeps its first position.
  static func buckets(titles: [String]) -> [LibraryIndexBucket] {
    var seen = Set<String>()
    var result: [LibraryIndexBucket] = []
    for (index, title) in titles.enumerated() {
      let bucket = label(for: title)
      if seen.insert(bucket).inserted {
        result.append(LibraryIndexBucket(label: bucket, firstIndex: index))
      }
    }
    return result
  }
}
