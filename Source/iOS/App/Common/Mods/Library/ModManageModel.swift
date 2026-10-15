// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// State behind "Manage…": the patched copies, saved Riivolution presets and installed Riivolution packs of one
/// game, and what deleting each does. The base game is never offered and never removed.
@MainActor
final class ModManageModel: ObservableObject {
  /// A patched copy or saved preset in the library.
  struct Entry: Identifiable, Equatable {
    let path: String
    let name: String
    let kind: ModdedKind

    var id: String { path }

    init?(entry: some ModdedLibraryEntry, isModded: ModdedLibrary.Classifier = ModdedLibrary.defaultClassifier) {
      guard let info = ModdedLibrary.tileInfo(path: entry.filePath, title: entry.title, isModded: isModded) else { return nil }
      self.init(path: entry.filePath, name: info.displayName, kind: info.kind)
    }

    init(path: String, name: String, kind: ModdedKind) {
      self.path = path
      self.name = name
      self.kind = kind
    }
  }

  let game: RiivolutionLaunchModel.Game
  @Published private(set) var entries: [Entry]
  @Published private(set) var packs: [RiivolutionPack] = []
  @Published private(set) var isLoadingPacks = true
  @Published var failureMessage: String?

  private let sdRoot: URL
  private let loadPacks: RiivolutionLaunchModel.PackLoader
  private let removeFiles: @Sendable ([String]) async -> LocalGameDeleter.Outcome
  private let isModded: ModdedLibrary.Classifier
  private let onChanged: () -> Void

  /// - Parameter onChanged: called after a copy or preset is deleted, so the library can rescan.
  init(
    game: RiivolutionLaunchModel.Game,
    entries: [Entry],
    sdRoot: URL = RiivolutionLocation.installRoot(),
    loadPacks: @escaping RiivolutionLaunchModel.PackLoader = { RiivolutionBridgeAccess.packs(for: $0, in: $1) },
    removeFiles: @escaping @Sendable ([String]) async -> LocalGameDeleter.Outcome = { await LocalGameDeleter.delete(paths: $0) },
    isModded: @escaping ModdedLibrary.Classifier = ModdedLibrary.defaultClassifier,
    onChanged: @escaping () -> Void
  ) {
    self.game = game
    self.entries = entries
    self.sdRoot = sdRoot
    self.loadPacks = loadPacks
    self.removeFiles = removeFiles
    self.isModded = isModded
    self.onChanged = onChanged
  }

  var patchedCopies: [Entry] { entries.filter { $0.kind == .patchedCopy } }
  var presets: [Entry] { entries.filter { $0.kind == .descriptor } }
  var isEmpty: Bool { entries.isEmpty && packs.isEmpty }

  func load() async {
    let game = game
    let sdRoot = sdRoot
    let loadPacks = loadPacks
    packs = await Task.detached(priority: .userInitiated) { loadPacks(game, sdRoot) }.value
    isLoadingPacks = false
  }

  /// Only modded files qualify, and never the game's own file.
  func canDelete(path: String) -> Bool {
    path != game.filePath && isModded(path)
  }

  func delete(_ entry: Entry) async {
    guard canDelete(path: entry.path) else { return }
    let outcome = await removeFiles([entry.path])
    if let failure = outcome.failures.first {
      failureMessage = failure.message
    }
    if outcome.deleted.contains(entry.path) {
      entries.removeAll { $0.path == entry.path }
      onChanged()
    }
  }

  /// Removes the pack's XML, which is what lists it. Files the XML refers to stay: other packs may share them.
  func remove(_ pack: RiivolutionPack) async {
    guard isInsidePackFolder(pack.xmlPath) else { return }
    let outcome = await removeFiles([pack.xmlPath])
    if let failure = outcome.failures.first {
      failureMessage = failure.message
    }
    if outcome.deleted.contains(pack.xmlPath) {
      packs.removeAll { $0.xmlPath == pack.xmlPath }
    }
  }

  private func isInsidePackFolder(_ path: String) -> Bool {
    let folder = sdRoot.appendingPathComponent(RiivolutionLocation.xmlFolderName, isDirectory: true).standardizedFileURL.path + "/"
    return URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(folder)
  }
}
