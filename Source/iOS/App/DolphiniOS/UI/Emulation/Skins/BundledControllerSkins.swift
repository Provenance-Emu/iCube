// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import CryptoKit
import Foundation

/// Local, free picker availability. Never chooses a skin: older versions persisted "None" as an
/// absent selection key, so absence cannot safely establish a fresh install or consent.
@MainActor
enum BundledControllerSkins {
  static let identifier = "starvingartist.ngc.gcpocket-indigo"
  static let archiveSHA256 = "16a83a56eef89b656b142c2c56144291f11ee13db76624e1709a577c2ee8371d"
  static let seedKey = "bundledControllerSkins.gameCubePocket.v1"

  enum InstallError: Error { case missingArchive, archiveMismatch, unexpectedSkin }

  /// Invoke after the user folder is ready. Marks success once, so deleting the skin is respected.
  /// Existing imports with the same identifier are preserved, as are all controller selections.
  static func installIfNeeded(library: SkinLibrary? = nil, defaults: UserDefaults = .standard,
                              bundle: Bundle = .main) throws {
    guard !defaults.bool(forKey: seedKey) else { return }
    let library = library ?? .shared
    if library.skins.contains(where: { $0.id == identifier }) {
      defaults.set(true, forKey: seedKey)
      return
    }
    guard let archive = bundle.url(forResource: "gamecubepocket", withExtension: "manicskin",
                                   subdirectory: "BundledSkins") else { throw InstallError.missingArchive }
    try install(archive: archive, library: library, defaults: defaults)
  }

  /// Separate archive seam lets tests exercise the shipped bytes through the real importer.
  static func install(archive: URL, library: SkinLibrary, defaults: UserDefaults) throws {
    guard !defaults.bool(forKey: seedKey) else { return }
    if !library.skins.contains(where: { $0.id == identifier }) {
      let data = try Data(contentsOf: archive)
      let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      guard hash == archiveSHA256 else { throw InstallError.archiveMismatch }
      let skin = try library.importSkin(from: archive)
      guard skin.id == identifier, skin.gameType == .gameCube else { throw InstallError.unexpectedSkin }
    }
    defaults.set(true, forKey: seedKey)
  }
}
#endif
