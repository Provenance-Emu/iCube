// Common/Swift/MenuKit/ICubeTVRoomBackground.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// The full-bleed room behind the tvOS pause screen and its panes, ported from iFly's `TVDreamcastBackground`:
/// the iCube room gradient, an optional faint wash of the game's art (in place of iFly's drawn swirl), a radial
/// vignette, two blurred colour blobs (the platform accent low-left, the app accent high-right) and a top gloss.
/// Every layer ignores the safe area, so nothing is left black at the screen edges. Static: nothing animates.
struct ICubeTVRoomBackground: View {
  var art: UIImage?
  @Environment(\.icubePlatformAccent) private var platformAccent

  var body: some View {
    let room = ICubeDesign.TVRoom.self
    ZStack {
      ICubeRoom(style: .gradient)

      if let art {
        // An overlay on a flexible view, so the fill-scaled image never widens the room.
        Color.clear
          .overlay { Image(uiImage: art).resizable().scaledToFill().blur(radius: room.artBlur) }
          .clipped()
          .opacity(room.artOpacity)
          .ignoresSafeArea()
      }

      RadialGradient(colors: [.clear, .black.opacity(room.vignetteOpacity)], center: .center,
                     startRadius: room.vignetteStartRadius, endRadius: room.vignetteEndRadius)
        .ignoresSafeArea()

      Circle()
        .fill((platformAccent ?? ICubeDesign.color(.accent)).opacity(room.primaryBlobOpacity))
        .frame(width: room.primaryBlobDiameter, height: room.primaryBlobDiameter)
        .blur(radius: room.blobBlur)
        .offset(room.primaryBlobOffset)
      Circle()
        .fill(ICubeDesign.color(.accent).opacity(room.secondaryBlobOpacity))
        .frame(width: room.secondaryBlobDiameter, height: room.secondaryBlobDiameter)
        .blur(radius: room.blobBlur)
        .offset(room.secondaryBlobOffset)

      LinearGradient(colors: [.white.opacity(room.glossOpacity), .clear], startPoint: .top, endPoint: .center)
        .ignoresSafeArea()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }
}
