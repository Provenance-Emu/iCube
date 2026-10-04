// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Builds one player's screen (controller hub spec, "Player screen"):
/// - Device (a pushed list), then Profile.
/// - Wii Remote (Wii ports): Extension, Sideways.
/// - Buttons: capture rows under Face / D-Pad / Sticks / Triggers / System / Motion.
/// - Pointer & Motion: iOS, Wii ports bound to the touchscreen or a gyro pad.
/// - Advanced, collapsed: numeric settings and raw expressions.
///
/// Help (`PlayerScreenHelp`): each Buttons category and Raw Bindings opens with a caption row, and
/// each Device / Profile / Wii Remote row has a caption as its subtitle (its value, if any, is the
/// badge). Numeric settings carry the core's own explanation.
///
/// Pure: state and actions in, `MenuModel` out, no bridge calls, like `ControllerHubModelBuilder`.
/// Rows that open something push (`.destination`); nothing here presents.
enum PlayerScreenModelBuilder {
  static func make(state: PlayerScreenState, actions: PlayerScreenActions, platform: PlatformKind) -> MenuModel {
    var sections = [deviceSection(state: state, actions: actions), profileSection(state: state, actions: actions)]
    if state.player.kind == .wiiRemote {
      sections.append(wiiSection(state: state, actions: actions, platform: platform))
    }
    sections += buttonSections(state: state, actions: actions)
    if showsPointerAndMotion(state: state, platform: platform) {
      sections.append(pointerSection(state: state, actions: actions))
    }
    sections += advancedSections(state: state, actions: actions)
    return lockedToTheArmedRow(MenuModel(sections: sections), armedControlID: state.armedControlID)
  }

  /// Wii ports, iOS only (tvOS has no touchscreen and no Pointer & Motion), and only where something
  /// drives the pointer: the device's motion or touch, or a pad's own gyro.
  static func showsPointerAndMotion(state: PlayerScreenState, platform: PlatformKind) -> Bool {
    platform == .ios && state.player.kind == .wiiRemote && (state.isTouchscreen || state.boundPad?.hasGyro == true)
  }

  /// "Physical Controller", "Physical Controller (edited)", or "Custom" when not known.
  static func profileDisplayName(_ state: PlayerScreenState) -> String {
    guard let name = state.profileName else { return L("Custom") }
    return state.profileEdited ? String(format: L("%@ (edited)"), name) : name
  }

  static func captureRowID(_ row: RemapControlRow) -> String { "control-\(row.id)" }
  static func expressionRowID(_ row: RemapControlRow) -> String { "expression-\(row.id)" }

  // MARK: Device (decision 9: a pushed list, one pick = one assignment)

  /// What the Device row shows.
  static func deviceSummary(_ state: PlayerScreenState) -> String {
    switch state.deviceChoice {
    case .noDevice:
      return L("No Device")
    case .touchscreen:
      return L("Touchscreen")
    case .pad(let qualifier):
      if let pad = state.boundPad { return pad.name }
      let name = qualifierName(qualifier)
      // Only an MFi pad can be "Disconnected"; a DSU device is never in the pad list (decision 11).
      return state.isDisconnected ? String(format: L("%@ (Disconnected)"), name) : name
    }
  }

  /// The Device list: None, Touchscreen (iOS), each connected pad, and the bound device when it is
  /// none of those (a disconnected pad, a DSU device), so the list can mark it current.
  static func deviceOptions(state: PlayerScreenState, platform: PlatformKind) -> [DeviceOption] {
    var options = [DeviceOption(choice: .noDevice, title: L("None"))]
    if platform == .ios {
      options.append(DeviceOption(choice: .touchscreen, title: L("Touchscreen")))
    }
    options += state.pads.map { DeviceOption(choice: .pad($0.qualifier), title: $0.name) }
    if case .pad = state.deviceChoice, state.boundPad == nil {
      options.append(DeviceOption(choice: state.deviceChoice, title: deviceSummary(state)))
    }
    return options
  }

  /// "Xbox Wireless Controller" from `MFi/0/Xbox Wireless Controller`, as the hub shows it.
  private static func qualifierName(_ qualifier: String) -> String {
    qualifier.split(separator: "/", maxSplits: 2).last.map(String.init) ?? qualifier
  }

