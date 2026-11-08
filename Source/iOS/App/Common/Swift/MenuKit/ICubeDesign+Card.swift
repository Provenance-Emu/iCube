// Common/Swift/MenuKit/ICubeDesign+Card.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// The tvOS card look, ported from iFly's pause grid (`DreamcastCardButtonStyle`, `TVDreamcastBackground`,
/// `PauseMenuView+tvOSGrid`): an opaque card on focus with an accent border, a 1.06 lift and two coloured glows,
/// over a full-bleed room with a vignette and two blurred colour blobs.
extension ICubeDesign {
  enum Card {
    static let cornerRadius: CGFloat = 20
    /// Row cards (the save-state pane's View All, sub-pane rows) are a step tighter.
    static let rowCornerRadius: CGFloat = Radius.large.rawValue
    static let focusScale: CGFloat = 1.06
    /// Multiplies the focus scale while the remote is pressed.
    static let pressedScale: CGFloat = 0.97
    static let restFillOpacity: Double = 0.55
    static let borderWidth: CGFloat = 3
    static let restBorderOpacity: Double = 0.18

    static let primaryGlowOpacity: Double = 0.5
    static let primaryGlowRadius: CGFloat = 22
    static let primaryGlowY: CGFloat = 6
    static let secondaryGlowOpacity: Double = 0.4
    static let secondaryGlowRadius: CGFloat = 30
    static let secondaryGlowY: CGFloat = 10

    /// Room a ScrollView's content needs for the scale and glows to draw inside its clip: a shadow fades out over
    /// about twice its radius (30 pt, offset 10), plus the scale overhang. iFly's 44 still shaved the glow flat at
    /// the scroll edge. Applied as padding and cancelled again outside, so the clip moves, not the cards.
    static let glowInset: CGFloat = 80

    static let focusSpring = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let pressSpring = Animation.spring(response: 0.3, dampingFraction: 0.7)

    /// The card surface: a lifted navy over the room's dark stops.
    static let uiSurface = UIColor { $0.userInterfaceStyle == .dark
      ? UIColor(red: 0x1C / 255, green: 0x27 / 255, blue: 0x48 / 255, alpha: 1)
      : UIColor(red: 0xF5 / 255, green: 0xF7 / 255, blue: 0xFF / 255, alpha: 1) }
    static var surface: Color { Color(uiColor: uiSurface) }
    /// Text on a white pill.
    static let leadInk = UIColor(red: 0x0A / 255, green: 0x0F / 255, blue: 0x26 / 255, alpha: 1)
  }

  /// The tvOS pause screen's geometry (iFly's numbers at 1080p).
  enum TVPause {
    static let horizontalMargin: CGFloat = 90
    static let topMargin: CGFloat = 70
    static let bottomMargin: CGFloat = 44
    static let heroWidth: CGFloat = 380
    static let heroArtWidth: CGFloat = 260
    static let heroGap: CGFloat = 64
    /// Between the hero/tiles band and the help footer.
    static let footerGap: CGFloat = 28
    static let primaryTileHeight: CGFloat = 150
    static let tileHeight: CGFloat = 118
    static let primaryRowSpacing: CGFloat = 26
    static let gridSpacing: CGFloat = 22
    static let sectionSpacing: CGFloat = 30
    static let footerHeight: CGFloat = 104
    static let footerCornerRadius: CGFloat = 18
    static let footerFillOpacity: Double = 0.35
    static let footerBorderOpacity: Double = 0.15
    static let heroArtShadowRadius: CGFloat = 24
    static let heroArtShadowY: CGFloat = 14
    /// "▌▌ PAUSED" letter spacing.
    static let pausedTracking: CGFloat = 6
  }

