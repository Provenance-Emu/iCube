// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The single source of truth for the motion and pointer defaults, read by `TCDeviceMotion` and the
/// settings screens. `MotionSettings.defaults` replaced the equivalent entries that used to live in
/// `DefaultPreferences.plist` (commit 2691df551c): the values here are exactly what that plist
/// shipped, so no user sees a behaviour change. Defaults are registered on every launch (registered
/// values are not persisted); `DefaultPreferences.plist` must not define any of these keys, or its
/// registration (which runs after this one) would silently win.
enum MotionSettings {
  enum Key {
    static let useYawForHorizontal = "motion_use_yaw_for_horizontal"
    static let invertRoll = "motion_invert_roll"
    static let invertPitch = "motion_invert_pitch"
    static let enhancedShakeDetection = "motion_enhanced_shake_detection"
    static let full6DOF = "motion_enable_full_6dof"
    static let wiimoteIMU = "motion_wiimote_imu_enabled"
    static let nunchukIMU = "motion_nunchuck_imu_enabled"
    static let irPointerGain = "touch_overlay_ir_pointer_gain"
    /// New in controller hub Phase 3: a multiplier on `TCDeviceMotion`'s gyro pointer constants.
    static let gyroPointerSensitivity = "motion_gyro_pointer_sensitivity"
  }

  static let defaults: [String: Any] = [
    Key.useYawForHorizontal: false,
    Key.invertRoll: false,
    Key.invertPitch: false,
    // `setupEnhancedMotionControls()` used to force this on for every touchscreen Wii boot.
    Key.enhancedShakeDetection: true,
    Key.full6DOF: true,
    Key.wiimoteIMU: true,
    Key.nunchukIMU: false,
    Key.irPointerGain: 1.0,
    // 1.0 keeps the gyro pointer exactly as it was before the setting existed.
    Key.gyroPointerSensitivity: 1.0,
  ]

  static func registerDefaults(in store: UserDefaults = .standard) {
    store.register(defaults: defaults)
  }

  static func useYawForHorizontal(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.useYawForHorizontal) }
  static func invertRoll(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.invertRoll) }
  static func invertPitch(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.invertPitch) }
  static func enhancedShakeDetection(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.enhancedShakeDetection) }
  static func full6DOF(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.full6DOF) }
  static func wiimoteIMU(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.wiimoteIMU) }
  static func nunchukIMU(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.nunchukIMU) }
  static func irPointerGain(in store: UserDefaults = .standard) -> Double { store.double(forKey: Key.irPointerGain) }

  /// A missing (unregistered reads 0), non-finite or non-positive value reads as 1, the neutral gain.
  static func gyroPointerSensitivity(in store: UserDefaults = .standard) -> Double {
    let value = store.double(forKey: Key.gyroPointerSensitivity)
    return value.isFinite && value > 0 ? value : 1
  }

  // Writers for the player screen's Pointer & Motion rows. The same keys, so `TCDeviceMotion`, the
  // touch overlay and the older screens all see the change. `TCDeviceMotion` reads invert and gyro
  // sensitivity on every motion sample; only the shake setting needs `.DOLMotionSettingsChanged`,
  // because the emulation screen decides from it whether motion runs at all.
  static func setInvertRoll(_ value: Bool, in store: UserDefaults = .standard) { store.set(value, forKey: Key.invertRoll) }
  static func setInvertPitch(_ value: Bool, in store: UserDefaults = .standard) { store.set(value, forKey: Key.invertPitch) }
  static func setEnhancedShakeDetection(_ value: Bool, in store: UserDefaults = .standard) {
    store.set(value, forKey: Key.enhancedShakeDetection)
  }
  static func setIRPointerGain(_ value: Double, in store: UserDefaults = .standard) { store.set(value, forKey: Key.irPointerGain) }
  static func setGyroPointerSensitivity(_ value: Double, in store: UserDefaults = .standard) {
    store.set(value, forKey: Key.gyroPointerSensitivity)
  }
}
