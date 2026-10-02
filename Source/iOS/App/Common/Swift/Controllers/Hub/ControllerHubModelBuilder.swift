// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Builds the Controllers hub (controller hub spec, "Controllers hub"):
/// - Players, with unbound ports under "Show All Ports".
/// - On-Screen Controls (iOS).
/// - Connected Devices.
/// - More.
/// - Help.
///
/// Pure: state and actions in, `MenuModel` out, no bridge calls, mirroring `PauseMenuModelBuilder`
/// and `CheatsMenuModelBuilder`. Rows that open something PUSH (`.destination`); nothing here
/// presents.
enum ControllerHubModelBuilder {
  static func make(state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuModel {
    var sections = [playersSection(state: state, actions: actions)]
    if platform == .ios {
      sections.append(onScreenSection(state: state, actions: actions))
    }
    sections.append(devicesSection(state: state, actions: actions))
    sections.append(MenuSection(id: "more", items: [
      MenuItem(
        id: "more-settings", title: L("More Controller Settings"), icon: "slider.horizontal.3",
        role: .destination(actions.moreSettingsDestination())),
    ]))
    sections.append(helpSection(platform: platform))
    return MenuModel(sections: sections)
  }

  // MARK: Players

  private static func playersSection(state: ControllerHubState, actions: ControllerHubActions) -> MenuSection {
    let bound = state.players.filter(\.isBound)
    let shown = state.showAllPorts ? state.players : bound
    var items = shown.map { player in
      MenuItem(
        id: player.id,
        title: title(for: player),
        subtitle: "\(deviceName(for: player, pads: state.pads)) · \(emulatedController(for: player))",
        icon: player.kind == .gameCube ? "gamecontroller" : "wand.and.rays",
        role: .destination(actions.playerDestination(player)))
    }
    let hiddenCount = state.players.count - bound.count
    if hiddenCount > 0 {
      items.append(MenuItem(
        id: "show-all-ports",
        title: state.showAllPorts ? L("Hide Unused Ports") : L("Show All Ports"),
        icon: state.showAllPorts ? "chevron.up" : "chevron.down",
        role: .action(actions.toggleShowAllPorts),
        badge: state.showAllPorts ? nil : String(hiddenCount)))
    }
    return MenuSection(id: "players", header: L("Players"), items: items)
  }

  private static func title(for player: PlayerState) -> String {
    String(format: player.kind == .gameCube ? L("Player %d") : L("Wii Remote %d"), player.port)
  }

  private static func deviceName(for player: PlayerState, pads: [ConnectedPadState]) -> String {
    let qualifier = player.deviceQualifier
    if qualifier.isEmpty { return L("No Device") }
    if DeviceFamily.from(qualifier: qualifier) == .touchscreen { return L("Touchscreen") }
    if let pad = pads.first(where: { $0.qualifier == qualifier }) { return pad.name }
    // Bound, but the pad is not connected: the binding is kept and returns with the pad.
    let name = qualifier.split(separator: "/", maxSplits: 2).last.map(String.init) ?? qualifier
    return String(format: L("%@ (Disconnected)"), name)
  }

  private static func emulatedController(for player: PlayerState) -> String {
    switch player.kind {
    case .gameCube:
      return L("GameCube Controller")
    case .wiiRemote:
      switch player.wiiExtension {
      case 1: return L("Wii Remote + Nunchuk")
      case 2: return L("Wii Remote + Classic Controller")
      default: return player.isSideways ? L("Wii Remote (Sideways)") : L("Wii Remote")
      }
    }
  }

  // MARK: On-Screen Controls (iOS)

  private static func onScreenSection(state: ControllerHubState, actions: ControllerHubActions) -> MenuSection {
    var items: [MenuItem] = []
    // Visibility and style are re-derived at every game start, so they only mean something in a
    // game. Style also has a side effect (choosing Wii binds Wii Remote 1 to the touchscreen), which
    // should only fire from a running game, not from Settings.
    if state.isGameRunning {
      items.append(MenuItem(
        id: "osc-visible", title: L("Show On-Screen Controls"), icon: "hand.tap",
        role: .toggle(Binding(get: { state.overlayVisible }, set: { actions.setOverlayVisible($0) }))))
      let styles: [(String, AnyHashable)] = [
        (L("Auto"), AnyHashable(ControllerManager.OverlayMode.auto)),
        (L("GameCube"), AnyHashable(ControllerManager.OverlayMode.gamecube)),
        (L("Wii"), AnyHashable(ControllerManager.OverlayMode.wii)),
      ]
      items.append(MenuItem(
        id: "osc-style", title: L("On-Screen Style"), icon: "rectangle.3.group",
        role: .picker(options: styles, selection: Binding(
          get: { AnyHashable(state.overlayMode) },
          set: { if let mode = $0.base as? ControllerManager.OverlayMode { actions.setOverlayMode(mode) } }))))
    }
    items.append(MenuItem(
      id: "osc-opacity", title: L("Opacity"), icon: "circle.lefthalf.filled",
      role: .picker(
        options: ControllerHubState.opacityChoices.map { ("\($0)%", AnyHashable($0)) },
        selection: Binding(
          get: { AnyHashable(state.overlayOpacityPercent) },
          set: { if let percent = $0.base as? Int { actions.setOverlayOpacity(Float(percent) / 100) } }))))
    items.append(MenuItem(
      id: "osc-edit-layout", title: L("Edit Layout…"), icon: "rectangle.and.pencil.and.ellipsis",
      role: .destination(actions.editLayoutDestination())))
    items.append(MenuItem(
      id: "osc-skins", title: L("Skins…"), icon: "paintpalette",
      role: .destination(actions.skinsDestination())))
    return MenuSection(id: "on-screen", header: L("On-Screen Controls"), items: items)
  }

  // MARK: Connected Devices

  private static func devicesSection(state: ControllerHubState, actions: ControllerHubActions) -> MenuSection {
    var items = state.pads.map { pad in
      MenuItem(
        id: "pad-\(pad.qualifier)", title: pad.name, subtitle: batteryText(for: pad), icon: "gamecontroller.fill",
        role: .action { actions.identifyPad(pad.qualifier) }, badge: pad.playerLabel)
    }
    if items.isEmpty {
      items.append(MenuItem(id: "no-pads", title: L("No controllers connected"), role: .action({}), isEnabled: false))
    }
    if state.system.showsWii {
      items.append(MenuItem(
        id: "wiimote-scan", title: L("Continuous Wii Remote Scanning"), icon: "antenna.radiowaves.left.and.right",
        role: .toggle(Binding(get: { state.continuousScanning }, set: { actions.setContinuousScanning($0) }))))
    }
    items.append(MenuItem(
      id: "dsu", title: L("Motion Source (DSU)"), subtitle: dsuSummary(state), icon: "dot.radiowaves.left.and.right",
      role: .destination(actions.dsuDestination())))
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
