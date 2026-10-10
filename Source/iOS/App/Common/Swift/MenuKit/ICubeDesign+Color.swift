// Common/Swift/MenuKit/ICubeDesign+Color.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// The colour roles of spec §2.5. Each is an adaptive `UIColor`, so it follows light and dark mode
/// and tests can resolve either appearance.
enum ICubeColorRole: CaseIterable {
  case accent, rowSurface, selectedFill, hairline, textPrimary, textSecondary, textTertiary, destructive
}

extension ICubeDesign {
  private static let ink = UIColor(red: 0x0A / 255, green: 0x0F / 255, blue: 0x26 / 255, alpha: 1)

  private static func adaptive(light: UIColor, dark: UIColor) -> UIColor {
    UIColor { $0.userInterfaceStyle == .dark ? dark : light }
  }

  private static func hex(_ value: UInt32) -> UIColor {
    UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
  }

  static func uiColor(_ role: ICubeColorRole) -> UIColor {
    switch role {
    // The DolphinTint asset: #3F56A4 light, #8EC5F9 dark.
    case .accent: UIColor(resource: .dolphinTint)
    case .rowSurface: adaptive(light: ink.withAlphaComponent(0.05), dark: .white.withAlphaComponent(0.07))
    case .selectedFill: adaptive(light: hex(0x3F56A4).withAlphaComponent(0.2), dark: hex(0x8EC5F9).withAlphaComponent(0.2))
    case .hairline: adaptive(light: ink.withAlphaComponent(0.12), dark: .white.withAlphaComponent(0.10))
    case .textPrimary: adaptive(light: ink, dark: .white)
    case .textSecondary: adaptive(light: ink.withAlphaComponent(0.65), dark: .white.withAlphaComponent(0.70))
    // 50 % light, not the sheet's 45 %: 45 % misses 3:1 (spec Correction 1).
    case .textTertiary: adaptive(light: ink.withAlphaComponent(0.50), dark: .white.withAlphaComponent(0.45))
    case .destructive: .systemRed
    }
  }

  static func color(_ role: ICubeColorRole) -> Color { Color(uiColor: uiColor(role)) }

  /// The room gradient, top-leading → bottom-trailing.
  static let roomStops: [UIColor] = [
    adaptive(light: hex(0xE6EDFA), dark: hex(0x141F38)),
    adaptive(light: hex(0xD6E3FA), dark: hex(0x0A0F26)),
    adaptive(light: hex(0xF5F7FF), dark: hex(0x000000)),
  ]

  /// Focus rings on rows, tiles and rail items (not the card, whose ring is frozen in `ICubeCardArtFocus`).
  static var focusGradient: LinearGradient {
    LinearGradient(colors: [Color(uiColor: .systemCyan), color(.accent), Color(uiColor: .systemPurple)],
                   startPoint: .topLeading, endPoint: .bottomTrailing)
  }

  /// The `title` role's top-down fill (spec §2.5).
  static var titleGradient: LinearGradient {
    LinearGradient(colors: [color(.textPrimary), color(.accent)], startPoint: .top, endPoint: .bottom)
  }
}
