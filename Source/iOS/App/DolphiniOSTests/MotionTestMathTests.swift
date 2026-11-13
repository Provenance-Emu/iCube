// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import UIKit
import XCTest
import simd

@testable import iCube

/// `WiiRemoteMotionMapping.mfi` must be the core's MFi mapping. These mirror
/// `MFiMotionAxisTests.mm` (which drives the real `MFiController`) pose for pose and number for
/// number: a mapping changed on one side and not the other fails here or there.
final class WiiRemoteMotionMappingTests: XCTestCase {
  private let g = WiiRemoteMotionMapping.standardGravity

  private func expect(
    pad: SIMD3<Double>, readsOnTheRemoteAs expected: SIMD3<Double>, pose: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let remote = WiiRemoteMotionMapping.mfi(acceleration: pad, rotationRate: nil).acceleration
    XCTAssertEqual(remote.x, expected.x, accuracy: 1e-9, "\(pose): left/right", file: file, line: line)
    XCTAssertEqual(remote.y, expected.y, accuracy: 1e-9, "\(pose): back/forward", file: file, line: line)
    XCTAssertEqual(remote.z, expected.z, accuracy: 1e-9, "\(pose): up/down", file: file, line: line)
  }

  /// `testAPadAtRestReadsAsAWiiRemoteInTheSamePose`: GCMotion reads the direction gravity pulls,
  /// the remote the force holding it up.
  func testAPadAtRestReadsAsAWiiRemoteInTheSamePose() {
    expect(pad: SIMD3(0, 0, -1), readsOnTheRemoteAs: SIMD3(0, 0, g), pose: "flat, face up")
    expect(pad: SIMD3(0, 0, 1), readsOnTheRemoteAs: SIMD3(0, 0, -g), pose: "flat, face down")
    expect(pad: SIMD3(0, -1, 0), readsOnTheRemoteAs: SIMD3(0, -g, 0), pose: "pointing at the ceiling")
    expect(pad: SIMD3(0, 1, 0), readsOnTheRemoteAs: SIMD3(0, g, 0), pose: "pointing at the floor")
    expect(pad: SIMD3(1, 0, 0), readsOnTheRemoteAs: SIMD3(g, 0, 0), pose: "right side down")
    expect(pad: SIMD3(-1, 0, 0), readsOnTheRemoteAs: SIMD3(-g, 0, 0), pose: "left side down")
  }

  /// The same six, through to the line a tester reads.
  func testTheSixRestPosesAreNamed() {
    let poses: [(SIMD3<Double>, WiiRemotePose)] = [
      (SIMD3(0, 0, -1), .flatFaceUp), (SIMD3(0, 0, 1), .flatFaceDown),
      (SIMD3(0, -1, 0), .pointingAtCeiling), (SIMD3(0, 1, 0), .pointingAtFloor),
      (SIMD3(1, 0, 0), .rightSideDown), (SIMD3(-1, 0, 0), .leftSideDown),
    ]
    for (pad, expected) in poses {
      let remote = WiiRemoteMotionMapping.mfi(acceleration: pad, rotationRate: nil)
      XCTAssertEqual(WiiRemoteAttitude(acceleration: remote.acceleration).pose, expected, "pad \(pad)")
    }
  }

  /// `testRotationRatesKeepTheirDirections`, with its numbers.
  func testRotationRatesKeepTheirDirections() throws {
    let remote = WiiRemoteMotionMapping.mfi(acceleration: SIMD3(0, 0, -1), rotationRate: SIMD3(0.5, -0.25, 2.0))
    let rates = try XCTUnwrap(remote.angularVelocity)
    XCTAssertEqual(rates.x, -0.5, accuracy: 1e-9, "nose up is Pitch Up")
    XCTAssertEqual(rates.y, 0.25, accuracy: 1e-9, "left side down is Roll Left")
    XCTAssertEqual(rates.z, 2.0, accuracy: 1e-9, "turning left is Yaw Left")
  }

