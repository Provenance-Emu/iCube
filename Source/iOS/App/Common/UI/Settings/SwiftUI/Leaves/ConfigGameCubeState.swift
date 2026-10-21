// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Snapshot of Config for the GameCube screen. Defaults match the old view's `@State` defaults.
struct ConfigGameCubeState: Equatable {
  /// The inverse of skipIPL, whose old `@State` default was false.
  var loadMainMenu = true
  /// English; `sync` derives the real value.
  var language = 0
  /// MAIN_SLOT_B holds the Microphone (true) or nothing (false).
  var slotBMicrophone = false

  /// MAIN_GC_LANGUAGE is a 0-based GameCube index (DiscIO::FromGameCubeLanguage maps N to Language(N+1)),
  /// and the GameCube IPL has no Japanese entry.
  static let languageRange = 0 ... 5

  /// Config already resolves an unset key to the core's locale-derived default.
  /// Clamp values written by the old 0...6 picker to the six valid IPL entries.
  static func displayedLanguage(stored: Int) -> Int {
    languageRange.contains(stored) ? stored : 0
  }
}

/// One user edit. The host applies it to its snapshot AND to Config; the builder only emits it.
enum ConfigGameCubeChange: Equatable {
  case loadMainMenu(Bool)
  case language(Int)
  case slotBMicrophone(Bool)
}
