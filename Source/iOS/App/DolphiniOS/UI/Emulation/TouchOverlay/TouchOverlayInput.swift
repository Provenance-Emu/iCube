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
  /// "Up" writes a negative value to the Up id and 0 to Down; "down" writes positive to Down
  /// and 0 to Up. `TCManagerInterface.mm`'s `combUD` / `combLR` compensate for this asymmetry
  /// when re-deriving a signed DSU axis, so it must stay exactly like this.
  static func stickWrites(x: CGFloat, y: CGFloat, baseId: Int) -> [(id: Int, value: Float)] {
    let axes = [min(y, 0), min(y, 1), min(x, 0), min(x, 1)]
    return axes.enumerated().map { (id: baseId + $0.offset + 1, value: Float($0.element)) }
  }

  /// The four button writes for a D-pad with `baseId`, in `TCDirectionalPad`'s
  /// Up/Down/Left/Right order (`baseId + 0 ... baseId + 3`).
  static func dpadWrites(up: Bool, down: Bool, left: Bool, right: Bool, baseId: Int) -> [(id: Int, pressed: Bool)] {
    [up, down, left, right].enumerated().map { (id: baseId + $0.offset, pressed: $0.element) }
  }
}
#endif
