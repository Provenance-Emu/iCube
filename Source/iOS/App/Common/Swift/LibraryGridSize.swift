// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics

/// How large the tvOS library draws its covers, after iFly's library density. The View menu offers the three
/// sizes; the number of columns follows from the size and the width of the column, so a choice always changes
/// the layout. Platform-neutral so the iOS test target covers it.
enum LibraryGridSize: String, CaseIterable, Identifiable {
  case compact
  case comfortable
  case large

  /// `UserDefaults` key of the stored choice.
  static let storageKey = "library_grid_size"

  var id: String { rawValue }

  /// English title; callers localize it.
  var titleKey: String {
    switch self {
    case .compact: "Compact"
    case .comfortable: "Comfortable"
    case .large: "Large"
    }
  }

  var systemImage: String {
    switch self {
    case .compact: "square.grid.3x3"
    case .comfortable: "square.grid.2x2"
    case .large: "square"
    }
  }

  /// Width of one cover on a TV, in points. `comfortable` is the size the library always had.
  var tvCardWidth: CGFloat {
    switch self {
    case .compact: 176
    case .comfortable: 260
    case .large: 340
    }
  }

  /// One cover on a TV, at the standard case shape (`LibraryLayout.cardSize`).
  var tvCardSize: CGSize {
    CGSize(width: tvCardWidth, height: tvCardWidth * Self.coverAspect)
  }

  /// Height over width of a game case.
  static let coverAspect: CGFloat = 1.5

  /// A laid-out tvOS grid: how many covers per row, how large, and the gap that spreads them across the row.
  struct Metrics: Equatable {
    let count: Int
    let cardSize: CGSize
    let spacing: CGFloat
  }

  /// The columns of this size that fit `availableWidth`, never fewer than one, and the gap that spreads them
  /// edge to edge. The gap never falls under `minSpacing`, the room a focused cover lifts into; `floorSpacing`
  /// is the least it may be when a single cover is wider than the row.
  func tvMetrics(availableWidth: CGFloat, minSpacing: CGFloat, floorSpacing: CGFloat) -> Metrics {
    let width = tvCardWidth
    let available = max(width, availableWidth)
    let count = max(1, Int((available + minSpacing) / (width + minSpacing)))
    let spread = count > 1 ? (available - CGFloat(count) * width) / CGFloat(count - 1) : minSpacing
    return Metrics(count: count, cardSize: tvCardSize, spacing: max(floorSpacing, spread))
  }
}

/// What the library's batch bar offers for a selection, after iFly's: the bar shows for as long as selection
/// mode is on, and an action is offered only once it has something to act on.
struct LibrarySelectionBarState: Equatable {
  let selectedCount: Int
  let visibleCount: Int

  /// Delete, Favorite, Unfavorite and Platform need at least one game.
  var canActOnSelection: Bool { selectedCount > 0 }
  /// Properties describes one game.
  var canShowProperties: Bool { selectedCount == 1 }
  var canSelectAll: Bool { visibleCount > 0 && selectedCount < visibleCount }
  var canDeselectAll: Bool { selectedCount > 0 }
}
