import Foundation
import GameController

/// Tracks shoulder + menu/start gestures
///
/// Rules:
/// - While holding all four shoulder buttons (L1, L2, R1, R2): fast-forward is ACTIVE
/// - While holding all four shoulder buttons AND pressing Menu/Start: show the pause menu
/// - No long-hold gesture on shoulders alone
final class PauseGestureTracker {
  @MainActor
  static let shared = PauseGestureTracker()

  /// Notification posted when fast forward active state changes.
  /// userInfo: ["active": Bool]
  static let fastForwardDidChangeNotification = Notification.Name("DOLFastForwardDidChange")

  /// Swift mirror of `DOLRequestPauseMenuNotification` (declared in EmuEventVC.h,
  /// defined in EmuEventVC.m — the single string literal lives there).
  static let requestPauseMenuNotification: Notification.Name = .DOLRequestPauseMenu

  /// True when all four shoulder buttons are currently held down.
  private(set) var isAllShouldersHeld: Bool = false {
    didSet {
      if oldValue != isAllShouldersHeld {
        // Activate/deactivate fast forward in the core
        syncFastForward(with: isAllShouldersHeld)
        // Legacy/local notification for other listeners
        NotificationCenter.default.post(
          name: Self.fastForwardDidChangeNotification,
          object: nil,
          userInfo: ["active": isAllShouldersHeld]
        )
        // UI/state notification used by ControllerManager/EmulationScreen
        NotificationCenter.default.post(
          name: Notification.Name("DOLFastForwardToggled"),
          object: nil,
          userInfo: ["enabled": NSNumber(value: isAllShouldersHeld)]
        )
      }
    }
  }

  /// Two Menu routes can fire for one physical press (UIPress + GCController).
  /// Requests closer together than this are treated as the same press.
  private static let pauseRequestCoalesceWindow: TimeInterval = 0.35
  private var lastPauseRequest: TimeInterval = 0
  /// Pairing a DualShock/DualSense/Xbox pad means holding its Home/PS button, and the
  /// framework can deliver that press through the freshly installed `buttonHome` handler
  /// right after `GCControllerDidConnect`. Mid-game that paused the core and popped the
  /// pause menu the instant the pad connected (the TestFlight "menu won't go away /
  /// touch stops working when I connect a controller" reports). Ignore pause requests
  /// for a short window after any connect.
  private static let connectGraceWindow: TimeInterval = 0.75
  private var lastControllerConnect: TimeInterval = 0

  func noteControllerConnected() {
    lastControllerConnect = Date().timeIntervalSinceReferenceDate
  }

  /// Press-down timestamps for the dual-purpose pause-menu buttons
  /// (`microGamepad.buttonMenu` on the Siri Remote, `buttonOptions` on
  /// extended gamepads), keyed by route. See `menuButtonChanged`.
  private var menuPressStart: [String: TimeInterval] = [:]

  /// State of the most recent `extendedGamepad.buttonMenu` transition, noted
  /// by `ControllerExtensions.installPauseMenuHandlers` on every press AND
  /// release. An extended gamepad's Menu button (Xbox "≡", the PlayStation
  /// button labelled OPTIONS — which GameController exposes as `buttonMenu`,
  /// not `buttonOptions` — Switch Pro "+") is bound to the emulated Start/+
  /// by the default Dolphin profile, not the pause menu — `buttonOptions` is
  /// that pad's dedicated pause button instead. `EmuEventVC`
  /// (`GCEventViewController`) can still surface the SAME physical Menu press
  /// as a `"uipress-menu"` request (the route that exists so the Siri Remote,
  /// which has no other button, can pause) — `requestPauseMenu` uses this
  /// state to drop that specific duplicate without touching a genuine Siri
  /// Remote press, which has no accompanying extended-gamepad transition to
  /// correlate against.
  ///
  /// Both `isDown` and the timestamp are tracked, not just the timestamp,
  /// because the two routes race for a hold longer than
  /// `pauseRequestCoalesceWindow`: by the time `pressesEnded` posts
  /// `"uipress-menu"` the press-down note may already have fallen outside the
  /// window. `isDown` still being true (the release-side note on the
  /// GCController path hasn't landed yet) or the timestamp still being fresh
  /// (it has) — either one — is enough to suppress, so the outcome does not
  /// depend on which of the two `@MainActor` hops wins the race.
  private var extendedGamepadMenuIsDown = false
  private var lastExtendedGamepadMenuTransition: TimeInterval = 0

  private init() {}

  /// Call on every `extendedGamepad.buttonMenu` press/release transition.
  /// See `extendedGamepadMenuIsDown` / `lastExtendedGamepadMenuTransition`.
  func noteExtendedGamepadMenuPress(pressed: Bool) {
    extendedGamepadMenuIsDown = pressed
    lastExtendedGamepadMenuTransition = Date().timeIntervalSinceReferenceDate
  }

