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

  private init() {}

  /// Call whenever the current state of the four shoulder buttons changes.
  /// - Parameter allPressed: true if L1, R1, L2, R2 are all currently pressed.
  func updateShoulderState(allPressed: Bool) {
    NSLog("updateShoulderState: \(allPressed ? "Yes" : "No")")
    isAllShouldersHeld = allPressed
  }

  /// Call when Menu or Start is pressed **as part of the shoulder chord**.
  ///
  /// This is now only the *chord* path: L1+R1+L2+R2 held while Menu/Start is
  /// pressed. The ungated Menu/Options path lives in `installPauseMenuHandlers`
  /// (ControllerExtensions) and calls `requestPauseMenu()` directly, so no
  /// controller depends on discovering this combo any more. The chord is kept
  /// because it doubles as the fast-forward gesture and users rely on it.
  func menuOrStartPressed() {
    guard isAllShouldersHeld else { return }
    requestPauseMenu(reason: "shoulder-chord")
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
