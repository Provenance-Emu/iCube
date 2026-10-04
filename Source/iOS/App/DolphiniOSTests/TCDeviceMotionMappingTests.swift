// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit
import simd
import XCTest

@testable import iCube

/// Unit tests for the pure IMU mapping helpers on `TCDeviceMotion`. These do not touch
/// CoreMotion or `TCManagerInterface` at all: they exercise the orientation math and the
/// Touchscreen.mm axis-pair write convention in isolation.
final class TCDeviceMotionMappingTests: XCTestCase {
  private let g = TCDeviceMotion.gravityToMetersPerSecondSquared

  // MARK: - Required case: 6DOF at rest in portrait

  func testAccelAtRestInPortraitPutsGravityOnExactlyOneWiimoteZSide() {
    // Device flat, screen up, at rest: gravity + userAcceleration ~= (0, 0, +1g) in the
    // device's own frame (userAcceleration ~= 0 at rest). CMDeviceMotion.h documents
    // "the total acceleration of the device is equal to gravity plus userAcceleration",
    // i.e. gravity uses the SAME sign convention as CMAccelerometerData.acceleration
    // (proper/specific acceleration, opposing gravity) -- not an inverted
    // points-toward-earth vector. This matches WiimoteEmu.cpp's own at-rest fallback
    // of `Common::Vec3(0, 0, +GRAVITY_ACCELERATION)` for the accelerometer (WiimoteEmu.cpp
    // ~line 950), which is what handle6DOFMotionMapping now feeds into
    // mapAccelToWiimoteFrame.
    let mapped = TCDeviceMotion.mapAccelToWiimoteFrame(x: 0, y: 0, z: g, orientation: .portrait)
    let writes = TCDeviceMotion.wiimoteAccelWrites(x: mapped.x, y: mapped.y, z: mapped.z)

    XCTAssertEqual(writes[.wiiAccelUp] ?? 0, Float(g), accuracy: 0.001)
    XCTAssertEqual(writes[.wiiAccelDown], 0)

    // Also check the core-side combination directly: IMUAccelerometer::GetState()
    // computes z = Up.GetState() - Down.GetState(), and Axis::GetState() multiplies by
    // m_neg (WIIMOTE_ACCEL_UP has m_neg = +1, WIIMOTE_ACCEL_DOWN has m_neg = -1).
    let upState = (writes[.wiiAccelUp] ?? 0) * 1.0
    let downState = (writes[.wiiAccelDown] ?? 0) * -1.0
    XCTAssertEqual(upState - downState, Float(g), accuracy: 0.001)
  }

  // MARK: - Required case: pure X rotation yields only a pitch write

  func testPureXRotationInPortraitYieldsOnlyPitchWrite() {
    let gyro = TCDeviceMotion.mapGyroToWiimoteFrame(x: 1.0, y: 0, z: 0, orientation: .portrait)
    let writes = TCDeviceMotion.wiimoteGyroWrites(pitch: gyro.pitch, roll: gyro.roll, yaw: gyro.yaw)

    XCTAssertEqual(writes[.wiiGyroPitchDown] ?? 0, -1.0, accuracy: 0.0001)
    XCTAssertEqual(writes[.wiiGyroPitchUp], 0)
    XCTAssertEqual(writes[.wiiGyroRollLeft], 0)
    XCTAssertEqual(writes[.wiiGyroRollRight], 0)
    XCTAssertEqual(writes[.wiiGyroYawLeft], 0)
    XCTAssertEqual(writes[.wiiGyroYawRight], 0)
  }

  // MARK: - The core combination convention itself

