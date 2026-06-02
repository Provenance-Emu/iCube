// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if canImport(Zip)
import Zip
#endif

/// Result of attempting to extract a zip archive of disc images.
///
/// Exposed to Objective-C so `ImportFileManager` can route `.zip` imports
/// through a single synchronous call. Extraction is synchronous (mirroring the
/// synchronous `copyItemAtPath:` used for non-archive imports) so the caller can
/// release its security-scoped resource immediately afterward.
@objc(DOLZipImportResult)
final class ZipImportResult: NSObject {
  /// Number of supported disc images moved into the destination folder.
  @objc let importedCount: Int
  /// Number of entries skipped because a file with the same name already
  /// existed in the destination (already-imported collisions).
  @objc let skippedExistingCount: Int
  /// Localized-description-style error message, or nil on success.
  /// Non-nil whenever nothing usable was imported.
  @objc let errorMessage: String?

  init(importedCount: Int, skippedExistingCount: Int, errorMessage: String?) {
    self.importedCount = importedCount
    self.skippedExistingCount = skippedExistingCount
    self.errorMessage = errorMessage
    super.init()
  }
}

@objc(DOLZipImportHelper)
final class ZipImportHelper: NSObject {
  /// Supported disc-image extensions the library scanner recognizes.
  ///
  /// NOTE: This intentionally mirrors the canonical allow-list in
  /// `TVLibraryView.swift` (`expandAndFilterImportURLs`). It is duplicated
  /// rather than shared to keep this change scoped to the import pipeline
  /// (TVLibraryView is owned by other work). If these ever diverge, that is a
  /// bug — keep them in sync.
  private static let supportedExtensions: Set<String> =
    ["iso", "gcm", "wbfs", "gcz", "ciso", "rvz", "wad", "dol", "elf"]

  /// Extract a `.zip` at `sourcePath`, then move every supported disc image it
  /// contains into `destinationFolder` (where the library scanner looks).
  ///
  /// - The source archive itself is never copied into the destination, so a
  ///   failed/empty zip leaves no phantom file blocking a retry.
  /// - All temp state is removed before returning on every path.
  /// - Entries whose names collide with an existing file in the destination
  ///   are skipped and counted (not overwritten).
  ///
  /// Returns a result describing what happened; `errorMessage` is non-nil when
  /// nothing usable was imported.
  @objc(extractZipAtPath:toFolder:)
  static func extractZip(atPath sourcePath: String, toFolder destinationFolder: String) -> ZipImportResult {
    let fm = FileManager.default
    let sourceURL = URL(fileURLWithPath: sourcePath)

    // Stage extraction in a unique temp directory so we can discard
    // unsupported entries and never leave anything behind.
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("dol_zip_import-\(UUID().uuidString)", isDirectory: true)

    defer {
      try? fm.removeItem(at: tempDir)
    }

    do {
      try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    } catch {
      return ZipImportResult(importedCount: 0,
                             skippedExistingCount: 0,
                             errorMessage: "Could not create a temporary directory for extraction.\n\n\(error.localizedDescription)")
    }

    do {
      #if canImport(Zip)
      try Zip.unzipFile(sourceURL, destination: tempDir, overwrite: true, password: nil, progress: nil)
      #else
      // The `Zip` SPM package is a direct dependency of the iCube target, so this branch is
      // never compiled. Kept valid (not FileManager.unzipItem, which doesn't exist) as a guard.
      throw NSError(domain: "DOLZipImport", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Zip support is unavailable in this build."])
      #endif
    } catch {
      return ZipImportResult(importedCount: 0,
                             skippedExistingCount: 0,
                             errorMessage: "The archive could not be extracted. It may be corrupt or password-protected.\n\n\(error.localizedDescription)")
    }

    // Walk the extracted tree (handles nested / multi-file archives) and
    // collect every supported disc image.
    var supportedFiles: [URL] = []
    if let enumerator = fm.enumerator(at: tempDir,
                                      includingPropertiesForKeys: [.isRegularFileKey],
                                      options: [.skipsHiddenFiles]) {
      for case let fileURL as URL in enumerator {
        let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
        guard isRegular else { continue }
        if supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
          supportedFiles.append(fileURL)
        }
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

    for fileURL in supportedFiles {
      let target = destinationURL.appendingPathComponent(fileURL.lastPathComponent)

      // Per-entry dedup: a file already in the library is skipped, not
      // overwritten. This is the real dedup surface now that the zip
      // itself is never written into the destination.
      if fm.fileExists(atPath: target.path) {
        skippedExisting += 1
        continue
      }

      do {
        try fm.moveItem(at: fileURL, to: target)
        imported += 1
      } catch {
        moveErrors.append("\(fileURL.lastPathComponent): \(error.localizedDescription)")
      }
    }

    if imported == 0 {
      if skippedExisting > 0 && moveErrors.isEmpty {
        return ZipImportResult(importedCount: 0,
                               skippedExistingCount: skippedExisting,
                               errorMessage: "Every game in this archive has already been imported.")
      }
      let detail = moveErrors.isEmpty ? "" : "\n\n" + moveErrors.joined(separator: "\n")
      return ZipImportResult(importedCount: 0,
                             skippedExistingCount: skippedExisting,
                             errorMessage: "No games from this archive could be imported.\(detail)")
    }

    // Partial success: some moved, some failed. Report imported count;
    // surface errors only if any occurred.
    let errorMessage = moveErrors.isEmpty ? nil : "Some files could not be imported:\n\n" + moveErrors.joined(separator: "\n")
    return ZipImportResult(importedCount: imported,
                           skippedExistingCount: skippedExisting,
                           errorMessage: errorMessage)
  }
}
