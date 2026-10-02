// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVWebServer
import UIKit

/// Routes web uploads through the same archive extraction pipeline as the document picker
/// and supplies debounced snackbar text when archives were extracted or rejected.
final class WebUploadImportService: NSObject, UIApplicationDelegate {
  private let lock = NSLock()
  private var archivesProcessed = 0
  private var gamesImported = 0
  /// Names of uploads that failed to import, and whether each was moved to Rejected Imports.
  private var rejectedArchives: [(name: String, movedAside: Bool)] = []

  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    PVWebServer.shared.setUploadPostProcessor { [weak self] path in
      self?.processUpload(atPath: path, libraryFolder: UserFolderUtil.getSoftwareFolder())
    }
    PVWebServer.shared.setUploadSummaryProvider { [weak self] uploadCount in
      self?.consumeSummary(defaultUploadCount: uploadCount)
    }
    return true
  }

  /// Extracts archives immediately after they land in `libraryFolder`. An archive that can't be
  /// imported (corrupt, unsafe paths, no disc images) is moved to Rejected Imports so the
  /// orphan rescan doesn't copy and reject it again, and is reported in the upload summary.
  func processUpload(atPath path: String, libraryFolder: String) {
    if ZipImportHelper.isArchivePath(path) {
      guard let result = ZipImportHelper.processArchiveInPlace(atPath: path, libraryFolder: libraryFolder) else {
        return
      }
      lock.lock()
      if result.importedCount > 0 || result.skippedExistingCount > 0 {
        archivesProcessed += 1
        gamesImported += result.importedCount
      } else if result.errorMessage != nil {
        rejectedArchives.append(((path as NSString).lastPathComponent, result.movedToRejectedImports))
      }
      lock.unlock()
      return
    }

    LibraryAddedDateStore.record(path: path)
  }

  /// Returns custom snackbar text when archives were extracted or rejected during a debounced
  /// upload burst.
  func consumeSummary(defaultUploadCount: Int) -> String? {
    lock.lock()
    let archives = archivesProcessed
    let games = gamesImported
    let rejected = rejectedArchives
    archivesProcessed = 0
    gamesImported = 0
    rejectedArchives = []
    lock.unlock()

    let extracted = archives > 0
      ? ZipImportHelper.snackbarText(importedCount: games, skippedCount: 0, archivesProcessed: archives)
      : nil
    let movedAside = rejected.filter { $0.movedAside }
    let leftInPlace = rejected.filter { !$0.movedAside }
    let rejectedText = ZipImportHelper.rejectedSnackbarText(count: movedAside.count,
                                                            name: movedAside.first?.name,
                                                            movedAside: true)
    let failedText = ZipImportHelper.rejectedSnackbarText(count: leftInPlace.count,
                                                          name: leftInPlace.first?.name,
                                                          movedAside: false)
    let lines = [extracted, rejectedText, failedText].compactMap { $0 }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }
}
