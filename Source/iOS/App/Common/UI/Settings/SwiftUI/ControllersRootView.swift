// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit
import QuartzCore
import PVWebServer
import PVHelp
#if os(iOS)
import SafariServices
import AudioToolbox
#endif
#if os(iOS)
#endif
import Foundation

// MARK: - Analog Stick Settings (dsu_* keys, applied in TCManagerInterface.setAxisValueFor:)

struct AnalogStickSettingsView: View {
  @State private var gain: Double = UserDefaults.standard.object(forKey: "dsu_gyro_gain") as? Double ?? 1.0
  @State private var deadzone: Double = UserDefaults.standard.object(forKey: "dsu_deadzone") as? Double ?? 0.05
  @State private var smoothing: Double = UserDefaults.standard.object(forKey: "dsu_smoothing") as? Double ?? 0.0
  var body: some View {
    Form {
      Section(header: Text(L("Analog Stick Gain"))) {
        settingsCaption(
          Group {
#if os(tvOS)
            TVFloatStepper(
              value: Binding(
                get: { CGFloat(gain) },
                set: { gain = Double($0) }
              ),
              range: 0.1...3.0,
              step: 0.05
            )
#else
            HStack {
              Slider(value: $gain, in: 0.1...3.0, step: 0.05)
              Text(String(format: "%.2f", gain)).frame(width: 50).monospacedDigit()
            }
#endif
          },
          L("Scales on-screen analog stick and trigger travel. Higher values reach full deflection sooner. Motion (gyro/accelerometer) and physical controllers are never scaled."))
      }
      Section(header: Text(L("Analog Stick Deadzone"))) {
        settingsCaption(
          Group {
#if os(tvOS)
            TVFloatStepper(
              value: Binding(
                get: { CGFloat(deadzone) },
                set: { deadzone = Double($0) }
              ),
              range: 0.0...0.49,
              step: 0.01
            )
#else
            HStack {
              Slider(value: $deadzone, in: 0.0...0.49, step: 0.01)
              Text(String(format: "%.2f", deadzone)).frame(width: 50).monospacedDigit()
            }
#endif
          },
          L("Ignores small stick movements to reduce drift."))
      }
      Section(header: Text(L("Analog Stick Smoothing"))) {
        settingsCaption(
          Group {
#if os(tvOS)
            TVFloatStepper(
              value: Binding(
                get: { CGFloat(smoothing) },
                set: { smoothing = Double($0) }
              ),
              range: 0.0...0.9,
              step: 0.05
            )
#else
            HStack {
              Slider(value: $smoothing, in: 0.0...0.9, step: 0.05)
              Text(String(format: "%.2f", smoothing)).frame(width: 50).monospacedDigit()
            }
#endif
          },
          L("Applies exponential smoothing to analog triggers. Sticks and motion are never smoothed. 0 disables smoothing."))
      }
    }
    .navigationTitle(L("Analog Stick Settings"))
    .onChange(of: gain) { UserDefaults.standard.set($0, forKey: "dsu_gyro_gain") }
    .onChange(of: deadzone) { UserDefaults.standard.set($0, forKey: "dsu_deadzone") }
    .onChange(of: smoothing) { UserDefaults.standard.set($0, forKey: "dsu_smoothing") }
  }
}

// MARK: - Controllers (Settings → Controllers)

/// Settings → Controllers is the Controllers hub, the same screen the pause menu and the top bar
/// open (controller hub spec, Phase 2). What the hub does not cover is behind its "More Controller
/// Settings" row (`ControllerMoreSettingsView`) and "Motion Source (DSU)" row (`DSUSettingsView`).
struct ControllersRootView: View {
  var body: some View {
    ControllerHubView(system: .forSettings, prepare: Self.ensureDefaultGCPlayer1)
  }

