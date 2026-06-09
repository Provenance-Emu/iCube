// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if canImport(Zip)
import Zip
#endif
#if canImport(PLzmaSDK)
import PLzmaSDK
#endif
#if canImport(SWCompression)
import SWCompression
#endif

/// Result of attempting to extract an archive of disc images.
///
/// Exposed to Objective-C so `ImportFileManager` and the web-upload bridge can route
/// archive imports through a single synchronous call.
@objc(DOLZipImportResult)
final class ZipImportResult: NSObject {
  @objc let importedCount: Int
  @objc let skippedExistingCount: Int
  @objc let errorMessage: String?

  init(importedCount: Int, skippedExistingCount: Int, errorMessage: String?) {
    self.importedCount = importedCount
    self.skippedExistingCount = skippedExistingCount
    self.errorMessage = errorMessage
    super.init()
  }
}

/// Aggregate result from processing multiple orphaned archives during a library rescan.
@objc(DOLArchiveBatchImportResult)
final class ArchiveBatchImportResult: NSObject {
  @objc let archivesProcessed: Int
  @objc let gamesImported: Int
  @objc let gamesSkipped: Int
  @objc let failedArchives: Int

  init(archivesProcessed: Int, gamesImported: Int, gamesSkipped: Int, failedArchives: Int) {
    self.archivesProcessed = archivesProcessed
    self.gamesImported = gamesImported
    self.gamesSkipped = gamesSkipped
    self.failedArchives = failedArchives
    super.init()
  }
}

@objc(DOLZipImportHelper)
final class ZipImportHelper: NSObject {
  private enum ArchiveKind {
    case zip
    case sevenZip
    case gzip
    case bzip2
    case tar
    case tarGz
    case tarBz2
    case xz
  }

  private static func mapArchiveKind(_ kind: ImportableFileTypes.ArchiveKind) -> ArchiveKind {
    switch kind {
    case .zip: return .zip
    case .sevenZip: return .sevenZip
    case .gzip: return .gzip
    case .bzip2: return .bzip2
    case .tar: return .tar
    case .tarGz: return .tarGz
    case .tarBz2: return .tarBz2
    case .xz: return .xz
    }
  }

  /// File extensions treated as importable archives across all import paths.
  @objc(supportedArchivePathExtensions)
  static func supportedArchivePathExtensions() -> [String] {
    ImportableFileTypesBridge.archivePathExtensions()
  }

  /// Returns true when `path` has a supported archive extension.
  @objc(isArchivePath:)
  static func isArchivePath(_ path: String) -> Bool {
    ImportableFileTypesBridge.isArchivePath(path)
  }

  /// Human-readable snackbar text for a successful archive import.
  @objc(snackbarTextForImportedCount:skippedCount:archivesProcessed:)
  static func snackbarText(importedCount: Int, skippedCount: Int, archivesProcessed: Int) -> String {
    if importedCount == 0, skippedCount > 0 {
      return skippedCount == 1
        ? "Archive already imported"
        : "\(skippedCount) games from archive already imported"
    }
    if archivesProcessed > 1 {
      return importedCount == 1
        ? "Extracted 1 game from \(archivesProcessed) archives"
        : "Extracted \(importedCount) games from \(archivesProcessed) archives"
    }
    return importedCount == 1
      ? "Extracted 1 game from archive"
      : "Extracted \(importedCount) games from archive"
  }

  /// Snackbar text for a batch orphan recovery pass during library rescan.
  @objc(snackbarTextForBatchImportResult:)
  static func snackbarText(for batch: ArchiveBatchImportResult) -> String? {
    guard batch.archivesProcessed > 0 else { return nil }
    return snackbarText(importedCount: batch.gamesImported,
                        skippedCount: batch.gamesSkipped,
                        archivesProcessed: batch.archivesProcessed)
  }

  /// Extract a supported archive and import contained disc images into `destinationFolder`.
  @objc(importArchiveAtPath:toFolder:)
  static func importArchive(atPath sourcePath: String, toFolder destinationFolder: String) -> ZipImportResult {
    guard let sourceKind = ImportableFileTypes.archiveKind(for: URL(fileURLWithPath: sourcePath)) else {
      return ZipImportResult(importedCount: 0,
                             skippedExistingCount: 0,
                             errorMessage: "Not a supported archive format.")
    }

    let fm = FileManager.default
    let sourceURL = URL(fileURLWithPath: sourcePath)
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("dol_archive_import-\(UUID().uuidString)", isDirectory: true)

    defer { try? fm.removeItem(at: tempDir) }

    do {
      try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
      try extractArchive(kind: mapArchiveKind(sourceKind), sourceURL: sourceURL, to: tempDir)
    } catch {
      return ZipImportResult(importedCount: 0,
                             skippedExistingCount: 0,
                             errorMessage: "The archive could not be extracted. It may be corrupt or password-protected.\n\n\(error.localizedDescription)")
    }

    return importSupportedFiles(from: tempDir, toFolder: destinationFolder)
  }

