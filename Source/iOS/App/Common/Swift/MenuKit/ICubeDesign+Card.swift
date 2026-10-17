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
  }
}

extension EnvironmentValues {
  /// Published by `ICubeCardButtonStyle` on its label, so a card face can swap its fill and border on focus.
  @Entry var icubeCardFocused: Bool = false
}
