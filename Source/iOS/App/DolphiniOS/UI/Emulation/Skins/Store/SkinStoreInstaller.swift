// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// Where one catalog entry is in the download → install pipeline.
enum SkinStoreInstallState: Sendable, Equatable {
  case idle
  /// `progress` is 0...1; it stays 0 when the server sends no length.
  case downloading(progress: Double)
  case installing
  case installed
  case failed(message: String)

  var isBusy: Bool {
    switch self {
    case .downloading, .installing: return true
    case .idle, .installed, .failed: return false
    }
  }
}

/// Downloads and installs skins from the store, publishing per-entry state for SwiftUI.
///
/// Per entry: download to `<tmp>/SkinStore-<uuid>/<entry id>.<ext>` → `SkinLibrary.importSkin`
/// (as-is, or rewritten to GameCube for the N64 shelf) → record the catalog id. The library already
/// vets the archive, unzips, validates `info.json` and announces the change, so an unreadable skin
/// fails here with the library's own message. Files are always fetched from the entry's
/// `downloadURL`; iCube never re-hosts them.
@MainActor
final class SkinStoreInstaller: ObservableObject {
  static let shared = SkinStoreInstaller()

  /// Turns a downloaded file into an installed skin. Injected for tests.
  typealias InstallStep = @MainActor (_ file: URL, _ section: SkinStoreSection) throws -> InstalledSkin

  enum InstallError: LocalizedError {
    /// The entry is one the policy hides (a `.zip`, an extensionless link).
    case notInstallable(String)

    var errorDescription: String? {
      switch self {
      case .notInstallable(let name): return String(format: L("%@ isn't a skin iCube can install."), name)
      }
    }
  }

  private static let temporaryFolderPrefix = "SkinStore-"

  /// Transient state for entries touched this session. Read through `state(for:)`, which folds in `installedIds`.
  @Published private(set) var states: [String: SkinStoreInstallState] = [:]
  /// Catalog ids installed from the store (persisted).
  @Published private(set) var installedIds: Set<String>

  private let downloader: any SkinStoreDownloading
  private let record: SkinStoreInstalledRecord
  private let installStep: InstallStep
  private var tasks: [String: Task<Void, Never>] = [:]

  init(downloader: any SkinStoreDownloading = URLSessionSkinStoreDownloader(),
       record: SkinStoreInstalledRecord = SkinStoreInstalledRecord(),
       installStep: InstallStep? = nil) {
    self.downloader = downloader
    self.record = record
    // Resolved here, not as a default argument: that expression runs outside the main actor.
    self.installStep = installStep ?? Self.libraryInstallStep(.shared)
    installedIds = Set(record.load().keys)
  }

  /// The default install step: the library's import, rewritten to the shelf's target when it has one.
  static func libraryInstallStep(_ library: SkinLibrary) -> InstallStep {
    { file, section in try library.importSkin(from: file, retargetingTo: section.retarget) }
  }

  // MARK: - State

  func state(for entry: SkinCatalogEntry) -> SkinStoreInstallState {
    if let state = states[entry.id], state != .idle { return state }
    return installedIds.contains(entry.id) ? .installed : .idle
  }

  /// Forgets store installs whose skin is no longer in the library (the player deleted it), so the
  /// store offers it again. Pass every installed skin identifier.
  func reconcileInstalled(with installedSkinIds: Set<String>) {
    let gone = Set(record.load().filter { !installedSkinIds.contains($0.value) }.keys)
    guard !gone.isEmpty else { return }
    record.remove(catalogIds: gone)
    installedIds.subtract(gone)
    for id in gone where states[id] == .installed { states[id] = nil }
    NSLog("[SKINSTORE] %d installed skin(s) no longer present", gone.count)
  }

  // MARK: - Install

  /// Starts installing `entry` in the background. A second call while one is running is ignored.
  func startInstall(_ entry: SkinCatalogEntry) {
    guard tasks[entry.id] == nil else { return }
    tasks[entry.id] = Task { [weak self] in
      await self?.install(entry)
      self?.tasks[entry.id] = nil
    }
  }

  /// Cancels a running install; the entry returns to idle.
  func cancelInstall(_ entry: SkinCatalogEntry) {
    tasks[entry.id]?.cancel()
  }

  /// Downloads and installs `entry`, updating `states` along the way.
  func install(_ entry: SkinCatalogEntry) async {
    if states[entry.id]?.isBusy == true { return }
    guard let section = SkinStorePolicy.section(for: entry), let fileName = SkinStorePolicy.downloadFileName(for: entry) else {
      states[entry.id] = .failed(message: InstallError.notInstallable(entry.name).localizedDescription)
      return
    }

    states[entry.id] = .downloading(progress: 0)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Self.temporaryFolderPrefix + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent(fileName)

    do {
      let id = entry.id
      try await downloader.download(from: entry.downloadURL, to: file) { [weak self] fraction in
        Task { @MainActor in self?.applyProgress(fraction, for: id) }
      }
      try Task.checkCancellation()

      states[entry.id] = .installing
      let skin = try installStep(file, section)
      record.markInstalled(catalogId: entry.id, skinIdentifier: skin.id)
      installedIds.insert(entry.id)
      states[entry.id] = .installed
      NSLog("[SKINSTORE] Installed '%@' [%@] as %@", entry.name, section.rawValue, skin.id)
    } catch {
      if Self.isCancellation(error) || Task.isCancelled {
        states[entry.id] = .idle
        return
      }
      let message = (error as? SkinImportError).map(SkinImportError.describe) ?? error.localizedDescription
      states[entry.id] = .failed(message: message)
      NSLog("[SKINSTORE] Install of '%@' failed: %@", entry.name, message)
    }
  }

  // MARK: - Private

  /// Progress hops arrive asynchronously and can land after the state moved on; only a still-downloading entry takes them.
  private func applyProgress(_ fraction: Double, for id: String) {
    guard case .downloading = states[id] else { return }
    states[id] = .downloading(progress: fraction)
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    return (error as? URLError)?.code == .cancelled
  }
}
#endif
