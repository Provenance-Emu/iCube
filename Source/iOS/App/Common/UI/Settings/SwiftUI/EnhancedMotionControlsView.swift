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

struct EnhancedMotionControlsView: View {
  // Use @AppStorage for automatic UI updates and better SwiftUI integration
  @AppStorage("motion_use_yaw_for_horizontal") private var useYawForHorizontal: Bool = false
  @AppStorage("motion_invert_roll") private var invertRoll: Bool = false
  @AppStorage("motion_invert_pitch") private var invertPitch: Bool = false
  @AppStorage("motion_enhanced_shake_detection") private var enhancedShakeEnabled: Bool = true
  @AppStorage("motion_enable_full_6dof") private var fullMotionEnabled: Bool = true
  @AppStorage("motion_wiimote_imu_enabled") private var wiimoteIMUEnabled: Bool = true
  @AppStorage("motion_nunchuck_imu_enabled") private var nunchuckIMUEnabled: Bool = false

  @State private var horizontalMotionMode: HorizontalMotionMode = .roll
  @State private var currentIRMode: TouchIRMode = .drag

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
      Section(header: Text(L("Motion IR Cursor"))) {
        settingsNavCaption(
          destination: TouchIRModePicker(selected: $currentIRMode),
          L("How the Wii Remote IR pointer is controlled. Gyro uses device motion for added precision and unlocks the motion options below.")
        ) {
          Text(L("IR Control Method"))
        }
        .onChange(of: currentIRMode) { mode in
          DOLConfigBridge.setMainTouchPadIRMode(mode.rawValue)
          notifyMotionSettingsChanged()
        }

        if currentIRMode == .gyro {
          settingsNavCaption(
            destination: HorizontalMotionPicker(selected: $horizontalMotionMode),
            L("Whether tilting (roll) or turning (yaw) the device moves the pointer left/right.")
          ) {
            Text(L("Horizontal Movement"))
          }
          .onAppear { syncHorizontalMode() }
          .onChange(of: horizontalMotionMode) { mode in
            useYawForHorizontal = (mode == .yaw)
          }

          settingsCaption(
            Toggle(L("Invert Horizontal (Left/Right)"), isOn: $invertRoll),
            L("Flips left/right pointer motion."))

          settingsCaption(
            Toggle(L("Invert Vertical (Up/Down)"), isOn: $invertPitch),
            L("Flips up/down pointer motion."))
        }
      }

      Section(header: Text(L("Shake Detection"))) {
        settingsCaption(
          Toggle(L("Enable Advanced Shake Detection"), isOn: $enhancedShakeEnabled),
          L("Uses a motion-pattern algorithm to detect shake gestures more reliably than Dolphin's basic detection."))
      }

      Section(header: Text(L("Full Motion Mapping"))) {
        settingsCaption(
          Toggle(L("Enable 6DOF Motion Controls"), isOn: $fullMotionEnabled),
          L("Maps device motion to all 6 axes (rotation + acceleration) for games like Wii Sports and Mario Kart. Active only when IR control isn't using gyro mode."))

        if fullMotionEnabled {
          VStack(alignment: .leading, spacing: 8) {
            Toggle(L("Wiimote Motion Controls"), isOn: $wiimoteIMUEnabled)
            Text(L("Maps device motion to Wiimote's built-in accelerometer and gyroscope. Required for most motion-controlled Wii games."))
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.leading)

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
        Button(L("Apply Recommended Settings")) {
          // Set improved defaults based on user feedback
          enhancedShakeEnabled = true
          currentIRMode = .gyro // Use gyro IR mode
          DOLConfigBridge.setMainTouchPadIRMode(TouchIRMode.gyro.rawValue)
          fullMotionEnabled = true
          useYawForHorizontal = false // Use roll by default
          wiimoteIMUEnabled = true
          nunchuckIMUEnabled = false
          invertRoll = false
          invertPitch = false

          // Update local state
          horizontalMotionMode = .roll

          // Show confirmation
          #if os(iOS)
          let generator = UINotificationFeedbackGenerator()
          generator.notificationOccurred(.success)
          #endif
        }
      }
    }
    .navigationTitle(L("Advanced Motion Settings"))
    .onAppear {
      syncHorizontalMode()
      syncIRMode()
    }
    // CRITICAL: Notify running emulator when settings change
    .onChange(of: useYawForHorizontal) { _ in notifyMotionSettingsChanged() }
    .onChange(of: invertRoll) { _ in notifyMotionSettingsChanged() }
    .onChange(of: invertPitch) { _ in notifyMotionSettingsChanged() }
    .onChange(of: enhancedShakeEnabled) { _ in notifyMotionSettingsChanged() }
    .onChange(of: fullMotionEnabled) { _ in notifyMotionSettingsChanged() }
    .onChange(of: wiimoteIMUEnabled) { _ in notifyMotionSettingsChanged() }
    .onChange(of: nunchuckIMUEnabled) { _ in notifyMotionSettingsChanged() }
  }

  private func syncHorizontalMode() {
    horizontalMotionMode = useYawForHorizontal ? .yaw : .roll
  }

  private func syncIRMode() {
    let irModeRaw = DOLConfigBridge.mainTouchPadIRMode()
    currentIRMode = TouchIRMode.from(raw: irModeRaw)
  }

  /// Notify running emulator that motion settings have changed
  private func notifyMotionSettingsChanged() {
    NotificationCenter.default.post(
      name: Notification.Name("DOLMotionSettingsChanged"),
      object: nil
    )
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