  /// Document-picker and legacy entry point — delegates to `importArchive`.
  @objc(extractZipAtPath:toFolder:)
  static func extractZip(atPath sourcePath: String, toFolder destinationFolder: String) -> ZipImportResult {
    importArchive(atPath: sourcePath, toFolder: destinationFolder)
  }

  /// Called from the web-upload post-processor after a file lands in `Software/`.
  @objc(processWebUploadAtPath:)
  static func processWebUpload(atPath path: String) {
    _ = processArchiveInPlace(atPath: path)
  }

  /// Scans `folder` recursively for supported archives, extracts ROMs, and removes each
  /// archive atomically once extraction completes.
  @objc(processOrphanedArchivesInFolder:)
  static func processOrphanedArchives(inFolder folder: String) -> ArchiveBatchImportResult {
    let fm = FileManager.default
    let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
    guard fm.fileExists(atPath: folder) else {
      return ArchiveBatchImportResult(archivesProcessed: 0, gamesImported: 0, gamesSkipped: 0, failedArchives: 0)
    }

    var archivePaths: [String] = []
    if let enumerator = fm.enumerator(at: folderURL,
                                      includingPropertiesForKeys: [.isRegularFileKey],
                                      options: [.skipsHiddenFiles]) {
      for case let fileURL as URL in enumerator {
        let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
        guard isRegular, isArchivePath(fileURL.path) else { continue }
        archivePaths.append(fileURL.path)
      }
    }

    var archivesProcessed = 0
    var gamesImported = 0
    var gamesSkipped = 0
    var failedArchives = 0

    for path in archivePaths {
      guard let result = processArchiveInPlace(atPath: path) else { continue }
      if result.importedCount > 0 || result.skippedExistingCount > 0 {
        archivesProcessed += 1
        gamesImported += result.importedCount
        gamesSkipped += result.skippedExistingCount
      } else if result.errorMessage != nil {
        failedArchives += 1
      }
    }

    return ArchiveBatchImportResult(archivesProcessed: archivesProcessed,
                                  gamesImported: gamesImported,
                                  gamesSkipped: gamesSkipped,
                                  failedArchives: failedArchives)
  }

  /// Extracts a single archive beside its contents and removes the archive on success.
  @objc(processArchiveInPlaceAtPath:)
  @discardableResult
  static func processArchiveInPlace(atPath path: String) -> ZipImportResult? {
    guard isArchivePath(path) else { return nil }

    let destinationFolder = (path as NSString).deletingLastPathComponent
    let result = importArchive(atPath: path, toFolder: destinationFolder)

    if result.importedCount > 0 || result.skippedExistingCount > 0 {
      removeArchiveAtomically(atPath: path)
      return result
    }

    if let message = result.errorMessage {
      NSLog("[ArchiveImport] Archive import failed for \(path): \(message)")
    }
    return result
  }

  /// Moves the archive out of the library folder before deletion so a failed unlink
  /// never leaves a half-imported archive beside extracted ROMs.
  private static func removeArchiveAtomically(atPath path: String) {
    let fm = FileManager.default
    let sourceURL = URL(fileURLWithPath: path)
    guard fm.fileExists(atPath: path) else { return }

    let trashURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("dol_archive_trash-\(UUID().uuidString)")
      .appendingPathExtension(sourceURL.pathExtension)

    do {
      try fm.moveItem(at: sourceURL, to: trashURL)
      try fm.removeItem(at: trashURL)
    } catch {
      NSLog("[ArchiveImport] Failed to remove archive at \(path): \(error.localizedDescription)")
      try? fm.removeItem(atPath: path)
    }
  }

  // MARK: - Extraction

  private static func extractArchive(kind: ArchiveKind, sourceURL: URL, to tempDir: URL) throws {
    switch kind {
    case .zip:
      try extractZipArchive(sourceURL: sourceURL, to: tempDir)
    case .sevenZip:
      try extractSevenZip(sourceURL: sourceURL, to: tempDir)
    case .xz:
      try extractXz(sourceURL: sourceURL, to: tempDir)
    case .tar:
      try extractTarArchive(sourceURL: sourceURL, to: tempDir)
    case .tarGz:
      try extractTarGzArchive(sourceURL: sourceURL, to: tempDir)
    case .tarBz2:
      try extractTarBz2Archive(sourceURL: sourceURL, to: tempDir)
    case .gzip:
      try extractGzipSingleFile(sourceURL: sourceURL, to: tempDir)
    case .bzip2:
      try extractBzip2SingleFile(sourceURL: sourceURL, to: tempDir)
    }
  }

