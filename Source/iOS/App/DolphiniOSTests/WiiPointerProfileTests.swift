// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// The touchscreen Wii Remote's pointer against the live bridges: a profile load, a blank IR block
/// or the overlay's show/hide must never leave the IR rows unbound or the core's motion pointer
/// (`IMUIR/Enabled`) on, and the player screen must not offer profiles that cannot work on the
/// on-screen device (the Angry Birds Trilogy "hand stuck in the centre / gone" reports).
///
/// Everything runs on Wii Remote 4, which the test host never drives; its whole mapping is saved to
/// a scratch user profile first and loaded back, with its device and source, afterwards.
final class WiiPointerProfileTests: XCTestCase {
  /// 1-based, as the mapping bridge takes it.
  private static let port = 4
  /// `WiimoteEmu::WiimoteGroup::Point` (WiimoteEmu.h): the IR group, controls Up, Down, Left, Right
  /// first.
  private static let pointGroup = 3
  private static let buttonsGroup = 0
  /// The bundled Touchscreen.ini's IR block (ButtonType.h: IR Up/Down/Left/Right = Axis 112-115).
  private static let touchIR = ["`Axis 112`", "`Axis 113`", "`Axis 114`", "`Axis 115`"]
  /// A pad that is not connected, standing in for a physical controller bound to the slot.
  private static let padQualifier = "MFi/0/Gamepad"
  private static let backupProfile = "WiiPointerProfileTests Backup"

  private let service = ControllerAssignmentService(writer: BridgeControllerConfigWriter())
  private var savedDevice = ""
  private var savedSource = 0
  private var savedMapping = false

  override func setUp() {
    super.setUp()
    savedDevice = TVControllerMappingBridge.defaultDevice(forWiimote: Self.port) as String
    savedSource = DOLConfigBridge.wiimoteSource(for: Self.port)
    savedMapping = TVControllerMappingBridge.saveProfile(Self.backupProfile, forWiimote: Self.port)
  }

  override func tearDown() {
    if savedMapping {
      _ = TVControllerMappingBridge.loadProfile(Self.backupProfile, forWiimote: Self.port, restoreDevice: false)
    }
    TVControllerMappingBridge.setDefaultDevice(savedDevice, forWiimote: Self.port)
    DOLConfigBridge.setWiimoteSourceFor(Self.port, source: savedSource)
    if let backup = DolphinPaths.userDirectoryURL()?
      .appendingPathComponent("Config/Profiles/Wiimote/\(Self.backupProfile).ini") {
      try? FileManager.default.removeItem(at: backup)
    }
    super.tearDown()
  }

  // MARK: Profile loads

  func test_loadingPhysicalControllerOntoATouchscreenSlot_keepsTheTouchPointer() throws {
    try bindTouchscreen()

    XCTAssertTrue(TVControllerMappingBridge.loadProfile("Physical Controller", forWiimote: Self.port, restoreDevice: true))

    XCTAssertTrue(TVControllerMappingBridge.wiimoteUsesTouchscreen(forWiimote: Self.port),
                  "restoreDevice keeps the slot on the Touchscreen")
    XCTAssertEqual(irDirections(), Self.touchIR,
                   "Physical Controller.ini has no IR/ keys; the touchscreen's IR block must be re-applied")
    XCTAssertTrue(TVControllerMappingBridge.wiimoteHasIRPointerBinding(forWiimote: Self.port))
    XCTAssertFalse(isMotionPointerEnabled(),
                   "Physical Controller.ini sets IMUIR/Enabled = True, which must not survive on a touchscreen slot")
  }

  func test_loadingTheMotionPlusProfileOntoATouchscreenSlot_keepsTheTouchPointer() throws {
    try bindTouchscreen()

    XCTAssertTrue(TVControllerMappingBridge.loadProfile(
      "Wii Remote with MotionPlus Pointing", forWiimote: Self.port, restoreDevice: true))

    XCTAssertEqual(irDirections(), Self.touchIR)
    XCTAssertFalse(isMotionPointerEnabled())
  }

  // MARK: Repair

