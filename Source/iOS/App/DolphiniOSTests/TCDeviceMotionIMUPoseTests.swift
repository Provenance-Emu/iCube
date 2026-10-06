// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import simd
import UIKit
import XCTest

@testable import iCube

/// What the emulated Wii Remote's accelerometer and gyroscope read for PHYSICAL phone poses.
///
/// Expectations come from the physical pose and the core's Wii Remote frame, not from the
/// mapping code: +x = the remote's LEFT, +y its BACK (toward the player), +z its TOP, with the
/// accelerometer reading proper acceleration (a level remote at rest reads (0, 0, +1 g)) and the
/// gyroscope right-handed rates about those axes (see the frame notes in TCDeviceMotion.swift).
/// The neutral grip is the phone held like a remote aimed at the TV with its screen facing the
/// player: the remote's front is out of the phone's back, its top the screen's up edge.
///
/// Poses are built in CoreMotion's Z-vertical reference frame (X = the player's right, Y = away
/// from the player toward the TV, Z = up), and the raw sensor readings are derived from them the
/// way CoreMotion reports them (the gravity vector at rest, in g).
final class TCDeviceMotionIMUPoseTests: XCTestCase {
  private let g = TCDeviceMotion.gravityToMetersPerSecondSquared
  private let accuracy = 1e-6

  private static let worldRight = SIMD3<Double>(1, 0, 0)
  private static let worldAway = SIMD3<Double>(0, 1, 0)
  private static let worldUp = SIMD3<Double>(0, 0, 1)
  private static let towardPlayer = -worldAway

  private static let orientations: [UIInterfaceOrientation] = [
    .portrait, .landscapeLeft, .landscapeRight, .portraitUpsideDown,
  ]

  private static func attitude(x: SIMD3<Double>, y: SIMD3<Double>, z: SIMD3<Double>) -> simd_quatd {
    simd_quatd(simd_double3x3(columns: (x, y, z)))
  }

  /// Device attitude for the phone held upright, screen at the player, in `orientation`. The columns
  /// are where the device's own X (portrait right edge), Y (portrait top edge) and Z (out of the
  /// screen) point.
  private static func upright(_ orientation: UIInterfaceOrientation) -> simd_quatd {
    switch orientation {
    case .landscapeLeft:
      // Home side on the left: the device's top edge points right, its right edge down.
      return attitude(x: -worldUp, y: worldRight, z: towardPlayer)
    case .landscapeRight:
      return attitude(x: worldUp, y: -worldRight, z: towardPlayer)
    case .portraitUpsideDown:
      return attitude(x: -worldRight, y: -worldUp, z: towardPlayer)
    default:
      return attitude(x: worldRight, y: worldUp, z: towardPlayer)
    }
  }

  /// `pose` turned by `degrees` about a world `axis` (right-handed).
  private static func turned(_ pose: simd_quatd, _ degrees: Double, about axis: SIMD3<Double>) -> simd_quatd {
    simd_quatd(angle: degrees * .pi / 180, axis: axis) * pose
  }

  /// Reclined: the top edge tipped away from the player by `degrees`, so the screen faces up more
  /// and the phone's back (the remote's front) points down. 90 = face up, -90 = face down.
  private static func reclined(_ orientation: UIInterfaceOrientation, _ degrees: Double) -> simd_quatd {
    turned(upright(orientation), -degrees, about: worldRight)
  }

  /// CoreMotion's raw accelerometer at rest for `pose`: the gravity vector in the device frame, g.
  private static func rawAtRest(_ pose: simd_quatd) -> SIMD3<Double> {
    pose.inverse.act(SIMD3(0, 0, -1))
  }

