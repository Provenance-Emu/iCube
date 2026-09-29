// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreHaptics
import GameController
import SwiftUI
import UIKit

/// Controller settings outside the hub's four sections, pushed from its "More Controller Settings"
/// row. Everything here was on Settings → Controllers before the hub. Controller hub Phase 4
/// removes what the player screen replaces (the pointer-mode picker, Advanced Motion Settings).
struct ControllerMoreSettingsView: View {
  @State private var autoSelectOnScreenBySystem = true
  @State private var connectWiimotes = false
  @State private var touchIRMode: TouchIRMode = .drag
  #if os(iOS)
  @State private var touchOverlayProgrammatic = false
  /// Raw `TouchOverlayArt.Style` integer (`touch_overlay_style`).
  @State private var touchOverlayStyle = 0
  @State private var touchOverlayIRPointerGain = 1.0
  #endif

  var body: some View {
    List {
      Section(header: Text(L("General"))) {
        settingsCaption(
          Toggle(L("Auto‑select On‑Screen Controller by System"), isOn: $autoSelectOnScreenBySystem)
            .onChange(of: autoSelectOnScreenBySystem) { _, newValue in
              UserDefaults.standard.set(newValue, forKey: "auto_touchpad_by_system")
            },
          L("Automatically shows the GameCube or Wii on-screen layout based on the game being played."))
        #if os(iOS)
        Button {
          Self.testRumble()
        } label: {
          Label(L("Test Rumble"), systemImage: "waveform")
        }
        #endif
      }

      Section(header: Text(L("Wii Remotes"))) {
        settingsCaption(
          Toggle(L("Connect Wiimotes for Controller Interface"), isOn: $connectWiimotes)
            .onChange(of: connectWiimotes) { _, newValue in
              DOLConfigBridge.setConnectWiimotesForControllerInterface(newValue)
            },
          L("Automatically pairs Wii Remotes when the controller interface is in use."))
      }

      Section(header: Text(L("Alternate Input Sources"))) {
        // TouchIRModePicker's rows set the mode through PointerModeController themselves.
        settingsNavCaption(
          destination: TouchIRModePicker(selected: $touchIRMode),
          L("How the Wii Remote pointer is driven. Gyro uses device motion; Follow/Drag use touch gestures.")
        ) {
          Text("\(L("Touch IR Pointer")): \(touchIRMode.label)")
        }

        #if os(iOS)
        settingsCaption(
          Toggle(L("Programmatic touch overlay (beta)"), isOn: $touchOverlayProgrammatic)
            .onChange(of: touchOverlayProgrammatic) { _, newValue in
              UserDefaults.standard.set(newValue, forKey: "touch_overlay_programmatic")
            },
          L("Replaces the on-screen GameCube/Wii pads with the new SwiftUI-rendered, user-editable overlay. Long-press the overlay in-game to move or resize its controls."))

        settingsCaption(
          Picker(L("Overlay Style"), selection: $touchOverlayStyle) {
            Text(L("Auto")).tag(0)
            Text(L("GameCube")).tag(1)
            Text(L("Wii")).tag(2)
          }
          .pickerStyle(.segmented)
          .onChange(of: touchOverlayStyle) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "touch_overlay_style")
          },
          L("Overrides whether the programmatic overlay's button art uses GameCube or Wii coloring, or matches the pad kind automatically."))

        Button(role: .destructive) {
          for kind in TouchOverlayPadKind.allCases { TouchOverlayLayoutStore.shared.reset(padKind: kind) }
        } label: {
          Label(L("Reset All Overlay Layouts"), systemImage: "arrow.counterclockwise")
        }

        // Gated on the beta flag: these only affect the programmatic overlay's live rendering.
        if touchOverlayProgrammatic {
          NavigationLink {
            TouchOverlayIRAreaEditorView()
          } label: {
            Label(L("Edit IR Area…"), systemImage: "scope")
          }

          settingsCaption(
            HStack {
              Text(L("Pointer Sensitivity"))
              Spacer()
              Slider(
                value: $touchOverlayIRPointerGain,
                in: Double(TouchOverlayIRGeometry.dragGainRange.lowerBound) ... Double(TouchOverlayIRGeometry.dragGainRange.upperBound))
                .frame(width: 220)
                .onChange(of: touchOverlayIRPointerGain) { _, gain in
                  UserDefaults.standard.set(gain, forKey: MotionSettings.Key.irPointerGain)
                }
            },
            L("Scales how far the Wii Remote pointer moves per drag in Drag mode. Doesn't affect Follow or Gyro mode."))
        }
        #endif

        NavigationLink(destination: EnhancedMotionControlsView()) {
          Label(L("Advanced Motion Settings"), systemImage: "gyroscope")
        }
        NavigationLink(destination: AnalogStickSettingsView()) {
          Label(L("Analog Stick Settings"), systemImage: "l.joystick")
        }
      }
    }
    .navigationTitle(L("More Controller Settings"))
    .onAppear { syncFromConfig() }
  }

  private func syncFromConfig() {
    if UserDefaults.standard.object(forKey: "auto_touchpad_by_system") == nil {
      UserDefaults.standard.set(true, forKey: "auto_touchpad_by_system")
    }
    autoSelectOnScreenBySystem = UserDefaults.standard.bool(forKey: "auto_touchpad_by_system")
    connectWiimotes = DOLConfigBridge.connectWiimotesForControllerInterface()
    touchIRMode = TouchIRMode.from(raw: DOLConfigBridge.mainTouchPadIRMode())
    #if os(iOS)
    touchOverlayProgrammatic = UserDefaults.standard.bool(forKey: "touch_overlay_programmatic")
    touchOverlayStyle = UserDefaults.standard.integer(forKey: "touch_overlay_style")
    touchOverlayIRPointerGain = Double(TouchOverlayIRGeometry.clampDragGain(MotionSettings.irPointerGain()))
    #endif
  }

  #if os(iOS)
  /// Pulses every connected controller's haptics and the device's, then reports what fired.
  private static func testRumble() {
    var controllersTestedCount = 0
    var deviceTested = false
    for controller in GCController.controllers() {
      guard let haptics = controller.haptics, let engine = haptics.createEngine(withLocality: .default) else { continue }
      do {
        try engine.start()
        let pattern = try CHHapticPattern(events: [
          CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8),
          ], relativeTime: 0),
        ], parameters: [])
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: 0)
        controllersTestedCount += 1
      } catch {}
    }
    if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
      do {
        let engine = try CHHapticEngine()
        try engine.start()
        let pattern = try CHHapticPattern(events: [
          CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0),
          ], relativeTime: 0),
        ], parameters: [])
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: 0)
        deviceTested = true
      } catch {}
    }
    let message: String
    if controllersTestedCount > 0 && deviceTested {
      message = String(format: L("Tested %d controller(s) + device rumble"), controllersTestedCount)
    } else if controllersTestedCount > 0 {
      message = String(format: L("Tested %d controller(s) rumble"), controllersTestedCount)
    } else if deviceTested {
      message = L("Tested device rumble")
    } else {
      message = L("No haptic feedback available")
    }
    NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": message])
  }
  #endif
}
