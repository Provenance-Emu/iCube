import Foundation
import GameController

/// Tracks shoulder + menu/start gestures
///
/// Rules:
/// - While holding all four shoulder buttons (L1, L2, R1, R2): fast-forward is ACTIVE
/// - While holding all four shoulder buttons AND pressing Menu/Start: show the pause menu
/// - No long-hold gesture on shoulders alone
final class PauseGestureTracker {
    static let shared = PauseGestureTracker()

    /// Notification posted when fast forward active state changes.
    /// userInfo: ["active": Bool]
    static let fastForwardDidChangeNotification = Notification.Name("DOLFastForwardDidChange")

    /// True when all four shoulder buttons are currently held down.
    private(set) var isAllShouldersHeld: Bool = false {
        didSet {
            if oldValue != isAllShouldersHeld {
                if isAllShouldersHeld { lastAllShouldersTrueAt = Date().timeIntervalSince1970 }
                NotificationCenter.default.post(
                    name: Self.fastForwardDidChangeNotification,
                    object: nil,
                    userInfo: ["active": isAllShouldersHeld]
                )
            }
        }
    }

    /// Time the shoulders were last observed as all pressed (epoch seconds).
    private var lastAllShouldersTrueAt: TimeInterval = 0

    private init() {}

    /// Call whenever the current state of the four shoulder buttons changes.
    /// - Parameter allPressed: true if L1, R1, L2, R2 are all currently pressed.
    func updateShoulderState(allPressed: Bool) {
        isAllShouldersHeld = allPressed
        if allPressed { lastAllShouldersTrueAt = Date().timeIntervalSince1970 }
    }

    /// Call when Menu or Start is pressed.
    /// If all shoulders are currently held, this will show the pause menu.
    /// Also permits a small timing tolerance if shoulders were just pressed
    /// shortly before the Menu press to account for handler ordering.
    func menuOrStartPressed() {
        let now = Date().timeIntervalSince1970
        let recentShoulders = (now - lastAllShouldersTrueAt) <= 0.30
        guard isAllShouldersHeld || recentShoulders else { return }
        DispatchQueue.main.async {
            TVEmulationBridge.pause()
            NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil)
        }
    }

    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            TVEmulationBridge.pause()
            #if canImport(ActivityKit)
            GameActivityManager.update(isPaused: true, elapsedSeconds: 0)
            #endif
            NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil)
        }
    }
}