  /// Call whenever the current state of the four shoulder buttons changes.
  /// - Parameter allPressed: true if L1, R1, L2, R2 are all currently pressed.
  func updateShoulderState(allPressed: Bool) {
    NSLog("updateShoulderState: \(allPressed ? "Yes" : "No")")
    isAllShouldersHeld = allPressed
  }

  /// Call when Menu or Start is pressed **as part of the shoulder chord**.
  ///
  /// This is the *only* route a plain Menu press has into the pause menu:
  /// L1+R1+L2+R2 held while Menu/Start is pressed. Outside the chord, Menu is
  /// the emulated Start/+ button (bound by the default Dolphin profile) and
  /// must NOT open the pause menu — see the doc comment on
  /// `installPauseMenuHandlers` (ControllerExtensions.swift). The ungated
  /// pause-menu route for extended gamepads is `buttonOptions` instead, which
  /// calls `requestPauseMenu()` directly via `menuButtonChanged`. The chord is
  /// kept because it doubles as the fast-forward gesture and users rely on it.
  func menuOrStartPressed() {
    guard isAllShouldersHeld else { return }
    requestPauseMenu(reason: "shoulder-chord")
  }

  /// The dedicated pause-menu button (Siri Remote Menu, or `buttonOptions` on
  /// an extended gamepad) is dual-purpose during emulation: a short press
  /// opens the pause menu, a hold of `DOLMenuLongPressDuration` exits to the
  /// library. So the decision can only be made at RELEASE — requesting the
  /// pause menu on press-down would flash the menu at t=0 on every hold and
  /// then exit at t=2. `EmuEventVC` takes the same shape on the UIPress path,
  /// using the same constant.
  func menuButtonChanged(pressed: Bool, reason: String) {
    let now = Date().timeIntervalSinceReferenceDate
    guard !pressed else {
      menuPressStart[reason] = now
      return
    }
    guard let start = menuPressStart.removeValue(forKey: reason) else { return }
    guard now - start < DOLMenuLongPressDuration else { return }
    requestPauseMenu(reason: reason)
  }

  /// The single sink for "the user asked for the pause menu".
  ///
  /// Every route — Siri Remote Menu (UIPress), microGamepad Menu, extended
  /// gamepad Menu/Options, DS4/DS5/Xbox Home, the touchpad button, the
  /// on-screen long press and the shoulder chord — funnels through here so that:
  ///
  /// 1. It is **gated** on emulation actually running. The same handlers stay
  ///    installed while the library is on screen (a nil handler lets tvOS/iOS
  ///    fall back to its own Menu behaviour — Game Center / app switcher), so
  ///    the gate is what makes an always-installed handler safe.
  /// 2. It is **coalesced**. On tvOS a Siri Remote Menu press can arrive on both
  ///    the UIPress path and the GCController path; without a window the menu
  ///    would be requested twice for one press.
  func requestPauseMenu(reason: String = "") {
    guard TVEmulationBridge.isRunning() else {
      if UserDefaults.standard.bool(forKey: "input_debug") {
        NSLog("[INPUT] pause request ignored (%@): emulation not running", reason)
      }
      return
    }
    let now = Date().timeIntervalSinceReferenceDate
    if now - lastControllerConnect < Self.connectGraceWindow {
      if UserDefaults.standard.bool(forKey: "input_debug") {
        NSLog("[INPUT] pause request ignored (%@): controller connected %.2fs ago", reason, now - lastControllerConnect)
      }
      return
    }
    // See `extendedGamepadMenuIsDown`: a "uipress-menu" request that
    // correlates with an extended gamepad's Menu press is that pad's Start
    // button, not a pause request — drop it. A genuine Siri Remote press has
    // no accompanying extended-gamepad transition and is unaffected.
    if reason == "uipress-menu",
       extendedGamepadMenuIsDown || now - lastExtendedGamepadMenuTransition < Self.pauseRequestCoalesceWindow {
      if UserDefaults.standard.bool(forKey: "input_debug") {
        NSLog("[INPUT] pause request ignored (%@): correlates with an extended-gamepad Menu press (Start)", reason)
      }
      return
    }
    guard now - lastPauseRequest > Self.pauseRequestCoalesceWindow else { return }
    lastPauseRequest = now
    DispatchQueue.main.async {
      if UserDefaults.standard.bool(forKey: "input_debug") {
        NSLog("[INPUT] presenting pause menu (%@)", reason)
      }
      #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
      GameActivityManager.update(isPaused: true, elapsedSeconds: 0)
      #endif
      TVEmulationBridge.pause()
      NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil)
    }
  }

  @MainActor
  @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
    if gesture.state == .began {
      requestPauseMenu(reason: "long-press")
    }
  }

  /// Ensure the bridge fast-forward state matches our desired active state
  private func syncFastForward(with active: Bool) {
    let currentlyEnabled = TVEmulationBridge.isFastForwardEnabled()
    if currentlyEnabled != active {
      _ = TVEmulationBridge.toggleFastForward()
    }
  }
}