  /// If every GameCube port is off, turns Player 1 on as a GameCube Controller (raw
  /// `SIDEVICE_GC_CONTROLLER` is 6; the SI_Device.h enum is not sequential), as this screen always
  /// did on appear. Runs before the hub's first read, so the Player 1 row shows at once.
  private static func ensureDefaultGCPlayer1() {
    guard (1 ... 4).allSatisfy({ DOLConfigBridge.gcPortDevice(forPort: $0) == 0 }) else { return }
    DOLConfigBridge.setGCPortDeviceForPort(1, device: 6)
  }
}

enum TouchIRMode: Int, CaseIterable { case gyro = 0, follow = 1, drag = 2
  var label: String { switch self { case .gyro: return L("Gyro"); case .follow: return L("Follow"); case .drag: return L("Drag") } }
  static func from(raw: Int) -> TouchIRMode { TouchIRMode(rawValue: raw) ?? .drag }
}

struct TouchIRModePicker: View {
  @Binding var selected: TouchIRMode
  var body: some View {
    List {
      ForEach(Array(TouchIRMode.allCases.enumerated()), id: \.offset) { _, value in
        SettingsSelectRow(label: value.label, checked: value == selected) { selected = value; PointerModeController.shared.set(rawValue: value.rawValue) }
      }
    }
    .navigationTitle(L("Touch IR Pointer"))
  }
}

#if os(iOS)
/// The "Edit Layout…" preview (task item 3): the programmatic overlay already in `.layout` edit
/// mode, with no live game/device context. `TouchOverlayView.init(initialEditMode:)` makes this
/// safe: every group's input is suppressed while any edit mode is active. There is no live game to
/// infer the Wii variant from, so the picker chooses which of the four pad kinds to edit.
///
/// `irMode: .none` (task item 2's DSU pass) rather than the live `mainTouchPadIRMode()`:
/// `TouchOverlayIRPadView`'s `mode`/`isEditingFlag` `didSet`s both call `forceReleaseAndCenter()`
/// on mount, which wrote to the placeholder `deviceId: 0`. `.none` makes both true no-ops.
///
/// Pushed, not presented. It owns no `NavigationStack`, so the Controllers hub (itself a sheet from
/// the pause menu and the top bar) pushes it instead of nesting a sheet.
struct TouchOverlayLayoutEditorView: View {
  @State private var padKind: TouchOverlayPadKind = .gameCube

  var body: some View {
    VStack(spacing: 0) {
      Picker(L("Layout"), selection: $padKind) {
        Text(L("GameCube")).tag(TouchOverlayPadKind.gameCube)
        Text(L("Wii Remote")).tag(TouchOverlayPadKind.wiiRemote)
        Text(L("Wii Remote (Sideways)")).tag(TouchOverlayPadKind.wiiRemoteSideways)
        Text(L("Wii + Classic Controller")).tag(TouchOverlayPadKind.wiiClassic)
      }
      .pickerStyle(.segmented)
      .padding()

      TouchOverlayView(padKind: padKind, deviceId: 0,
                       irMode: TCWiiTouchIRMode.none.rawValue, initialEditMode: .layout)
        .id(padKind)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }
    .navigationTitle(L("Edit Layout"))
    .navigationBarTitleDisplayMode(.inline)
    #if DEBUG
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink("Gallery") { TouchOverlayGalleryView() }
      }
    }
    #endif
  }
}

/// The "Edit IR Area…" preview (task item 1): the same `TouchOverlayView`, seeded into `.irArea`
/// mode. Forces `padKind: .wiiRemote`: `wiiIRPad` exists only in that pad kind's default layout
/// (`TouchOverlayDefaults.wiiRemote`). `irMode: .none` for the same reason as the layout editor.
/// Pushed, like `TouchOverlayLayoutEditorView`.
struct TouchOverlayIRAreaEditorView: View {
  var body: some View {
    TouchOverlayView(padKind: .wiiRemote, deviceId: 0,
                     irMode: TCWiiTouchIRMode.none.rawValue, initialEditMode: .irArea)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black.opacity(0.85))
      .navigationTitle(L("Edit IR Area"))
      .navigationBarTitleDisplayMode(.inline)
  }
}
#endif
