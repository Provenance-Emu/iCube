// Common/Swift/MenuKit/MenuTheme.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The few tokens the menu kit draws with (unified menu UX spec §4.1). One palette; ported from iFly's
/// Theme protocol with the Dreamcast branding removed. iCube keeps its blurred cover-art backdrop and
/// material tiles, so the theme never owns a background colour.
protocol MenuTheme {
  var accent: Color { get }
  var tileFill: Material { get }
  var cornerRadius: CGFloat { get }
  var focusRingWidth: CGFloat { get }
  var focusScale: CGFloat { get }
  var tileMinHeight: CGFloat { get }
  var shelfHeight: CGFloat { get }
  var tileTitleFont: Font { get }
}

struct ICubeTheme: MenuTheme {
  var accent: Color = .accentColor
  var tileFill: Material = .ultraThinMaterial
  var cornerRadius: CGFloat = 16
  var focusRingWidth: CGFloat = 4
  var focusScale: CGFloat = 1.06
  #if os(tvOS)
  var tileMinHeight: CGFloat = 180
  var shelfHeight: CGFloat = 80
  var tileTitleFont: Font = .headline
  #else
  var tileMinHeight: CGFloat = 96
  var shelfHeight: CGFloat = 56
  var tileTitleFont: Font = .subheadline.weight(.semibold)
  #endif
}

private struct MenuThemeKey: EnvironmentKey {
  static let defaultValue: any MenuTheme = ICubeTheme()
}

extension EnvironmentValues {
  var menuTheme: any MenuTheme {
    get { self[MenuThemeKey.self] }
    set { self[MenuThemeKey.self] = newValue }
  }
}
