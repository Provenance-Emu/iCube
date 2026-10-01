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

  func testRegisteredDefaultsAreTheShippedValues() {
    MotionSettings.registerDefaults(in: store)
    XCTAssertFalse(MotionSettings.useYawForHorizontal(in: store))
    XCTAssertFalse(MotionSettings.invertRoll(in: store))
    XCTAssertFalse(MotionSettings.invertPitch(in: store))
    XCTAssertTrue(MotionSettings.enhancedShakeDetection(in: store))
    XCTAssertTrue(MotionSettings.full6DOF(in: store))
    XCTAssertTrue(MotionSettings.wiimoteIMU(in: store))
    XCTAssertFalse(MotionSettings.nunchukIMU(in: store))
    XCTAssertEqual(MotionSettings.irPointerGain(in: store), 1.0)
  }

  func testAUserValueBeatsTheRegisteredDefault() {
    MotionSettings.registerDefaults(in: store)
    store.set(false, forKey: MotionSettings.Key.enhancedShakeDetection)
    XCTAssertFalse(MotionSettings.enhancedShakeDetection(in: store))
  }

  /// DefaultPreferences.plist is registered on every launch after MotionSettings, so a motion key
  /// left in it would silently override MotionSettings.defaults.
  func testBundledDefaultPreferencesDefineNoMotionSettingsKey() throws {
    let url = try XCTUnwrap(Bundle.main.url(forResource: "DefaultPreferences", withExtension: "plist"))
    let plist = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
    for key in MotionSettings.defaults.keys {
      XCTAssertNil(plist[key], "\(key) is registered by both DefaultPreferences.plist and MotionSettings")
    }
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

  /// Decision 4: a multiplier on TCDeviceMotion's constants, 1.0 by default so nothing changes.
  func testGyroPointerSensitivityDefaultsToOne() {
    XCTAssertEqual(MotionSettings.gyroPointerSensitivity(in: store), 1.0, "unregistered reads as 1")
    MotionSettings.registerDefaults(in: store)
    XCTAssertEqual(MotionSettings.gyroPointerSensitivity(in: store), 1.0)
    store.set(-2.0, forKey: MotionSettings.Key.gyroPointerSensitivity)
    XCTAssertEqual(MotionSettings.gyroPointerSensitivity(in: store), 1.0, "a broken value reads as 1")
    XCTAssertEqual(MotionSettings.Key.gyroPointerSensitivity, "motion_gyro_pointer_sensitivity")
  }

  func testSettersWriteTheExistingKeys() {
    MotionSettings.setInvertRoll(true, in: store)
    MotionSettings.setInvertPitch(true, in: store)
    MotionSettings.setEnhancedShakeDetection(false, in: store)
    MotionSettings.setIRPointerGain(2.0, in: store)
    MotionSettings.setGyroPointerSensitivity(1.5, in: store)
    XCTAssertTrue(store.bool(forKey: "motion_invert_roll"))
    XCTAssertTrue(store.bool(forKey: "motion_invert_pitch"))
    XCTAssertEqual(store.object(forKey: "motion_enhanced_shake_detection") as? Bool, false)
    XCTAssertEqual(store.double(forKey: "touch_overlay_ir_pointer_gain"), 2.0)
    XCTAssertEqual(MotionSettings.gyroPointerSensitivity(in: store), 1.5)
  }

  /// The observers in EmulationScreen and the existing posters use the literal string; the declared
  /// name must be the same string or the new posters would restart nothing.
  func testMotionSettingsChangedIsTheStringTheObserversUse() {
    XCTAssertEqual(Notification.Name.DOLMotionSettingsChanged.rawValue, "DOLMotionSettingsChanged")
  }
}
