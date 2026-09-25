// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
// Home-screen quick actions don't exist on tvOS (no `UIApplicationShortcutItem` concept there).
#if !os(tvOS)
import PVLibrarySnapshot
import UIKit

/// Home-screen quick actions for the three most recently played games. Rebuilt after every
/// snapshot write (see `EcosystemSurfaceRefresher`) so they track what's actually in the App
/// Group snapshot, not a stale in-memory list. Routed through `MainDisplaySceneDelegate`'s
/// existing `handleShortcut` switch.
enum QuickActionsUpdater {
    static let shortcutType = "com.joemattiello.icube.play"
    static let maxItems = 3

    /// Pure: up to three most recent games, in the snapshot's existing recency order.
    static func shortcutItems(from snapshot: LibrarySnapshot) -> [UIApplicationShortcutItem] {
        snapshot.recentlyPlayed.prefix(maxItems).map { game in
            UIApplicationShortcutItem(
                type: shortcutType,
                localizedTitle: game.title,
                localizedSubtitle: game.platform.displayName,
                icon: UIApplicationShortcutIcon(systemImageName: "gamecontroller"),
                userInfo: ["id": game.id as NSString]
            )
        }
    }

    @MainActor
    static func update(with snapshot: LibrarySnapshot) {
        UIApplication.shared.shortcutItems = shortcutItems(from: snapshot)
    }
}
#endif
