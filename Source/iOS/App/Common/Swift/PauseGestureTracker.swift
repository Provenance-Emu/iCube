import Foundation
import GameController

/// Tracks timing-based pause gestures for controllers without dedicated Menu/Start buttons
final class PauseGestureTracker {
    static let shared = PauseGestureTracker()
    
    private var shoulderHoldTimer: Timer?
    private var shoulderHoldStartTime: Date?
    private let requiredHoldDuration: TimeInterval = 2.0
    
    private init() {}
    
    /// Updates the state of all four shoulder buttons being pressed
    /// - Parameter allPressed: true if L1, R1, L2, R2 are all currently pressed
    func updateShoulderState(allPressed: Bool) {
        if allPressed {
            // Start tracking if not already tracking
            if shoulderHoldStartTime == nil {
                shoulderHoldStartTime = Date()
                
                // Set up timer to fire after required duration
                shoulderHoldTimer?.invalidate()
                shoulderHoldTimer = Timer.scheduledTimer(withTimeInterval: requiredHoldDuration, repeats: false) { [weak self] _ in
                    self?.triggerPauseMenu()
                }
            }
        } else {
            // Reset tracking when buttons are released
            shoulderHoldTimer?.invalidate()
            shoulderHoldTimer = nil
            shoulderHoldStartTime = nil
        }
    }
    
    private func triggerPauseMenu() {
        // Clean up timer state
        shoulderHoldTimer?.invalidate()
        shoulderHoldTimer = nil
        shoulderHoldStartTime = nil
        
        // Trigger pause menu
        DispatchQueue.main.async {
            TVEmulationBridge.pause()
            NotificationCenter.default.post(name: Notification.Name("DOLShowPauseMenu"), object: nil)
        }
    }
    
    deinit {
        shoulderHoldTimer?.invalidate()
    }
}
