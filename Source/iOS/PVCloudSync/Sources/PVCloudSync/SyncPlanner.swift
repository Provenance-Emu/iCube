// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One thing the sync engine has decided to do about one file.
public enum SyncPlanStep: Sendable, Equatable {
    /// Present locally, absent remotely.
    case upload(SyncableFileMetadata, reason: UploadReason)
    /// Present remotely, absent locally.
    case download(SyncableFileMetadata)
    /// Both sides agree — record it as synced and move on.
    case markSynced(SyncableFileMetadata)
    /// Both sides changed and the resolver refused to guess.
    case conflict(SyncConflict)

    public enum UploadReason: String, Sendable {
        case localOnly
        case contentChanged
        case conflictKeepLocal
    }
}

/// Turns a local snapshot and a remote snapshot into a list of steps.
///
/// Pure and synchronous: no filesystem, no network. This is the half of the sync
/// engine worth testing exhaustively, and keeping it separate from the I/O is
/// what makes that possible.
///
/// **Deletions are never propagated.** The merge is an additive union: a file on
/// only one side is copied to the other, never removed from the side that has
/// it. That means a fresh device with an empty cloud can never wipe local saves,
/// and deleting a save state on one device will not delete it elsewhere — it
/// will come back on the next sync. That is the deliberate trade: re-appearing
/// saves are an annoyance, silently destroyed saves are not recoverable.
public struct SyncPlanner: Sendable {

    private let resolver: any ConflictResolver
    /// Mtimes within this many seconds count as the same version.
    private let modificationTimeTolerance: TimeInterval

    public init(
        resolver: any ConflictResolver = TimestampConflictResolver(),
        modificationTimeTolerance: TimeInterval = CloudSyncConstants.modificationTimeTolerance
    ) {
        self.resolver = resolver
        self.modificationTimeTolerance = modificationTimeTolerance
    }

    public func plan(
        local: [SyncableFileMetadata],
        remote: [SyncableFileMetadata]
    ) -> [SyncPlanStep] {
        // Keep the first entry on a duplicate path so a malformed remote set
        // cannot make the plan nondeterministic.
        let localByPath = Dictionary(local.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteByPath = Dictionary(remote.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })

        var steps: [SyncPlanStep] = []

        // Stable ordering: the caller executes these in sequence and a test that
        // depends on dictionary iteration order is a flaky test.
        for path in localByPath.keys.sorted() {
            guard let localMeta = localByPath[path] else { continue }

            guard let remoteMeta = remoteByPath[path] else {
                steps.append(.upload(localMeta, reason: .localOnly))
                continue
            }

            // Identical bytes never need transferring, whatever the mtimes say.
            // This is what stops a file whose mtime was bumped without a content
            // change from re-uploading on every launch.
            if !localMeta.checksum.isEmpty, localMeta.checksum == remoteMeta.checksum {
                steps.append(.markSynced(localMeta))
                continue
            }

            // A previously-synced file reads back with a near-matching mtime
            // because the download path stamps the source mtime onto the file.
            let timeDifference = abs(localMeta.lastModified.timeIntervalSince(remoteMeta.lastModified))
            if timeDifference <= modificationTimeTolerance {
                steps.append(.markSynced(localMeta))
                continue
            }

            switch resolver.resolve(local: localMeta, remote: remoteMeta) {
            case .useLocal:
                steps.append(.upload(localMeta, reason: .contentChanged))
            case .useRemote:
                steps.append(.download(remoteMeta))
            case .manual(let conflict):
                steps.append(.conflict(conflict))
            case .keepBoth:
                steps.append(.conflict(SyncConflict(local: localMeta, remote: remoteMeta)))
            }
        }

        // Files that exist only remotely come last. Files present on both sides
        // are handled in the loop above, in path order, so a download for one of
        // those can still precede an upload — the guarantee is only that a
        // purely-new local file is never queued behind a purely-new remote one.
        for path in remoteByPath.keys.sorted() where localByPath[path] == nil {
            guard let remoteMeta = remoteByPath[path] else { continue }
            steps.append(.download(remoteMeta))
        }

        return steps
    }
}
