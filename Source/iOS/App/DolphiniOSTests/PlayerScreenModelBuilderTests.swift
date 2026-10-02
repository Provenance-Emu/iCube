// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

/// Covers `PlayerScreenModelBuilder` (controller hub spec, Testing: "sections per system and
/// device; Advanced collapsed by default; Pointer & Motion only where it applies"), plus the
/// signed-off decisions 4, 7, 9 and 11. Pure: every action is a recorded closure, every
/// destination an `EmptyView`.
final class PlayerScreenModelBuilderTests: XCTestCase {

  private static let xbox = "MFi/0/Xbox Wireless Controller"
  private static let dualSense = "MFi/1/DualSense Wireless Controller"
  private static let dsu = "DSUClient/0/Pad C"
  private static let touch = "iOS/4/Touchscreen"

  private final class Recorder {
    var calls: [String] = []
  }

  private func actions(_ recorder: Recorder = Recorder()) -> PlayerScreenActions {
    PlayerScreenActions(
      deviceListDestination: { AnyView(EmptyView()) },
      profileListDestination: { AnyView(EmptyView()) },
      saveProfileAs: { recorder.calls.append("save-as") },
      resetProfile: { recorder.calls.append("reset") },
      setExtension: { recorder.calls.append("extension:\($0)") },
      setSideways: { recorder.calls.append("sideways:\($0)") },
      toggleCapture: { recorder.calls.append("capture:\($0.id)") },
      clearBinding: { recorder.calls.append("clear:\($0.id)") },
      setPointerMode: { recorder.calls.append("pointer:\($0)") },
      recenterPointer: { recorder.calls.append("recenter") },
      setDragGain: { recorder.calls.append("gain:\($0)") },
      setGyroSensitivity: { recorder.calls.append("gyro-sensitivity:\($0)") },
      setInvertX: { recorder.calls.append("invert-x:\($0)") },
      setInvertY: { recorder.calls.append("invert-y:\($0)") },
      setShakeToWiggle: { recorder.calls.append("shake:\($0)") },
      setMotionPointer: { recorder.calls.append("motion-pointer:\($0)") },
      toggleAdvanced: { recorder.calls.append("advanced") },
      setNumericSetting: { recorder.calls.append("setting:\($0.id)=\($1)") },
      expressionDestination: { _ in AnyView(EmptyView()) })
  }

  private func pad(_ qualifier: String, _ name: String, gyro: Bool = false) -> ConnectedPadState {
    ConnectedPadState(qualifier: qualifier, name: name, batteryPercent: nil, isCharging: false, playerLabel: nil, hasGyro: gyro)
  }

  private func rows(_ owner: RemapGroupOwner, _ group: Int, _ names: [String]) -> [RemapControlRow] {
    names.enumerated().map {
      RemapControlRow(owner: owner, groupId: group, index: $0.offset, name: $0.element, expression: "`Button \($0.element)`")
    }
  }

  /// A GameCube port's controls in `RemapGroup.gamecube` order, Rumble included.
  private var gameCubeControls: [RemapControlRow] {
    rows(.gcPad, 0, ["A", "B", "X", "Y", "Z", "START"]) + rows(.gcPad, 3, ["Up", "Down", "Left", "Right"])
      + rows(.gcPad, 1, ["Up", "Down", "Left", "Right", "Modifier"]) + rows(.gcPad, 4, ["L", "R", "L-Analog", "R-Analog"])
      + rows(.gcPad, 5, ["Motor"])
  }

  private func state(
    _ kind: PlayerState.Kind, device: String = "", pads: [ConnectedPadState] = [], controls: [RemapControlRow] = []
  ) -> PlayerScreenState {
    var screen = PlayerScreenState.empty(
      PlayerState(kind: kind, port: 1, deviceQualifier: device, wiiExtension: 0, isSideways: false))
    screen.pads = pads
    screen.controls = controls
    return screen
  }

