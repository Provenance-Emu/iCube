// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import PVSyncRules
@testable import PVCloudSync

final class TimestampConflictResolverTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let resolver = TimestampConflictResolver()

    private func meta(offsetSeconds: TimeInterval, checksum: String) -> SyncableFileMetadata {
        SyncableFileMetadata(
            relativePath: "StateSaves/GALE01.s01",
            lastModified: epoch.addingTimeInterval(offsetSeconds),
            fileSize: 2048,
            checksum: checksum,
            fileType: .saveState
        )
    }

    /// Rule 1: identical checksum wins immediately.
    func testIdenticalChecksumInsideTheWindowResolvesToLocal() {
        let resolution = resolver.resolve(
            local: meta(offsetSeconds: 0, checksum: "same"),
            remote: meta(offsetSeconds: 2, checksum: "same")
        )
        XCTAssertEqual(resolution, .useLocal)
    }

    /// Rule 2: differing checksums inside the window escalate to manual.
    func testDifferingChecksumInsideTheWindowEscalatesToManual() {
        let resolution = resolver.resolve(
            local: meta(offsetSeconds: 0, checksum: "left"),
            remote: meta(offsetSeconds: 4, checksum: "right")
        )
        guard case .manual(let conflict) = resolution else {
            return XCTFail("expected manual escalation, got \(resolution)")
        }
        XCTAssertEqual(conflict.localVersion.checksum, "left")
        XCTAssertEqual(conflict.remoteVersion.checksum, "right")
    }

    func testTheWindowIsSymmetric() {
        // Remote earlier than local, same 4 s gap.
        let resolution = resolver.resolve(
            local: meta(offsetSeconds: 4, checksum: "left"),
            remote: meta(offsetSeconds: 0, checksum: "right")
        )
        guard case .manual = resolution else {
            return XCTFail("expected manual escalation, got \(resolution)")
        }
    }

    /// Rule 3: outside the window, last writer wins.
    func testOutsideTheWindowNewerWins() {
        XCTAssertEqual(
            resolver.resolve(local: meta(offsetSeconds: 10, checksum: "l"),
                             remote: meta(offsetSeconds: 0, checksum: "r")),
            .useLocal
        )
        XCTAssertEqual(
            resolver.resolve(local: meta(offsetSeconds: 0, checksum: "l"),
                             remote: meta(offsetSeconds: 10, checksum: "r")),
            .useRemote
        )
    }

    /// Exactly at the boundary is *outside* the window (`<`, not `<=`), so it
    /// resolves by timestamp rather than escalating.
    func testExactlyAtTheThresholdResolvesByTimestamp() {
        XCTAssertEqual(
            resolver.resolve(local: meta(offsetSeconds: 5, checksum: "l"),
                             remote: meta(offsetSeconds: 0, checksum: "r")),
            .useLocal
        )
    }

    func testThresholdIsConfigurable() {
        let wide = TimestampConflictResolver(simultaneousThreshold: 60)
        guard case .manual = wide.resolve(local: meta(offsetSeconds: 0, checksum: "l"),
                                          remote: meta(offsetSeconds: 30, checksum: "r")) else {
            return XCTFail("a 60 s window should escalate a 30 s gap")
        }
    }
}
