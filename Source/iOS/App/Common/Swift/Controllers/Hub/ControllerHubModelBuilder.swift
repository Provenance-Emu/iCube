// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Builds the Controllers hub (controller hub spec, "Controllers hub"), as two pages.
///
/// Root, in the order a player reaches for things:
/// - On-Screen Controls (iOS): which controller they are, whether they show, and a push to Touch Controls.
/// - One section per player: Device, Plays as, Pointer, then the push to its buttons and profiles.
///   Unbound ports appear under "Show All Ports".
/// - Controllers: the connected pads, and everything that is about physical pads (lights, rumble,
///   who takes Player 1, background input).
/// - Phones (while any phone advertises itself as a controller).
/// - Motion: the DSU motion source.
/// - Help.
///
/// Touch Controls (iOS): opacity, editable controls, the layout and IR area editors, skins, stick
/// feel and the layout reset. Appearance only; nothing there changes who plays what.
///
/// Pure: state and actions in, `MenuModel` out, no bridge calls, mirroring `PauseMenuModelBuilder`
/// and `CheatsMenuModelBuilder`. Rows that open something PUSH (`.destination`), except Edit
/// Layout… and Edit IR Area…, actions: their editors must cover the whole screen (see
/// `ControllerHubViewModel`).
enum ControllerHubModelBuilder {
  static func make(
    state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind, page: ControllerHubPage = .root
  ) -> MenuModel {
    if page == .touchControls {
      let sections = platform == .ios ? [touchControlsSection(state: state, actions: actions)] : []
      return MenuModel(sections: sections, focusRequest: state.focusRequest)
    }
    var sections: [MenuSection] = []
    if platform == .ios {
      sections.append(onScreenSection(state: state, actions: actions))
    }
    sections += playerSections(state: state, actions: actions, platform: platform)
    sections.append(devicesSection(state: state, actions: actions, platform: platform))
    if !state.phones.isEmpty { sections.append(phonesSection(state: state, actions: actions)) }
    sections.append(motionSection(state: state, actions: actions))
    sections.append(helpSection(platform: platform))
    return MenuModel(sections: sections, focusRequest: state.focusRequest)
  }

  // MARK: On-Screen Controls (iOS)

  static let onScreenControllerRowID = "touch-controller"

  /// The one-step switch, the show toggle (in a game) and the push to Touch Controls.
  private static func onScreenSection(state: ControllerHubState, actions: ControllerHubActions) -> MenuSection {
    var items: [MenuItem] = []
    // A GameCube title has one controller to be: nothing to choose.
    let options = OnScreenController.options(for: state.system)
    if state.system != .gamecube {
      let current = state.pending.onScreenController
        ?? OnScreenController.current(overlayMode: state.overlayMode, players: state.players)
      items.append(MenuItem(
        id: onScreenControllerRowID, title: L("Controller"), icon: "rectangle.3.group",
        role: .cycle(options: options.map { ($0.title, AnyHashable($0)) }, selection: Binding(
          get: { AnyHashable(current) },
          set: { if let choice = $0.base as? OnScreenController { actions.setOnScreenController(choice) } })),
        description: L("What the on-screen controls are. One choice makes them Player 1 of that kind. Auto follows the game.")))
    }
    // Visibility is re-derived at every game start, so it only means something in a game.
    if state.isGameRunning {
      items.append(MenuItem(
        id: "touch-visible", title: L("Show Touch Controls"), icon: "hand.tap",
        role: .toggle(Binding(get: { state.overlayVisible }, set: { actions.setOverlayVisible($0) })),
        description: L("Draw the on-screen controller over the game.")))
    }
    items.append(MenuItem(
      id: "touch-settings", title: L("Layout, Skins & Opacity…"), icon: "paintpalette",
      role: .destination(actions.touchControlsDestination()),
      description: L("How the on-screen controls look and where they sit.")))
    return MenuSection(id: "on-screen", header: L("On-Screen Controls"), items: items)
  }

  // MARK: Players: a section per port (spec 7.1, deviation: rows, not pills)

  static func playerSectionID(_ player: PlayerState) -> String { "player-" + player.id }

