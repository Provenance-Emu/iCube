// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Builds the Controllers hub (controller hub spec, "Controllers hub"):
/// - Players: a row group per port (title, Device, Plays as, Pointer), unbound ports under "Show All Ports".
/// - Touch Controls (iOS).
/// - Connected Devices.
/// - Setup.
/// - Help.
///
/// Pure: state and actions in, `MenuModel` out, no bridge calls, mirroring `PauseMenuModelBuilder`
/// and `CheatsMenuModelBuilder`. Rows that open something PUSH (`.destination`), except Edit
/// Layout… and Edit IR Area…, actions: their editors must cover the whole screen (see
/// `ControllerHubViewModel`).
enum ControllerHubModelBuilder {
  static func make(state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuModel {
    var sections = [playersSection(state: state, actions: actions, platform: platform)]
    if platform == .ios {
      sections.append(touchControlsSection(state: state, actions: actions))
    }
    sections.append(devicesSection(state: state, actions: actions, platform: platform))
    sections.append(setupSection(state: state, actions: actions, platform: platform))
    sections.append(helpSection(platform: platform))
    return MenuModel(sections: sections, focusRequest: state.focusRequest)
  }

  // MARK: Players: a group per port (spec 7.1, deviation: rows, not pills)

  private static func playersSection(state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuSection {
    let bound = state.players.filter(\.isBound)
    let shown = state.showAllPorts ? state.players : bound
    var items: [MenuItem] = []
    for player in shown {
      let playsAs = state.pending.playsAs[player.id] ?? PlaysAs.current(of: player)
      items.append(MenuItem(
        id: player.id, title: player.title, icon: player.kind == .gameCube ? "gamecontroller" : "wand.and.rays",
        role: .destination(actions.playerDestination(player)),
        badge: player.isBound ? playsAs.title : nil,
        description: L("Remap buttons, profiles, motion and advanced settings.")))
      items.append(deviceRow(for: player, state: state, actions: actions, platform: platform))
      // An unbound port has nothing to play as and no pointer: title and Device only.
      guard player.isBound else { continue }
      let options = PlaysAs.options(for: state.system)
      if options.count > 1 {
        items.append(MenuItem(
          id: "\(player.id)-plays-as", title: L("Plays as"), icon: "person.crop.rectangle",
          role: .cycle(options: options.map { ($0.title, AnyHashable($0)) }, selection: Binding(
            get: { AnyHashable(playsAs) },
            set: { if let value = $0.base as? PlaysAs { actions.setPlaysAs(player, value) } })),
          description: L("The controller the game sees. Wii Remote choices move this player to a Wii Remote slot; GameCube Controller moves it to a GameCube port.")))
      }
      if let pointer = pointerRow(for: player, state: state, actions: actions, platform: platform) {
        items.append(pointer)
      }
    }
    let hiddenCount = state.players.count - bound.count
    if hiddenCount > 0 {
      items.append(MenuItem(
        id: "show-all-ports", title: state.showAllPorts ? L("Hide Unused Ports") : L("Show All Ports"),
        icon: state.showAllPorts ? "chevron.up" : "chevron.down",
        role: .action(actions.toggleShowAllPorts), badge: state.showAllPorts ? nil : String(hiddenCount)))
    }
    return MenuSection(id: "players", header: L("Players"), items: items)
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

  /// Touchscreen Wii Remote (iOS): the pointer mode. Gyro pad: Motion on/off. Otherwise none.
  private static func pointerRow(for player: PlayerState, state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuItem? {
    guard player.kind == .wiiRemote, player.isBound else { return nil }
    if DeviceFamily.from(qualifier: player.deviceQualifier) == .touchscreen {
      guard platform == .ios else { return nil }
      return MenuItem(
        id: "\(player.id)-pointer", title: L("Pointer"), icon: state.pointerMode.systemImage,
        role: .cycle(options: PlayerScreenModelBuilder.pointerModes.map { ($0.title, AnyHashable($0)) }, selection: Binding(
          get: { AnyHashable(state.pointerMode) },
          set: { if let mode = $0.base as? PointerMode { actions.setPointerMode(mode) } })),
        badge: state.pointerIsThisGameOnly ? L("This game") : nil,
        description: L("How the Wii pointer moves: follow your finger, drag it, or tilt the device."))
    }
    guard state.pads.first(where: { $0.qualifier == player.deviceQualifier })?.hasGyro == true else { return nil }
    return MenuItem(
      id: "\(player.id)-pointer", title: L("Pointer"), icon: "gyroscope",
      role: .toggle(Binding(get: { player.motionPointerEnabled }, set: { actions.setMotionPointer(player, $0) })),
      description: L("Aim with the controller's gyro."))
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

  // MARK: Touch Controls (iOS; was On-Screen Controls)

  private static func touchControlsSection(state: ControllerHubState, actions: ControllerHubActions) -> MenuSection {
    var items: [MenuItem] = []
    // Visibility and layout are re-derived at every game start, so they only mean something in a
    // game. Layout also has a side effect (choosing Wii binds Wii Remote 1 to the touchscreen), which
    // should only fire from a running game, not from Settings.
    if state.isGameRunning {
      items.append(MenuItem(
        id: "touch-visible", title: L("Show Touch Controls"), icon: "hand.tap",
        role: .toggle(Binding(get: { state.overlayVisible }, set: { actions.setOverlayVisible($0) })),
        description: L("Draw the on-screen controller over the game.")))
      let layouts: [(String, AnyHashable)] = [
        (L("Auto"), AnyHashable(ControllerManager.OverlayMode.auto)),
        (L("GameCube"), AnyHashable(ControllerManager.OverlayMode.gamecube)),
        (L("Wii Remote"), AnyHashable(ControllerManager.OverlayMode.wii)),
      ]
      items.append(MenuItem(
        id: "touch-layout", title: L("Layout"), icon: "rectangle.3.group",
        role: .cycle(options: layouts, selection: Binding(
          get: { AnyHashable(state.pending.overlayMode ?? state.overlayMode) },
          set: { if let mode = $0.base as? ControllerManager.OverlayMode { actions.setOverlayMode(mode) } })),
        description: L("Which on-screen controller is drawn. Auto follows the running game's system and the attached controllers, not any player's Plays as.")))
    }
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
      id: "touch-reset-layouts", title: L("Reset All Layouts"), icon: "arrow.counterclockwise", role: .destructive(actions.resetOverlayLayouts),
      description: L("Put every on-screen layout back to its default.")))
    return MenuSection(id: "touch-controls", header: L("Touch Controls"), items: items)
  }

  // MARK: Setup (was More Controller Settings)

  private static func setupSection(state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuSection {
    var items = [MenuItem(
      id: "background-input", title: L("Background Input"), icon: "rectangle.on.rectangle",
      role: .toggle(Binding(get: { state.backgroundInput }, set: { actions.setBackgroundInput($0) })),
      description: L("Keep reading controllers while another app is in front."))]
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
      id: "dsu", title: L("Motion Source (DSU)"), subtitle: dsuSummary(state), icon: "dot.radiowaves.left.and.right",
      role: .destination(actions.dsuDestination()),
      description: L("Use a phone or a DSU server as a motion controller.")))
    return MenuSection(id: "setup", header: L("Setup"), items: items)
  }

  // MARK: Connected Devices

  private static func devicesSection(state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuSection {
    var items = state.pads.map { pad in
      MenuItem(
        id: "pad-\(pad.qualifier)", title: pad.name, subtitle: batteryText(for: pad), icon: "gamecontroller.fill",
        role: .action { actions.identifyPad(pad.qualifier) }, badge: pad.playerLabel)
    }
    if items.isEmpty {
      items.append(MenuItem(id: "no-pads", title: L("No controllers connected"), role: .action({}), isEnabled: false))
    }
    if platform == .ios, state.pads.contains(where: \.hasLight) {
      items.append(MenuItem(
        id: "lights", title: L("Controller Lights"), icon: "lightbulb", role: .destination(actions.lightsDestination()),
        description: L("The colour of each controller's light bar.")))
    }
    return MenuSection(id: "devices", header: L("Connected Devices"), items: items)
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
