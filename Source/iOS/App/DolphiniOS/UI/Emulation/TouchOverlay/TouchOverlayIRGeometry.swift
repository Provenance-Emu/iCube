// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import CoreGraphics
import Foundation

/// Pure IR pointer math for the phase 3 Wii IR drag/follow surface (design §6.5/§6.6, task item
/// 1), ported bit-for-bit from `TCWiiPad.recalculatePointerValues` / `normalizedFromPoint` /
/// `handleLongPress`'s drag branch / `viewIsInsideControl`. No UIKit — deliberately stateless
/// (`TouchOverlayIRSurfaceView` reads `TVEmulationBridge` live at gesture time and calls these
/// functions with the result, rather than caching a converted rect, which is exactly the
/// "read geometry before it settled" bug class documented for the thin libretro wrapper).
enum TouchOverlayIRGeometry {
  /// `TCWiiPad.recalculatePointerValues`'s letterbox correction: `rect` (the video content rect,
  /// already converted into the caller's local coordinate space, or the full surface bounds when
  /// the bridge hasn't reported one yet) is narrowed to the sub-rect that actually matches
  /// `aspectRatio`, centered within `rect`. Falls back to `rect` unchanged when `aspectRatio` is
  /// non-finite/non-positive or `rect` is empty (mirrors the bridge-not-ready case).
  static func letterboxedGameRect(in rect: CGRect, aspectRatio: CGFloat) -> CGRect {
    guard aspectRatio.isFinite, aspectRatio > 0, rect.width > 0, rect.height > 0 else { return rect }
    var gameWidth = rect.width
    var gameHeight = rect.height
    let surfaceAR = gameWidth / gameHeight
    if aspectRatio <= surfaceAR {
      // Black bars on left/right.
      gameWidth = gameHeight * aspectRatio
    } else {
      // Black bars on top/bottom.
      gameHeight = gameWidth / aspectRatio
    }
    let gx = rect.midX - gameWidth * 0.5
    let gy = rect.midY - gameHeight * 0.5
    return CGRect(x: gx, y: gy, width: gameWidth, height: gameHeight)
  }

  static func clamp(_ v: CGFloat) -> CGFloat { max(-1.0, min(1.0, v)) }

  /// `TCWiiPad.normalizedFromPoint`: map an absolute point (in the same coordinate space as
  /// `gameRect`) to normalized IR space, clamped to [-1, 1] on both axes.
  static func follow(point: CGPoint, in gameRect: CGRect) -> (x: CGFloat, y: CGFloat) {
    let halfW = max(1.0, gameRect.width * 0.5)
    let halfH = max(1.0, gameRect.height * 0.5)
    return (clamp((point.x - gameRect.midX) / halfW), clamp((point.y - gameRect.midY) / halfH))
  }

  /// `TCWiiPad.handleLongPress`'s drag branch: delta from `start` to `current`, scaled by the
  /// game rect's half-extent, accumulated onto the position persisted from the previous drag
  /// (`oldX`/`oldY`), clamped to [-1, 1].
  static func drag(start: CGPoint, current: CGPoint, oldX: CGFloat, oldY: CGFloat,
                   in gameRect: CGRect) -> (x: CGFloat, y: CGFloat) {
    let halfW = max(1.0, gameRect.width * 0.5)
    let halfH = max(1.0, gameRect.height * 0.5)
    let dx = (current.x - start.x) / halfW
    let dy = (current.y - start.y) / halfH
    return (clamp(oldX + dx), clamp(oldY + dy))
  }

  /// `TCWiiPad.viewIsInsideControl`'s exclusion rule, re-expressed as a pure region check instead
  /// of an ancestor-view walk: a touch that starts inside any OTHER group's frame must never begin
  /// an IR gesture. In the live overlay this is already true for free (the IR surface paints
  /// BELOW every other group, so a touch on a button/D-pad/stick is delivered to that control's
  /// own surface first and never reaches the IR surface at all) — this predicate is the
  /// belt-and-braces guard `TouchOverlayIRSurfaceView` also checks on touch-down, and the
  /// unit-testable form of the rule.
  static func touchStartAllowed(at point: CGPoint, excluding otherGroupFrames: [CGRect]) -> Bool {
    !otherGroupFrames.contains { $0.contains(point) }
  }
}
#endif
