// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Observation

/// Whether a game session is running, for everything that should stay quiet while one is.
///
/// A session is active from `DOLEmulationWillStartNotification` (the boot, shader compile and JIT
/// handshake included) until `DOLEmulationDidEndNotification`. Library background work (rescans,
/// Spotlight, the App Group snapshot, network-path refreshes) competes with the emulation threads
/// for cores and memory bandwidth, and the SwiftUI library underneath keeps animating and
/// re-evaluating unless something tells it to stop. This is the one place that answers
/// "is a game running?".
///
/// Read it from SwiftUI (`EmulationState.shared.isActive` in a `body` is tracked) or from main-actor
/// code. Off the main thread use `EmulationTelemetryGate.isEmulationActive`, which the Sentry service
/// maintains from the same notifications.
///
/// Work that cannot run during a session registers through `EmulationDeferral`, or calls
/// `addTransitionHandler` directly, and is flushed when the session ends. Handlers run after
/// `isActive` has been updated, so they never race the flag the way two independent
/// `DidEnd` observers would.
@MainActor
@Observable
final class EmulationState {
  static let shared = EmulationState()

  static let willStartName = Notification.Name("DOLEmulationWillStartNotification")
  static let didEndName = Notification.Name("DOLEmulationDidEndNotification")

  private(set) var isActive = false

  @ObservationIgnored private var handlers: [UUID: @MainActor (Bool) -> Void] = [:]
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private let center: NotificationCenter

  /// `center` is injectable so tests can post the notifications without touching the app's.
  init(center: NotificationCenter = .default) {
    self.center = center
    observers = [
      center.addObserver(forName: Self.willStartName, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.setActive(true) }
      },
      center.addObserver(forName: Self.didEndName, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.setActive(false) }
      }
    ]
  }

  deinit {
    for token in observers { center.removeObserver(token) }
  }

  /// Applies a state change. Repeats are ignored: `DidEnd` is posted from several places (the core's
  /// shutdown, the in-game screen's exit, a cancelled JIT prompt that never posted `WillStart`).
  func setActive(_ active: Bool) {
    guard active != isActive else { return }
    isActive = active
    for handler in Array(handlers.values) { handler(active) }
  }

  /// Calls `handler(true)` when a session starts and `handler(false)` when it ends, until the
  /// returned token is passed to `removeTransitionHandler`. Not called for the current state.
  @discardableResult
  func addTransitionHandler(_ handler: @escaping @MainActor (Bool) -> Void) -> UUID {
    let token = UUID()
    handlers[token] = handler
    return token
  }

  func removeTransitionHandler(_ token: UUID) {
    handlers[token] = nil
  }
}

/// Runs `work` now, or, if a game is running, once when it ends. Any number of requests during a
/// session collapse into one run. A deferral lives as long as the app: it stays registered with the
/// shared state, so create them once, not per request. Used for work that is idempotent and reads current state when it
/// runs (rescans, index passes), so deferring it loses nothing.
@MainActor
final class EmulationDeferral {
  private let state: EmulationState
  private let work: @MainActor () -> Void
  private(set) var isPending = false

  init(state: EmulationState = .shared, work: @escaping @MainActor () -> Void) {
    self.state = state
    self.work = work
    state.addTransitionHandler { [weak self] active in
      guard let self, !active, self.isPending else { return }
      self.isPending = false
      self.work()
    }
  }

  /// Runs `work` immediately when idle, otherwise marks it for the end of the session.
  func request() {
    if state.isActive {
      isPending = true
    } else {
      work()
    }
  }
}
