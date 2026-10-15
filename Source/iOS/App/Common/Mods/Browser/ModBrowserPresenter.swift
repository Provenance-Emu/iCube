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

  /// userInfo key of `.DOLShowModsForGame`.
  static let gameIDKey = "gameID"

  /// The game whose "Play with Mods" sheet opens once the browser is gone.
  private var modsGameIDAfterDismiss: String?

  func open(game: ModLibraryGame? = nil) {
    guard ModBrowser.isEnabled else { return }
    request = ModBrowserRequest(game: game)
  }

  /// Closes the browser, then asks the library to open "Play with Mods" for `game`. The library cannot
  /// present a sheet while the browser still covers it, so the request waits for `browserDidDismiss()`.
  func closeAndShowMods(for game: ModLibraryGame) {
    modsGameIDAfterDismiss = game.gameID
    request = nil
  }

  /// Called by the browser sheet when it has gone.
  func browserDidDismiss() {
    guard let gameID = modsGameIDAfterDismiss else { return }
    modsGameIDAfterDismiss = nil
    NotificationCenter.default.post(name: .DOLShowModsForGame, object: nil, userInfo: [Self.gameIDKey: gameID])
  }
}

/// The context-menu item that opens the browser filtered to a game. Shown only for games the
/// bundled table knows, so it never offers a browser with nothing in it.
struct FindModsButton: View {
  let item: TVGameItem

  var body: some View {
    if Self.isOffered(for: item) {
      Button {
        ModBrowserPresenter.shared.open(game: ModLibraryGame(item: item))
      } label: {
        Label(L("Find Mods Online"), systemImage: "puzzlepiece.extension")
      }
    }
  }

  static func isOffered(for item: TVGameItem) -> Bool {
    !item.isDemoItem && ModBrowser.offersMods(forGameID: item.gameID)
  }
}
