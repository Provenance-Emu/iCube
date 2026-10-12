// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVSyncRules
#if canImport(CloudKit)
import CloudKit

/// CloudKit backend: private database, one custom zone, one record type.
///
/// Shape ported from iFly, with the failure handling rewritten.
///
/// - **Record name is the `User/`-relative path**, normalised through
///   `CanonicalRelativePath`. That makes the path an identity key, which is why
///   the normalisation is not optional — see `CanonicalRelativePath` for the
///   path-mangling bug it fixes.
/// - **`CKAsset` for every payload**, with no inline-versus-asset branching.
///   Inline data would be marginally cheaper for a 4 KB INI, but a second code
///   path is a second thing that can round-trip wrong, and the size threshold is
///   exactly the kind of constant that drifts.
/// - **Deletes travel as tombstones**: the same record with its asset removed
///   and `deleted = 1`, `deletedAt` set. Whether a tombstone is *applied* is
///   `SyncPlanner`'s decision; the provider only stores and reports them.
///   `purgeAllData` exists for the explicit "clear iCloud data" action.
public actor CloudKitSyncProvider: SyncProvider {

    public nonisolated let providerName = "iCloud"
    public nonisolated let kind: SyncProviderKind = .iCloud

    private let container: CKContainer
    private let database: CKDatabase
    private let zone: CKRecordZone
    private let deviceIdentifier: String
    private let retryPolicy: SyncRetryPolicy
    private var hasVerifiedZone = false

    /// Fails (returns nil) rather than trapping when this build cannot use
    /// CloudKit. Callers use `InertSyncProvider` in that case.
    public init?(
        containerIdentifier: String = CloudSyncConstants.containerIdentifier,
        deviceIdentifier: String,
        retryPolicy: SyncRetryPolicy = SyncRetryPolicy()
    ) {
        guard let container = CloudKitAvailability.makeContainer(identifier: containerIdentifier) else {
            return nil
        }
        self.container = container
        self.database = container.privateCloudDatabase
        self.zone = CKRecordZone(
            zoneID: CKRecordZone.ID(zoneName: CloudSyncConstants.zoneName, ownerName: CKCurrentUserDefaultName)
        )
        self.deviceIdentifier = deviceIdentifier
        self.retryPolicy = retryPolicy
    }

    // MARK: - Availability

    public func unavailableReason() async -> SyncUnavailableReason? {
        if let buildReason = CloudKitAvailability.buildLevelUnavailableReason() {
            return buildReason
        }
        do {
            return SyncUnavailableReason.forAccountStatus(try await container.accountStatus())
        } catch let error as CKError {
            return SyncUnavailableReason(ckError: error)
        } catch {
            return .unknown(error.localizedDescription)
        }
    }

    public func initialize() async throws {
        if let reason = await unavailableReason() {
            throw SyncProviderError.unavailable(reason)
        }
        try await createCustomZoneIfNeeded()
    }

    /// The signed-in user's record name: stable per iCloud account, opaque,
    /// and different for every account. The index is bound to it so a sign-out
    /// and sign-in never reads one account's deletions as the other's.
    public func accountIdentity() async -> String? {
        (try? await container.userRecordID())?.recordName
    }

    private func createCustomZoneIfNeeded() async throws {
        guard !hasVerifiedZone else { return }
        do {
            _ = try await database.recordZone(for: zone.zoneID)
            hasVerifiedZone = true
        } catch let error as CKError where error.code == .zoneNotFound {
            _ = try await database.save(zone)
            hasVerifiedZone = true
        }
    }

    // MARK: - Fetch

    public func fetchRemoteSnapshot() async throws -> RemoteSyncSnapshot {
        let records = try await withRetry { try await self.performFetchAllZoneRecords() }
        var snapshot = RemoteSyncSnapshot()
        for record in records {
            switch record {
            case .file(let metadata): snapshot.files.append(metadata)
            case .tombstone(let tombstone): snapshot.tombstones.append(tombstone)
            }
        }
        snapshot.files.sort { $0.lastModified > $1.lastModified }
        snapshot.tombstones.sort { $0.deletedAt > $1.deletedAt }
        return snapshot
    }

    /// Every record in the zone, via `CKFetchRecordZoneChangesOperation` with a
    /// nil change token.
    ///
    /// Not a `CKQuery`. A "fetch all" query is implemented on top of the
    /// `recordName` system-field index, and when that index is not marked
    /// Queryable the query throws "Field 'recordName' is not marked queryable".
    /// iFly shipped a version that swallowed that to `[]`, which made every local
    /// file look local-only and re-uploaded the whole library on every boot.
    /// Zone-change fetch needs no index at all. (The returned change token is
    /// discarded; a future delta sync can persist it.)
    private func performFetchAllZoneRecords() async throws -> [RemoteRecord] {
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        configuration.previousServerChangeToken = nil   // nil ⇒ full snapshot
        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zone.zoneID],
            configurationsByRecordZoneID: [zone.zoneID: configuration]
        )
        operation.fetchAllChanges = true   // follow `moreComing` automatically

        let collector = ZoneFetchCollector()

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.recordWasChangedBlock = { _, result in
                    if case .success(let record) = result,
                       let mapped = Self.remoteRecord(from: record) {
                        collector.append(mapped)
                    }
                }
                // A per-zone failure (the zone was deleted, say) surfaces here,
                // not necessarily on the overall result block.
                operation.recordZoneFetchResultBlock = { _, result in
                    if case .failure(let error) = result {
                        collector.setZoneError(error)
                    }
                }
                operation.fetchRecordZoneChangesResultBlock = { result in
                    switch result {
                    case .success:
                        if let zoneError = collector.zoneError() {
                            continuation.resume(throwing: zoneError)
                        } else {
                            continuation.resume()
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                database.add(operation)
            }
        } catch let error as CKError {
            // An absent zone is a genuine first run — the zone is created on the
            // first upload — so an empty remote is correct and local files should
            // upload. Any OTHER error must abort the sync: returning [] on a real
            // failure is how you get a blind re-upload of everything.
            if error.code == .zoneNotFound || error.code == .userDeletedZone {
                return []
            }
            throw error
        }

        return collector.records()
    }

    // MARK: - Transfer

    public func upload(metadata: SyncableFileMetadata, data: Data) async throws {
        try await withRetry { try await self.performUpload(metadata: metadata, data: data) }
    }

    /// Uploads are deliberately **not batched**. Several multi-megabyte
    /// `CKAsset`s in one `CKModifyRecordsOperation` runs into the per-request
    /// size limit, and a batch that fails takes every record in it down with it.
    /// One record per request costs round trips and buys predictable failure.
    private func performUpload(metadata: SyncableFileMetadata, data: Data) async throws {
        try await createCustomZoneIfNeeded()

        let recordID = CKRecord.ID(
            recordName: metadata.cloudKitRecordID ?? metadata.relativePath,
            zoneID: zone.zoneID
        )

        let record: CKRecord
        if let existing = try? await database.record(for: recordID) {
            record = existing
        } else {
            record = CKRecord(recordType: CloudSyncConstants.recordType, recordID: recordID)
        }

        // CKAsset needs a file on disk; it is read at save time, so the temp file
        // has to outlive the call.
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try data.write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        record[CloudSyncConstants.Field.fileName] = metadata.relativePath as CKRecordValue
        record[CloudSyncConstants.Field.fileData] = CKAsset(fileURL: temporaryURL)
        record[CloudSyncConstants.Field.lastModified] = metadata.lastModified as CKRecordValue
        record[CloudSyncConstants.Field.checksum] = metadata.checksum as CKRecordValue
        record[CloudSyncConstants.Field.fileType] = metadata.fileType.rawValue as CKRecordValue
        record[CloudSyncConstants.Field.fileSize] = metadata.fileSize as CKRecordValue
        record[CloudSyncConstants.Field.deviceIdentifier] = deviceIdentifier as CKRecordValue
        record[CloudSyncConstants.Field.appVersion] = Self.appVersion as CKRecordValue
        // An upload over a tombstone is an undelete: clear the markers.
        record[CloudSyncConstants.Field.deleted] = nil
        record[CloudSyncConstants.Field.deletedAt] = nil

        _ = try await database.save(record)
    }

    private nonisolated static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    // MARK: - Tombstones

    public func writeTombstone(_ tombstone: SyncTombstone) async throws {
        try await withRetry { try await self.performWriteTombstone(tombstone) }
    }

    /// Same record name, asset removed, markers set. Reusing the record (rather
    /// than deleting it and creating a sibling) keeps the identity key simple:
    /// one path, one record, live or dead.
    private func performWriteTombstone(_ tombstone: SyncTombstone) async throws {
        try await createCustomZoneIfNeeded()
        let recordID = CKRecord.ID(recordName: tombstone.relativePath, zoneID: zone.zoneID)
        let record: CKRecord
        if let existing = try? await database.record(for: recordID) {
            record = existing
        } else {
            record = CKRecord(recordType: CloudSyncConstants.recordType, recordID: recordID)
        }
        guard let fileType = SyncClassifier.classify(relativePath: tombstone.relativePath) else {
            throw SyncProviderError.invalidData
        }
        record[CloudSyncConstants.Field.fileName] = tombstone.relativePath as CKRecordValue
        record[CloudSyncConstants.Field.fileData] = nil
        record[CloudSyncConstants.Field.lastModified] = tombstone.deletedAt as CKRecordValue
        record[CloudSyncConstants.Field.checksum] = tombstone.checksum as CKRecordValue
        record[CloudSyncConstants.Field.fileType] = fileType.rawValue as CKRecordValue
        record[CloudSyncConstants.Field.fileSize] = Int64(0) as CKRecordValue
        record[CloudSyncConstants.Field.deviceIdentifier] = deviceIdentifier as CKRecordValue
        record[CloudSyncConstants.Field.appVersion] = Self.appVersion as CKRecordValue
        record[CloudSyncConstants.Field.deleted] = Int64(1) as CKRecordValue
        record[CloudSyncConstants.Field.deletedAt] = tombstone.deletedAt as CKRecordValue
        _ = try await database.save(record)
    }

    /// Any device may clear tombstones past retention; the planner treats a
    /// path with neither a record nor a tombstone as "upload if you have it".
    public func purgeExpiredTombstones(olderThan cutoff: Date) async throws {
        let snapshot = try await fetchRemoteSnapshot()
        let expired = snapshot.tombstones.filter { $0.deletedAt < cutoff }
        guard !expired.isEmpty else { return }
        let recordIDs = expired.map { CKRecord.ID(recordName: $0.relativePath, zoneID: zone.zoneID) }
        for start in stride(from: 0, to: recordIDs.count, by: Self.deleteBatchSize) {
            let batch = Array(recordIDs[start ..< min(start + Self.deleteBatchSize, recordIDs.count)])
            try await withRetry { try await self.performDelete(recordIDs: batch) }
        }
    }

    /// CloudKit's documented ceiling is 400 items per modify operation.
    private static let deleteBatchSize = 200

    public func download(metadata: SyncableFileMetadata) async throws -> Data {
        try await withRetry { try await self.performDownload(metadata: metadata) }
    }

    private func performDownload(metadata: SyncableFileMetadata) async throws -> Data {
        let recordName = metadata.cloudKitRecordID ?? metadata.relativePath
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zone.zoneID)
        let record = try await database.record(for: recordID)

        guard let asset = record[CloudSyncConstants.Field.fileData] as? CKAsset,
              let fileURL = asset.fileURL,
              let data = try? Data(contentsOf: fileURL) else {
            throw SyncProviderError.invalidData
        }
        return data
    }

    // MARK: - Purge

    /// Deletes every record in the zone. Batched, because deletes carry no
    /// assets and the batch limit, not the size limit, is what binds.
    public func purgeAllData() async throws {
        let snapshot = try await fetchRemoteSnapshot()
        let recordIDs = snapshot.files.map {
            CKRecord.ID(recordName: $0.cloudKitRecordID ?? $0.relativePath, zoneID: zone.zoneID)
        } + snapshot.tombstones.map {
            CKRecord.ID(recordName: $0.relativePath, zoneID: zone.zoneID)
        }
        guard !recordIDs.isEmpty else { return }

        for start in stride(from: 0, to: recordIDs.count, by: Self.deleteBatchSize) {
            let batch = Array(recordIDs[start ..< min(start + Self.deleteBatchSize, recordIDs.count)])
            try await withRetry { try await self.performDelete(recordIDs: batch) }
        }
    }

    /// One delete batch, with the `partialFailure` unwrapped.
    ///
    /// This is the case iFly has no handling for, because it never batches: a
    /// `CKModifyRecordsOperation` reports per-item failures as
    /// `CKError.partialFailure` with the real errors in
    /// `partialErrorsByItemID`. Treating the outer error as the whole story
    /// either hides a failure or abandons a batch that was mostly fine.
    /// `unknownItem` inside the batch is success — the record is already gone.
    private func performDelete(recordIDs: [CKRecord.ID]) async throws {
        do {
            _ = try await database.modifyRecords(saving: [], deleting: recordIDs)
        } catch let error as CKError where error.code == .partialFailure {
            guard let partial = error.partialErrorsByItemID else { throw error }
            let realFailures = partial.values.compactMap { $0 as? CKError }
                .filter { $0.code != .unknownItem }
            // Every failure was "already deleted" — that is the desired state.
            if realFailures.isEmpty { return }
            throw error
        }
    }

    // MARK: - Retry

    /// Retry wrapper driven by `SyncRetryPolicy`, which reads
    /// `CKErrorRetryAfterKey` (including from inside a `partialFailure`) and
    /// treats `requestRateLimited` as its own case. iFly does neither.
    private func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch let error as CKError {
                let facts = SyncRetryFacts(ckError: error)
                switch retryPolicy.decide(facts: facts, attempt: attempt) {
                case .giveUp:
                    throw mapped(error)
                case .retry(let afterSeconds):
                    try? await Task.sleep(nanoseconds: UInt64(afterSeconds * 1_000_000_000))
                    if Task.isCancelled { throw CancellationError() }
                    attempt += 1
                }
            }
        }
    }

    private func mapped(_ error: CKError) -> Error {
        switch error.code {
        case .notAuthenticated: return SyncProviderError.unavailable(.notSignedIn)
        case .quotaExceeded: return SyncProviderError.quotaExceeded
        case .networkUnavailable, .networkFailure:
            return SyncProviderError.unavailable(.networkUnavailable)
        case .unknownItem: return SyncProviderError.fileNotFound
        default: return SyncProviderError.uploadFailed(error.localizedDescription)
        }
    }

    // MARK: - Record mapping

    /// A remote record, live or dead.
    enum RemoteRecord: Equatable {
        case file(SyncableFileMetadata)
        case tombstone(SyncTombstone)
    }

    /// Pure record → model mapping. `nonisolated static` so it is safe to call
    /// from a CloudKit operation callback, which runs off the actor.
    nonisolated static func remoteRecord(from record: CKRecord) -> RemoteRecord? {
        if (record[CloudSyncConstants.Field.deleted] as? Int64 ?? 0) != 0 {
            return tombstone(from: record).map(RemoteRecord.tombstone)
        }
        return metadata(from: record).map(RemoteRecord.file)
    }

    nonisolated static func tombstone(from record: CKRecord) -> SyncTombstone? {
        guard let fileName = record[CloudSyncConstants.Field.fileName] as? String,
              let checksum = record[CloudSyncConstants.Field.checksum] as? String else {
            return nil
        }
        // A tombstone for a path we would never sync is noise.
        guard SyncClassifier.classify(relativePath: fileName) != nil else { return nil }
        let deletedAt = (record[CloudSyncConstants.Field.deletedAt] as? Date)
            ?? (record[CloudSyncConstants.Field.lastModified] as? Date)
            ?? record.modificationDate
            ?? Date()
        return SyncTombstone(
            relativePath: fileName,
            checksum: checksum,
            deletedAt: deletedAt,
            deviceIdentifier: record[CloudSyncConstants.Field.deviceIdentifier] as? String
        )
    }

    nonisolated static func metadata(from record: CKRecord) -> SyncableFileMetadata? {
        guard let fileName = record[CloudSyncConstants.Field.fileName] as? String,
              let lastModified = record[CloudSyncConstants.Field.lastModified] as? Date,
              let checksum = record[CloudSyncConstants.Field.checksum] as? String,
              let rawType = record[CloudSyncConstants.Field.fileType] as? String,
              let fileType = SyncableFileType(rawValue: rawType),
              let fileSize = record[CloudSyncConstants.Field.fileSize] as? Int64 else {
            return nil
        }
        // Re-classify on the way in. A record written by a future build, a
        // different app version, or anything that got into the container by
        // other means does not get to decide where a file lands on this device.
        // Classification only: policy is applied by the planner, so a record
        // from a device with different switches is still understood here.
        guard SyncClassifier.syncableType(relativePath: fileName, sizeBytes: fileSize) != nil else {
            return nil
        }

        return SyncableFileMetadata(
            relativePath: fileName,
            lastModified: lastModified,
            fileSize: fileSize,
            checksum: checksum,
            fileType: fileType,
            syncStatus: .synced,
            lastSyncDate: Date(),
            cloudKitRecordID: record.recordID.recordName,
            lastModifiedDeviceID: record[CloudSyncConstants.Field.deviceIdentifier] as? String
        )
    }
}

/// Lock-backed accumulator for `CKFetchRecordZoneChangesOperation` callbacks,
/// which run off the actor.
private final class ZoneFetchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CloudKitSyncProvider.RemoteRecord] = []
    private var error: Error?

    func append(_ item: CloudKitSyncProvider.RemoteRecord) {
        lock.lock(); defer { lock.unlock() }
        items.append(item)
    }

    func setZoneError(_ newError: Error) {
        lock.lock(); defer { lock.unlock() }
        error = newError
    }

    func records() -> [CloudKitSyncProvider.RemoteRecord] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    func zoneError() -> Error? {
        lock.lock(); defer { lock.unlock() }
        return error
    }
}
#endif
