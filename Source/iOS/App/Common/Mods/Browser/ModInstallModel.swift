// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Drives one mod file from "Download" to installed: fetch, verify, unpack, classify, then run
/// whichever installs the user picks.
@MainActor
final class ModInstallModel: ObservableObject {
  enum Phase: Equatable {
    case idle
    case downloading(Double)
    case verifying
    case extracting
    case ready(ModPackageClassification)
    case failed(String)
  }

  let file: GameBananaFile
  /// The library game the user came from or owns, if any.
  let ownedGame: ModLibraryGame?

  @Published private(set) var phase: Phase = .idle
  /// What has been installed so far, one line each.
  @Published private(set) var log: [String] = []
  @Published private(set) var isInstalling = false
  /// Set when a download needs the user's go-ahead because of its size.
  @Published var largeDownloadBytes: Int64?
  /// Set after a texture pack went in while custom textures are off.
  @Published var offerCustomTextures = false

  private let handler: any ModInstallHandling
  private let downloader: ModDownloadManager
  private var downloadTask: Task<Void, Never>?
  private var keepsExtractedFiles = false

  init(file: GameBananaFile, ownedGame: ModLibraryGame?, handler: any ModInstallHandling,
       downloader: ModDownloadManager = .shared) {
    self.file = file
    self.ownedGame = ownedGame
    self.handler = handler
    self.downloader = downloader
  }

  /// Why this file cannot be installed here, or nil when it can.
  nonisolated static func blockedReason(for file: GameBananaFile) -> String? {
    let ext = (file.fileName as NSString).pathExtension.lowercased()
    if ext == "rar" { return L("This is a RAR archive, which iCube cannot open.") }
    if file.downloadURL == nil { return L("GameBanana lists no download link for this file.") }
    return nil
  }

  var isBusy: Bool {
    switch phase {
    case .downloading, .verifying, .extracting: return true
    case .idle, .ready, .failed: return false
    }
  }

  // MARK: - Download

  func requestStart() {
    let available = ModDownloadPolicy.availableBytes(at: URL(fileURLWithPath: UserFolderUtil.getUserFolder()))
    switch ModDownloadPolicy.verdict(fileSize: file.size, availableBytes: available) {
    case .allowed:
      start()
    case .confirmLargeDownload(let bytes):
      largeDownloadBytes = bytes
    case .insufficientSpace(let needed, let available):
      phase = .failed(String(format: L("Not enough free space: this needs about %@ and %@ is available."),
                             Self.formatted(needed), Self.formatted(available)))
    }
  }

  func start() {
    guard !isBusy else { return }
    phase = .downloading(0)
    log = []
    downloadTask = Task { [weak self] in await self?.run() }
  }

  func cancel() {
    downloadTask?.cancel()
  }

  private func run() async {
    do {
      let archive = try await downloader.download(file) { [weak self] fraction in
        Task { @MainActor in
          guard let self, case .downloading = self.phase else { return }
          self.phase = .downloading(fraction)
        }
      }
      phase = .verifying
      let expected = file.md5
      try await Task.detached(priority: .userInitiated) {
        try ModDownloadPolicy.verifyChecksum(of: archive, expected: expected)
      }.value
      phase = .extracting
      let gameID = ownedGame?.gameID
      let classification = try await Task.detached(priority: .userInitiated) {
        let root = try Self.unpack(archive, in: archive.deletingLastPathComponent())
        return ModPackageClassifier.classify(extractedRoot: root, gameID: gameID)
      }.value
      phase = .ready(classification)
    } catch is CancellationError {
      phase = .idle
    } catch {
      removeWorkFolder()
      phase = .failed(error.localizedDescription)
    }
  }

