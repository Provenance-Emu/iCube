// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation
import UIKit

/// Serializes archive extraction and file copies off the main thread.
private actor ArchiveImportService {
  static let shared = ArchiveImportService()

  struct Outcome {
    var importedGames = 0
    var skippedGames = 0
    var extractedArchives = 0
    var errors: [String] = []
  }

  /// Performs disk I/O for picked files while security-scoped access is held.
  func importFiles(_ urls: [URL], softwareFolder: String) -> Outcome {
    let files = ImportableFileTypes.filterImportURLs(urls)
    guard !files.isEmpty else { return Outcome() }

    let fm = FileManager.default
    var outcome = Outcome()

    for url in files {
      let sourcePath = url.path

      if ImportableFileTypes.isArchiveFile(url) {
        if let result = ZipImportHelper.processArchiveInPlace(atPath: sourcePath) {
          if result.importedCount > 0 || result.skippedExistingCount > 0 {
            outcome.extractedArchives += 1
            outcome.importedGames += result.importedCount
            outcome.skippedGames += result.skippedExistingCount
          } else if let message = result.errorMessage {
            outcome.errors.append("\(url.lastPathComponent): \(message)")
          }
        }
        continue
      }

      let destinationPath = (softwareFolder as NSString).appendingPathComponent(url.lastPathComponent)
      if fm.fileExists(atPath: destinationPath) {
        outcome.skippedGames += 1
        continue
      }

      do {
        try fm.copyItem(atPath: sourcePath, toPath: destinationPath)
        LibraryAddedDateStore.record(path: destinationPath)
        outcome.importedGames += 1
      } catch {
        outcome.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
      }
    }

    return outcome
  }
}

@objc
public extension ImportFileManager {
  /// Imports multiple picked files: archives are extracted automatically and disc images are copied into `Software/`.
  @objc(importFilesAtUrls:)
  func importFiles(at urls: [NSURL]) {
    let picked = urls as [URL]
    guard !picked.isEmpty else { return }

    if picked.count == 1, !ImportableFileTypes.isArchiveFile(picked[0]) {
      importFile(at: picked[0])
      return
    }

    Task { @MainActor in
      await importFilesAsync(picked)
    }
  }

  @MainActor
  private func importFilesAsync(_ urls: [URL]) async {
    guard let mainScene = MainSceneCoordinator.shared().mainScene else { return }

    let files = ImportableFileTypes.filterImportURLs(urls)
    guard !files.isEmpty else {
      postSnackbar("No supported files to import")
      return
    }

    showWindow(on: mainScene)

    var accessedURLs: [URL] = []
    for url in urls {
      if url.startAccessingSecurityScopedResource() {
        accessedURLs.append(url)
      }
    }

    let softwareFolder = UserFolderUtil.getSoftwareFolder()
    let outcome = await Task.detached(priority: .userInitiated) {
      await ArchiveImportService.shared.importFiles(files, softwareFolder: softwareFolder)
    }.value

    for url in accessedURLs {
      url.stopAccessingSecurityScopedResource()
    }
    hideWindow()

    if outcome.extractedArchives > 0 {
      postSnackbar(ZipImportHelper.snackbarText(importedCount: outcome.importedGames,
                                               skippedCount: outcome.skippedGames,
                                               archivesProcessed: outcome.extractedArchives))
    } else if outcome.importedGames > 0 {
      postSnackbar(outcome.importedGames == 1 ? "Imported 1 game" : "Imported \(outcome.importedGames) games")
    } else if outcome.skippedGames > 0 {
      postSnackbar(outcome.skippedGames == 1 ? "1 file already imported" : "\(outcome.skippedGames) files already imported")
    }

    if !outcome.errors.isEmpty {
      let message = outcome.errors.prefix(3).joined(separator: "\n\n")
      let suffix = outcome.errors.count > 3 ? "\n\n…" : ""
      presentBatchAlert(title: DOLCoreLocalizedString("Import"),
                        message: message + suffix)
    }

    if outcome.importedGames > 0 || outcome.skippedGames > 0 || outcome.extractedArchives > 0 {
      NotificationCenter.default.post(
        name: NSNotification.Name("DOLImportFileFinishedNotification"),
        object: self,
        userInfo: nil
      )
    }
  }

  private func postSnackbar(_ text: String) {
    NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"),
                                    object: nil,
                                    userInfo: ["text": text])
  }

  private func presentBatchAlert(title: String, message: String) {
    guard let scene = MainSceneCoordinator.shared().mainScene else { return }
    showWindow(on: scene)
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: DOLCoreLocalizedString("OK"), style: .default) { [weak self] _ in
      self?.hideWindow()
    })
    presentViewController(onWindow: alert)
  }
}
#endif
