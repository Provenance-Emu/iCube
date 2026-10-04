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

/// The player screen's help: one line per Buttons category, shown at the top of its section, and a
/// caption for each row whose subtitle would otherwise be empty. A row that shows a value (Device,
/// Load Profile…) shows it as its badge and this caption as its subtitle.
enum PlayerScreenHelp {
  /// What the category's rows do. Motion names its four groups; on the Touchscreen it says that the
  /// app drives the pointer, which is set under Pointer & Motion rather than bound.
  static func category(_ category: ControlCategory, onTouchscreen: Bool) -> String {
    switch category {
    case .face:
      return L("The main buttons. Select a row, then press the button that should do it.")
    case .dPad:
      return L("The four D-Pad directions.")
    case .sticks:
      return L("One row per stick direction. A stick direction moves the stick partway; a button pushes it all the way.")
    case .triggers:
      return L("Shoulder buttons and triggers. An analog row follows how far an analog trigger is pressed.")
    case .system:
      return L("Start, +, − and Home: the buttons games use for menus.")
    case .motion:
      return onTouchscreen
        ? L("Shake, Pointer, Tilt and Swing move the Wii Remote through the air. On the Touchscreen the app drives the pointer: set it under Pointer & Motion.")
        : L("Shake, Pointer, Tilt and Swing move the Wii Remote through the air. Bind each direction to a stick or a button to act it out.")
    }
  }

  static var device: String { L("The controller that plays as this player.") }
  static var devicePinned: String {
    L("Pinned: you chose this device, so controllers that connect leave this player alone. Choose Auto to undo.")
  }
  static var loadProfile: String { L("Replaces this player's buttons with a saved profile.") }
  static var saveProfile: String { L("Keeps this player's buttons as a profile to load later, on any port.") }
  static var resetProfile: String { L("Loads the built-in profile for the bound controller.") }
  static var clearAll: String { L("Unbinds every control, to capture each one from scratch.") }
  static var extensionCaption: String { L("What is plugged into the Wii Remote: the Nunchuk adds a stick, C and Z.") }
  static var sideways: String { L("For games played with the Wii Remote held sideways. The D-Pad and motion turn with it.") }
  static var rawBindings: String {
    L("Each control's Dolphin expression. Select one to edit it, combine inputs, or bind an output such as Rumble.")
  }
}
