// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Which controller the on-screen controls are: Auto (whatever the running game's system uses), or
/// one emulated controller. Picking a controller is one step: the touchscreen becomes Player 1 of
/// that kind, a Wii Remote gets its extension and sideways flag, and that pad is drawn. Before this
/// the same change took three (which pad is drawn, the player's Plays as, and freeing the port the
/// move wanted), and a Wii game that needs a GameCube pad was a chore to set up.
enum OnScreenController: Hashable {
  case auto
  case fixed(PlaysAs)

  var title: String {
    switch self {
    case .auto: return L("Auto")
    case .fixed(let controller): return controller.title
    }
  }

  /// Auto first, then every controller the listed ports can be (`PlaysAs.options`).
  static func options(for system: ControllerSetupSystem) -> [OnScreenController] {
    [.auto] + PlaysAs.options(for: system).map(OnScreenController.fixed)
  }

  /// What the stored state amounts to: the drawn pad (`overlayMode`), and for a Wii pad what Wii
  /// Remote 1 plays as.
  static func current(overlayMode: ControllerManager.OverlayMode, players: [PlayerState]) -> OnScreenController {
    switch overlayMode {
    case .auto:
      return .auto
    case .gamecube:
      return .fixed(.gameCube)
    case .wii:
      guard let remote = players.first(where: { $0.kind == .wiiRemote && $0.port == OnScreenControllerPlan.port }) else {
        return .fixed(.wiiRemote)
      }
      return .fixed(PlaysAs.current(of: remote))
    }
  }
}

enum OnScreenControllerStep: Equatable {
  /// Binds the touchscreen to the slot (and pins it, as any explicit device choice does).
  case bindTouchscreen(PlayerSlot)
  case setExtension(wiimote: Int, value: Int)
  case setSideways(wiimote: Int, enabled: Bool)
  case setOverlayMode(ControllerManager.OverlayMode)
}

/// The ordered writes an on-screen controller choice needs. Pure, so the order is tested; the hub
/// view model runs the steps.
enum OnScreenControllerPlan {
  /// The on-screen controls are always Player 1 of their kind: `ControllerManager.overlayMode = .wii`
  /// has taken Wii Remote 1 for the touchscreen since the first overlay switch, and the top bar's
  /// Player 1 picker does the same for a GameCube port.
  static let port = 1

  static func steps(for choice: OnScreenController, players: [PlayerState]) -> [OnScreenControllerStep] {
    guard case .fixed(let controller) = choice else { return [.setOverlayMode(.auto)] }
    let slot = PlayerSlot(kind: controller.kind, port: port)
    var steps: [OnScreenControllerStep] = []
    let holder = players.first { $0.kind == slot.kind && $0.port == slot.port }
    if holder.map({ PlayerDeviceChoice(qualifier: $0.deviceQualifier) }) != .touchscreen {
      steps.append(.bindTouchscreen(slot))
    }
    if controller.kind == .wiiRemote {
      steps.append(.setExtension(wiimote: port, value: controller.wiiExtension))
      steps.append(.setSideways(wiimote: port, enabled: controller.isSideways))
    }
    // Last: the drawn pad follows a binding that already exists.
    steps.append(.setOverlayMode(controller.kind == .gameCube ? .gamecube : .wii))
    return steps
  }
}

/// The on-screen controller of the running game, for the surfaces outside the hub (the top bar's
/// Controller menu, the pause menu's Controllers tile). Reads and writes through the hub's view
/// model, so every surface makes exactly the hub's change.
@MainActor
enum OnScreenControllerLive {
  /// Auto and every controller the running game's ports can be; empty for a GameCube title, which
  /// has nothing to choose.
  static func options() -> [OnScreenController] {
    let system = ControllerSetupSystem.forRunningGame
    return system == .gamecube ? [] : OnScreenController.options(for: system)
  }

  static func current() -> OnScreenController {
    let model = ControllerHubViewModel(system: .forRunningGame)
    model.reload()
    return OnScreenController.current(overlayMode: model.state.overlayMode, players: model.state.players)
  }

  static func apply(_ choice: OnScreenController) {
    ControllerHubViewModel(system: .forRunningGame).setOnScreenController(choice)
  }
}