  func testImuAccelWritesReproduceExactlyTheSignedInputAfterCoreCombination() {
    // For arbitrary x/y/z, writing through imuAccelWrites and then applying the same
    // m_neg signs Touchscreen.mm uses (Left/Backward/Up = +1, Right/Forward/Down = -1)
    // must reconstruct x, y, z exactly, with no doubling and no cancellation.
    let writes = TCDeviceMotion.wiimoteAccelWrites(x: 3.5, y: -2.25, z: 9.80665)

    let x = (writes[.wiiAccelLeft] ?? 0) * 1.0 - (writes[.wiiAccelRight] ?? 0) * -1.0
    let y = (writes[.wiiAccelBackward] ?? 0) * 1.0 - (writes[.wiiAccelForward] ?? 0) * -1.0
    let z = (writes[.wiiAccelUp] ?? 0) * 1.0 - (writes[.wiiAccelDown] ?? 0) * -1.0

    XCTAssertEqual(x, 3.5, accuracy: 0.0001)
    XCTAssertEqual(y, -2.25, accuracy: 0.0001)
    XCTAssertEqual(z, 9.80665, accuracy: 0.0001)
  }

  func testImuGyroWritesReproduceExactlyTheSignedInputAfterCoreCombination() {
    let writes = TCDeviceMotion.wiimoteGyroWrites(pitch: 1.1, roll: -0.4, yaw: 2.2)

    let pitch = (writes[.wiiGyroPitchDown] ?? 0) * 1.0 - (writes[.wiiGyroPitchUp] ?? 0) * -1.0
    let roll = (writes[.wiiGyroRollLeft] ?? 0) * 1.0 - (writes[.wiiGyroRollRight] ?? 0) * -1.0
    let yaw = (writes[.wiiGyroYawLeft] ?? 0) * 1.0 - (writes[.wiiGyroYawRight] ?? 0) * -1.0

    XCTAssertEqual(pitch, 1.1, accuracy: 0.0001)
    XCTAssertEqual(roll, -0.4, accuracy: 0.0001)
    XCTAssertEqual(yaw, 2.2, accuracy: 0.0001)
  }

  func testNunchukAccelWritesUseNunchukButtonTypes() {
    let writes = TCDeviceMotion.nunchukAccelWrites(x: 1, y: 2, z: 3)
    XCTAssertEqual(writes[.nunchukAccelLeft], 1)
    XCTAssertEqual(writes[.nunchukAccelBackward], 2)
    XCTAssertEqual(writes[.nunchukAccelUp], 3)
    XCTAssertEqual(writes[.nunchukAccelRight], 0)
    XCTAssertEqual(writes[.nunchukAccelForward], 0)
    XCTAssertEqual(writes[.nunchukAccelDown], 0)
  }

  // MARK: - Orientation table: accelerometer matches the legacy handler exactly

  func testAccelOrientationMappingMatchesLegacyHandlerSwitch() {
    let v = (x: 1.0, y: 2.0, z: 3.0)

    XCTAssertEqual(
      TCDeviceMotion.mapAccelToWiimoteFrame(x: v.x, y: v.y, z: v.z, orientation: .portrait).x, -v.x
    )
    XCTAssertEqual(
      TCDeviceMotion.mapAccelToWiimoteFrame(x: v.x, y: v.y, z: v.z, orientation: .portrait).y, -v.y
    )
    XCTAssertEqual(
      TCDeviceMotion.mapAccelToWiimoteFrame(x: v.x, y: v.y, z: v.z, orientation: .landscapeRight).x, v.y
    )
    XCTAssertEqual(
      TCDeviceMotion.mapAccelToWiimoteFrame(x: v.x, y: v.y, z: v.z, orientation: .landscapeRight).y, -v.x
    )
    XCTAssertEqual(
      TCDeviceMotion.mapAccelToWiimoteFrame(x: v.x, y: v.y, z: v.z, orientation: .portraitUpsideDown).x, v.x
    )
    XCTAssertEqual(
      TCDeviceMotion.mapAccelToWiimoteFrame(x: v.x, y: v.y, z: v.z, orientation: .portraitUpsideDown).y, v.y
    )
    XCTAssertEqual(
      TCDeviceMotion.mapAccelToWiimoteFrame(x: v.x, y: v.y, z: v.z, orientation: .landscapeLeft).x, -v.y
    )
    XCTAssertEqual(
      TCDeviceMotion.mapAccelToWiimoteFrame(x: v.x, y: v.y, z: v.z, orientation: .landscapeLeft).y, v.x
    )

    // Z always passes straight through, for every orientation.
    for orientation: UIInterfaceOrientation in [.portrait, .landscapeRight, .portraitUpsideDown, .landscapeLeft] {
      XCTAssertEqual(
        TCDeviceMotion.mapAccelToWiimoteFrame(x: v.x, y: v.y, z: v.z, orientation: orientation).z, v.z
      )
    }
  }