  /// GameCube port 1 on a connected Xbox pad, every control listed.
  private var boundGameCube: PlayerScreenState {
    state(.gameCube, device: Self.xbox, pads: [pad(Self.xbox, "Xbox Wireless Controller")], controls: gameCubeControls)
  }

  private func make(_ state: PlayerScreenState, _ recorder: Recorder = Recorder(), platform: PlatformKind = .ios) -> MenuModel {
    PlayerScreenModelBuilder.make(state: state, actions: actions(recorder), platform: platform)
  }

  private func sectionIDs(_ model: MenuModel) -> [String] { model.sections.map(\.id) }

  private func ids(_ model: MenuModel, section id: String) -> [String] {
    model.sections.first { $0.id == id }?.items.map(\.id) ?? []
  }

  private func optionTitles(_ item: MenuItem?) -> [String] {
    guard let item, case .picker(let options, _) = item.role else { return [] }
    return options.map { $0.0 }
  }

  private func select(_ value: AnyHashable, on item: MenuItem?) {
    guard let item, case .picker(_, let selection) = item.role else { return XCTFail("not a picker") }
    selection.wrappedValue = value
  }

  private func run(_ item: MenuItem?) {
    guard let item, case .action(let action) = item.role else { return XCTFail("not an action row") }
    action()
  }

  // MARK: Sections per system and device

  func test_gameCubePort_withAPad() {
    XCTAssertEqual(
      sectionIDs(make(boundGameCube)),
      ["device", "profile", "buttons-face", "buttons-dpad", "buttons-sticks", "buttons-triggers", "buttons-system", "advanced"])
  }

  func test_gameCubePort_neverShowsWiiSections_evenOnTheTouchscreen() {
    let ids = sectionIDs(make(state(.gameCube, device: "iOS/0/Touchscreen")))
    XCTAssertFalse(ids.contains("wii"))
    XCTAssertFalse(ids.contains("pointer"))
  }

  func test_wiiPort_onTheTouchscreen_iOS() {
    XCTAssertEqual(
      sectionIDs(make(state(.wiiRemote, device: Self.touch))),
      ["device", "profile", "wii", "buttons-hint", "pointer", "advanced"])
  }

  // MARK: Device (decision 9)

  func test_deviceRow_pushesTheDeviceList() {
    guard let item = make(boundGameCube).item(id: "device"), case .destination = item.role else {
      return XCTFail("Device must be a pushed list, never a stepped picker")
    }
  }

  func test_deviceSummary() {
    XCTAssertEqual(PlayerScreenModelBuilder.deviceSummary(state(.gameCube)), "No Device")
    XCTAssertEqual(PlayerScreenModelBuilder.deviceSummary(state(.wiiRemote, device: Self.touch)), "Touchscreen")
    XCTAssertEqual(PlayerScreenModelBuilder.deviceSummary(boundGameCube), "Xbox Wireless Controller")
    XCTAssertEqual(
      PlayerScreenModelBuilder.deviceSummary(state(.gameCube, device: Self.xbox)), "Xbox Wireless Controller (Disconnected)")
    XCTAssertEqual(PlayerScreenModelBuilder.deviceSummary(state(.gameCube, device: Self.dsu)), "Pad C", "DSU is never Disconnected")
  }

  func test_deviceOptions_iOS() {
    let options = PlayerScreenModelBuilder.deviceOptions(
      state: state(.gameCube, pads: [pad(Self.xbox, "Xbox Wireless Controller")]), platform: .ios)
    XCTAssertEqual(options.map(\.title), ["None", "Touchscreen", "Xbox Wireless Controller"])
    XCTAssertEqual(options.map(\.choice), [.noDevice, .touchscreen, .pad(Self.xbox)])
  }

  func test_deviceOptions_tvOS_haveNoTouchscreen() {
    let options = PlayerScreenModelBuilder.deviceOptions(
      state: state(.gameCube, pads: [pad(Self.xbox, "Xbox Wireless Controller")]), platform: .tvos)
    XCTAssertEqual(options.map(\.title), ["None", "Xbox Wireless Controller"])
  }

