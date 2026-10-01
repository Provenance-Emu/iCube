// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import GameController
import SwiftUI

/// Everything the player screen reads and writes beyond `ControllerHubReading`, behind one seam, so
/// `PlayerScreenViewModel` is testable without the core, the bridges or real pads. Ports are 1-based.
@MainActor
protocol PlayerScreenIO {
  // Reads
  func controlRows(owner: RemapGroupOwner, group: Int, port: Int) -> [RemapControlRow]
  func numericSettings(owner: RemapGroupOwner, group: Int, port: Int) -> [NumericSettingState]
  func profiles(for slot: PlayerSlot) -> [String]
  /// The profile a device gets when first bound ("Physical Controller", "Touchscreen", "DSU").
  func defaultProfileName(forQualifier qualifier: String) -> String?
  /// The port already has a mapping, so binding a device keeps it (`ControllerAssignmentService`).
  func hasAnyBinding(_ slot: PlayerSlot) -> Bool
  func isMotionPointerEnabled(wiimote: Int) -> Bool
  func pointerMotion() -> PointerMotionState
  func inputNames(forQualifier qualifier: String) -> [String]
  func inputStates(forQualifier qualifier: String) -> [Float]
  func check(_ expression: String) -> ExpressionCheck

  // Writes
  func setDevice(_ choice: PlayerDeviceChoice, slot: PlayerSlot)
  func loadProfile(_ name: String, slot: PlayerSlot) -> Bool
  func saveProfile(_ name: String, slot: PlayerSlot) -> Bool
  func setExtension(_ value: Int, wiimote: Int)
  func setSideways(_ enabled: Bool, wiimote: Int)
  func setExpression(_ expression: String, for row: RemapControlRow, port: Int)
  func setNumericSetting(_ setting: NumericSettingState, value: Double, port: Int)
  func setMotionPointerEnabled(_ enabled: Bool, wiimote: Int)
  func setPointerMode(_ mode: PointerMode)
  func recenterPointer()
  func setInvertX(_ enabled: Bool)
  func setInvertY(_ enabled: Bool)
  func setShakeToWiggle(_ enabled: Bool)
  func setDragGain(_ gain: Double)
  func setGyroSensitivity(_ gain: Double)
}

extension RemapGroupOwner {
  /// The bridge's spelling of the same owner.
  var controlGroupOwner: ControlGroupOwner {
    switch self {
    case .gcPad: return .gcPad
    case .wiimote: return .wiimote
    case .nunchuk: return .nunchuk
    case .classic: return .classic
    }
  }
}

/// The live seam. Together with `LiveControllerHubReader`, the only player-screen code that touches
/// `ControllerManager`, `TVControllerMappingBridge`, `DOLControllerSettingsBridge`,
/// `PointerModeController`, `MotionSettings`, `TCDeviceMotion` and `GCController`.
struct LivePlayerScreenIO: PlayerScreenIO {
  /// Explicit and `nonisolated`, as `LiveControllerHubReader.init` is, so it can be a default
  /// argument of the main-actor view model's `init`.
  nonisolated init() {} // swiftlint:disable:this unneeded_synthesized_initializer

  // MARK: Reads

  func controlRows(owner: RemapGroupOwner, group: Int, port: Int) -> [RemapControlRow] {
    let names: [String]
    let expressions: [String]
    switch owner {
    case .gcPad:
      names = TVControllerMappingBridge.padControlNames(forGroup: port, group: group) as [String]
      expressions = TVControllerMappingBridge.padControlExpressions(forGroup: port, group: group) as [String]
    case .wiimote:
      names = TVControllerMappingBridge.wiimoteControlNames(forGroup: port, group: group) as [String]
      expressions = TVControllerMappingBridge.wiimoteControlExpressions(forGroup: port, group: group) as [String]
    case .nunchuk:
      names = TVControllerMappingBridge.wiimoteExtensionControlNames(forIndex: port, kind: .nunchuk, group: group) as [String]
      expressions = TVControllerMappingBridge.wiimoteExtensionControlExpressions(forIndex: port, kind: .nunchuk, group: group) as [String]
    case .classic:
      names = TVControllerMappingBridge.wiimoteExtensionControlNames(forIndex: port, kind: .classic, group: group) as [String]
      expressions = TVControllerMappingBridge.wiimoteExtensionControlExpressions(forIndex: port, kind: .classic, group: group) as [String]
    }
    return names.enumerated().map { index, name in
      RemapControlRow(
        owner: owner, groupId: group, index: index, name: name,
        expression: index < expressions.count ? expressions[index] : RemapExpression.unboundDisplay)
    }
  }