  // MARK: - Orientation table: gyro pitch/yaw match the legacy handler exactly

  func testGyroPitchYawMatchesLegacyHandlerSwitch() {
    let v = (x: 1.0, y: 2.0, z: 3.0)

    let portrait = TCDeviceMotion.mapGyroToWiimoteFrame(x: v.x, y: v.y, z: v.z, orientation: .portrait)
    XCTAssertEqual(portrait.pitch, -v.x)
    XCTAssertEqual(portrait.yaw, v.z)

    let upsideDown = TCDeviceMotion.mapGyroToWiimoteFrame(x: v.x, y: v.y, z: v.z, orientation: .portraitUpsideDown)
    XCTAssertEqual(upsideDown.pitch, v.x)
    XCTAssertEqual(upsideDown.yaw, -v.z)

    let landscapeLeft = TCDeviceMotion.mapGyroToWiimoteFrame(x: v.x, y: v.y, z: v.z, orientation: .landscapeLeft)
    XCTAssertEqual(landscapeLeft.pitch, -v.y)
    XCTAssertEqual(landscapeLeft.yaw, v.z)

    let landscapeRight = TCDeviceMotion.mapGyroToWiimoteFrame(x: v.x, y: v.y, z: v.z, orientation: .landscapeRight)
    XCTAssertEqual(landscapeRight.pitch, v.y)
    XCTAssertEqual(landscapeRight.yaw, -v.z)
  }

  // MARK: - Derived roll table (NOT verified on-device; see doc comment on
  // mapGyroToWiimoteFrame). This locks in the current derivation so a future change
  // to it is deliberate, not accidental.

  func testGyroRollDerivedTable() {
    let v = (x: 1.0, y: 2.0, z: 3.0)

    XCTAssertEqual(TCDeviceMotion.mapGyroToWiimoteFrame(x: v.x, y: v.y, z: v.z, orientation: .portrait).roll, v.y)
    XCTAssertEqual(
      TCDeviceMotion.mapGyroToWiimoteFrame(x: v.x, y: v.y, z: v.z, orientation: .portraitUpsideDown).roll, -v.y
    )
    XCTAssertEqual(
      TCDeviceMotion.mapGyroToWiimoteFrame(x: v.x, y: v.y, z: v.z, orientation: .landscapeLeft).roll, -v.x
    )
    XCTAssertEqual(
      TCDeviceMotion.mapGyroToWiimoteFrame(x: v.x, y: v.y, z: v.z, orientation: .landscapeRight).roll, v.x
    )
  }

  // MARK: - Gyro-mode IR cursor: single-sided writes, four directions + clamp
  //
  // ControllerEmu::Cursor::GetReshapableState() (Cursor.cpp:67-68) combines
  // y = Up.GetState() - Down.GetState(), x = Right.GetState() - Left.GetState().
  // Axis::GetState() multiplies by m_neg (Touchscreen.mm ~line 74-77):
  // WIIMOTE_IR_RIGHT/DOWN default to +1, WIIMOTE_IR_UP/LEFT are explicitly -1 --
  // the reverse of the accelerometer's Up/Left-positive convention above. These
  // tests reconstruct the core's combine directly from the write dictionary so a
  // future change to the sign derivation is caught here, not on a device.

