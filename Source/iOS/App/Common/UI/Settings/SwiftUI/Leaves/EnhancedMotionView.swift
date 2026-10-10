// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

/// Motion options with no home on the player screen (controller hub decision 6): which gesture
/// moves the gyro pointer sideways, and the full 6DOF motion mapping. The pointer mode, its
/// invert switches and Shake to Wiggle are on the player screen.
/// `sync()` reads UserDefaults into the snapshot and writes nothing; `apply(_:)` is the only writer.
struct EnhancedMotionControlsView: View {
  @State private var state = EnhancedMotionState()

  var body: some View {
    SettingsLeafScreen(model: EnhancedMotionModelBuilder.make(state: state, apply: apply), title: L("Advanced Motion Settings"), sync: sync)
  }

  private func sync() {
    var s = EnhancedMotionState()
    s.horizontalMotionMode = MotionSettings.useYawForHorizontal() ? .yaw : .roll
    s.wiimoteIMU = MotionSettings.wiimoteIMU()
    s.full6DOF = MotionSettings.full6DOF()
    s.nunchukIMU = MotionSettings.nunchukIMU()
    state = s
  }

  private func apply(_ change: EnhancedMotionChange) {
    let defaults = UserDefaults.standard
    switch change {
    case .horizontalMotion(let mode):
      state.horizontalMotionMode = mode
      defaults.set(mode == .yaw, forKey: MotionSettings.Key.useYawForHorizontal)
    case .wiimoteIMU(let v):
      state.wiimoteIMU = v
      defaults.set(v, forKey: MotionSettings.Key.wiimoteIMU)
    case .full6DOF(let v):
      state.full6DOF = v
      defaults.set(v, forKey: MotionSettings.Key.full6DOF)
    case .nunchukIMU(let v):
      state.nunchukIMU = v
      defaults.set(v, forKey: MotionSettings.Key.nunchukIMU)
    case .applyRecommended:
      // The pointer mode is left alone: it used to switch to Gyro, which silently turned off the 6DOF
      // mapping this same button turns on, and the player screen owns the mode.
      MotionSettings.applyRecommended()
      sync()
      #if os(iOS)
      UINotificationFeedbackGenerator().notificationOccurred(.success)
      #endif
    }
    // A running game re-reads motion settings on this notification.
    NotificationCenter.default.post(name: .DOLMotionSettingsChanged, object: nil)
  }
}
