// Common/Swift/MenuKit/ICubeTVRoomBackground.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// The full-bleed room behind the pause screen and its tvOS panes, ported from iFly's `TVDreamcastBackground`:
/// the iCube room gradient, an optional faint wash of the game's art (in place of iFly's drawn swirl), a radial
/// vignette, two blurred colour blobs (the platform accent low-left, the app accent high-right) and a top gloss.
/// The room ignores the safe area, so nothing is left black at the screen edges. Static: nothing animates.
struct ICubeTVRoomBackground: View {
  var art: UIImage?
  @Environment(\.icubePlatformAccent) private var platformAccent

  var body: some View {
    GeometryReader { proxy in
      room(scale: RoomScale(size: proxy.size))
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }

  /// The room's numbers are 1080p points; a smaller screen (an iPhone, an iPad) scales them, so the blobs and the
  /// vignette sit where they do on the TV instead of off screen.
  private struct RoomScale {
    let x: CGFloat
    let y: CGFloat
    var size: CGFloat { max(x, y) }

    init(size: CGSize) {
      x = size.width / ICubeDesign.TVRoom.referenceSize.width
      y = size.height / ICubeDesign.TVRoom.referenceSize.height
    }

    func offset(_ offset: CGSize) -> CGSize { CGSize(width: offset.width * x, height: offset.height * y) }
  }

  private func room(scale: RoomScale) -> some View {
    let room = ICubeDesign.TVRoom.self
    return ZStack {
      ICubeRoom(style: .gradient)

      if let art {
        // An overlay on a flexible view, so the fill-scaled image never widens the room.
        Color.clear
          .overlay { Image(uiImage: art).resizable().scaledToFill().blur(radius: room.artBlur * scale.size) }
          .clipped()
          .opacity(room.artOpacity)
      }

      RadialGradient(colors: [.clear, .black.opacity(room.vignetteOpacity)], center: .center,
                     startRadius: room.vignetteStartRadius * scale.size, endRadius: room.vignetteEndRadius * scale.size)

      Circle()
        .fill((platformAccent ?? ICubeDesign.color(.accent)).opacity(room.primaryBlobOpacity))
        .frame(width: room.primaryBlobDiameter * scale.size, height: room.primaryBlobDiameter * scale.size)
        .blur(radius: room.blobBlur * scale.size)
        .offset(scale.offset(room.primaryBlobOffset))
      Circle()
        .fill(ICubeDesign.color(.accent).opacity(room.secondaryBlobOpacity))
        .frame(width: room.secondaryBlobDiameter * scale.size, height: room.secondaryBlobDiameter * scale.size)
        .blur(radius: room.blobBlur * scale.size)
        .offset(scale.offset(room.secondaryBlobOffset))

      LinearGradient(colors: [.white.opacity(room.glossOpacity), .clear], startPoint: .top, endPoint: .center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipped()
  }
}
