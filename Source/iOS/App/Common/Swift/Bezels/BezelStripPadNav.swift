// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation
import SkinKitBezelsUI

/// A controller's buttons as the TV switcher strip reads them: left and right step (a hold repeats), the
/// shoulders jump between groups of TVs, A keeps, B cancels, X toggles room light and Y "this game only".
///
/// Pure, like `MenuControllerNav`, which it wraps for the timing every other iCube menu uses. The strip is one
/// row, so up and down are never passed on.
struct BezelStripPadNav: Equatable {
  struct Input: Equatable {
    var left = false
    var right = false
    /// Left stick X, +1 is right.
    var stickX: Float = 0
    var a = false
    var b = false
    var x = false
    var y = false
    var leftShoulder = false
    var rightShoulder = false

    /// Every pad's input as one: any pad may drive the strip.
    static func merged(_ inputs: [Input]) -> Input {
      inputs.reduce(into: Input()) { merged, input in
        merged.left = merged.left || input.left
        merged.right = merged.right || input.right
        if abs(input.stickX) > abs(merged.stickX) { merged.stickX = input.stickX }
        merged.a = merged.a || input.a
        merged.b = merged.b || input.b
        merged.x = merged.x || input.x
        merged.y = merged.y || input.y
        merged.leftShoulder = merged.leftShoulder || input.leftShoulder
        merged.rightShoulder = merged.rightShoulder || input.rightShoulder
      }
    }
  }

  private var nav = MenuControllerNav()
  private var stickDirection = 0
  private var xLatched = false
  private var yLatched = false

  init() {}

  /// The commands this tick's input makes, in order.
  mutating func update(_ input: Input, at time: TimeInterval) -> [BezelNavigationCommand] {
    var commands: [BezelNavigationCommand] = []
    for event in nav.update(navInput(input), at: time) {
      switch event {
      case .adjust(let step), .adjustRepeat(let step): commands.append(step < 0 ? .left : .right)
      case .jumpSection(let step): commands.append(step < 0 ? .previousGroup : .nextGroup)
      case .activate: commands.append(.activate)
      case .back: commands.append(.back)
      case .move, .switchTab, .longActivate: break
      }
    }
    if input.x != xLatched {
      xLatched = input.x
      if input.x { commands.append(.toggleRoomLight) }
    }
    if input.y != yLatched {
      yLatched = input.y
      if input.y { commands.append(.toggleThisGameOnly) }
    }
    return commands
  }

  /// Adopts what is held without a command. The strip opens while the A that chose "Bezels" may still be down,
  /// and that press must not keep the first TV; the same holds whenever another surface owns the controller.
  mutating func resync(_ input: Input, at time: TimeInterval) {
    nav.resync(navInput(input), at: time)
    xLatched = input.x
    yLatched = input.y
  }

  /// The stick counts as the d-pad once pushed past the engage threshold, until it falls back inside release.
  private mutating func navInput(_ input: Input) -> MenuControllerNav.Input {
    let magnitude = abs(input.stickX)
    if stickDirection != 0 {
      if magnitude < nav.config.stickRelease { stickDirection = 0 }
    } else if magnitude > nav.config.stickEngage {
      stickDirection = input.stickX < 0 ? -1 : 1
    }
    return MenuControllerNav.Input(
      a: input.a, b: input.b, leftShoulder: input.leftShoulder, rightShoulder: input.rightShoulder,
      left: input.left || stickDirection < 0, right: input.right || stickDirection > 0)
  }
}
#endif
