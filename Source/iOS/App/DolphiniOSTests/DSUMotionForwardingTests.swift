// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

/// The DSU server streams the Wii Remote IMU axes the touch controller writes. The IMU writers put
/// the SAME signed value on both halves of each pair (accel in m/s^2, gyro in rad/s), and the core
/// reads `positive half - negative half`. DSU wants one signed value per axis, in g and deg/s, in
/// the convention Dolphin's own DSU client decodes (DualShockUDPClient.cpp).
final class DSUMotionForwardingTests: XCTestCase {
  private let gravity = Float(TCDeviceMotion.gravityToMetersPerSecondSquared)

  /// The DSU pad a client would see after the given axis writes, applied in order. Mirrors the
  /// accumulation `setAxisValueFor` performs: each non-`none` component overwrites its slot.
  private struct Pad {
    var accel = [Float](repeating: 0, count: 3)
    var gyro = [Float](repeating: 0, count: 3)
  }

  private func apply(_ writes: [(TCButtonType, Float)]) -> Pad {
    var pad = Pad()
    for (button, value) in writes {
      let component = TCManagerInterface.dsuMotionComponent(forAxis: button.rawValue, value: value)
      switch component.kind {
      case .accelerometer: pad.accel[component.index] = component.value
      case .gyro: pad.gyro[component.index] = component.value
      default: break
      }
    }
    return pad
  }

  private func writes(accel: SIMD3<Double>) -> [(TCButtonType, Float)] {
    TCDeviceMotion.wiimoteAccelWrites(x: accel.x, y: accel.y, z: accel.z).map { ($0.key, $0.value) }
  }

  private func writes(gyro: SIMD3<Double>) -> [(TCButtonType, Float)] {
    TCDeviceMotion.wiimoteGyroWrites(pitch: gyro.x, roll: gyro.y, yaw: gyro.z).map { ($0.key, $0.value) }
  }

  // MARK: - Sign independent of write order

  func testAccelSignDoesNotDependOnWriteOrder() {
    let all = writes(accel: SIMD3(3.0, -2.0, 9.0))
    let forward = apply(all)
    let backward = apply(all.reversed())
    // Shuffled differently again: interleave from both ends.
    var shuffled: [(TCButtonType, Float)] = []
    var lower = 0, upper = all.count - 1
    while lower <= upper {
      shuffled.append(all[lower]); lower += 1
      if lower <= upper { shuffled.append(all[upper]); upper -= 1 }
    }
    XCTAssertEqual(forward.accel, backward.accel)
    XCTAssertEqual(forward.accel, apply(shuffled).accel)
    XCTAssertEqual(forward.accel[0], 3.0 / gravity, accuracy: 1e-5)
  }

  func testGyroSignDoesNotDependOnWriteOrder() {
    let all = writes(gyro: SIMD3(0.5, -1.0, 2.0))
    XCTAssertEqual(apply(all).gyro, apply(all.reversed()).gyro)
  }

  func testOnlyOneHalfPerAxisIsForwarded() {
    // Each of the 12 IMU axis ids maps to a motion component or none; exactly 3 + 3 are signed.
    let kinds = (625...636).map { TCManagerInterface.dsuMotionComponent(forAxis: $0, value: 1).kind }
    XCTAssertEqual(kinds.filter { $0 == .accelerometer }.count, 3)
    XCTAssertEqual(kinds.filter { $0 == .gyro }.count, 3)
    // Ids outside the Wii Remote IMU range are not motion.
    for axis in [0, 11, 20, 112, 624, 637, 900, 905] {
      XCTAssertEqual(TCManagerInterface.dsuMotionComponent(forAxis: axis, value: 1).kind, TCDSUMotionKind.none)
    }
  }

  // MARK: - Units

  func testAccelerationIsConvertedFromMetersPerSecondSquaredToG() {
    // A level remote at rest: +1 g on the core's Up axis. DSU's y points the other way (Dolphin's
    // client reads Accel Up = -y), so a resting remote is y = -1 g.
    let rest = apply(writes(accel: SIMD3(0, 0, Double(gravity))))
    XCTAssertEqual(rest.accel[0], 0, accuracy: 1e-5)
    XCTAssertEqual(rest.accel[1], -1.0, accuracy: 1e-5)
    XCTAssertEqual(rest.accel[2], 0, accuracy: 1e-5)
  }

  func testGyroIsConvertedFromRadiansToDegreesPerSecond() {
    let pad = apply(writes(gyro: SIMD3(.pi, 0, 0)))
    XCTAssertEqual(abs(pad.gyro[0]), 180.0, accuracy: 1e-3)
    XCTAssertEqual(pad.gyro[1], 0, accuracy: 1e-5)
    XCTAssertEqual(pad.gyro[2], 0, accuracy: 1e-5)
  }

  // MARK: - Convention: a Dolphin DSU client decodes the original remote motion

  /// Dolphin's DSU client (DualShockUDPClient.cpp): each half is `(dsu * sign) / range`, clamped
  /// at 0 by ControlExpression; the core then combines the halves. Reproduce that and the core's
  /// IMU combination and require the original vector back.
  func testDolphinDSUClientReconstructsTheRemoteMotion() {
    let accel = SIMD3<Double>(4.0, -3.0, 7.5)
    let gyro = SIMD3<Double>(1.2, -0.7, 0.4) // pitch, roll, yaw rad/s
    let pad = apply(writes(accel: accel) + writes(gyro: gyro))

    func half(_ dsu: Float, _ scale: Float) -> Float { max(0, dsu * scale) }
    // Client: Accel Left/Right use x with +/-g, Up/Down use y with -/+g, Forward/Backward use z.
    let x = pad.accel[0] * gravity
    let yDsu = pad.accel[1] * gravity
    let zDsu = pad.accel[2] * gravity
    let coreX = half(x, 1) - half(x, -1)            // Left - Right
    let coreZ = half(yDsu, -1) - half(yDsu, 1)      // Up - Down
    let coreY = half(zDsu, -1) - half(zDsu, 1)      // Backward - Forward
    XCTAssertEqual(Double(coreX), accel.x, accuracy: 1e-3)
    XCTAssertEqual(Double(coreY), accel.y, accuracy: 1e-3)
    XCTAssertEqual(Double(coreZ), accel.z, accuracy: 1e-3)

    // Client gyro: Pitch Up = +pitch, Down = -pitch; Roll Left = -roll, Right = +roll; Yaw likewise.
    let toRad = Float.pi / 180
    let pitch = pad.gyro[0] * toRad, yaw = pad.gyro[1] * toRad, roll = pad.gyro[2] * toRad
    let corePitch = half(pitch, -1) - half(pitch, 1) // PitchDown - PitchUp
    let coreRoll = half(roll, -1) - half(roll, 1)    // RollLeft - RollRight
    let coreYaw = half(yaw, -1) - half(yaw, 1)       // YawLeft - YawRight
    XCTAssertEqual(Double(corePitch), gyro.x, accuracy: 1e-4)
    XCTAssertEqual(Double(coreRoll), gyro.y, accuracy: 1e-4)
    XCTAssertEqual(Double(coreYaw), gyro.z, accuracy: 1e-4)
  }
}
