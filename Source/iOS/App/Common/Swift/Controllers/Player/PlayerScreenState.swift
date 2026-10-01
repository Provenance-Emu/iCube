// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// What the Device list offers and selects.
enum PlayerDeviceChoice: Hashable {
  case noDevice
  case touchscreen
  /// A pad's Dolphin qualifier (`MFi/0/Xbox Wireless Controller`, `DSUClient/0/Pad C`).
  case pad(String)

  init(qualifier: String) {
    if qualifier.isEmpty {
      self = .noDevice
    } else if DeviceFamily.from(qualifier: qualifier) == .touchscreen {
      self = .touchscreen
    } else {
      self = .pad(qualifier)
    }
  }
}

/// One row of the Device list.
struct DeviceOption: Equatable {
  let choice: PlayerDeviceChoice
  let title: String
}

extension PlayerSlot {
  /// Same value as `PlayerState.id`.
  var playerID: String { (kind == .gameCube ? "gc-" : "wii-") + String(port) }
  /// "Player 1" / "Wii Remote 1": the hub's row titles.
  var title: String { String(format: kind == .gameCube ? L("Player %d") : L("Wii Remote %d"), port) }
}

extension RemapControlRow {
  /// The expression as editable text. The bridges report an unbound control as "—"
  /// (TVControllerMappingBridge.mm:529), which must never be saved back as a literal.
  var editableExpression: String { expression == RemapExpression.unboundDisplay ? "" : expression }
}

/// Pointer & Motion on the touchscreen's port, read from `PointerModeController` and
/// `MotionSettings`.
struct PointerMotionState: Equatable {
  var pointerMode: PointerMode
  /// `motion_invert_roll`: the gyro pointer's left/right.
  var invertX: Bool
  /// `motion_invert_pitch`: the gyro pointer's up/down.
  var invertY: Bool
  /// `motion_enhanced_shake_detection`: shaking the device shakes the Wii Remote.
  var shakeToWiggle: Bool
  /// `touch_overlay_ir_pointer_gain`, snapped to one of `dragGainChoices`.
  var dragGain: Double
  /// `motion_gyro_pointer_sensitivity`, snapped to one of `gyroSensitivityChoices`.
  var gyroSensitivity: Double
  /// The drag gain is read only by the programmatic overlay (`TouchOverlayView.swift:182`), which
  /// is off by default.
  var usesProgrammaticOverlay: Bool

  /// Registered as false by `DefaultPreferences.plist`; toggled in More Controller Settings.
  static let programmaticOverlayKey = "touch_overlay_programmatic"
  /// Steps across `TouchOverlayIRGeometry.dragGainRange` (0.25...4).
  static let dragGainChoices: [Double] = [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4]
  /// Multipliers on the gyro pointer's fixed constants; 1 is the behaviour before the setting.
  static let gyroSensitivityChoices: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3]

  static let standard = PointerMotionState(
    pointerMode: .touchFollow, invertX: false, invertY: false, shakeToWiggle: true, dragGain: 1,
    gyroSensitivity: 1, usesProgrammaticOverlay: false)

  /// The nearest choice. A missing or broken stored value reads as 1×, as
  /// `TouchOverlayIRGeometry.clampDragGain` does.
  static func snapped(_ raw: Double, to choices: [Double]) -> Double {
    guard raw.isFinite, raw > 0 else { return 1 }
    return choices.min { abs($0 - raw) < abs($1 - raw) } ?? 1
  }
}

/// One Advanced group: its title and numeric settings.
struct AdvancedGroupState: Equatable {
  let owner: RemapGroupOwner
  let groupId: Int
  let title: String
  let settings: [NumericSettingState]
}

/// Plain snapshot of one player's screen. `PlayerScreenViewModel` rebuilds it; the builder reads
/// nothing else.
struct PlayerScreenState: Equatable {
  /// Filled through the hub's `ControllerHubReading`, exactly as the hub's own row is.
  var player: PlayerState
  var pads: [ConnectedPadState]
  /// nil: not known this session ("Custom").
  var profileName: String?
  var profileEdited: Bool
  /// Every control of the port's groups (`RemapGroup.groups(for:attachment:)`), in group order.
  var controls: [RemapControlRow]
  /// The armed capture row's `RemapControlRow.id`.
  var armedControlID: String?
  var pointerMotion: PointerMotionState
  /// The Wii Remote's IMU pointer (`IMUIR/Enabled`), for a gyro pad's port.
  var motionPointerEnabled: Bool
  /// UI state, kept across reloads.
  var showsAdvanced: Bool
  var advanced: [AdvancedGroupState]

  static func empty(_ player: PlayerState) -> PlayerScreenState {
    PlayerScreenState(
      player: player, pads: [], profileName: nil, profileEdited: false, controls: [], armedControlID: nil,
      pointerMotion: .standard, motionPointerEnabled: false, showsAdvanced: false, advanced: [])
  }

  /// Dolphin's MFi qualifier prefix: the only devices that come and go with `GCController`.
  static let mfiPrefix = "MFi/"

  /// A bound MFi pad that is not connected. DSU devices are not `GCController`s, so the pad list
  /// never holds them, and they are never "missing" here (decision 11).
  static func isMissing(_ qualifier: String, pads: [ConnectedPadState]) -> Bool {
    qualifier.hasPrefix(mfiPrefix) && !pads.contains { $0.qualifier == qualifier }
  }

  var deviceChoice: PlayerDeviceChoice { PlayerDeviceChoice(qualifier: player.deviceQualifier) }
  var boundPad: ConnectedPadState? { pads.first { $0.qualifier == player.deviceQualifier } }
  var isTouchscreen: Bool { deviceChoice == .touchscreen }

  /// Bound to an MFi pad that is not connected. The binding is kept and comes back with the pad.
  var isDisconnected: Bool { Self.isMissing(player.deviceQualifier, pads: pads) }

  /// Capture listens to a real device: any non-touchscreen qualifier (MFi or DSU, as
  /// `RemapPlayerView.deviceIsPhysical`), except an MFi pad that is not connected.
  var canCapture: Bool {
    if case .pad = deviceChoice { return !isDisconnected }
    return false
  }

  var isCapturing: Bool { armedControlID != nil }
}

/// Plain closures: no bridge calls inside `PlayerScreenModelBuilder`. Destinations are factories so
/// the builder never names a bridge-backed view.
struct PlayerScreenActions {
  /// Pushes the Device list (decision 9).
  var deviceListDestination: () -> AnyView
  var profileListDestination: () -> AnyView
  /// Opens the host's Save Profile As… prompt.
  var saveProfileAs: () -> Void
  /// Asks to reset (decision 10); the host's confirmation does the load.
  var resetProfile: () -> Void
  var setExtension: (Int) -> Void
  var setSideways: (Bool) -> Void
  /// Arms the row's capture, or cancels it when that row is the armed one.
  var toggleCapture: (RemapControlRow) -> Void
  var clearBinding: (RemapControlRow) -> Void
  var setPointerMode: (PointerMode) -> Void
  var recenterPointer: () -> Void
  var setDragGain: (Double) -> Void
  var setGyroSensitivity: (Double) -> Void
  var setInvertX: (Bool) -> Void
  var setInvertY: (Bool) -> Void
  var setShakeToWiggle: (Bool) -> Void
  /// The gyro pad port's "Aim with Controller Motion".
  var setMotionPointer: (Bool) -> Void
  var toggleAdvanced: () -> Void
  var setNumericSetting: (NumericSettingState, Double) -> Void
  var expressionDestination: (RemapControlRow) -> AnyView
}
