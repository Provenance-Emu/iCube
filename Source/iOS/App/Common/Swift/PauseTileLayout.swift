// Common/Swift/PauseTileLayout.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics

/// Column and hero rules for the pause screen's cards (tvOS: `TVPauseGridView`; iPhone and iPad: `MenuStyle.cards`).
enum PauseTileLayout {
  static let tvColumns = 4

  /// Where the iPhone/iPad hero goes: a column beside the cards (`columnWidth` > 0) or a banner above them.
  struct TouchHero: Equatable {
    var columnWidth: CGFloat
    var gap: CGFloat
  }

  /// From this width (an iPad, either way up) the hero is a column with the cover, as on the TV.
  static let heroColumnMinWidth: CGFloat = 700
  static let iPadHero = TouchHero(columnWidth: 220, gap: 28)
  /// iPhone landscape: a narrow column without the cover, so the cards keep the height.
  static let compactHeightHero = TouchHero(columnWidth: 180, gap: 16)
  /// iPhone portrait: a banner above the cards.
  static let bannerHero = TouchHero(columnWidth: 0, gap: 0)

  static func touchHero(width: CGFloat, isCompactHeight: Bool) -> TouchHero {
    if isCompactHeight { return compactHeightHero }
    return width >= heroColumnMinWidth ? iPadHero : bannerHero
  }

  /// Cards per row for the width the grid gets: three on a phone in portrait, four in landscape and on an iPad in
  /// portrait, five on a landscape iPad. Fewer, wider cards than the old tiles: a centred glyph and title need room.
  static func cardColumns(forGridWidth width: CGFloat) -> Int {
    switch width {
    case ..<520: return 3
    case ..<900: return 4
    default: return 5
    }
  }
}
