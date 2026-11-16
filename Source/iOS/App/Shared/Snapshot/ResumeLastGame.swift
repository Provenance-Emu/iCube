// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import PVLibrarySnapshot

/// What "resume the last game" should do for a given library snapshot.
enum ResumeLastGameDecision: Equatable {
    /// Queue this game id for launch, then open the app.
    case resume(gameID: String)
    /// Nothing to resume (empty library, or nothing played yet): just open the app.
    case openAppOnly
}

/// Pure decision logic behind the "Resume Last Game" Control Center control and Siri's "Continue
/// Last Game". Lives in `Shared/Snapshot` because the Live Activity widget extension compiles it
/// too; it must stay Foundation + PVLibrarySnapshot only.
enum ResumeLastGame {
    /// The most recently played game. `recentlyPlayed` is newest-first by construction, but the
    /// newest `lastPlayed` date wins here regardless of order; on a tie, or when no game carries a
    /// date, the earliest entry in the list wins. Games with an empty id are never chosen.
    static func decide(recentlyPlayed: [LibrarySnapshotGame]) -> ResumeLastGameDecision {
        let candidates = recentlyPlayed.filter { !$0.id.isEmpty }
        var best: LibrarySnapshotGame?
        for game in candidates {
            guard let current = best else { best = game; continue }
            if let candidateDate = game.lastPlayed, candidateDate > (current.lastPlayed ?? .distantPast) {
                best = game
            }
        }
        return best.map { .resume(gameID: $0.id) } ?? .openAppOnly
    }

    static func decide(snapshot: LibrarySnapshot) -> ResumeLastGameDecision {
        decide(recentlyPlayed: snapshot.recentlyPlayed)
    }
}

/// The App Group key an App Intent writes a game id under, and `PendingGameLaunchStore` consumes on
/// `sceneDidBecomeActive`. One constant, because the intent also runs from the widget extension's
/// copy of the code and must agree with the app.
enum PendingGameLaunchKey {
    static let defaultsKey = "pending_intent_game_id_v1"
}
