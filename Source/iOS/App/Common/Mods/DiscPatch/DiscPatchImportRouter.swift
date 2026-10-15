// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Sends patch files that arrive through the normal import paths (Files picker, drag and drop, web
/// upload) to the disc patching flow instead of the game library.
enum DiscPatchImportRouter {
  /// How long uploads are collected before the sheet opens, so a burst of uploads opens it once.
  private static let uploadDebounce: TimeInterval = 1.5

  /// Splits the patch files off `urls`.
  static func partition(_ urls: [URL]) -> (patches: [URL], others: [URL]) {
    (urls.filter(DiscPatchPlanner.isPatchFile), urls.filter { !DiscPatchPlanner.isPatchFile($0) })
  }

  /// Stores `patches` in `<User>/Patches/` and asks which game they are for.
  @MainActor
  static func route(_ patches: [URL]) {
    guard let directories = DiscPatchDirectories.live else { return }
    var stored: [URL] = []
    var failures: [String] = []
    for patch in patches {
      do { stored.append(try DiscPatchStore.importPatch(from: patch, directories: directories)) } catch {
        failures.append("\(patch.lastPathComponent): \(error.localizedDescription)")
      }
    }
    if !failures.isEmpty {
      snackbar(String(format: L("Couldn't import a patch: %@"), failures.joined(separator: "\n")))
    }
    guard !stored.isEmpty else { return }
    open(stored)
  }

  private static let pendingLock = NSLock()
  private static var pendingUploads: [URL] = []

  /// A patch the web server wrote into the library folder: moved to `Patches/`, then offered once the
  /// uploads stop arriving. Returns false when `path` is not a patch (or cannot be moved) so the caller
  /// handles it as a normal upload.
  @discardableResult
  static func adoptUpload(atPath path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard DiscPatchPlanner.isPatchFile(url), let directories = DiscPatchDirectories.live,
          let stored = try? DiscPatchStore.adoptUpload(at: url, directories: directories) else { return false }
    pendingLock.lock()
    pendingUploads.append(stored)
    pendingLock.unlock()
    DispatchQueue.main.asyncAfter(deadline: .now() + uploadDebounce) { flushUploads() }
    return true
  }

  private static func flushUploads() {
    pendingLock.lock()
    let batch = pendingUploads
    pendingUploads = []
    pendingLock.unlock()
    if !batch.isEmpty { open(batch) }
  }

  /// A running game owns the screen and the controllers, so the sheet waits for the library: the patch
  /// is already stored and "Apply Patch…" finds it there.
  private static func open(_ patches: [URL]) {
    if TVEmulationBridge.isRunning() {
      snackbar(L("Patch saved. Choose Apply Patch… from a game's menu to use it."))
    } else {
      Task { @MainActor in DiscPatchFlow.present(patchURLs: patches, suggestedGameID: nil) }
    }
  }

  private static func snackbar(_ text: String) {
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": text])
    }
  }
}
