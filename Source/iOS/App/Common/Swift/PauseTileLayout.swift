// Common/Swift/PauseTileLayout.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics

/// Spec §5.1 column rule for the pause overlay's tile grid.
enum PauseTileLayout {
  static let tvColumns = 6

  static func columns(forWidth width: CGFloat, isTV: Bool) -> Int {
    if isTV { return tvColumns }
    switch width {
    case ..<600: return 3
    case ..<900: return 4
    case ..<1200: return 5
    default: return 6
    }
  }
}
