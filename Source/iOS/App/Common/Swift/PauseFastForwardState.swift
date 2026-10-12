// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The pause menu's fast-forward selection. Owned as `@State` by `PauseMenuView` so every press
/// changes something the view observes; a binding getter that re-read UserDefaults left the view
/// (and the tile badge) unchanged after the first press.
struct PauseFastForwardState: Equatable {
  var isEnabled: Bool
  /// The configured speed in percent, 0 = Unlimited. Kept while off so Off → On restores it.
  var percent: Int

  enum Effect: Equatable { case turnOff, setSpeed(Int) }

  var selection: AnyHashable {
    isEnabled ? AnyHashable(percent) : PauseMenuModelBuilder.fastForwardOff
  }

  /// Applies a tile value and says what the bridge must do.
  mutating func select(_ value: AnyHashable) -> Effect {
    if let p = value as? Int, p >= 0 {
      isEnabled = true
      percent = p
      return .setSpeed(p)
    }
    isEnabled = false
    return .turnOff
  }
}
