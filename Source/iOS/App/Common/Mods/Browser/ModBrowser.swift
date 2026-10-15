// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Switch for the online mod browser. Every entry point checks it, so a build that cannot ship
/// the browser (an App Store review objection) drops it by flipping this one constant.
enum ModBrowser {
  static let isEnabled = true

  /// Where the browser's catalogue comes from; shown on every screen.
  static let attribution = "Mods are provided by GameBanana. iCube does not host or modify them."

  /// A download above this size asks the user to confirm first.
  static let largeDownloadBytes: Int64 = 500 * 1024 * 1024

  /// Whether the bundled catalogue has mods for this game. Entry points show "Find Mods Online" only
  /// then, so they never open a browser with nothing in it.
  static func offersMods(forGameID gameID: String) -> Bool {
    isEnabled && ModGameTable.bundled.entry(forGameID: gameID) != nil
  }
}