  private func assertVector(
    _ actual: SIMD3<Double>, _ expected: SIMD3<Double>, _ message: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, "x: \(message)", file: file, line: line)
    XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, "y: \(message)", file: file, line: line)
    XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, "z: \(message)", file: file, line: line)
  }

  /// Phone-tracking reading for a pose at rest, with an optional baseline taken at `baselinePose`.
  private func phoneReading(
    _ pose: simd_quatd, _ orientation: UIInterfaceOrientation, baseline baselinePose: simd_quatd? = nil
  ) -> SIMD3<Double> {
    let mount = baselinePose.map {
      TCDeviceMotion.imuMount(gravity: Self.rawAtRest($0), orientation: orientation)
    }
    return TCDeviceMotion.imuAcceleration(
      source: .phone, acceleration: Self.rawAtRest(pose), gravity: Self.rawAtRest(pose), mount: mount,
      orientation: orientation)
  }

  private func level() -> SIMD3<Double> { SIMD3(0, 0, g) }

  // MARK: - The pose builder agrees with the measured sensor

  /// On the iPhone used for the 2026-10-05 harness run, face down read raw z = +1 g and upright
  /// portrait raw y = -1 g. Every expectation below depends on these poses, so pin them first.
  func testPoseBuilderReproducesTheMeasuredRawReadings() {
    assertVector(Self.rawAtRest(Self.upright(.portrait)), SIMD3(0, -1, 0), "upright portrait")
    assertVector(Self.rawAtRest(Self.reclined(.portrait, -90)), SIMD3(0, 0, 1), "face down")
    assertVector(Self.rawAtRest(Self.reclined(.portrait, 90)), SIMD3(0, 0, -1), "face up")
    // Landscape-left: the device's right edge points down, so gravity lies along device +X.
    assertVector(Self.rawAtRest(Self.upright(.landscapeLeft)), SIMD3(1, 0, 0), "upright landscape-left")
  }

  // MARK: - Policy

  /// Full 6DOF and Wii Remote motion are ON by default, so they must not bring tilt back.
  func testTouchModesNeverTrackThePhoneWithTheRemote() {
    for irMode in [1, 2] {
      for full6DOF in [false, true] {
        let policy = TCDeviceMotion.imuPolicy(irMode: irMode, full6DOF: full6DOF, nunchukIMU: false)
        XCTAssertEqual(policy.wiimote, .level, "irMode \(irMode) 6DOF \(full6DOF)")
      }
    }
  }

  func testGyroModeTracksTheRemoteButNotTheNunchuk() {
    let policy = TCDeviceMotion.imuPolicy(irMode: 0, full6DOF: false, nunchukIMU: false)
    XCTAssertEqual(policy, .init(wiimote: .phone, nunchuk: .level))
  }

  func testNunchukTracksThePhoneOnlyWith6DOFAndNunchukMotion() {
    for irMode in [0, 1, 2] {
      XCTAssertEqual(TCDeviceMotion.imuPolicy(irMode: irMode, full6DOF: true, nunchukIMU: true).nunchuk, .phone)
      XCTAssertEqual(TCDeviceMotion.imuPolicy(irMode: irMode, full6DOF: false, nunchukIMU: true).nunchuk, .level)
      XCTAssertEqual(TCDeviceMotion.imuPolicy(irMode: irMode, full6DOF: true, nunchukIMU: false).nunchuk, .level)
    }
  }

  func testShippedMotionDefaultsKeepTouchModesLevel() {
    let store = UserDefaults(suiteName: "TCDeviceMotionIMUPoseTests")!
    store.removePersistentDomain(forName: "TCDeviceMotionIMUPoseTests")
    MotionSettings.registerDefaults(in: store)
    let policy = TCDeviceMotion.imuPolicy(
      irMode: 2, full6DOF: MotionSettings.full6DOF(in: store), nunchukIMU: MotionSettings.nunchukIMU(in: store))
    XCTAssertEqual(policy, .init(wiimote: .level, nunchuk: .level))
  }

  /// A sideways remote has no pointer to hide, and its tilt is the steering (Mario Kart Wii) or
  /// tilt control (New Super Mario Bros. Wii): it follows the phone in the touch modes too.
  func testSidewaysRemoteFollowsThePhoneInTouchModes() {
    for irMode in [0, 1, 2] {
      for full6DOF in [false, true] {
        let policy = TCDeviceMotion.imuPolicy(irMode: irMode, full6DOF: full6DOF, nunchukIMU: false, sideways: true)
        XCTAssertEqual(policy.wiimote, .phone, "irMode \(irMode) 6DOF \(full6DOF)")
      }
    }
  }

  func testUprightRemoteStaysLevelInTouchModesWithWiiRemoteMotionOn() {
    for irMode in [1, 2] {
      let policy = TCDeviceMotion.imuPolicy(irMode: irMode, full6DOF: true, nunchukIMU: false, wiimoteIMU: true, sideways: false)
      XCTAssertEqual(policy.wiimote, .level, "irMode \(irMode)")
    }
  }

  /// "Wiimote Motion Controls" off: the remote rests level in every mode, sideways or not.
  func testWiiRemoteMotionOffRestsTheRemoteLevelInEveryMode() {
    for irMode in [0, 1, 2] {
      for sideways in [false, true] {
        let policy = TCDeviceMotion.imuPolicy(
          irMode: irMode, full6DOF: true, nunchukIMU: false, wiimoteIMU: false, sideways: sideways)
        XCTAssertEqual(policy.wiimote, .level, "irMode \(irMode) sideways \(sideways)")
      }
    }
  }

  /// The DSU server streams the phone's own motion whatever the pointer mode and settings, through
  /// the static grip (DSU never had a baseline).
  func testDSUFollowsThePhoneRegardlessOfThePointerMode() {
    for irMode in [0, 1, 2] {
      for wiimoteIMU in [false, true] {
        for sideways in [false, true] {
          let policy = TCDeviceMotion.imuPolicy(
            irMode: irMode, full6DOF: true, nunchukIMU: false, wiimoteIMU: wiimoteIMU, sideways: sideways, dsu: true)
          XCTAssertEqual(policy.wiimote, .phoneUnmounted, "irMode \(irMode) imu \(wiimoteIMU) sideways \(sideways)")
        }
      }
    }
  }

  func testDSUReadingIsTheStaticGripAndIgnoresAMount() {
    let faceUp = Self.rawAtRest(Self.reclined(.portrait, 90))
    let mount = TCDeviceMotion.imuMount(gravity: faceUp, orientation: .portrait)
    let reading = TCDeviceMotion.imuAcceleration(
      source: .phoneUnmounted, acceleration: faceUp, gravity: faceUp, mount: mount, orientation: .portrait)
    // Face up is the remote aimed at the floor: its back (+y) up.
    assertVector(reading, SIMD3(0, g, 0), "face up, static grip")
  }

  /// The policy the motion queue uses reads the snapshotted routing state.
  func testCurrentPolicyReadsTheDSUAndSidewaysSnapshots() {
    let motion = TCDeviceMotion()
    motion.setDSUStreaming(true)
    XCTAssertEqual(motion.currentIMUPolicy(irMode: 2).wiimote, .phoneUnmounted)
    motion.setDSUStreaming(false)
    motion.boundRemoteSideways = true
    XCTAssertEqual(
      motion.currentIMUPolicy(irMode: 2).wiimote, MotionSettings.wiimoteIMU() ? .phone : .level)
    motion.boundRemoteSideways = false
    XCTAssertEqual(motion.currentIMUPolicy(irMode: 2).wiimote, .level)
  }

  /// Sideways in drag mode, phone held upright in landscape at the baseline: steering the phone
  /// (turning it about the axis out of the screen) tilts the remote by the same angle, where an
  /// upright remote in the same mode stays level.
  func testSidewaysDragModeSteeringTiltsTheRemote() {
    let steer = 30.0
    for orientation in [UIInterfaceOrientation.landscapeLeft, .landscapeRight] {
      let baseline = Self.upright(orientation)
      let steered = Self.turned(baseline, steer, about: Self.towardPlayer)
      let raw = Self.rawAtRest(steered)
      let mount = TCDeviceMotion.imuMount(gravity: Self.rawAtRest(baseline), orientation: orientation)

      let sideways = TCDeviceMotion.imuPolicy(irMode: 2, full6DOF: true, nunchukIMU: false, sideways: true)
      let tilted = TCDeviceMotion.imuAcceleration(
        source: sideways.wiimote, acceleration: raw, gravity: raw, mount: mount, orientation: orientation)
      XCTAssertEqual(abs(tilted.x), g * sin(steer * .pi / 180), accuracy: accuracy, "\(orientation.rawValue)")
      XCTAssertEqual(tilted.y, 0, accuracy: accuracy, "\(orientation.rawValue)")
      XCTAssertEqual(tilted.z, g * cos(steer * .pi / 180), accuracy: accuracy, "\(orientation.rawValue)")

      let upright = TCDeviceMotion.imuPolicy(irMode: 2, full6DOF: true, nunchukIMU: false, sideways: false)
      let level = TCDeviceMotion.imuAcceleration(
        source: upright.wiimote, acceleration: raw, gravity: raw, mount: mount, orientation: orientation)
      assertVector(level, self.level(), "upright remote, \(orientation.rawValue)")
    }
  }

  // MARK: - Touch modes: always a level remote

  func testTouchModesReadLevelForEveryPoseAndOrientation() {
    for orientation in Self.orientations {
      for recline in [0.0, 30, 60, 90, -90, 180] {
        let raw = Self.rawAtRest(Self.reclined(orientation, recline))
        // At rest the accelerometer reads exactly CoreMotion's gravity estimate.
        let reading = TCDeviceMotion.imuAcceleration(
          source: .level, acceleration: raw, gravity: raw, mount: nil, orientation: orientation)
        assertVector(reading, level(), "\(orientation.rawValue) recline \(recline)")
      }
    }
  }

  func testTouchModesRestLevelBeforeTheFirstGravityEstimate() {
    let raw = Self.rawAtRest(Self.reclined(.portrait, 90))
    let reading = TCDeviceMotion.imuAcceleration(
      source: .level, acceleration: raw, gravity: nil, mount: nil, orientation: .portrait)
    assertVector(reading, level(), "no gravity yet")
  }

  /// The player's own swing still reaches the game. CoreMotion reports the negated proper
  /// acceleration, so a swing to the player's right (world +X, `a` g) adds -a (device frame) to
  /// the raw reading, and a real remote swung right reads `a` toward its right: x = -a * g.
  func testTouchModesPassTheSwingThrough() {
    let swing = 0.5
    for orientation in Self.orientations {
      for recline in [0.0, 45, 90] {
        let pose = Self.reclined(orientation, recline)
        let gravity = Self.rawAtRest(pose)
        let user = -pose.inverse.act(SIMD3(swing, 0, 0))
        let reading = TCDeviceMotion.imuAcceleration(
          source: .level, acceleration: gravity + user, gravity: gravity, mount: nil, orientation: orientation)
        // Horizontal sideways swing: purely along the remote's left/right axis whatever the
        // recline, since reclining turns the remote about that same axis.
        assertVector(reading, SIMD3(-swing * g, 0, g), "\(orientation.rawValue) recline \(recline)")
      }
    }
  }

  func testTouchModeThrustTowardTheTVReadsForward() {
    let thrust = 0.8
    for orientation in Self.orientations {
      let pose = Self.upright(orientation)
      let gravity = Self.rawAtRest(pose)
      let user = -pose.inverse.act(SIMD3(0, thrust, 0))
      let reading = TCDeviceMotion.imuAcceleration(
        source: .level, acceleration: gravity + user, gravity: gravity, mount: nil, orientation: orientation)
      // Forward is -y (the remote's back is +y).
      assertVector(reading, SIMD3(0, -thrust * g, g), "\(orientation.rawValue)")
    }
  }

  /// With the phone reclined or flat, a thrust toward the TV leaves through its top edge; it must
  /// still read as the remote moving forward, not up.
  func testTouchModeThrustTowardTheTVReadsForwardWhenReclined() {
    let thrust = 0.8
    for orientation in Self.orientations {
      for recline in [30.0, 60, 90] {
        let pose = Self.reclined(orientation, recline)
        let gravity = Self.rawAtRest(pose)
        let user = -pose.inverse.act(SIMD3(0, thrust, 0))
        let reading = TCDeviceMotion.imuAcceleration(
          source: .level, acceleration: gravity + user, gravity: gravity, mount: nil, orientation: orientation)
        assertVector(reading, SIMD3(0, -thrust * g, g), "\(orientation.rawValue) recline \(recline)")
      }
    }
  }

  /// Lifting a flat phone straight up reads as the remote's top moving up.
  func testTouchModeLiftOfAFlatPhoneReadsUp() {
    let lift = 0.5
    for orientation in Self.orientations {
      let pose = Self.reclined(orientation, 90)
      let gravity = Self.rawAtRest(pose)
      let user = -pose.inverse.act(SIMD3(0, 0, lift))
      let reading = TCDeviceMotion.imuAcceleration(
        source: .level, acceleration: gravity + user, gravity: gravity, mount: nil, orientation: orientation)
      assertVector(reading, SIMD3(0, 0, g + lift * g), "\(orientation.rawValue)")
    }
  }

  // MARK: - Gyro mode, static neutral grip (no baseline)

  func testUprightGripIsALevelRemoteInEveryOrientation() {
    for orientation in Self.orientations {
      assertVector(phoneReading(Self.upright(orientation), orientation), level(), "\(orientation.rawValue)")
    }
  }

  /// Reclining tips the remote's front (the phone's back) toward the floor: the reaction to
  /// gravity gains a component along the remote's back axis.
  func testRecliningPitchesTheRemoteDown() {
    for orientation in Self.orientations {
      for recline in [30.0, 60] {
        let radians = recline * .pi / 180
        assertVector(
          phoneReading(Self.reclined(orientation, recline), orientation),
          SIMD3(0, g * sin(radians), g * cos(radians)), "\(orientation.rawValue) recline \(recline)")
      }
    }
  }

  func testFaceUpPointsTheRemoteAtTheFloorAndFaceDownAtTheCeiling() {
    for orientation in Self.orientations {
      assertVector(phoneReading(Self.reclined(orientation, 90), orientation), SIMD3(0, g, 0), "face up \(orientation.rawValue)")
      assertVector(phoneReading(Self.reclined(orientation, -90), orientation), SIMD3(0, -g, 0), "face down \(orientation.rawValue)")
    }
  }

  /// Turning the phone clockwise as the player sees it drops the screen's right edge: a remote
  /// rolled right, whose left axis now leans up.
  func testRollingRightRaisesTheRemotesLeftAxis() {
    let roll = 25.0
    for orientation in Self.orientations {
      let pose = Self.turned(Self.upright(orientation), roll, about: Self.worldAway)
      let radians = roll * .pi / 180
      assertVector(phoneReading(pose, orientation), SIMD3(g * sin(radians), 0, g * cos(radians)), "\(orientation.rawValue)")
    }
  }

  func testUnknownOrientationFoldsIntoPortrait() {
    let pose = Self.reclined(.portrait, 30)
    assertVector(phoneReading(pose, .unknown), phoneReading(pose, .portrait), "unknown")
  }

  // MARK: - Gyro mode, baseline-relative

  func testEveryGripReadsLevelAtItsOwnBaseline() {
    for orientation in Self.orientations {
      for recline in [0.0, 30, 60, 90, -90] {
        let pose = Self.reclined(orientation, recline)
        assertVector(phoneReading(pose, orientation, baseline: pose), level(), "\(orientation.rawValue) recline \(recline)")
      }
    }
  }

  func testAnUpsideDownBaselineStillReadsLevel() {
    for orientation in Self.orientations {
      let pose = Self.reclined(orientation, 180)
      assertVector(phoneReading(pose, orientation, baseline: pose), level(), "\(orientation.rawValue)")
    }
  }

  /// Recentered while reclined 30 degrees, a further 30 degrees reads like 30 degrees from upright.
  func testTiltIsMeasuredFromTheBaseline() {
    let radians = 30.0 * .pi / 180
    for orientation in Self.orientations {
      let reading = phoneReading(
        Self.reclined(orientation, 60), orientation, baseline: Self.reclined(orientation, 30))
      assertVector(reading, SIMD3(0, g * sin(radians), g * cos(radians)), "\(orientation.rawValue)")
    }
  }

  func testTurningAboutTheVerticalAfterABaselineChangesNothing() {
    for orientation in Self.orientations {
      let baseline = Self.reclined(orientation, 40)
      let turned = Self.turned(baseline, 70, about: Self.worldUp)
      assertVector(phoneReading(turned, orientation, baseline: baseline), level(), "\(orientation.rawValue)")
    }
  }

  // MARK: - Gyroscope

  private func rates(
    _ worldRate: SIMD3<Double>, pose: simd_quatd, orientation: UIInterfaceOrientation, baseline: simd_quatd? = nil
  ) -> SIMD3<Double> {
    let mount = baseline.map { TCDeviceMotion.imuMount(gravity: Self.rawAtRest($0), orientation: orientation) }
    return TCDeviceMotion.imuAngularVelocity(pose.inverse.act(worldRate), mount: mount, orientation: orientation)
  }

  /// Turning left (counterclockwise seen from above) is a positive yaw about the remote's top.
  func testTurningLeftIsPositiveYaw() {
    for orientation in Self.orientations {
      assertVector(rates(SIMD3(0, 0, 1.5), pose: Self.upright(orientation), orientation: orientation),
                   SIMD3(0, 0, 1.5), "\(orientation.rawValue)")
    }
  }

  /// Aiming up turns the front (world +Y) toward +Z: a positive turn about world +X, which is the
  /// remote's RIGHT, so a negative rate about its left axis.
  func testAimingUpIsNegativePitch() {
    for orientation in Self.orientations {
      assertVector(rates(SIMD3(0.8, 0, 0), pose: Self.upright(orientation), orientation: orientation),
                   SIMD3(-0.8, 0, 0), "\(orientation.rawValue)")
    }
  }

  /// Rolling right (right side down) is a positive turn about world +Y, the remote's FRONT, so a
  /// negative rate about its back axis.
  func testRollingRightIsNegativeRoll() {
    for orientation in Self.orientations {
      assertVector(rates(SIMD3(0, 2, 0), pose: Self.upright(orientation), orientation: orientation),
                   SIMD3(0, -2, 0), "\(orientation.rawValue)")
    }
  }

  /// With a reclined baseline the remote is level, so turning about the true vertical is pure yaw,
  /// matching the accelerometer's mount.
  func testBaselineMountTurnsTheGyroLikeTheAccelerometer() {
    for orientation in Self.orientations {
      let baseline = Self.reclined(orientation, 50)
      assertVector(rates(SIMD3(0, 0, 1), pose: baseline, orientation: orientation, baseline: baseline),
                   SIMD3(0, 0, 1), "\(orientation.rawValue)")
    }
  }

  // MARK: - Writes

  func testLevelReadingLandsOnUpOnly() {
    let writes = TCDeviceMotion.wiimoteAccelWrites(
      x: TCDeviceMotion.levelAcceleration.x, y: TCDeviceMotion.levelAcceleration.y, z: TCDeviceMotion.levelAcceleration.z)
    XCTAssertEqual(writes[.wiiAccelUp] ?? 0, Float(g), accuracy: 0.001)
    XCTAssertEqual(writes[.wiiAccelLeft] ?? 1, 0)
    XCTAssertEqual(writes[.wiiAccelBackward] ?? 1, 0)
  }
}
