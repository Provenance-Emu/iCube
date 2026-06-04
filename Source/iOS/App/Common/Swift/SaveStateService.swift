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
    return SaveStateMetadataStore.write(metadata, forStateFile: stateURL)
  }

  /// A reasonable default label for an unlabeled save, e.g. "Slot 1 — Jun 3, 2026 at 4:12 PM".
  public static func defaultTitle(slot: Int, date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return "Slot \(slot) — \(formatter.string(from: date))"
  }
}
