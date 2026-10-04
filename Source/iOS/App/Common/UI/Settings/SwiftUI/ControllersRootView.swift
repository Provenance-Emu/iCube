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
/// Opening it writes nothing: unused ports are under "Show All Ports".
struct ControllersRootView: View {
  var body: some View {
    ControllerHubView(system: .forSettings)
  }
}

#if os(iOS)
/// The on-screen controls editor: `TouchOverlayView` already in an edit mode, on the canvas the game
/// plays the controls on. The overlay is laid out inside the safe area with the real insets, exactly
/// as the game's `TouchPadsContainer` hosts it, so `TouchOverlayCanvas` gives the whole screen in both
/// and a layout lands on the same spot in play; only the backdrop ignores the safe area. The editor
/// used to be pushed under a navigation bar and a segmented picker, and positions stored as fractions
/// of that smaller rectangle moved (and sizes grew) when the game resumed.
///
/// Presented full screen: by the game screen over the running game (Edit Layout… in a game, a
/// long-press on the overlay), and by the Controllers hub and More Controller Settings outside one.
/// `TouchOverlayView.init(initialEditMode:)` suppresses every group's input while editing, so the
/// placeholder `deviceId: 0` is never written; `irMode: .none` because `TouchOverlayIRPadView`'s
/// `mode`/`isEditingFlag` `didSet`s both call `forceReleaseAndCenter()` on mount, and `.none` makes
/// both no-ops.
struct TouchOverlayLayoutEditorView: View {
  private let mode: TouchOverlayEditMode
  /// Drawn over the running game, which then also decides the pad. Elsewhere a picker chooses it.
  private let overGame: Bool
  private let onDone: () -> Void
  @State private var padKind: TouchOverlayPadKind

  /// - Parameter mode: `.layout` moves and resizes every group; `.irArea` (Edit IR Area…) only
  ///   reshapes the Wii Remote's IR pad, so it comes with `padKind: .wiiRemote`, the only pad kind
  ///   whose default layout has `wiiIRPad`.
  init(mode: TouchOverlayEditMode = .layout, padKind: TouchOverlayPadKind, overGame: Bool,
       onDone: @escaping () -> Void) {
    self.mode = mode
    self.overGame = overGame
    self.onDone = onDone
    _padKind = State(initialValue: padKind)
  }

  var body: some View {
    ZStack {
      // Over the game, a light scrim keeps the picture visible behind the controls being placed.
      Color.black.opacity(overGame ? 0.3 : 0.85)
        .ignoresSafeArea()
      TouchOverlayView(padKind: padKind, deviceId: 0, irMode: TCWiiTouchIRMode.none.rawValue,
                       initialEditMode: mode, onDone: onDone,
                       toolbarAccessory: overGame || mode != .layout ? nil : AnyView(padPicker))
        .id(padKind)
    }
    // The game hides the status bar; so does the editor, so both report the same top inset (it is
    // the status bar's height on a screen without a sensor housing) and lay defaults out alike.
    .statusBarHidden()
  }

  private var padPicker: some View {
    Picker(L("Layout"), selection: $padKind) {
      Text(L("GameCube")).tag(TouchOverlayPadKind.gameCube)
      Text(L("Wii Remote")).tag(TouchOverlayPadKind.wiiRemote)
      Text(L("Wii Remote (Sideways)")).tag(TouchOverlayPadKind.wiiRemoteSideways)
      Text(L("Wii + Classic Controller")).tag(TouchOverlayPadKind.wiiClassic)
    }
    .pickerStyle(.menu)
  }

  /// The pad the last game showed, so the editor opens on it outside a game: `ControllerManager`
  /// keeps the last game's system, and the Wii Remote on the touchscreen gives the variant (Classic
  /// Controller over sideways, as `TouchPadsContainer` picks it).
  static func lastPadKind() -> TouchOverlayPadKind {
    guard ControllerManager.shared.isWiiSystem else { return .gameCube }
    let slot = (ControllerManager.shared.touchscreenSlot(system: .wii) ?? 0) + 1
    return .wii(classicActive: WiimoteSlotOptions.selectedExtension(forWiimote: slot) == 2,
                sideways: WiimoteSlotOptions.isSideways(forWiimote: slot))
  }
}
#endif