  func test_blankIRWithAutoHide_isRepairedWithoutTouchingOtherBindings() throws {
    try bindTouchscreen()
    let buttons = TVControllerMappingBridge.wiimoteControlExpressions(forGroup: Self.port, group: Self.buttonsGroup)
      as [String]
    for index in 0 ..< Self.touchIR.count {
      TVControllerMappingBridge.setWiimoteControlExpressionFor(Self.port, group: Self.pointGroup, index: index, expression: "")
    }
    let autoHide = try autoHideSetting()
    DOLControllerSettingsBridge.setNumericSetting(
      1, index: autoHide.index, owner: .wiimote, port: Self.port, group: Self.pointGroup)
    DOLControllerSettingsBridge.setGroupEnabled(
      true, owner: .wiimote, port: Self.port, group: AdvancedSettingGroups.imuPointGroup)
    XCTAssertFalse(TVControllerMappingBridge.wiimoteHasIRPointerBinding(forWiimote: Self.port), "precondition")

    XCTAssertTrue(TVControllerMappingBridge.enforceTouchscreenPointer(forWiimote: Self.port))

    XCTAssertEqual(irDirections(), Self.touchIR)
    XCTAssertEqual(try autoHideSetting().value, 0, "a pointer that sat still while unbound stays hidden with Auto-Hide on")
    XCTAssertFalse(isMotionPointerEnabled())
    XCTAssertEqual(
      TVControllerMappingBridge.wiimoteControlExpressions(forGroup: Self.port, group: Self.buttonsGroup) as [String],
      buttons, "only the IR block is re-applied")
    XCTAssertFalse(TVControllerMappingBridge.enforceTouchscreenPointer(forWiimote: Self.port),
                   "a slot already in shape is left alone")
  }

  func test_enforce_leavesAPhysicalControllerSlotAlone() {
    TVControllerMappingBridge.setDefaultDevice(Self.padQualifier, forWiimote: Self.port)
    DOLControllerSettingsBridge.setGroupEnabled(
      true, owner: .wiimote, port: Self.port, group: AdvancedSettingGroups.imuPointGroup)

    XCTAssertFalse(TVControllerMappingBridge.enforceTouchscreenPointer(forWiimote: Self.port))

    XCTAssertTrue(isMotionPointerEnabled(), "a physical motion controller owns the core's motion pointer")
  }

  // MARK: Overlay show / hide

  func test_overlayHideAndShow_keepTheMotionPointerOffOnATouchscreenSlot() throws {
    try bindTouchscreen()
    XCTAssertFalse(isMotionPointerEnabled(), "precondition: binding the touchscreen turns it off")

    // EmulationScreen's `isTouchControlsActive` handler used to pass `!active`: hidden -> ON.
    for enabled in [true, false, true] {
      TVEmulationBridge.setWiiIMUPointEnabled(enabled, forWiimote: Self.port - 1)
      XCTAssertFalse(isMotionPointerEnabled(), "after setWiiIMUPointEnabled(\(enabled))")
    }
  }

  func test_setWiiIMUPointEnabled_stillDrivesAPhysicalControllerSlot() {
    TVControllerMappingBridge.setDefaultDevice(Self.padQualifier, forWiimote: Self.port)

    TVEmulationBridge.setWiiIMUPointEnabled(true, forWiimote: Self.port - 1)
    XCTAssertTrue(isMotionPointerEnabled())
    TVEmulationBridge.setWiiIMUPointEnabled(false, forWiimote: Self.port - 1)
    XCTAssertFalse(isMotionPointerEnabled())
  }

  // MARK: Profile lists

  func test_profileListForATouchscreenSlot_offersOnlyTouchProfiles() throws {
    try bindTouchscreen()

    let names = TVControllerMappingBridge.profiles(forWiimote: Self.port) as [String]

    XCTAssertTrue(names.contains("Touchscreen"), "\(names)")
    XCTAssertFalse(names.contains("Physical Controller"), "\(names)")
    XCTAssertFalse(names.contains("Wii Remote with MotionPlus Pointing"), "\(names)")
    XCTAssertFalse(names.contains("SDL Gamepad"), "\(names)")
    XCTAssertTrue((TVControllerMappingBridge.allProfiles(forWiimote: Self.port) as [String]).contains("Physical Controller"),
                  "the unfiltered list (what a save collides with) still has every profile")
  }

