// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Darwin
import Foundation
import UIKit

/// Staged, verified writes into the library folder.
///
/// Why: `copyItem` straight to the final filename is not atomic. iOS killing the app mid-copy
/// (memory pressure while a 1.4 GB image streams in, or a suspend in the background) leaves a
/// truncated file under the REAL name, which the library then lists as a valid game and the
/// title fails inside with "disc read error". Observed 2026-09-23 on an iPad mini 5: three images
/// at 47-75 % of their size, all stamped one minute after a memory-warning termination. Copies now
/// land in `<name>.importing` (not a library extension, so never listed), are size-checked
/// against the source, and are renamed into place only when complete. Leftover `.importing` files
/// from an interrupted run are swept on the next import and at launch.
@objc(DOLImportStaging)
public final class ImportStaging: NSObject {
  public static let stagingSuffix = ".importing"

  /// `.importing` paths being written by this process right now.
  private static let liveStagedPaths = LivePathSet()

  private final class LivePathSet {
    private let lock = NSLock()
    private var paths = Set<String>()

    func insert(_ path: String) { lock.lock(); paths.insert(path); lock.unlock() }
    func remove(_ path: String) { lock.lock(); paths.remove(path); lock.unlock() }
    func snapshot() -> Set<String> { lock.lock(); defer { lock.unlock() }; return paths }
  }