  /// The bound device is always listed, so the list can mark it current.
  func test_deviceOptions_listTheBoundDeviceWhenItIsNotAConnectedPad() {
    let disconnected = PlayerScreenModelBuilder.deviceOptions(state: state(.gameCube, device: Self.xbox), platform: .ios)
    XCTAssertEqual(disconnected.last?.title, "Xbox Wireless Controller (Disconnected)")
    let dsu = PlayerScreenModelBuilder.deviceOptions(state: state(.gameCube, device: Self.dsu), platform: .ios)
    XCTAssertEqual(dsu.last, DeviceOption(choice: .pad(Self.dsu), title: "Pad C"))
  }

  // MARK: Pointer & Motion only where it applies (decisions 2, 4, 7)

  func test_tvOS_hasNoPointerAndMotion() {
    let model = make(
      state(.wiiRemote, device: Self.dualSense, pads: [pad(Self.dualSense, "DualSense", gyro: true)]), platform: .tvos)
    XCTAssertFalse(sectionIDs(model).contains("pointer"))
  }

  func test_wiiPort_gyroPad_iOS_getsOnlyTheMotionPointerToggle() {
    let model = make(state(.wiiRemote, device: Self.dualSense, pads: [pad(Self.dualSense, "DualSense", gyro: true)]))
    XCTAssertEqual(ids(model, section: "pointer"), ["pointer-motion"])
  }

  func test_wiiPort_padWithoutAGyro_hasNoPointerSection() {
    let model = make(state(.wiiRemote, device: Self.xbox, pads: [pad(Self.xbox, "Xbox")]))
    XCTAssertFalse(sectionIDs(model).contains("pointer"))
  }

  func test_pointer_follow_showsModeRecenterAndShake() {
    XCTAssertEqual(
      ids(make(state(.wiiRemote, device: Self.touch)), section: "pointer"),
      ["pointer-mode", "pointer-recenter", "pointer-shake"])
  }

  func test_pointer_gyro_addsGyroSensitivityAndInvert() {
    let recorder = Recorder()
    var screen = state(.wiiRemote, device: Self.touch)
    screen.pointerMotion.pointerMode = .gyro
    let model = make(screen, recorder)
    XCTAssertEqual(
      ids(model, section: "pointer"),
      ["pointer-mode", "pointer-recenter", "pointer-sensitivity", "pointer-invert-x", "pointer-invert-y", "pointer-shake"])
    XCTAssertTrue(model.item(id: "pointer-sensitivity")?.isCompactOnTV == true)
    XCTAssertEqual(optionTitles(model.item(id: "pointer-sensitivity")).count, PointerMotionState.gyroSensitivityChoices.count)
    select(AnyHashable(1.5), on: model.item(id: "pointer-sensitivity"))
    XCTAssertEqual(recorder.calls, ["gyro-sensitivity:1.5"])
  }

  func test_pointer_dragAddsTheDragGain_onlyOnTheProgrammaticOverlay() {
    let recorder = Recorder()
    var screen = state(.wiiRemote, device: Self.touch)
    screen.pointerMotion.pointerMode = .touchDrag
    XCTAssertEqual(ids(make(screen), section: "pointer"), ["pointer-mode", "pointer-recenter", "pointer-shake"])
    screen.pointerMotion.usesProgrammaticOverlay = true
    let model = make(screen, recorder)
    XCTAssertEqual(ids(model, section: "pointer"), ["pointer-mode", "pointer-recenter", "pointer-sensitivity", "pointer-shake"])
    select(AnyHashable(2.0), on: model.item(id: "pointer-sensitivity"))
    XCTAssertEqual(recorder.calls, ["gain:2.0"])
  }

  func test_pointerModes_inTheSpecsOrder() {
    XCTAssertEqual(
      optionTitles(make(state(.wiiRemote, device: Self.touch)).item(id: "pointer-mode")),
      ["Touch – Follow", "Touch – Drag", "Gyro"])
  }

  // MARK: Advanced

