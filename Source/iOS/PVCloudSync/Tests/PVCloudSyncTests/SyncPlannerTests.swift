// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import PVSyncRules
@testable import PVCloudSync

final class SyncPlannerTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func meta(
        _ path: String,
        offsetSeconds: TimeInterval = 0,
        checksum: String = "aaa",
        size: Int64 = 1024,
        type: SyncableFileType = .saveState
    ) -> SyncableFileMetadata {
        SyncableFileMetadata(
            relativePath: path,
            lastModified: epoch.addingTimeInterval(offsetSeconds),
            fileSize: size,
            checksum: checksum,
            fileType: type
        )
    }

    // MARK: - Union merge

    func testLocalOnlyFilesUpload() {
        let steps = SyncPlanner().plan(local: [meta("StateSaves/GALE01.s01")], remote: [])
        XCTAssertEqual(steps, [.upload(meta("StateSaves/GALE01.s01"), reason: .localOnly)])
    }

    func testRemoteOnlyFilesDownload() {
        let remote = meta("StateSaves/GALE01.s01")
        XCTAssertEqual(SyncPlanner().plan(local: [], remote: [remote]), [.download(remote)])
    }

    /// The merge is additive in both directions: an empty cloud never deletes
    /// local saves, and a file missing locally is never deleted remotely.
    func testNoStepEverDeletesAnything() {
        let planner = SyncPlanner()
        let localOnly = planner.plan(local: [meta("GC/USA/MemoryCardA.raw", type: .gameCubeMemoryCard)], remote: [])
        let remoteOnly = planner.plan(local: [], remote: [meta("GC/USA/MemoryCardA.raw", type: .gameCubeMemoryCard)])
        for step in localOnly + remoteOnly {
            switch step {
            case .upload, .download, .markSynced, .conflict:
                continue   // there is deliberately no `.delete` case to match
            }
        }
        XCTAssertEqual(localOnly.count, 1)
        XCTAssertEqual(remoteOnly.count, 1)
    }

    // MARK: - Skipping work

    func testIdenticalChecksumSkipsTransferEvenWithDistantMtimes() {
        let local = meta("Config/Dolphin.ini", offsetSeconds: 0, checksum: "same", type: .config)
        let remote = meta("Config/Dolphin.ini", offsetSeconds: 9_000, checksum: "same", type: .config)
        XCTAssertEqual(SyncPlanner().plan(local: [local], remote: [remote]), [.markSynced(local)])
    }

    func testNearIdenticalMtimesSkipTransfer() {
        let local = meta("Config/Dolphin.ini", offsetSeconds: 0, checksum: "a", type: .config)
        let remote = meta("Config/Dolphin.ini", offsetSeconds: 1, checksum: "b", type: .config)
        XCTAssertEqual(SyncPlanner().plan(local: [local], remote: [remote]), [.markSynced(local)])
    }

    func testAnEmptyLocalChecksumDoesNotCountAsAMatch() {
        let local = meta("Config/Dolphin.ini", offsetSeconds: 0, checksum: "", type: .config)
        let remote = meta("Config/Dolphin.ini", offsetSeconds: 600, checksum: "", type: .config)
        XCTAssertEqual(SyncPlanner().plan(local: [local], remote: [remote]),
                       [.download(remote)])
    }

    // MARK: - Conflicts

    func testNewerLocalUploads() {
        let local = meta("StateSaves/GALE01.s01", offsetSeconds: 600, checksum: "new")
        let remote = meta("StateSaves/GALE01.s01", offsetSeconds: 0, checksum: "old")
        XCTAssertEqual(SyncPlanner().plan(local: [local], remote: [remote]),
                       [.upload(local, reason: .contentChanged)])
    }

    func testNewerRemoteDownloads() {
        let local = meta("StateSaves/GALE01.s01", offsetSeconds: 0, checksum: "old")
        let remote = meta("StateSaves/GALE01.s01", offsetSeconds: 600, checksum: "new")
        XCTAssertEqual(SyncPlanner().plan(local: [local], remote: [remote]), [.download(remote)])
    }

    /// Different bytes written within the simultaneity window cannot be ordered
    /// by timestamp, so the user decides.
    func testSimultaneousDifferentContentBecomesAConflict() {
        let local = meta("StateSaves/GALE01.s01", offsetSeconds: 0, checksum: "x")
        let remote = meta("StateSaves/GALE01.s01", offsetSeconds: 3, checksum: "y")
        // 3 s is inside the 5 s window but outside the 2 s mtime tolerance.
        let steps = SyncPlanner().plan(local: [local], remote: [remote])
        guard case .conflict(let conflict)? = steps.first, steps.count == 1 else {
            return XCTFail("expected exactly one conflict, got \(steps)")
        }
        XCTAssertEqual(conflict.localVersion.checksum, "x")
        XCTAssertEqual(conflict.remoteVersion.checksum, "y")
    }

    // MARK: - Ordering

    func testPlanIsDeterministicAndUploadsBeforeRemoteOnlyDownloads() {
        let local = [meta("StateSaves/b.s01"), meta("StateSaves/a.s01")]
        let remote = [meta("StateSaves/z.s01"), meta("StateSaves/y.s01")]
        let first = SyncPlanner().plan(local: local, remote: remote)
        let second = SyncPlanner().plan(local: local.reversed(), remote: remote.reversed())
        XCTAssertEqual(first, second, "plan must not depend on input order")
        XCTAssertEqual(first, [
            .upload(meta("StateSaves/a.s01"), reason: .localOnly),
            .upload(meta("StateSaves/b.s01"), reason: .localOnly),
            .download(meta("StateSaves/y.s01")),
            .download(meta("StateSaves/z.s01"))
        ])
    }
}
