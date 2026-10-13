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
  /// NAND import notices for the next upload summary (started, or refused).
  private var nandNotices: [String] = []
  private var nandImportInProgress = false

  /// Where a NAND backup waits while it imports. Outside the library folder, so the rescan that follows an
  /// upload never lists a 528 MB `nand.bin` as a game.
  var nandStagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("NANDImport", isDirectory: true)
  /// The NAND is in use while a game runs.
  var isEmulationRunning: () -> Bool = { TVEmulationBridge.isRunning() }
  /// Runs the importer; the default hops to the main thread because it presents the progress alert.
  var nandImporter: (_ url: URL, _ completion: @escaping (_ success: Bool) -> Void) -> Void = { url, completion in
    DispatchQueue.main.async { NANDImportManager.importNAND(from: url, completion: completion) }
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
    if handleNandBackup(atPath: path) { return }

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

  /// Routes a BootMii NAND backup to the NAND importer instead of the library. Anything else named `nand.bin`
  /// (wrong size, a renamed disc image) returns false and takes the normal upload handling untouched.
  ///
  /// The backup is moved out of the library folder first, then imported from there. After a good import the
  /// copy is deleted (it is already in the NAND, and tvOS has little storage). After a bad one, or when the
  /// import is refused, it is kept for the next upload to replace.
  private func handleNandBackup(atPath path: String) -> Bool {
    let fileManager = FileManager.default
    let size = ((try? fileManager.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
    guard UploadKind.classify(fileName: (path as NSString).lastPathComponent, size: size) == .nandBackup else {
      return false
    }

    lock.lock()
    let busy = nandImportInProgress || isEmulationRunning()
    if !busy { nandImportInProgress = true }
    lock.unlock()

    // A refused upload must not wipe the folder: a running import reads from it.
    if !busy { try? fileManager.removeItem(at: nandStagingRoot) }
    let source = URL(fileURLWithPath: path)
    let staged = stageNandBackup(source)
    guard !busy else {
      noteNandNotice(L("A Wii NAND import can't start right now. Quit the game, then upload nand.bin again."))
      return true
    }

    noteNandNotice(L("Importing Wii NAND backup…"))
    nandImporter(staged ?? source) { [weak self] success in
      self?.finishNandImport(success: success, staged: staged, source: source)
    }
    return true
  }

  /// Moves the backup into its own staging folder; nil leaves it where it is (imported from there instead).
  private func stageNandBackup(_ source: URL) -> URL? {
    let directory = nandStagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let destination = directory.appendingPathComponent(source.lastPathComponent)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try FileManager.default.moveItem(at: source, to: destination)
      return destination
    } catch {
      return nil
    }
  }

  private func finishNandImport(success: Bool, staged: URL?, source: URL) {
    if success {
      try? FileManager.default.removeItem(at: staged?.deletingLastPathComponent() ?? source)
    }
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