  func test_profileListForAPhysicalSlot_hidesProfilesForMissingBackends() {
    TVControllerMappingBridge.setDefaultDevice(Self.padQualifier, forWiimote: Self.port)

    let names = TVControllerMappingBridge.profiles(forWiimote: Self.port) as [String]

    XCTAssertTrue(names.contains("Physical Controller"), "\(names)")
    XCTAssertFalse(names.contains("Wii Remote with MotionPlus Pointing"), "\(names)")
    XCTAssertFalse((TVControllerMappingBridge.profiles(forGCPort: Self.port) as [String]).contains("SDL Gamepad"))
  }

  // MARK: Wii Remote options

  /// Extension and Sideways reach WiimoteNew.ini as they change; they used to live in memory only
  /// and were gone after a relaunch.
  func test_extensionAndSideways_areSavedToWiimoteNewIni() throws {
    let index = Self.port - 1
    let extensionBefore = DOLWiimoteBridge.selectedExtension(forWiimote: index)
    let sidewaysBefore = DOLWiimoteBridge.isSideways(forWiimote: index)
    defer {
      DOLWiimoteBridge.setExtensionForWiimote(index, extension: extensionBefore)
      DOLWiimoteBridge.setSidewaysForWiimote(index, enabled: sidewaysBefore)
    }
    let classic = extensionBefore != 2

    DOLWiimoteBridge.setExtensionForWiimote(index, extension: classic ? 2 : 1)
    DOLWiimoteBridge.setSidewaysForWiimote(index, enabled: !sidewaysBefore)

    let saved = try wiimoteIniValues()
    XCTAssertEqual(saved["Extension"], classic ? "Classic" : "Nunchuk")
    // A value equal to the default (Sideways off) is not written at all.
    XCTAssertEqual(saved["Options/Sideways Wiimote"] ?? "False", sidewaysBefore ? "False" : "True")
  }

  // MARK: Helpers

  /// The `[Wiimote<port>]` section of `Config/WiimoteNew.ini` as it is on disk.
  private func wiimoteIniValues() throws -> [String: String] {
    let url = try XCTUnwrap(DolphinPaths.userDirectoryURL()?.appendingPathComponent("Config/WiimoteNew.ini"))
    let text = try String(contentsOf: url, encoding: .utf8)
    var values: [String: String] = [:]
    var inSection = false
    for line in text.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") {
        inSection = trimmed == "[Wiimote\(Self.port)]"
      } else if inSection, let separator = trimmed.range(of: " = ") {
        values[String(trimmed[..<separator.lowerBound])] = String(trimmed[separator.upperBound...])
      }
    }
    return values
  }

  /// Binds Wii Remote 4 to its Touchscreen instance the way the player screen does.
  private func bindTouchscreen() throws {
    service.assignTouchscreen(toPlayer: Self.port - 1, system: .wii)
    try XCTSkipUnless(TVControllerMappingBridge.wiimoteUsesTouchscreen(forWiimote: Self.port),
                      "the test host enumerates no Touchscreen device for Wii Remote \(Self.port)")
  }

  private func irDirections() -> [String] {
    let expressions = TVControllerMappingBridge.wiimoteControlExpressions(forGroup: Self.port, group: Self.pointGroup)
      as [String]
    return Array(expressions.prefix(Self.touchIR.count))
  }

  private func isMotionPointerEnabled() -> Bool {
    DOLControllerSettingsBridge.isGroupEnabled(owner: .wiimote, port: Self.port, group: AdvancedSettingGroups.imuPointGroup)
  }

  /// `IR/Auto-Hide`: the Cursor group adds it last (Cursor.cpp), after `Relative Input`.
  private func autoHideSetting() throws -> NumericSettingInfo {
    let settings = DOLControllerSettingsBridge.numericSettings(owner: .wiimote, port: Self.port, group: Self.pointGroup)
    let setting = settings.first(where: { $0.name == "Auto-Hide" }) ?? settings.last(where: { $0.type == .bool })
    return try XCTUnwrap(setting, "the IR group has no Auto-Hide setting")
  }
}