  func test_advanced_isCollapsedByDefault() {
    let recorder = Recorder()
    let model = make(boundGameCube, recorder)
    XCTAssertEqual(sectionIDs(model).filter { $0.hasPrefix("advanced") }, ["advanced"])
    XCTAssertEqual(model.item(id: "advanced-toggle")?.title, "Show Advanced")
    run(model.item(id: "advanced-toggle"))
    XCTAssertEqual(recorder.calls, ["advanced"])
  }

  func test_advanced_expanded_listsSettingsAndEveryRawBinding() {
    var screen = boundGameCube
    screen.showsAdvanced = true
    let deadZone = NumericSettingState(
      owner: .gcPad, groupId: 1, index: 0, name: "Dead Zone", suffix: "%", isToggle: false, isInteger: false,
      value: 15, minimum: 0, maximum: 50, defaultValue: 0, isExpression: false)
    let scripted = NumericSettingState(
      owner: .gcPad, groupId: 1, index: 1, name: "Virtual Notches", suffix: "°", isToggle: false, isInteger: false,
      value: 0, minimum: 0, maximum: 45, defaultValue: 0, isExpression: true)
    screen.advanced = [AdvancedGroupState(owner: .gcPad, groupId: 1, title: "Control Stick", settings: [deadZone, scripted])]
    let model = make(screen)
    XCTAssertEqual(sectionIDs(model).filter { $0.hasPrefix("advanced") }, ["advanced", "advanced-gcPad-1", "advanced-expressions"])
    XCTAssertEqual(model.item(id: "advanced-toggle")?.title, "Hide Advanced")
    XCTAssertTrue(model.item(id: deadZone.id)?.isCompactOnTV == true)
    XCTAssertEqual(optionTitles(model.item(id: deadZone.id)).count, 11)
    XCTAssertEqual(model.item(id: scripted.id)?.subtitle, "Set by an expression")
    XCTAssertEqual(ids(model, section: "advanced-expressions").count, gameCubeControls.count, "Rumble too: outputs are edited here")
  }

  /// An expression-driven numeric setting is a read-only row: editing it here would silently
  /// replace the expression, and the bridge does not refuse. This builder guard is the only one.
  func test_advanced_anExpressionDrivenSetting_isReadOnly() {
    let recorder = Recorder()
    var screen = state(.gameCube)
    screen.showsAdvanced = true
    let scripted = NumericSettingState(
      owner: .gcPad, groupId: 1, index: 1, name: "Virtual Notches", suffix: "°", isToggle: false, isInteger: false,
      value: 0, minimum: 0, maximum: 45, defaultValue: 0, isExpression: true)
    screen.advanced = [AdvancedGroupState(owner: .gcPad, groupId: 1, title: "Control Stick", settings: [scripted])]
    let item = make(screen, recorder).item(id: scripted.id)
    XCTAssertNotNil(item)
    guard case .action = item?.role else { return XCTFail("an expression row must be a plain action, not a picker or toggle") }
    run(item)  // activation
    XCTAssertEqual(recorder.calls, [], "activating writes nothing")
    // Adjustment (d-pad left/right, tvOS compact stepping) only exists on a picker or a toggle.
    if case .picker = item?.role { XCTFail("adjustable") }
    if case .toggle = item?.role { XCTFail("adjustable") }
    XCTAssertEqual(recorder.calls, [])
  }

  func test_advanced_settingPickerReportsTheValue() {
    let recorder = Recorder()
    var screen = state(.gameCube)
    screen.showsAdvanced = true
    let deadZone = NumericSettingState(
      owner: .gcPad, groupId: 1, index: 0, name: "Dead Zone", suffix: "%", isToggle: false, isInteger: false,
      value: 15, minimum: 0, maximum: 50, defaultValue: 0, isExpression: false)
    screen.advanced = [AdvancedGroupState(owner: .gcPad, groupId: 1, title: "Control Stick", settings: [deadZone])]
    select(AnyHashable(25.0), on: make(screen, recorder).item(id: deadZone.id))
    XCTAssertEqual(recorder.calls, ["setting:\(deadZone.id)=25.0"])
  }

