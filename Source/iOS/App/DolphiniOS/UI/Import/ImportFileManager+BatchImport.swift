// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation
import UIKit

@objc
public extension ImportFileManager {
  /// Imports multiple picked files: archives are extracted automatically and disc images are copied into `Software/`.
  @objc(importFilesAtUrls:)
  func importFiles(at urls: [NSURL]) {
    let picked = urls as [URL]
    guard !picked.isEmpty else { return }

    if picked.count == 1 {
      importFile(at: picked[0])
      return
    }

    importFilesBatch(picked)
  }

  private func importFilesBatch(_ urls: [URL]) {
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
    let fm = FileManager.default
    var importedGames = 0
    var skippedGames = 0
    var extractedArchives = 0
    var errors: [String] = []

    for url in files {
      let sourcePath = url.path

      if ImportableFileTypes.isArchiveFile(url) {
        if let result = ZipImportHelper.processArchiveInPlace(atPath: sourcePath) {
          if result.importedCount > 0 || result.skippedExistingCount > 0 {
            extractedArchives += 1
            importedGames += result.importedCount
            skippedGames += result.skippedExistingCount
          } else if let message = result.errorMessage {
            errors.append("\(url.lastPathComponent): \(message)")
          }
        }
        continue
      }

      let destinationPath = (softwareFolder as NSString).appendingPathComponent(url.lastPathComponent)
      if fm.fileExists(atPath: destinationPath) {
        skippedGames += 1
        continue
      }

      do {
        try fm.copyItem(atPath: sourcePath, toPath: destinationPath)
        importedGames += 1
      } catch {
        errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
      }
    }

    for url in accessedURLs {
      url.stopAccessingSecurityScopedResource()
    }
    hideWindow()

    if extractedArchives > 0 {
      postSnackbar(ZipImportHelper.snackbarText(importedCount: importedGames,
                                               skippedCount: skippedGames,
                                               archivesProcessed: extractedArchives))
    } else if importedGames > 0 {
      postSnackbar(importedGames == 1 ? "Imported 1 game" : "Imported \(importedGames) games")
    } else if skippedGames > 0 {
      postSnackbar(skippedGames == 1 ? "1 file already imported" : "\(skippedGames) files already imported")
    }

    if !errors.isEmpty {
      let message = errors.prefix(3).joined(separator: "\n\n")
      let suffix = errors.count > 3 ? "\n\n…" : ""
      presentBatchAlert(title: DOLCoreLocalizedString("Import"),
                        message: message + suffix)
    }

    if importedGames > 0 || skippedGames > 0 || extractedArchives > 0 {
      NotificationCenter.default
        .post(name: .DOLImportFileFinished,
                                    object: self,
                                    userInfo: nil)
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
