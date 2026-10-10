// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What a player plays as (unified menu UX spec §7.1): the Wii slot kind, the extension and the
/// sideways flag as one choice. Pure; the bridge writes happen in `PlaysAsTransition`'s steps.
enum PlaysAs: Int, CaseIterable, Hashable {
  case gameCube
  case wiiRemote
  case wiiNunchuk
  case wiiClassic
  case wiiSideways

  var title: String {
    switch self {
    case .gameCube: return L("GameCube Controller")
    case .wiiRemote: return L("Wii Remote")
    case .wiiNunchuk: return L("Wii Remote + Nunchuk")
    case .wiiClassic: return L("Wii Remote + Classic Controller")
    case .wiiSideways: return L("Sideways Wii Remote")
    }
  }

  var kind: PlayerState.Kind { self == .gameCube ? .gameCube : .wiiRemote }

  /// `WiimoteSlotOptions` numbering: 0 None, 1 Nunchuk, 2 Classic.
  var wiiExtension: Int {
    switch self {
    case .wiiNunchuk: return 1
    case .wiiClassic: return 2
    default: return 0
    }
  }

  var isSideways: Bool { self == .wiiSideways }

  /// The extension wins over sideways: a sideways remote with a Nunchuk is not a thing the UI offers,
  /// so a stored Nunchuk + Sideways reads as Nunchuk (`PlaysAsTransition` clears the hidden flag).
  init(kind: PlayerState.Kind, wiiExtension: Int, isSideways: Bool) {
    switch (kind, wiiExtension, isSideways) {
    case (.gameCube, _, _): self = .gameCube
    case (.wiiRemote, 1, _): self = .wiiNunchuk
    case (.wiiRemote, 2, _): self = .wiiClassic
    case (.wiiRemote, _, true): self = .wiiSideways
    default: self = .wiiRemote
    }
  }

  /// A Wii-only list has no GameCube ports, so no GameCube Controller; a GameCube title has only
  /// GameCube ports; a Wii title that also takes GameCube ports (or Settings with every port)
  /// offers everything, Wii first.
  static func options(for system: ControllerSetupSystem) -> [PlaysAs] {
    switch system {
    case .gamecube: return [.gameCube]
    case .wii: return [.wiiRemote, .wiiNunchuk, .wiiClassic, .wiiSideways]
    case .both, .wiiAndGameCube: return [.wiiRemote, .wiiNunchuk, .wiiClassic, .wiiSideways, .gameCube]
    }
  }

  static func current(of player: PlayerState) -> PlaysAs {
    PlaysAs(kind: player.kind, wiiExtension: player.wiiExtension, isSideways: player.isSideways)
  }
}