  func numericSettings(owner: RemapGroupOwner, group: Int, port: Int) -> [NumericSettingState] {
    DOLControllerSettingsBridge.numericSettings(owner: owner.controlGroupOwner, port: port, group: group).map { info in
      NumericSettingState(
        owner: owner, groupId: group, index: info.index, name: info.name, suffix: info.suffix,
        isToggle: info.type == .bool, isInteger: info.type == .int, value: info.value, minimum: info.minimum,
        maximum: info.maximum, defaultValue: info.defaultValue, isExpression: info.isExpression)
    }
  }

  func profiles(for slot: PlayerSlot) -> [String] {
    slot.kind == .gameCube
      ? TVControllerMappingBridge.profiles(forGCPort: slot.port) as [String]
      : TVControllerMappingBridge.profiles(forWiimote: slot.port) as [String]
  }

  func defaultProfileName(forQualifier qualifier: String) -> String? {
    BridgeControllerConfigWriter().defaultProfileName(forQualifier: qualifier)
  }

  func hasAnyBinding(_ slot: PlayerSlot) -> Bool {
    slot.kind == .gameCube
      ? TVControllerMappingBridge.padHasAnyBinding(forGCPort: slot.port)
      : TVControllerMappingBridge.wiimoteHasAnyBinding(forWiimote: slot.port)
  }

  func isMotionPointerEnabled(wiimote: Int) -> Bool {
    DOLControllerSettingsBridge.isGroupEnabled(owner: .wiimote, port: wiimote, group: AdvancedSettingGroups.imuPointGroup)
  }

  func pointerMotion() -> PointerMotionState {
    PointerMotionState(
      pointerMode: PointerModeController.shared.mode,
      invertX: MotionSettings.invertRoll(),
      invertY: MotionSettings.invertPitch(),
      shakeToWiggle: MotionSettings.enhancedShakeDetection(),
      dragGain: PointerMotionState.snapped(MotionSettings.irPointerGain(), to: PointerMotionState.dragGainChoices),
      gyroSensitivity: PointerMotionState.snapped(
        MotionSettings.gyroPointerSensitivity(), to: PointerMotionState.gyroSensitivityChoices),
      usesProgrammaticOverlay: UserDefaults.standard.bool(forKey: PointerMotionState.programmaticOverlayKey))
  }

  func inputNames(forQualifier qualifier: String) -> [String] {
    TVControllerMappingBridge.inputs(forQualifiedDevice: qualifier) as [String]
  }

  func inputStates(forQualifier qualifier: String) -> [Float] {
    TVControllerMappingBridge.inputStates(forQualifiedDevice: qualifier).map { $0.floatValue }
  }

  func check(_ expression: String) -> ExpressionCheck {
    let result = DOLControllerSettingsBridge.parse(expression: expression)
    return ExpressionCheck(parseStatus: result.status, parserMessage: result.message)
  }

  // MARK: Writes

  /// Through `ControllerManager`'s explicit-choice wrappers, each of which ends in
  /// `reconcile(autoAssign: false)` (ControllerManager.swift:484-542): changing this port never
  /// re-assigns the others.
  func setDevice(_ choice: PlayerDeviceChoice, slot: PlayerSlot) {
    let manager = ControllerManager.shared
    switch choice {
    case .noDevice:
      if slot.kind == .gameCube {
        manager.clearDefaultDevice(forGCPort: slot.port)
      } else {
        manager.clearDefaultDevice(forWiimote: slot.port)
      }
    case .touchscreen:
      if slot.kind == .gameCube {
        manager.assignTouchscreen(toGCPort: slot.port)
      } else {
        manager.assignTouchscreen(toWiimote: slot.port)
      }
    case .pad(let qualifier):
      // Only a connected GCController can be picked; the list shows a DSU or disconnected device
      // only as the current one, and picking the current device is a no-op upstream.
      guard let controller = GCController.controllers().first(where: {
        (TVControllerMappingBridge.qualifiedName(for: $0) as String) == qualifier
      }) else { return }
      if slot.kind == .gameCube {
        manager.assign(controller, toGCPort: slot.port)
      } else {
        manager.assign(controller, toWiimote: slot.port)
      }
    }
  }

