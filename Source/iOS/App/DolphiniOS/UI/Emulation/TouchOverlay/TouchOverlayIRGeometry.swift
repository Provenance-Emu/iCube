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
  /// `gameRect`) to normalized IR space, clamped to [-1, 1] on both axes. Absolute, so it
  /// deliberately does NOT take a sensitivity gain (design §7 / task item 1) -- scaling an
  /// absolute position would make part of the screen unreachable (a gain < 1) or overshoot the
  /// game rect entirely (a gain > 1) well before the finger reaches the edge of the pad.
  static func follow(point: CGPoint, in gameRect: CGRect) -> (x: CGFloat, y: CGFloat) {
    let halfW = max(1.0, gameRect.width * 0.5)
    let halfH = max(1.0, gameRect.height * 0.5)
    return (clamp((point.x - gameRect.midX) / halfW), clamp((point.y - gameRect.midY) / halfH))
  }

  /// The valid range for the drag-mode pointer-sensitivity gain (task item 1's "Pointer
  /// Sensitivity" setting, `touch_overlay_ir_pointer_gain`). Neither the legacy `TCWiiPad` drag
  /// math nor gyro mode (`TCDeviceMotion.handleIRCursorMapping`'s hardcoded 2.66/2.0) exposed a
  /// user-facing control for this before, so there's no existing convention to match here beyond
  /// "1.0 must mean unchanged".
  static let dragGainRange: ClosedRange<CGFloat> = 0.25...4.0

  /// Clamps a raw `UserDefaults` double (which reads `0` for an unregistered/never-set key) to
  /// `dragGainRange`, folding non-finite or non-positive values to the neutral `1.0` -- the same
  /// defensive shape as `TCManagerInterface.mm`'s `dsu_gyro_gain` handling
  /// (`if (gain <= 0.f) gain = 1.f;`).
  static func clampDragGain(_ raw: Double) -> CGFloat {
    guard raw.isFinite, raw > 0 else { return 1.0 }
    return min(max(CGFloat(raw), dragGainRange.lowerBound), dragGainRange.upperBound)
  }

  /// `TCWiiPad.handleLongPress`'s drag branch: delta from `start` to `current`, scaled by the
  /// game rect's half-extent AND by `gain` (task item 1 -- ported code has no gain term, so the
  /// default keeps every existing caller byte-for-bit identical), accumulated onto the position
  /// persisted from the previous drag (`oldX`/`oldY`), clamped to [-1, 1].
  ///
  /// `gain` scales ONLY this call's incremental delta, never the accumulated `oldX`/`oldY` it's
  /// added to: `oldX` already reflects every previously-applied gain from prior drags, so scaling
  /// the SUM instead of the delta would compound geometrically across successive drag gestures
  /// (a second drag would apply gain twice, a third three times, ...) instead of scaling the
  /// user's finger movement linearly, which is what "pointer sensitivity" should mean.
  static func drag(start: CGPoint, current: CGPoint, oldX: CGFloat, oldY: CGFloat,
                   in gameRect: CGRect, gain: CGFloat = 1.0) -> (x: CGFloat, y: CGFloat) {
    let halfW = max(1.0, gameRect.width * 0.5)
    let halfH = max(1.0, gameRect.height * 0.5)
    let dx = (current.x - start.x) / halfW * gain
    let dy = (current.y - start.y) / halfH * gain
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

  /// Clamp a per-axis size scale for a `.fillInset`-anchored group (today only `wiiIRPad`, task
  /// item 1's "Edit IR Area" editor) so its resolved size never exceeds `boundsExtent`.
  ///
  /// `TouchOverlayLayoutStore.scaleRange` (0.5...2.0) is calibrated for the SMALL, fixed-size
  /// button/stick groups every other group uses -- doubling a 128pt stick is harmless. The Wii IR
  /// pad's `.fillInset` base size already consumes most of the overlay
  /// (`TouchOverlayDefaults.irPadMargin` inset on every side), so the same upper bound would let
  /// the box grow to roughly 4x the screen's area. `TouchOverlayLayoutEngine.clampCenter` only
  /// RE-CENTERS a box larger than its bounds (see its own doc comment) -- it doesn't shrink it --
  /// so nothing downstream of a stored scale catches this; it has to be clamped here, at write
  /// time, instead.
  static func clampFillInsetScale(_ scale: CGFloat, baseExtent: CGFloat, boundsExtent: CGFloat) -> CGFloat {
    // Mirrors `TouchOverlayLayoutStore.scaleRange` (0.5...2.0) as the outer bound before the
    // bounds-aware `hardMax` narrows it further. Duplicated as a plain constant, not referenced
    // directly, because that store is `@MainActor`-isolated and this is pure, actor-independent
    // geometry (like the rest of this file) that the unit tests call synchronously.
    let genericRange: ClosedRange<CGFloat> = 0.5...2.0
    guard baseExtent > 0, boundsExtent > 0 else {
      return min(max(scale, genericRange.lowerBound), genericRange.upperBound)
    }
    let hardMax = boundsExtent / baseExtent
    let upper = min(genericRange.upperBound, hardMax)
    let lower = min(genericRange.lowerBound, upper)
    return min(max(scale, lower), upper)
  }
}
#endif
