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
  /// NAND import notices for the next upload summary (started, keys received, or refused).
  private var nandNotices: [String] = []
  private var nandImportInProgress = false

  /// Where a NAND backup waits while it imports, and where an uploaded keys.bin waits for it. Outside the library
  /// folder, so the rescan that follows an upload never lists them as games.
  var nandStagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("NANDImport", isDirectory: true)
  /// The NAND is in use while a game runs.
  var isEmulationRunning: () -> Bool = { TVEmulationBridge.isRunning() }
  /// Runs the importer; the default hops to the main thread because it presents the progress alert.
  var nandImporter: (_ url: URL, _ keysURL: URL?, _ completion: @escaping (_ success: Bool) -> Void) -> Void = { url, keysURL, completion in
    DispatchQueue.main.async { NANDImportManager.importNAND(from: url, keysURL: keysURL, completion: completion) }
  }

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
    if handleNandUpload(atPath: path) { return }

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

    if DiscPatchImportRouter.adoptUpload(atPath: path) { return }

    LibraryAddedDateStore.record(path: path)
  }

  /// Routes a BootMii NAND backup (and its keys.bin) to the NAND importer instead of the library. Anything
  /// else, including a `nand.bin` of the wrong size (a renamed disc image), returns false and takes the normal
  /// upload handling untouched.
  ///
  /// Uploads are copies of files still on the user's computer, so every refusal deletes the copy and tells the
  /// user to upload again; nothing is left behind in the library or in tmp. A keyless dump is imported only
  /// with a keys.bin uploaded before it. The dump is moved out of the library folder before the import (the
  /// rescan that follows an upload would list a 528 MB `.bin` as a game) and deleted when the import ends. The
  /// keys.bin is deleted after a good import only, so a failed one can be retried with just nand.bin.
  private func handleNandUpload(atPath path: String) -> Bool {
    let fileManager = FileManager.default
    let size = ((try? fileManager.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    switch UploadKind.classify(fileName: (path as NSString).lastPathComponent, size: size) {
    case .other:
      return false
    case .nandKeys:
      stageNandKeys(atPath: path)
    case .nandBackup:
      importNandBackup(atPath: path, size: size)
    }
    return true
  }

  private var stagedKeysURL: URL { nandStagingRoot.appendingPathComponent("keys.bin") }

  private func stageNandKeys(atPath path: String) {
    lock.lock()
    let importing = nandImportInProgress
    lock.unlock()
    // A running import may be reading the staged keys.
    if importing {
      try? FileManager.default.removeItem(atPath: path)
      noteNandNotice(L("A NAND import is already running."))
      return
    }
    do {
      try FileManager.default.createDirectory(at: nandStagingRoot, withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: stagedKeysURL)
      try FileManager.default.moveItem(at: URL(fileURLWithPath: path), to: stagedKeysURL)
      noteNandNotice(L("Wii keys received. Now upload nand.bin."))
    } catch {
      try? FileManager.default.removeItem(atPath: path)
      noteNandNotice(L("The Wii NAND backup couldn't be imported. Check that it is a BootMii dump with its keys, then upload it again."))
    }
  }

  private func importNandBackup(atPath path: String, size: Int64) {
    let needsKeys = UploadKind.needsSeparateKeys(size: size)
    let hasKeys = FileManager.default.fileExists(atPath: stagedKeysURL.path)
    let emulating = isEmulationRunning()

    // Every refusal comes before the dump is staged and deletes the upload.
    lock.lock()
    let refusal: String? = nandImportInProgress ? L("A NAND import is already running.")
      : emulating ? L("A Wii NAND import can't start right now. Quit the game, then upload nand.bin again.")
      : needsKeys && !hasKeys ? L("This NAND backup has no keys. Upload keys.bin from the same backup first, then upload nand.bin again.")
      : nil
    if refusal == nil { nandImportInProgress = true }
    lock.unlock()
    if let refusal {
      try? FileManager.default.removeItem(atPath: path)
      noteNandNotice(refusal)
      return
    }

    // If it can't be moved out of the library it stays untouched and isn't imported in place.
    guard let staged = stageNandBackup(URL(fileURLWithPath: path)) else {
      lock.lock()
      nandImportInProgress = false
      lock.unlock()
      noteNandNotice(L("The Wii NAND backup couldn't be imported. Check that it is a BootMii dump with its keys, then upload it again."))
      return
    }

    noteNandNotice(L("Importing Wii NAND backup…"))
    nandImporter(staged, needsKeys ? stagedKeysURL : nil) { [weak self] success in
      self?.finishNandImport(success: success, staged: staged, usedKeys: needsKeys)
    }
  }

  /// Moves the backup into its own staging folder; nil if that fails.
  private func stageNandBackup(_ source: URL) -> URL? {
    let directory = nandStagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let destination = directory.appendingPathComponent(source.lastPathComponent)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: source, to: destination)
      return destination
    } catch {
      try? FileManager.default.removeItem(at: directory)
      return nil
    }
  }

  private func finishNandImport(success: Bool, staged: URL, usedKeys: Bool) {
    try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
    if success && usedKeys { try? FileManager.default.removeItem(at: stagedKeysURL) }
    lock.lock()
    nandImportInProgress = false
    lock.unlock()
    postSnackbar(success ? L("Wii NAND backup imported.")
                         : L("The Wii NAND backup couldn't be imported. Check that it is a BootMii dump with its keys, then upload it again."))
  }

  private func noteNandNotice(_ text: String) {
    lock.lock()
    nandNotices.append(text)
    lock.unlock()
  }

  private func postSnackbar(_ text: String) {
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: Notification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": text])
    }
  }

  /// Returns custom snackbar text when archives were extracted or rejected during a debounced
  /// upload burst.
  func consumeSummary(defaultUploadCount: Int) -> String? {
    lock.lock()
    let archives = archivesProcessed
    let games = gamesImported
    let rejected = rejectedArchives
    let nand = nandNotices
    nandNotices = []
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
    let lines = [extracted, rejectedText, failedText].compactMap { $0 } + nand
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }
}
