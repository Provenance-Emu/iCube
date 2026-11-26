// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import AppIntents
import PVLibrarySnapshot
import PVWidgets
import SwiftUI

/// Maps the App Group snapshot (`LibrarySnapshotStore`) into the shared PVWidgets game lists.
///
/// The grid and list drawing, the size-driven layout and the edit-screen options all live in
/// the PVWidgets package (github.com/Provenance-Emu/PVWidgets), shared with Provenance and iFly.
/// The Continue list (games with a save state) is iCube's own App Group key, `ContinuesList`.
struct ICubeWidgetDataSource: WidgetDataSource {
  private let telemetry = ExtensionTelemetry(.widget)

  var feeds: [WidgetFeed] { [Self.recentlyPlayed, Self.continues, Self.favorites, Self.recentlyAdded] }

  func items(for feed: WidgetFeed.ID, limit: Int) -> [WidgetItem] {
    telemetry.measure(.widgetEntry) {
      let (snapshot, outcome) = LibrarySnapshotStore().loadWithOutcome()
      telemetry.record(outcome)
      switch feed {
      case .recentlyPlayed:
        return snapshot.recentlyPlayed.prefix(limit).map { Self.item(for: $0, date: $0.lastPlayed) }
      case .continues:
        // No link resumes one save state, so a tap opens the game; the date is the save's.
        let entries = ContinuesList.load(from: ICubeSnapshot.appGroup.defaults)
        return ContinuesList.games(for: entries, in: snapshot).prefix(limit).map { Self.item(for: $0.game, date: $0.savedAt) }
      case .favorites:
        // A favorite may never have been played, so it shows no date.
        return snapshot.favorites.prefix(limit).map { Self.item(for: $0, date: nil) }
      case .recentlyAdded:
        return snapshot.recentlyAdded.prefix(limit).map { Self.item(for: $0, date: $0.dateAdded) }
      default:
        return []
      }
    }
  }

  static func item(for game: LibrarySnapshotGame, date: Date?) -> WidgetItem {
    let platform = game.icubePlatform
    return WidgetItem(
      id: game.id,
      title: game.title,
      badge: platform == .unknown ? nil : platform.displayName,
      artworkURL: game.coverURL,
      date: date,
      launchURL: game.launchURL
    )
  }

  // MARK: Feeds

  static let recentlyPlayed = WidgetFeed(
    id: .recentlyPlayed,
    title: String(localized: "Recently Played"),
    symbolName: "clock.arrow.circlepath",
    emptyMessage: String(localized: "Play a game\nto see it here")
  )

  static let continues = WidgetFeed(
    id: .continues,
    title: String(localized: "Continue"),
    symbolName: "play.circle.fill",
    emptyMessage: String(localized: "Make a save state\nto see the game here")
  )

  static let favorites = WidgetFeed(
    id: .favorites,
    title: String(localized: "Favorites"),
    symbolName: "star.fill",
    emptyMessage: String(localized: "Mark games as\nfavorites to see them here")
  )

  static let recentlyAdded = WidgetFeed(
    id: .recentlyAdded,
    title: String(localized: "Recently Added"),
    symbolName: "square.and.arrow.down",
    emptyMessage: String(localized: "Add a game\nto see it here")
  )
}

/// iCube's look for the shared game list widgets: the system's widget background, as before,
/// with the platform pill in the library's GameCube purple.
enum ICubeWidgetTheme {
  private static let gameCubePurple = Color(red: 0.35, green: 0.25, blue: 0.75)

  static var standard: WidgetTheme {
    var theme = WidgetTheme()
    theme.badgeFill = AnyShapeStyle(gameCubePurple)
    return theme
  }
}

/// Lets the system find the Show and Layout options PVWidgets adds to the widget's edit screen.
struct ICubeWidgetsIntents: AppIntentsPackage {
  static var includedPackages: [any AppIntentsPackage.Type] { [PVWidgetsIntentsPackage.self] }
}