  private static func extractZipArchive(sourceURL: URL, to tempDir: URL) throws {
    #if canImport(Zip)
    try Zip.unzipFile(sourceURL, destination: tempDir, overwrite: true, password: nil, progress: nil)
    #else
    throw archiveUnavailableError("Zip")
    #endif
  }

  #if canImport(PLzmaSDK)
  private static func extractSevenZip(sourceURL: URL, to tempDir: URL) throws {
    try extractWithPLzma(sourceURL: sourceURL, to: tempDir, fileType: .sevenZ)
  }

  private static func extractXz(sourceURL: URL, to tempDir: URL) throws {
    try extractWithPLzma(sourceURL: sourceURL, to: tempDir, fileType: .xz)
  }

  private static func extractWithPLzma(sourceURL: URL, to tempDir: URL, fileType: FileType) throws {
    let stream = try InStream(path: Path(sourceURL.path))
    let decoder = try Decoder(stream: stream, fileType: fileType, delegate: nil)
    _ = try decoder.open()
    _ = try decoder.extract(to: Path(tempDir.path))
  }
  #else
  private static func extractSevenZip(sourceURL: URL, to tempDir: URL) throws {
    throw archiveUnavailableError("7z")
  }

  private static func extractXz(sourceURL: URL, to tempDir: URL) throws {
    throw archiveUnavailableError("xz")
  }
  #endif

  #if canImport(SWCompression)
  private static func extractGzipSingleFile(sourceURL: URL, to tempDir: URL) throws {
    let data = try Data(contentsOf: sourceURL)
    let decompressed = try GzipArchive.unarchive(archive: data)
    let outputName = sourceURL.deletingPathExtension().lastPathComponent
    try decompressed.write(to: tempDir.appendingPathComponent(outputName))
  }

  private static func extractBzip2SingleFile(sourceURL: URL, to tempDir: URL) throws {
    let data = try Data(contentsOf: sourceURL)
    let decompressed = try BZip2.decompress(data: data)
    let outputName = sourceURL.deletingPathExtension().lastPathComponent
    try decompressed.write(to: tempDir.appendingPathComponent(outputName))
  }

  private static func extractTarArchive(sourceURL: URL, to tempDir: URL) throws {
    let data = try Data(contentsOf: sourceURL)
    try writeTarEntries(try TarContainer.open(container: data), to: tempDir)
  }

  private static func extractTarGzArchive(sourceURL: URL, to tempDir: URL) throws {
    let data = try Data(contentsOf: sourceURL)
    let tarData = try GzipArchive.unarchive(archive: data)
    try writeTarEntries(try TarContainer.open(container: tarData), to: tempDir)
  }

  private static func extractTarBz2Archive(sourceURL: URL, to tempDir: URL) throws {
    let data = try Data(contentsOf: sourceURL)
    let tarData = try BZip2.decompress(data: data)
    try writeTarEntries(try TarContainer.open(container: tarData), to: tempDir)
  }

  private static func writeTarEntries(_ entries: [TarEntry], to tempDir: URL) throws {
    let fm = FileManager.default
    for entry in entries {
      guard entry.info.type == .regular, let payload = entry.data else { continue }
      let relative = entry.info.name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      guard !relative.isEmpty, !shouldSkipArchiveRelativePath(relative) else { continue }
      let outURL = tempDir.appendingPathComponent(relative)
      try fm.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try payload.write(to: outURL)
    }
  }
  #else
  private static func extractGzipSingleFile(sourceURL: URL, to tempDir: URL) throws {
    throw archiveUnavailableError("gzip")
  }

  private static func extractBzip2SingleFile(sourceURL: URL, to tempDir: URL) throws {
    throw archiveUnavailableError("bzip2")
  }

  private static func extractTarArchive(sourceURL: URL, to tempDir: URL) throws {
    #if canImport(PLzmaSDK)
    try extractWithPLzma(sourceURL: sourceURL, to: tempDir, fileType: .tar)
    #else
    throw archiveUnavailableError("tar")
    #endif
  }

  private static func extractTarGzArchive(sourceURL: URL, to tempDir: URL) throws {
    throw archiveUnavailableError("tar.gz")
  }

