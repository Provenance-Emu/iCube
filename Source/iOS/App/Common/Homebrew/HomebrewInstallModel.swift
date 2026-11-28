// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum HomebrewInstallError: LocalizedError, Equatable {
  case noPackage
  case sizeMismatch
  case checksumMismatch
  case noProgram
  case cannotBoot

  var errorDescription: String? {
    switch self {
    case .noPackage: return L("No download is available for this title yet.")
    case .sizeMismatch: return L("The download is not the size Dolphin Depot lists, so it was discarded.")
    case .checksumMismatch: return L("The download does not match Dolphin Depot's checksum, so it was discarded.")
    case .noProgram: return L("This package has no program iCube can start.")
    case .cannotBoot: return L("iCube cannot start the program in this package.")
    }
  }
}

/// Takes one homebrew title from "Download" to a game in the library: fetch, verify, unpack, pick
/// the program, move it into `Software/Homebrew/<slug>/`, register it, and record the version.
///
/// Nothing reaches the Homebrew folder until the package has passed every check, and an update
/// keeps the old version until the new one is registered.
@MainActor
final class HomebrewInstallModel: ObservableObject {
  enum Phase: Equatable {
    case idle
    case downloading(Double)
    case verifying
    case installing
    case installed
    case failed(String)
  }

  let title: HomebrewTitle
  let workDirectory: URL

  @Published private(set) var phase: Phase = .idle
  @Published private(set) var state: HomebrewInstalledIndex.State
  /// Set when a download needs the user's go-ahead because of its size.
  @Published var largeDownloadBytes: Int64?

  private let root: URL
  private let downloader: any HomebrewDownloading
  private let registrar: any HomebrewLibraryRegistering
  private let cover: @Sendable (URL) async -> Data?
  private let availableBytes: @Sendable () -> Int64?
  private var task: Task<Void, Never>?

  init(title: HomebrewTitle, root: URL, downloader: any HomebrewDownloading = ModDownloadManager.shared,
       registrar: any HomebrewLibraryRegistering = LiveHomebrewLibraryRegistrar(),
       cover: @escaping @Sendable (URL) async -> Data? = { try? await DolphinDepotClient.shared.data(from: $0) },
       availableBytes: @escaping @Sendable () -> Int64? = {
         ModDownloadPolicy.availableBytes(at: URL(fileURLWithPath: UserFolderUtil.getUserFolder()))
       }) {
    self.title = title
    self.root = root
    self.downloader = downloader
    self.registrar = registrar
    self.cover = cover
    self.availableBytes = availableBytes
    self.workDirectory = ModDownloadManager.makeWorkDirectory(forKey: "homebrew-" + title.slug)
    self.state = HomebrewInstalledIndex.load(root: root).state(of: title, root: root)
  }

  /// Installs in progress, by slug. An install outlives the screen that started it, so a screen
  /// opened later attaches to it instead of starting a second one over the same folder.
  private static var running: [String: HomebrewInstallModel] = [:]

  /// Titles with an install in progress, on any screen.
  static var installingSlugs: Set<String> { Set(running.keys) }

  /// The model to show for `title`: the one already installing it, else a new one.
  static func attach(title: HomebrewTitle, root: URL) -> HomebrewInstallModel {
    running[title.slug] ?? HomebrewInstallModel(title: title, root: root)
  }

  /// True from Download until the install has stopped, whichever way.
  var isBusy: Bool { task != nil }

  /// The installed program, for Play.
  var programURL: URL? {
    HomebrewInstalledIndex.load(root: root).programURL(forSlug: title.slug, root: root)
  }

  /// Re-reads the index: the library may have deleted the game since.
  func refreshState() {
    state = HomebrewInstalledIndex.load(root: root).state(of: title, root: root)
  }

  // MARK: - Starting and stopping

