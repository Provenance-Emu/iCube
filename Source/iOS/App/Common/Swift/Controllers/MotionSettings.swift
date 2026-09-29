// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The motion and pointer settings, read by `TCDeviceMotion` and the settings screens. Before this
/// existed each screen declared its own `@AppStorage` default and the runtime read `bool(forKey:)`
/// (false when unset), so two screens showed "on" for features that were off. Defaults are
/// registered on every launch (registered values are not persisted), and they match what the
/// runtime did before registration, so no user sees a behaviour change.
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
  }

  static let defaults: [String: Any] = [
    Key.useYawForHorizontal: false,
    Key.invertRoll: false,
    Key.invertPitch: false,
    // `setupEnhancedMotionControls()` used to force this on for every touchscreen Wii boot.
    Key.enhancedShakeDetection: true,
    Key.full6DOF: false,
    Key.wiimoteIMU: false,
    Key.nunchukIMU: false,
    Key.irPointerGain: 1.0,
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
}
