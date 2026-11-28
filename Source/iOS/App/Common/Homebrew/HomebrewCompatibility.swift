// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What iCube can tell the user about a title before they find out from a blank screen.
///
/// The emulator core has no SD card for a GameCube: not in either memory card slot and not on
/// Serial Port 2. A program that reads files while it runs finds no storage at all, so its
/// level data, its music or the user's ROMs are never loaded, whatever the package holds.
enum HomebrewCompatibility: Equatable {
  /// A tool for a real console's drive, memory cards, network adapter or loader.
  case needsConsole
  /// The installed package holds files the program reads from an SD card.
  case needsPackagedFiles
  /// An emulator or media player: it starts, but has nowhere to load the user's files from.
  case needsSDCard
  /// Dolphin Depot lists Dolphin among the systems the title runs on.
  case listedForDolphin
  /// Nothing known either way.
  case untested

  /// `packagedDataFiles` is the count from `HomebrewPackageLayout.dataFiles`, or nil when the
  /// title is not installed: the catalogue does not say what a package holds.
  static func assess(_ title: HomebrewTitle, packagedDataFiles: Int?) -> HomebrewCompatibility {
    if consoleTools.contains(title.slug) { return .needsConsole }
    if let packagedDataFiles, packagedDataFiles > 0 { return .needsPackagedFiles }
    if title.needsSDCard { return .needsSDCard }
    return title.listedForDolphin ? .listedForDolphin : .untested
  }

  /// The line shown under the buttons, or nil when there is nothing to say.
  var note: String? {
    switch self {
    case .needsConsole:
      return L("This is a tool for a real GameCube and its accessories. It has nothing to work with in iCube and may not start.")
    case .needsPackagedFiles:
      return L("This package keeps its data on an SD card beside the program. iCube does not provide an SD card yet, so it will probably stop at a blank screen.")
    case .needsSDCard:
      return L("This program looks for files on an SD card, which iCube does not provide yet.")
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
