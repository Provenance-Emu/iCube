// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Rich metadata for a save state, persisted as a JSON sidecar next to the
/// state file (e.g. `GALE01.s01.json`). Non-breaking by design: the state
/// binary is untouched and STATE_VERSION is not bumped.
/// See `docs/icube/save-management-adr.md`.
public struct SaveStateMetadata: Codable, Hashable {
  /// Bump when the sidecar shape changes; readers tolerate older versions.
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  /// User-editable label. Defaults to a timestamped name on first save.
  public var title: String
  /// Dolphin game ID (e.g. `GALE01`), authoritative from the core.
  public var gameID: String
  /// Human-readable game title, when the frontend has it.
  public var gameTitle: String?
  /// When this state was written.
  public var savedAt: Date
  /// SCM revision of the build that wrote the state, for compatibility display.
  public var scmRevision: String?
  /// Optional in-game play-time context, when available.
  public var playTimeSeconds: Double?
  /// True for the dedicated "resume where I left off" auto-save (`{GameID}.auto`).
  public var isAuto: Bool

  public init(title: String,
              gameID: String,
              gameTitle: String? = nil,
              savedAt: Date = Date(),
              scmRevision: String? = nil,
              playTimeSeconds: Double? = nil,
              isAuto: Bool = false,
              schemaVersion: Int = SaveStateMetadata.currentSchemaVersion) {
    self.schemaVersion = schemaVersion
    self.title = title
    self.gameID = gameID
    self.gameTitle = gameTitle
    self.savedAt = savedAt
    self.scmRevision = scmRevision
    self.playTimeSeconds = playTimeSeconds
    self.isAuto = isAuto
  }
}
