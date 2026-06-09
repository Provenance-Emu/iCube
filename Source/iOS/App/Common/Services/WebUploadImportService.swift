// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVWebServer
import UIKit

/// Routes web uploads through the same archive extraction pipeline as the document picker
/// and supplies debounced snackbar text when archives were extracted.
final class WebUploadImportService: NSObject, UIApplicationDelegate {
  private let lock = NSLock()
  private var archivesProcessed = 0
  private var gamesImported = 0

  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    PVWebServer.shared.setUploadPostProcessor { [weak self] path in
      self?.processUpload(atPath: path)
    }
    PVWebServer.shared.setUploadSummaryProvider { [weak self] uploadCount in
      self?.consumeSummary(defaultUploadCount: uploadCount)
    }
    return true
  }

  /// Extracts archives immediately after they land in `Software/`.
  private func processUpload(atPath path: String) {
    guard ZipImportHelper.isArchivePath(path),
          let result = ZipImportHelper.processArchiveInPlace(atPath: path) else { return }

    guard result.importedCount > 0 || result.skippedExistingCount > 0 else { return }

    lock.lock()
    archivesProcessed += 1
    gamesImported += result.importedCount
    lock.unlock()
  }

  /// Returns custom snackbar text when archives were extracted during a debounced upload burst.
  private func consumeSummary(defaultUploadCount: Int) -> String? {
    lock.lock()
    let archives = archivesProcessed
    let games = gamesImported
    archivesProcessed = 0
    gamesImported = 0
    lock.unlock()

    if archives > 0 {
      return ZipImportHelper.snackbarText(importedCount: games,
                                          skippedCount: 0,
                                          archivesProcessed: archives)
    }
    return nil
  }
}
