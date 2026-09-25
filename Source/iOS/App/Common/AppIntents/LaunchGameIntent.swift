// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import AppIntents

/// "Play <game> in iCube". Hands off through `PendingGameLaunchStore`, the same App Group
/// bridge `dolphinios://play?id=` uses, rather than launching directly — `perform()` isn't
/// guaranteed to run after the library UI has mounted.
struct LaunchGameIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Game"
    static var description = IntentDescription("Launches a game in iCube.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Game")
    var game: iCubeGameEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$game) in iCube")
    }

    func perform() async throws -> some IntentResult {
        PendingGameLaunchStore.set(gameID: game.id)
        return .result()
    }
}
