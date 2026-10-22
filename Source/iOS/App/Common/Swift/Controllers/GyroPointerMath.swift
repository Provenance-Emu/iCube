// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Pointer math shared by the phone-gyro pointer (`TCDeviceMotion`, iOS only: CoreMotion) and the
/// Siri Remote pointer (`RemotePointerBinding`, tvOS). Pure, and compiled on both platforms.
enum GyroPointerMath {
  /// The IR cursor's writes for a pointer position (positive `horizontal` = right, positive
  /// `vertical` = up), clamped to [-1, 1], on both halves of each pair.
  ///
  /// `ControllerEmu::Cursor::GetReshapableState()` (InputCommon/ControllerEmu/
  /// ControlGroup/Cursor.cpp:67-68) computes `y = Up - Down` and `x = Right - Left` on the
  /// clamped halves. `Touchscreen.mm` (~line 74-77) wires `WIIMOTE_IR_RIGHT` /
  /// `WIIMOTE_IR_DOWN` with `m_neg == +1` and `WIIMOTE_IR_UP` / `WIIMOTE_IR_LEFT` with
  /// `m_neg == -1`.
  ///
  /// X: `horizontal` on Right and Left gives `max(0, h) - max(0, -h) == h` (positive =
  /// right). Y: positive `vertical` means up, and Up's `m_neg == -1` makes `-vertical` on
  /// Up and Down read `max(0, v) - max(0, -v) == v`. This is the touch path's convention
  /// too (`TouchOverlayIRPadView.IRSurfaceView.sendIR` writes `[y, y, x, x]` with y positive = down).
  /// The single-sided writes this replaced lost the left and bottom halves to the clamp.
  static func irCursorWrites(horizontal: Double, vertical: Double) -> [TCButtonType: Float] {
    let clampedHorizontal = Float(max(-1.0, min(1.0, horizontal)))
    let clampedVertical = Float(max(-1.0, min(1.0, vertical)))
    return [
      .wiiInfraredRight: clampedHorizontal, .wiiInfraredLeft: clampedHorizontal,
      .wiiInfraredUp: -clampedVertical, .wiiInfraredDown: -clampedVertical,
    ]
  }
}

/// A relative gyro pointer: turning the remote moves the cursor, holding it still leaves it where it
/// is. Integrates angular rate into a cursor clamped to [-1, 1] on each axis (0 = centre), the range
/// `GyroPointerMath.irCursorWrites` takes.
///
/// Which `GCMotion.rotationRate` component is the Siri Remote's yaw and which its pitch is
/// unverified until a device test: `remoteRates` picks z for left/right and x for up/down, and the
/// user's Invert X / Invert Y settings flip either sign.
struct GyroPointerIntegrator: Equatable {
  /// -1 (left) … 1 (right).
  private(set) var horizontal: Double = 0
  /// -1 (bottom) … 1 (top).
  private(set) var vertical: Double = 0

  /// Cursor units per radian at sensitivity 1: turning the remote about 30° (0.52 rad) crosses from
  /// the centre to the edge, about what the IR camera's ±15° field of view gives a real remote held
  /// at a normal distance.
  static let unitsPerRadian = 2.0
  /// A gap between samples longer than this (the app was suspended, the remote slept) moves the
  /// cursor by no more than this much time's worth of rotation.
  static let maxStep: TimeInterval = 0.1

  /// The remote's rotation rates (rad/s, `GCMotion.rotationRate`) as (left/right, up/down) rates:
  /// turning left about z is positive, and moves the cursor left; tipping the front up about x is
  /// positive, and moves it up.
  static func remoteRates(x: Double, y: Double, z: Double) -> (horizontal: Double, vertical: Double) {
    (-z, x)
  }

  /// One sample: `horizontalRate` / `verticalRate` in rad/s (positive = right / up), `dt` seconds
  /// since the previous one.
  mutating func integrate(
    horizontalRate: Double, verticalRate: Double, dt: TimeInterval, sensitivity: Double,
    invertX: Bool, invertY: Bool
  ) {
    guard dt > 0, horizontalRate.isFinite, verticalRate.isFinite else { return }
    let step = min(dt, Self.maxStep) * Self.unitsPerRadian * (sensitivity.isFinite && sensitivity > 0 ? sensitivity : 1)
    horizontal = Self.clamp(horizontal + (invertX ? -horizontalRate : horizontalRate) * step)
    vertical = Self.clamp(vertical + (invertY ? -verticalRate : verticalRate) * step)
  }

  /// Back to the centre of the screen.
  mutating func recenter() {
    horizontal = 0
    vertical = 0
  }

  /// What to write for the current position.
  var irWrites: [TCButtonType: Float] { GyroPointerMath.irCursorWrites(horizontal: horizontal, vertical: vertical) }

  private static func clamp(_ value: Double) -> Double { max(-1, min(1, value)) }
}
