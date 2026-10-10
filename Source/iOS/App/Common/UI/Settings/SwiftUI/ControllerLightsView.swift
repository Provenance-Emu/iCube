// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import GameController
import SwiftUI
import UIKit

/// One colour picker per connected controller that has a light bar, pushed from the hub's
/// "Controller Lights" row (shown only when a connected pad has one).
struct ControllerLightsView: View {
  /// Connected pads with a light bar.
  @State private var litControllers: [GCController] = []

  var body: some View {
    List {
      ForEach(Array(litControllers.enumerated()), id: \.offset) { _, controller in
        if let light = controller.light {
          ColorPicker(controller.vendorName ?? controller.productCategory, selection: ledBinding(for: light))
        }
      }
    }
    .navigationTitle(L("Controller Lights"))
    .onAppear { reloadLitControllers() }
    .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in reloadLitControllers() }
    .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in reloadLitControllers() }
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
}
#endif
