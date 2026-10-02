// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

/// Writes a tar by hand so a test controls every header field, including the entry types and names a tar tool refuses to write.
enum TestTarBuilder {
  struct Entry {
    var name: String
    var type = UInt8(ascii: "0")
    var linkName = ""
    var contents = Data()
  }

  static let symlinkType = UInt8(ascii: "2")
  static let hardLinkType = UInt8(ascii: "1")
  static let directoryType = UInt8(ascii: "5")
  private static let blockSize = 512
  private static let checksumOffset = 148
  private static let checksumFieldSize = 8
  private static let sizeFieldWidth = 11

  static func build(_ entries: [Entry]) -> Data {
    var archive = Data()
    for entry in entries {
      archive.append(header(for: entry))
      archive.append(entry.contents)
      archive.append(Data(count: (blockSize - entry.contents.count % blockSize) % blockSize))
    }
    archive.append(Data(count: 2 * blockSize))
    return archive
  }

  private static func header(for entry: Entry) -> Data {
    var header = [UInt8](repeating: 0, count: blockSize)
    func put(_ text: String, at offset: Int) {
      for (index, byte) in text.utf8.enumerated() { header[offset + index] = byte }
    }
    put(entry.name, at: 0)
    put("0000644", at: 100)
    put("0000000", at: 108)
    put("0000000", at: 116)
    put(String(entry.contents.count, radix: 8).leftPadded(to: sizeFieldWidth), at: 124)
    put("00000000000", at: 136)
    put(String(repeating: " ", count: checksumFieldSize), at: checksumOffset)
    header[156] = entry.type
    put(entry.linkName, at: 157)
    put("ustar", at: 257)
    put("00", at: 263)
    let checksum = header.reduce(0) { $0 + Int($1) }
    put(String(checksum, radix: 8).leftPadded(to: 6), at: checksumOffset)
    header[checksumOffset + 6] = 0
    header[checksumOffset + 7] = UInt8(ascii: " ")
    return Data(header)
  }
}

private extension String {
  func leftPadded(to width: Int) -> String {
    String(repeating: "0", count: max(0, width - count)) + self
  }
}

/// Every archive format reaches `ZipImportHelper.extractArchive(at:to:)`, the call the import paths make, so these tests
/// exercise the copy, the checks and the extraction together. Archives are extracted into `root/dest`, which makes
/// `root/escape.txt` the place a `../escape.txt` entry would land.
final class ZipImportHelperTests: XCTestCase {
  private var root: URL!
  private var destination: URL { root.appendingPathComponent("dest", isDirectory: true) }
  private var escapedFile: URL { root.appendingPathComponent("escape.txt") }
  private var staleDirectoriesBefore = Set<String>()

