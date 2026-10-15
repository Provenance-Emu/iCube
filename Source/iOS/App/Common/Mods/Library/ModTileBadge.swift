// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The mod mark on a library tile, drawn like the region flag and the cloud icon: a material capsule over the
/// cover's lower corner. A modded tile gets a "Patched" or "Mod" caption in the lower left; a base game with
/// patched copies or saved mods gets their count in the lower right. Nothing is drawn for a plain game.
///
/// It takes no hits and no focus, so it cannot disturb the tvOS focus and tilt of the card it sits on.
struct ModTileBadge: View {
  let info: ModdedTileInfo?
  let count: Int

  #if os(tvOS)
  private static let fontSize: CGFloat = 20
  #else
  private static let fontSize: CGFloat = 13
  #endif
  private static let padding: CGFloat = 8

  var body: some View {
    if let info {
      badge(Label(info.caption, systemImage: info.systemImage), alignment: .bottomLeading)
    } else if count > 0 {
      badge(Label("\(count)", systemImage: "puzzlepiece.extension"), alignment: .bottomTrailing)
        .accessibilityLabel(String(format: L("%d patched or modded versions"), count))
    }
  }

  private func badge(_ label: Label<Text, Image>, alignment: Alignment) -> some View {
    label
      .labelStyle(.titleAndIcon)
      .font(.system(size: Self.fontSize, weight: .semibold))
      .padding(.horizontal, Self.padding)
      .padding(.vertical, Self.padding / 2)
      .background(.ultraThinMaterial, in: Capsule())
      .padding(Self.padding)
      .frame(width: LibraryLayout.cardSize.width, height: LibraryLayout.cardSize.height, alignment: alignment)
      .allowsHitTesting(false)
  }
}
