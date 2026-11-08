// Common/Swift/MenuKit/ICubeDesign+LibraryDashboard.swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

#if !os(tvOS)
/// Geometry of the iPad library dashboard (`LibraryDashboardView`), after iFly's iPad layout.
extension ICubeDesign {
  enum LibraryDashboard {
    /// Narrower than this, even in landscape, the hero and the side column stack.
    static let sideBySideMinimumWidth: CGFloat = 760
    static let sideColumnWidth: CGFloat = 340
    /// The hero sets the top row's height; the side column fits inside it.
    static let heroMinimumHeight: CGFloat = 300
    static let heroCoverSize = CGSize(width: 132, height: 184)
    static let heroCoverTilt: Double = 6
    static let heroCoverShadowOpacity: Double = 0.35
    static let heroCoverShadowRadius: CGFloat = 12
    static let heroBackdropBlur: CGFloat = 16
    static let heroScrimLeadingOpacity: Double = 0.8
    static let heroScrimTrailingOpacity: Double = 0.55
    static let heroEyebrowOpacity: Double = 0.8
    static let heroDetailOpacity: Double = 0.85
    static let heroStrokeOpacity: Double = 0.14
    /// The hero's corners are `Card.cornerRadius`, a step rounder than the tiles beside it.
    static let heroCornerRadius: CGFloat = Card.cornerRadius

    static let saveCardWidth: CGFloat = 208
    static let saveThumbnailAspect: CGFloat = 16.0 / 9.0
    static let incompatibleSaveOpacity: Double = 0.5

    static let peerIconSize: CGFloat = 36
    static let peerIconWash: Double = 0.15
  }
}
#endif
