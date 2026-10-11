// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if canImport(CloudKit)
import CloudKit
import XCTest
import PVSyncRules
@testable import PVCloudSync

/// Record ↔ model mapping. `CKRecord` can be built offline, so this needs no
/// container and no account.
final class CloudKitRecordMappingTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(
        _ path: String,
        type: SyncableFileType = .saveState,
        size: Int64 = 1024,
        deleted: Bool = false
    ) -> CKRecord {
        let record = CKRecord(recordType: CloudSyncConstants.recordType, recordID: CKRecord.ID(recordName: path))
        record[CloudSyncConstants.Field.fileName] = path as CKRecordValue
        record[CloudSyncConstants.Field.lastModified] = epoch as CKRecordValue
        record[CloudSyncConstants.Field.checksum] = "abc" as CKRecordValue
        record[CloudSyncConstants.Field.fileType] = type.rawValue as CKRecordValue
        record[CloudSyncConstants.Field.fileSize] = size as CKRecordValue
        record[CloudSyncConstants.Field.deviceIdentifier] = "dev" as CKRecordValue
        if deleted {
            record[CloudSyncConstants.Field.deleted] = Int64(1) as CKRecordValue
            record[CloudSyncConstants.Field.deletedAt] = epoch.addingTimeInterval(60) as CKRecordValue
        }
        return record
    }

    func testLiveRecordMapsToMetadata() {
        guard case .file(let meta)? = CloudKitSyncProvider.remoteRecord(from: record("StateSaves/GALE01.s01")) else {
            return XCTFail("expected a live file")
        }
        XCTAssertEqual(meta.relativePath, "StateSaves/GALE01.s01")
        XCTAssertEqual(meta.fileType, .saveState)
        XCTAssertEqual(meta.checksum, "abc")
        XCTAssertEqual(meta.syncStatus, .synced)
        XCTAssertEqual(meta.lastModifiedDeviceID, "dev")
    }

    func testTombstoneRecordMapsToTombstone() {
        guard case .tombstone(let dead)? = CloudKitSyncProvider.remoteRecord(from: record("StateSaves/GALE01.s01", deleted: true)) else {
            return XCTFail("expected a tombstone")
        }
        XCTAssertEqual(dead.relativePath, "StateSaves/GALE01.s01")
        XCTAssertEqual(dead.checksum, "abc")
        XCTAssertEqual(dead.deletedAt, epoch.addingTimeInterval(60))
        XCTAssertEqual(dead.deviceIdentifier, "dev")
    }

    /// Policy is the planner's job; an opt-in record still maps so a device
    /// with the switch on sees it, and one with it off ignores it later.
    func testOptInRecordsStillMap() {
        let channel = record("Wii/title/00010001/48414441/content/00000000.app", type: .wiiChannel, size: 40 * 1024 * 1024)
        guard case .file(let meta)? = CloudKitSyncProvider.remoteRecord(from: channel) else {
            return XCTFail("expected a live file")
        }
        XCTAssertEqual(meta.fileType, .wiiChannel)
    }

    /// Anything the classifier would not let out of the device is not let in
    /// either, live or dead.
    func testUnclassifiablePathsAreDropped() {
        XCTAssertNil(CloudKitSyncProvider.remoteRecord(from: record("Software/game.iso")))
        XCTAssertNil(CloudKitSyncProvider.remoteRecord(from: record("Software/game.iso", deleted: true)))
        XCTAssertNil(CloudKitSyncProvider.remoteRecord(from: record("../escape.s01")))
        // Oversize for its category.
        XCTAssertNil(CloudKitSyncProvider.remoteRecord(from: record("StateSaves/GALE01.s01", size: 65 * 1024 * 1024)))
    }

    func testTombstoneWithoutDeletedAtFallsBackToLastModified() {
        let r = record("StateSaves/GALE01.s01", deleted: true)
        r[CloudSyncConstants.Field.deletedAt] = nil
        guard case .tombstone(let dead)? = CloudKitSyncProvider.remoteRecord(from: r) else {
            return XCTFail("expected a tombstone")
        }
        XCTAssertEqual(dead.deletedAt, epoch)
    }

    func testTombstoneExpiry() {
        let dead = SyncTombstone(relativePath: "x", checksum: "c", deletedAt: epoch)
        XCTAssertFalse(dead.isExpired(asOf: epoch.addingTimeInterval(CloudSyncConstants.tombstoneRetention - 1)))
        XCTAssertTrue(dead.isExpired(asOf: epoch.addingTimeInterval(CloudSyncConstants.tombstoneRetention + 1)))
    }
}
#endif
