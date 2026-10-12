// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct AchievementsSnapshot {
  var enabled: Bool
  var hardcore: Bool
  var spectator: Bool
  var discordPresence: Bool
  var progress: Bool
  var isSignedIn: Bool
}

enum AchievementsChange: Equatable { case enabled(Bool), hardcore(Bool), spectator(Bool), discordPresence(Bool), progress(Bool) }

/// Pure: the RetroAchievements toggles as rows. The credential fields stay in a stock `List` beside it on tvOS.
enum AchievementsModelBuilder {
  static func make(_ s: AchievementsSnapshot, apply: @escaping (AchievementsChange) -> Void) -> MenuModel {
    MenuModel(sections: [
      MenuSection(id: "retroachievements", header: L("RetroAchievements"), items: [
        SettingsRow.toggle("enabled", L("Enable Integration"), s.enabled,
                           L("Connects to RetroAchievements.org to unlock achievements and track progress across supported games."),
                           icon: "trophy.fill", set: { apply(.enabled($0)) }),
        SettingsRow.toggle("hardcore", L("Hardcore Mode"), s.hardcore,
                           L("Disables save states, cheats, and speed changes for authentic difficulty and full achievement credit."),
                           enabled: s.enabled, icon: "flame.fill", set: { apply(.hardcore($0)) }),
        SettingsRow.toggle("spectator", L("Spectator Mode"), s.spectator,
                           L("Tracks achievements without earning them — view progress without affecting your record."),
                           enabled: s.enabled, icon: "eye.fill", set: { apply(.spectator($0)) }),
        SettingsRow.toggle("discord", L("Discord Presence"), s.discordPresence,
                           L("Shows your current game and achievements in your Discord status."),
                           enabled: s.enabled, icon: "bubble.left.and.bubble.right.fill", set: { apply(.discordPresence($0)) }),
        SettingsRow.toggle("progress", L("Show Progress Popups"), s.progress,
                           L("Displays achievement-progress notifications during gameplay."),
                           enabled: s.enabled, icon: "bell.badge.fill", set: { apply(.progress($0)) }),
      ]),
    ])
  }
}
