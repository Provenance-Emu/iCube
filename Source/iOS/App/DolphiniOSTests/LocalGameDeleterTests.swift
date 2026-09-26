// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import os
import XCTest

@testable import iCube

/// ICUBE-2F: the Library's delete alert removed game files on the main thread, and removing a
/// multi-GB image or a Wii folder title hung the app for 3-4 s (once per game in a batch delete).
final class LocalGameDeleterTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalGameDeleterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeGame(_ name: String) throws -> String {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0, count: 16).write(to: url)
        return url.path
    }

    @MainActor
    func test_delete_removesFilesOffTheMainThread() async throws {
        let paths = [try makeGame("a.iso"), try makeGame("b.iso")]
        let removedOnMain = OSAllocatedUnfairLock(initialState: [Bool]())

        let outcome = await LocalGameDeleter.delete(paths: paths) { path in
            removedOnMain.withLock { $0.append(Thread.isMainThread) }
            try FileManager.default.removeItem(atPath: path)
        }

        XCTAssertEqual(removedOnMain.withLock { $0 }, [false, false])
        XCTAssertEqual(outcome.deleted, paths)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertFalse(paths.contains { FileManager.default.fileExists(atPath: $0) })
    }

    @MainActor
    func test_delete_reportsAFailureAndKeepsGoing() async throws {
        let missing = folder.appendingPathComponent("missing.iso").path
        let present = try makeGame("present.iso")

        let outcome = await LocalGameDeleter.delete(paths: [missing, present])

        XCTAssertEqual(outcome.deleted, [present])
        XCTAssertEqual(outcome.failures.map(\.path), [missing])
        XCTAssertFalse(FileManager.default.fileExists(atPath: present))
    }
}
