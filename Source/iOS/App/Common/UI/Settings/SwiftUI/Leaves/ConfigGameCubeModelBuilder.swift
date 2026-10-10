// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed.
enum ConfigGameCubeModelBuilder {
  /// Index order is the GameCube's: 0 English, 1 German, 2 French, 3 Spanish, 4 Italian, 5 Dutch.
  static func languageOptions(including value: Int) -> [(String, Int)] {
    var options = [(L("English"), 0), (L("German"), 1), (L("French"), 2), (L("Spanish"), 3), (L("Italian"), 4), (L("Dutch"), 5)]
    if !options.contains(where: { $0.1 == value }) { options.append((L("Error"), value)) }
    return options
  }

  static func make(state: ConfigGameCubeState, apply: @escaping (ConfigGameCubeChange) -> Void) -> MenuModel {
    let general = MenuSection(id: "general", header: L("General"), items: [
      SettingsRow.toggle("load-main-menu", L("Load GameCube Main Menu"), state.loadMainMenu,
                         L("Boots through the console's startup menu (IPL/BIOS animation) instead of straight into the game. Needs a matching-region GameCube IPL dump; without one, games boot directly anyway. Turn off to start games faster."),
                         set: { apply(.loadMainMenu($0)) }),
    ])
    // The old screen's section header was the row's own label, so it is the row's title here.
    let language = MenuSection(id: "system-language", items: [
      SettingsRow.cycle("language", L("System Language"), languageOptions(including: state.language), state.language,
                        L("Language the emulated GameCube reports to games. The GameCube supports English, German, French, Spanish, Italian, and Dutch only. Defaults to your device language where supported, otherwise English."),
                        set: { apply(.language($0)) }),
    ])
    return MenuModel(sections: [general, language])
  }
}
