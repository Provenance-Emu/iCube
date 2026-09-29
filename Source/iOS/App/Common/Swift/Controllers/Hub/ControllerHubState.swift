// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Which ports a controller screen lists. Distinct from `EmulatedSystem` (which the assignment
/// service switches on exhaustively) so `.both` can never leak into the service. Moved here from
/// `ControllerSetupView.swift`, which Phase 4 deletes.
enum ControllerSetupSystem {
  case gamecube
  case wii
  case both
  /// A running Wii title: Wii Remotes first, then the GameCube ports many Wii games also accept.
  case wiiAndGameCube

  var showsGameCube: Bool { self == .gamecube || self == .both || self == .wiiAndGameCube }
  var showsWii: Bool { self == .wii || self == .both || self == .wiiAndGameCube }
  var wiiFirst: Bool { self == .wiiAndGameCube }
}

extension ControllerSetupSystem {
  /// The ports the running game accepts: Wii titles get Wii Remotes and GameCube ports,
  /// GameCube titles the ports only. Read from the running core, not `ControllerManager.isWiiSystem`.
  static var forRunningGame: ControllerSetupSystem {
    let isWii = TVEmulationBridge.isRunning() ? TVEmulationBridge.isCurrentSystemWii() : ControllerManager.shared.isWiiSystem
    return isWii ? .wiiAndGameCube : .gamecube
  }

  /// Settings → Controllers: the running game's ports while one runs (Settings opened from the pause
  /// menu, so it matches the pause menu's hub), otherwise every GameCube port and Wii Remote.
  static var forSettings: ControllerSetupSystem {
    TVEmulationBridge.isRunning() ? forRunningGame : .both
  }
}

extension PlatformKind {
  static var current: PlatformKind {
    #if os(tvOS)
    return .tvos
    #else
    return .ios
    #endif
  }
}

/// One port as the hub shows it.
struct PlayerState: Equatable {
  enum Kind: Equatable {
    case gameCube
    case wiiRemote
  }

  let kind: Kind
  /// 1-based.
  let port: Int
  /// The bound device (`MFi/0/Xbox Wireless Controller`, `iOS/4/Touchscreen`), or "" when the
  /// port is off. A port's stock default device is the touchscreen even while the port is off,
  /// so the reader reports "" for an inactive port, never the stored qualifier.
  let deviceQualifier: String
  /// 0 None, 1 Nunchuk, 2 Classic (`WiimoteSlotOptions`). 0 for GameCube ports.
  let wiiExtension: Int
  let isSideways: Bool

  var id: String { (kind == .gameCube ? "gc-" : "wii-") + String(port) }
  var isBound: Bool { !deviceQualifier.isEmpty }
}

struct PlayerSlot: Equatable {
  let kind: PlayerState.Kind
  let port: Int
}

/// One connected pad, read from `GCController` by the view model.
struct ConnectedPadState: Equatable {
  /// `TVControllerMappingBridge.qualifiedName(for:)`, unique per pad (it carries the index).
  let qualifier: String
  let name: String
  /// nil while the pad reports no battery.
  let batteryPercent: Int?
  let isCharging: Bool
  /// "P1"…"P4", nil when the pad has no player index.
  let playerLabel: String?
}

/// Plain snapshot of everything the hub shows. No bridge reads happen after it is built;
/// `ControllerHubViewModel` rebuilds it.
struct ControllerHubState {
  var system: ControllerSetupSystem
  var players: [PlayerState]
  /// "Show All Ports": list unbound ports too. UI state, kept across reloads.
  var showAllPorts: Bool
  var pads: [ConnectedPadState]
  var isGameRunning: Bool
  var overlayVisible: Bool
  var overlayMode: ControllerManager.OverlayMode
  /// One of `opacityChoices`.
  var overlayOpacityPercent: Int
  var continuousScanning: Bool
  var dsuClientEnabled: Bool
  var dsuServerCount: Int

  static func empty(system: ControllerSetupSystem) -> ControllerHubState {
    ControllerHubState(
      system: system, players: [], showAllPorts: false, pads: [], isGameRunning: false,
      overlayVisible: false, overlayMode: .auto, overlayOpacityPercent: 50,
      continuousScanning: false, dsuClientEnabled: false, dsuServerCount: 0)
  }

  /// Ports in on-screen order: a running Wii title lists its Wii Remotes first.
  static func slots(for system: ControllerSetupSystem) -> [PlayerSlot] {
    let gameCube = (1 ... 4).map { PlayerSlot(kind: .gameCube, port: $0) }
    let wii = (1 ... 4).map { PlayerSlot(kind: .wiiRemote, port: $0) }
    switch system {
    case .gamecube: return gameCube
    case .wii: return wii
    case .both: return gameCube + wii
    case .wiiAndGameCube: return wii + gameCube
    }
  }

  /// The on-screen controls' opacity steps. A slider cannot be reached by a pad on iOS or focused
  /// on tvOS; four steps can, and d-pad left/right cycles them.
  static let opacityChoices = [25, 50, 75, 100]

  /// The choice nearest the stored opacity (0…1), so the picker always shows a selection.
  static func snappedOpacityPercent(_ opacity: Float) -> Int {
    let percent = Int((opacity * 100).rounded())
    return opacityChoices.min { abs($0 - percent) < abs($1 - percent) } ?? 100
  }
}

/// Plain closures: no bridge calls inside `ControllerHubModelBuilder`. Destinations are factories
/// so the builder never names a bridge-backed view.
struct ControllerHubActions {
  var playerDestination: (PlayerState) -> AnyView
  var toggleShowAllPorts: () -> Void
  var setOverlayVisible: (Bool) -> Void
  var setOverlayMode: (ControllerManager.OverlayMode) -> Void
  /// 0…1.
  var setOverlayOpacity: (Float) -> Void
  var editLayoutDestination: () -> AnyView
  /// The pad's qualifier.
  var identifyPad: (String) -> Void
  var setContinuousScanning: (Bool) -> Void
  var dsuDestination: () -> AnyView
  var moreSettingsDestination: () -> AnyView
}
