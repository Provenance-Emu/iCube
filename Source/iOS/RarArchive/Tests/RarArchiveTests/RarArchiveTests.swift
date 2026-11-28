// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import RarArchive

/// The archives are libarchive's own test files (BSD 2-clause).
final class RarArchiveTests: XCTestCase {
  private var destination: URL!

  override func setUpWithError() throws {
    destination = FileManager.default.temporaryDirectory.appendingPathComponent("rar-tests-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: destination)
  }

  private func fixture(_ name: String) throws -> URL {
    try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "rar", subdirectory: "Fixtures"))
  }

  private func text(_ relative: String) throws -> String {
    try String(contentsOf: destination.appendingPathComponent(relative), encoding: .utf8)
  }

  private func scratchFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-rar-\(UUID().uuidString).rar")
    try data.write(to: url)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func testRecognisesBothSignaturesAndNothingElse() throws {
    XCTAssertTrue(RarArchive.isRarFile(at: try fixture("test_read_format_rar")))
    XCTAssertTrue(RarArchive.isRarFile(at: try fixture("test_read_format_rar5_stored")))
    XCTAssertFalse(RarArchive.isRarFile(at: try scratchFile(Data("PK\u{3}\u{4}".utf8))))
  }

  func testListsARar4Archive() throws {
    let entries = try RarArchive.entries(ofArchiveAt: try fixture("test_read_format_rar"))
    XCTAssertEqual(entries.map(\.path), ["test.txt", "testlink", "testdir/test.txt", "testdir", "testemptydir"])
    XCTAssertEqual(entries.map(\.isRegularFile), [true, false, true, false, false])
    XCTAssertEqual(entries[0].size, 20)
    XCTAssertTrue(entries[3].isDirectory)
  }

  func testExtractsStoredRar4FilesAndSkipsTheLink() throws {
    let written = try RarArchive.extract(archiveAt: try fixture("test_read_format_rar"), to: destination)
    XCTAssertEqual(written.map(\.lastPathComponent), ["test.txt", "test.txt"])
    XCTAssertEqual(try text("test.txt"), "test text document\r\n")
    XCTAssertEqual(try text("testdir/test.txt"), "test text document\r\n")
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("testlink").path))
  }

  func testExtractsCompressedRar4() throws {
    try RarArchive.extract(archiveAt: try fixture("test_read_format_rar_compress_normal"), to: destination)
    let html = try Data(contentsOf: destination.appendingPathComponent("LibarchiveAddingTest.html"))
    XCTAssertEqual(html.count, 20111)
    XCTAssertTrue(String(decoding: html.prefix(64), as: UTF8.self).hasPrefix("<!DOCTYPE HTML PUBLIC"))
    XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("testdir/LibarchiveAddingTest.html")), html)
  }

  func testExtractsRar5StoredCompressedAndSolid() throws {
    try RarArchive.extract(archiveAt: try fixture("test_read_format_rar5_stored"), to: destination)
    XCTAssertEqual(try text("helloworld.txt"), "hello libarchive test suite!\n")

    try RarArchive.extract(archiveAt: try fixture("test_read_format_rar5_compressed"), to: destination)
    XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("test.bin")).count, 1200)

    let solid = try RarArchive.extract(archiveAt: try fixture("test_read_format_rar5_solid"), to: destination)
    XCTAssertEqual(solid.count, 7)
    XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("test6.bin")).count, 4096)
  }

  func testRar5LinksAreNotWritten() throws {
    let written = try RarArchive.extract(archiveAt: try fixture("test_read_format_rar5_symlink"), to: destination)
    XCTAssertEqual(written.map(\.lastPathComponent), ["file.txt"])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["file.txt"])
  }

  func testKeepsUnicodeNames() throws {
    let paths = try RarArchive.entries(ofArchiveAt: try fixture("test_read_format_rar_unicode")).map(\.path)
    XCTAssertTrue(paths.contains { $0.precomposedStringWithCanonicalMapping == "abcdefghijklmnopqrsテスト.txt" }, "\(paths)")
    XCTAssertFalse(paths.contains { $0.contains("?") }, "\(paths)")
  }

  func testEncryptedArchivesAreRefusedAndWriteNothing() throws {
    for name in ["test_read_format_rar4_encrypted", "test_read_format_rar5_encrypted"] {
      XCTAssertThrowsError(try RarArchive.extract(archiveAt: try fixture(name), to: destination), name) { error in
        XCTAssertEqual(error as? RarArchive.Failure, .encrypted, name)
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("a.txt").path))
  }

  func testRefusesAnArchiveLargerThanTheLimit() throws {
    let archive = try fixture("test_read_format_rar5_solid")
    XCTAssertThrowsError(try RarArchive.extract(archiveAt: archive, to: destination, maximumBytes: 4096)) {
      XCTAssertEqual($0 as? RarArchive.Failure, .tooLarge(limit: 4096))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("test.bin").path))
  }

  func testAFileThatIsNotRarCannotBeOpened() throws {
    XCTAssertThrowsError(try RarArchive.entries(ofArchiveAt: try scratchFile(Data(repeating: 0x41, count: 4096))))
  }
}