  private func coreCursorState(_ writes: [TCButtonType: Float]) -> (x: Float, y: Float) {
    let up = (writes[.wiiInfraredUp] ?? 0) * -1.0
    let down = (writes[.wiiInfraredDown] ?? 0) * 1.0
    let left = (writes[.wiiInfraredLeft] ?? 0) * -1.0
    let right = (writes[.wiiInfraredRight] ?? 0) * 1.0
    return (x: right - left, y: up - down)
  }

  func testIRCursorTiltUpMovesPointerUp() {
    let writes = TCDeviceMotion.irCursorWrites(horizontal: 0, vertical: 1.0)
    XCTAssertEqual(writes[.wiiInfraredUp] ?? 0, -1.0, accuracy: 0.0001)
    XCTAssertEqual(writes[.wiiInfraredDown], 0)
    let state = coreCursorState(writes)
    XCTAssertEqual(state.y, 1.0, accuracy: 0.0001, "positive vertical must yield a positive (up) cursor state")
    XCTAssertEqual(state.x, 0, accuracy: 0.0001)
  }

  func testIRCursorTiltDownMovesPointerDown() {
    let writes = TCDeviceMotion.irCursorWrites(horizontal: 0, vertical: -1.0)
    XCTAssertEqual(writes[.wiiInfraredUp] ?? 0, 1.0, accuracy: 0.0001)
    XCTAssertEqual(writes[.wiiInfraredDown], 0)
    let state = coreCursorState(writes)
    XCTAssertEqual(state.y, -1.0, accuracy: 0.0001, "negative vertical must yield a negative (down) cursor state")
  }

  func testIRCursorRollRightMovesPointerRight() {
    let writes = TCDeviceMotion.irCursorWrites(horizontal: 1.0, vertical: 0)
    XCTAssertEqual(writes[.wiiInfraredRight] ?? 0, 1.0, accuracy: 0.0001)
    XCTAssertEqual(writes[.wiiInfraredLeft], 0)
    let state = coreCursorState(writes)
    XCTAssertEqual(state.x, 1.0, accuracy: 0.0001, "positive horizontal must yield a positive (right) cursor state")
    XCTAssertEqual(state.y, 0, accuracy: 0.0001)
  }

  func testIRCursorRollLeftMovesPointerLeft() {
    let writes = TCDeviceMotion.irCursorWrites(horizontal: -1.0, vertical: 0)
    XCTAssertEqual(writes[.wiiInfraredRight] ?? 0, -1.0, accuracy: 0.0001)
    XCTAssertEqual(writes[.wiiInfraredLeft], 0)
    let state = coreCursorState(writes)
    XCTAssertEqual(state.x, -1.0, accuracy: 0.0001, "negative horizontal must yield a negative (left) cursor state")
  }

  func testIRCursorWritesClampBeyondUnitRange() {
    let writesHigh = TCDeviceMotion.irCursorWrites(horizontal: 5.0, vertical: 5.0)
    XCTAssertEqual(writesHigh[.wiiInfraredRight] ?? 0, 1.0, accuracy: 0.0001)
    XCTAssertEqual(writesHigh[.wiiInfraredUp] ?? 0, -1.0, accuracy: 0.0001)
    let stateHigh = coreCursorState(writesHigh)
    XCTAssertEqual(stateHigh.x, 1.0, accuracy: 0.0001)
    XCTAssertEqual(stateHigh.y, 1.0, accuracy: 0.0001)

    let writesLow = TCDeviceMotion.irCursorWrites(horizontal: -5.0, vertical: -5.0)
    XCTAssertEqual(writesLow[.wiiInfraredRight] ?? 0, -1.0, accuracy: 0.0001)
    XCTAssertEqual(writesLow[.wiiInfraredUp] ?? 0, 1.0, accuracy: 0.0001)
    let stateLow = coreCursorState(writesLow)
    XCTAssertEqual(stateLow.x, -1.0, accuracy: 0.0001)
    XCTAssertEqual(stateLow.y, -1.0, accuracy: 0.0001)
  }

