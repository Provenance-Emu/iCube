// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The installer's view of the game library and the emulator core.
protocol HomebrewLibraryRegistering: Sendable {
  /// True when the emulator can start this file.
  func canBoot(_ program: URL) async -> Bool
  /// The custom title and cover the library holds for this file, if any.
  func metadata(of program: URL) async -> (title: String?, cover: Data?)
  /// Adds the file to the library and sets its title and cover.
  func register(_ program: URL, title: String, cover: Data?) async throws
}

enum HomebrewPaths {
  static let relativeRoot = "Software/" + ZipImportHelper.installedHomebrewFolderName

  /// Where installed homebrew lives: one folder per title, beside `installed.json`.
  static func root() throws -> URL {
    try ContinuityPaths.validatedURL(forRelativePath: relativeRoot)
  }
}

struct LiveHomebrewLibraryRegistrar: HomebrewLibraryRegistering {
  @MainActor
  func canBoot(_ program: URL) async -> Bool {
    DiscImageBridge.gameItem(forPath: program.path) != nil
  }

  /// A `.dol` has no game ID, so the library knows it by a hash of its bytes. An update has new
  /// bytes; the installer reads this before it replaces the file and writes it to the new one.
  @MainActor
  func metadata(of program: URL) async -> (title: String?, cover: Data?) {
    guard let item = DiscImageBridge.gameItem(forPath: program.path),
          let identity = try? await LibraryMetadataService.resolveIdentity(for: item),
          let draft = try? await Task.detached(priority: .utility, operation: {
            try LibraryMetadataService.store().draft(for: identity)
          }).value else { return (nil, nil) }
    let title = draft.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (title?.isEmpty == false ? title : nil, draft.coverData)
  }

  @MainActor
  func register(_ program: URL, title: String, cover: Data?) async throws {
    TVLibraryBridge.updateLibrary(withRemotePaths: [program.path], fetchMetadata: true)
    guard let item = DiscImageBridge.gameItem(forPath: program.path) else { throw HomebrewInstallError.cannotBoot }
    let identity = try await LibraryMetadataService.resolveIdentity(for: item)
    // A cover the store cannot take (not an image, or too big even when shrunk) is dropped; the
    // title still goes in.
    let prepared = cover.flatMap { try? LibraryMetadataService.prepareCover($0) }
    let draft = LibraryMetadataStore.Draft(title: title, coverData: prepared)
    try await Task.detached(priority: .utility) {
      try LibraryMetadataService.store().commit(draft, baseline: LibraryMetadataStore.Draft(), for: identity)
    }.value
    LibraryMetadataService.didChange()
  }
}