  /// A section per shown port, headed by the port's name: Device, then (bound ports) Plays as and
  /// the pointer rows, then the push to the port's own screen. The last section holds Show All Ports.
  private static func playerSections(state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> [MenuSection] {
    let bound = state.players.filter(\.isBound)
    let shown = state.showAllPorts ? state.players : bound
    var sections: [MenuSection] = []
    for player in shown {
      let playsAs = state.pending.playsAs[player.id] ?? PlaysAs.current(of: player)
      var items = [deviceRow(for: player, state: state, actions: actions, platform: platform)]
      // An unbound port has nothing to play as and no pointer.
      if player.isBound {
        let options = PlaysAs.options(for: state.system)
        if options.count > 1 {
          items.append(MenuItem(
            id: "\(player.id)-plays-as", title: L("Plays as"), icon: "person.crop.rectangle",
            role: .cycle(options: options.map { ($0.title, AnyHashable($0)) }, selection: Binding(
              get: { AnyHashable(playsAs) },
              set: { if let value = $0.base as? PlaysAs { actions.setPlaysAs(player, value) } })),
            description: L("The controller the game sees. Switching between Wii and GameCube moves this player; a player already there trades places.")))
        }
        items += pointerRows(for: player, state: state, actions: actions, platform: platform)
      }
      items.append(MenuItem(
        id: player.id, title: L("Buttons, Profiles & Motion…"), icon: player.kind == .gameCube ? "gamecontroller" : "wand.and.rays",
        role: .destination(actions.playerDestination(player)),
        description: L("Remap buttons, profiles, motion and advanced settings.")))
      sections.append(MenuSection(id: playerSectionID(player), header: player.title, items: items))
    }
    let hiddenCount = state.players.count - bound.count
    if hiddenCount > 0 {
      sections.append(MenuSection(id: "ports", items: [MenuItem(
        id: "show-all-ports", title: state.showAllPorts ? L("Hide Unused Ports") : L("Show All Ports"),
        icon: state.showAllPorts ? "chevron.up" : "chevron.down",
        role: .action(actions.toggleShowAllPorts), badge: state.showAllPorts ? nil : String(hiddenCount))]))
    }
    return sections
  }

  /// The player screen's Device list (`PlayerScreenModelBuilder.deviceOptions`), as a cycle.
  private static func deviceRow(for player: PlayerState, state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuItem {
    let committed = PlayerDeviceChoice(qualifier: player.deviceQualifier)
    let options = PlayerScreenModelBuilder.deviceOptions(
      isPinned: player.isPinned, current: committed, pads: state.pads,
      currentTitle: deviceName(for: player, pads: state.pads), platform: platform)
    let shown = state.pending.devices[player.id] ?? committed
    return MenuItem(
      id: "\(player.id)-device", title: L("Device"), icon: player.isPinned ? "pin.fill" : "gamecontroller",
      role: .cycle(options: options.map { ($0.title, AnyHashable($0.choice)) }, selection: Binding(
        get: { AnyHashable(shown) },
        set: { if let choice = $0.base as? PlayerDeviceChoice { actions.setDevice(player, choice) } })),
      description: player.isPinned ? PlayerScreenHelp.devicePinned : PlayerScreenHelp.device)
  }

  /// The pointer rows under a bound Wii Remote:
  /// - iOS touchscreen: the Follow / Drag / Gyro cycle, labelled with the source it gives.
  /// - Wii Remote 1 otherwise (and tvOS whatever holds it): Pointer Source (Automatic plus every
  ///   source this setup can drive), then "Aim with Controller Motion" when the pad's gyro is it.
  /// - Wii Remotes 2-4 on a gyro pad: the motion toggle, labelled with the pad. Otherwise none.
  private static func pointerRows(for player: PlayerState, state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> [MenuItem] {
    guard player.kind == .wiiRemote, player.isBound else { return [] }
    let source = player.port == 1 ? state.pointerSource : nil
    let pad = state.pads.first { $0.qualifier == player.deviceQualifier }
    if DeviceFamily.from(qualifier: player.deviceQualifier) == .touchscreen, platform == .ios {
      return [MenuItem(
        id: "\(player.id)-pointer", title: L("Pointer"), subtitle: source?.headline, icon: state.pointerMode.systemImage,
        role: .cycle(options: PlayerScreenModelBuilder.pointerModes.map { ($0.title, AnyHashable($0)) }, selection: Binding(
          get: { AnyHashable(state.pointerMode) },
          set: { if let mode = $0.base as? PointerMode { actions.setPointerMode(mode) } })),
        badge: state.pointerIsThisGameOnly ? L("This game") : nil,
        description: L("How the Wii pointer moves: follow your finger, drag it, or tilt the device."))]
    }
    if let source {
      var items = [pointerSourceRow(id: "\(player.id)-pointer-source", source: source, setOverride: actions.setPointerSourceOverride)]
      if case .padGyro = source.source, pad?.hasGyro == true {
        items.append(MenuItem(
          id: "\(player.id)-pointer", title: L("Aim with Controller Motion"), icon: "gyroscope",
          role: .toggle(Binding(get: { player.motionPointerEnabled }, set: { actions.setMotionPointer(player, $0) })),
          description: L("Aim with the controller's gyro.")))
      }
      return items
    }
    guard let pad, pad.hasGyro else { return [] }
    return [MenuItem(
      id: "\(player.id)-pointer", title: L("Pointer"),
      subtitle: String(format: L("Pointer: %@"), PointerSource.padGyro(padName: pad.name).label(deviceModel: "")), icon: "gyroscope",
      role: .toggle(Binding(get: { player.motionPointerEnabled }, set: { actions.setMotionPointer(player, $0) })),
      description: L("Aim with the controller's gyro."))]
  }

  /// Wii Remote 1's Pointer Source: a cycle of Automatic and every source this setup can drive,
  /// subtitled with the one in use. With no choice at all it is an enabled no-op (tvOS focus must
  /// reach it, as the Help rows do) that says why nothing aims. The player screen uses it too.
  static func pointerSourceRow(id: String, source: PointerSourceModel, setOverride: @escaping (PointerSource.Kind?) -> Void) -> MenuItem {
    guard !source.choices.isEmpty else {
      return MenuItem(
        id: id, title: L("Pointer Source"), subtitle: source.explanation, icon: source.source.systemImage, role: .action({}),
        badge: source.label)
    }
    return MenuItem(
      id: id, title: L("Pointer Source"), subtitle: source.headline, icon: source.source.systemImage,
      role: .cycle(options: source.options, selection: Binding(
        get: { AnyHashable(source.selectedTag) },
        set: { setOverride(PointerSourceModel.override(forTag: $0)) })),
      description: source.rowDescription)
  }

  private static func deviceName(for player: PlayerState, pads: [ConnectedPadState]) -> String {
    let qualifier = player.deviceQualifier
    if qualifier.isEmpty { return L("No Device") }
    if DeviceFamily.from(qualifier: qualifier) == .touchscreen { return L("Touchscreen") }
    if let pad = pads.first(where: { $0.qualifier == qualifier }) { return pad.name }
    let name = qualifier.split(separator: "/", maxSplits: 2).last.map(String.init) ?? qualifier
    // Only a missing MFi pad is "Disconnected" (its binding returns with the pad); a DSU device is
    // never in the pad list. The player screen uses the same rule.
    return PlayerScreenState.isMissing(qualifier, pads: pads) ? String(format: L("%@ (Disconnected)"), name) : name
  }

  // MARK: Touch Controls page (iOS)

  private static func touchControlsSection(state: ControllerHubState, actions: ControllerHubActions) -> MenuSection {
    var items: [MenuItem] = []
    items.append(MenuItem(
      id: "touch-opacity", title: L("Opacity"), icon: "circle.lefthalf.filled",
      role: .cycle(options: ControllerHubState.opacityChoices.map { ("\($0)%", AnyHashable($0)) }, selection: Binding(
        get: { AnyHashable(state.overlayOpacityPercent) },
        set: { if let percent = $0.base as? Int { actions.setOverlayOpacity(Float(percent) / 100) } })),
      description: L("How see-through the on-screen controls are.")))
    items.append(MenuItem(
      id: "touch-editable", title: L("Editable Controls"), icon: "slider.horizontal.below.rectangle",
      role: .toggle(Binding(get: { state.touchOverlayProgrammatic }, set: { actions.setTouchOverlayProgrammatic($0) })),
      description: L("On by default: controls you can move and resize from Edit Layout or with a long press in-game. Off uses the older fixed pads.")))
    items.append(MenuItem(
      id: "touch-edit-layout", title: L("Edit Layout…"), icon: "rectangle.and.pencil.and.ellipsis", role: .action(actions.editLayout),
      description: L("Move and resize the on-screen controls on the game's own screen.")))
    // The IR area is where a touch moves the Wii pointer; a GameCube game has no pointer.
    if state.system != .gamecube {
      items.append(MenuItem(
        id: "touch-edit-ir-area", title: L("Edit IR Area…"), icon: "scope", role: .action(actions.editIRArea),
        description: L("Where a touch moves the Wii pointer.")))
    }
    items.append(MenuItem(
      id: "touch-skins", title: L("Skins…"), icon: "paintpalette", role: .destination(actions.skinsDestination()),
      description: L("Artwork for the on-screen controller.")))
    items.append(MenuItem(
      id: "touch-stick-feel", title: L("On-Screen Stick Feel…"), icon: "l.joystick", role: .destination(actions.stickFeelDestination()),
      description: L("Gain, dead zone and smoothing of the on-screen sticks and triggers.")))
    items.append(MenuItem(
      id: "touch-reset-layouts", title: L("Reset All Layouts"), icon: "arrow.counterclockwise", role: .destructive(actions.resetOverlayLayouts),
      description: L("Put every on-screen layout back to its default.")))
    return MenuSection(id: "touch-controls", items: items)
  }

  // MARK: Motion

  private static func motionSection(state: ControllerHubState, actions: ControllerHubActions) -> MenuSection {
    MenuSection(id: "motion", header: L("Motion"), items: [MenuItem(
      id: "dsu", title: L("Motion Source (DSU)"), subtitle: dsuSummary(state), icon: "dot.radiowaves.left.and.right",
      role: .destination(actions.dsuDestination()),
      description: L("Use a phone or a DSU server as a motion controller."))])
  }

  /// What is about physical pads as a group, under the pad list.
  private static func padOptionRows(state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> [MenuItem] {
    var items: [MenuItem] = []
    if platform == .ios {
      items.append(MenuItem(
        id: "takes-player-1", title: L("Controllers Take Player 1"), icon: "1.circle",
        role: .toggle(Binding(get: { state.connectTakesPlayer1 }, set: { actions.setConnectTakesPlayer1($0) })),
        description: L("A controller that connects while the on-screen controls are Player 1 becomes Player 1, even if you chose the on-screen controls there.")))
      items.append(MenuItem(
        id: "rumble", title: L("Rumble Output"), icon: "waveform",
        role: .cycle(options: RumbleDestination.allCases.map { ($0.title, AnyHashable($0)) }, selection: Binding(
          get: { AnyHashable(state.rumbleDestination) },
          set: { if let value = $0.base as? RumbleDestination { actions.setRumbleDestination(value) } })),
        description: L("Where a game's rumble goes.")))
      items.append(MenuItem(
        id: "rumble-test", title: L("Test Rumble"), icon: "waveform.path", role: .action(actions.testRumble),
        description: L("A short pulse on the chosen output.")))
    }
    items.append(MenuItem(
      id: "background-input", title: L("Background Input"), icon: "rectangle.on.rectangle",
      role: .toggle(Binding(get: { state.backgroundInput }, set: { actions.setBackgroundInput($0) })),
      description: L("Keep reading controllers while another app is in front.")))
    return items
  }

  // MARK: Controllers (physical pads)

  private static func devicesSection(state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuSection {
    var items = state.pads.filter { !$0.isMenuRemote }.map { pad in
      MenuItem(
        id: "pad-\(pad.qualifier)", title: pad.name, subtitle: batteryText(for: pad), icon: "gamecontroller.fill",
        role: .action { actions.identifyPad(pad.qualifier) }, badge: pad.playerLabel)
    }
    if items.isEmpty {
      items.append(MenuItem(id: "no-pads", title: L("No controllers connected"), role: .action({}), isEnabled: false))
    }
    // A menu remote plays nothing: a read-only caption, like the placeholder above. The id carries
    // the index because a remote the ControllerInterface has not enumerated yet has no qualifier.
    for (index, remote) in state.pads.filter(\.isMenuRemote).enumerated() {
      items.append(MenuItem(
        id: "remote-\(index)", title: remote.name, subtitle: L("Siri Remote — menus and quick actions only"),
        icon: "appletvremote.gen4", role: .action({}), isEnabled: false))
    }
    if platform == .ios, state.pads.contains(where: \.hasLight) {
      items.append(MenuItem(
        id: "lights", title: L("Controller Lights"), icon: "lightbulb", role: .destination(actions.lightsDestination()),
        description: L("The colour of each controller's light bar.")))
    }
    items += padOptionRows(state: state, actions: actions, platform: platform)
    return MenuSection(id: "devices", header: L("Controllers"), items: items)
  }

  // MARK: Phones

  /// One row per advertising phone. An added phone already has its row, so its row connects nothing (an
  /// enabled no-op: tvOS focus must reach it, as the Help rows do).
  private static func phonesSection(state: ControllerHubState, actions: ControllerHubActions) -> MenuSection {
    MenuSection(id: "phones", header: L("Phones"), items: state.phones.map { phone in
      MenuItem(
        id: "phone-\(phone.pid)", title: phone.name, icon: "iphone.radiowaves.left.and.right",
        role: .action { if !phone.isAdded { actions.connectPhone(phone.pid) } },
        badge: phone.isAdded ? L("Added") : L("Connect"))
    })
  }

  private static func batteryText(for pad: ConnectedPadState) -> String? {
    guard let percent = pad.batteryPercent else { return nil }
    return pad.isCharging
      ? String(format: L("Battery %d%% · Charging"), percent)
      : String(format: L("Battery %d%%"), percent)
  }

  private static func dsuSummary(_ state: ControllerHubState) -> String {
    guard state.dsuClientEnabled else { return L("Off") }
    if state.dsuServerCount == 1 { return L("On · 1 server") }
    return String(format: L("On · %d servers"), state.dsuServerCount)
  }

  // MARK: Help

  /// Enabled no-op rows: a tvOS List scrolls only by focus, and a disabled row takes none.
  private static func helpSection(platform: PlatformKind) -> MenuSection {
    MenuSection(id: "help", header: L("Help"), items: ControllerHelp.lines(platform: platform).map { line in
      MenuItem(id: "help-\(line.id)", title: line.action, subtitle: line.how, role: .action({}))
    })
  }
}
