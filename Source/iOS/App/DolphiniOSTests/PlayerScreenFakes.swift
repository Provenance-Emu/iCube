// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

// Fakes for the hub / player-screen seams, shared by the player screen, hub and live-writer tests.

@MainActor
final class FakePlayerHubReader: ControllerHubReading {
  var gameCube: [Int: String] = [:]
  var wii: [Int: String] = [:]
  var extensions: [Int: Int] = [:]
  var pads: [ConnectedPadState] = []

  func boundQualifier(forGCPort port: Int) -> String { gameCube[port] ?? "" }
  func boundQualifier(forWiimote index: Int) -> String { wii[index] ?? "" }
  func wiiExtension(forWiimote index: Int) -> Int { extensions[index] ?? 0 }
  func isSideways(forWiimote index: Int) -> Bool { false }
  func connectedPads() -> [ConnectedPadState] { pads }
  func isGameRunning() -> Bool { false }
  func overlayVisible() -> Bool { false }
  func overlayMode() -> ControllerManager.OverlayMode { .auto }
  func overlayOpacity() -> Float { 1 }
  func dsuClientEnabled() -> Bool { false }
  func dsuServerCount() -> Int { 0 }
  func isPinned(_ slot: PlayerSlot) -> Bool { false }
  func isMotionPointerEnabled(wiimote: Int) -> Bool { false }
  func pointerMode() -> PointerMode { .touchFollow }
  func pointerIsThisGameOnly() -> Bool { false }
  func backgroundInput() -> Bool { false }
  func rumbleDestination() -> RumbleDestination { .controller }
  func connectTakesPlayer1() -> Bool { true }
  func touchOverlayProgrammatic() -> Bool { true }
}

@MainActor
final class FakePlayerScreenIO: PlayerScreenIO {
  /// "owner-group" for each `controlRows` read, in order.
  var groupReads: [String] = []
  /// Every write, as "kind:detail".
  var writes: [String] = []
  var deviceInputs = ["Button A", "Button B"]
  var inputValues: [Float] = [0, 0]
  /// What `ControllerAssignmentService.assign` does to the port on a pad bind: true loads the pad's
  /// default profile over the mapping (the old mapping bound nothing on the pad), false keeps it.
  var assignmentReplacesMapping = false
  var boundExpression = "`Button A`"
  var saveSucceeds = true
  var existingProfiles = ["Physical Controller", "Mine"]
  /// Saved profiles the list hides for the bound device (a pad profile on a touchscreen slot).
  var hiddenProfiles: [String] = []
  var parsable: Set<String> = ["`Button B`", ""]
  /// Lets a test make the reader follow a device change, as the real config does.
  var onSetDevice: ((PlayerDeviceChoice) -> Void)?
  /// The same, with the slot (the real binding depends on the slot's kind).
  var onSetDeviceForSlot: ((PlayerDeviceChoice, PlayerSlot) -> Void)?

  func controlRows(owner: RemapGroupOwner, group: Int, port: Int) -> [RemapControlRow] {
    groupReads.append("\(owner)-\(group)")
    return [RemapControlRow(owner: owner, groupId: group, index: 0, name: "Control", expression: boundExpression)]
  }

  func numericSettings(owner: RemapGroupOwner, group: Int, port: Int) -> [NumericSettingState] { [] }
  func profiles(for slot: PlayerSlot) -> [String] { existingProfiles }
  func allProfileNames(for slot: PlayerSlot) -> [String] { existingProfiles + hiddenProfiles }
  /// The user's own profiles; the rest of `existingProfiles` are bundled.
  var userProfiles = ["Mine"]
  var deleteSucceeds = true
  func userProfileNames(for slot: PlayerSlot) -> [String] { userProfiles }

  func deleteProfile(_ name: String, slot: PlayerSlot) -> Bool {
    writes.append("delete:\(name)")
    guard deleteSucceeds, userProfiles.contains(name) else { return false }
    userProfiles.removeAll { $0 == name }
    existingProfiles.removeAll { $0 == name }
    return true
  }

  func defaultProfileName(forQualifier qualifier: String) -> String? {
    qualifier.hasPrefix("iOS/") ? "Touchscreen" : "Physical Controller"
  }

  /// What each profile gives the control rows (every row reads the same here); a missing profile
  /// cannot be read.
  var profileExpressions: [String: String] = ["Physical Controller": "`Button B`", "Touchscreen": "`Button 0`"]
  /// Every `expression(inProfile:)` read, as "profile:row".
  var profileReads: [String] = []

  func expression(inProfile profile: String, for row: RemapControlRow, port: Int) -> String? {
    profileReads.append("\(profile):\(row.id)")
    return profileExpressions[profile]
  }

  func isMotionPointerEnabled(wiimote: Int) -> Bool { true }
  func pointerMotion() -> PointerMotionState { .standard }
  func inputNames(forQualifier qualifier: String) -> [String] { deviceInputs }
  func inputStates(forQualifier qualifier: String) -> [Float] { inputValues }

  func check(_ expression: String) -> ExpressionCheck {
    parsable.contains(expression)
      ? ExpressionCheck(status: .valid, message: "ok")
      : ExpressionCheck(status: .invalid, message: "bad")
  }

  /// Whether the port is pinned; picking Auto or No Device unpins it (`clearDefaultDevice`).
  var pinned = false
  func isPinned(_ slot: PlayerSlot) -> Bool { pinned }
  func isSensorBarOnTop() -> Bool { false }

  func setDevice(_ choice: PlayerDeviceChoice, slot: PlayerSlot) {
    writes.append("device:\(choice)")
    if choice == .automatic || choice == .noDevice { pinned = false }
    if assignmentReplacesMapping, case .pad = choice { boundExpression = "`Button 0`" }
    onSetDevice?(choice)
    onSetDeviceForSlot?(choice, slot)
  }

  func loadProfile(_ name: String, slot: PlayerSlot) -> Bool {
    writes.append("load:\(name)")
    return true
  }

  func saveProfile(_ name: String, slot: PlayerSlot) -> Bool {
    writes.append("save:\(name)")
    return saveSucceeds
  }

  func setExpression(_ expression: String, for row: RemapControlRow, port: Int) { writes.append("expression:\(row.id)=\(expression)") }
  func setNumericSetting(_ setting: NumericSettingState, value: Double, port: Int) { writes.append("setting:\(setting.id)=\(value)") }
  func setMotionPointerEnabled(_ enabled: Bool, wiimote: Int) { writes.append("motion-pointer:\(enabled)") }
  func setPointerMode(_ mode: PointerMode) { writes.append("pointer:\(mode)") }
  func recenterPointer() { writes.append("recenter") }
  func setInvertX(_ enabled: Bool) { writes.append("invert-x:\(enabled)") }
  func setInvertY(_ enabled: Bool) { writes.append("invert-y:\(enabled)") }
  func setShakeToWiggle(_ enabled: Bool) { writes.append("shake:\(enabled)") }
  func setDragGain(_ gain: Double) { writes.append("gain:\(gain)") }
  func setGyroSensitivity(_ gain: Double) { writes.append("gyro-sensitivity:\(gain)") }
}
