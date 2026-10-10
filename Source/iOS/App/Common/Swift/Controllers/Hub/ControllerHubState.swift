// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Which ports a controller screen lists. Distinct from `EmulatedSystem` (which the assignment
/// service switches on exhaustively) so `.both` can never leak into the service. Moved here from
/// the old controller setup screen (deleted in Phase 4).
enum ControllerSetupSystem {
  case gamecube
  case wii
  case both
  /// A running Wii title: Wii Remotes first, then the GameCube ports many Wii games also accept.
  case wiiAndGameCube

  var showsGameCube: Bool { self == .gamecube || self == .both || self == .wiiAndGameCube }
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
  /// The user picked this port's device, so auto-assignment leaves it alone.
  var isPinned = false
  /// The Wii Remote's IMU pointer is on (`PlayerScreenIO.isMotionPointerEnabled`). Always false for
  /// GameCube ports.
  var motionPointerEnabled = false

  var id: String { (kind == .gameCube ? "gc-" : "wii-") + String(port) }
  /// "Player 1" / "Wii Remote 1".
  var title: String { PlayerSlot(kind: kind, port: port).title }
  var isBound: Bool { !deviceQualifier.isEmpty }
}

/// Where a game's rumble goes. The raw values are stored under `defaultsKey` and read natively by
/// `Source/Core/InputCommon/ControllerInterface/iOS/Motor.mm`: do not renumber.
enum RumbleDestination: Int, CaseIterable {
  case deviceHaptics = 0
  case controller = 1
  case both = 2

  static let defaultsKey = "rumble_destination"
  static let `default`: RumbleDestination = .controller

  var title: String {
    switch self {
    case .deviceHaptics: return L("Device Haptics")
    case .controller: return L("Controller")
    case .both: return L("Both")
    }
  }

  static func stored(in defaults: UserDefaults = .standard) -> RumbleDestination {
    (defaults.object(forKey: defaultsKey) as? Int).flatMap(RumbleDestination.init(rawValue:)) ?? .default
  }
}

/// Choices the player made that the view model has not written yet (ruling H4). The builder shows
/// them in place of the stored values; the view model commits them after the settle delay.
struct PendingHubChanges: Equatable {
  var devices: [String: PlayerDeviceChoice] = [:]
  var playsAs: [String: PlaysAs] = [:]
  var overlayMode: ControllerManager.OverlayMode?

  var isEmpty: Bool { devices.isEmpty && playsAs.isEmpty && overlayMode == nil }
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
  /// The pad has a gyroscope (`GCController.motion?.hasRotationRate`). Only then does Dolphin's MFi
  /// backend expose its `Gyro …` inputs (MFiController.mm:189-198), so only then can it drive the
  /// Wii pointer. Defaulted so existing memberwise inits compile.
  var hasGyro: Bool = false
  /// The pad has an LED light bar (`GCController.light`).
  var hasLight: Bool = false
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
  var dsuClientEnabled: Bool
  var dsuServerCount: Int
  var pointerMode: PointerMode
  /// The running title has its own pointer mode, so a change lasts for this game only.
  var pointerIsThisGameOnly: Bool
  var backgroundInput: Bool
  var rumbleDestination: RumbleDestination
  var connectTakesPlayer1: Bool
  var touchOverlayProgrammatic: Bool
  /// Device, Plays as and Layout choices waiting out the settle delay; the builder shows them.
  var pending = PendingHubChanges()
  /// The id of a row the view should move focus to once, after its list changed (a Plays as change
  /// that moved a player between Wii and GameCube re-ids the row). One-shot: the next reload drops it.
  var focusRequest: String?

  static func empty(system: ControllerSetupSystem) -> ControllerHubState {
    ControllerHubState(
      system: system, players: [], showAllPorts: false, pads: [], isGameRunning: false,
      overlayVisible: false, overlayMode: .auto, overlayOpacityPercent: 50,
      dsuClientEnabled: false, dsuServerCount: 0,
      pointerMode: .touchFollow, pointerIsThisGameOnly: false, backgroundInput: false,
      rumbleDestination: .default, connectTakesPlayer1: true, touchOverlayProgrammatic: true)
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
  /// Edit Layout…: edits on the game's own canvas while a game runs, else opens the full-screen editor.
  var editLayout: () -> Void
  /// Edit IR Area…: where a touch moves the Wii pointer, edited full screen.
  var editIRArea: () -> Void
  var skinsDestination: () -> AnyView
  /// The pad's qualifier.
  var identifyPad: (String) -> Void
  var dsuDestination: () -> AnyView
  /// Device choice for a row; settles before it is written (ruling H4).
  var setDevice: (PlayerState, PlayerDeviceChoice) -> Void
  /// Plays as choice for a row; settles before it is written.
  var setPlaysAs: (PlayerState, PlaysAs) -> Void
  var setPointerMode: (PointerMode) -> Void
  var setMotionPointer: (PlayerState, Bool) -> Void
  var setBackgroundInput: (Bool) -> Void
  var setRumbleDestination: (RumbleDestination) -> Void
  var setConnectTakesPlayer1: (Bool) -> Void
  var testRumble: () -> Void
  var setTouchOverlayProgrammatic: (Bool) -> Void
  var resetOverlayLayouts: () -> Void
  var lightsDestination: () -> AnyView
}
