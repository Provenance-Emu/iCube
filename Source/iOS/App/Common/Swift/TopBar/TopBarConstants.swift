// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Timing shared by the top bar, its toast and their tests.
enum TopBarTiming {
  static let nanosecondsPerSecond: Double = 1_000_000_000
  /// How often the bar re-reads state that can change behind its back (mute, fast-forward) while it is up.
  static let stateRefreshInterval: TimeInterval = 1
  /// If a popover never reports its dismissal, a destination waiting on it is presented after this long.
  static let popoverDismissFallback: TimeInterval = 0.6
  /// The longest a hand-off hold outlives the request that took it, in case the destination never reports presenting.
  static let handoffGrace: TimeInterval = 1.5

  static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
    UInt64(max(0, seconds) * nanosecondsPerSecond)
  }
}

/// The one animation the bar uses to slide in and out.
enum TopBarStyle {
  static let transition = Animation.spring(response: 0.3, dampingFraction: 0.9)
}

/// UserDefaults keys the bar reads to decide which controls to offer.
enum TopBarDefaultsKey {
  static let thermalAutoEnable = "thermal_auto_enable"
  static let instantReplayEnabled = "replaykit_instant_replay_enabled"
}

/// Reports the bar's real height so anything pinned under it (the toast) follows it.
struct TopBarHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// A destination (sheet, overlay, alert) chosen from a popover. It must not be presented in the same
/// update that dismisses the popover: SwiftUI can drop a presentation requested while one is dismissing.
/// The request waits here until the popover reports it is gone, and is taken exactly once.
struct TopBarHandoff<Destination: Equatable>: Equatable {
  /// Held in `TopBarVisibility` from the request until the destination has taken over holding the bar up.
  static var holdID: String { "handoff" }

  private(set) var pending: Destination?

  var isPending: Bool { pending != nil }

  mutating func request(_ destination: Destination) {
    pending = destination
  }

  /// The waiting destination, once; nil when nothing waits (or it was already presented).
  mutating func take() -> Destination? {
    defer { pending = nil }
    return pending
  }
}

/// When the bar's cached toggle state (mute, fast-forward) must be re-read.
enum TopBarToggleRefresh {
  /// A pause menu, sheet or settings screen just closed: it may have changed either toggle.
  static func shouldRefresh(childWasPresented: Bool, childIsPresented: Bool) -> Bool {
    childWasPresented && !childIsPresented
  }
}

/// The toggle states the bar mirrors but does not own, read from where they live. A seam so a rendered
/// snapshot can show them on.
struct TopBarToggles: Equatable {
  var isMuted: Bool
  var fastForwardEnabled: Bool

  static func live() -> TopBarToggles {
    TopBarToggles(isMuted: QuickMute.isMuted, fastForwardEnabled: TVEmulationBridge.isFastForwardEnabled())
  }
}

/// Who paused the game. A surface that pauses (controller settings, the pause menu) resumes on close, as
/// it always did, except when the user paused from the top bar: that pause is theirs and survives it.
enum PauseOwnership {
  /// Set by the top bar's pause button while its pause is in force; cleared when it resumes, and by the
  /// screen's pause poll once the game is running again. Main thread only.
  static var pausedFromBar = false

  /// Pauses unless already paused. True when the caller should resume on close: it paused the game itself,
  /// or the game was paused by something other than the user's bar pause.
  static func claim(isPaused: Bool, pausedFromBar: Bool = PauseOwnership.pausedFromBar, pause: () -> Void) -> Bool {
    guard isPaused else {
      pause()
      return true
    }
    return !pausedFromBar
  }

  static func release(owned: Bool, resume: () -> Void) {
    if owned { resume() }
  }
}
