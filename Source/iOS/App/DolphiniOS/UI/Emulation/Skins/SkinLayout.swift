// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import UIKit

struct SkinLayout {
  let skinRect: CGRect
  let gameRect: CGRect?
  let items: [(item: SkinItem, drawFrame: CGRect, hitFrame: CGRect)]

  static func make(_ rep: SkinRepresentation, canvas: CGSize) -> SkinLayout {
    // Guard against zero mapping size
    guard rep.mappingSize.width > 0, rep.mappingSize.height > 0 else {
      return SkinLayout(skinRect: .zero, gameRect: nil, items: [])
    }

    // Calculate scale: fit the mapping to the canvas while maintaining aspect ratio
    let scale = min(canvas.width / rep.mappingSize.width, canvas.height / rep.mappingSize.height)

    // Calculate scaled skin size
    let scaledSize = CGSize(width: rep.mappingSize.width * scale, height: rep.mappingSize.height * scale)

    // Determine if portrait (canvas taller than wide)
    let isPortrait = canvas.height > canvas.width

    // Calculate skin origin
    let skinX = (canvas.width - scaledSize.width) / 2  // Always centered horizontally
    let skinY: CGFloat
    if isPortrait {
      // Bottom-anchored in portrait
      skinY = canvas.height - scaledSize.height
    } else {
      // Centered vertically in landscape
      skinY = (canvas.height - scaledSize.height) / 2
    }
    let skinOrigin = CGPoint(x: skinX, y: skinY)
    let skinRect = CGRect(origin: skinOrigin, size: scaledSize)

    // Map items
    var mappedItems: [(item: SkinItem, drawFrame: CGRect, hitFrame: CGRect)] = []
    for item in rep.items {
      let scaledFrame = item.frame.applying(CGAffineTransform(scaleX: scale, y: scale))
      let drawFrame = CGRect(
        x: skinOrigin.x + scaledFrame.origin.x,
        y: skinOrigin.y + scaledFrame.origin.y,
        width: scaledFrame.width,
        height: scaledFrame.height
      )

      // Calculate hit frame: outset by scaled extended edges
      let scaledEdges = UIEdgeInsets(
        top: item.extendedEdges.top * scale,
        left: item.extendedEdges.left * scale,
        bottom: item.extendedEdges.bottom * scale,
        right: item.extendedEdges.right * scale
      )
      let hitFrame = CGRect(
        x: drawFrame.origin.x - scaledEdges.left,
        y: drawFrame.origin.y - scaledEdges.top,
        width: drawFrame.width + scaledEdges.left + scaledEdges.right,
        height: drawFrame.height + scaledEdges.top + scaledEdges.bottom
      )

      mappedItems.append((item: item, drawFrame: drawFrame, hitFrame: hitFrame))
    }

    // Map game rect from first screen's outputFrame
    let gameRect: CGRect?
    if let firstScreen = rep.screens.first {
      let scaledOutputFrame = firstScreen.outputFrame.applying(CGAffineTransform(scaleX: scale, y: scale))
      gameRect = CGRect(
        x: skinOrigin.x + scaledOutputFrame.origin.x,
        y: skinOrigin.y + scaledOutputFrame.origin.y,
        width: scaledOutputFrame.width,
        height: scaledOutputFrame.height
      )
    } else {
      gameRect = nil
    }

    return SkinLayout(skinRect: skinRect, gameRect: gameRect, items: mappedItems)
  }
}
#endif
