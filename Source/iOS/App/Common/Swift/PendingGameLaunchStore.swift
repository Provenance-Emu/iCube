// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Bridges App Intents (whose `perform()` isn't guaranteed to run after the library UI has
/// mounted) to the existing `dolphinios://play?id=` launch path: `perform()` writes the id here,
/// the scene delegate consumes it on `sceneDidBecomeActive` and launches through
/// `GameLaunchRequest`, same as a `dolphinios://play?id=` open.
enum PendingGameLaunchStore {
    private static let key = "pending_intent_game_id_v1"
    /// Matches the cold-launch URL-context delay in `MainDisplaySceneDelegate.willConnectTo` —
    /// gives the library view time to mount its `DOLLaunchGameByGameID` observer.
    private static let launchDelay: TimeInterval = 0.6

    static func set(gameID: String, in defaults: UserDefaults = SharedDefaults.suite) {
        guard !gameID.isEmpty else { return }
        defaults.set(gameID, forKey: key)
    }

    /// Test seam: consumes (and clears) the pending id without scheduling the launch.
    static func consume(from defaults: UserDefaults = SharedDefaults.suite) -> String? {
        guard let gameID = defaults.string(forKey: key), !gameID.isEmpty else { return nil }
        defaults.removeObject(forKey: key)
        return gameID
    }

    @MainActor
    static func consumeAndLaunch(from defaults: UserDefaults = SharedDefaults.suite) {
        guard let gameID = consume(from: defaults) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + launchDelay) {
            GameLaunchRequest.launch(gameID: gameID)
        }
    }
}
