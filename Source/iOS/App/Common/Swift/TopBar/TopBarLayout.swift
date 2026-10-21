// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Where a bar button sends the user. `EmulationScreen` owns the sheets and overlays these open.
enum TopBarDestination: Equatable {
  case exitConfirm, perfOverlay, audioEffects, shaders, shaderParameters
  case controllerSettings, pauseMenu, skylanderImport, skylanderClear
  /// The on-screen controls' layout editor, over the game.
  case editLayout, saveStates
}


/// The visible action order is shared by the toolbar and its layout regressions.
enum TopBarControl: String, CaseIterable {
  case pause, save, load, saves, fastForward, audio, controller, display, shaders, options, hide

  var directDestination: TopBarDestination? {
    switch self {
    case .pause: return .pauseMenu
    case .saves: return .saveStates
    case .shaders: return .shaders
    default: return nil
    }
  }
}

enum TopBarLayout {
  static let minimumTarget: CGFloat = 44
  static let controlHeight: CGFloat = 56
  static let verticalPadding: CGFloat = 8
  static let horizontalPadding: CGFloat = 8
  static let wideMinimumWidth: CGFloat = 1000
  static let compactControls: [TopBarControl] = [.pause, .save, .load, .saves, .options, .hide]
  static let wideControls: [TopBarControl] = [.pause, .save, .load, .saves, .fastForward, .audio, .controller, .display, .shaders, .hide]

  /// Portrait, split-width windows and accessibility type always use the concise action set.
  static func usesWideRow(width: CGFloat, height: CGFloat, accessibilityType: Bool) -> Bool {
    !accessibilityType && width > height && width >= wideMinimumWidth
  }

  static var standardHeight: CGFloat { controlHeight + 2 * verticalPadding }
}
