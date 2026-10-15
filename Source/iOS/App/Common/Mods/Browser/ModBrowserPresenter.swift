// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// A game in the user's library, as far as the mod browser cares.
struct ModLibraryGame: Hashable, Identifiable {
  let gameID: String
  let title: String
  let revision: Int

  var id: String { gameID }

  init(gameID: String, title: String, revision: Int) {
    self.gameID = gameID
    self.title = title
    self.revision = revision
  }

  init(item: TVGameItem) {
    self.init(gameID: item.gameID, title: item.title, revision: item.revision)
  }
}

/// A request to open the browser: for one library game, or for the whole catalogue.
struct ModBrowserRequest: Identifiable {
  let id = UUID()
  let game: ModLibraryGame?
}

/// Every "Find Mods Online" entry point goes through this one object, so the library view hosts a
/// single sheet whichever menu the user came from.
@MainActor
final class ModBrowserPresenter: ObservableObject {
  static let shared = ModBrowserPresenter()

  @Published var request: ModBrowserRequest?
  /// A message for the user, shown as an alert on the browser.
  @Published var notice: String?

  func open(game: ModLibraryGame? = nil) {
    guard ModBrowser.isEnabled else { return }
    request = ModBrowserRequest(game: game)
  }
}

/// The context-menu item that opens the browser filtered to a game. Shown only for games the
/// bundled table knows, so it never offers a browser with nothing in it.
struct FindModsButton: View {
  let item: TVGameItem

  var body: some View {
    if ModBrowser.isEnabled, !item.isDemoItem, ModGameTable.bundled.entry(forGameID: item.gameID) != nil {
      Button {
        ModBrowserPresenter.shared.open(game: ModLibraryGame(item: item))
      } label: {
        Label(L("Find Mods Online"), systemImage: "puzzlepiece.extension")
      }
    }
  }
}
