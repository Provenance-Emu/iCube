// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// ICUBE-F: the Library, Spotlight and ecosystem readers call `currentGames` on the main thread.
/// It used to `dispatch_sync` onto the serial cache queue, so a read that landed during a rescan
/// waited for the whole scan (archive extraction, disc parsing, cover downloads) — 3-5 s hangs.
/// Readers must see the last published list instead of queueing behind the scan.
final class GameFileCacheManagerTests: XCTestCase {

    /// Longest a read may take while the cache queue is busy. Generous for a slow simulator; the
    /// old code blocked until the queue was released, so it could never pass.
    private let readDeadline: TimeInterval = 1

    func test_currentGames_returnsWhileCacheQueueIsBusy() {
        let manager = GameFileCacheManager.shared()
        let parked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        manager.enqueueOnCacheQueueForTesting {
            parked.signal()
            release.wait()
        }
        // Unpark even when the assertion fails, so a blocked reader finishes and the queue drains.
        defer { release.signal() }

        // The host app may have a launch scan queued ahead of us; wait until our block holds the queue.
        XCTAssertEqual(parked.wait(timeout: .now() + 60), .success, "cache queue never drained")

        let returned = expectation(description: "currentGames returned while the cache queue was busy")
        DispatchQueue.global(qos: .userInitiated).async {
            _ = manager.currentGames()
            returned.fulfill()
        }
        wait(for: [returned], timeout: readDeadline)
    }
}
