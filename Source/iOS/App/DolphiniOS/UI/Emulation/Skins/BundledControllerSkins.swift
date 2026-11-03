// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import CryptoKit
import Foundation
import Zip

/// Local, free picker availability. Never chooses a skin: older versions persisted "None" as an
/// absent selection key, so absence cannot safely establish a fresh install or consent.
@MainActor
enum BundledControllerSkins {
  static let identifier = "starvingartist.ngc.gcpocket-indigo"
  nonisolated static let archiveSHA256 = "1da985d4a6f5cefdf94e21aac5a8251ae072c7ada98c44ebf11436d35bd71634"
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

  /// Launch path: hash and unpack the bundled archive off the main actor; publish only the
  /// final import on the main actor. Recheck after suspension to preserve imports and deletion.
  static func installIfNeededInBackground(library: SkinLibrary? = nil, defaults: UserDefaults = .standard,
                                          bundle: Bundle = .main) async throws {
    guard !defaults.bool(forKey: seedKey) else { return }
    let library = library ?? .shared
    if library.skins.contains(where: { $0.id == identifier }) {
      defaults.set(true, forKey: seedKey)
      return
    }
    guard let archive = bundle.url(forResource: "gamecubepocket", withExtension: "manicskin",
                                   subdirectory: "BundledSkins") else { throw InstallError.missingArchive }
    let staging = try await Task.detached(priority: .utility) {
      try unpackVerifiedArchive(archive)
    }.value
    defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent()) }
    guard !defaults.bool(forKey: seedKey) else { return }
    if !library.skins.contains(where: { $0.id == identifier }) {
      let info = try SkinInfo.load(directory: staging)
      guard info.identifier == identifier, info.gameType == .gameCube else { throw InstallError.unexpectedSkin }
      try library.importUnpackedSkin(from: staging)
    }
    defaults.set(true, forKey: seedKey)
  }

  private nonisolated static func unpackVerifiedArchive(_ archive: URL) throws -> URL {
    let data = try Data(contentsOf: archive)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    guard hash == archiveSHA256 else { throw InstallError.archiveMismatch }
    let fm = FileManager.default
    let staging = fm.temporaryDirectory.appendingPathComponent("BundledSkin-\(UUID().uuidString)", isDirectory: true)
    do {
      try fm.createDirectory(at: staging, withIntermediateDirectories: true)
      // Zip requires a .zip extension; keep all writes inside private staging.
      let zipCopy = staging.appendingPathComponent("archive.zip")
      try data.write(to: zipCopy)
      _ = try ZipEntryScanner.scan(fileAt: zipCopy)
      let extracted = staging.appendingPathComponent("skin", isDirectory: true)
      try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
      try Zip.unzipFile(zipCopy, destination: extracted, overwrite: true, password: nil)
      try fm.removeItem(at: zipCopy)
      // The verified bundled archive has its info.json at the root.
      return extracted
    } catch {
      try? fm.removeItem(at: staging)
      throw error
    }
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
