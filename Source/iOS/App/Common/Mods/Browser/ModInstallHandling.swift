// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What the mod browser hands off to other parts of the app. Texture packs and Gecko codes are
/// installed by the browser itself; the two kinds below belong to the Riivolution and disc-patch
/// flows.
protocol ModInstallHandling {
  /// Installs the Riivolution pack whose `riivolution/` folder lives in `root`, and returns a
  /// line for the user ("Installed Riivolution pack X (3 options)").
  func installRiivolutionPack(at root: URL) async throws -> String

  /// Offers the extracted patch files to the disc-patching flow. Fire and forget: the flow reads
  /// the files after this returns, so the caller must not delete them.
  func presentDiscPatch(_ patches: [URL], suggestedGameID: String?)
}
