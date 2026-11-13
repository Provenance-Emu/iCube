// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import simd

/// What a controller says about its motion sensors (`GCMotion`'s capability flags).
struct MotionSensorFlags: Equatable {
  var hasRotationRate: Bool
  var hasGravityAndUserAcceleration: Bool
  var hasAttitude: Bool
  var sensorsRequireManualActivation: Bool
  var sensorsActive: Bool
}

/// One thing with motion sensors, sampled once: its raw reading and what the emulated Wii Remote
/// reads from it.
struct MotionTestSource: Equatable, Identifiable {
  enum Kind: Equatable {
    /// A gamepad: it can play as a Wii Remote.
    case controller
    /// A menu device (`GCController.isMenuRemote`: the Siri Remote).
    case menuRemote
    /// This device's own sensors, used while the touchscreen plays as a Wii Remote (iOS).
    case device
  }

  /// Stable while the source stays connected; the rows' ids are built on it.
  let id: String
  var name: String
  var kind: Kind
  /// As the sensor reports it, in g (`GCMotion.acceleration`, CoreMotion's accelerometer): the
  /// direction gravity pulls at rest.
  var acceleration: SIMD3<Double>
  /// As the sensor reports it, rad/s. nil when it has no gyroscope.
  var rotationRate: SIMD3<Double>?
  /// nil for `device`: CoreMotion has no such flags.
  var flags: MotionSensorFlags?
  var remote: WiiRemoteMotion

  /// A `GCController`'s reading, through the core's own mapping (`WiiRemoteMotionMapping.mfi`). The
  /// rotation rate counts only when the pad says it has one, as in the core.
  static func controller(
    id: String, name: String, isMenuRemote: Bool, acceleration: SIMD3<Double>, rotationRate: SIMD3<Double>,
    flags: MotionSensorFlags
  ) -> MotionTestSource {
    let rate = flags.hasRotationRate ? rotationRate : nil
    return MotionTestSource(
      id: id, name: name, kind: isMenuRemote ? .menuRemote : .controller, acceleration: acceleration,
      rotationRate: rate, flags: flags,
      remote: WiiRemoteMotionMapping.mfi(acceleration: acceleration, rotationRate: rate))
  }
}

/// Plain snapshot of everything Motion Test shows; `MotionTestSampler` replaces it about 15 times a
/// second.
struct MotionTestState: Equatable {
  /// Connected controllers that have motion sensors, menu remotes included.
  var sources: [MotionTestSource] = []
  /// This device's own sensors (iOS). nil on tvOS, on hardware without them (the simulator) and
  /// before their first sample.
  var device: MotionTestSource?
  /// The device has an accelerometer at all: false turns the device section into one line saying so.
  var deviceMotionAvailable = false
}