  private static let stagingPrefixes = ["dol_archive_source-", "dol_archive_import-"]
  /// `7z a` of `ok/game.iso` (contents "game\n"), headers stored uncompressed.
  private static let sevenZipFixture = "N3q8ryccAARqxdxxBQAAAAAAAABSAAAAAAAAAEcJw1RnYW1lCgEEBgABCQUABwsBAAEBAAwFAAgKAani+tYAAAUBERkAbwBrAC8AZwBhAG0AZQAuAGkAcwBvAAAAGQIAABQKAQAAmOf7FlLdARUGAQAggKSBAAA="
  /// The same archive with the stored name `AA/escape.txt` rewritten to `../escape.txt` (header CRCs recomputed).
  private static let hostileSevenZipFixture = "N3q8ryccAARJoG80CAAAAAAAAABSAAAAAAAAAF59QUdlc2NhcGVkCgEEBgABCQgABwsBAAEBAAwIAAgKAeN2/M4AAAUBER0ALgAuAC8AZQBzAGMAYQBwAGUALgB0AHgAdAAAABQKAQAAmOf7FlLdARUGAQAggKSBAAA="
  /// `xz -k game.iso` (contents "game\n").
  private static let xzFixture = "/Td6WFoAAATm1rRGBMAJBSEBFgAAAAAAAAAAAL95JWcBAARnYW1lCgAAAADvE8hnXREDkAABJQVDkR+4H7bzfQEAAAAABFla"

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("ZipImportHelperTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("in", isDirectory: true), withIntermediateDirectories: true)
    staleDirectoriesBefore = stagingDirectories()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: - Helpers

  private func stagingDirectories() -> Set<String> {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
    return Set(names.filter { name in Self.stagingPrefixes.contains { name.hasPrefix($0) } })
  }

  private func write(_ data: Data, as name: String) throws -> URL {
    let url = root.appendingPathComponent("in", isDirectory: true).appendingPathComponent(name)
    try data.write(to: url)
    return url
  }

  private func extract(_ data: Data, as name: String) throws {
    try ZipImportHelper.extractArchive(at: try write(data, as: name), to: destination)
  }

  private func destinationContents() -> [String] {
    let enumerator = FileManager.default.enumerator(atPath: destination.path)
    return (enumerator?.allObjects as? [String] ?? []).sorted()
  }

  private func assertRejectedAsUnsafe(_ data: Data, as name: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try extract(data, as: name), file: file, line: line) {
      guard case ZipEntryScannerError.unsafeEntry = $0 else { return XCTFail("expected unsafeEntry, got \($0)", file: file, line: line) }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: escapedFile.path), "an entry was written outside the destination", file: file, line: line)
    XCTAssertEqual(destinationContents(), [], "a rejected archive must leave nothing behind", file: file, line: line)
    XCTAssertEqual(stagingDirectories(), staleDirectoriesBefore, "the private copy was not cleaned up", file: file, line: line)
  }

  private func contents(of relativePath: String) -> String? {
    (try? Data(contentsOf: destination.appendingPathComponent(relativePath))).flatMap { String(data: $0, encoding: .utf8) }
  }

  // MARK: - Zip

  func testExtractsABenignZip() throws {
    let archive = TestZipBuilder.build([.init(name: "Game/"), .init(name: "Game/disc.iso", contents: Data("disc".utf8))])
    try extract(archive, as: "game.zip")
    XCTAssertEqual(contents(of: "Game/disc.iso"), "disc")
    XCTAssertEqual(stagingDirectories(), staleDirectoriesBefore)
  }

  func testRejectsAZipEntryThatEscapesTheDestination() {
    assertRejectedAsUnsafe(TestZipBuilder.build([.init(name: "ok.iso", contents: Data("ok".utf8)), .init(name: "../escape.txt", contents: Data("x".utf8))]), as: "hostile.zip")
  }

  func testRejectsABackslashZipEntryThatEscapesTheDestination() {
    assertRejectedAsUnsafe(TestZipBuilder.build([.init(name: "..\\escape.txt", contents: Data("x".utf8))]), as: "hostile.zip")
  }

  func testRejectsAZipSymlinkEntry() {
    assertRejectedAsUnsafe(TestZipBuilder.build([.init(name: "link.iso", contents: Data("/etc/hosts".utf8), externalAttributes: TestZipBuilder.unixSymlinkAttributes)]), as: "hostile.zip")
  }

  func testLeavesTheSourceArchiveUntouched() throws {
    let archive = TestZipBuilder.build([.init(name: "disc.iso", contents: Data("disc".utf8))])
    let url = try write(archive, as: "game.zip")
    try ZipImportHelper.extractArchive(at: url, to: destination)
    XCTAssertEqual(try Data(contentsOf: url), archive)
  }

  // MARK: - Tar

  private func tar(_ entries: [TestTarBuilder.Entry]) -> Data {
    TestTarBuilder.build(entries)
  }

  func testExtractsABenignTar() throws {
    try extract(tar([.init(name: "Game/", type: TestTarBuilder.directoryType), .init(name: "Game/disc.iso", contents: Data("disc".utf8))]), as: "game.tar")
    XCTAssertEqual(contents(of: "Game/disc.iso"), "disc")
  }

  func testRejectsATarEntryThatEscapesTheDestination() {
    assertRejectedAsUnsafe(tar([.init(name: "ok.iso", contents: Data("ok".utf8)), .init(name: "../escape.txt", contents: Data("x".utf8))]), as: "hostile.tar")
  }

  func testRejectsATarEntryWithAnEmbeddedParentComponent() {
    assertRejectedAsUnsafe(tar([.init(name: "a/../../escape.txt", contents: Data("x".utf8))]), as: "hostile.tar")
  }

  func testRejectsATarSymlinkEntry() {
    assertRejectedAsUnsafe(tar([.init(name: "ok.iso", contents: Data("ok".utf8)), .init(name: "link.iso", type: TestTarBuilder.symlinkType, linkName: "/etc/hosts")]), as: "hostile.tar")
  }

  func testRejectsATarSymlinkEntryWithABenignTarget() {
    assertRejectedAsUnsafe(tar([.init(name: "link.iso", type: TestTarBuilder.symlinkType, linkName: "disc.iso")]), as: "hostile.tar")
  }

  func testRejectsATarHardLinkEntry() {
    assertRejectedAsUnsafe(tar([.init(name: "link.iso", type: TestTarBuilder.hardLinkType, linkName: "../escape.txt")]), as: "hostile.tar")
  }

  func testStripsALeadingSlashFromATarEntryAsBefore() throws {
    try extract(tar([.init(name: "/disc.iso", contents: Data("disc".utf8))]), as: "game.tar")
    XCTAssertEqual(destinationContents(), ["disc.iso"])
  }

  func testSkipsTarEntriesNamedLikeTheDestinationItself() throws {
    let entries: [TestTarBuilder.Entry] = [.init(name: ".", contents: Data("x".utf8)), .init(name: "./", contents: Data("x".utf8)), .init(name: "disc.iso", contents: Data("disc".utf8)),
                                           .init(name: "", contents: Data("x".utf8)), .init(name: "last.iso", contents: Data("last".utf8))]
    try extract(tar(entries), as: "game.tar")
    XCTAssertEqual(destinationContents(), ["disc.iso", "last.iso"])
  }

  // MARK: - 7z and xz

  func testExtractsABenign7z() throws {
    try extract(try XCTUnwrap(Data(base64Encoded: Self.sevenZipFixture)), as: "game.7z")
    XCTAssertEqual(contents(of: "ok/game.iso"), "game\n")
  }

  func testRejectsA7zItemThatEscapesTheDestination() throws {
    assertRejectedAsUnsafe(try XCTUnwrap(Data(base64Encoded: Self.hostileSevenZipFixture)), as: "hostile.7z")
  }

  func testExtractsAnXzFileUnderTheSourceName() throws {
    try extract(try XCTUnwrap(Data(base64Encoded: Self.xzFixture)), as: "game.iso.xz")
    XCTAssertEqual(contents(of: "game.iso"), "game\n")
  }

  func testRejectsHostileItemPaths() {
    for path in ["../escape.txt", "a/../../escape.txt", "..\\escape.txt", "C:/escape.txt", "/escape.txt"] {
      XCTAssertThrowsError(try ZipImportHelper.validateItemPaths([path]), path) {
        XCTAssertEqual($0 as? ZipEntryScannerError, .unsafeEntry(path))
      }
    }
    XCTAssertNoThrow(try ZipImportHelper.validateItemPaths(["Game/disc.iso", "a..b/c", "", "Game/"]))
  }

  // MARK: - End to end

  func testImportReportsAnUnsafeArchiveWithItsOwnMessage() throws {
    let software = root.appendingPathComponent("software", isDirectory: true)
    try FileManager.default.createDirectory(at: software, withIntermediateDirectories: true)
    let escapeName = "zs-escape-\(UUID().uuidString).txt"
    let escapedInTemp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(escapeName)
    addTeardownBlock { try? FileManager.default.removeItem(at: escapedInTemp) }
    let archive = TestZipBuilder.build([.init(name: "game.iso", contents: Data("disc".utf8)), .init(name: "../\(escapeName)", contents: Data("x".utf8))])
    let result = ZipImportHelper.importArchive(atPath: try write(archive, as: "hostile.zip").path, toFolder: software.path)
    XCTAssertEqual(result.errorMessage, ZipImportHelper.unsafeArchiveMessage)
    XCTAssertEqual(result.importedCount, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: escapedInTemp.path))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: software.path), [])
  }

  func testImportReportsAnUnsupportedLayoutWithoutCallingItCorrupt() throws {
    let software = root.appendingPathComponent("software", isDirectory: true)
    try FileManager.default.createDirectory(at: software, withIntermediateDirectories: true)
    let archive = TestZipBuilder.build([.init(name: "game.iso", contents: Data("disc".utf8), diskStart: 1)])
    let result = ZipImportHelper.importArchive(atPath: try write(archive, as: "split.zip").path, toFolder: software.path)
    XCTAssertEqual(result.errorMessage, ZipImportHelper.unsupportedLayoutMessage)
    XCTAssertFalse(try XCTUnwrap(result.errorMessage).localizedCaseInsensitiveContains("corrupt"))
  }

  func testImportStillImportsABenignZip() throws {
    let software = root.appendingPathComponent("software", isDirectory: true)
    try FileManager.default.createDirectory(at: software, withIntermediateDirectories: true)
    let archive = TestZipBuilder.build([.init(name: "Game/"), .init(name: "Game/disc.iso", contents: Data("disc".utf8))])
    let result = ZipImportHelper.importArchive(atPath: try write(archive, as: "game.zip").path, toFolder: software.path)
    XCTAssertNil(result.errorMessage)
    XCTAssertEqual(result.importedCount, 1)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: software.path), ["disc.iso"])
  }
}