  func loadProfile(_ name: String, slot: PlayerSlot) -> Bool {
    let loaded = slot.kind == .gameCube
      ? TVControllerMappingBridge.loadProfile(name, forGCPort: slot.port, restoreDevice: true)
      : TVControllerMappingBridge.loadProfile(name, forWiimote: slot.port, restoreDevice: true)
    // autoAssign: false — loading a profile for THIS port must not re-decide every other port's
    // device (the "profiles loading weird" bug, RemapPlayerView.swift:586-591).
    ControllerManager.shared.reconcile(autoAssign: false)
    return loaded
  }

  func saveProfile(_ name: String, slot: PlayerSlot) -> Bool {
    slot.kind == .gameCube
      ? TVControllerMappingBridge.saveProfile(name, forGCPort: slot.port)
      : TVControllerMappingBridge.saveProfile(name, forWiimote: slot.port)
  }

  /// `WiimoteSlotOptions` already ends in `reconcile(autoAssign: false)`.
  func setExtension(_ value: Int, wiimote: Int) { WiimoteSlotOptions.setExtension(value, forWiimote: wiimote) }
  func setSideways(_ enabled: Bool, wiimote: Int) { WiimoteSlotOptions.setSideways(enabled, forWiimote: wiimote) }

  func setExpression(_ expression: String, for row: RemapControlRow, port: Int) {
    switch row.owner {
    case .gcPad:
      TVControllerMappingBridge.setPadControlExpressionForPort(port, group: row.groupId, index: row.index, expression: expression)
    case .wiimote:
      TVControllerMappingBridge.setWiimoteControlExpressionFor(port, group: row.groupId, index: row.index, expression: expression)
    case .nunchuk:
      TVControllerMappingBridge.setWiimoteExtensionControlExpressionFor(
        port, kind: .nunchuk, group: row.groupId, index: row.index, expression: expression)
    case .classic:
      TVControllerMappingBridge.setWiimoteExtensionControlExpressionFor(
        port, kind: .classic, group: row.groupId, index: row.index, expression: expression)
    }
  }

  func setNumericSetting(_ setting: NumericSettingState, value: Double, port: Int) {
    DOLControllerSettingsBridge.setNumericSetting(
      value, index: setting.index, owner: setting.owner.controlGroupOwner, port: port, group: setting.groupId)
  }

  func setMotionPointerEnabled(_ enabled: Bool, wiimote: Int) {
    DOLControllerSettingsBridge.setGroupEnabled(enabled, owner: .wiimote, port: wiimote, group: AdvancedSettingGroups.imuPointGroup)
  }

  func setPointerMode(_ mode: PointerMode) { PointerModeController.shared.set(mode) }

  func recenterPointer() {
    #if os(iOS)
    TCDeviceMotion.requestPointerRecenter()
    #endif
  }

  /// Read on every motion sample (TCDeviceMotion.handleIRCursorMapping): no restart needed.
  func setInvertX(_ enabled: Bool) { MotionSettings.setInvertRoll(enabled) }
  func setInvertY(_ enabled: Bool) { MotionSettings.setInvertPitch(enabled) }

  /// The emulation screen decides from this whether the motion system runs at all, at boot and on
  /// `.DOLMotionSettingsChanged` (EmulationScreen.swift:1079, :1102-1112).
  func setShakeToWiggle(_ enabled: Bool) {
    MotionSettings.setEnhancedShakeDetection(enabled)
    NotificationCenter.default.post(name: .DOLMotionSettingsChanged, object: nil)
  }

  /// Read by the programmatic overlay each time it renders; nothing to restart.
  func setDragGain(_ gain: Double) { MotionSettings.setIRPointerGain(gain) }

  /// Read on every motion sample (Task 6): nothing to restart.
  func setGyroSensitivity(_ gain: Double) { MotionSettings.setGyroPointerSensitivity(gain) }
}
