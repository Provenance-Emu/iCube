// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import GameController

#if os(iOS)
struct DSUControllerView: View {
  let onClose: () -> Void
  @State private var virtualController: GCVirtualController?
  @State private var showMotionSheet = false
  @State private var irModeLabel: String = ""

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      VStack(spacing: 24) {
        Image(systemName: "gamecontroller.fill").font(.system(size: 48)).foregroundColor(.white.opacity(0.8))
        Text(L("On‑Screen Controller Active"))
          .font(.title2).foregroundColor(.white)
        Text(L("Inputs are being sent over DSU to the connected client."))
          .font(.footnote).foregroundColor(.white.opacity(0.7))
      }
    }
    .onAppear { startVirtualController(); refreshIRLabel() }
    .onDisappear { stopVirtualController() }
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        Button(action: toggleIRMode) {
          Label(irModeLabel, systemImage: "gyroscope")
        }
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(action: { showMotionSheet = true }) {
          Label(L("Motion"), systemImage: "slider.horizontal.3")
        }
      }
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(action: onClose) { Label(L("Exit"), systemImage: "xmark") }
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showMotionSheet) { MotionQuickSettingsView() }
  }

  private func startVirtualController() {
    guard virtualController == nil else { return }
    let cfg = GCVirtualController.Configuration()
    cfg.elements = [
      GCInputLeftThumbstick, GCInputRightThumbstick,
      GCInputLeftShoulder, GCInputRightShoulder,
      GCInputLeftTrigger, GCInputRightTrigger,
      GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY,
      GCInputDirectionalDpad, GCInputButtonMenu
    ]
    let vc = GCVirtualController(configuration: cfg)
    vc.connect()
    virtualController = vc
  }

  private func stopVirtualController() {
    virtualController?.disconnect()
    virtualController = nil
  }

  private func refreshIRLabel() {
    let raw = DOLConfigBridge.mainTouchPadIRMode()
    irModeLabel = (raw == 0) ? L("Gyro") : (raw == 1 ? L("Follow") : L("Drag"))
  }

  private func toggleIRMode() {
    let raw = DOLConfigBridge.mainTouchPadIRMode()
    // Cycle: gyro(0) -> follow(1) -> drag(2) -> gyro(0)
    let next = (raw + 1) % 3
    DOLConfigBridge.setMainTouchPadIRMode(next)
    refreshIRLabel()
  }
}

private struct MotionQuickSettingsView: View {
  @State private var gain: Double = UserDefaults.standard.object(forKey: "dsu_gyro_gain") as? Double ?? 1.0
  @State private var deadzone: Double = UserDefaults.standard.object(forKey: "dsu_deadzone") as? Double ?? 0.05
  @State private var smoothing: Double = UserDefaults.standard.object(forKey: "dsu_smoothing") as? Double ?? 0.0
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        Section(header: Text(L("Gyro Gain"))) {
          HStack {
            Slider(value: $gain, in: 0.1...3.0, step: 0.05)
            Text(String(format: "%.2f", gain)).frame(width: 50).monospacedDigit()
          }
        }
        Section(header: Text(L("Deadzone"))) {
          HStack {
            Slider(value: $deadzone, in: 0.0...0.49, step: 0.01)
            Text(String(format: "%.2f", deadzone)).frame(width: 50).monospacedDigit()
          }
        }
        Section(header: Text(L("Smoothing"))) {
          HStack {
            Slider(value: $smoothing, in: 0.0...0.9, step: 0.05)
            Text(String(format: "%.2f", smoothing)).frame(width: 50).monospacedDigit()
          }
        }
      }
      .navigationTitle(L("Motion Settings"))
      .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L("Done")) { dismiss() } } }
      .onChange(of: gain) { UserDefaults.standard.set($0, forKey: "dsu_gyro_gain") }
      .onChange(of: deadzone) { UserDefaults.standard.set($0, forKey: "dsu_deadzone") }
      .onChange(of: smoothing) { UserDefaults.standard.set($0, forKey: "dsu_smoothing") }
    }
  }
}
#endif
