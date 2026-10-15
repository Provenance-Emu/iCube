// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

extension View {
  /// Hosts the mod browser sheet. `libraryGames` is the library the browser lists first.
  func modBrowserSheet(libraryGames: [TVGameItem]) -> some View {
    modifier(ModBrowserSheetModifier(libraryGames: libraryGames))
  }
}

private struct ModBrowserSheetModifier: ViewModifier {
  @ObservedObject private var presenter = ModBrowserPresenter.shared
  let libraryGames: [TVGameItem]

  func body(content: Content) -> some View {
    content.sheet(item: $presenter.request) { request in
      ModBrowserRoot(
        request: request,
        libraryGames: libraryGames.filter { !$0.isDemoItem }.map(ModLibraryGame.init(item:)),
        // The one place the browser is built: swap in the real installers here.
        handler: PendingModInstallHandler()
      )
      .claimsController()
    }
  }
}
