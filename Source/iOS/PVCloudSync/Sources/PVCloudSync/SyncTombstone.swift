// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A record that a file was deleted on some device.
///
/// A tombstone keeps the file's record name and the checksum of the content
/// that was deleted. The checksum is what makes a remote delete safe to apply:
/// a peer removes its copy only when the bytes it holds are the bytes that were
/// deleted. Anything else is a change the deleting device never saw, and that
/// becomes a conflict for the user rather than a silent delete.
public struct SyncTombstone: Codable, Hashable, Sendable, Identifiable {
    public var id: String { relativePath }

    /// Path relative to the `User/` directory; the record name.
    public let relativePath: String
    /// SHA-256 of the content that was deleted, lowercase hex. Empty when the
    /// deleting device did not know it (should not happen; treated as "never
    /// matches", so such a tombstone can only ever produce a conflict).
    public let checksum: String
    public let deletedAt: Date
    /// Which device deleted it. Display only.
    public let deviceIdentifier: String?

    public init(relativePath: String, checksum: String, deletedAt: Date, deviceIdentifier: String? = nil) {
        self.relativePath = relativePath
        self.checksum = checksum
        self.deletedAt = deletedAt
        self.deviceIdentifier = deviceIdentifier
    }

    /// Whether a tombstone this old should be removed from the remote. A device
    /// offline longer than this re-uploads the file, which is the resurrection
    /// the old additive-only engine always had, now confined to a rare case.
    public func isExpired(asOf now: Date, retention: TimeInterval = CloudSyncConstants.tombstoneRetention) -> Bool {
        now.timeIntervalSince(deletedAt) > retention
    }
}

/// Everything a provider knows about the remote side, in one fetch.
///
/// `cursor` is opaque and provider-specific: a CloudKit change token, the
/// content server's change-feed cursor, or nil for a provider that only does
/// full snapshots. The engine stores it and hands it back; it never inspects it.
public struct RemoteSyncSnapshot: Sendable, Equatable {
    public var files: [SyncableFileMetadata]
    public var tombstones: [SyncTombstone]
    public var cursor: String?

    public init(files: [SyncableFileMetadata] = [], tombstones: [SyncTombstone] = [], cursor: String? = nil) {
        self.files = files
        self.tombstones = tombstones
        self.cursor = cursor
    }

    public static let empty = RemoteSyncSnapshot()
}
