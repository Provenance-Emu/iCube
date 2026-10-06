// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import CoreHaptics
import QuartzCore
import PVWebServer
import PVHelp
#if os(iOS)
import SafariServices
import AudioToolbox
#endif
#if canImport(GameController)
import GameController
#endif
#if os(iOS)
#endif
import Foundation

/// Motion options with no home on the player screen (controller hub decision 6): which gesture
/// moves the gyro pointer sideways, and the full 6DOF motion mapping. The pointer mode, its
/// invert switches and Shake to Wiggle are on the player screen.
struct EnhancedMotionControlsView: View {
  @AppStorage(MotionSettings.Key.useYawForHorizontal) private var useYawForHorizontal: Bool = false
  @AppStorage(MotionSettings.Key.full6DOF) private var fullMotionEnabled: Bool = true
  @AppStorage(MotionSettings.Key.wiimoteIMU) private var wiimoteIMUEnabled: Bool = true
  @AppStorage(MotionSettings.Key.nunchukIMU) private var nunchuckIMUEnabled: Bool = false

  @State private var horizontalMotionMode: HorizontalMotionMode = .roll

  enum HorizontalMotionMode: Int, CaseIterable {
    case roll = 0, yaw = 1
    var label: String {
      switch self {
      case .roll: return L("Roll (Tilt Left/Right)")
      case .yaw: return L("Yaw (Turn Left/Right)")
      }
    }
    var description: String {
      switch self {
      case .roll: return L("Tilt device left/right to move cursor")
      case .yaw: return L("Rotate device left/right to move cursor")
      }
    }
  }

  var body: some View {
    List {
      Section(header: Text(L("Gyro Pointer"))) {
        settingsNavCaption(
          destination: HorizontalMotionPicker(selected: $horizontalMotionMode),
          L("Whether tilting (roll) or turning (yaw) the device moves the pointer left/right while the Pointer is set to Gyro.")
        ) {
          Text(L("Horizontal Movement"))
        }
        .onChange(of: horizontalMotionMode) { _, mode in
          useYawForHorizontal = (mode == .yaw)
        }
      }

      Section(header: Text(L("Full Motion Mapping"))) {
        // Read by TCDeviceMotion's IMU policy in every pointer mode, so it is not nested under 6DOF.
        settingsCaption(
          Toggle(L("Wiimote Motion Controls"), isOn: $wiimoteIMUEnabled),
          L("The Wii Remote tilts and turns with the device while the Pointer is set to Gyro and while the remote is held sideways. With a touch Pointer the upright remote stays level, so tilting the device never hides the pointer; swings and shakes still reach the game. Off: the remote always rests level."))

        settingsCaption(
          Toggle(L("Enable 6DOF Motion Controls"), isOn: $fullMotionEnabled),
          L("Lets device motion reach the Nunchuck too, with Nunchuck Motion Controls below."))

        if fullMotionEnabled {
          VStack(alignment: .leading, spacing: 8) {
            Toggle(L("Nunchuck Motion Controls"), isOn: $nunchuckIMUEnabled)
            Text(L("Maps device motion to Nunchuck's accelerometer. Used by fewer games, mainly for secondary motion controls when using Nunchuck + Wiimote."))
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.leading)
        }
      }

      Section(header: Text(L("Quick Setup"))) {
        settingsCaption(
          Button(L("Recommended Motion Settings")) { applyRecommendedSettings() },
          L("Turns on 6DOF and Wiimote motion, Shake to Wiggle and roll for horizontal movement, and turns off invert and Nunchuck motion. The Pointer mode is not changed."))
      }
    }
    .navigationTitle(L("Advanced Motion Settings"))
    .onAppear { horizontalMotionMode = useYawForHorizontal ? .yaw : .roll }
    // A running game re-reads motion settings on this notification.
    .onChange(of: useYawForHorizontal) { _, _ in notifyMotionSettingsChanged() }
    .onChange(of: fullMotionEnabled) { _, _ in notifyMotionSettingsChanged() }
    .onChange(of: wiimoteIMUEnabled) { _, _ in notifyMotionSettingsChanged() }
    .onChange(of: nunchuckIMUEnabled) { _, _ in notifyMotionSettingsChanged() }
  }

  /// The pointer mode is left alone: it used to switch to Gyro, which silently turned off the 6DOF
  /// mapping this same button turns on, and the player screen owns the mode.
  private func applyRecommendedSettings() {
    MotionSettings.applyRecommended()
    horizontalMotionMode = .roll
    notifyMotionSettingsChanged()
    #if os(iOS)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    #endif
  }

  private func notifyMotionSettingsChanged() {
    NotificationCenter.default.post(name: .DOLMotionSettingsChanged, object: nil)
  }
}

private struct HorizontalMotionPicker: View {
  @Binding var selected: EnhancedMotionControlsView.HorizontalMotionMode

  var body: some View {
    List {
      ForEach(EnhancedMotionControlsView.HorizontalMotionMode.allCases, id: \.rawValue) { mode in
        Button(action: { selected = mode }) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(mode.label)
                .foregroundColor(.primary)
              Text(mode.description)
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            if selected == mode {
              Image(systemName: "checkmark")
                .foregroundColor(.accentColor)
            }
          }
        }
        .buttonStyle(.plain)
      }
    }
    .navigationTitle(L("Horizontal Movement"))
  }
}
