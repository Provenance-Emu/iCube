// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What iCube can tell the user about a title before they find out from a blank screen.
///
/// A program's own files are not the problem: `HomebrewSDCard` hands every title its package
/// folder as an SD card. What is left are the programs that want the user's files, and the
/// tools for hardware an emulator does not have.
enum HomebrewCompatibility: Equatable {
  /// A tool for a real console's drive, memory cards, network adapter or loader.
  case needsConsole
  /// An emulator or media player: it starts, and finds the user's files on its SD card.
  case usesFilesOnSDCard
  /// Dolphin Depot lists Dolphin among the systems the title runs on.
  case listedForDolphin
  /// Nothing known either way.
  case untested

  static func assess(_ title: HomebrewTitle) -> HomebrewCompatibility {
    if consoleTools.contains(title.slug) { return .needsConsole }
    if title.usesFilesOnSDCard { return .usesFilesOnSDCard }
    return title.listedForDolphin ? .listedForDolphin : .untested
  }

  /// The line shown under the buttons for `title`, or nil when there is nothing to say.
  func note(for title: HomebrewTitle) -> String? {
    switch self {
    case .needsConsole:
      return L("This is a tool for a real GameCube and its accessories. It has nothing to work with in iCube and may not start.")
    case .usesFilesOnSDCard:
      return String(format: L("This program loads your files from its SD card. In iCube the card is the title's own folder, Software/Homebrew/%@: put your files there."),
                    title.slug)
    case .listedForDolphin:
      return L("Dolphin Depot lists this title as working in Dolphin.")
    case .untested:
      return nil
    }
  }

  /// Titles that manage hardware an emulator does not have. The catalogue has no field for this
  /// yet, so the list is kept here by slug; a title it misses is only left without a note.
  private static let consoleTools: Set<String> = [
    "blueretro-companion", "cleanrip", "cubiboot-new-ui", "dolphindepot", "ftpii", "gba-link-cable-dumper",
    "gbi", "gchttpserver", "gcmm", "gcmm-exfat", "indigo", "swiss",
  ]
}
