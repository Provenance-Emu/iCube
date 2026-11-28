// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Where a bar button sends the user. `EmulationScreen` owns the sheets and overlays these open.
enum TopBarDestination: Equatable {
  case exitConfirm, perfOverlay, audioEffects, shaders, shaderParameters
  /// The shader settings sheet: the enable switch and the compatibility options.
  case shaderOptions
  case controllerSettings, pauseMenu, skylanderImport, skylanderClear
  /// The on-screen controls' layout editor, over the game.
  case editLayout, saveStates
  /// The TV list: which TV is drawn around the picture.
  case bezels
}

/// The popovers the bar can show. Only one is up at a time.
enum TopBarPopover: String {
  case audio, controller, display, options, speed
}

/// What holding a bar button does: a second, deeper action beside the tap.
enum TopBarLongPress: Equatable {
  case popover(TopBarPopover)
  case destination(TopBarDestination)
  case toggleMute
}

/// The visible action order is shared by the toolbar and its layout regressions.
enum TopBarControl: String, CaseIterable {
  case menu, save, load, saves, fastForward, audio, controller, display, shaders, options, exit

  var directDestination: TopBarDestination? {
    switch self {
    case .menu: return .pauseMenu
    case .saves: return .saveStates
    case .shaders: return .shaders
    case .exit: return .exitConfirm
    default: return nil
    }
  }

  /// Holding the button. Every one opens something the tap does not, so nothing is reachable only by a hold.
  var longPress: TopBarLongPress? {
    switch self {
    case .menu: return .popover(.options)
    case .save, .load: return .destination(.saveStates)
    case .fastForward: return .popover(.speed)
    case .audio: return .toggleMute
    case .controller: return .destination(.controllerSettings)
    case .display: return .destination(.perfOverlay)
    case .shaders: return .destination(.shaderParameters)
    case .saves, .options, .exit: return nil
    }
  }

  /// VoiceOver's name for the hold (a custom action), and the hint under the popover rows that mention it.
  var longPressTitle: String? {
    switch self {
    case .menu: return L("All Options")
    case .save, .load: return L("Choose a Save State")
    case .fastForward: return L("Choose Speed")
    case .audio: return L("Mute")
    case .controller: return L("Controller Settings")
    case .display: return L("Performance")
    case .shaders: return L("Shader Parameters")
    case .saves, .options, .exit: return nil
    }
  }
}

enum TopBarLayout {
  static let minimumTarget: CGFloat = 44
  static let controlHeight: CGFloat = 60
  static let verticalPadding: CGFloat = 6
  static let horizontalPadding: CGFloat = 8
  static let wideMinimumWidth: CGFloat = 1000
  /// How long a button is held before its second action runs.
  static let longPressDuration: TimeInterval = 0.45
  /// Menu and Exit bracket the row: the two ways out sit at its ends, where a thumb finds them.
  static let compactControls: [TopBarControl] = [.menu, .save, .load, .saves, .display, .options, .exit]
  static let wideControls: [TopBarControl] = [.menu, .save, .load, .saves, .fastForward, .audio, .controller, .display, .shaders, .exit]

  /// Portrait, split-width windows and accessibility type always use the concise action set.
  static func usesWideRow(width: CGFloat, height: CGFloat, accessibilityType: Bool) -> Bool {
    !accessibilityType && width > height && width >= wideMinimumWidth
  }

  static var standardHeight: CGFloat { controlHeight + 2 * verticalPadding }
}

/// What the bar's buttons say under their titles, and what the Display popover's rows show. A plain
/// snapshot read when the bar appears and whenever something it opened closes.
struct TopBarValues: Equatable {
  /// The classic quick slot; nil while quick saves go to the history.
  var quickSlot: Int?
  /// Fast-forward speed in percent while it is on (0 = unlimited); nil when off.
  var fastForwardPercent: Int?
  var volume = 100
  var isMuted = false
  /// What Player 1 plays on, short enough for the bar ("Touch", a pad's name).
  var controllerName: String?
  /// Dolphin's aspect setting (`AspectRatio.aspectRaw`).
  var aspectRaw = 0
  /// The selected preset's name; nil when no shader is selected or shaders are off.
  var shaderName: String?
  /// The TV around the picture; nil for none.
  var bezelName: String?

  static let aspectOptions: [(title: String, raw: Int)] = [(L("Auto"), 0), ("16:9", 1), ("4:3", 2), (L("Stretch"), 3)]
  /// Off, then the pause menu's speeds: one list, so the bar and the menu cannot drift.
  static let speedOptions: [(title: String, percent: Int?)] = [
    (L("Off"), nil), ("2x", 200), ("3x", 300), ("4x", 400), ("8x", 800), (L("Max"), 0),
  ]

  static func aspectTitle(raw: Int) -> String {
    aspectOptions.first { $0.raw == raw }?.title ?? L("Auto")
  }

  static func speedTitle(percent: Int?) -> String {
    guard let percent else { return L("Off") }
    if percent == 0 { return L("Max") }
    return percent % 100 == 0 ? "\(percent / 100)x" : String(format: "%.1fx", Double(percent) / 100)
  }

  var audioTitle: String { isMuted || volume <= 0 ? L("Muted") : "\(volume) %" }

  /// The caption under a bar button; nil for a button that has no state of its own.
  func caption(for control: TopBarControl) -> String? {
    switch control {
    case .save, .load: return quickSlot.map { String(format: L("Slot %d"), $0) }
    case .fastForward: return Self.speedTitle(percent: fastForwardPercent)
    case .audio: return audioTitle
    case .controller: return controllerName
    case .display: return Self.aspectTitle(raw: aspectRaw)
    case .shaders: return shaderName ?? L("Off")
    case .menu, .saves, .options, .exit: return nil
    }
  }
}