  /// The full-bleed room behind the tvOS pause screen and its panes (`ICubeTVRoomBackground`).
  enum TVRoom {
    /// The screen the numbers below are for (a 1080p TV, in points); other screens scale them.
    static let referenceSize = CGSize(width: 1920, height: 1080)
    static let vignetteStartRadius: CGFloat = 200
    static let vignetteEndRadius: CGFloat = 1400
    static let vignetteOpacity: Double = 0.55
    static let primaryBlobDiameter: CGFloat = 900
    static let primaryBlobOpacity: Double = 0.22
    static let primaryBlobOffset = CGSize(width: -500, height: 420)
    static let secondaryBlobDiameter: CGFloat = 820
    static let secondaryBlobOpacity: Double = 0.20
    static let secondaryBlobOffset = CGSize(width: 560, height: -360)
    static let blobBlur: CGFloat = 220
    static let artBlur: CGFloat = 60
    static let artOpacity: Double = 0.18
    static let glossOpacity: Double = 0.05
    /// iPhone and iPad (`ICubeTVRoomBackground.artForward`): the game's own art is the room, darkened enough to read on.
    static let forwardArtBlur: CGFloat = 70
    static let forwardArtSaturation: Double = 1.6
    static let forwardScrimTop: Double = 0.42
    static let forwardScrimBottom: Double = 0.78
  }
}

#if !os(tvOS)
/// The iPhone and iPad pause tile (`PauseCardFace`) and the grid around it (`MenuStyle.cards`).
extension ICubeDesign.PauseCard {
  enum Touch {
    /// One screen class's numbers.
    struct Size {
      let cellHeight: CGFloat
      let cellSpacing: CGFloat
      let circle: CGFloat
      let glyph: CGFloat
      let title: CGFloat
      let value: Font
      let focusCornerRadius: CGFloat
      let leadHeight: CGFloat
      let leadGlyph: CGFloat
      let leadTitle: CGFloat

      /// iPhone portrait.
      static let regular = Size(cellHeight: 92, cellSpacing: 6, circle: 52, glyph: 21, title: 12, value: smallValue,
                                focusCornerRadius: 16, leadHeight: 60, leadGlyph: 20, leadTitle: 18)
      /// iPad.
      static let large = Size(cellHeight: 120, cellSpacing: 8, circle: 68, glyph: 27, title: 14, value: largeValue,
                              focusCornerRadius: 20, leadHeight: 72, leadGlyph: 24, leadTitle: 22)
      /// iPhone landscape.
      static let compact = Size(cellHeight: 76, cellSpacing: 4, circle: 42, glyph: 17, title: 11, value: smallValue,
                                focusCornerRadius: 14, leadHeight: 48, leadGlyph: 16, leadTitle: 16)

      var glyphFont: Font { .system(size: glyph, weight: .semibold) }
      var leadGlyphFont: Font { .system(size: leadGlyph, weight: .bold) }

      private static let smallValue = Font.system(.caption2, design: .rounded, weight: .medium)
      private static let largeValue = Font.system(.caption, design: .rounded, weight: .medium)
    }

    static let leadFill = Color.white
    static let leadInk = Color(uiColor: ICubeDesign.Card.leadInk)
    static let leadSpacing: CGFloat = ICubeDesign.Spacing.xs.rawValue
    static let leadHorizontalPadding: CGFloat = ICubeDesign.Spacing.s.rawValue
    static let cellHorizontalPadding: CGFloat = 2
    /// Keeps the circle clear of the box a press or a pad's focus draws around the cell.
    static let cellTopPadding: CGFloat = 4
    static let titleValueSpacing: CGFloat = 1
    static let titleMinimumScale: CGFloat = 0.8
    static let valueMinimumScale: CGFloat = 0.8

    static let glassFill = LinearGradient(colors: [Color.white.opacity(0.2), Color.white.opacity(0.08)],
                                          startPoint: .top, endPoint: .bottom)
    static let glassEdge = LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.06)],
                                          startPoint: .top, endPoint: .bottom)

    static let gridSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 14
    /// Between a section's quiet label and its row.
    static let sectionLabelSpacing: CGFloat = 8
    static let sectionFont = Font.system(.footnote, design: .rounded, weight: .semibold)
    static let hintFont = Font.footnote
    static let hintHeight: CGFloat = 38
    /// Room inside the scroll view for the focus scale and glow, cancelled outside it so the cells stay put.
    static let scrollInset: CGFloat = 14
    /// The cells fade out over this height above the hint line, instead of being cut by it.
    static let scrollFadeHeight: CGFloat = 24
  }
}
#endif

extension EnvironmentValues {
  /// Published by `ICubeCardButtonStyle` on its label, so a card face can swap its fill and border on focus.
  @Entry var icubeCardFocused: Bool = false
}
