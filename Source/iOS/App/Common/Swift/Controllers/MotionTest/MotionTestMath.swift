// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import simd

/// What an emulated Wii Remote's motion sensors read, in the core's own frame and signs.
struct WiiRemoteMotion: Equatable {
  /// m/s^2, as `IMUAccelerometer::GetState` combines its inputs: x = Left - Right, y = Back - Forward,
  /// z = Up - Down. Proper acceleration: a remote lying flat, buttons up, reads (0, 0, +g), the force
  /// holding it up.
  var acceleration: SIMD3<Double>
  /// rad/s, as `IMUGyroscope::GetRawState` combines its inputs: x = Pitch Down - Pitch Up,
  /// y = Roll Left - Roll Right, z = Yaw Left - Yaw Right. nil without a gyroscope.
  var angularVelocity: SIMD3<Double>?
}

enum WiiRemoteMotionMapping {
  /// `MathUtil::GRAVITY_ACCELERATION`.
  static let standardGravity = 9.80665

  /// A controller's `GCMotion` reading as the emulated Wii Remote reads it through the stock profile.
  ///
  /// MUST MATCH THE C++: the `AccelerometerAxis` / `GyroscopeAxis` `AddInput` calls and their
  /// `GetState` in `Source/Core/InputCommon/ControllerInterface/iOS/MFiController.mm`. The Motion
  /// Test screen shows this function's result, so a mapping changed there and not here makes the
  /// screen lie. `WiiRemoteMotionMappingTests` mirrors `MFiMotionAxisTests.mm` pose for pose.
  ///
  /// - `acceleration`: `GCMotion.acceleration`, in g. GCMotion's frame for a pad lying flat, face
  ///   up: x right, y forward (out of the top edge), z up. Apple's sign: at rest it is the
  ///   direction gravity pulls, so that pad reads (0, 0, -1).
  /// - `rotationRate`: `GCMotion.rotationRate`, rad/s, right-handed about the same axes. nil when
  ///   the pad has no gyroscope (`hasRotationRate` false): the core then adds no gyro inputs.
  static func mfi(acceleration: SIMD3<Double>, rotationRate: SIMD3<Double>?) -> WiiRemoteMotion {
    // One input as a bound control reads it: `value * multiplier`, and ControlExpression clamps a
    // negative input to zero.
    func half(_ value: Double, _ multiplier: Double) -> Double { max(0, value * multiplier) }

    // AddInput(new AccelerometerAxis(motion, X, 1.0, "Accel Left")) and the five after it;
    // AccelerometerAxis::GetState scales g to m/s^2.
    let g = standardGravity
    let left = half(acceleration.x, g), right = half(acceleration.x, -g)
    let forward = half(acceleration.y, -g), back = half(acceleration.y, g)
    let up = half(acceleration.z, -g), down = half(acceleration.z, g)

    var angularVelocity: SIMD3<Double>?
    if let rotationRate {
      // AddInput(new GyroscopeAxis(motion, X, 1.0, "Gyro Pitch Up")) and the five after it.
      let pitchUp = half(rotationRate.x, 1), pitchDown = half(rotationRate.x, -1)
      let rollLeft = half(rotationRate.y, -1), rollRight = half(rotationRate.y, 1)
      let yawLeft = half(rotationRate.z, 1), yawRight = half(rotationRate.z, -1)
      angularVelocity = SIMD3(pitchDown - pitchUp, rollLeft - rollRight, yawLeft - yawRight)
    }
    return WiiRemoteMotion(
      acceleration: SIMD3(left - right, back - forward, up - down), angularVelocity: angularVelocity)
  }
}

/// How the emulated Wii Remote is lying, in words a tester can check against the controller in
/// their hands.
enum WiiRemotePose: Equatable, CaseIterable {
  case flatFaceUp
  case flatFaceDown
  case pointingAtCeiling
  case pointingAtFloor
  case rightSideDown
  case leftSideDown
  /// At rest, but not within `WiiRemoteAttitude.poseCone` of any of the six.
  case tilted
  /// Not about 1 g: swung, shaken or dropped, so the reading says nothing about the pose.
  case moving
  /// Nothing at all: the sensors are off or have not reported yet.
  case noReading

  var title: String {
    switch self {
    case .flatFaceUp: return L("Flat, face up")
    case .flatFaceDown: return L("Upside down (face down)")
    case .pointingAtCeiling: return L("Pointing at the ceiling")
    case .pointingAtFloor: return L("Pointing at the floor")
    case .rightSideDown: return L("Right side down")
    case .leftSideDown: return L("Left side down")
    case .tilted: return L("Tilted")
    case .moving: return L("Moving")
    case .noReading: return L("No reading")
    }
  }
}

/// The pose and tilt an accelerometer reading implies. Only gravity tells: it is right while the
/// remote is held still.
struct WiiRemoteAttitude: Equatable {
  var pose: WiiRemotePose
  /// Degrees the nose is above the horizon: +90 pointing at the ceiling. nil while `moving` or
  /// `noReading`.
  var pitchDegrees: Double?
  /// Degrees rolled about the nose, positive with the right side down; 180 face down. nil with
  /// `pitchDegrees`, and 0 pointing straight up or down, where roll means nothing.
  var rollDegrees: Double?

