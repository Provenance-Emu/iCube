// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// GameCube, on the menu engine. `sync()` reads Config into the snapshot and writes nothing; `apply(_:)` and the
/// one-time language seed are the only writers.
struct ConfigGameCubeView: View {
  @State private var state = ConfigGameCubeState()

  var body: some View {
    SettingsLeafScreen(model: ConfigGameCubeModelBuilder.make(state: state, apply: apply), title: L("GameCube"), sync: sync)
      .onAppear(perform: seedLanguage)
      .onReceive(NotificationCenter.default.publisher(for: .DOLConfigChanged)) { _ in seedLanguage() }
  }

  private static var preferredLanguage: String {
    Locale.preferredLanguages.first ?? Locale.current.identifier
  }

  private func sync() {
    var s = ConfigGameCubeState()
    s.loadMainMenu = !DOLConfigBridge.mainSkipIPL()
    s.language = ConfigGameCubeState.displayedLanguage(isSet: DOLConfigBridge.mainGCLanguageIsSet(), stored: DOLConfigBridge.mainGCLanguage(), preferredLanguage: Self.preferredLanguage)
    state = s
  }

  /// The one write outside `apply`: persist the locale-derived language once, so the game sees what the row shows.
  /// Also run on a Config change, as the old view's sync did, so a Reset re-seeds it.
  private func seedLanguage() {
    if let seed = ConfigGameCubeState.languageSeed(isSet: DOLConfigBridge.mainGCLanguageIsSet(), preferredLanguage: Self.preferredLanguage) {
      DOLConfigBridge.setMainGCLanguage(seed)
    }
  }

  private func apply(_ change: ConfigGameCubeChange) {
    switch change {
    case .loadMainMenu(let v): state.loadMainMenu = v; DOLConfigBridge.setMainSkipIPL(!v)
    case .language(let v): state.language = v; DOLConfigBridge.setMainGCLanguage(v)
    }
  }
}