  private static func size(ofPath path: String) -> Int64? {
    (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
  }

  private static func commit(staged: String, to destination: String, expectedSize: Int64?) throws {
    let fm = FileManager.default
    do {
      if let expected = expectedSize, let got = size(ofPath: staged), got != expected {
        throw NSError(domain: "DOLImportStaging", code: 1, userInfo: [
          NSLocalizedDescriptionKey: "Incomplete copy: \(got) of \(expected) bytes"])
      }
      try fm.moveItem(atPath: staged, toPath: destination)
    } catch {
      try? fm.removeItem(atPath: staged)
      throw error
    }
  }

  /// Copy `source` to `destination` through a `.importing` sibling; the destination only ever
  /// appears complete. Throws (and leaves nothing behind) on any failure.
  @objc public static func stagedCopy(fromPath source: String, toPath destination: String) throws {
    let fm = FileManager.default
    let staged = destination + stagingSuffix
    liveStagedPaths.insert(staged)
    defer { liveStagedPaths.remove(staged) }
    try? fm.removeItem(atPath: staged)
    do {
      try fm.copyItem(atPath: source, toPath: staged)
    } catch {
      try? fm.removeItem(atPath: staged)
      throw error
    }
    try commit(staged: staged, to: destination, expectedSize: size(ofPath: source))
  }

  /// Move `source` to `destination` the same way. A same-volume move is a rename and completes
  /// instantly; a cross-volume move is a copy + delete underneath, so it gets the same staging.
  @objc public static func stagedMove(fromPath source: String, toPath destination: String) throws {
    let fm = FileManager.default
    let staged = destination + stagingSuffix
    liveStagedPaths.insert(staged)
    defer { liveStagedPaths.remove(staged) }
    try? fm.removeItem(atPath: staged)
    let expected = size(ofPath: source)
    do {
      try fm.moveItem(atPath: source, toPath: staged)
    } catch {
      try? fm.removeItem(atPath: staged)
      throw error
    }
    try commit(staged: staged, to: destination, expectedSize: expected)
  }

  // MARK: - Progress-reporting, cancellable copies (the iOS 26 continued-processing path)

  /// `stagedCopy` for an import tracked by `keepAlive`: bytes are reported as they land and the
  /// copy stops at the next step once the system asks (expiry or cancel from the system UI).
  /// With no tracking `keepAlive` this is exactly `stagedCopy(fromPath:toPath:)`. The staging
  /// rules are the same: `.importing` name, size check, rename; nothing is left behind on a stop.
  @objc public static func stagedCopy(fromPath source: String, toPath destination: String,
                                      keepAlive: ImportKeepAlive?, itemIndex: Int) throws {
    guard let keepAlive, keepAlive.tracksProgress else {
      try stagedCopy(fromPath: source, toPath: destination)
      return
    }
    try trackedCopy(fromPath: source, toPath: destination, keepAlive: keepAlive, itemIndex: itemIndex)
    keepAlive.finish(item: itemIndex)
  }

  /// `stagedMove` for a tracked import. A same-volume move is a rename, instant and with nothing
  /// to report. A cross-volume move is a tracked staged copy, and the source is removed only after
  /// the copy has been renamed into place.
  @objc public static func stagedMove(fromPath source: String, toPath destination: String,
                                      keepAlive: ImportKeepAlive?, itemIndex: Int) throws {
    guard let keepAlive, keepAlive.tracksProgress,
          !onSameVolume(source, (destination as NSString).deletingLastPathComponent) else {
      try stagedMove(fromPath: source, toPath: destination)
      keepAlive?.finish(item: itemIndex)
      return
    }
    try trackedCopy(fromPath: source, toPath: destination, keepAlive: keepAlive, itemIndex: itemIndex)
    do {
      try FileManager.default.removeItem(atPath: source)
    } catch {
      // The game is imported; a source we cannot delete is not a failed import.
      NSLog("[Import] copied but could not remove the source of a move: %@", error.localizedDescription)
    }
    keepAlive.finish(item: itemIndex)
  }

  static let stoppedErrorCode = 2

  /// Tests turn this off to force the data-copy path that reports progress (a clone makes no callbacks).
  nonisolated(unsafe) static var cloneEnabled = true

  private static func trackedCopy(fromPath source: String, toPath destination: String,
                                  keepAlive: ImportKeepAlive, itemIndex: Int) throws {
    let fm = FileManager.default
    let staged = destination + stagingSuffix
    liveStagedPaths.insert(staged)
    defer { liveStagedPaths.remove(staged) }
    try? fm.removeItem(atPath: staged)
    let expected = size(ofPath: source)
    do {
      try copyWithProgress(source: source, staged: staged, expectedBytes: expected,
                           onBytes: { keepAlive.report(item: itemIndex, copiedBytes: $0) },
                           isCancelled: { keepAlive.isCancelled })
    } catch {
      try? fm.removeItem(atPath: staged)
      throw error
    }
    try commit(staged: staged, to: destination, expectedSize: expected)
  }

  private static func onSameVolume(_ a: String, _ b: String) -> Bool {
    let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
    guard let va = try? URL(fileURLWithPath: a).resourceValues(forKeys: keys).volumeIdentifier,
          let vb = try? URL(fileURLWithPath: b).resourceValues(forKeys: keys).volumeIdentifier else { return false }
    return va.isEqual(vb)
  }

  private final class CopyContext {
    let onBytes: (Int64) -> Void
    let isCancelled: () -> Bool
    var wasStopped = false

    init(onBytes: @escaping (Int64) -> Void, isCancelled: @escaping () -> Bool) {
      self.onBytes = onBytes
      self.isCancelled = isCancelled
    }
  }

  /// `copyfile(3)` with `COPYFILE_CLONE`: an APFS clone where the volume allows it (a file already
  /// "On My iPhone" copies instantly, as it does with `copyItem`), a real copy with a progress
  /// callback otherwise. The callback returns `COPYFILE_QUIT` once cancellation is requested.
  private static func copyWithProgress(source: String, staged: String, expectedBytes: Int64?,
                                       onBytes: @escaping (Int64) -> Void,
                                       isCancelled: @escaping () -> Bool) throws {
    guard let state = copyfile_state_alloc() else { throw POSIXError(.ENOMEM) }
    defer { copyfile_state_free(state) }

    let context = CopyContext(onBytes: onBytes, isCancelled: isCancelled)
    let callback: copyfile_callback_t = { what, stage, state, _, _, rawContext in
      guard what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS,
            let rawContext = rawContext, let state = state else { return COPYFILE_CONTINUE }
      let context = Unmanaged<CopyContext>.fromOpaque(rawContext).takeUnretainedValue()
      var copied: off_t = 0
      copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
      context.onBytes(Int64(copied))
      if context.isCancelled() {
        context.wasStopped = true
        return COPYFILE_QUIT
      }
      return COPYFILE_CONTINUE
    }

    let result: Int32 = withExtendedLifetime(context) {
      copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
      copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())
      return copyfile(source, staged, state, copyfile_flags_t(cloneEnabled ? COPYFILE_CLONE : (COPYFILE_DATA | COPYFILE_EXCL)))
    }
    let failureErrno = errno
    if result != 0 {
      if context.wasStopped || isCancelled() {
        throw NSError(domain: "DOLImportStaging", code: stoppedErrorCode, userInfo: [
          NSLocalizedDescriptionKey: "The import was stopped."])
      }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(failureErrno))
    }
    // A clone makes no callbacks; report the whole file so progress is not left at zero.
    if let expectedBytes { onBytes(expectedBytes) }
  }

  /// Delete `.importing` leftovers from an interrupted import. Returns how many were removed.
  /// Files a copy in this process is writing right now are left alone: a batch can keep running in
  /// the background for minutes, and an import started when the user comes back sweeps first.
  @objc @discardableResult
  public static func removeStaleStagedImports(inFolder folder: String) -> Int {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: folder) else { return 0 }
    let live = liveStagedPaths.snapshot()
    var removed = 0
    for name in names where name.hasSuffix(stagingSuffix) {
      let path = (folder as NSString).appendingPathComponent(name)
      if live.contains(path) { continue }
      if (try? fm.removeItem(atPath: path)) != nil {
        removed += 1
      }
    }
    if removed > 0 {
      NSLog("[Import] removed %d interrupted import(s) from %@", removed, folder)
    }
    return removed
  }

  /// Keep the process alive while a long copy runs after the user leaves the app; without this a
  /// background suspend turns into exactly the truncated file this type exists to prevent.
  @objc public static func beginBackgroundTask() -> UIBackgroundTaskIdentifier {
    UIApplication.shared.beginBackgroundTask(withName: "iCube.import", expirationHandler: nil)
  }

  @objc public static func endBackgroundTask(_ task: UIBackgroundTaskIdentifier) {
    if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
  }
}

