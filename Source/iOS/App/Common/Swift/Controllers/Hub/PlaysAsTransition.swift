// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum PlaysAsStep: Equatable {
  case setExtension(wiimote: Int, value: Int)
  case setSideways(wiimote: Int, enabled: Bool)
  /// Assign `qualifier` to `to` FIRST, then clear `from`, so a refused assignment leaves the
  /// player as they were.
  case moveDevice(qualifier: String, from: PlayerSlot, to: PlayerSlot)
  case clearSlot(PlayerSlot)
}

/// The ordered writes a Plays as change needs. Pure, so the order is tested; the hub view model
/// executes the steps in order.
enum PlaysAsTransition {
  static func plan(from player: PlayerState, to target: PlaysAs) -> [PlaysAsStep] {
    let current = PlaysAs.current(of: player)
    // A stored Nunchuk/Classic + Sideways reads as the extension (`PlaysAs.init`); a Wii target
    // still clears the hidden flag, even when it equals what the player reads as.
    let hasHiddenSideways = player.kind == .wiiRemote && player.isSideways && !current.isSideways
    guard current != target || (hasHiddenSideways && target.kind == .wiiRemote) else { return [] }
    var steps: [PlaysAsStep] = []
    let from = PlayerSlot(kind: player.kind, port: player.port)
    let to = PlayerSlot(kind: target.kind, port: player.port)
    if from.kind != to.kind {
      if player.isBound {
        steps.append(.moveDevice(qualifier: player.deviceQualifier, from: from, to: to))
      } else {
        steps.append(.clearSlot(from))
      }
    }
    if target.kind == .wiiRemote {
      steps.append(.setExtension(wiimote: player.port, value: target.wiiExtension))
      steps.append(.setSideways(wiimote: player.port, enabled: target.isSideways))
    }
    return steps
  }
}
