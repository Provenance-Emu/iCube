// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Halves the controller-navigation poll rate while a game is running (not paused).
///
/// `MenuScreen` and `PadBackNavigation` poll the pads from a shared 60 Hz main-thread timer for as
/// long as they are mounted. A menu opened over a live game (the in-game top bar's sheets) would
/// otherwise add 60 main-thread wakeups a second, plus a `GCController` sweep each, to the frame
/// budget. 30 Hz still catches every press a thumb can make, and menu repeat is timed off the clock,
/// not the tick count.
///
/// A reference type held in `@State`: ticks mutate it without invalidating the view.
final class PadPollThrottle {
  /// Poll interval while a game runs.
  static let emulatingInterval: TimeInterval = 1.0 / 30
  /// The shared timer jitters; accept a tick this much early so one is not dropped for it.
  static let tolerance: TimeInterval = 0.004

  /// True while a game is actually running: a session is active and not paused. A pause menu sits
  /// over a paused game, so it keeps the full rate.
  @MainActor
  static var gameIsRunning: Bool {
    EmulationState.shared.isActive && !TVEmulationBridge.isPaused()
  }

  private var lastRun: TimeInterval = -.infinity

  /// Whether this tick should do its polling. Always true when no game is running.
  func shouldRun(at now: TimeInterval, emulating: Bool) -> Bool {
    guard emulating else {
      lastRun = now
      return true
    }
    guard now - lastRun >= Self.emulatingInterval - Self.tolerance else { return false }
    lastRun = now
    return true
  }
}