  // MARK: - Gyro pointer: rotation since the baseline, in screen axes

  // Reference frame: X = the player's right, Y = away from the player, Z = up (CoreMotion's
  // Z-vertical frames). A baseline maps device axes to that frame; its columns are where the
  // device's X, Y and Z axes point. Every baseline here is the phone held UPRIGHT, screen facing
  // the player, which is where the old Euler-angle mapping broke (pitch near 90 degrees in
  // portrait; device axes turned a quarter turn in landscape).
  private static let towardPlayer = SIMD3<Double>(0, -1, 0)
  private static let worldRight = SIMD3<Double>(1, 0, 0)
  private static let worldUp = SIMD3<Double>(0, 0, 1)

  private static func attitude(x: SIMD3<Double>, y: SIMD3<Double>, z: SIMD3<Double>) -> simd_quatd {
    simd_quatd(simd_double3x3(columns: (x, y, z)))
  }

  /// Portrait: the device's right edge points right, its top edge up, its screen at the player.
  private static let uprightPortrait = attitude(x: worldRight, y: worldUp, z: towardPlayer)
  /// Landscape-left (home side on the left): the device's top edge points right, its right edge down.
  private static let uprightLandscapeLeft = attitude(x: -worldUp, y: worldRight, z: towardPlayer)
  /// Landscape-right (home side on the right): the device's top edge points left, its right edge up.
  private static let uprightLandscapeRight = attitude(x: worldUp, y: -worldRight, z: towardPlayer)

  private static let uprightCases: [(UIInterfaceOrientation, simd_quatd)] = [
    (.portrait, uprightPortrait), (.landscapeLeft, uprightLandscapeLeft), (.landscapeRight, uprightLandscapeRight),
  ]

  /// `baseline` turned by `angle` about a reference-frame `axis`, as the player moves the phone.
  private func moved(_ baseline: simd_quatd, by angle: Double, about axis: SIMD3<Double>) -> simd_quatd {
    simd_quatd(angle: angle, axis: axis) * baseline
  }

  private let swing = 0.2

  func testGyroPointerIsCenteredAtTheBaseline() {
    for (orientation, baseline) in Self.uprightCases {
      let offsets = TCDeviceMotion.gyroPointerOffsets(
        current: baseline, baseline: baseline, orientation: orientation, useYawForHorizontal: false)
      XCTAssertEqual(offsets.horizontal, 0, accuracy: 0.0001, "\(orientation.rawValue)")
      XCTAssertEqual(offsets.vertical, 0, accuracy: 0.0001, "\(orientation.rawValue)")
    }
  }

  /// "Yaw (Turn Left/Right)": turning the phone to the right about the vertical moves the pointer
  /// right and nothing else, in every orientation.
  func testTurningRightMovesThePointerRightInEveryOrientation() {
    for (orientation, baseline) in Self.uprightCases {
      let current = moved(baseline, by: -swing, about: Self.worldUp)
      let offsets = TCDeviceMotion.gyroPointerOffsets(
        current: current, baseline: baseline, orientation: orientation, useYawForHorizontal: true)
      XCTAssertEqual(offsets.horizontal, swing * TCDeviceMotion.gyroPointerHorizontalSensitivity, accuracy: 0.0001,
                     "\(orientation.rawValue)")
      XCTAssertEqual(offsets.vertical, 0, accuracy: 0.0001, "\(orientation.rawValue)")
    }
  }

  /// Tipping the phone's back upward (top edge toward the player) moves the pointer up and nothing
  /// else, in every orientation.
  func testTippingTheBackUpMovesThePointerUpInEveryOrientation() {
    for (orientation, baseline) in Self.uprightCases {
      let current = moved(baseline, by: swing, about: Self.worldRight)
      let offsets = TCDeviceMotion.gyroPointerOffsets(
        current: current, baseline: baseline, orientation: orientation, useYawForHorizontal: false)
      XCTAssertEqual(offsets.vertical, swing * TCDeviceMotion.gyroPointerVerticalSensitivity, accuracy: 0.0001,
                     "\(orientation.rawValue)")
      XCTAssertEqual(offsets.horizontal, 0, accuracy: 0.0001, "\(orientation.rawValue)")
    }
  }

