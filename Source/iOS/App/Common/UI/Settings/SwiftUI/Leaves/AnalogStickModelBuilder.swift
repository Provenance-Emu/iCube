// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Each old one-row section's header is its row's title.
enum AnalogStickModelBuilder {
  static func format(_ value: Double) -> String { String(format: "%.2f", value) }

  static func make(state: AnalogStickState, apply: @escaping (AnalogStickChange) -> Void) -> MenuModel {
    MenuModel(sections: [
      MenuSection(id: "stick-feel", header: nil, items: [
        SettingsRow.stepper("gain", L("Analog Stick Gain"), state.gain, range: AnalogStickLimits.gain, step: AnalogStickLimits.gainStep,
                            format: format,
                            L("Scales on-screen analog stick and trigger travel. Higher values reach full deflection sooner. Motion (gyro/accelerometer) and physical controllers are never scaled."),
                            set: { apply(.gain($0)) }),
        SettingsRow.stepper("deadzone", L("Analog Stick Deadzone"), state.deadzone, range: AnalogStickLimits.deadzone, step: AnalogStickLimits.deadzoneStep,
                            format: format,
                            L("Ignores small stick movements to reduce drift."),
                            set: { apply(.deadzone($0)) }),
        SettingsRow.stepper("smoothing", L("Analog Stick Smoothing"), state.smoothing, range: AnalogStickLimits.smoothing, step: AnalogStickLimits.smoothingStep,
                            format: format,
                            L("Applies exponential smoothing to analog triggers. Sticks and motion are never smoothed. 0 disables smoothing."),
                            set: { apply(.smoothing($0)) }),
      ]),
    ])
  }
}