  private static func extractTarBz2Archive(sourceURL: URL, to tempDir: URL) throws {
    throw archiveUnavailableError("tar.bz2")
  }
  #endif

  private static func archiveUnavailableError(_ component: String) -> NSError {
    NSError(domain: "DOLArchiveImport", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "\(component) support is unavailable in this build."])
  }

  private static func shouldSkipArchiveRelativePath(_ relative: String) -> Bool {
    let normalized = relative.replacingOccurrences(of: "\\", with: "/").lowercased()
    return normalized.hasPrefix("__macosx/") || normalized.contains("/__macosx/")
      || normalized == ".ds_store" || normalized.hasSuffix("/.ds_store")
  }

  // MARK: - Import extracted files

  private static func importSupportedFiles(from tempDir: URL, toFolder destinationFolder: String) -> ZipImportResult {
    let fm = FileManager.default
    var supportedFiles: [URL] = []

    if let enumerator = fm.enumerator(at: tempDir,
                                      includingPropertiesForKeys: [.isRegularFileKey],
                                      options: [.skipsHiddenFiles]) {
      for case let fileURL as URL in enumerator {
        let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
        guard isRegular else { continue }
        guard ImportableFileTypes.isSoftwareFile(fileURL) else { continue }

        let relative = fileURL.path.replacingOccurrences(of: tempDir.path + "/", with: "")
        guard !shouldSkipArchiveRelativePath(relative) else { continue }
        supportedFiles.append(fileURL)
      }
    }

    guard !supportedFiles.isEmpty else {
      return ZipImportResult(importedCount: 0,
                             skippedExistingCount: 0,
                             errorMessage: "This archive does not contain any supported disc images.")
    }

    let destinationURL = URL(fileURLWithPath: destinationFolder, isDirectory: true)
    var imported = 0
    var skippedExisting = 0
    var moveErrors: [String] = []
    var reservedNames = Set<String>()

    for fileURL in supportedFiles {
      let target = uniqueFlatDestinationURL(for: fileURL,
                                            relativeTo: tempDir,
                                            in: destinationURL,
                                            reservedNames: &reservedNames)

      if fm.fileExists(atPath: target.path) {
        skippedExisting += 1
        reservedNames.insert(target.lastPathComponent.lowercased())
        continue
      }

      do {
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: fileURL, to: target)
        LibraryAddedDateStore.record(path: target.path)
        imported += 1
        reservedNames.insert(target.lastPathComponent.lowercased())
      } catch {
        moveErrors.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
      }
    }

    if imported == 0 {
      if skippedExisting > 0, moveErrors.isEmpty {
        return ZipImportResult(importedCount: 0,
                               skippedExistingCount: skippedExisting,
                               errorMessage: "Every game in this archive has already been imported.")
      }
      let detail = moveErrors.isEmpty ? "" : "\n\n" + moveErrors.joined(separator: "\n")
      return ZipImportResult(importedCount: 0,
                             skippedExistingCount: skippedExisting,
                             errorMessage: "No games from this archive could be imported.\(detail)")
    }

    let errorMessage = moveErrors.isEmpty ? nil : "Some files could not be imported:\n\n" + moveErrors.joined(separator: "\n")
    return ZipImportResult(importedCount: imported,
                           skippedExistingCount: skippedExisting,
                           errorMessage: errorMessage)
  }

  /// Flattens nested archive paths into `Software/` while avoiding basename collisions.
  private static func uniqueFlatDestinationURL(for fileURL: URL,
                                               relativeTo tempDir: URL,
                                               in destinationURL: URL,
                                               reservedNames: inout Set<String>) -> URL {
    let fm = FileManager.default
    let flatName = fileURL.lastPathComponent
    var candidate = destinationURL.appendingPathComponent(flatName)
    if !fm.fileExists(atPath: candidate.path), !reservedNames.contains(flatName.lowercased()) {
      return candidate
    }

    let relative = fileURL.path.replacingOccurrences(of: tempDir.path + "/", with: "")
    let flattened = relative.replacingOccurrences(of: "/", with: "_")
    candidate = destinationURL.appendingPathComponent(flattened)

    if !fm.fileExists(atPath: candidate.path), !reservedNames.contains(flattened.lowercased()) {
      return candidate
    }

    let base = fileURL.deletingPathExtension().lastPathComponent
    let ext = fileURL.pathExtension
    var counter = 1
    while true {
      let suffix = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
      candidate = destinationURL.appendingPathComponent(suffix)
      if !fm.fileExists(atPath: candidate.path), !reservedNames.contains(suffix.lowercased()) {
        return candidate
      }
      counter += 1
    }
  }
}
