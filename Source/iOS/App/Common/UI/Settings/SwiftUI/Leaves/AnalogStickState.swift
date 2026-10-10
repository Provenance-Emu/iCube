// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// UserDefaults keys for the on-screen stick feel. They keep their old `dsu_` names because
/// `TCManagerInterface.setAxisValueFor:` reads them.
enum AnalogStickKey {
  static let gain = "dsu_gyro_gain"
  static let deadzone = "dsu_deadzone"
  static let smoothing = "dsu_smoothing"
}

/// Slider limits, defined once for the builder and the tests.
enum AnalogStickLimits {
  static let gain: ClosedRange<Double> = 0.1...3.0
  static let gainStep = 0.05
  static let deadzone: ClosedRange<Double> = 0.0...0.49
  static let deadzoneStep = 0.01
  static let smoothing: ClosedRange<Double> = 0.0...0.9
  static let smoothingStep = 0.05
}

/// Snapshot of the stick-feel UserDefaults. Defaults match the old view's.
struct AnalogStickState: Equatable {
  static let defaultGain = 1.0
  static let defaultDeadzone = 0.05
  static let defaultSmoothing = 0.0

  var gain = defaultGain
  var deadzone = defaultDeadzone
  var smoothing = defaultSmoothing

  /// A stored Double, or `default` when nothing (or something that is not a Double) is stored. A stored
  /// 0.0 is a real value (smoothing off), never "unset".
  static func stored(_ object: Any?, default fallback: Double) -> Double {
    object as? Double ?? fallback
  }
}

/// One user edit. The host applies it to its snapshot AND to UserDefaults; the builder only emits it.
enum AnalogStickChange: Equatable {
  case gain(Double)
  case deadzone(Double)
  case smoothing(Double)
}
