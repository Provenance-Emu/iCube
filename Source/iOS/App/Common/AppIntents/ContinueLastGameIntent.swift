// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import AppIntents
import PVLibrarySnapshot

/// "Continue my game in iCube". Resumes the most recently played game from the snapshot
/// (`recentlyPlayed` is already newest-first per `LibrarySnapshot.build`).
struct ContinueLastGameIntent: AppIntent {
    static var title: LocalizedStringResource = "Continue Last Game"
    static var description = IntentDescription("Resumes the most recently played game in iCube.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        let snapshot = LibrarySnapshotStore().load()
        guard let last = snapshot.recentlyPlayed.first else {
            throw iCubeIntentError.noRecentGame
        }
        PendingGameLaunchStore.set(gameID: last.id)
        return .result()
    }
}
