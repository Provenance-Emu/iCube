// Common/Swift/PauseArbiter.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import SwiftUI

/// The one owner of the core's pause state in the UI layer (unified menu UX spec §4.3).
///
/// Every surface that must keep the game paused — the pause menu, each of its panes and sheets, the
/// Settings cover, the controller-settings sheet, the user's bar pause, a controller disconnect — holds
/// a `Token`. The core is paused on the first claim and resumed when the last token goes, and nowhere
/// else: `UILayerPauseCallsTests` fails the build of any other Swift file that calls
/// `TVEmulationBridge.pause()` / `.resume()`.
///
/// Two rules keep the old behaviour that mattered:
/// - A pause the arbiter did not make (the debug API, a core-side stop) is never resumed by it.
/// - The last release resumes one main-queue turn later and re-checks the count, so a covered presenter's
///   `onDisappear` release followed by the cover's `onAppear` claim inside one SwiftUI transition never lets
///   the game run for a frame.
@MainActor
final class PauseArbiter {
  struct Token: Hashable {
    let id: UUID
    let reason: String
  }

  /// The core seam, so tests never touch `TVEmulationBridge`.
  struct Core {
    var isRunning: () -> Bool
    var isPaused: () -> Bool
    var pause: () -> Void
    var resume: () -> Void
    /// Pause / resume that never block the calling thread (the app-inactive transition runs on main
    /// while the host queue can be busy). The bridge drops one that a later pause or resume supersedes.
    var pauseAsync: () -> Void = {}
    var resumeAsync: () -> Void = {}

    static let bridge = Core(
      isRunning: { TVEmulationBridge.isRunning() },
      isPaused: { TVEmulationBridge.isPaused() },
      pause: { TVEmulationBridge.pause() },
      resume: { TVEmulationBridge.resume() },
      pauseAsync: { TVEmulationBridge.pauseAsync() },
      resumeAsync: { TVEmulationBridge.resumeAsync() })
  }

  static let shared = PauseArbiter(core: .bridge)

  /// Reasons used by more than one file. A one-off presentation can pass any string.
  enum Reason {
    static let user = "user"
    static let disconnect = "disconnect"
    static let pauseMenu = "pause-menu"
    static let pauseMenuRequest = "pause-menu-request"
    /// The app is not active (switcher, lock, Control Center, notification pull-down, backgrounded).
    static let appInactive = "app-inactive"
  }

  #if DEBUG
  /// A token still held this long after its claim is logged with its reason (spec §8).
  static let leakWarningDelay: TimeInterval = 60
  #endif

  private let core: Core
  private let schedule: (@escaping () -> Void) -> Void
  private var tokens: [Token] = []
  /// True once this object paused the core itself; only then does the last release resume.
  private var ownsPause = false
  /// A claim made while no game was running; applied on `emulationDidStart()`.
  private var deferred = false
  private var pending: Token?
  /// The claim held for as long as the app is inactive; nil while active.
  private var inactiveToken: Token?
  /// True when the app-inactive transition (not a claim) paused the core and nobody has taken that over.
  private var inactivePauseOwned = false
  /// True after `core.resumeAsync()` until a pause or resume the arbiter makes itself: that resume may still
  /// be queued, so `isPaused()` can read true for a core that is about to run. A claim or a resign in that
  /// window must pause explicitly, which also cancels the queued resume.
  private var asyncResumeIssued = false
  private var observers: [NSObjectProtocol] = []

  init(core: Core, schedule: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
    self.core = core
    self.schedule = schedule
  }

  var isHeld: Bool { !tokens.isEmpty }
  var holders: [String] { tokens.map(\.reason) }

  @discardableResult
  func claim(_ reason: String) -> Token {
    claim(reason, pausing: true)
  }