  private static func deviceSection(state: PlayerScreenState, actions: PlayerScreenActions) -> MenuSection {
    MenuSection(id: "device", items: [
      // The bound device is the badge (the row's value); the subtitle says what the row is for.
      MenuItem(
        id: "device", title: L("Device"), subtitle: PlayerScreenHelp.device, icon: "gamecontroller",
        role: .destination(actions.deviceListDestination()), badge: deviceSummary(state)),
    ])
  }

  // MARK: Profile

  private static func profileSection(state: PlayerScreenState, actions: PlayerScreenActions) -> MenuSection {
    MenuSection(id: "profile", header: L("Profile"), items: [
      MenuItem(
        id: "profile-load", title: L("Load Profile…"), subtitle: PlayerScreenHelp.loadProfile, icon: "tray.and.arrow.down",
        role: .destination(actions.profileListDestination()), badge: profileDisplayName(state)),
      MenuItem(
        id: "profile-save", title: L("Save Profile As…"), subtitle: PlayerScreenHelp.saveProfile, icon: "square.and.arrow.down",
        role: .action(actions.saveProfileAs)),
      MenuItem(
        id: "profile-reset", title: L("Reset to Default Profile"), subtitle: PlayerScreenHelp.resetProfile,
        icon: "arrow.counterclockwise", role: .action(actions.resetProfile), isEnabled: state.deviceChoice != .noDevice),
    ])
  }

  // MARK: Wii Remote

  private static func wiiSection(state: PlayerScreenState, actions: PlayerScreenActions, platform: PlatformKind) -> MenuSection {
    let extensions = (0 ..< WiimoteSlotOptions.extensionCount).map { value -> (String, AnyHashable) in
      let name = WiimoteSlotOptions.extensionName(value)
      // tvOS shows only the option titles, so they say what they are.
      return (platform == .tvos ? String(format: L("Extension: %@"), name) : name, AnyHashable(value))
    }
    return MenuSection(id: "wii", header: L("Wii Remote"), items: [
      MenuItem(
        id: "wii-extension", title: L("Extension"), subtitle: PlayerScreenHelp.extensionCaption, icon: "puzzlepiece.extension",
        role: .picker(options: extensions, selection: Binding(
          get: { AnyHashable(state.player.wiiExtension) },
          set: { if let value = $0.base as? Int { actions.setExtension(value) } }))),
      MenuItem(
        id: "wii-sideways", title: L("Sideways"), subtitle: PlayerScreenHelp.sideways, icon: "rotate.right",
        role: .toggle(Binding(get: { state.player.isSideways }, set: { actions.setSideways($0) }))),
    ])
  }

  // MARK: Buttons

  private static func buttonSections(state: PlayerScreenState, actions: PlayerScreenActions) -> [MenuSection] {
    var sections: [MenuSection] = []
    if let hint = captureHint(state) {
      // Enabled no-op: a tvOS List scrolls only by focus, and a disabled row takes none.
      sections.append(MenuSection(id: "buttons-hint", items: [MenuItem(id: "buttons-hint", title: hint, role: .action({}))]))
    }
    // Once per build, not per row.
    let family = DeviceFamily.from(qualifier: state.player.deviceQualifier)
    for (category, rows) in ControlCategory.grouped(state.controls) {
      let captureRows: [MenuItem] = rows.map { row in
        let title = ControlCategory.title(for: row)
        let isArmed = state.armedControlID == row.id
        let isEnabled = state.canCapture && (!state.isCapturing || isArmed)
        return MenuItem(
          id: captureRowID(row), title: title,
          role: .custom(AnyView(CaptureRowView(
            title: title, binding: BindingDisplay.text(for: row.expression, family: family), isArmed: isArmed,
            isEnabled: isEnabled, onActivate: { actions.toggleCapture(row) }, onClear: { actions.clearBinding(row) },
            onReset: { actions.resetBinding(row) }))),
          isEnabled: isEnabled,
          onCustomActivate: { actions.toggleCapture(row) })
      }
      let help = helpCaption(id: helpID(category), PlayerScreenHelp.category(category, onTouchscreen: state.isTouchscreen))
      sections.append(MenuSection(id: "buttons-\(category.id)", header: category.title, items: [help] + captureRows))
    }
    return sections
  }

