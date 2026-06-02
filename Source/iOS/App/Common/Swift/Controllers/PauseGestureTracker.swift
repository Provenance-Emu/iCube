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

    private init() {}

    /// Call whenever the current state of the four shoulder buttons changes.
    /// - Parameter allPressed: true if L1, R1, L2, R2 are all currently pressed.
    func updateShoulderState(allPressed: Bool) {
        NSLog("updateShoulderState: \(allPressed ? "Yes" : "No")")
        isAllShouldersHeld = allPressed
    }

    /// Call when Menu or Start is pressed.
    /// If all shoulders are currently held, this will show the pause menu.
    /// Also permits a small timing tolerance if shoulders were just pressed
    /// shortly before the Menu press to account for handler ordering.
  func menuOrStartPressed() {
        NSLog("menuOrStartPressed entered: isAllShouldersHeld? \(isAllShouldersHeld ? "Yes" : "No")")

        let now = Date().timeIntervalSince1970
        guard isAllShouldersHeld else { return }
        DispatchQueue.main.async {
            NSLog("menuOrStartPressed recognized shoulder gesture")
          
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
            #if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
            GameActivityManager.update(isPaused: true, elapsedSeconds: 0)
            #endif
            TVEmulationBridge.pause()
            NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil)
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
