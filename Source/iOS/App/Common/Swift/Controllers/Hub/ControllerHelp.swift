// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

struct ControllerHelpLine: Equatable {
  let id: String
  let action: String
  let how: String
}

/// The hub's Help rows, one per in-game action. Generated from the routing that
/// `installPauseMenuHandlers` documents (the table in `ControllerExtensions.swift`) and
/// `PauseGestureTracker` implements. A route added there needs a line here.
///
/// Hold-to-exit is tvOS only. `EmuEventVC`'s exit timer is `TARGET_OS_TV`, and on iOS the pad
/// route (`PauseGestureTracker.menuButtonChanged`) drops a long hold without exiting.
enum ControllerHelp {
  static func lines(platform: PlatformKind) -> [ControllerHelpLine] {
    var lines = [
      ControllerHelpLine(id: "pause", action: L("Pause"), how: L("View / Share / − button, or Home on Xbox and PlayStation pads")),
      ControllerHelpLine(id: "pause-chord", action: L("Pause on any pad"), how: L("Hold all four shoulder buttons, then press Menu")),
      ControllerHelpLine(id: "fast-forward", action: L("Fast-forward"), how: L("Hold all four shoulder buttons")),
      ControllerHelpLine(id: "start", action: L("Start / +"), how: L("Menu / Options / + button")),
    ]
    if platform == .tvos {
      lines.append(ControllerHelpLine(id: "remote-pause", action: L("Pause with the Siri Remote"), how: L("Press Back / Menu")))
      lines.append(ControllerHelpLine(
        id: "remote-exit", action: L("Exit to Library"),
        how: String(format: L("Hold Back / Menu for %d s"), Int(DOLMenuLongPressDuration))))
    }
    return lines
  }
}
