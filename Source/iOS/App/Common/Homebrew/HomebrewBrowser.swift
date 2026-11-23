// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Switch for the homebrew browser. Every entry point checks it, so a build that cannot ship the
/// browser (an App Store review objection) drops it by flipping this one constant.
enum HomebrewBrowser {
  static let isEnabled = true

  /// Where the catalogue comes from; shown on every screen.
  static let attribution = "Catalogue from Dolphin Depot. iCube does not host or modify these programs."

  /// How many titles each category shows on the first screen.
  static let rootSectionCount = 4
}
