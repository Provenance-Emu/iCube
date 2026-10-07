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

  /// "Recommended Motion Settings": 6DOF and Wii Remote motion on, Nunchuk motion off, Shake to
  /// Wiggle on, roll for horizontal, invert off. The pointer mode and both sensitivities are left
  /// alone. The caller posts `.DOLMotionSettingsChanged` so a running game picks it up.
  static func applyRecommended(in store: UserDefaults = .standard) {
    store.set(true, forKey: Key.full6DOF)
    store.set(true, forKey: Key.wiimoteIMU)
    store.set(false, forKey: Key.nunchukIMU)
    store.set(true, forKey: Key.enhancedShakeDetection)
    store.set(false, forKey: Key.useYawForHorizontal)
    store.set(false, forKey: Key.invertRoll)
    store.set(false, forKey: Key.invertPitch)
  }
}

extension MotionSettings {
  /// Every motion setting the device-motion handlers read per sample, plus `input_debug`.
  struct Snapshot: Equatable {
    var useYawForHorizontal: Bool
    var invertRoll: Bool
    var invertPitch: Bool
    var enhancedShakeDetection: Bool
    var full6DOF: Bool
    var wiimoteIMU: Bool
    var nunchukIMU: Bool
    var gyroPointerSensitivity: Double
    var inputDebug: Bool

    static let inputDebugKey = "input_debug"

    init(store: UserDefaults = .standard) {
      useYawForHorizontal = MotionSettings.useYawForHorizontal(in: store)
      invertRoll = MotionSettings.invertRoll(in: store)
      invertPitch = MotionSettings.invertPitch(in: store)
      enhancedShakeDetection = MotionSettings.enhancedShakeDetection(in: store)
      full6DOF = MotionSettings.full6DOF(in: store)
      wiimoteIMU = MotionSettings.wiimoteIMU(in: store)
      nunchukIMU = MotionSettings.nunchukIMU(in: store)
      gyroPointerSensitivity = MotionSettings.gyroPointerSensitivity(in: store)
      inputDebug = store.bool(forKey: Self.inputDebugKey)
    }
  }
}

/// `MotionSettings.Snapshot`, re-read only after a user default changes. `TCDeviceMotion` used to
/// read eight user defaults on every sample (the accelerometer and gyro at 200 Hz each, device motion
/// at 60 Hz); a change still applies from the next sample, because the change notification is posted
/// synchronously on the writing thread before the write returns.
///
/// Safe from any thread. The lock is never held while UserDefaults is called, so a defaults write
/// that posts its notification while holding UserDefaults' own lock can never deadlock against a
/// reader here.
final class MotionSettingsCache {
  static let shared = MotionSettingsCache()

  private let store: UserDefaults
  private let lock = NSLock()
  private var cached: MotionSettings.Snapshot?
  /// Bumped by every invalidation, so a snapshot read from the store before a change is never
  /// cached after it.
  private var generation = 0
  private let center: NotificationCenter
  private var observer: NSObjectProtocol?

  init(store: UserDefaults = .standard, center: NotificationCenter = .default) {
    self.store = store
    self.center = center
    // Any defaults object, not just `store`: a write through another `UserDefaults` instance on the
    // same domain posts with that instance as the object.
    observer = center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
      self?.invalidate()
    }
  }

  deinit {
    if let observer { center.removeObserver(observer) }
  }

  var snapshot: MotionSettings.Snapshot {
    lock.lock()
    if let cached {
      lock.unlock()
      return cached
    }
    let readGeneration = generation
    lock.unlock()

    let fresh = MotionSettings.Snapshot(store: store)
    lock.lock()
    if generation == readGeneration { cached = fresh }
    lock.unlock()
    return fresh
  }

  func invalidate() {
    lock.lock()
    generation &+= 1
    cached = nil
    lock.unlock()
  }
}