  func requestStart() {
    guard !isBusy, Self.running[title.slug] == nil else { return }
    guard let latest = title.latest else {
      phase = .failed(HomebrewInstallError.noPackage.localizedDescription)
      return
    }
    switch ModDownloadPolicy.verdict(fileSize: latest.size, availableBytes: availableBytes()) {
    case .allowed:
      start()
    case .confirmLargeDownload(let bytes):
      largeDownloadBytes = bytes
    case .insufficientSpace(let needed, let available):
      phase = .failed(String(format: L("Not enough free space: this needs about %@ and %@ is available."),
                             ModInstallModel.formatted(needed), ModInstallModel.formatted(available)))
    }
  }

  func start() {
    guard !isBusy, Self.running[title.slug] == nil else { return }
    Self.running[title.slug] = self
    phase = .downloading(0)
    task = Task { [weak self] in await self?.run() }
  }

  /// Stops the download and keeps its resume data, so Download continues where it stopped.
  func cancel() {
    task?.cancel()
  }

  // MARK: - The install

  private func run() async {
    defer {
      task = nil
      Self.running[title.slug] = nil
    }
    do {
      try await install()
      phase = .installed
    } catch is CancellationError {
      phase = .idle
    } catch {
      phase = .failed(error.localizedDescription)
    }
    // If putting the previous version back failed, it is still in the work folder: leave it for
    // the stale-download sweep rather than delete the only copy.
    let previous = workDirectory.appendingPathComponent(Self.previousFolderName, isDirectory: true)
    if !FileManager.default.fileExists(atPath: previous.path) {
      try? FileManager.default.removeItem(at: workDirectory)
    }
    refreshState()
  }

  private func install() async throws {
    try Task.checkCancellation()
    let slug = title.slug
    guard let latest = title.latest,
          let source = DolphinDepotEndpoint.package(slug: slug, fileName: latest.fileName) else {
      throw HomebrewInstallError.noPackage
    }
    let download = try await downloader.download(
      key: "homebrew-\(slug)-\(latest.versionSlug)", from: source, fileName: latest.fileName,
      expectedBytes: latest.size, into: workDirectory
    ) { [weak self] fraction in
      Task { @MainActor in
        guard let self, case .downloading = self.phase else { return }
        self.phase = .downloading(fraction)
      }
    }
    try Task.checkCancellation()

    phase = .verifying
    try await Task.detached(priority: .userInitiated) {
      try Self.verify(download, expectedBytes: latest.size)
    }.value
    try Task.checkCancellation()

    phase = .installing
    let extracted = workDirectory.appendingPathComponent("extracted", isDirectory: true)
    let staged = try await Task.detached(priority: .userInitiated) {
      try Self.unpack(download.file, to: extracted, slug: slug)
    }.value
    guard await registrar.canBoot(staged) else { throw HomebrewInstallError.cannotBoot }
    guard let relative = Self.relativePath(of: staged, in: extracted) else { throw HomebrewInstallError.noProgram }
    try Task.checkCancellation()

    // The old program's title and cover are keyed by its bytes, so read them before it goes.
    var index = HomebrewInstalledIndex.load(root: root)
    var kept: (title: String?, cover: Data?) = (nil, nil)
    if let old = index.programURL(forSlug: slug, root: root) { kept = await registrar.metadata(of: old) }
    var coverData = kept.cover
    if coverData == nil, let path = title.coverPath, let url = DolphinDepotEndpoint.image(path: path) {
      coverData = await cover(url)
    }
    try Task.checkCancellation()

    // The swap either completes or is undone: a failure or a cancellation while registering puts
    // the previous version back.
    let root = root
    let previous = workDirectory.appendingPathComponent(Self.previousFolderName, isDirectory: true)
    let swap = try await Task.detached(priority: .userInitiated) {
      try Self.swapIn(extracted, root: root, slug: slug, previous: previous)
    }.value
    let program = swap.folder.appendingPathComponent(relative)
    do {
      try await registrar.register(program, title: kept.title ?? title.name, cover: coverData)
    } catch {
      Self.undo(swap)
      throw error
    }
    index = HomebrewInstalledIndex.load(root: root)
    index.titles[slug] = .init(versionSlug: latest.versionSlug, version: latest.version, programPath: slug + "/" + relative)
    do {
      try index.save(root: root)
    } catch {
      Self.undo(swap)
      throw error
    }
    registrar.publish(program)
    try? FileManager.default.removeItem(at: previous)
  }