  /// "Roll (Tilt Left/Right)": tilting the phone clockwise like a steering wheel moves the pointer
  /// right, in every orientation.
  func testSteeringClockwiseMovesThePointerRightInEveryOrientation() {
    for (orientation, baseline) in Self.uprightCases {
      // Clockwise as the player sees it is a positive turn about the axis pointing away from them.
      let current = moved(baseline, by: swing, about: -Self.towardPlayer)
      let offsets = TCDeviceMotion.gyroPointerOffsets(
        current: current, baseline: baseline, orientation: orientation, useYawForHorizontal: false)
      XCTAssertEqual(offsets.horizontal, swing * TCDeviceMotion.gyroPointerHorizontalSensitivity, accuracy: 0.0001,
                     "\(orientation.rawValue)")
      XCTAssertEqual(offsets.vertical, 0, accuracy: 0.0001, "\(orientation.rawValue)")
    }
  }

  /// Every edge is reachable: about 23 degrees of turn or 32 degrees of tip is past a full swing.
  func testAModestSwingReachesTheScreenEdges() {
    for (orientation, baseline) in Self.uprightCases {
      let turned = TCDeviceMotion.gyroPointerOffsets(
        current: moved(baseline, by: 0.4, about: Self.worldUp), baseline: baseline,
        orientation: orientation, useYawForHorizontal: true)
      XCTAssertLessThanOrEqual(turned.horizontal, -1, "\(orientation.rawValue)")
      let tipped = TCDeviceMotion.gyroPointerOffsets(
        current: moved(baseline, by: -0.55, about: Self.worldRight), baseline: baseline,
        orientation: orientation, useYawForHorizontal: true)
      XCTAssertLessThanOrEqual(tipped.vertical, -1, "\(orientation.rawValue)")
    }
  }

  /// The pointer is relative: how the phone was held when it was centered does not matter.
  func testGyroPointerIgnoresHowTheDeviceIsHeld() {
    let lyingFlat = Self.attitude(x: Self.worldRight, y: -Self.towardPlayer, z: Self.worldUp)
    let current = moved(lyingFlat, by: -swing, about: Self.worldUp)
    let offsets = TCDeviceMotion.gyroPointerOffsets(
      current: current, baseline: lyingFlat, orientation: .portrait, useYawForHorizontal: false)
    // Flat on its back, a turn about the vertical is a turn about the screen's own axis: steering.
    XCTAssertEqual(offsets.horizontal, swing * TCDeviceMotion.gyroPointerHorizontalSensitivity, accuracy: 0.0001)
    XCTAssertEqual(offsets.vertical, 0, accuracy: 0.0001)
  }

  /// A quaternion and its negation are the same attitude; the pointer must not flip between them.
  func testNegatedQuaternionIsTheSameAttitude() {
    let current = moved(Self.uprightPortrait, by: -swing, about: Self.worldUp)
    let plain = TCDeviceMotion.gyroPointerOffsets(
      current: current, baseline: Self.uprightPortrait, orientation: .portrait, useYawForHorizontal: true)
    let negated = TCDeviceMotion.gyroPointerOffsets(
      current: simd_quatd(vector: -current.vector), baseline: Self.uprightPortrait,
      orientation: .portrait, useYawForHorizontal: true)
    XCTAssertEqual(negated.horizontal, plain.horizontal, accuracy: 0.0001)
    XCTAssertEqual(negated.vertical, plain.vertical, accuracy: 0.0001)
  }

