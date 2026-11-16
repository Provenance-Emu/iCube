// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import AppIntents
import PVLibrarySnapshot

/// Backs the "Resume Last Game" Control Center control. Compiled into the app AND the widget
/// extension (a control's intent has to exist in both); because it opens the app, the system runs
/// `perform()` in the app process. It therefore uses only what both targets have: the App Group
/// snapshot and the pending-launch key, not the app-only `PendingGameLaunchStore`.
///
/// The game is chosen here, when the control is tapped, not when the control is rendered, so the
/// button never resumes a game that was last played before a newer one. With nothing to resume it
/// still succeeds and the app simply opens. Hidden from Shortcuts: `ContinueLastGameIntent` is the
/// Siri/Shortcuts version of this.
struct ResumeLastGameIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Last Game"
    static var description = IntentDescription("Opens iCube and resumes the game you played most recently.")
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = false

    func perform() async throws -> some IntentResult {
        let snapshot = LibrarySnapshotStore().load()
        if case .resume(let gameID) = ResumeLastGame.decide(snapshot: snapshot) {
            ICubeSnapshot.appGroup.defaults?.set(gameID, forKey: PendingGameLaunchKey.defaultsKey)
        }
        return .result()
    }
}
