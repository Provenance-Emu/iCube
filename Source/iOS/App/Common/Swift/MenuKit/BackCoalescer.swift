// Common/Swift/MenuKit/BackCoalescer.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// On tvOS the release of the press that opened a menu can arrive as an exit command and close it
/// again. Drop back/exit for a short window after opening.
enum BackCoalescer {
  static let window: TimeInterval = 0.25

  static func shouldHonor(openedAt: Date, now: Date) -> Bool {
    now.timeIntervalSince(openedAt) >= window
  }
}