  static func helpID(_ category: ControlCategory) -> String { "help-\(category.id)" }

  /// A caption row: text only, never focused (`isEnabled` false, so a pad's focus walks past it and
  /// tvOS skips it), and visible whenever the rows around it are. It reads as a caption because it
  /// is one `Text` in the caption style, not a disabled button.
  private static func helpCaption(id: String, _ text: String) -> MenuItem {
    MenuItem(id: id, title: text, role: .custom(AnyView(PlayerHelpCaption(text: text))), isEnabled: false)
  }

  /// Why capture is impossible, or nil when it is possible (decision 11).
  private static func captureHint(_ state: PlayerScreenState) -> String? {
    switch state.deviceChoice {
    case .noDevice: return L("Choose a device to bind its buttons.")
    case .touchscreen: return L("Touchscreen controls are laid out by the on-screen overlay.")
    case .pad: return state.isDisconnected ? L("Connect this controller to capture buttons.") : nil
    }
  }

  // MARK: Pointer & Motion

  private static func pointerSection(state: PlayerScreenState, actions: PlayerScreenActions) -> MenuSection {
    guard state.isTouchscreen else {
      // A pad's pointer comes from its own gyro through its profile; the only switch is the Wii
      // Remote's IMU pointer (decision 2).
      return MenuSection(id: "pointer", header: L("Pointer & Motion"), items: [
        MenuItem(
          id: "pointer-motion", title: L("Aim with Controller Motion"), subtitle: L("The controller's gyro moves the Wii pointer."),
          icon: "gyroscope",
          role: .toggle(Binding(get: { state.motionPointerEnabled }, set: { actions.setMotionPointer($0) }))),
      ])
    }
    let motion = state.pointerMotion
    let modes: [PointerMode] = [.touchFollow, .touchDrag, .gyro]
    var items = [
      MenuItem(
        id: "pointer-mode", title: L("Pointer"), icon: motion.pointerMode.systemImage,
        role: .picker(options: modes.map { ($0.title, AnyHashable($0)) }, selection: Binding(
          get: { AnyHashable(motion.pointerMode) },
          set: { if let mode = $0.base as? PointerMode { actions.setPointerMode(mode) } }))),
      MenuItem(id: "pointer-recenter", title: L("Recenter Pointer"), icon: "scope", role: .action(actions.recenterPointer)),
    ]
    if motion.pointerMode == .touchDrag, motion.usesProgrammaticOverlay {
      items.append(sensitivityItem(
        choices: PointerMotionState.dragGainChoices, current: motion.dragGain, set: actions.setDragGain))
    }
    if motion.pointerMode == .gyro {
      // Decision 4: a multiplier on the gyro pointer's constants. Decision 7: invert only here,
      // because only the gyro pointer reads the invert keys.
      items.append(sensitivityItem(
        choices: PointerMotionState.gyroSensitivityChoices, current: motion.gyroSensitivity, set: actions.setGyroSensitivity))
      items.append(MenuItem(
        id: "pointer-invert-x", title: L("Invert X"), icon: "arrow.left.and.right",
        role: .toggle(Binding(get: { motion.invertX }, set: { actions.setInvertX($0) }))))
      items.append(MenuItem(
        id: "pointer-invert-y", title: L("Invert Y"), icon: "arrow.up.and.down",
        role: .toggle(Binding(get: { motion.invertY }, set: { actions.setInvertY($0) }))))
    }
    items.append(MenuItem(
      id: "pointer-shake", title: L("Shake to Wiggle"), subtitle: L("Shaking the device shakes the Wii Remote."),
      icon: "iphone.radiowaves.left.and.right",
      role: .toggle(Binding(get: { motion.shakeToWiggle }, set: { actions.setShakeToWiggle($0) }))))
    return MenuSection(id: "pointer", header: L("Pointer & Motion"), items: items)
  }

