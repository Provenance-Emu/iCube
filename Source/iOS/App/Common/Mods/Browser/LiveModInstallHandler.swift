// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Hands the browser's two non-trivial kinds to the app: Riivolution packs go to the pack installer,
/// patch files to the disc-patching sheet.
struct LiveModInstallHandler: ModInstallHandling {
  /// Where packs are unpacked: Dolphin's virtual SD card.
  var packRoot: @Sendable () -> URL = { RiivolutionLocation.installRoot() }
  /// Opens the "Apply Patch" sheet.
  var presentPatches: @MainActor @Sendable ([URL], String?) -> Void = { patches, gameID in
    DiscPatchFlow.present(patchURLs: patches, suggestedGameID: gameID)
  }

  func installRiivolutionPack(at root: URL, named name: String) async throws -> String {
    let packRoot = packRoot()
    return try await Task.detached(priority: .userInitiated) {
      try RiivolutionPackInstaller.install(extractedFolder: root, name: name, into: packRoot).message
    }.value
  }

  func presentDiscPatch(_ patches: [URL], suggestedGameID: String?) {
    let presentPatches = presentPatches
    Task { @MainActor in presentPatches(patches, suggestedGameID) }
  }
}