  /// GCRotationRate is right-handed about the pad's axes: +x lifts the nose, +y drops the right
  /// side, +z turns left (MFiController.mm).
  func testEachTwistIsNamedAfterItsCoreInput() {
    let twists: [(SIMD3<Double>, WiiRemoteTurn)] = [
      (SIMD3(1, 0, 0), .pitchUp), (SIMD3(-1, 0, 0), .pitchDown),
      (SIMD3(0, 1, 0), .rollRight), (SIMD3(0, -1, 0), .rollLeft),
      (SIMD3(0, 0, 1), .yawLeft), (SIMD3(0, 0, -1), .yawRight),
    ]
    for (rate, expected) in twists {
      let remote = WiiRemoteMotionMapping.mfi(acceleration: SIMD3(0, 0, -1), rotationRate: rate)
      XCTAssertEqual(remote.angularVelocity.map(WiiRemoteTurn.init(angularVelocity:)), expected, "rate \(rate)")
    }
  }

  /// The core adds no gyro inputs for a pad without `hasRotationRate`.
  func testAPadWithoutAGyroscopeReadsNoRates() {
    XCTAssertNil(WiiRemoteMotionMapping.mfi(acceleration: SIMD3(0, 0, -1), rotationRate: nil).angularVelocity)
  }
}

final class WiiRemoteAttitudeTests: XCTestCase {
  private let g = WiiRemoteMotionMapping.standardGravity

  /// `testTheGyroPointerDoesNotSettleUpsideDown`'s pad: nose 20 degrees up, still the right way up.
  func testANoseTwentyDegreesUpIsStillFlatAndPitchedTwenty() throws {
    let tilt = 20.0 * .pi / 180
    let remote = WiiRemoteMotionMapping.mfi(acceleration: SIMD3(0, -sin(tilt), -cos(tilt)), rotationRate: nil)
    let attitude = WiiRemoteAttitude(acceleration: remote.acceleration)
    XCTAssertEqual(attitude.pose, .flatFaceUp)
    XCTAssertEqual(try XCTUnwrap(attitude.pitchDegrees), 20, accuracy: 1e-6)
    XCTAssertEqual(try XCTUnwrap(attitude.rollDegrees), 0, accuracy: 1e-6)
  }

  func testRollIsPositiveWithTheRightSideDown() throws {
    let right = WiiRemoteAttitude(acceleration: SIMD3(g, 0, 0))
    XCTAssertEqual(try XCTUnwrap(right.rollDegrees), 90, accuracy: 1e-6)
    XCTAssertEqual(try XCTUnwrap(right.pitchDegrees), 0, accuracy: 1e-6)
    XCTAssertEqual(try XCTUnwrap(WiiRemoteAttitude(acceleration: SIMD3(-g, 0, 0)).rollDegrees), -90, accuracy: 1e-6)
    let faceDown = try XCTUnwrap(WiiRemoteAttitude(acceleration: SIMD3(0, 0, -g)).rollDegrees)
    XCTAssertEqual(abs(faceDown), 180, accuracy: 1e-6)
  }

  /// Straight up or down, roll is whatever the noise says: it reads 0.
  func testRollIsZeroPointingStraightUp() {
    let attitude = WiiRemoteAttitude(acceleration: SIMD3(0.01 * g, -g, -0.01 * g))
    XCTAssertEqual(attitude.pose, .pointingAtCeiling)
    XCTAssertEqual(attitude.rollDegrees, 0)
  }

  func testHalfwayBetweenTwoPosesIsTilted() throws {
    let half = 45.0 * .pi / 180
    let attitude = WiiRemoteAttitude(acceleration: SIMD3(0, -sin(half) * g, cos(half) * g))
    XCTAssertEqual(attitude.pose, .tilted)
    XCTAssertEqual(try XCTUnwrap(attitude.pitchDegrees), 45, accuracy: 1e-6)
  }

