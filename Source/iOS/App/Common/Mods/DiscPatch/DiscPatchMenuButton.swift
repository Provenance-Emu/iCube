// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// "Apply Patch…" for a library game's context menu. Shown for local GameCube and Wii discs only.
struct DiscPatchMenuButton: View {
  let item: TVGameItem

  var body: some View {
    if isPatchable {
      Button {
        let gameID = item.gameID
        // The menu is still dismissing; presenting in the same turn is dropped.
        DispatchQueue.main.async {
          DiscPatchFlow.present(patchURLs: [], suggestedGameID: gameID)
        }
      } label: {
        Label(L("Apply Patch…"), systemImage: "bandage")
      }
    }
  }

  private var isPatchable: Bool {
    guard !item.isDemoItem, item.filePath.hasPrefix("/"),
          let info = DiscImageBridge.info(forGameItem: item) else { return false }
    return DiscPatchPlanner.refusal(for: DiscPatchImage(info)) == nil
  }
}
