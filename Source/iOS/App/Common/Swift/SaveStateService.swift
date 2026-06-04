// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Facade over the save-state bridge that writes a metadata sidecar alongside
/// every save, so saves are self-describing (title, timestamp, game).
///
/// Call sites should prefer this over calling `TVEmulationBridge.saveState`
/// directly. The save-manager UI phase migrates the existing in-game Save
/// buttons onto these entry points.
public enum SaveStateService {
  /// Game ID of the running title (authoritative, from the core), or nil when
  /// nothing is running.
  public static var currentGameID: String? {
    let gid = TVEmulationBridge.currentGameID()
    return gid.isEmpty ? nil : gid
  }

  /// Save to a numbered slot and write/refresh its metadata sidecar.
  ///
  /// `wait` blocks until the state file has been written so the sidecar is
  /// consistent with the file on disk. Returns false if the path could not be
  /// resolved (no game running) — the state save itself is still attempted.
  @discardableResult
  public static func saveSlot(_ slot: Int,
                              title: String? = nil,
                              gameTitle: String? = nil,
                              wait: Bool = true) -> Bool {
    TVEmulationBridge.saveState(toSlot: slot, wait: wait)

    guard let path = TVEmulationBridge.stateFilePath(forSlot: slot) else { return false }
    let stateURL = URL(fileURLWithPath: path)
    let now = Date()
    let metadata = SaveStateMetadata(
      title: title ?? defaultTitle(slot: slot, date: now),
      gameID: currentGameID ?? "UNKNOWN",
      gameTitle: gameTitle,
      savedAt: now,
      isAuto: false
    )
    let ok = SaveStateMetadataStore.write(metadata, forStateFile: stateURL)
    captureThumbnail(forStateFile: stateURL)
    return ok
  }

  // MARK: - Thumbnails

  /// Stable scratch path for the "last frame before the pause menu opened" preview.
  public static var pausePreviewURL: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("icube_pause_preview.png")
  }

  /// Grab the current frame into the pause preview. Call this as the pause menu
  /// opens, while frames are still in flight — so a save made while paused still
  /// has a thumbnail (the live capture below can't fire once presenting stops).
  public static func capturePausePreview() {
    TVEmulationBridge.captureScreenshot(toPath: pausePreviewURL.path)
  }

  /// Produce a thumbnail next to the state file. Adopts the fresh pause preview
  /// (covers saves made while paused), then requests a live capture that overwrites
  /// it with the current frame when emulation is still running. Both are best-effort;
  /// a missing thumbnail degrades to a placeholder in the UI.
  private static func captureThumbnail(forStateFile stateURL: URL) {
    let thumbURL = stateURL.appendingPathExtension("png")
    adoptPausePreviewIfFresh(into: thumbURL)
    TVEmulationBridge.captureScreenshot(toPath: thumbURL.path)
  }

  private static func adoptPausePreviewIfFresh(into thumbURL: URL) {
    let fm = FileManager.default
    let preview = pausePreviewURL
    guard let attrs = try? fm.attributesOfItem(atPath: preview.path),
          let modified = attrs[.modificationDate] as? Date,
          Date().timeIntervalSince(modified) < 60 else { return }
    try? fm.removeItem(at: thumbURL)
    try? fm.copyItem(at: preview, to: thumbURL)
  }

  /// A reasonable default label for an unlabeled save, e.g. "Slot 1 — Jun 3, 2026 at 4:12 PM".
  public static func defaultTitle(slot: Int, date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return "Slot \(slot) — \(formatter.string(from: date))"
  }

  // MARK: - Resume where I left off

  /// NSUserDefault key for the "resume where I left off" toggle. Kept as a default
  /// (not a Dolphin Config key) because it is pure frontend behavior — the core
  /// never reads it, so a Config key would be flagged dangling by icube_config_lint.
  public static let resumeDefaultsKey = "resume_where_left_off"

  public static var resumeEnabled: Bool {
    UserDefaults.standard.bool(forKey: resumeDefaultsKey)
  }

  /// Path to the running title's dedicated auto-state, or nil if nothing is running.
  public static var autoStateURL: URL? {
    guard let path = TVEmulationBridge.autoStateFilePath() else { return nil }
    return URL(fileURLWithPath: path)
  }

  /// True when a resume auto-state exists on disk for the running title.
  public static var hasAutoState: Bool {
    guard let url = autoStateURL else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }

  /// If resume is enabled and an auto-state exists for the running title, load it.
  /// Returns true if a load was issued. Safe to call right after the game boots.
  /// (The save side runs in TVEmulationBridge.stop so every quit path is covered.)
  @discardableResult
  public static func resumeIfAvailable() -> Bool {
    guard resumeEnabled, let url = autoStateURL,
          FileManager.default.fileExists(atPath: url.path) else { return false }
    TVEmulationBridge.loadState(fromPath: url.path)
    return true
  }
}