  /// The edge of the cone: just inside is the pose, just outside is tilted.
  func testThePoseConeIsTwentyFiveDegrees() {
    func nose(_ degrees: Double) -> WiiRemotePose {
      let angle = degrees * .pi / 180
      return WiiRemoteAttitude(acceleration: SIMD3(0, -sin(angle) * g, cos(angle) * g)).pose
    }
    XCTAssertEqual(nose(24), .flatFaceUp)
    XCTAssertEqual(nose(26), .tilted)
    XCTAssertEqual(nose(64), .tilted)
    XCTAssertEqual(nose(66), .pointingAtCeiling)
  }

  /// A swing or a drop is not a pose, and sensors that are off read nothing.
  func testAReadingFarFromOneGIsNotAPose() {
    XCTAssertEqual(WiiRemoteAttitude(acceleration: SIMD3(0, 0, 2 * g)), WiiRemoteAttitude(pose: .moving))
    XCTAssertEqual(WiiRemoteAttitude(acceleration: SIMD3(0, 0, 0.4 * g)), WiiRemoteAttitude(pose: .moving))
    XCTAssertEqual(WiiRemoteAttitude(acceleration: .zero), WiiRemoteAttitude(pose: .noReading))
  }
}

final class WiiRemoteTurnTests: XCTestCase {
  func testAGyroAtRestIsNotTurning() {
    XCTAssertEqual(WiiRemoteTurn(angularVelocity: SIMD3(0.05, -0.04, 0.03)), .still)
    XCTAssertEqual(WiiRemoteTurn(angularVelocity: .zero), .still)
  }

  func testTheFastestAxisNamesTheTurn() {
    XCTAssertEqual(WiiRemoteTurn(angularVelocity: SIMD3(0.4, -2, 0.6)), .rollRight)
    XCTAssertEqual(WiiRemoteTurn(angularVelocity: SIMD3(0.4, 0.2, -0.6)), .yawRight)
    XCTAssertEqual(WiiRemoteTurn(angularVelocity: SIMD3(0.4, 0.2, 0.1)), .pitchDown)
  }

  func testEveryPoseAndTurnHasItsOwnTitle() {
    XCTAssertEqual(Set(WiiRemotePose.allCases.map(\.title)).count, WiiRemotePose.allCases.count)
    XCTAssertEqual(Set(WiiRemoteTurn.allCases.map(\.title)).count, WiiRemoteTurn.allCases.count)
  }
}

final class MotionSensorActivationTests: XCTestCase {
  private final class Sensor: ManuallyActivatedMotion {
    let sensorsRequireManualActivation: Bool
    var sensorsActive: Bool

    init(manual: Bool, active: Bool) {
      sensorsRequireManualActivation = manual
      sensorsActive = active
    }
  }

  /// A DualShock 4 nobody switched on: on from the second sample, off again on leaving.
  func testASensorLeftOffIsTurnedOnAndRestored() {
    let sensor = Sensor(manual: true, active: false)
    var activation = MotionSensorActivation()
    activation.sample(sensor)
    XCTAssertFalse(sensor.sensorsActive, "one sample's grace for the app's own connect handler")
    activation.sample(sensor)
    XCTAssertTrue(sensor.sensorsActive)
    activation.restore()
    XCTAssertFalse(sensor.sensorsActive)
  }

  /// The app and the core switch a pad's sensors on at connect and expect them to stay on.
  func testASensorSomeoneElseTurnedOnStaysOn() {
    let sensor = Sensor(manual: true, active: true)
    var activation = MotionSensorActivation()
    activation.sample(sensor)
    activation.sample(sensor)
    activation.restore()
    XCTAssertTrue(sensor.sensorsActive)
  }

  /// A pad that connects while the screen is up: the connect handler gets there within the grace
  /// sample, so the pad is not ours to switch off.
  func testASensorTurnedOnDuringTheGraceSampleStaysOn() {
    let sensor = Sensor(manual: true, active: false)
    var activation = MotionSensorActivation()
    activation.sample(sensor)
    sensor.sensorsActive = true
    activation.sample(sensor)
    activation.restore()
    XCTAssertTrue(sensor.sensorsActive)
  }