  /// Gyro pointer sensitivity (decision 4) scales both axes on top of the fixed constants; 1 is
  /// today's behaviour.
  func testGyroPointerSensitivityScalesBothAxes() {
    let current = moved(moved(Self.uprightPortrait, by: -0.1, about: Self.worldUp), by: 0.1, about: Self.worldRight)
    let unscaled = TCDeviceMotion.gyroPointerOffsets(
      current: current, baseline: Self.uprightPortrait, orientation: .portrait, useYawForHorizontal: true)
    let scaled = TCDeviceMotion.gyroPointerOffsets(
      current: current, baseline: Self.uprightPortrait, orientation: .portrait, useYawForHorizontal: true, gain: 1.5)
    XCTAssertEqual(scaled.horizontal, 1.5 * unscaled.horizontal, accuracy: 0.0001)
    XCTAssertEqual(scaled.vertical, 1.5 * unscaled.vertical, accuracy: 0.0001)
  }

  // MARK: - Gyro pointer: flat <-> upright swings and re-baselining

  /// The same hold as `upright`, laid flat on its back: the top edge tipped away from the player.
  private func flat(from upright: simd_quatd) -> simd_quatd {
    moved(upright, by: -.pi / 2, about: Self.worldRight)
  }

  /// Centered while flat, then lifted upright: a quarter turn of tip, far past a full swing, so the
  /// pointer pins at the top edge (it does not vanish or flip) in every orientation.
  func testLiftingFromFlatToUprightPinsThePointerAtTheTop() {
    for (orientation, upright) in Self.uprightCases {
      let offsets = TCDeviceMotion.gyroPointerOffsets(
        current: upright, baseline: flat(from: upright), orientation: orientation, useYawForHorizontal: false)
      XCTAssertEqual(offsets.vertical, .pi / 2 * TCDeviceMotion.gyroPointerVerticalSensitivity, accuracy: 0.0001,
                     "\(orientation.rawValue)")
      XCTAssertEqual(offsets.horizontal, 0, accuracy: 0.0001, "\(orientation.rawValue)")
      let state = coreCursorState(TCDeviceMotion.irCursorWrites(horizontal: offsets.horizontal, vertical: offsets.vertical))
      XCTAssertEqual(state.y, 1, accuracy: 0.0001, "\(orientation.rawValue)")
      XCTAssertEqual(state.x, 0, accuracy: 0.0001, "\(orientation.rawValue)")
    }
  }

  /// Centered upright, then laid flat: the mirror image, pinned at the bottom edge.
  func testLayingFromUprightToFlatPinsThePointerAtTheBottom() {
    for (orientation, upright) in Self.uprightCases {
      let offsets = TCDeviceMotion.gyroPointerOffsets(
        current: flat(from: upright), baseline: upright, orientation: orientation, useYawForHorizontal: false)
      XCTAssertEqual(offsets.vertical, -.pi / 2 * TCDeviceMotion.gyroPointerVerticalSensitivity, accuracy: 0.0001,
                     "\(orientation.rawValue)")
      XCTAssertEqual(offsets.horizontal, 0, accuracy: 0.0001, "\(orientation.rawValue)")
      let state = coreCursorState(TCDeviceMotion.irCursorWrites(horizontal: offsets.horizontal, vertical: offsets.vertical))
      XCTAssertEqual(state.y, -1, accuracy: 0.0001, "\(orientation.rawValue)")
    }
  }

  /// A re-baseline taken while upright makes upright the center again, and small tips around it
  /// move the pointer normally instead of staying pinned.
  func testRebaselineWhileUprightRecentresThePointer() {
    for (orientation, upright) in Self.uprightCases {
      XCTAssertTrue(TCDeviceMotion.needsPointerRebaseline(
        recenterRequested: true, baselineOrientation: orientation, orientation: orientation))
      let centered = TCDeviceMotion.gyroPointerOffsets(
        current: upright, baseline: upright, orientation: orientation, useYawForHorizontal: false)
      XCTAssertEqual(centered.vertical, 0, accuracy: 0.0001, "\(orientation.rawValue)")
      XCTAssertEqual(centered.horizontal, 0, accuracy: 0.0001, "\(orientation.rawValue)")
      let tipped = TCDeviceMotion.gyroPointerOffsets(
        current: moved(upright, by: swing, about: Self.worldRight), baseline: upright, orientation: orientation,
        useYawForHorizontal: false)
      XCTAssertEqual(tipped.vertical, swing * TCDeviceMotion.gyroPointerVerticalSensitivity, accuracy: 0.0001,
                     "\(orientation.rawValue)")
    }
  }

