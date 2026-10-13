// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// A `nand.bin` upload goes to the NAND importer only when it is the size of a BootMii dump, never while a
/// game runs, and its copy is deleted only after a good import.
final class WebUploadNandRoutingTests: XCTestCase {

    private var root: URL!
    private var library: URL!
    private var staging: URL!
    private var importedPaths: [String] = []
    private var importedKeys: [URL?] = []
    private var importCompletion: ((Bool) -> Void)?

    private let keyless = UInt64(UploadKind.keylessDumpSize)
    private let withKeys = UInt64(UploadKind.keylessDumpSize + UploadKind.keysSize)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WebUploadNandRoutingTests-\(UUID().uuidString)")
        library = root.appendingPathComponent("Software", isDirectory: true)
        staging = root.appendingPathComponent("NANDImport", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeService(emulating: Bool = false) -> WebUploadImportService {
        let service = WebUploadImportService()
        service.nandStagingRoot = staging
        service.isEmulationRunning = { emulating }
        service.nandImporter = { [unowned self] url, keysURL, completion in
            importedPaths.append(url.path)
            importedKeys.append(keysURL)
            importCompletion = completion
        }
        return service
    }

    /// A sparse file of `size` bytes: the size is what the router checks.
    private func upload(named name: String, size: UInt64) throws -> String {
        let url = library.appendingPathComponent(name)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: size)
        try handle.close()
        return url.path
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Every file under the staging folder.
    private func stagedFiles() -> [String] {
        (try? FileManager.default.subpathsOfDirectory(atPath: staging.path)) ?? []
    }

    func testNandBackupIsImportedFromOutsideTheLibrary() throws {
        let service = makeService()
        let path = try upload(named: "nand.bin", size: withKeys)
        service.processUpload(atPath: path, libraryFolder: library.path)

        XCTAssertEqual(importedPaths.count, 1)
        XCTAssertTrue(importedPaths[0].hasPrefix(staging.path))
        XCTAssertNil(importedKeys[0], "a dump with its keys appended needs no keys.bin")
        XCTAssertFalse(exists(path), "the library rescan must not see nand.bin")
        XCTAssertNotNil(service.consumeSummary(defaultUploadCount: 1))
    }

    func testGoodImportDeletesTheBackup() throws {
        let service = makeService()
        let path = try upload(named: "nand.bin", size: withKeys)
        service.processUpload(atPath: path, libraryFolder: library.path)
        importCompletion?(true)

        XCTAssertTrue(stagedFiles().filter { $0.hasSuffix("nand.bin") }.isEmpty)
    }

    func testFailedImportDeletesTheBackupToo() throws {
        let service = makeService()
        let path = try upload(named: "nand.bin", size: withKeys)
        service.processUpload(atPath: path, libraryFolder: library.path)
        importCompletion?(false)

        XCTAssertTrue(stagedFiles().filter { $0.hasSuffix("nand.bin") }.isEmpty, "the original is still on the user's computer")
    }

    func testWrongSizeFallsThroughUntouched() throws {
        let service = makeService()
        let path = try upload(named: "nand.bin", size: 1_459_978_240)
        service.processUpload(atPath: path, libraryFolder: library.path)

        XCTAssertTrue(importedPaths.isEmpty)
        XCTAssertTrue(exists(path))
    }

    func testRunningGameRefusesAndDeletesTheUpload() throws {
        let service = makeService(emulating: true)
        let path = try upload(named: "nand.bin", size: withKeys)
        service.processUpload(atPath: path, libraryFolder: library.path)

        XCTAssertTrue(importedPaths.isEmpty)
        XCTAssertFalse(exists(path))
        XCTAssertTrue(stagedFiles().isEmpty)
        XCTAssertTrue(service.consumeSummary(defaultUploadCount: 1)?.contains("Quit the game") ?? false)
    }

    func testSecondUploadDuringAnImportIsRefusedAndDeleted() throws {
        let service = makeService()
        service.processUpload(atPath: try upload(named: "nand.bin", size: withKeys), libraryFolder: library.path)
        _ = service.consumeSummary(defaultUploadCount: 1)
        let second = try upload(named: "nand.bin", size: withKeys)
        service.processUpload(atPath: second, libraryFolder: library.path)

        XCTAssertEqual(importedPaths.count, 1)
        XCTAssertFalse(exists(second))
        XCTAssertEqual(service.consumeSummary(defaultUploadCount: 1), "A NAND import is already running.")
    }

    func testImportEndingReleasesTheGuard() throws {
        let service = makeService()
        service.processUpload(atPath: try upload(named: "nand.bin", size: withKeys), libraryFolder: library.path)
        importCompletion?(false)
        service.processUpload(atPath: try upload(named: "nand.bin", size: withKeys), libraryFolder: library.path)

        XCTAssertEqual(importedPaths.count, 2)
    }

    func testKeylessDumpWithoutKeysIsRejectedAndDeleted() throws {
        let service = makeService()
        let path = try upload(named: "nand.bin", size: keyless)
        service.processUpload(atPath: path, libraryFolder: library.path)

        XCTAssertTrue(importedPaths.isEmpty)
        XCTAssertFalse(exists(path))
        XCTAssertTrue(stagedFiles().isEmpty)
        XCTAssertTrue(service.consumeSummary(defaultUploadCount: 1)?.contains("no keys") ?? false)
    }

    func testKeysUploadIsStagedOutsideTheLibrary() throws {
        let service = makeService()
        let path = try upload(named: "keys.bin", size: UInt64(UploadKind.keysSize))
        service.processUpload(atPath: path, libraryFolder: library.path)

        XCTAssertFalse(exists(path))
        XCTAssertEqual(stagedFiles(), ["keys.bin"])
        XCTAssertEqual(service.consumeSummary(defaultUploadCount: 1), "Wii keys received. Now upload nand.bin.")
    }

    func testWrongSizeKeysFileFallsThroughUntouched() throws {
        let service = makeService()
        let path = try upload(named: "keys.bin", size: 4096)
        service.processUpload(atPath: path, libraryFolder: library.path)

        XCTAssertTrue(exists(path))
        XCTAssertTrue(stagedFiles().isEmpty)
    }

    func testKeylessDumpImportsWithStagedKeysAndDeletesThemAfterSuccess() throws {
        let service = makeService()
        service.processUpload(atPath: try upload(named: "keys.bin", size: UInt64(UploadKind.keysSize)), libraryFolder: library.path)
        service.processUpload(atPath: try upload(named: "nand.bin", size: keyless), libraryFolder: library.path)

        XCTAssertEqual(importedPaths.count, 1)
        XCTAssertEqual(importedKeys[0]?.lastPathComponent, "keys.bin")
        XCTAssertTrue(exists(importedKeys[0]!.path))
        importCompletion?(true)
        XCTAssertTrue(stagedFiles().isEmpty)
    }

    func testFailedKeylessImportKeepsTheKeysForARetry() throws {
        let service = makeService()
        service.processUpload(atPath: try upload(named: "keys.bin", size: UInt64(UploadKind.keysSize)), libraryFolder: library.path)
        service.processUpload(atPath: try upload(named: "nand.bin", size: keyless), libraryFolder: library.path)
        importCompletion?(false)

        XCTAssertEqual(stagedFiles(), ["keys.bin"])
    }

    func testStagingFailureLeavesTheUploadUntouchedAndNotImported() throws {
        let service = makeService()
        // A file where the staging folder should be makes creating it fail.
        FileManager.default.createFile(atPath: staging.path, contents: Data())
        let path = try upload(named: "nand.bin", size: withKeys)
        service.processUpload(atPath: path, libraryFolder: library.path)

        XCTAssertTrue(importedPaths.isEmpty)
        XCTAssertTrue(exists(path))
        service.nandStagingRoot = root.appendingPathComponent("Other", isDirectory: true)
        service.processUpload(atPath: path, libraryFolder: library.path)
        XCTAssertEqual(importedPaths.count, 1, "the guard must be released after a staging failure")
    }
}