  // MARK: Buttons and capture (decision 11)

  func test_rumbleIsNotACaptureRow() {
    let model = make(boundGameCube)
    XCTAssertNil(model.item(id: "control-gcPad-5-0"))
    XCTAssertEqual(ids(model, section: "buttons-face"), ["control-gcPad-0-0", "control-gcPad-0-1", "control-gcPad-0-2", "control-gcPad-0-3"])
  }

  func test_captureRow_padActivateTogglesThatControl() {
    let recorder = Recorder()
    make(boundGameCube, recorder).item(id: "control-gcPad-0-1")?.onCustomActivate?()
    XCTAssertEqual(recorder.calls, ["capture:gcPad-0-1"])
  }

  func test_armedCapture_leavesOnlyTheArmedRowEnabled() {
    var screen = boundGameCube
    screen.armedControlID = "gcPad-0-0"
    XCTAssertEqual(make(screen).focusableIDs, ["control-gcPad-0-0"])
  }

  func test_touchscreen_disablesCapture_withAHint() {
    let model = make(state(.gameCube, device: "iOS/0/Touchscreen", controls: gameCubeControls))
    XCTAssertEqual(model.item(id: "buttons-hint")?.title, "Touchscreen controls are laid out by the on-screen overlay.")
    XCTAssertEqual(model.item(id: "control-gcPad-0-0")?.isEnabled, false)
  }

  func test_noDevice_disablesCapture_withAHint() {
    let model = make(state(.gameCube, controls: gameCubeControls))
    XCTAssertEqual(model.item(id: "buttons-hint")?.title, "Choose a device to bind its buttons.")
    XCTAssertEqual(model.item(id: "control-gcPad-0-0")?.isEnabled, false)
  }

  func test_disconnectedPad_disablesCapture_withAHint() {
    let model = make(state(.gameCube, device: Self.xbox, controls: gameCubeControls))
    XCTAssertEqual(model.item(id: "buttons-hint")?.title, "Connect this controller to capture buttons.")
    XCTAssertEqual(model.item(id: "control-gcPad-0-0")?.isEnabled, false)
    XCTAssertEqual(model.item(id: "device")?.subtitle, "Xbox Wireless Controller (Disconnected)")
  }

  func test_dsuPort_captures_andIsNotDisconnected() {
    let model = make(state(.gameCube, device: Self.dsu, controls: gameCubeControls))
    XCTAssertNil(model.item(id: "buttons-hint"))
    XCTAssertEqual(model.item(id: "control-gcPad-0-0")?.isEnabled, true)
    XCTAssertEqual(model.item(id: "device")?.subtitle, "Pad C")
  }

  // MARK: Profile and Wii rows

  func test_profileName_customThenEdited() {
    var screen = boundGameCube
    XCTAssertEqual(make(screen).item(id: "profile-load")?.subtitle, "Custom")
    screen.profileName = "Physical Controller"
    screen.profileEdited = true
    XCTAssertEqual(make(screen).item(id: "profile-load")?.subtitle, "Physical Controller (edited)")
  }

  func test_saveAndReset_runTheirActions_resetNeedsADevice() {
    let recorder = Recorder()
    let model = make(boundGameCube, recorder)
    run(model.item(id: "profile-save"))
    run(model.item(id: "profile-reset"))
    XCTAssertEqual(recorder.calls, ["save-as", "reset"])
    XCTAssertEqual(make(state(.gameCube)).item(id: "profile-reset")?.isEnabled, false)
  }

  func test_extensionOptions_sayExtensionOnTVOS() {
    XCTAssertEqual(optionTitles(make(state(.wiiRemote)).item(id: "wii-extension")), ["None", "Nunchuk", "Classic"])
    XCTAssertEqual(
      optionTitles(make(state(.wiiRemote), platform: .tvos).item(id: "wii-extension")),
      ["Extension: None", "Extension: Nunchuk", "Extension: Classic"])
  }
}