  /// The mode's Sensitivity row: a stepped multiplier, one compact row on tvOS.
  private static func sensitivityItem(choices: [Double], current: Double, set: @escaping (Double) -> Void) -> MenuItem {
    MenuItem(
      id: "pointer-sensitivity", title: L("Sensitivity"), icon: "dial.medium",
      role: .picker(
        options: choices.map { ("×" + NumericSettingSteps.label($0, suffix: ""), AnyHashable($0)) },
        selection: Binding(
          get: { AnyHashable(PointerMotionState.snapped(current, to: choices)) },
          set: { if let value = $0.base as? Double { set(value) } })),
      isCompactOnTV: true)
  }

  // MARK: Advanced

  private static func advancedSections(state: PlayerScreenState, actions: PlayerScreenActions) -> [MenuSection] {
    var sections = [MenuSection(id: "advanced", header: L("Advanced"), items: [
      MenuItem(
        id: "advanced-toggle", title: state.showsAdvanced ? L("Hide Advanced") : L("Show Advanced"),
        icon: state.showsAdvanced ? "chevron.up" : "chevron.down", role: .action(actions.toggleAdvanced)),
    ])]
    guard state.showsAdvanced else { return sections }
    for group in state.advanced where !group.settings.isEmpty {
      sections.append(MenuSection(
        id: "advanced-\(group.owner)-\(group.groupId)", header: group.title,
        items: group.settings.map { settingItem($0, actions: actions) }))
    }
    if !state.controls.isEmpty {
      // Readable names, as the capture rows show them; the editor a row pushes holds the raw text.
      let family = DeviceFamily.from(qualifier: state.player.deviceQualifier)
      let expressionRows: [MenuItem] = state.controls.map { row in
        MenuItem(
          id: expressionRowID(row), title: ControlCategory.title(for: row),
          subtitle: BindingDisplay.text(for: row.expression, family: family),
          role: .destination(actions.expressionDestination(row)))
      }
      let help = helpCaption(id: "help-expressions", PlayerScreenHelp.rawBindings)
      sections.append(MenuSection(id: "advanced-expressions", header: L("Raw Bindings"), items: [help] + expressionRows))
    }
    return sections
  }

  /// What a setting's row says under its name: the core's explanation, or that an expression drives
  /// it. nil when the core has no explanation.
  static func settingSubtitle(_ setting: NumericSettingState) -> String? {
    if setting.isExpression { return L("Set by an expression") }
    return setting.explanation.isEmpty ? nil : setting.explanation
  }

  private static func settingItem(_ setting: NumericSettingState, actions: PlayerScreenActions) -> MenuItem {
    let subtitle = settingSubtitle(setting)
    if setting.isExpression {
      // Enabled no-op so tvOS focus can reach it; editing an expression-driven value here would
      // silently replace the expression.
      return MenuItem(id: setting.id, title: setting.name, subtitle: subtitle, role: .action({}))
    }
    if setting.isToggle {
      return MenuItem(
        id: setting.id, title: setting.name, subtitle: subtitle,
        role: .toggle(Binding(get: { setting.value != 0 }, set: { actions.setNumericSetting(setting, $0 ? 1 : 0) })))
    }
    let values = NumericSettingSteps.values(for: setting)
    let selected = NumericSettingSteps.nearest(to: setting.value, in: values)
    return MenuItem(
      id: setting.id, title: setting.name, subtitle: subtitle,
      role: .picker(
        options: values.map { (NumericSettingSteps.label($0, suffix: setting.suffix), AnyHashable($0)) },
        selection: Binding(
          get: { AnyHashable(selected) },
          set: { if let value = $0.base as? Double { actions.setNumericSetting(setting, value) } })),
      isCompactOnTV: true)
  }

  // MARK: Capture lock

  /// While a capture is armed only the armed row responds. On tvOS a pad's d-pad drives native
  /// focus, which then has nowhere to go; touch cannot change the device under a running capture.
  private static func lockedToTheArmedRow(_ model: MenuModel, armedControlID: String?) -> MenuModel {
    guard let armedControlID else { return model }
    let armedItemID = "control-\(armedControlID)"
    var locked = model
    for section in locked.sections.indices {
      for item in locked.sections[section].items.indices where locked.sections[section].items[item].id != armedItemID {
        locked.sections[section].items[item].isEnabled = false
      }
    }
    return locked
  }
}

/// A help caption row's view (`PlayerScreenModelBuilder.helpCaption`).
struct PlayerHelpCaption: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
}
