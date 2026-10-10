// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed.
enum EnhancedMotionModelBuilder {
  static func make(state: EnhancedMotionState, apply: @escaping (EnhancedMotionChange) -> Void) -> MenuModel {
    let gyroPointer = MenuSection(id: "gyro-pointer", header: L("Gyro Pointer"), items: [
      SettingsRow.cycle("horizontal-movement", L("Horizontal Movement"), HorizontalMotionMode.allCases.map { ($0.label, $0) },
                        state.horizontalMotionMode, horizontalDescription(for: state.horizontalMotionMode),
                        set: { apply(.horizontalMotion($0)) }),
    ])

    var fullMotion = [
      // Read by TCDeviceMotion's IMU policy in every pointer mode, so it is not nested under 6DOF.
      SettingsRow.toggle("wiimote-imu", L("Wiimote Motion Controls"), state.wiimoteIMU,
                         L("The Wii Remote tilts and turns with the device while the Pointer is set to Gyro and while the remote is held sideways. With a touch Pointer the upright remote stays level, so tilting the device never hides the pointer; swings and shakes still reach the game. Off: the remote always rests level."),
                         set: { apply(.wiimoteIMU($0)) }),
      SettingsRow.toggle("six-dof", L("Enable 6DOF Motion Controls"), state.full6DOF,
                         L("Lets device motion reach the Nunchuck too, with Nunchuck Motion Controls below."),
                         set: { apply(.full6DOF($0)) }),
    ]
    if state.full6DOF {
      fullMotion.append(
        SettingsRow.toggle("nunchuk-imu", L("Nunchuck Motion Controls"), state.nunchukIMU,
                           L("Maps device motion to Nunchuck's accelerometer. Used by fewer games, mainly for secondary motion controls when using Nunchuck + Wiimote."),
                           set: { apply(.nunchukIMU($0)) }))
    }

    let quickSetup = MenuSection(id: "quick-setup", header: L("Quick Setup"), items: [
      SettingsRow.action("recommended", L("Recommended Motion Settings"),
                         L("Turns on 6DOF and Wiimote motion, Shake to Wiggle and roll for horizontal movement, and turns off invert and Nunchuck motion. The Pointer mode is not changed."),
                         run: { apply(.applyRecommended) }),
    ])

    return MenuModel(sections: [gyroPointer, MenuSection(id: "full-motion", header: L("Full Motion Mapping"), items: fullMotion), quickSetup])
  }

  /// The old caption, then what the selected mode does (the old screen showed it in the picker it pushed).
  static func horizontalDescription(for mode: HorizontalMotionMode) -> String {
    L("Whether tilting (roll) or turning (yaw) the device moves the pointer left/right while the Pointer is set to Gyro.") + " " + mode.description
  }
}
