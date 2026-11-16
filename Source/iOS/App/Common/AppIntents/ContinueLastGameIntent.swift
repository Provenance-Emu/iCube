// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import AppIntents
import PVLibrarySnapshot

/// "Continue my game in iCube". Resumes the most recently played game from the snapshot
/// (`ResumeLastGame` decides which); tells Siri when there is none.
struct ContinueLastGameIntent: AppIntent {
    static var title: LocalizedStringResource = "Continue Last Game"
    static var description = IntentDescription("Resumes the most recently played game in iCube.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        switch ResumeLastGame.decide(snapshot: LibrarySnapshotStore().load()) {
        case .resume(let gameID):
            PendingGameLaunchStore.set(gameID: gameID)
            return .result()
        case .openAppOnly:
            throw iCubeIntentError.noRecentGame
        }
    }
}
