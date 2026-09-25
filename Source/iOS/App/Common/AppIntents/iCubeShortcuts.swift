// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
// Home-screen quick actions and the RecentGamesWidget are also iOS-only (see
// QuickActionsUpdater.swift and Live Activity/RecentGamesWidget.swift); the intents and entity
// above stay cross-platform since they compile fine on tvOS 17.
#if os(iOS)
import AppIntents

/// Pins the three launch intents to Siri/Shortcuts with ready-made phrases, so they show up
/// without the user having to build a Shortcut manually.
struct iCubeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LaunchGameIntent(),
            phrases: ["Play \(\.$game) in \(.applicationName)"],
            shortTitle: "Play Game",
            systemImageName: "gamecontroller.fill"
        )
        AppShortcut(
            intent: ContinueLastGameIntent(),
            phrases: ["Continue my game in \(.applicationName)", "Continue playing in \(.applicationName)"],
            shortTitle: "Continue",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayRandomGameIntent(),
            phrases: ["Play a random game in \(.applicationName)"],
            shortTitle: "Random Game",
            systemImageName: "shuffle"
        )
    }
}
#endif