  func testASensorThatNeedsNoActivationIsLeftAlone() {
    let sensor = Sensor(manual: false, active: false)
    var activation = MotionSensorActivation()
    activation.sample(sensor)
    activation.sample(sensor)
    XCTAssertFalse(sensor.sensorsActive)
  }

  func testRestoreHappensOnce() {
    let sensor = Sensor(manual: true, active: false)
    var activation = MotionSensorActivation()
    activation.sample(sensor)
    activation.sample(sensor)
    activation.restore()
    sensor.sensorsActive = true
    activation.restore()
    XCTAssertTrue(sensor.sensorsActive, "a second restore must not touch a sensor it no longer owns")
  }
}

#if os(iOS)
/// The device's own sensors go through `TCDeviceMotion`'s mapping: the touchscreen's Wii Remote
/// points out of the device's back, its top at the screen's up edge.
final class MotionTestDeviceSourceTests: XCTestCase {
  private func pose(_ acceleration: SIMD3<Double>, _ orientation: UIInterfaceOrientation) -> WiiRemotePose {
    let source = MotionTestSource.device(acceleration: acceleration, rotationRate: nil, orientation: orientation)
    return WiiRemoteAttitude(acceleration: source.remote.acceleration).pose
  }

  /// CoreMotion's device frame: x the portrait right edge, y the portrait top edge, z out of the
  /// screen; at rest it reads the direction gravity pulls.
  func testAnUprightPhoneIsALevelRemote() {
    XCTAssertEqual(pose(SIMD3(0, -1, 0), .portrait), .flatFaceUp)
    XCTAssertEqual(pose(SIMD3(0, 1, 0), .portraitUpsideDown), .flatFaceUp)
    // Home side on the left: the device's right edge points down.
    XCTAssertEqual(pose(SIMD3(1, 0, 0), .landscapeLeft), .flatFaceUp)
    XCTAssertEqual(pose(SIMD3(-1, 0, 0), .landscapeRight), .flatFaceUp)
  }

  func testAPhoneLyingOnATableIsARemotePointingAtTheFloor() {
    XCTAssertEqual(pose(SIMD3(0, 0, -1), .portrait), .pointingAtFloor)
    XCTAssertEqual(pose(SIMD3(0, 0, 1), .portrait), .pointingAtCeiling)
  }

  func testAPhoneOnItsRightEdgeIsARemoteWithItsRightSideDown() {
    XCTAssertEqual(pose(SIMD3(1, 0, 0), .portrait), .rightSideDown)
    XCTAssertEqual(pose(SIMD3(-1, 0, 0), .portrait), .leftSideDown)
  }

  /// The same functions the game's motion uses, not a second derivation.
  func testItIsTCDeviceMotionsUnmountedMapping() {
    let acceleration = SIMD3(0.2, -0.9, 0.3), rate = SIMD3(0.5, -1.5, 2.5)
    let source = MotionTestSource.device(acceleration: acceleration, rotationRate: rate, orientation: .landscapeLeft)
    XCTAssertEqual(source.remote.acceleration, TCDeviceMotion.imuAcceleration(
      source: .phoneUnmounted, acceleration: acceleration, gravity: nil, mount: nil, orientation: .landscapeLeft))
    XCTAssertEqual(source.remote.angularVelocity, TCDeviceMotion.imuAngularVelocity(rate, mount: nil, orientation: .landscapeLeft))
    XCTAssertEqual(source.kind, .device)
    XCTAssertNil(source.flags)
  }

  /// Reclining an upright phone (its top edge coming toward you) aims its back, the remote's nose,
  /// upward.
  func testRecliningAnUprightPhoneIsPitchUp() throws {
    // Right-handed about the device's x (the portrait right edge): a positive turn brings the top
    // edge out of the screen's side, so the back of the phone rises.
    let source = MotionTestSource.device(acceleration: SIMD3(0, -1, 0), rotationRate: SIMD3(1, 0, 0), orientation: .portrait)
    XCTAssertEqual(WiiRemoteTurn(angularVelocity: try XCTUnwrap(source.remote.angularVelocity)), .pitchUp)
  }
}
#endif
