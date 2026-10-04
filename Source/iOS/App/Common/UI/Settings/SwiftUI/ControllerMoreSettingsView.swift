// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreHaptics
import GameController
import SwiftUI
import UIKit

/// Controller settings outside the hub's sections, pushed from its "More Controller Settings" row.
/// The pointer mode and its sensitivity live on the player screen (controller hub Phase 4).
struct ControllerMoreSettingsView: View {
  @State private var autoSelectOnScreenBySystem = true
  @State private var connectWiimotes = false
  @AppStorage("virtual_mfi_connect") private var mfiConnect = false
  /// Rumble destination, honored by the core rumble path (`Motor`): 0 device haptics, 1 controller,
  /// 2 both. tvOS has no device to hold, so the option is hidden there.
  @AppStorage("rumble_destination") private var rumbleDestination = 1
  @State private var backgroundInput = false
  @State private var wiimoteSpeaker = false
  #if os(iOS)
  @State private var touchOverlayProgrammatic = false
  /// Edit IR Area…, full screen so it edits on the canvas the game uses (`TouchOverlayLayoutEditorView`).
  @State private var showIRAreaEditor = false
  /// Connected pads with a light bar, for the LED colour rows.
  @State private var litControllers: [GCController] = []
  #endif

  var body: some View {
    List {
      Section(header: Text(L("General"))) {
        Toggle(L("Connect MFi Controllers"), isOn: $mfiConnect)
        Toggle(L("Background Input"), isOn: $backgroundInput)
          .onChange(of: backgroundInput) { _, enabled in DOLConfigBridge.setMainBackgroundInput(enabled) }
        #if os(iOS)
        Picker(L("Rumble Output"), selection: $rumbleDestination) {
          Text(L("Device Haptics")).tag(0)
          Text(L("Controller")).tag(1)
          Text(L("Both")).tag(2)
        }
        #endif
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
        Toggle(L("Enable Speaker"), isOn: $wiimoteSpeaker)
          .onChange(of: wiimoteSpeaker) { _, enabled in DOLConfigBridge.setWiimoteEnableSpeaker(enabled) }
        settingsCaption(
          Toggle(L("Connect Wiimotes for Controller Interface"), isOn: $connectWiimotes)
            .onChange(of: connectWiimotes) { _, newValue in
              DOLConfigBridge.setConnectWiimotesForControllerInterface(newValue)
            },
          L("Automatically pairs Wii Remotes when the controller interface is in use."))
      }

      Section(header: Text(L("Alternate Input Sources"))) {
        #if os(iOS)
        settingsCaption(
          Toggle(L("Programmatic touch overlay (beta)"), isOn: $touchOverlayProgrammatic)
            .onChange(of: touchOverlayProgrammatic) { _, newValue in
              TouchOverlayFlag.isProgrammatic = newValue
            },
          L("Replaces the on-screen GameCube/Wii pads with the new SwiftUI-rendered, user-editable overlay. Long-press the overlay in-game to move or resize its controls."))

        Button(role: .destructive) {
          for kind in TouchOverlayPadKind.allCases { TouchOverlayLayoutStore.shared.reset(padKind: kind) }
        } label: {
          Label(L("Reset All Overlay Layouts"), systemImage: "arrow.counterclockwise")
        }

        // Gated on the beta flag: these only affect the programmatic overlay's live rendering.
        if touchOverlayProgrammatic {
          Button {
            showIRAreaEditor = true
          } label: {
            Label(L("Edit IR Area…"), systemImage: "scope")
          }
        }
        #if DEBUG
        NavigationLink("Gallery") { TouchOverlayGalleryView() }
        #endif
        #endif

        NavigationLink(destination: EnhancedMotionControlsView()) {
          Label(L("Advanced Motion Settings"), systemImage: "gyroscope")
        }
        NavigationLink(destination: AnalogStickSettingsView()) {
          Label(L("Analog Stick Settings"), systemImage: "l.joystick")
        }
      }

      #if os(iOS)
      if !litControllers.isEmpty {
        Section(header: Text(L("Controller Lights"))) {
          ForEach(Array(litControllers.enumerated()), id: \.offset) { _, controller in
            if let light = controller.light {
              ColorPicker(controller.vendorName ?? controller.productCategory, selection: ledBinding(for: light))
            }
          }
        }
      }
      #endif
    }
    .navigationTitle(L("More Controller Settings"))
    .onAppear { syncFromConfig() }
    #if os(iOS)
    .fullScreenCover(isPresented: $showIRAreaEditor) {
      TouchOverlayLayoutEditorView(mode: .irArea, padKind: .wiiRemote, overGame: false) {
        showIRAreaEditor = false
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in reloadLitControllers() }
    .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in reloadLitControllers() }
    #endif
  }

  private func syncFromConfig() {
    if UserDefaults.standard.object(forKey: "auto_touchpad_by_system") == nil {
      UserDefaults.standard.set(true, forKey: "auto_touchpad_by_system")
    }
    autoSelectOnScreenBySystem = UserDefaults.standard.bool(forKey: "auto_touchpad_by_system")
    connectWiimotes = DOLConfigBridge.connectWiimotesForControllerInterface()
    #if os(iOS)
    touchOverlayProgrammatic = TouchOverlayFlag.isProgrammatic
    #endif
    backgroundInput = DOLConfigBridge.mainBackgroundInput()
    wiimoteSpeaker = DOLConfigBridge.wiimoteEnableSpeaker()
    #if os(iOS)
    reloadLitControllers()
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

  private func reloadLitControllers() {
    litControllers = GCController.controllers().filter { $0.light != nil }
  }

  /// Two-way bridge between SwiftUI's `Color` and a controller's `GCDeviceLight`.
  private func ledBinding(for light: GCDeviceLight) -> Binding<Color> {
    Binding(
      get: { Color(red: Double(light.color.red), green: Double(light.color.green), blue: Double(light.color.blue)) },
      set: { newColor in
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(newColor).getRed(&r, green: &g, blue: &b, alpha: &a)
        light.color = GCColor(red: Float(r), green: Float(g), blue: Float(b))
      })
  }
  #endif
}
