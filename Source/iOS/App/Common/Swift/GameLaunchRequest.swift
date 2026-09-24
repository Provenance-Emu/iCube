// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Boots a game by id from outside the library UI (Top Shelf, URL). If a game is
/// running it is stopped first; the library remounts and its
/// `DOLLaunchGameByGameID` observer performs the actual boot.
@MainActor
enum GameLaunchRequest {
  private static let pollInterval: TimeInterval = 0.25
  private static let stopTimeout: TimeInterval = 10
  private static let remountDelay: TimeInterval = 0.5

  static func launch(gameID: String) {
    guard !gameID.isEmpty else { return }
    if TVEmulationBridge.isRunning() {
      TVEmulationBridge.stop()
      NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
      waitForStop(deadline: Date().addingTimeInterval(stopTimeout)) { post(gameID) }
    } else {
      post(gameID)
    }
  }

  private static func waitForStop(deadline: Date, then completion: @escaping () -> Void) {
    if !TVEmulationBridge.isRunning() {
      DispatchQueue.main.asyncAfter(deadline: .now() + remountDelay, execute: completion)
      return
    }
    guard Date() < deadline else {
      NSLog("[Launch] core did not stop within %.0fs; giving up on %@", stopTimeout, "play link")
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { waitForStop(deadline: deadline, then: completion) }
  }

  private static func post(_ gameID: String) {
    NotificationCenter.default.post(name: NSNotification.Name("DOLLaunchGameByGameID"), object: nil, userInfo: ["gameID": gameID])
  }
}
