// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// tvOS: "No controller connected" once per boot (design A4, plan call 2). The Siri Remote only
/// navigates menus, so a game started without a gameplay pad cannot be played; the notice says so,
/// with Continue and Controllers. It informs and never gates: Continue plays on.
///
/// Pure: `EmulationScreen` feeds it from its one-second tick.
enum NoControllerNotice {
  /// How long after the game starts running before the check: a pad that connects during the boot
  /// must not trip it.
  static let delay: TimeInterval = 3

  /// Launch arguments of the preview and screenshot harnesses, which never show it.
  static let harnessArguments = ["-ICubePausePreview", "-ICubeLivePerformancePreview", "-ICubePlayControlsPreview", "-SCREENSHOT_MODE"]

  struct Inputs: Equatable {
    /// Seconds since the game was first seen running this boot; nil until then.
    var secondsRunning: TimeInterval?
    var alreadyShown: Bool
    var gameplayPadConnected: Bool
    /// The pause menu, the quick menu or the disconnect banner is up: wait for it to close.
    var anotherOverlayIsUp: Bool
    var isHarnessLaunch: Bool
  }

  static func shouldShow(_ inputs: Inputs) -> Bool {
    guard let secondsRunning = inputs.secondsRunning, secondsRunning >= delay else { return false }
    return !inputs.alreadyShown && !inputs.gameplayPadConnected && !inputs.anotherOverlayIsUp && !inputs.isHarnessLaunch
  }

  /// A gameplay pad among `ControllerStateStore.State.connectedQualifiers` (which already leaves the
  /// Siri Remote out): anything but the app's own `iOS/` devices (the idle touchscreen). A DSU device
  /// counts, as it does for assignment.
  static func hasGameplayPad(connectedQualifiers: [String]) -> Bool {
    connectedQualifiers.contains { !AssignmentEngine.isVirtual($0) }
  }

  /// The panel's rows: Continue (plays on) first, so a stray press does not leave the game, then
  /// Controllers (the hub, as the pause menu's Controllers tile opens it).
  static func model(onContinue: @escaping () -> Void, onControllers: @escaping () -> Void) -> MenuModel {
    MenuModel(sections: [MenuSection(id: "no-controller", items: [
      MenuItem(id: "no-controller-continue", title: L("Continue"), icon: "play.fill", role: .action(onContinue)),
      MenuItem(id: "no-controller-controllers", title: L("Controllers"), icon: "gamecontroller", role: .action(onControllers)),
    ])])
  }

  /// `-SCREENSHOT_MODE 1` reaches UserDefaults; the preview arguments are flags.
  static func isHarnessLaunch(arguments: [String], screenshotMode: Bool) -> Bool {
    screenshotMode || arguments.contains { harnessArguments.contains($0) }
  }
}