  /// The pointer re-centres on the first sample, on a recenter request, and whenever the interface
  /// orientation differs from the one the baseline was taken in (a quarter turn or the 180-degree
  /// landscape flip); otherwise it keeps its baseline.
  func testPointerRebaselinesWhenTheInterfaceOrientationChanges() {
    XCTAssertTrue(TCDeviceMotion.needsPointerRebaseline(
      recenterRequested: false, baselineOrientation: nil, orientation: .portrait))
    XCTAssertFalse(TCDeviceMotion.needsPointerRebaseline(
      recenterRequested: false, baselineOrientation: .portrait, orientation: .portrait))
    XCTAssertTrue(TCDeviceMotion.needsPointerRebaseline(
      recenterRequested: false, baselineOrientation: .portrait, orientation: .landscapeLeft))
    XCTAssertTrue(TCDeviceMotion.needsPointerRebaseline(
      recenterRequested: false, baselineOrientation: .landscapeLeft, orientation: .landscapeRight))
    XCTAssertTrue(TCDeviceMotion.needsPointerRebaseline(
      recenterRequested: false, baselineOrientation: .portrait, orientation: .portraitUpsideDown))
  }

  /// Why the re-baseline on rotation matters: a turn read along the old orientation's axes is a
  /// different gesture. Tipping the back up in landscape, read with portrait axes, is a turn to the
  /// left with no vertical movement at all.
  func testATipReadAlongStaleAxesMovesThePointerSideways() {
    let tipped = moved(Self.uprightLandscapeLeft, by: swing, about: Self.worldRight)
    let stale = TCDeviceMotion.gyroPointerOffsets(
      current: tipped, baseline: Self.uprightLandscapeLeft, orientation: .portrait, useYawForHorizontal: true)
    XCTAssertEqual(stale.vertical, 0, accuracy: 0.0001)
    XCTAssertEqual(stale.horizontal, -swing * TCDeviceMotion.gyroPointerHorizontalSensitivity, accuracy: 0.0001)
    let current = TCDeviceMotion.gyroPointerOffsets(
      current: tipped, baseline: Self.uprightLandscapeLeft, orientation: .landscapeLeft, useYawForHorizontal: true)
    XCTAssertEqual(current.vertical, swing * TCDeviceMotion.gyroPointerVerticalSensitivity, accuracy: 0.0001)
    XCTAssertEqual(current.horizontal, 0, accuracy: 0.0001)
  }

  // MARK: - Unknown orientation is a safe no-op

  func testUnknownOrientationFoldsIntoPortraitForAccelAndIsZeroForGyro() {
    let accel = TCDeviceMotion.mapAccelToWiimoteFrame(x: 1, y: 1, z: 1, orientation: .unknown)
    XCTAssertEqual(accel.x, -1)
    XCTAssertEqual(accel.y, -1)
    XCTAssertEqual(accel.z, 1)

    // .unknown is handled explicitly (folded into .portrait) by mapGyroToWiimoteFrame's
    // switch, matching the legacy gyro handler's `case .portrait, .unknown:`.
    let gyro = TCDeviceMotion.mapGyroToWiimoteFrame(x: 1, y: 1, z: 1, orientation: .unknown)
    XCTAssertEqual(gyro.pitch, -1)
    XCTAssertEqual(gyro.roll, 1)
    XCTAssertEqual(gyro.yaw, 1)
  }
}
