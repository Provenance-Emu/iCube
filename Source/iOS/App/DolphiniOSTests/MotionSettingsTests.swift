// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class MotionSettingsTests: XCTestCase {
  private var store: UserDefaults!
  private let suite = "MotionSettingsTests"

  override func setUp() {
    super.setUp()
    UserDefaults().removePersistentDomain(forName: suite)
    store = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: suite)
    super.tearDown()
  }

  func testRegisteredDefaultsMatchWhatTheRuntimeDidBeforeRegistration() {
    MotionSettings.registerDefaults(in: store)
    XCTAssertFalse(MotionSettings.useYawForHorizontal(in: store))
    XCTAssertFalse(MotionSettings.invertRoll(in: store))
    XCTAssertFalse(MotionSettings.invertPitch(in: store))
    XCTAssertTrue(MotionSettings.enhancedShakeDetection(in: store))
    XCTAssertFalse(MotionSettings.full6DOF(in: store))
    XCTAssertFalse(MotionSettings.wiimoteIMU(in: store))
    XCTAssertFalse(MotionSettings.nunchukIMU(in: store))
    XCTAssertEqual(MotionSettings.irPointerGain(in: store), 1.0)
  }

  func testAUserValueBeatsTheRegisteredDefault() {
    MotionSettings.registerDefaults(in: store)
    store.set(false, forKey: MotionSettings.Key.enhancedShakeDetection)
    XCTAssertFalse(MotionSettings.enhancedShakeDetection(in: store))
  }

  func testKeyNamesAreTheExistingOnes() {
    XCTAssertEqual(MotionSettings.Key.useYawForHorizontal, "motion_use_yaw_for_horizontal")
    XCTAssertEqual(MotionSettings.Key.invertRoll, "motion_invert_roll")
    XCTAssertEqual(MotionSettings.Key.invertPitch, "motion_invert_pitch")
    XCTAssertEqual(MotionSettings.Key.enhancedShakeDetection, "motion_enhanced_shake_detection")
    XCTAssertEqual(MotionSettings.Key.full6DOF, "motion_enable_full_6dof")
    XCTAssertEqual(MotionSettings.Key.wiimoteIMU, "motion_wiimote_imu_enabled")
    XCTAssertEqual(MotionSettings.Key.nunchukIMU, "motion_nunchuck_imu_enabled")
    XCTAssertEqual(MotionSettings.Key.irPointerGain, "touch_overlay_ir_pointer_gain")
  }
}
