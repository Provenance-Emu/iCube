// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Opens and closes the homebrew browser. The library view hosts one sheet for it.
@MainActor
final class HomebrewBrowserPresenter: ObservableObject {
  static let shared = HomebrewBrowserPresenter()

  @Published var isPresented = false

  /// The program to start once the browser has gone.
  private var programAfterDismiss: URL?

  func open() {
    guard HomebrewBrowser.isEnabled else { return }
    isPresented = true
  }

  /// Closes the browser, then starts `program`. The game screen cannot come up while the browser
  /// still covers the library, so the launch waits for `browserDidDismiss()`.
  func closeAndPlay(_ program: URL) {
    programAfterDismiss = program
    isPresented = false
  }

  /// Called by the browser sheet when it has gone.
  func browserDidDismiss() {
    guard let program = programAfterDismiss else { return }
    programAfterDismiss = nil
    DiscPatchFlow.launch(path: program.path)
  }
}

extension View {
  /// Hosts the homebrew browser.
  func homebrewBrowserSheet() -> some View {
    modifier(HomebrewBrowserSheetModifier())
  }
}

private struct HomebrewBrowserSheetModifier: ViewModifier {
  @ObservedObject private var presenter = HomebrewBrowserPresenter.shared

  func body(content: Content) -> some View {
    #if os(tvOS)
    // Full screen: tvOS draws a `.sheet` as a small centred card.
    content.fullScreenCover(isPresented: $presenter.isPresented, onDismiss: { presenter.browserDidDismiss() }) {
      HomebrewBrowserRoot().claimsController()
    }
    #else
    content.sheet(isPresented: $presenter.isPresented, onDismiss: { presenter.browserDidDismiss() }) {
      HomebrewBrowserRoot().claimsController()
    }
    #endif
  }
}
