// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVSyncRules

/// A category of file a continuity transfer can carry.
///
/// Relationship to `PVSyncRules.SyncableFileType`
/// ---------------------------------------------
/// Every **user-data** case here is a one-to-one mirror of a `SyncableFileType`
/// case and delegates its ordering and its resume-requirement to it, so the
/// classification rules live in exactly one place — `SyncClassifier`.
///
/// The one case with no counterpart is `gameFile`, and its absence from
/// `SyncableFileType` is the point, not an oversight:
///
///   * `SyncClassifier` answers "may this file be uploaded to CloudKit or
///     offered as part of a sync payload?". A disc image must always answer
///     **no**; `romExtensions` rejects it explicitly and the doc comment on
///     `SyncClassifier` states the "no ROM ever leaves the device" guarantee
///     that WS-5 is built on. Adding a `gameFile` case there would punch a hole
///     straight through it.
///   * A continuity ROM transfer is a different act with a different
///     authorisation: one specific title, named by the user (handing off a game
///     they are playing, or a peer asking to copy one title from a browsed
///     library), approved per-peer, and never enumerated by a background
///     scanner. It is carried by an explicit descriptor the manifest builder
///     adds by hand, not by anything `classify` returns.
///
/// So: user data goes through `SyncClassifier`; the game file is added
/// deliberately, once, by whoever built the manifest. Nothing else may be.
public enum ContinuityFileKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// The disc image itself. Never produced by `SyncClassifier` — see above.
    case gameFile

    case saveState
    case resumeState
    case saveStateMetadata
    case saveStateThumbnail
    case gameCubeMemoryCard
    case wiiSave
    case config
    case gameSettings

    /// Lift a classified user-data file into a transfer kind.
    public init(_ syncableType: SyncableFileType) {
        switch syncableType {
        case .saveState: self = .saveState
        case .resumeState: self = .resumeState
        case .saveStateMetadata: self = .saveStateMetadata
        case .saveStateThumbnail: self = .saveStateThumbnail
        case .gameCubeMemoryCard: self = .gameCubeMemoryCard
        case .wiiSave: self = .wiiSave
        case .config: self = .config
        case .gameSettings: self = .gameSettings
        }
    }

    /// The sync category this kind corresponds to, or nil for `gameFile`
    /// (which is deliberately not a syncable type).
    public var syncableType: SyncableFileType? {
        switch self {
        case .gameFile: return nil
        case .saveState: return .saveState
        case .resumeState: return .resumeState
        case .saveStateMetadata: return .saveStateMetadata
        case .saveStateThumbnail: return .saveStateThumbnail
        case .gameCubeMemoryCard: return .gameCubeMemoryCard
        case .wiiSave: return .wiiSave
        case .config: return .config
        case .gameSettings: return .gameSettings
        }
    }

    /// Download ordering: lower sorts earlier. Delegates to
    /// `SyncableFileType.pullPriority` so the "smallest and most essential
    /// first" policy is stated once; the disc image sorts dead last because it
    /// is orders of magnitude the largest thing in any payload and a transfer
    /// that dies before it still leaves a usable set of saves behind.
    public var pullPriority: Int {
        guard let syncableType else { return Int.max }
        return syncableType.pullPriority
    }

    /// Whether the receiving device needs this category to resume at the
    /// handed-off point. The disc image is required to boot *at all*, which the
    /// fallback machine tracks separately as `requiredGameFilesComplete` — this
    /// flag is specifically about resuming rather than booting.
    public var isRequiredToResume: Bool {
        syncableType?.isRequiredToResume ?? false
    }
}