#if os(iOS)

/// Serializes archive extraction and file copies off the main thread.
private actor ArchiveImportService {
  static let shared = ArchiveImportService()

  struct Outcome {
    var importedGames = 0
    var skippedGames = 0
    var extractedArchives = 0
    var installedPackMessages: [String] = []
    var errors: [String] = []
    /// The system asked the import to stop (expiry or cancel from the system UI).
    var stopped = false
    /// Files never started because of that. Files already finished stay imported.
    var notStarted = 0
  }

  /// Performs disk I/O for picked files while security-scoped access is held.
  /// `keepAlive` reports progress per file, in the order of `files`.
  func importFiles(_ files: [URL], softwareFolder: String, keepAlive: ImportKeepAlive? = nil) -> Outcome {
    guard !files.isEmpty else { return Outcome() }

    let fm = FileManager.default
    var outcome = Outcome()

    for (index, url) in files.enumerated() {
      if keepAlive?.isCancelled == true {
        outcome.stopped = true
        outcome.notStarted = files.count - index
        break
      }
      let sourcePath = url.path

      if ImportableFileTypes.isArchiveFile(url) {
        // Picked files live outside the app container: read-only, never extract beside or delete.
        let result = ZipImportHelper.importPickedArchive(at: url, toFolder: softwareFolder)
        keepAlive?.finish(item: index)
        if let packMessage = result.installedPackMessage {
          outcome.installedPackMessages.append(packMessage)
        }
        if result.importedCount > 0 || result.skippedExistingCount > 0 {
          outcome.extractedArchives += 1
          outcome.importedGames += result.importedCount
          outcome.skippedGames += result.skippedExistingCount
        } else if let message = result.errorMessage {
          outcome.errors.append("\(url.lastPathComponent): \(message)")
        }
        continue
      }

      let destinationPath = (softwareFolder as NSString).appendingPathComponent(url.lastPathComponent)
      if fm.fileExists(atPath: destinationPath) {
        outcome.skippedGames += 1
        keepAlive?.finish(item: index)
        continue
      }

      do {
        try ImportStaging.stagedCopy(fromPath: sourcePath, toPath: destinationPath,
                                     keepAlive: keepAlive, itemIndex: index)
        LibraryAddedDateStore.record(path: destinationPath)
        outcome.importedGames += 1
      } catch {
        if keepAlive?.isCancelled == true {
          outcome.stopped = true
          outcome.notStarted = files.count - index
          break
        }
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
    let (patches, picked) = DiscPatchImportRouter.partition(urls as [URL])
    if !patches.isEmpty { Task { @MainActor in DiscPatchImportRouter.route(patches) } }
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
    ImportStaging.removeStaleStagedImports(inFolder: softwareFolder)
    let keepAlive = ImportKeepAlive.begin(items: files.map { url in
      let destination = (softwareFolder as NSString).appendingPathComponent(url.lastPathComponent)
      // Already-imported files are skipped: they add nothing to the bytes the task reports.
      let skipped = !ImportableFileTypes.isArchiveFile(url) && FileManager.default.fileExists(atPath: destination)
      return (url.lastPathComponent, skipped ? 0 : Self.fileSize(of: url))
    })
    let outcome = await Task.detached(priority: .userInitiated) {
      await ArchiveImportService.shared.importFiles(files, softwareFolder: softwareFolder, keepAlive: keepAlive)
    }.value
    keepAlive.end(outcome.stopped ? .stopped : (outcome.errors.isEmpty ? .completed : .failed))

    for url in accessedURLs {
      url.stopAccessingSecurityScopedResource()
    }
    hideWindow()

    for message in outcome.installedPackMessages {
      postSnackbar(message)
    }

    if outcome.extractedArchives > 0 {
      postSnackbar(ZipImportHelper.snackbarText(importedCount: outcome.importedGames,
                                               skippedCount: outcome.skippedGames,
                                               archivesProcessed: outcome.extractedArchives))
    } else if outcome.importedGames > 0 {
      postSnackbar(outcome.importedGames == 1 ? "Imported 1 game" : "Imported \(outcome.importedGames) games")
    } else if outcome.skippedGames > 0 {
      postSnackbar(outcome.skippedGames == 1 ? "1 file already imported" : "\(outcome.skippedGames) files already imported")
    }

    if outcome.stopped {
      let notStarted = outcome.notStarted
      postSnackbar(notStarted == 1 ? L("Import stopped. 1 file was not imported.")
                                   : String(format: L("Import stopped. %d files were not imported."), notStarted))
    }

    if !outcome.errors.isEmpty {
      let message = outcome.errors.prefix(3).joined(separator: "\n\n")
      let suffix = outcome.errors.count > 3 ? "\n\n…" : ""
      presentBatchAlert(title: DOLCoreLocalizedString("Import"),
                        message: message + suffix)
    }

    if outcome.importedGames > 0 || outcome.skippedGames > 0 || outcome.extractedArchives > 0 || !outcome.installedPackMessages.isEmpty {
      NotificationCenter.default.post(
        name: NSNotification.Name("DOLImportFileFinishedNotification"),
        object: self,
        userInfo: nil
      )
    }
  }

  private static func fileSize(of url: URL) -> Int64 {
    Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
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
