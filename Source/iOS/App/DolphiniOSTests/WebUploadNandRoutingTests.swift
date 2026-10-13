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
    private var importCompletion: ((Bool) -> Void)?

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
        service.nandImporter = { [unowned self] url, completion in
            importedPaths.append(url.path)
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

    func testNandBackupIsImportedFromOutsideTheLibrary() throws {
        let service = makeService()
        let path = try upload(named: "nand.bin", size: UInt64(UploadKind.acceptedSizes.max()!))
        service.processUpload(atPath: path, libraryFolder: library.path)

        XCTAssertEqual(importedPaths.count, 1)
        XCTAssertTrue(importedPaths[0].hasPrefix(staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "the library rescan must not see nand.bin")
        XCTAssertNotNil(service.consumeSummary(defaultUploadCount: 1))
    }

    func testGoodImportDeletesTheBackup() throws {
        let service = makeService()
        let path = try upload(named: "nand.bin", size: UInt64(UploadKind.acceptedSizes.min()!))
        service.processUpload(atPath: path, libraryFolder: library.path)
        importCompletion?(true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: importedPaths[0]))
    }

    func testFailedImportKeepsTheBackup() throws {
        let service = makeService()
        let path = try upload(named: "nand.bin", size: UInt64(UploadKind.acceptedSizes.min()!))
        service.processUpload(atPath: path, libraryFolder: library.path)
        importCompletion?(false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: importedPaths[0]))
    }

    func testWrongSizeFallsThroughUntouched() throws {
        let service = makeService()
        let path = try upload(named: "nand.bin", size: 1_459_978_240)
        service.processUpload(atPath: path, libraryFolder: library.path)

        XCTAssertTrue(importedPaths.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testRunningGameRefusesButKeepsTheBackup() throws {
        let service = makeService(emulating: true)
        let path = try upload(named: "nand.bin", size: UInt64(UploadKind.acceptedSizes.min()!))
        service.processUpload(atPath: path, libraryFolder: library.path)

        XCTAssertTrue(importedPaths.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        let kept = try FileManager.default.subpathsOfDirectory(atPath: staging.path).filter { $0.hasSuffix("nand.bin") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertNotNil(service.consumeSummary(defaultUploadCount: 1))
    }
}