  /// Within this many degrees of an axis, the remote is in that axis's pose.
  static let poseCone = 25.0
  /// Below this (in g) there is no reading to speak of.
  static let minimumReading = 0.1
  /// A still remote reads 1 g; outside this range it is being moved.
  static let restRange = 0.7 ... 1.3
  /// With less than this of "up" left across the remote (sine of the angle from vertical), roll is noise.
  static let minimumRollLever = 0.15

  /// - Parameter acceleration: `WiiRemoteMotion.acceleration` (m/s^2, x left, y back, z top).
  init(acceleration: SIMD3<Double>) {
    let magnitude = simd_length(acceleration) / WiiRemoteMotionMapping.standardGravity
    guard magnitude >= Self.minimumReading else {
      self.init(pose: .noReading)
      return
    }
    guard Self.restRange.contains(magnitude) else {
      self.init(pose: .moving)
      return
    }
    // At rest the reading points up, in the remote's frame.
    let up = simd_normalize(acceleration)
    let threshold = cos(Self.poseCone * .pi / 180)
    let pose: WiiRemotePose
    if up.z >= threshold {
      pose = .flatFaceUp
    } else if up.z <= -threshold {
      pose = .flatFaceDown
    } else if up.y <= -threshold {
      // The remote's nose is its -y end: up along -y is nose up.
      pose = .pointingAtCeiling
    } else if up.y >= threshold {
      pose = .pointingAtFloor
    } else if up.x >= threshold {
      // Up along the remote's left is its right side down.
      pose = .rightSideDown
    } else if up.x <= -threshold {
      pose = .leftSideDown
    } else {
      pose = .tilted
    }
    let pitch = asin(max(-1, min(1, -up.y))) * 180 / .pi
    let roll = simd_length(SIMD2(up.x, up.z)) < Self.minimumRollLever ? 0 : atan2(up.x, up.z) * 180 / .pi
    self.init(pose: pose, pitchDegrees: pitch, rollDegrees: roll)
  }

  init(pose: WiiRemotePose, pitchDegrees: Double? = nil, rollDegrees: Double? = nil) {
    self.pose = pose
    self.pitchDegrees = pitchDegrees
    self.rollDegrees = rollDegrees
  }
}

/// Which way the emulated Wii Remote is turning, named after the core's gyro inputs.
enum WiiRemoteTurn: Equatable, CaseIterable {
  case still
  case pitchUp
  case pitchDown
  case rollLeft
  case rollRight
  case yawLeft
  case yawRight

  /// rad/s (about 20 degrees a second): above a resting gyro's bias, below any deliberate twist.
  static let threshold = 0.35

  /// The fastest axis, if it is turning at all.
  ///
  /// - Parameter angularVelocity: `WiiRemoteMotion.angularVelocity`.
  init(angularVelocity: SIMD3<Double>) {
    let magnitudes = [abs(angularVelocity.x), abs(angularVelocity.y), abs(angularVelocity.z)]
    guard let fastest = magnitudes.max(), fastest >= Self.threshold else {
      self = .still
      return
    }
    // The core's signs: x = Pitch Down - Pitch Up, y = Roll Left - Roll Right, z = Yaw Left - Yaw Right.
    if fastest == magnitudes[0] {
      self = angularVelocity.x > 0 ? .pitchDown : .pitchUp
    } else if fastest == magnitudes[1] {
      self = angularVelocity.y > 0 ? .rollLeft : .rollRight
    } else {
      self = angularVelocity.z > 0 ? .yawLeft : .yawRight
    }
  }

  var title: String {
    switch self {
    case .still: return L("Not turning")
    case .pitchUp: return L("Nose lifting (Pitch Up)")
    case .pitchDown: return L("Nose dropping (Pitch Down)")
    case .rollLeft: return L("Left side dropping (Roll Left)")
    case .rollRight: return L("Right side dropping (Roll Right)")
    case .yawLeft: return L("Turning left (Yaw Left)")
    case .yawRight: return L("Turning right (Yaw Right)")
    }
  }
}

/// Turns on motion sensors that need it (`GCMotion.sensorsRequireManualActivation`: the DualShock 4)
/// while Motion Test is on screen, and afterwards turns off only the ones it turned on.
///
/// A sensor found off gets one sample's grace before this turns it on. The app's connect handler
/// (`installMotionHandler`) and the core's MFi backend both switch a new pad's sensors on and
/// expect them to stay on; were this to get there first on a pad that connects while the screen is
/// up, leaving the screen would switch that pad's motion off under them.
struct MotionSensorActivation {
  private var seenOff: Set<ObjectIdentifier> = []
  private var activated: [any ManuallyActivatedMotion] = []

  /// Call once per sample for every sensor on screen.
  mutating func sample(_ motion: any ManuallyActivatedMotion) {
    let id = ObjectIdentifier(motion)
    guard motion.sensorsRequireManualActivation, !motion.sensorsActive else {
      seenOff.remove(id)
      return
    }
    guard seenOff.contains(id) else {
      seenOff.insert(id)
      return
    }
    seenOff.remove(id)
    motion.sensorsActive = true
    activated.append(motion)
  }

  /// Turns off what `sample` turned on, and forgets everything.
  mutating func restore() {
    for motion in activated { motion.sensorsActive = false }
    activated.removeAll()
    seenOff.removeAll()
  }
}

/// The part of `GCMotion` `MotionSensorActivation` needs, so tests can stand in for a controller.
protocol ManuallyActivatedMotion: AnyObject {
  var sensorsRequireManualActivation: Bool { get }
  var sensorsActive: Bool { get set }
}
