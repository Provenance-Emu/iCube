// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Drives one mod file from "Download" to installed: fetch, verify, unpack, classify, then run
/// whichever installs the user picks.
///
/// A model outlives the screen that shows it: `ModInstallCenter` keeps it while it has work or a
/// download worth keeping, and `ModInstallLedger` remembers the rest across launches.
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

  /// Where a file sits in the browser's lists.
  enum Status: Equatable {
    case none
    case downloading(Double)
    case preparing
    case downloaded
    case installed
  }

  let file: GameBananaFile
  let modName: String
  /// The catalogue game the file was found under.
  let bananaGameID: Int?
  /// The library game the user came from or owns, if any.
  let ownedGame: ModLibraryGame?

  @Published private(set) var phase: Phase = .idle
  /// What has been installed so far, one line each. Survives a relaunch.
  @Published private(set) var log: [String] = []
  @Published private(set) var isInstalling = false
  /// Indices into the classification's kinds that were installed since the download was unpacked.
  @Published private(set) var installedKinds: Set<Int> = []
  /// The names of the codes in each Gecko file of the download.
  @Published private(set) var geckoCodeNames: [URL: [String]] = [:]
  /// Set when a download needs the user's go-ahead because of its size.
  @Published var largeDownloadBytes: Int64?
  /// Set after a texture pack went in while custom textures are off.
  @Published var offerCustomTextures = false
  /// Set after Gecko codes went in while cheats are off globally.
  @Published var offerCheats = false
  /// Set after a Riivolution pack went in for a library game, to offer playing with it.
  @Published var offerPlayWithMods = false

  private let handler: any ModInstallHandling
  private let downloader: ModDownloadManager
  private let ledger: ModInstallLedger
  /// Title code of the catalogue game, for when the user owns no copy.
  private let catalogueTitleCode: String?
  private(set) var workDirectory: URL
  private var downloadTask: Task<Void, Never>?
  private var keepsExtractedFiles = false
  private var didRestore = false
  /// True while `restoreIfNeeded` is looking at a kept download, which nothing may delete meanwhile.
  private var isRestoring = false
  /// Set by `downloadAgain`: the next `start()` replaces the unpacked download.
  private var replacesDownload = false

  nonisolated private static let extractedFolderName = "extracted"
  private static let titleCodeLength = 3
  nonisolated private static let maxNestedArchives = 8
  nonisolated private static let maxNestedArchiveBytes: Int64 = 512 * 1024 * 1024

  init(file: GameBananaFile, modName: String = "", bananaGameID: Int? = nil, titleCode: String? = nil,
       ownedGame: ModLibraryGame?, handler: any ModInstallHandling,
       downloader: ModDownloadManager = .background, ledger: ModInstallLedger = .shared) {
    self.file = file
    self.modName = modName.isEmpty ? file.fileName : modName
    self.bananaGameID = bananaGameID
    self.catalogueTitleCode = titleCode
    self.ownedGame = ownedGame
    self.handler = handler
    self.downloader = downloader
    self.ledger = ledger
    self.workDirectory = ModDownloadManager.makeWorkDirectory(forFileID: file.id)
  }

  /// Why this file cannot be installed here, or nil when it can.
  nonisolated static func blockedReason(for file: GameBananaFile) -> String? {
    if file.downloadURL == nil { return L("GameBanana lists no download link for this file.") }
    return nil
  }

  var status: Status {
    switch phase {
    case .downloading(let fraction): return .downloading(fraction)
    case .verifying, .extracting: return .preparing
    case .ready: return log.isEmpty ? .downloaded : .installed
    case .idle, .failed: return log.isEmpty ? .none : .installed
    }
  }

  /// True while the model has something a screen would want to come back to.
  var isWorthKeeping: Bool {
    switch phase {
    case .downloading, .verifying, .extracting, .ready: return true
    case .idle, .failed: return isInstalling || isRestoring
    }
  }

  /// True once the unpacked files were handed to the disc-patch flow, which reads them later.
  var holdsFilesForAnotherFlow: Bool { keepsExtractedFiles }

  private var downloadKey: String { String(file.id) }

  /// The game the files are for: the user's copy, else the catalogue's.
  private var titleCode: String? {
    if let owned = ownedGame?.gameID, owned.count >= Self.titleCodeLength { return String(owned.prefix(Self.titleCodeLength)) }
    return catalogueTitleCode
  }

  // MARK: - Restoring

  /// Picks up where an earlier visit, or an earlier launch, left this file: a transfer still under
  /// way, a download that finished while the app was away, an unpacked download, or the list of
  /// what was installed from it.
  func restoreIfNeeded() async {
    guard !didRestore else { return }
    didRestore = true
    isRestoring = true
    defer { isRestoring = false }
    guard case .idle = phase, let record = ledger.record(forFileID: file.id) else { return }
    log = record.installed
    guard let folder = record.workFolder else { return }
    let directory = ModDownloadManager.downloadsDirectory.appendingPathComponent(folder, isDirectory: true)
    let fileManager = FileManager.default
    let extracted = directory.appendingPathComponent(Self.extractedFolderName, isDirectory: true)

    if record.stage != .downloading, fileManager.fileExists(atPath: extracted.path) {
      workDirectory = directory
      let gameID = ownedGame?.gameID
      let classification = await Task.detached(priority: .userInitiated) {
        ModPackageClassifier.classify(extractedRoot: extracted, gameID: gameID)
      }.value
      guard case .idle = phase else { return }
      present(classification)
      return
    }
    if record.stage == .downloading {
      let archive = directory.appendingPathComponent(file.fileName)
      let isRunning = await downloader.isDownloading(key: downloadKey)
      guard case .idle = phase else { return }
      if isRunning {
        workDirectory = directory
        begin(finishedArchive: nil)
        return
      }
      if fileManager.fileExists(atPath: archive.path) {
        workDirectory = directory
        begin(finishedArchive: archive)
        return
      }
    }
    // Nothing of the download is left: keep only what was installed from it.
    try? fileManager.removeItem(at: directory)
    forgetDownload()
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
      let message = String(format: L("Not enough free space: this needs about %@ and %@ is available."),
                           Self.formatted(needed), Self.formatted(available))
      // An unpacked download stays as it is when its replacement cannot start.
      if case .ready = phase {
        replacesDownload = false
        ModBrowserPresenter.shared.notice = message
      } else {
        phase = .failed(message)
      }
    }
  }

  func start() {
    switch phase {
    case .idle, .failed: break
    case .ready:
      guard replacesDownload, !isInstalling, !keepsExtractedFiles else { return }
      removeWorkFolder()
      workDirectory = ModDownloadManager.makeWorkDirectory(forFileID: file.id)
      geckoCodeNames = [:]
    case .downloading, .verifying, .extracting: return
    }
    replacesDownload = false
    didRestore = true
    begin(finishedArchive: nil)
  }

  /// Downloads the file again over an unpacked copy, e.g. after the mod was updated.
  func downloadAgain() {
    guard case .ready = phase, !isInstalling, !keepsExtractedFiles else { return }
    // The copy at hand is deleted only once the new download really starts: after the space
    // check, and after the user agreed to a large one.
    replacesDownload = true
    requestStart()
  }

  func cancel() {
    downloadTask?.cancel()
  }

  private func begin(finishedArchive: URL?) {
    phase = finishedArchive == nil ? .downloading(0) : .verifying
    installedKinds = []
    remember(stage: .downloading)
    downloadTask = Task { [weak self] in await self?.run(finishedArchive: finishedArchive) }
  }

  private func run(finishedArchive: URL?) async {
    defer { downloadTask = nil }
    do {
      try Task.checkCancellation()
      let archive: URL
      if let finishedArchive {
        archive = finishedArchive
      } else {
        archive = try await downloader.download(file, into: workDirectory) { [weak self] fraction in
          Task { @MainActor in
            guard let self, case .downloading = self.phase else { return }
            self.phase = .downloading(fraction)
          }
        }
      }
      try Task.checkCancellation()
      // The transfer may have ended while iCube was in the background: ask for time to unpack it.
      let background = BackgroundTime(name: "iCube.mod-unpack")
      defer { background.end() }
      phase = .verifying
      let expected = file.md5
      try await Task.detached(priority: .userInitiated) {
        try ModDownloadPolicy.verifyChecksum(of: archive, expected: expected)
      }.value
      try Task.checkCancellation()
      phase = .extracting
      let gameID = ownedGame?.gameID
      let classification = try await Task.detached(priority: .userInitiated) {
        let root = try Self.unpack(archive, in: archive.deletingLastPathComponent())
        return ModPackageClassifier.classify(extractedRoot: root, gameID: gameID)
      }.value
      try Task.checkCancellation()
      present(classification)
    } catch is CancellationError {
      removeWorkFolder()
      forgetDownload()
      phase = .idle
    } catch {
      removeWorkFolder()
      forgetDownload()
      phase = .failed(error.localizedDescription)
    }
  }

  private func present(_ classification: ModPackageClassification) {
    var names: [URL: [String]] = [:]
    for case .gecko(let codesFile) in classification.kinds {
      names[codesFile] = (try? ModContentInstaller.geckoText(of: codesFile)).map { GeckoCodeParser.parse($0).map(\.name) } ?? []
    }
    geckoCodeNames = names
    phase = .ready(classification)
    remember(stage: log.isEmpty ? .downloaded : .installed)
  }

  /// Extracts an archive next to itself (or files a bare download under the same folder) and deletes the archive.
  nonisolated private static func unpack(_ archive: URL, in directory: URL) throws -> URL {
    let fm = FileManager.default
    let extracted = directory.appendingPathComponent(extractedFolderName, isDirectory: true)
    try? fm.removeItem(at: extracted)
    if ImportableFileTypes.archiveKind(for: archive) != nil {
      try ZipImportHelper.extractArchive(at: archive, to: extracted)
      expandNestedArchives(in: extracted)
    } else {
      try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
      try fm.moveItem(at: archive, to: extracted.appendingPathComponent(archive.lastPathComponent))
    }
    try? fm.removeItem(at: archive)
    return extracted
  }

  /// Unpacks archives found inside the download, one level deep, each into a folder named after
  /// it. Mods are often a zip of zips ("Voice Packs.rar" beside the files). An archive that cannot
  /// be opened stays where it is, and the classifier then says so.
  nonisolated static func expandNestedArchives(in root: URL) {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return }
    var archives: [URL] = []
    for case let url as URL in enumerator where ImportableFileTypes.archiveKind(for: url) != nil {
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
      if values?.isRegularFile == true, Int64(values?.fileSize ?? 0) <= maxNestedArchiveBytes { archives.append(url) }
    }
    for archive in archives.sorted(by: { $0.path < $1.path }).prefix(maxNestedArchives) {
      var target = archive.deletingPathExtension()
      if fm.fileExists(atPath: target.path) { target = archive.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + "-contents") }
      do {
        try ZipImportHelper.extractArchive(at: archive, to: target)
        try? fm.removeItem(at: archive)
      } catch {
        try? fm.removeItem(at: target)
      }
    }
  }

  // MARK: - Installing

  /// The kinds "Install All" would run: everything but disc patches, which need the user to pick
  /// a game and a destination, and what cannot be installed at all.
  func installableKinds(in classification: ModPackageClassification) -> [Int] {
    classification.kinds.indices.filter { index in
      guard !installedKinds.contains(index) else { return false }
      switch classification.kinds[index] {
      case .textures, .riivolution, .gameFiles: return true
      case .gecko: return ownedGame != nil
      case .discPatch, .unsupported: return false
      }
    }
  }

  func install(kindAt index: Int) {
    guard case .ready(let classification) = phase, classification.kinds.indices.contains(index) else { return }
    perform { try await self.runInstall(of: classification.kinds[index], at: index) }
  }

  /// Installs everything in the download that needs no further choice, one after another. A kind
  /// that fails is reported and the rest still go in.
  func installAll() {
    guard case .ready(let classification) = phase else { return }
    let indices = installableKinds(in: classification)
    perform {
      var failures: [String] = []
      for index in indices {
        do {
          try await self.runInstall(of: classification.kinds[index], at: index)
        } catch {
          failures.append(error.localizedDescription)
        }
      }
      if !failures.isEmpty { ModBrowserPresenter.shared.notice = failures.joined(separator: "\n") }
    }
  }

  private func runInstall(of kind: ModPackageKind, at index: Int) async throws {
    switch kind {
    case .textures(let gameID, let root): try await installTextures(gameID: gameID, root: root)
    case .gecko(let codesFile): try installGecko(file: codesFile)
    case .riivolution(let root): try await runRiivolutionPackInstall(root: root)
    case .gameFiles(let pack): try await installGameFiles(pack)
    case .discPatch, .unsupported: return
    }
    installedKinds.insert(index)
  }

  private func installTextures(gameID: String, root: URL) async throws {
    guard let texturesRoot = ModContentInstaller.bridgedTexturesRoot() else { throw ModContentInstaller.InstallError.emptyTexturePack }
    let result = try await Task.detached(priority: .userInitiated) {
      try ModContentInstaller.installTextures(from: root, gameID: gameID, texturesRoot: texturesRoot)
    }.value
    var line = String(format: L("Installed %d textures for %@."), result.filesCopied, gameID)
    if let mismatch = Self.regionWarning(packID: gameID, ownedID: ownedGame?.gameID) { line += " " + mismatch }
    record(line)
    if !DOLConfigBridge.gfxHiresTextures() { offerCustomTextures = true }
  }

  func enableCustomTextures() {
    DOLConfigBridge.setGfxHiresTextures(true)
    record(L("Custom textures are on."))
  }

  func enableCheats() {
    DOLConfigBridge.setMainEnableCheats(true)
    record(L("Cheats are on."))
  }

  private func installGecko(file codesFile: URL) throws {
    guard let game = ownedGame else { throw ModContentInstaller.InstallError.geckoNeedsLibraryGame }
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
    record(parts.joined(separator: " "))
    if !result.added.isEmpty && !DOLConfigBridge.mainEnableCheats() { offerCheats = true }
  }

  /// Installs the pack in `root` on its own, for a caller that holds a pack folder and no classification.
  func installRiivolutionPack(root: URL) {
    perform { try await self.runRiivolutionPackInstall(root: root) }
  }

  private func runRiivolutionPackInstall(root: URL) async throws {
    try await Task.detached(priority: .userInitiated) { try ModPackageClassifier.gatherLooseRiivolutionXMLs(in: root) }.value
    record(try await handler.installRiivolutionPack(at: root, named: modName))
    offerPlayWithMods = ownedGame != nil
  }

  /// Loose game files go in as a Riivolution pack iCube writes around them, so Dolphin's own
  /// patcher swaps them in at boot and "Play with Mods" lists them like any other pack.
  private func installGameFiles(_ downloaded: ModGameFilePack) async throws {
    var pack = downloaded
    var leftOut: [String] = []
    // With the user's disc at hand, leave out what it has no file for, and say so.
    if let game = ownedGame, let discPath = game.discPath {
      let names = await Task.detached(priority: .userInitiated) { DiscImageBridge.fileNames(inImageAtPath: discPath) }.value
      if let names {
        (pack, leftOut) = downloaded.keeping(discFileNames: names)
        if pack.groups.isEmpty {
          throw ModGameFilePackBuilder.BuildError.nothingOnDisc(fileCount: leftOut.count, gameTitle: game.title)
        }
      }
    }
    let plan = try ModGameFilePackBuilder.plan(pack: pack, modName: modName,
                                               packID: ModGameFilePackBuilder.packID(forFileID: file.id), titleCode: titleCode)
    let stage = workDirectory.appendingPathComponent("pack-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: stage) }
    try await Task.detached(priority: .userInitiated) {
      try ModGameFilePackBuilder.stage(plan, in: stage)
    }.value
    _ = try await handler.installRiivolutionPack(at: stage, named: modName)
    let format = pack.fileCount == 1 ? L("Installed %d game file from %@ as a pack with %d option(s).")
      : L("Installed %d game files from %@ as a pack with %d option(s).")
    var line = String(format: format, pack.fileCount, modName, plan.options.count)
    if !leftOut.isEmpty {
      line += " " + String(format: L("%d were left out because your disc has no file with that name."), leftOut.count)
    }
    record(line)
    offerPlayWithMods = ownedGame != nil
  }

  /// Closes the browser and opens "Play with Mods" for the game the pack was installed for.
  func playWithMods() {
    guard let game = ownedGame else { return }
    ModBrowserPresenter.shared.closeAndShowMods(for: game)
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

  // MARK: - Memory

  private func record(_ line: String) {
    log.append(line)
    remember(stage: .installed)
  }

  /// Writes this file's state to the ledger.
  private func remember(stage: ModInstallRecord.Stage) {
    ledger.save(ModInstallRecord(
      fileID: file.id, fileName: file.fileName, fileSize: file.size, downloadURL: file.downloadURL, md5: file.md5,
      modName: modName, bananaGameID: bananaGameID, workFolder: workDirectory.lastPathComponent, stage: stage,
      installed: log, updatedAt: Date()))
  }

  /// The download is gone: keep the record only for what was installed from it.
  private func forgetDownload() {
    if log.isEmpty {
      ledger.remove(fileID: file.id)
    } else {
      ledger.update(fileID: file.id) { record in
        record.workFolder = nil
        record.stage = .installed
      }
    }
  }

  // MARK: - Cleanup

  /// Called when no screen shows the file any more. A transfer keeps running and an unpacked
  /// download the user has not installed from is kept for their return; a download that is done
  /// with, or never got anywhere, is deleted.
  func cleanUp() {
    guard downloadTask == nil, !isInstalling, !isRestoring else { return }
    switch phase {
    case .ready(let classification):
      let isSpent = !log.isEmpty && installableKinds(in: classification).isEmpty
      if isSpent, !keepsExtractedFiles { discardDownload() }
    case .idle, .failed:
      if !keepsExtractedFiles { removeWorkFolder() }
    case .downloading, .verifying, .extracting:
      break
    }
  }

  /// Deletes the unpacked download and returns to "not downloaded". What was installed stays listed.
  func discardDownload() {
    guard downloadTask == nil, !isInstalling, !isRestoring, !keepsExtractedFiles else { return }
    removeWorkFolder()
    forgetDownload()
    installedKinds = []
    geckoCodeNames = [:]
    phase = .idle
  }

  private func removeWorkFolder() {
    try? FileManager.default.removeItem(at: workDirectory)
  }

  nonisolated static func formatted(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

/// Time from the system to finish a short job after the app left the foreground.
@MainActor
private final class BackgroundTime {
  #if canImport(UIKit)
  private var identifier = UIBackgroundTaskIdentifier.invalid

  init(name: String) {
    identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in self?.end() }
  }

  func end() {
    guard identifier != .invalid else { return }
    UIApplication.shared.endBackgroundTask(identifier)
    identifier = .invalid
  }
  #else
  init(name: String) {}
  func end() {}
  #endif
}
