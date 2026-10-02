// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// Archive imports must never modify a folder the user picked from, and an archive that fails to
/// import from the library folder must not be extracted and rejected again on every rescan.
final class ArchiveImportSafetyTests: XCTestCase {

    private var root: URL!
    private var external: URL!
    private var library: URL!
    private var rejected: URL!

    private let gameBytes = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })

    override func setUpWithError() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("ArchiveImportSafetyTests-\(UUID().uuidString)")
        external = root.appendingPathComponent("Picked Folder", isDirectory: true)
        library = root.appendingPathComponent("Software", isDirectory: true)
        rejected = root.appendingPathComponent(ZipImportHelper.rejectedImportsFolderName, isDirectory: true)
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Picked archives (document picker, asCopy: false)

    func testPickedArchiveImportsIntoLibraryAndLeavesTheOriginalUntouched() throws {
        let archive = external.appendingPathComponent("Game.zip")
        let archiveData = Self.storedZip(entries: [("Game.iso", gameBytes)])
        try archiveData.write(to: archive)

        let result = ZipImportHelper.importPickedArchive(at: archive, toFolder: library.path)

        XCTAssertEqual(result.importedCount, 1)
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("Game.iso")), gameBytes)
        try assertExternalFolderUnchanged(archive: archive, data: archiveData)
    }

    func testPickedArchiveIsKeptWhenEveryGameIsAlreadyImported() throws {
        try gameBytes.write(to: library.appendingPathComponent("Game.iso"))
        let archive = external.appendingPathComponent("Game.zip")
        let archiveData = Self.storedZip(entries: [("Game.iso", gameBytes)])
        try archiveData.write(to: archive)

        let result = ZipImportHelper.importPickedArchive(at: archive, toFolder: library.path)

        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.skippedExistingCount, 1)
        try assertExternalFolderUnchanged(archive: archive, data: archiveData)
    }

    func testRejectedPickedArchiveIsNeitherMovedNorDeleted() throws {
        let archive = external.appendingPathComponent("Broken.zip")
        let archiveData = Data("not a zip file".utf8)
        try archiveData.write(to: archive)

        let result = ZipImportHelper.importPickedArchive(at: archive, toFolder: library.path)

        XCTAssertEqual(result.importedCount, 0)
        XCTAssertNotNil(result.errorMessage)
        try assertExternalFolderUnchanged(archive: archive, data: archiveData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: library.path), [])
    }

    func testMissingPickedArchiveReportsAnError() {
        let result = ZipImportHelper.importPickedArchive(at: external.appendingPathComponent("Gone.zip"),
                                                         toFolder: library.path)
        XCTAssertEqual(result.importedCount, 0)
        XCTAssertNotNil(result.errorMessage)
    }

    // MARK: - Web uploads

    func testWebUploadedArchiveIsExtractedAndRemoved() throws {
        let archive = library.appendingPathComponent("Game.zip")
        try Self.storedZip(entries: [("Game.iso", gameBytes)]).write(to: archive)
        let service = WebUploadImportService()

        service.processUpload(atPath: archive.path, libraryFolder: library.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual(try Data(contentsOf: library.appendingPathComponent("Game.iso")), gameBytes)
        XCTAssertNotNil(service.consumeSummary(defaultUploadCount: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
    }

    func testRejectedWebUploadIsMovedAsideReportedAndNotReprocessed() throws {
        let archive = library.appendingPathComponent("Broken.zip")
        let archiveData = Data("not a zip file".utf8)
        try archiveData.write(to: archive)
        let service = WebUploadImportService()

        service.processUpload(atPath: archive.path, libraryFolder: library.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertEqual(try Data(contentsOf: rejected.appendingPathComponent("Broken.zip")), archiveData)

        let summary = try XCTUnwrap(service.consumeSummary(defaultUploadCount: 1))
        XCTAssertTrue(summary.contains("Broken.zip"), summary)
        XCTAssertNil(service.consumeSummary(defaultUploadCount: 0), "summary state is reset once consumed")

        let rescan = ZipImportHelper.processOrphanedArchives(inFolder: library.path)
        XCTAssertEqual(rescan.archivesProcessed, 0)
        XCTAssertEqual(rescan.failedArchives, 0, "a rejected upload must not be processed again")
    }

    func testReuploadingTheSameRejectedArchiveReplacesTheEarlierCopy() throws {
        let service = WebUploadImportService()
        for attempt in 0..<2 {
            let archive = library.appendingPathComponent("Broken.zip")
            try Data("attempt \(attempt)".utf8).write(to: archive)
            service.processUpload(atPath: archive.path, libraryFolder: library.path)
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: rejected.path), ["Broken.zip"])
        XCTAssertEqual(try Data(contentsOf: rejected.appendingPathComponent("Broken.zip")), Data("attempt 1".utf8))
    }

    func testSummaryCountsSeveralRejectedUploads() throws {
        let service = WebUploadImportService()
        for name in ["A.zip", "B.zip"] {
            let archive = library.appendingPathComponent(name)
            try Data("junk".utf8).write(to: archive)
            service.processUpload(atPath: archive.path, libraryFolder: library.path)
        }

        let summary = try XCTUnwrap(service.consumeSummary(defaultUploadCount: 2))
        XCTAssertTrue(summary.contains("2"), summary)
    }

    // MARK: - Orphan rescan

    func testOrphanRescanMovesRejectedArchiveAsideOnce() throws {
        let nested = library.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: nested.appendingPathComponent("Broken.zip"))

        let first = ZipImportHelper.processOrphanedArchives(inFolder: library.path)
        XCTAssertEqual(first.failedArchives, 1)
        XCTAssertNotNil(ZipImportHelper.snackbarText(for: first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rejected.appendingPathComponent("Broken.zip").path))

        let second = ZipImportHelper.processOrphanedArchives(inFolder: library.path)
        XCTAssertEqual(second.failedArchives, 0)
        XCTAssertNil(ZipImportHelper.snackbarText(for: second))
    }

    // MARK: - Helpers

    private func assertExternalFolderUnchanged(archive: URL, data: Data,
                                               file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path),
                       [archive.lastPathComponent], file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: archive), data, file: file, line: line)
    }

    /// A minimal uncompressed ("stored") ZIP. The test target doesn't link the Zip package.
    private static func storedZip(entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()

        func u16(_ v: Int, into d: inout Data) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func u32(_ v: UInt32, into d: inout Data) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(out.count)

            u32(0x0403_4B50, into: &out)
            u16(20, into: &out)          // version needed
            u16(0, into: &out)           // flags
            u16(0, into: &out)           // method: stored
            u16(0, into: &out)           // mod time
            u16(0x21, into: &out)        // mod date: 1980-01-01
            u32(crc, into: &out)
            u32(size, into: &out)
            u32(size, into: &out)
            u16(name.count, into: &out)
            u16(0, into: &out)           // extra length
            out.append(name)
            out.append(entry.data)

            u32(0x0201_4B50, into: &central)
            u16(0x031E, into: &central)  // made by: Unix, 3.0
            u16(20, into: &central)
            u16(0, into: &central)
            u16(0, into: &central)
            u16(0, into: &central)
            u16(0x21, into: &central)
            u32(crc, into: &central)
            u32(size, into: &central)
            u32(size, into: &central)
            u16(name.count, into: &central)
            u16(0, into: &central)       // extra length
            u16(0, into: &central)       // comment length
            u16(0, into: &central)       // disk number
            u16(0, into: &central)       // internal attributes
            u32(UInt32(0o100644) << 16, into: &central)
            u32(offset, into: &central)
            central.append(name)
        }

        let centralOffset = UInt32(out.count)
        out.append(central)
        u32(0x0605_4B50, into: &out)
        u16(0, into: &out)
        u16(0, into: &out)
        u16(entries.count, into: &out)
        u16(entries.count, into: &out)
        u32(UInt32(central.count), into: &out)
        u32(centralOffset, into: &out)
        u16(0, into: &out)
        return out
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return ~crc
    }
}
