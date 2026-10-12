// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVSyncRules

/// One thing the sync engine has decided to do about one file.
public enum SyncPlanStep: Sendable, Equatable {
    /// Present locally, absent or older remotely.
    case upload(SyncableFileMetadata, reason: UploadReason)
    /// Present remotely, absent or older locally.
    case download(SyncableFileMetadata)
    /// Both sides agree — record it as synced and move on.
    case markSynced(SyncableFileMetadata)
    /// Both sides changed and the resolver refused to guess, or another device
    /// deleted a file this one changed.
    case conflict(SyncConflict)
    /// A merged document differs on the two sides: merge, write, upload.
    case merge(local: SyncableFileMetadata, remote: SyncableFileMetadata)
    /// The user deleted this file here since the last sync, and the remote copy
    /// is the version they deleted: tell the other devices.
    case writeTombstone(SyncTombstone)
    /// Another device deleted this file and the local copy is the version that
    /// was deleted: move it to the trash.
    case trashLocal(SyncableFileMetadata, tombstone: SyncTombstone)
    /// The file is gone on both sides; just remember that in the index.
    case markDeleted(relativePath: String)
    /// The user deleted this file here, but another device changed it after
    /// the version that was deleted. Download it back rather than delete the
    /// other device's work, and say so in the log.
    case restore(SyncableFileMetadata)

    public enum UploadReason: String, Sendable {
        case localOnly
        case contentChanged
        case conflictKeepLocal
        /// The file was deleted elsewhere but changed here afterwards, or the
        /// user restored it from the trash. The upload replaces the tombstone.
        case undelete
    }
}

