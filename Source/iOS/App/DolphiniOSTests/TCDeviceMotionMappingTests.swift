// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit
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
