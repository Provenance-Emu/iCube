// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import PVSyncRules
@testable import PVCloudSync

/// The tombstone table from the design spec (section 6), one test per row, plus
/// the policy filter and merged-document behaviour around it.
final class SyncPlannerDeleteTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let planner = SyncPlanner()
    private let path = "StateSaves/GALE01.s01"

    private func meta(
        _ path: String,
        offsetSeconds: TimeInterval = 0,
        checksum: String = "aaa",
        type: SyncableFileType = .saveState
    ) -> SyncableFileMetadata {
        SyncableFileMetadata(
            relativePath: path,
            lastModified: epoch.addingTimeInterval(offsetSeconds),
            fileSize: 1024,
            checksum: checksum,
            fileType: type
        )
    }

    private func tombstone(_ path: String, offsetSeconds: TimeInterval = 0, checksum: String = "aaa") -> SyncTombstone {
        SyncTombstone(relativePath: path, checksum: checksum, deletedAt: epoch.addingTimeInterval(offsetSeconds), deviceIdentifier: "other")
    }

    private func index(_ path: String, checksum: String = "aaa", deleted: Bool = false) -> SyncIndexSnapshot {
        SyncIndexSnapshot(entries: [path: SyncIndexEntry(
            checksum: checksum, lastModified: epoch, syncedAt: epoch, deletedAt: deleted ? epoch : nil
        )])
    }

    private func plan(
        local: [SyncableFileMetadata] = [],
        files: [SyncableFileMetadata] = [],
        tombstones: [SyncTombstone] = [],
        index: SyncIndexSnapshot = .empty,
        policy: SyncPolicy = .default,
        nowOffset: TimeInterval = 3_600
    ) -> [SyncPlanStep] {
        planner.plan(
            local: local,
            remote: RemoteSyncSnapshot(files: files, tombstones: tombstones),
            index: index,
            policy: policy,
            now: epoch.addingTimeInterval(nowOffset),
            deviceIdentifier: "me"
        )
    }

    // MARK: - Local present, remote absent

    func testLocalPresentRemoteAbsentUploadsWhetherOrNotIndexed() {
        let local = meta(path)
        XCTAssertEqual(plan(local: [local]), [.upload(local, reason: .localOnly)])
        // Indexed too: the record vanished without a tombstone (purge, expiry,
        // zone reset). Re-upload is the only safe reading.
        XCTAssertEqual(plan(local: [local], index: index(path)), [.upload(local, reason: .localOnly)])
    }

    // MARK: - Local present, remote tombstone

    func testLocalNewerThanTombstoneUndeletes() {
        let local = meta(path, offsetSeconds: 600, checksum: "edited")
        let dead = tombstone(path, offsetSeconds: 0, checksum: "aaa")
        XCTAssertEqual(plan(local: [local], tombstones: [dead]), [.upload(local, reason: .undelete)])
    }

    func testLocalMatchingTombstoneChecksumGoesToTrash() {
        let local = meta(path, offsetSeconds: 0, checksum: "aaa")
        let dead = tombstone(path, offsetSeconds: 300, checksum: "aaa")
        XCTAssertEqual(plan(local: [local], tombstones: [dead]), [.trashLocal(local, tombstone: dead)])
    }

    func testLocalOlderThanTombstoneWithDifferentBytesIsAConflict() {
        let local = meta(path, offsetSeconds: 0, checksum: "mine")
        let dead = tombstone(path, offsetSeconds: 300, checksum: "theirs")
        let steps = plan(local: [local], tombstones: [dead])
        guard case .conflict(let conflict)? = steps.first, steps.count == 1 else {
            return XCTFail("expected one conflict, got \(steps)")
        }
        XCTAssertEqual(conflict.kind, .deletedRemotelyChangedLocally)
        XCTAssertEqual(conflict.localVersion.checksum, "mine")
        XCTAssertEqual(conflict.remoteVersion.checksum, "theirs")
        XCTAssertEqual(conflict.remoteVersion.size, 0)
        XCTAssertEqual(conflict.remoteVersion.modifiedDate, dead.deletedAt)
    }

    /// A tombstone with no checksum can never match, so it can only ever
    /// produce a conflict or lose to a newer local file. Never a silent delete.
    func testTombstoneWithoutChecksumNeverDeletes() {
        let local = meta(path, offsetSeconds: 0, checksum: "aaa")
        let dead = tombstone(path, offsetSeconds: 300, checksum: "")
        let steps = plan(local: [local], tombstones: [dead])
        guard case .conflict? = steps.first else { return XCTFail("expected conflict, got \(steps)") }
    }

    /// Inside the mtime tolerance of the deletion the local file does not
    /// count as "newer"; the checksum decides.
    func testLocalWithinToleranceOfTombstoneUsesChecksum() {
        let local = meta(path, offsetSeconds: 301, checksum: "aaa")
        let dead = tombstone(path, offsetSeconds: 300, checksum: "aaa")
        XCTAssertEqual(plan(local: [local], tombstones: [dead]), [.trashLocal(local, tombstone: dead)])
    }

    /// A merged document is never deleted; a tombstone for one is overridden.
    func testMergedDocumentIgnoresTombstone() {
        let local = meta("Profiles/library_state.json", checksum: "aaa", type: .libraryState)
        let dead = tombstone("Profiles/library_state.json", offsetSeconds: 300, checksum: "aaa")
        XCTAssertEqual(plan(local: [local], tombstones: [dead]), [.upload(local, reason: .undelete)])
    }

    // MARK: - Local absent, remote live

    func testRemoteOnlyWithoutIndexDownloads() {
        let remote = meta(path)
        XCTAssertEqual(plan(files: [remote]), [.download(remote)])
    }

    func testRemoteOnlyAlreadyMarkedDeletedDownloads() {
        // We applied its deletion once; a live record now means it came back.
        let remote = meta(path, checksum: "bbb")
        XCTAssertEqual(plan(files: [remote], index: index(path, checksum: "aaa", deleted: true)), [.download(remote)])
    }

    func testRemoteOnlyIndexedWithSameChecksumWritesTombstone() {
        let remote = meta(path, checksum: "aaa")
        let steps = plan(files: [remote], index: index(path, checksum: "aaa"))
        guard case .writeTombstone(let dead)? = steps.first, steps.count == 1 else {
            return XCTFail("expected tombstone, got \(steps)")
        }
        XCTAssertEqual(dead.relativePath, path)
        XCTAssertEqual(dead.checksum, "aaa")
        XCTAssertEqual(dead.deletedAt, epoch.addingTimeInterval(3_600))
        XCTAssertEqual(dead.deviceIdentifier, "me")
    }

    func testRemoteOnlyIndexedWithChangedChecksumRestores() {
        let remote = meta(path, offsetSeconds: 600, checksum: "newer")
        XCTAssertEqual(plan(files: [remote], index: index(path, checksum: "aaa")), [.restore(remote)])
    }

    func testRemoteOnlyMergedDocumentDeletedLocallyIsFetchedAgain() {
        let remote = meta("Profiles/game_profiles.json", checksum: "aaa", type: .gameProfile)
        XCTAssertEqual(
            plan(files: [remote], index: index("Profiles/game_profiles.json", checksum: "aaa")),
            [.download(remote)])
    }

    // MARK: - Local absent, remote tombstone

    func testTombstoneForUnknownPathIsSilent() {
        XCTAssertEqual(plan(tombstones: [tombstone(path)]), [])
    }

    func testTombstoneForIndexedLivePathMarksDeleted() {
        XCTAssertEqual(plan(tombstones: [tombstone(path)], index: index(path)), [.markDeleted(relativePath: path)])
    }

    func testTombstoneForAlreadyDeletedPathIsSilent() {
        XCTAssertEqual(plan(tombstones: [tombstone(path)], index: index(path, deleted: true)), [])
    }

    // MARK: - Both present

    func testMergedDocumentWithDifferentBytesMerges() {
        let local = meta("Profiles/library_state.json", offsetSeconds: 0, checksum: "a", type: .libraryState)
        let remote = meta("Profiles/library_state.json", offsetSeconds: 9_000, checksum: "b", type: .libraryState)
        XCTAssertEqual(plan(local: [local], files: [remote]), [.merge(local: local, remote: remote)])
    }

    func testMergedDocumentWithSameBytesIsSynced() {
        let local = meta("Profiles/library_state.json", offsetSeconds: 0, checksum: "a", type: .libraryState)
        let remote = meta("Profiles/library_state.json", offsetSeconds: 9_000, checksum: "a", type: .libraryState)
        XCTAssertEqual(plan(local: [local], files: [remote]), [.markSynced(local)])
    }

    /// A live record wins over a tombstone with the same name, for backends
    /// where both can exist.
    func testLiveRecordBeatsTombstoneForTheSamePath() {
        let local = meta(path, checksum: "aaa")
        let remote = meta(path, checksum: "aaa")
        XCTAssertEqual(plan(local: [local], files: [remote], tombstones: [tombstone(path)]), [.markSynced(local)])
    }

    // MARK: - Policy

    func testOptInCategoriesAreInvisibleInBothDirectionsWhenOff() {
        let channel = "Wii/title/00010001/48414441/content/00000000.app"
        let local = meta(channel, type: .wiiChannel)
        let remote = meta("GC/USA/IPL.bin", type: .firmware)
        let dead = tombstone("Wii/ticket/00010001/48414441.tik")
        XCTAssertEqual(plan(local: [local], files: [remote], tombstones: [dead], index: index(dead.relativePath)), [])

        let on = SyncPolicy(firmwareEnabled: true, wiiChannelsEnabled: true)
        XCTAssertEqual(
            plan(local: [local], files: [remote], tombstones: [dead], index: index(dead.relativePath), policy: on),
            [.upload(local, reason: .localOnly), .download(remote), .markDeleted(relativePath: dead.relativePath)])
    }

    func testPlanIsDeterministicAcrossInputOrder() {
        let locals = [meta("StateSaves/b.s01"), meta("StateSaves/a.s01", checksum: "x")]
        let files = [meta("StateSaves/z.s01"), meta("StateSaves/a.s01", offsetSeconds: 600, checksum: "y")]
        let dead = [tombstone("StateSaves/c.s01"), tombstone("StateSaves/b.s01", offsetSeconds: 600)]
        let idx = SyncIndexSnapshot(entries: [
            "StateSaves/c.s01": SyncIndexEntry(checksum: "aaa", lastModified: epoch, syncedAt: epoch)
        ])
        let first = plan(local: locals, files: files, tombstones: dead, index: idx)
        let second = plan(local: locals.reversed(), files: files.reversed(), tombstones: dead.reversed(), index: idx)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 4)
    }
}
