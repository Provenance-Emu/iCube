// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import GameController
import SwiftUI
import UIKit

/// Controller settings outside the hub's sections, pushed from its "More Controller Settings" row.
/// The pointer mode and its sensitivity live on the player screen (controller hub Phase 4).
struct ControllerMoreSettingsView: View {
  /// Rumble destination, honored by the core rumble path (`Motor`): 0 device haptics, 1 controller,
  /// 2 both. tvOS has no device to hold, so the option is hidden there.
  @AppStorage(RumbleDestination.defaultsKey) private var rumbleDestination = RumbleDestination.default.rawValue
  @State private var backgroundInput = false
  #if os(iOS)
  @AppStorage(ControllerManager.connectTakesPlayer1DefaultsKey) private var connectTakesPlayer1 = true
  @State private var touchOverlayProgrammatic = false
  /// Connected pads with a light bar, for the LED colour rows.
  @State private var litControllers: [GCController] = []
  #endif

  var body: some View {
    List {
      Section(header: Text(L("General"))) {
        Toggle(L("Background Input"), isOn: $backgroundInput.onSet { enabled in DOLConfigBridge.setMainBackgroundInput(enabled) })
        #if os(iOS)
        settingsCaption(
          Toggle(L("Controllers Take Player 1"), isOn: $connectTakesPlayer1),
          L("A controller that connects while the on-screen controls are Player 1 becomes Player 1, even if you chose the on-screen controls there."))
        Picker(L("Rumble Output"), selection: $rumbleDestination) {
          ForEach(RumbleDestination.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
        }
        #endif
        #if os(iOS)
        Button {
          RumbleTest.run()
        } label: {
          Label(L("Test Rumble"), systemImage: "waveform")
        }
        #endif
      }

      Section(header: Text(L("Alternate Input Sources"))) {
        #if os(iOS)
        settingsCaption(
          Toggle(L("Editable On-Screen Controls"), isOn: $touchOverlayProgrammatic)
            .onChange(of: touchOverlayProgrammatic) { _, newValue in
              TouchOverlayFlag.isProgrammatic = newValue
            },
          L("On by default: on-screen controls you can move and resize from Edit Layout or with a long press in-game. Turn off to use the older fixed pads."))

        Button(role: .destructive) {
          for kind in TouchOverlayPadKind.allCases { TouchOverlayLayoutStore.shared.reset(padKind: kind) }
        } label: {
          Label(L("Reset All Overlay Layouts"), systemImage: "arrow.counterclockwise")
        }

        #if DEBUG
        NavigationLink("Gallery") { TouchOverlayGalleryView() }
        #endif
        #endif

        NavigationLink(destination: EnhancedMotionControlsView()) {
          Label(L("Advanced Motion Settings"), systemImage: "gyroscope")
        }
        NavigationLink(destination: AnalogStickSettingsView()) {
          Label(L("On-Screen Stick Feel"), systemImage: "l.joystick")
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
    .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in reloadLitControllers() }
    .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in reloadLitControllers() }
    #endif
  }

  private func syncFromConfig() {
    #if os(iOS)
    touchOverlayProgrammatic = TouchOverlayFlag.isProgrammatic
    #endif
    backgroundInput = DOLConfigBridge.mainBackgroundInput()
    #if os(iOS)
    reloadLitControllers()
    #endif
  }

  #if os(iOS)
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
