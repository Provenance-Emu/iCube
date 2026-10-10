// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Snapshot of Config for the GameCube screen. Defaults match the old view's `@State` defaults.
struct ConfigGameCubeState: Equatable {
  /// The inverse of skipIPL, whose old `@State` default was false.
  var loadMainMenu = true
  /// English; `sync` derives the real value.
  var language = 0

  /// MAIN_GC_LANGUAGE is a 0-based GameCube index (DiscIO::FromGameCubeLanguage maps N to Language(N+1)),
  /// and the GameCube IPL has no Japanese entry.
  static let languageRange = 0 ... 5

  /// Leading ISO-639 subtag to GameCube index, in index order after English (0).
  private static let languagePrefixes: [(prefix: String, index: Int)] = [("de", 1), ("fr", 2), ("es", 3), ("it", 4), ("nl", 5)]

  /// Maps the preferred language to the nearest GameCube IPL language (English/German/French/Spanish/Italian/Dutch only;
  /// anything else, Japanese included, is English).
  static func gcLanguage(forPreferredLanguage code: String) -> Int {
    let lowered = code.lowercased()
    return languagePrefixes.first { lowered.hasPrefix($0.prefix) }?.index ?? 0
  }

  /// A stored value is trusted but clamped to the valid range (the old 0...6 picker could store 6); never chosen shows the locale's.
  static func displayedLanguage(isSet: Bool, stored: Int, preferredLanguage: String) -> Int {
    guard isSet else { return gcLanguage(forPreferredLanguage: preferredLanguage) }
    return languageRange.contains(stored) ? stored : 0
  }

  /// What to persist on appear: the locale-derived language, once, when the user never chose one. The old view wrote it from every sync.
  static func languageSeed(isSet: Bool, preferredLanguage: String) -> Int? {
    isSet ? nil : gcLanguage(forPreferredLanguage: preferredLanguage)
  }
}

/// One user edit. The host applies it to its snapshot AND to Config; the builder only emits it.
enum ConfigGameCubeChange: Equatable {
  case loadMainMenu(Bool)
  case language(Int)
}
