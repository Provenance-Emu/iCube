// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Combine
import GameController
import SkinKitBezelsUI
import SwiftUI

/// The pause menu's TV switcher as iCube shows it: SkinKit's strip along the bottom of the emulation screen,
/// over the paused game, which stays visible so each TV can be seen on it.
///
/// The pause menu is a full-screen cover, so the strip cannot live inside it: the menu's Bezels item closes the cover
/// (the game stays paused on the screen's own claim) and the screen shows this in its place.
struct GameplayBezelStrip: View {
  let session: GameplayBezelSession
  /// Keep or Cancel: back to the pause menu.
  let onClose: () -> Void
  /// "More…": the full list, in the strip's place.
  let onMore: () -> Void

  @State private var scopeID = UUID()
  @State private var pad = BezelPadInput()

  private static let tick = Timer.publish(every: 1.0 / 60, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      BezelSwitcherHost(session: session,
                        commands: pad.commands.eraseToAnyPublisher(),
                        showsControllerHints: !ControllerManager.shared.controllers.isEmpty,
                        onClose: onClose,
                        onMore: onMore)
    }
    .controllerScope(scopeID)
    .onReceive(Self.tick) { _ in pad.poll(isActive: ControllerFocusCoordinator.isActiveScope(scopeID)) }
  }
}

/// Polls the pads for a bezel view and publishes what they ask for. A reference type held in `@State`: a tick
/// changes it without invalidating the view.
@MainActor
final class BezelPadInput {
  let commands = PassthroughSubject<BezelNavigationCommand, Never>()
  private var nav = BezelStripPadNav()
  /// The first poll only adopts what is held: the press that opened the view is not a command in it.
  private var hasSynced = false

  func poll(isActive: Bool) {
    let inputs: [BezelStripPadNav.Input] = ControllerManager.shared.controllers.compactMap { controller in
      guard let gamepad = controller.extendedGamepad else { return nil }
      return BezelStripPadNav.Input(
        left: gamepad.dpad.left.isPressed, right: gamepad.dpad.right.isPressed, stickX: gamepad.leftThumbstick.xAxis.value,
        a: gamepad.buttonA.isPressed, b: gamepad.buttonB.isPressed, x: gamepad.buttonX.isPressed, y: gamepad.buttonY.isPressed,
        leftShoulder: gamepad.leftShoulder.isPressed, rightShoulder: gamepad.rightShoulder.isPressed)
    }
    guard !inputs.isEmpty else { return }
    let input = BezelStripPadNav.Input.merged(inputs)
    let now = CACurrentMediaTime()
    guard isActive, hasSynced else {
      nav.resync(input, at: now)
      hasSynced = true
      return
    }
    nav.update(input, at: now).forEach(commands.send)
  }
}

/// The full list of TVs, opened from the strip's "More…": the choice for every game, the player's own bezels,
/// import, and The Bezel Project for the running game's system.
struct GameplayBezelLibrarySheet: View {
  let game: ExternalDisplayGameContext?
  let onDone: () -> Void

  @BezelSetting(\.chosenBezel) private var chosenBezel

  var body: some View {
    NavigationStack {
      TVBezelPickerView(
        selection: Binding(get: { chosenBezel }, set: { chosenBezel = $0 ?? ExternalDisplayBezelRules.automaticBezelID }),
        offersSystemAutomatic: true,
        game: game)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) { Button(L("Done"), action: onDone) }
        }
    }
  }
}
#endif
