// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import PVSyncRules
@testable import PVCloudSync

final class SyncIndexStoreTests: XCTestCase {

    private var directory: URL!
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SyncIndex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("iCloud/index.json") }

    func testRoundTrip() async throws {
        let store = SyncIndexStore(fileURL: fileURL)
        await store.record(path: "StateSaves/a.s01", checksum: "aaa", lastModified: epoch, syncedAt: epoch)
        await store.markDeleted(path: "StateSaves/b.s01", at: epoch)
        await store.bind(toAccountIdentity: "_user1")
        try await store.save()

        let reloaded = SyncIndexStore(fileURL: fileURL)
        let snapshot = await reloaded.snapshot()
        XCTAssertEqual(snapshot["StateSaves/a.s01"], SyncIndexEntry(checksum: "aaa", lastModified: epoch, syncedAt: epoch))
        XCTAssertEqual(snapshot["StateSaves/b.s01"]?.deletedAt, epoch)
        XCTAssertEqual(snapshot["StateSaves/b.s01"]?.isLive, false)
        let identity = await reloaded.storedAccountIdentity()
        XCTAssertEqual(identity, "_user1")
    }

    func testMissingFileIsAnEmptyIndex() async {
        let store = SyncIndexStore(fileURL: fileURL)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot, .empty)
        let count = await store.count
        XCTAssertEqual(count, 0)
    }

    func testCorruptFileIsTreatedAsEmptyNotFatal() async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        let store = SyncIndexStore(fileURL: fileURL)
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot, .empty)
        // And it can be written over.
        await store.record(path: "x", checksum: "c", lastModified: epoch)
        try await store.save()
        let count = await SyncIndexStore(fileURL: fileURL).count
        XCTAssertEqual(count, 1)
    }

    func testBindingToADifferentAccountWipesTheIndex() async {
        let store = SyncIndexStore(fileURL: fileURL)
        await store.record(path: "x", checksum: "c", lastModified: epoch)
        let firstBind = await store.bind(toAccountIdentity: "A")
        XCTAssertFalse(firstBind)
        let sameAgain = await store.bind(toAccountIdentity: "A")
        XCTAssertFalse(sameAgain)
        var count = await store.count
        XCTAssertEqual(count, 1)

        let switched = await store.bind(toAccountIdentity: "B")
        XCTAssertTrue(switched, "a different account must wipe")
        count = await store.count
        XCTAssertEqual(count, 0)
        let identity = await store.storedAccountIdentity()
        XCTAssertEqual(identity, "B")

        // nil identity (backend without accounts) never wipes.
        await store.record(path: "y", checksum: "c", lastModified: epoch)
        let nilBind = await store.bind(toAccountIdentity: nil)
        XCTAssertFalse(nilBind)
        count = await store.count
        XCTAssertEqual(count, 1)
    }

    func testMarkDeletedOnUnknownPathCreatesADeadEntry() async {
        let store = SyncIndexStore(fileURL: fileURL)
        await store.markDeleted(path: "gone", at: epoch)
        let entry = await store.entry(for: "gone")
        XCTAssertEqual(entry?.isLive, false)
        XCTAssertEqual(entry?.checksum, "")
    }

    func testResetRemovesTheFile() async throws {
        let store = SyncIndexStore(fileURL: fileURL)
        await store.record(path: "x", checksum: "c", lastModified: epoch)
        try await store.save()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        await store.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let count = await store.count
        XCTAssertEqual(count, 0)
    }
}

final class SyncTrashTests: XCTestCase {

    private var userRoot: URL!
    private var trashRoot: URL!
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("SyncTrash-\(UUID().uuidString)")
        userRoot = base.appendingPathComponent("User", isDirectory: true)
        trashRoot = base.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: userRoot.deletingLastPathComponent())
    }

    private func write(_ relativePath: String, _ text: String = "save") throws -> URL {
        let url = userRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testMoveListRestore() async throws {
        let trash = SyncTrash(rootURL: trashRoot)
        let source = try write("StateSaves/GALE01.s01", "hello")
        let entry = try await trash.move(fileAt: source, relativePath: "StateSaves/GALE01.s01", now: epoch)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(entry.relativePath, "StateSaves/GALE01.s01")
        XCTAssertEqual(entry.deletedAt, epoch)
        XCTAssertEqual(entry.fileSize, 5)

        let listed = await trash.entries()
        XCTAssertEqual(listed, [entry])

        let restoredAt = epoch.addingTimeInterval(1_000)
        try await trash.restore(entry, into: userRoot, now: restoredAt)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "hello")
        let mtime = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        XCTAssertEqual(mtime.map { Int($0.timeIntervalSince1970) }, Int(restoredAt.timeIntervalSince1970),
                       "restored file is stamped now so the next sync reads it as an undelete")
        let afterRestore = await trash.entries()
        XCTAssertTrue(afterRestore.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashRoot.appendingPathComponent("1700000000000").path),
                       "empty stamp folders are pruned")
    }

    func testNewestFirstAndPurge() async throws {
        let trash = SyncTrash(rootURL: trashRoot)
        let old = try write("StateSaves/old.s01")
        let new = try write("StateSaves/new.s01")
        try await trash.move(fileAt: old, relativePath: "StateSaves/old.s01", now: epoch)
        try await trash.move(fileAt: new, relativePath: "StateSaves/new.s01", now: epoch.addingTimeInterval(86_400 * 10))

        let listed = await trash.entries()
        XCTAssertEqual(listed.map(\.relativePath), ["StateSaves/new.s01", "StateSaves/old.s01"])
        let size = await trash.totalSize()
        XCTAssertEqual(size, 8)

        let removed = await trash.purge(olderThan: epoch.addingTimeInterval(86_400 * 5))
        XCTAssertEqual(removed, 1)
        let remaining = await trash.entries()
        XCTAssertEqual(remaining.map(\.relativePath), ["StateSaves/new.s01"])
    }

    func testDeleteForGood() async throws {
        let trash = SyncTrash(rootURL: trashRoot)
        let source = try write("GC/USA/MemoryCardA.raw")
        let entry = try await trash.move(fileAt: source, relativePath: "GC/USA/MemoryCardA.raw", now: epoch)
        try await trash.delete(entry)
        let listed = await trash.entries()
        XCTAssertTrue(listed.isEmpty)
    }

    func testRestoreRefusesToEscapeTheUserRoot() async throws {
        let trash = SyncTrash(rootURL: trashRoot)
        let source = try write("StateSaves/x.s01")
        let entry = try await trash.move(fileAt: source, relativePath: "StateSaves/x.s01", now: epoch)
        let hostile = SyncTrashEntry(id: entry.id, relativePath: "../../escape.s01", deletedAt: entry.deletedAt,
                                     fileSize: entry.fileSize, url: entry.url)
        do {
            try await trash.restore(hostile, into: userRoot)
            XCTFail("must not restore outside the root")
        } catch {
            XCTAssertEqual(error as? SyncProviderError, .invalidData)
        }
    }

    func testScannerMovesThroughTrash() async throws {
        let trash = SyncTrash(rootURL: trashRoot)
        let scanner = UserDataScanner(rootDirectory: userRoot)
        _ = try write("StateSaves/GALE01.s01")
        let entry = try await scanner.moveToTrash(relativePath: "StateSaves/GALE01.s01", trash: trash, now: epoch)
        XCTAssertEqual(entry.relativePath, "StateSaves/GALE01.s01")
        let exists = await scanner.fileExists(relativePath: "StateSaves/GALE01.s01")
        XCTAssertFalse(exists)
    }
}
