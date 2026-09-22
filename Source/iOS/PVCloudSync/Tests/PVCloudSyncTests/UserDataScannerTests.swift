// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import PVSyncRules
@testable import PVCloudSync

/// Scanner tests against a real temp directory — no network, no container.
final class UserDataScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PVCloudSyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relativePath: String, bytes: Int = 16) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0x42, count: bytes).write(to: url)
    }

    // MARK: - Allow-list

    func testScanPicksUpEverySyncableCategory() async throws {
        try write("StateSaves/GALE01.s01")
        try write("StateSaves/GALE01.auto")
        try write("StateSaves/GALE01.json")
        try write("GC/USA/MemoryCardA.raw")
        try write("Config/Dolphin.ini")
        try write("GameSettings/GALE01.ini")

        let found = await UserDataScanner(rootDirectory: root).scanLocalFiles()
        let byPath = Dictionary(uniqueKeysWithValues: found.map { ($0.relativePath, $0.fileType) })

        XCTAssertEqual(byPath["StateSaves/GALE01.s01"], .saveState)
        XCTAssertEqual(byPath["StateSaves/GALE01.auto"], .resumeState)
        XCTAssertEqual(byPath["StateSaves/GALE01.json"], .saveStateMetadata)
        XCTAssertEqual(byPath["GC/USA/MemoryCardA.raw"], .gameCubeMemoryCard)
        XCTAssertEqual(byPath["Config/Dolphin.ini"], .config)
        XCTAssertEqual(byPath["GameSettings/GALE01.ini"], .gameSettings)
    }

    /// The acceptance criterion for the whole workstream: no ROM ever leaves the
    /// device, and neither does artwork or firmware.
    func testNoRomArtworkOrFirmwareIsEverScanned() async throws {
        try write("Games/SuperMario.iso", bytes: 4096)
        try write("StateSaves/NotAGame.rvz")
        try write("Cache/GameCovers/GALE01.png")
        try write("GC/USA/IPL.bin")
        try write("Load/Textures/GALE01/tex.png")
        try write("Dump/Frames/fifo.dff")
        try write("Logs/dolphin.log")

        let found = await UserDataScanner(rootDirectory: root).scanLocalFiles()
        XCTAssertTrue(found.isEmpty, "scanner offered up: \(found.map(\.relativePath))")
    }

    func testEmptyFilesAreSkipped() async throws {
        try write("StateSaves/GALE01.s01", bytes: 0)
        let found = await UserDataScanner(rootDirectory: root).scanLocalFiles()
        XCTAssertTrue(found.isEmpty)
    }

    func testMissingRootIsEmptyNotAnError() async {
        let missing = root.appendingPathComponent("does-not-exist")
        let found = await UserDataScanner(rootDirectory: missing).scanLocalFiles()
        XCTAssertTrue(found.isEmpty)
    }

    func testRelativePathsAreRootRelativeWithNoLeadingSlash() async throws {
        try write("GameSettings/GALE01.ini")
        let found = await UserDataScanner(rootDirectory: root).scanLocalFiles()
        XCTAssertEqual(found.map(\.relativePath), ["GameSettings/GALE01.ini"])
    }

    // MARK: - Checksums

    func testChecksumIsStableAndChangesWithContent() async throws {
        try write("Config/Dolphin.ini", bytes: 32)
        let scanner = UserDataScanner(rootDirectory: root)

        let first = await scanner.scanLocalFiles()
        let second = await scanner.scanLocalFiles()
        XCTAssertEqual(first.first?.checksum, second.first?.checksum)
        XCTAssertEqual(first.first?.checksum.count, 64, "SHA-256 hex is 64 characters")

        // A different size invalidates the cache even if the mtime were reused.
        try write("Config/Dolphin.ini", bytes: 64)
        let third = await scanner.scanLocalFiles()
        XCTAssertNotEqual(first.first?.checksum, third.first?.checksum)
    }

    // MARK: - Writing

    func testWriteStampsTheSourceModificationDate() async throws {
        let scanner = UserDataScanner(rootDirectory: root)
        let sourceDate = Date(timeIntervalSince1970: 1_600_000_000)
        try await scanner.writeFile(
            relativePath: "StateSaves/GALE01.s01",
            data: Data(repeating: 1, count: 8),
            modificationDate: sourceDate
        )
        let readBack = await scanner.modificationDate(relativePath: "StateSaves/GALE01.s01")
        XCTAssertEqual(readBack?.timeIntervalSince1970 ?? 0, sourceDate.timeIntervalSince1970, accuracy: 1)
    }

    /// A corrupt or hostile remote record name must not be able to place a file
    /// wherever it likes.
    func testWriteRejectsPathsTheClassifierWouldNeverAllow() async {
        let scanner = UserDataScanner(rootDirectory: root)
        for path in ["Games/Evil.iso", "../escape.ini", "Cache/GameCovers/x.png"] {
            do {
                try await scanner.writeFile(relativePath: path, data: Data([0]), modificationDate: nil)
                XCTFail("wrote a file the classifier rejects: \(path)")
            } catch {
                // expected
            }
        }
    }
}
