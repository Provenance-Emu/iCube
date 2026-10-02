// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Pure state machine behind the in-game top bar's show/auto-hide behaviour.
///
/// The bar hides itself after `idleInterval` of nothing happening, but never while something it opened
/// (a popover, a sheet, the perf overlay, ...) is still up: each of those registers a named hold with
/// `menuOpened` and drops it with `menuClosed`. Time is injected so the countdown is testable; the view
/// schedules a single wake-up against `deadline` and asks `shouldHide(at:)` when it fires.
struct TopBarVisibility: Equatable {
  /// How long the bar stays up without any interaction once nothing is holding it open.
  static let idleInterval: TimeInterval = 3.5

  private(set) var isVisible = false
  /// When the bar should hide, or nil when it is hidden or held open by an open menu or panel.
  private(set) var deadline: Date?
  private var holds: Set<String> = []

  /// Reveals the bar and arms the countdown (unless something is holding it open).
  mutating func show(now: Date) {
    isVisible = true
    rearm(now: now)
  }

  /// Any tap or drag on the bar: restarts the countdown.
  mutating func interaction(now: Date) {
    rearm(now: now)
  }

  /// A menu, popover, sheet or panel opened from the bar is now up. Suspends the countdown.
  mutating func menuOpened(_ id: String, now: Date) {
    holds.insert(id)
    rearm(now: now)
  }

  /// That menu or panel is gone (closing one that was never open does nothing). When it was the last one, the countdown restarts from `now`.
  mutating func menuClosed(_ id: String, now: Date) {
    guard holds.remove(id) != nil else { return }
    rearm(now: now)
  }

  /// Hides immediately. A hidden bar owns nothing, so stale holds are dropped.
  mutating func hideNow() {
    isVisible = false
    deadline = nil
    holds.removeAll()
  }

  /// True once the countdown has run out with the bar visible and nothing open.
  func shouldHide(at now: Date) -> Bool {
    guard isVisible, holds.isEmpty, let deadline else { return false }
    return now >= deadline
  }

  private mutating func rearm(now: Date) {
    deadline = isVisible && holds.isEmpty ? now.addingTimeInterval(Self.idleInterval) : nil
  }
}
