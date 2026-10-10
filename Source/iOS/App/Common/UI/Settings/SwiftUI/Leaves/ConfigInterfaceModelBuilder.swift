// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed.
enum ConfigInterfaceModelBuilder {
  static func make(state: ConfigInterfaceState, apply: @escaping (ConfigInterfaceChange) -> Void) -> MenuModel {
    let gameList = MenuSection(id: "game-list", header: L("Game List"), items: [
      SettingsRow.toggle("names-db", L("Use Built-In Database of Game Names"), state.useNamesDB,
                         L("Replaces raw disc IDs with proper game titles from the built-in database."),
                         set: { apply(.useNamesDB($0)) }),
      SettingsRow.toggle("covers", L("Download Game Covers from GameTDB.com for Use in Grid Mode"), state.useCovers,
                         L("Fetches box art from GameTDB.com over the network (once per game) for grid view. Turn off to stay fully offline."),
                         set: { apply(.useCovers($0)) }),
    ])

    let libraryUI = MenuSection(id: "library-ui", header: L("Library UI"), items: [
      SettingsRow.cycle("background-style", L("Background Style"), LibraryBackgroundStyle.allCases.map { ($0.label, $0) }, state.backgroundStyle,
                        L("Backdrop behind the game library. Animated adds full effects; Clean is the lightest."),
                        icon: "paintbrush.fill", set: { apply(.backgroundStyle($0)) }),
      SettingsRow.toggle("show-subtitles", L("Show Game ID Subtitles"), state.showSubtitles,
                         L("Shows each game's disc ID under its title in the library."),
                         icon: "textformat.123", set: { apply(.showSubtitles($0)) }),
    ])

    let general = MenuSection(id: "general", header: L("General"), items: [
      SettingsRow.toggle("confirm-on-stop", L("Confirm on Stop"), state.confirmOnStop,
                         L("Asks before quitting a running game so you don't lose unsaved progress."),
                         set: { apply(.confirmOnStop($0)) }),
      SettingsRow.toggle("panic-handlers", L("Use Panic Handlers"), state.usePanicHandlers,
                         L("Shows a dialog when the core hits an internal error instead of failing silently."),
                         set: { apply(.usePanicHandlers($0)) }),
      SettingsRow.toggle("osd-messages", L("Show On-Screen Display Messages"), state.osdMessages,
                         L("Transient status overlays drawn over the game (save-state notices, performance toggles)."),
                         set: { apply(.osdMessages($0)) }),
    ])

    return MenuModel(sections: [gameList, libraryUI, general])
  }
}
