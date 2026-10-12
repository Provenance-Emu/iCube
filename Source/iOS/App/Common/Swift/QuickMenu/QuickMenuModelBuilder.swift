// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The quick menu's tiles (spec §7): the pause menu's own items, looked up by id so the two menus cannot
/// drift, plus a tile that opens the full pause menu.
enum QuickMenuModelBuilder {
  /// Ids taken from `PauseMenuModelBuilder.make`, in display order.
  static let sharedIDs = ["fast-forward", "mute", "quick-save", "quick-load", "screenshot", "record", "perf-hud"]
  static let pauseMenuID = "pause-menu"

  static func make(state: PauseMenuState, bindings: PauseMenuBindings, actions: PauseMenuActions,
                   onOpenPauseMenu: @escaping () -> Void = {}) -> MenuModel {
    let pause = PauseMenuModelBuilder.make(state: state, bindings: bindings, actions: actions)
    var items = sharedIDs.compactMap { pause.item(id: $0) }
    items.append(MenuItem(id: pauseMenuID, title: L("Pause Menu"), icon: "pause.circle", tint: .blue,
                          role: .action(onOpenPauseMenu), description: L("Open the full pause menu.")))
    return MenuModel(sections: [MenuSection(id: "quick-menu", items: items)])
  }
}
