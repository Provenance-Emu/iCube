// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The "Patches & Mods" section of a game's context menu, the same on iOS and tvOS.
///
/// Flat buttons, no nested `Menu`: a `Menu` inside the tvOS context menu has no usable presentation.
struct PatchesAndModsMenu: View {
  let item: TVGameItem
  /// The installed patched copies and saved mods for this game, as library entries. Empty for a modded tile.
  let variants: [TVGameItem]
  let play: (TVGameItem) -> Void
  let showMods: (TVGameItem) -> Void
  let manage: (TVGameItem) -> Void

  var body: some View {
    if isOffered {
      Section(L("Patches & Mods")) {
        ForEach(variants, id: \.filePath) { variant in
          if let info = ModdedLibrary.tileInfo(path: variant.filePath, title: variant.title) {
            Button { play(variant) } label: {
              Label(String(format: L("Play %@"), info.displayName), systemImage: info.systemImage)
            }
          }
        }
        if RiivolutionEligibility.isEligible(filePath: item.filePath, platform: Int(item.platform)) {
          Button { showMods(item) } label: {
            Label(L("Play with Mods…"), systemImage: "puzzlepiece.extension")
          }
        }
        DiscPatchMenuButton(item: item)
        FindModsButton(item: item)
        if isManageable {
          Button { manage(item) } label: {
            Label(L("Manage…"), systemImage: "slider.horizontal.3")
          }
        }
      }
    }
  }

  /// A header with nothing under it is worse than no section.
  private var isOffered: Bool {
    !variants.isEmpty
      || RiivolutionEligibility.isEligible(filePath: item.filePath, platform: Int(item.platform))
      || DiscPatchMenuButton.isOffered(for: item)
      || FindModsButton.isOffered(for: item)
  }

  /// Manage lists what is made from a game, so it belongs to the game and not to a patched copy.
  private var isManageable: Bool {
    !ModdedBoot.isModdedPath(item.filePath)
      && RiivolutionEligibility.isEligible(filePath: item.filePath, platform: Int(item.platform))
  }
}