/// Turns a local snapshot, a remote snapshot and this device's index into a
/// list of steps.
///
/// Pure and synchronous: no filesystem, no network, no actor. This is the half
/// of the sync engine worth testing exhaustively, and keeping it separate from
/// the I/O is what makes that possible.
///
/// Deletes propagate through tombstones, with safety rails. A peer deletes its
/// copy only when the bytes it holds are the bytes that were deleted, and a
/// local change made after the delete wins over the delete. The full table is
/// in the design spec, section 6; the tests walk it row by row.
///
/// Without an index (fresh install, purged cache) the planner behaves
/// additively: it never emits a tombstone it cannot justify.
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

    /// Additive plan with no index and the default policy. Kept for callers and
    /// tests that only care about the two-sided rules.
    public func plan(
        local: [SyncableFileMetadata],
        remote: [SyncableFileMetadata]
    ) -> [SyncPlanStep] {
        plan(local: local, remote: RemoteSyncSnapshot(files: remote), index: .empty, policy: .default)
    }

    public func plan(
        local: [SyncableFileMetadata],
        remote: RemoteSyncSnapshot,
        index: SyncIndexSnapshot,
        policy: SyncPolicy,
        now: Date = Date(),
        deviceIdentifier: String? = nil
    ) -> [SyncPlanStep] {
        // Policy filters both sides: a category the user has off is invisible,
        // in both directions. A remote channel does not download onto a device
        // whose channels switch is off.
        let localAllowed = local.filter { policy.allows($0.fileType) }
        let remoteAllowed = remote.files.filter { policy.allows($0.fileType) }
        let tombstonesAllowed = remote.tombstones.filter {
            SyncClassifier.classify(relativePath: $0.relativePath).map(policy.allows) ?? false
        }

        // Keep the first entry on a duplicate path so a malformed remote set
        // cannot make the plan nondeterministic.
        let localByPath = Dictionary(localAllowed.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteByPath = Dictionary(remoteAllowed.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        // A live record and a tombstone for the same name cannot coexist in
        // CloudKit; for a backend where they can, the live record wins.
        let tombstoneByPath = Dictionary(
            tombstonesAllowed.filter { remoteByPath[$0.relativePath] == nil }.map { ($0.relativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var steps: [SyncPlanStep] = []

        // Stable ordering: the caller executes these in sequence and a test that
        // depends on dictionary iteration order is a flaky test.
        for path in localByPath.keys.sorted() {
            guard let localMeta = localByPath[path] else { continue }

            if let remoteMeta = remoteByPath[path] {
                steps.append(reconcile(local: localMeta, remote: remoteMeta))
                continue
            }

            if let tombstone = tombstoneByPath[path] {
                steps.append(reconcile(local: localMeta, tombstone: tombstone, now: now))
                continue
            }

            // Absent remotely. Whether or not the index knows the path, the
            // answer is the same: the remote lacks a file we have. (An index
            // entry here means the record vanished without a tombstone — a
            // purge, an expired tombstone or a zone reset — and re-uploading
            // is the only safe reading of that.)
            steps.append(.upload(localMeta, reason: .localOnly))
        }

        // Files that exist only remotely come last. Files present on both sides
        // are handled in the loop above, in path order, so a download for one of
        // those can still precede an upload — the guarantee is only that a
        // purely-new local file is never queued behind a purely-new remote one.
        for path in remoteByPath.keys.sorted() where localByPath[path] == nil {
            guard let remoteMeta = remoteByPath[path] else { continue }
            steps.append(reconcileRemoteOnly(remoteMeta, index: index[path], now: now, deviceIdentifier: deviceIdentifier))
        }

        // Tombstones for paths we do not have: nothing to delete, but remember
        // the path is gone so a later purge-and-reupload is read correctly.
        for path in tombstoneByPath.keys.sorted() where localByPath[path] == nil {
            if let entry = index[path], entry.isLive {
                steps.append(.markDeleted(relativePath: path))
            }
        }

        return steps
    }

    // MARK: - Both sides present

    private func reconcile(local localMeta: SyncableFileMetadata, remote remoteMeta: SyncableFileMetadata) -> SyncPlanStep {
        // Identical bytes never need transferring, whatever the mtimes say.
        // This is what stops a file whose mtime was bumped without a content
        // change from re-uploading on every launch.
        if !localMeta.checksum.isEmpty, localMeta.checksum == remoteMeta.checksum {
            return .markSynced(localMeta)
        }

        // Merged documents never pick a winner.
        if localMeta.fileType.mergeKind == .document {
            return .merge(local: localMeta, remote: remoteMeta)
        }

        // A previously-synced file reads back with a near-matching mtime
        // because the download path stamps the source mtime onto the file.
        let timeDifference = abs(localMeta.lastModified.timeIntervalSince(remoteMeta.lastModified))
        if timeDifference <= modificationTimeTolerance {
            return .markSynced(localMeta)
        }

        switch resolver.resolve(local: localMeta, remote: remoteMeta) {
        case .useLocal:
            return .upload(localMeta, reason: .contentChanged)
        case .useRemote:
            return .download(remoteMeta)
        case .manual(let conflict):
            return .conflict(conflict)
        case .keepBoth:
            return .conflict(SyncConflict(local: localMeta, remote: remoteMeta))
        }
    }

    // MARK: - Local file, remote tombstone

    private func reconcile(local localMeta: SyncableFileMetadata, tombstone: SyncTombstone, now: Date) -> SyncPlanStep {
        // Merged documents are never deleted; a tombstone for one is noise.
        guard localMeta.fileType.propagatesDeletes else {
            return .upload(localMeta, reason: .undelete)
        }

        // Changed (or restored) here after the delete happened elsewhere: the
        // user's later action wins and the upload replaces the tombstone.
        if localMeta.lastModified > tombstone.deletedAt.addingTimeInterval(modificationTimeTolerance) {
            return .upload(localMeta, reason: .undelete)
        }

        // Exactly the bytes that were deleted: apply the delete, via the trash.
        if !tombstone.checksum.isEmpty, localMeta.checksum == tombstone.checksum {
            return .trashLocal(localMeta, tombstone: tombstone)
        }

        // Older than the delete but different bytes: the deleting device never
        // saw this version. Only the user can call it.
        return .conflict(SyncConflict(local: localMeta, tombstone: tombstone))
    }

    // MARK: - Remote file, nothing local

    private func reconcileRemoteOnly(
        _ remoteMeta: SyncableFileMetadata,
        index entry: SyncIndexEntry?,
        now: Date,
        deviceIdentifier: String?
    ) -> SyncPlanStep {
        // Never had it, or already processed its deletion and it came back:
        // it is new to us.
        guard let entry, entry.isLive else {
            return .download(remoteMeta)
        }

        // We synced it and it is gone locally: the user deleted it here.
        guard remoteMeta.fileType.propagatesDeletes else {
            // A merged document deleted locally is simply fetched again.
            return .download(remoteMeta)
        }

        if !entry.checksum.isEmpty, remoteMeta.checksum == entry.checksum {
            return .writeTombstone(SyncTombstone(
                relativePath: remoteMeta.relativePath,
                checksum: remoteMeta.checksum,
                deletedAt: now,
                deviceIdentifier: deviceIdentifier
            ))
        }

        // The remote changed after we last synced it, and we deleted our older
        // copy. Deleting the other device's newer work is not a trade the user
        // agreed to; bring it back and say so.
        return .restore(remoteMeta)
    }
}
