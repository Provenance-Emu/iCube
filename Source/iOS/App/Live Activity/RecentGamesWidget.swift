// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import PVWidgets
import SwiftUI
import WidgetKit

/// A game list drawn by the shared PVWidgets package, at every Home Screen size. It shows
/// recently played games until the person picks another list (continue, favorites, recently
/// added) or a list layout on the widget's edit screen. The type keeps its old name with the kind. Games link straight to `dolphinios://play?id=`, the
/// same URL Top Shelf and Siri intents use. Data comes from the App Group snapshot
/// (`ICubeWidgetDataSource`); the app calls `WidgetCenter.shared.reloadTimelines(ofKind:)` after
/// every snapshot write (`EcosystemSurfaceRefresher`).
struct RecentGamesWidget: Widget {
  var body: some WidgetConfiguration {
    FeedWidgetDefinition(
      // Unchanged from the hand-drawn widget, so widgets already on a Home Screen stay.
      kind: RecentGamesWidgetKind.identifier,
      displayName: "Games",
      description: "Your recently played games, games to continue, favorites or new additions. Edit the widget to choose the list.",
      defaultFeed: ICubeWidgetDataSource.recentlyPlayed,
      families: [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
    ).configuration
  }
}
