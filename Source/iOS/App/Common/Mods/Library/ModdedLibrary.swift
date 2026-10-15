// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A library entry as the patch and mod rules see it.
protocol ModdedLibraryEntry {
  var filePath: String { get }
  var gameID: String { get }
  var title: String { get }
}

extension TVGameItem: ModdedLibraryEntry {}

/// How a modded library entry differs from the game it is made from.
enum ModdedKind: Equatable {
  /// A disc patched by the disc-patching flow and saved to the library (`<Software>/Patched/`).
  case patchedCopy
  /// A saved Riivolution selection (`.json`): the base disc plus patches, nothing copied.
  case descriptor
}

/// What a modded tile shows instead of the base game's look-alike title.
struct ModdedTileInfo: Equatable {
  let kind: ModdedKind
  /// The descriptor's own display name, or the name the user gave a patched copy when saving it. A patched
  /// disc's header still carries the base game's title, so the file name is what tells the two apart.
  let displayName: String

  var caption: String {
    switch kind {
    case .patchedCopy: return L("Patched")
    case .descriptor: return L("Mod")
    }
  }

  var systemImage: String {
    switch kind {
    case .patchedCopy: return "bandage"
    case .descriptor: return "puzzlepiece.extension"
    }
  }
}

/// The rules that sort patched copies and mod descriptors from base games: which tiles the grid shows, what a
/// base game's menu lists under "Patches & Mods", and the count its badge shows. Pure, so it can be tested.
enum ModdedLibrary {
  /// Says whether a path is a modded boot target. `ModdedBoot` is the one definition; tests pass their own.
  typealias Classifier = (String) -> Bool

  static let defaultClassifier: Classifier = { ModdedBoot.isModdedPath($0) }

  /// The "Show patched versions as separate library items" setting; on until the user turns it off.
  static func showsPatchedSeparately(defaults: UserDefaults = .standard) -> Bool {
    ConfigInterfaceState.storedShowPatchedSeparately(defaults.object(forKey: ConfigInterfaceDefaultsKey.showPatchedSeparately) as? Bool)
  }

  /// nil for a base game.
  static func tileInfo(path: String, title: String, isModded: Classifier = defaultClassifier) -> ModdedTileInfo? {
    guard isModded(path) else { return nil }
    if ModDescriptorStore.isDescriptor(path: path) {
      return ModdedTileInfo(kind: .descriptor, displayName: title)
    }
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    return ModdedTileInfo(kind: .patchedCopy, displayName: name.isEmpty ? title : name)
  }

  /// The entries the grid lists. With the setting off, patched copies and descriptors are left out; they stay
  /// reachable from their base game's menu.
  static func visible<E: ModdedLibraryEntry>(_ entries: [E], showPatchedSeparately: Bool,
                                             isModded: Classifier = defaultClassifier) -> [E] {
    showPatchedSeparately ? entries : entries.filter { !isModded($0.filePath) }
  }

  /// Every patched copy and descriptor, grouped by the game ID of the game it is made from.
  static func variantsByGameID<E: ModdedLibraryEntry>(in entries: [E], isModded: Classifier = defaultClassifier) -> [String: [E]] {
    var grouped: [String: [E]] = [:]
    for entry in entries where !entry.gameID.isEmpty && isModded(entry.filePath) {
      grouped[entry.gameID, default: []].append(entry)
    }
    return grouped
  }

  /// The library's own copy of a game: the entry with this ID that is not modded.
  static func baseGame<E: ModdedLibraryEntry>(withGameID gameID: String, in entries: [E], isModded: Classifier = defaultClassifier) -> E? {
    entries.first { $0.gameID == gameID && !isModded($0.filePath) }
  }
}
