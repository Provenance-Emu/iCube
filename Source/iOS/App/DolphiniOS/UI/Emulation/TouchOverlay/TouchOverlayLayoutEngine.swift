// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import CoreGraphics
import Foundation

/// Pure geometry for the overlay editor, ported from iFly's `ButtonLayoutEngine`. No UIKit /
/// SwiftUI, no shared state. Each control GROUP is one axis-aligned box; `resolve` is FREE
/// placement, clamped on-screen only (iFly dropped grid-snap / overlap rejection because the
/// resolver fought the user's finger; `snap` and `isValid` stay as standalone utilities).
enum TouchOverlayLayoutEngine {
  /// Padding (pt) added around every box before testing overlap in `isValid`.
  static let overlapMargin: CGFloat = 8

  static func box(center: CGPoint, size: CGSize) -> CGRect {
    CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
           width: size.width, height: size.height)
  }

  static func snap(_ point: CGPoint, grid: CGFloat) -> CGPoint {
    guard grid > 0 else { return point }
    return CGPoint(x: (point.x / grid).rounded() * grid, y: (point.y / grid).rounded() * grid)
  }

  /// Clamp a group's CENTER so its full box stays inside `bounds`. A group larger than the
  /// bounds on an axis is centred on that axis instead.
  static func clampCenter(_ center: CGPoint, size: CGSize, bounds: CGRect) -> CGPoint {
    let halfW = size.width / 2, halfH = size.height / 2
    let minX = bounds.minX + halfW, maxX = bounds.maxX - halfW
    let minY = bounds.minY + halfH, maxY = bounds.maxY - halfH
    let x = minX <= maxX ? min(max(center.x, minX), maxX) : bounds.midX
    let y = minY <= maxY ? min(max(center.y, minY), maxY) : bounds.midY
    return CGPoint(x: x, y: y)
  }

  /// True when the box stays within `bounds` and overlaps none of `others` (each inflated by
  /// `overlapMargin`). A small slop absorbs floating-point rounding.
  static func isValid(center: CGPoint, size: CGSize, others: [CGRect], bounds: CGRect) -> Bool {
    let b = box(center: center, size: size)
    guard bounds.insetBy(dx: -0.5, dy: -0.5).contains(b) else { return false }
    let inflated = b.insetBy(dx: -overlapMargin, dy: -overlapMargin)
    for o in others where inflated.intersects(o) { return false }
    return true
  }

  /// Commit a dragged group exactly where the finger released, clamped on-screen.
  static func resolve(proposed: CGPoint, size: CGSize, bounds: CGRect) -> CGPoint {
    clampCenter(proposed, size: size, bounds: bounds)
  }

  /// Normalized (0-1 of `bounds`) <-> points. The store keeps normalized centers so a layout
  /// survives device and orientation changes; the result is re-clamped by the caller.
  static func normalize(_ center: CGPoint, in bounds: CGRect) -> CGPoint {
    guard bounds.width > 0, bounds.height > 0 else { return .zero }
    return CGPoint(x: (center.x - bounds.minX) / bounds.width,
                   y: (center.y - bounds.minY) / bounds.height)
  }

  static func denormalize(_ normalized: CGPoint, in bounds: CGRect) -> CGPoint {
    CGPoint(x: bounds.minX + normalized.x * bounds.width,
            y: bounds.minY + normalized.y * bounds.height)
  }
}

/// Which edges a DEFAULT placement hangs from. The xibs pin every control to the bottom and to
/// one horizontal edge (or the horizontal centre) with Auto Layout, so anchored insets, not
/// fractions, reproduce today's look on every screen size.
enum TouchOverlayAnchor: String, Codable, Sendable {
  case bottomLeading
  case bottomTrailing
  case bottomCenter
  /// The whole overlay (the IR touch surface). `size` is ignored.
  case fill
}

/// A default placement: the group's CENTER sits `inset.x` points in from the anchored
/// horizontal edge (or offset from the centre line) and `inset.y` points up from the bottom.
struct TouchOverlayPlacement: Equatable, Sendable {
  let anchor: TouchOverlayAnchor
  let inset: CGPoint
  let size: CGSize

  init(_ anchor: TouchOverlayAnchor, inset: CGPoint = .zero, size: CGSize = .zero) {
    self.anchor = anchor
    self.inset = inset
    self.size = size
  }

  func resolvedSize(in bounds: CGRect) -> CGSize {
    anchor == .fill ? bounds.size : size
  }

  func center(in bounds: CGRect) -> CGPoint {
    switch anchor {
    case .bottomLeading:
      return CGPoint(x: bounds.minX + inset.x, y: bounds.maxY - inset.y)
    case .bottomTrailing:
      return CGPoint(x: bounds.maxX - inset.x, y: bounds.maxY - inset.y)
    case .bottomCenter:
      return CGPoint(x: bounds.midX + inset.x, y: bounds.maxY - inset.y)
    case .fill:
      return CGPoint(x: bounds.midX, y: bounds.midY)
    }
  }

  func box(in bounds: CGRect) -> CGRect {
    TouchOverlayLayoutEngine.box(center: center(in: bounds), size: resolvedSize(in: bounds))
  }
}
#endif
