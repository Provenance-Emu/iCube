// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// What the quick menu adds to the pause menu's own items.
struct QuickMenuExtras {
  /// Dolphin's aspect setting (`AspectRatio.aspectRaw`); the Scaling tile cycles it on the running game.
  var aspect: Binding<AnyHashable> = .constant(AnyHashable(0))
  /// The full pause menu.
  var openMenu: () -> Void = {}
}

/// The quick menu's tiles (spec §7): the pause menu's own items, looked up by id so the two menus cannot
/// drift, in two rows. Play: speed, sound, quick saves, capture. Display: performance, scaling, shaders,
/// bezels (where a TV can be drawn), then the two ways on: the full menu, and out of the game.
enum QuickMenuModelBuilder {
  /// Ids taken from `PauseMenuModelBuilder.make`, in display order.
  static let playIDs = ["fast-forward", "mute", "quick-save", "quick-load", "screenshot", "record"]
  static let displayIDs = ["perf-hud", scalingID, "shaders", "bezels"]
  static let scalingID = "scaling"
  static let menuID = "menu"
  static let exitID = "exit"
  static let playSectionID = "quick-play"
  static let displaySectionID = "quick-display"
  /// Tiles per row: the longer row's count, so each section is one row.
  static let columns = 6

  static let scalingOptions: [(String, AnyHashable)] = TopBarValues.aspectOptions.map { ($0.title, AnyHashable($0.raw)) }

  static func scalingItem(_ aspect: Binding<AnyHashable>) -> MenuItem {
    MenuItem(id: scalingID, title: L("Scaling"), icon: "aspectratio", tint: .indigo,
             role: .cycle(options: scalingOptions, selection: aspect),
             description: L("How the picture fills the screen. Tap to cycle. Long-press to pick one."))
  }

  static func make(state: PauseMenuState, bindings: PauseMenuBindings, actions: PauseMenuActions,
                   extras: QuickMenuExtras = QuickMenuExtras()) -> MenuModel {
    let pause = PauseMenuModelBuilder.make(state: state, bindings: bindings, actions: actions)
    func item(_ id: String) -> MenuItem? { id == scalingID ? scalingItem(extras.aspect) : pause.item(id: id) }
    var display = displayIDs.compactMap(item)
    display.append(MenuItem(id: menuID, title: L("Menu"), icon: "line.3.horizontal", tint: .blue,
                            role: .action(extras.openMenu), description: L("Everything else: saves, cheats, controllers, settings.")))
    if let exit = pause.item(id: exitID) { display.append(exit) }
    return MenuModel(sections: [
      MenuSection(id: playSectionID, header: L("Play"), items: playIDs.compactMap(item)),
      MenuSection(id: displaySectionID, header: L("Display"), items: display),
    ])
  }
}
