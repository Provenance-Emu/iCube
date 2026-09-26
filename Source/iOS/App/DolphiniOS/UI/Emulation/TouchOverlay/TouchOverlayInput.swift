// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import CoreGraphics
import Foundation

/// Pure input math the phase 2 views will feed into `TCManagerInterface`. Ported bit-for-bit
/// from the xib pads; §6.4 of the design explains why the stick convention below must NOT be
/// unified with the IR or IMU write conventions.
enum TouchOverlayInput {
  /// `TCJoystick`'s reach: the knob travels a third of the control's width.
  static let stickTravelFraction: CGFloat = 1 / 3

  /// Signed stick axes in [-1, 1] from a touch point, exactly as `TCJoystick.handlePan` derives
  /// them: distance clamped to `maxDistance`, then divided by it. +y is DOWN (UIKit coordinates).
  static func stickAxes(touch: CGPoint, center: CGPoint, maxDistance: CGFloat) -> (x: CGFloat, y: CGFloat) {
    guard maxDistance > 0 else { return (0, 0) }
    var xDiff = touch.x - center.x
    var yDiff = touch.y - center.y
    let distance = sqrt(pow(xDiff, 2) + pow(yDiff, 2))
    if distance > maxDistance {
      xDiff = maxDistance * (xDiff / distance)
      yDiff = maxDistance * (yDiff / distance)
    }
    return (xDiff / maxDistance, yDiff / maxDistance)
  }

  /// The four half-axis writes for a stick with `baseId` (`TCJoystick`'s
  /// `[min(y, 0), min(y, 1), min(x, 0), min(x, 1)]` sent to `baseId + 1 ... baseId + 4`).
  /// A negative value (up / left) lands on BOTH ids of its pair because `min(v, 1) == v` there;
  /// a positive value (down / right) lands only on the Down / Right id. `TCManagerInterface.mm`'s
  /// `combUD` / `combLR` compensate for this asymmetry when re-deriving a signed DSU axis, so it
  /// must stay exactly like this.
  static func stickWrites(x: CGFloat, y: CGFloat, baseId: Int) -> [(id: Int, value: Float)] {
    let axes = [min(y, 0), min(y, 1), min(x, 0), min(x, 1)]
    return axes.enumerated().map { (id: baseId + $0.offset + 1, value: Float($0.element)) }
  }

  /// The four button writes for a D-pad with `baseId`, in `TCDirectionalPad`'s
  /// Up/Down/Left/Right order (`baseId + 0 ... baseId + 3`).
  static func dpadWrites(up: Bool, down: Bool, left: Bool, right: Bool, baseId: Int) -> [(id: Int, pressed: Bool)] {
    [up, down, left, right].enumerated().map { (id: baseId + $0.offset, pressed: $0.element) }
  }

  /// Force-sensitive analog trigger pressure (task item 2, phase 3): the touch's force normalized
  /// to 0...1 when it's reported, else a flat `1.0` (binary press) fallback — the same fallback
  /// `TCButton.touchesMoved` uses on hardware without force reporting, generalized to check the
  /// SPECIFIC touch's `maximumPossibleForce` rather than gating on the device-wide
  /// `UITraitCollection.forceTouchCapability` `TCButton` reads at init: that trait reads
  /// `.unavailable` on every device shipped since 3D Touch was removed (iPhone XR/XS generation),
  /// which would dead-code the whole force path on all current hardware. `force == 0` is also
  /// treated as "not reporting a real sample yet" so the very first touch-down (before force has
  /// ramped up) doesn't send a near-zero value before the initial 1.0 press write.
  static func pressureValue(force: CGFloat, maximumPossibleForce: CGFloat) -> Float {
    guard maximumPossibleForce > 0, force > 0 else { return 1.0 }
    return Float(min(1.0, force / maximumPossibleForce))
  }

  /// The overlay's rendered opacity (task item 1's "Overlay Opacity" setting): REUSES
  /// `DOLConfigBridge.mainTouchPadOpacity()`/`setMainTouchPadOpacity` — the same key and Settings
  /// row (`ControllersRootView`'s "Alternate Input Sources > Opacity" slider, already unconditional
  /// on both the legacy xib pads and this overlay) rather than adding a second, overlay-specific
  /// opacity control. Full opacity while any edit mode is active, so the editor's own chrome
  /// (highlight border, resize handles) is always clearly visible regardless of how transparent
  /// the user has set gameplay opacity; otherwise the configured value, floored at 0.2 so the
  /// overlay can never be dragged to fully invisible (matching the legacy pads' own
  /// `max(0.2, ...)` floor in `EmulationScreen+TouchAndMotion.swift`).
  static func resolvedOpacity(isEditing: Bool, configuredOpacity: Float) -> Double {
    isEditing ? 1.0 : max(0.2, Double(configuredOpacity))
  }
}
#endif
