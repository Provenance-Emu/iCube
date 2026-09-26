// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

/// `TCManagerInterface.setAxisValueFor` applies the DSU deadzone / gain / smoothing knobs to
/// ordinary analog axes only. IMU axes (Wiimote accel 625-630, gyro 631-636, Nunchuk accel
/// 900-905) carry m/s^2 and rad/s and must reach the core untouched: gravity alone is ~9.8, so a
/// +/-1 clamp or a gain multiply corrupts every motion read. A clamped array index used to be
/// reused for the IMU range test, which made that classification impossible to satisfy.
final class TCManagerInterfaceAxisTests: XCTestCase {
  /// Controller slot no other test or view writes to.
  private let controller = 3
  private let defaults = UserDefaults.standard
  private var saved: [String: Any?] = [:]
  private let keys = ["dsu_gyro_gain", "dsu_deadzone", "dsu_smoothing"]

  override func setUp() {
    super.setUp()
    for key in keys { saved[key] = defaults.object(forKey: key) }
    // Aggressive knobs so any leak onto an IMU axis is unmistakable.
    defaults.set(2.0, forKey: "dsu_gyro_gain")
    defaults.set(0.2, forKey: "dsu_deadzone")
    defaults.set(0.5, forKey: "dsu_smoothing")
    TCManagerInterface.clearAll(forController: controller)
  }

  override func tearDown() {
    for key in keys {
      if let value = saved[key] ?? nil { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    TCManagerInterface.clearAll(forController: controller)
    super.tearDown()
  }

  private func roundTrip(_ axis: Int, _ value: Float) -> Float {
    TCManagerInterface.setAxisValueFor(axis, controller: controller, value: value)
    return TCManagerInterface.axisValue(for: axis, controller: controller)
  }

  func testWiimoteAccelerometerPassesGravityThroughUnclamped() {
    let gravity: Float = 9.80665
    XCTAssertEqual(roundTrip(625, gravity), gravity, accuracy: 0.0001)   // WIIMOTE_ACCEL_LEFT
    XCTAssertEqual(roundTrip(630, -gravity), -gravity, accuracy: 0.0001) // WIIMOTE_ACCEL_DOWN
  }

  func testWiimoteGyroscopeIsNotScaledDeadzonedOrSmoothed() {
    // 3 rad/s: above the old clamp, above the deadzone, and far from gain*value.
    XCTAssertEqual(roundTrip(631, 3.0), 3.0, accuracy: 0.0001) // WIIMOTE_GYRO_PITCH_UP
    // A tiny rate must survive the deadzone.
    XCTAssertEqual(roundTrip(636, 0.05), 0.05, accuracy: 0.0001) // WIIMOTE_GYRO_YAW_RIGHT
    // A second write must not be blended with the first (no EMA on IMU axes).
    XCTAssertEqual(roundTrip(631, -3.0), -3.0, accuracy: 0.0001)
  }

  func testNunchukAccelerometerIsRaw() {
    XCTAssertEqual(roundTrip(900, 9.80665), 9.80665, accuracy: 0.0001) // NUNCHUK_ACCEL_LEFT
    XCTAssertEqual(roundTrip(905, 4.2), 4.2, accuracy: 0.0001)         // NUNCHUK_ACCEL_DOWN
  }

  func testAnalogStickStillGetsDeadzoneGainAndClamp() {
    // Split-stick axis 12 (main stick down): deadzone zeroes small input, gain saturates large.
    XCTAssertEqual(roundTrip(12, 0.1), 0.0, accuracy: 0.0001)
    XCTAssertEqual(roundTrip(12, 0.9), 1.0, accuracy: 0.0001)
  }

  func testTriggerAxisIsSmoothedButBoundedByClamp() {
    // Axis 20 (GC L trigger) is an ordinary analog axis: EMA with alpha 0.5 from a cleared 0.
    // 0.6 -> deadzone (0.6-0.2)/0.8 = 0.5 -> gain 2 = 1.0 -> EMA 0.5*0 + 0.5*1.0.
    XCTAssertEqual(roundTrip(20, 0.6), 0.5, accuracy: 0.0001)
  }
}