  // MARK: - File work

  /// Size always; MD5 when the server's ETag is one (Dolphin Depot's CDN sends the MD5 in quotes).
  private nonisolated static func verify(_ download: HomebrewDownload, expectedBytes: Int64) throws {
    let size = (try download.file.resourceValues(forKeys: [.fileSizeKey])).fileSize.map(Int64.init)
    guard size == expectedBytes else { throw HomebrewInstallError.sizeMismatch }
    guard let md5 = md5(fromETag: download.etag) else { return }
    guard try ModDownloadPolicy.md5(of: download.file).caseInsensitiveCompare(md5) == .orderedSame else {
      throw HomebrewInstallError.checksumMismatch
    }
  }

  /// The MD5 inside an ETag, or nil when the tag is weak, multipart or otherwise not one.
  nonisolated static func md5(fromETag etag: String?) -> String? {
    guard let etag, etag.hasPrefix("\""), etag.hasSuffix("\""), etag.count == 34 else { return nil }
    let inner = etag.dropFirst().dropLast()
    return inner.allSatisfy(\.isHexDigit) ? String(inner) : nil
  }

  /// Unpacks the archive, picks the program and gives it the title's own name.
  private nonisolated static func unpack(_ archive: URL, to extracted: URL, slug: String) throws -> URL {
    try? FileManager.default.removeItem(at: extracted)
    try ZipImportHelper.extractArchive(at: archive, to: extracted)
    try? FileManager.default.removeItem(at: archive)
    guard let program = HomebrewPackageLayout.program(in: extracted, slug: slug) else { throw HomebrewInstallError.noProgram }
    return try HomebrewPackageLayout.rename(program, slug: slug)
  }

  private nonisolated static func relativePath(of file: URL, in folder: URL) -> String? {
    let base = folder.resolvingSymlinksInPath().pathComponents
    let parts = file.resolvingSymlinksInPath().pathComponents
    guard parts.count > base.count, Array(parts.prefix(base.count)) == base else { return nil }
    let rest = Array(parts.dropFirst(base.count))
    return rest.allSatisfy(HomebrewName.isSafe) ? rest.joined(separator: "/") : nil
  }

  private static let previousFolderName = "previous"

  private struct Swap: Sendable {
    let folder: URL
    let backup: URL?
  }

  /// Puts the unpacked package at `root/<slug>`, moving what was there to `previous` until the
  /// caller is sure the new one is good. `previous` is outside the library folder, which is
  /// scanned for games, so the old program never shows up as a second entry.
  private nonisolated static func swapIn(_ extracted: URL, root: URL, slug: String, previous: URL) throws -> Swap {
    guard HomebrewName.isSafe(slug) else { throw CocoaError(.fileWriteInvalidFileName) }
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let folder = root.appendingPathComponent(slug, isDirectory: true)
    var backup: URL?
    if fm.fileExists(atPath: folder.path) {
      try? fm.removeItem(at: previous)
      try fm.moveItem(at: folder, to: previous)
      backup = previous
    }
    do {
      try fm.moveItem(at: extracted, to: folder)
    } catch {
      undo(Swap(folder: folder, backup: backup))
      throw error
    }
    return Swap(folder: folder, backup: backup)
  }

  private nonisolated static func undo(_ swap: Swap) {
    let fm = FileManager.default
    try? fm.removeItem(at: swap.folder)
    if let backup = swap.backup { try? fm.moveItem(at: backup, to: swap.folder) }
  }
}