  /// `pausing: false` records the holder without touching the core, for the one claim whose pause is
  /// made asynchronously (`appWillResignActive`).
  private func claim(_ reason: String, pausing: Bool) -> Token {
    let token = Token(id: UUID(), reason: reason)
    tokens.append(token)
    if !pausing {
      // flag only
    } else if core.isRunning() {
      if asyncResumeIssued || !core.isPaused() {
        asyncResumeIssued = false
        core.pause()
        // Core::SetState ignores a pause before the core is Running, and RetroAchievements can refuse
        // one: only own the pause if it took, otherwise apply it again on emulationDidStart().
        if core.isPaused() {
          ownsPause = true
        } else {
          deferred = true
        }
      }
    } else {
      deferred = true
    }
    #if DEBUG
    let id = token.id
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.leakWarningDelay) { [weak self] in
      guard let self, self.tokens.contains(where: { $0.id == id }) else { return }
      NSLog("[PAUSE] token '%@' still held after %.0fs; holders: %@", reason, Self.leakWarningDelay, self.holders.joined(separator: ", "))
    }
    #endif
    return token
  }

  func release(_ token: Token) {
    guard let index = tokens.firstIndex(of: token) else { return }
    tokens.remove(at: index)
    if pending == token { pending = nil }
    resumeWhenEmpty()
  }

  /// Releases every token claimed with `reason`. For holders that keep no token: the top bar's pause
  /// button and the controller-disconnect pause.
  func release(reason: String) {
    guard tokens.contains(where: { $0.reason == reason }) else { return }
    tokens.removeAll { $0.reason == reason }
    if pending?.reason == reason { pending = nil }
    resumeWhenEmpty()
  }

  /// The pause menu's Resume: the user wants the game running, so their own bar pause, a disconnect
  /// pause and an unadopted pending claim go too. Presentation tokens are released by their presentations.
  func userResume() {
    if let old = pending {
      tokens.removeAll { $0 == old }
      pending = nil
    }
    tokens.removeAll { $0.reason == Reason.user || $0.reason == Reason.disconnect }
    resumeWhenEmpty()
  }

  /// The PausedPill shows only when no menu is up. If nothing is held and the core is paused, someone
  /// outside this object paused it (the debug API); the pill is the user's way out of that.
  func resumeIfUnheld() {
    guard tokens.isEmpty, core.isRunning(), core.isPaused() else { return }
    asyncResumeIssued = false
    core.resume()
    ownsPause = false
  }

  /// A claim made before its presenting surface exists: the gesture tracker pauses the instant Menu
  /// is pressed, and the pause menu appears a few frames later and `adoptPending()`s the token. A
  /// pending claim nobody adopted is released by the next `claimPending`, so a request that never
  /// presented (the menu was already up) cannot leak.
  func claimPending(_ reason: String) {
    // The menu is up (or about to be): it already holds the pause and would never adopt a second token.
    if tokens.contains(where: { $0.reason == Reason.pauseMenu || $0.reason == Reason.pauseMenuRequest }) { return }
    if let old = pending { release(old) }
    pending = claim(reason)
  }

  /// Hands the pending token to the caller exactly once; nil when there is none.
  func adoptPending() -> Token? {
    defer { pending = nil }
    return pending
  }

  /// `sceneWillResignActive`: the app is inactive, so a running game must stop emulating, and it must stay
  /// stopped whatever else changes until the app is active again. The claim is a flag only: the pause
  /// itself is `pauseAsync`, because this runs on main as the app switches away and a blocking pause
  /// there (waiting on the CPU thread) is what hung the scene callbacks before (ICUBE-7D). Nothing is
  /// claimed when no game is running, so a boot while inactive is not paused by a stale claim.
  func appWillResignActive() {
    guard inactiveToken == nil, core.isRunning() else { return }
    inactiveToken = claim(Reason.appInactive, pausing: false)
    if asyncResumeIssued || !core.isPaused() {
      asyncResumeIssued = false
      core.pauseAsync()
      inactivePauseOwned = true
      // A core still booting ignores the pause (it needs State::Running): apply it on emulationDidStart().
      deferred = true
    }
  }

  /// `sceneDidBecomeActive`: drop the inactive claim. The core resumes only if that was the last claim and
  /// the pause was ours (the app-inactive one, or one a claim made). A pause menu, a Settings cover, the
  /// user's bar pause or a disconnect pause keeps the game paused and takes over the pause, and one the
  /// arbiter never made (debug API) is left alone.
  func appDidBecomeActive() {
    guard let token = inactiveToken else { return }
    inactiveToken = nil
    let ownedInactivePause = inactivePauseOwned
    inactivePauseOwned = false
    guard let index = tokens.firstIndex(of: token) else { return }
    tokens.remove(at: index)
    if tokens.isEmpty {
      if ownedInactivePause, !ownsPause {
        deferred = false
        asyncResumeIssued = true
        core.resumeAsync()
      } else {
        resumeWhenEmpty()
      }
    } else if ownedInactivePause {
      ownsPause = true
    }
  }

  /// `DOLEmulationDidStartNotification`: apply a deferred claim.
  func emulationDidStart() {
    guard deferred, isHeld else { deferred = false; return }
    deferred = false
    if asyncResumeIssued || !core.isPaused() {
      asyncResumeIssued = false
      core.pause()
      if core.isPaused() { ownsPause = true }
    }
  }

  /// `DOLEmulationDidEndNotification`: nothing can be paused any more. Tokens are dropped; the
  /// presentations that hold them release no-ops later.
  func emulationDidStop() {
    tokens.removeAll()
    pending = nil
    inactiveToken = nil
    inactivePauseOwned = false
    asyncResumeIssued = false
    ownsPause = false
    deferred = false
  }

  func installObservers() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: .DOLEmulationDidStart, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.emulationDidStart() }
    })
    observers.append(center.addObserver(forName: .DOLEmulationDidEnd, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.emulationDidStop() }
    })
  }

  private func resumeWhenEmpty() {
    guard tokens.isEmpty else { return }
    schedule { [weak self] in
      guard let self, self.tokens.isEmpty else { return }
      if self.ownsPause, self.core.isRunning(), self.core.isPaused() {
        self.asyncResumeIssued = false
        self.core.resume()
      }
      self.ownsPause = false
      self.deferred = false
    }
  }
}

// MARK: - SwiftUI

private struct PauseClaim: ViewModifier {
  let reason: String
  @State private var token: PauseArbiter.Token?

  func body(content: Content) -> some View {
    content
      .onAppear { if token == nil { token = PauseArbiter.shared.claim(reason) } }
      .onDisappear {
        if let held = token {
          PauseArbiter.shared.release(held)
          token = nil
        }
      }
  }
}

extension View {
  /// Keeps the game paused for as long as this view is on screen. Put it on the CONTENT of every
  /// `.sheet` / `.fullScreenCover` opened over a paused game. A covered presenter releases and re-claims
  /// around its cover; the arbiter's deferred resume absorbs that.
  func pauseClaim(_ reason: String) -> some View {
    modifier(PauseClaim(reason: reason))
  }
}