  /// Extracts an archive next to itself (or files a bare download under the same folder) and deletes the archive.
  nonisolated private static func unpack(_ archive: URL, in directory: URL) throws -> URL {
    let fm = FileManager.default
    let extracted = directory.appendingPathComponent("extracted", isDirectory: true)
    try? fm.removeItem(at: extracted)
    if ImportableFileTypes.archiveKind(for: archive) != nil {
      try ZipImportHelper.extractArchive(at: archive, to: extracted)
    } else {
      try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
      try fm.moveItem(at: archive, to: extracted.appendingPathComponent(archive.lastPathComponent))
    }
    try? fm.removeItem(at: archive)
    return extracted
  }

  // MARK: - Installing

  func installTextures(gameID: String, root: URL) {
    perform {
      guard let texturesRoot = ModContentInstaller.bridgedTexturesRoot() else { throw ModContentInstaller.InstallError.emptyTexturePack }
      let result = try await Task.detached(priority: .userInitiated) {
        try ModContentInstaller.installTextures(from: root, gameID: gameID, texturesRoot: texturesRoot)
      }.value
      var line = String(format: L("Installed %d textures for %@."), result.filesCopied, gameID)
      if let mismatch = Self.regionWarning(packID: gameID, ownedID: self.ownedGame?.gameID) { line += " " + mismatch }
      self.log.append(line)
      if !DOLConfigBridge.gfxHiresTextures() { self.offerCustomTextures = true }
    }
  }

  func enableCustomTextures() {
    DOLConfigBridge.setGfxHiresTextures(true)
    log.append(L("Custom textures are on."))
  }

  func installGecko(file codesFile: URL) {
    perform {
      guard let game = self.ownedGame else { throw ModContentInstaller.InstallError.geckoNeedsLibraryGame }
      let text = try ModContentInstaller.geckoText(of: codesFile)
      let result = try ModContentInstaller.installGecko(text: text, gameID: game.gameID, revision: game.revision,
                                                        store: CoreGeckoStore())
      var parts = [String(format: L("Added %d Gecko codes to %@ and turned them on."), result.added.count, game.title)]
      if !result.alreadyPresent.isEmpty {
        parts.append(String(format: L("%d were already there."), result.alreadyPresent.count))
      }
      if !result.rejected.isEmpty {
        parts.append(String(format: L("%d could not be read."), result.rejected.count))
      }
      let stem = (codesFile.lastPathComponent as NSString).deletingPathExtension
      if let mismatch = Self.regionWarning(packID: stem, ownedID: game.gameID) { parts.append(mismatch) }
      self.log.append(parts.joined(separator: " "))
    }
  }

  func installRiivolutionPack(root: URL) {
    perform {
      self.log.append(try await self.handler.installRiivolutionPack(at: root))
    }
  }

  func presentDiscPatch(_ patches: [URL], suggestedGameID: String?) {
    keepsExtractedFiles = true
    handler.presentDiscPatch(patches, suggestedGameID: suggestedGameID)
  }

  private func perform(_ work: @escaping @MainActor () async throws -> Void) {
    guard !isInstalling else { return }
    isInstalling = true
    Task {
      do {
        try await work()
      } catch {
        ModBrowserPresenter.shared.notice = error.localizedDescription
      }
      isInstalling = false
    }
  }

  /// Warns when a pack made for one region is installed for another. Not blocking: many packs
  /// are region-free in practice and revisions share most files.
  nonisolated static func regionWarning(packID: String, ownedID: String?) -> String? {
    guard packID.count == 6, let ownedID, ownedID.count == 6, packID.uppercased() != ownedID.uppercased(),
          packID.prefix(3) == ownedID.prefix(3) else { return nil }
    return String(format: L("This is for %@ and your game is %@, so it may not apply."), packID, ownedID)
  }

  // MARK: - Cleanup

  /// Deletes the download and its unpacked files, unless another flow is still reading them.
  func cleanUp() {
    downloadTask?.cancel()
    if !keepsExtractedFiles && !isInstalling { removeWorkFolder() }
  }

  private func removeWorkFolder() {
    try? FileManager.default.removeItem(at: ModDownloadManager.workDirectory(forFileID: file.id))
  }

  nonisolated static func formatted(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}
