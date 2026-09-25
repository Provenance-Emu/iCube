// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import AppIntents
import PVLibrarySnapshot

/// "Play a random game in iCube". Picks uniformly from the whole snapshot library.
struct PlayRandomGameIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Random Game"
    static var description = IntentDescription("Launches a random game from your iCube library.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        let snapshot = LibrarySnapshotStore().load()
        var rng = SystemRandomNumberGenerator()
        guard let picked = RandomGameSelector.pick(from: snapshot, using: &rng) else {
            throw iCubeIntentError.noGames
        }
        PendingGameLaunchStore.set(gameID: picked.id)
        return .result()
    }
}
