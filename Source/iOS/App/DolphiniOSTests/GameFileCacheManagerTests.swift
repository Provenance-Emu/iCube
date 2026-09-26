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

    /// Every read used to build a fresh `TVGameItem` per game (cover bytes copied, banner `CGImage`
    /// created) on the caller's thread — main, for the Library. An unchanged game must come back as
    /// the item built when the list was published.
    func test_currentGames_returnsTheSameItemForAnUnchangedGame() throws {
        let manager = GameFileCacheManager.shared()
        let path = try addTestGame(manager)
        defer { removeTestGame(path, manager) }

        let first = manager.currentGames().first { $0.filePath == path }
        let second = manager.currentGames().first { $0.filePath == path }

        let item = try XCTUnwrap(first, "rescan did not pick up the test game")
        XCTAssertTrue(item === second, "an unchanged game was rebuilt on read")
    }

    /// Titles and makers are resolved in the configured GameCube/Wii language when an item is
    /// built, so reusing items across a language change would keep showing the old language.
    func test_rescan_rebuildsItemsAfterALanguageChange() throws {
        let manager = GameFileCacheManager.shared()
        let path = try addTestGame(manager)
        defer { removeTestGame(path, manager) }
        let before = try XCTUnwrap(manager.currentGames().first { $0.filePath == path })

        // A .dol is a GameCube title, so it follows the GameCube language.
        let original = DOLConfigBridge.mainGCLanguage()
        defer { DOLConfigBridge.setMainGCLanguage(original) }
        DOLConfigBridge.setMainGCLanguage(original == 0 ? 1 : 0)
        manager.rescan()
        drainCacheQueue(manager)

        let after = try XCTUnwrap(manager.currentGames().first { $0.filePath == path })
        XCTAssertFalse(before === after, "item built in the old language was reused")
    }

    /// Adds a dummy game and rescans. Any .dol is a valid GameFile by extension alone
    /// (GameFile.cpp), so no real disc is needed.
    private func addTestGame(_ manager: GameFileCacheManager) throws -> String {
        let path = (UserFolderUtil.getSoftwareFolder() as NSString)
            .appendingPathComponent("icube-test-\(UUID().uuidString).dol")
        try Data(repeating: 0, count: 0x100).write(to: URL(fileURLWithPath: path))
        manager.rescan()
        drainCacheQueue(manager)
        return path
    }

    private func removeTestGame(_ path: String, _ manager: GameFileCacheManager) {
        try? FileManager.default.removeItem(atPath: path)
        manager.rescan()
        drainCacheQueue(manager)
    }

    /// Waits for everything already queued on the cache queue (the rescan) to finish.
    private func drainCacheQueue(_ manager: GameFileCacheManager) {
        let drained = expectation(description: "cache queue drained")
        manager.enqueueOnCacheQueueForTesting { drained.fulfill() }
        wait(for: [drained], timeout: 60)
    }
}
