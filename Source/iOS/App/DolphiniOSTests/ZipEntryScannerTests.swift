// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

/// Writes a zip by hand (stored entries, no compression) so a test can name entries the zip tools refuse to.
enum TestZipBuilder {
  struct Entry {
    var name: [UInt8]
    var contents = Data()
    var externalAttributes: UInt32 = 0
    /// Replaces the compressed-size field in the central directory (to plant a zip64 sentinel).
    var compressedSizeField: UInt32?

    init(name: String, contents: Data = Data(), externalAttributes: UInt32 = 0, compressedSizeField: UInt32? = nil) {
      self.name = Array(name.utf8)
      self.contents = contents
      self.externalAttributes = externalAttributes
      self.compressedSizeField = compressedSizeField
    }

    init(rawName: [UInt8], contents: Data = Data()) {
      name = rawName
      self.contents = contents
    }
  }

  static let unixSymlinkAttributes: UInt32 = 0o120777 << 16
  private static let versionMadeByUnix: UInt16 = 0x031E
  private static let versionNeeded: UInt16 = 20
  private static let dosDate: UInt16 = 0x2821

  static func build(_ entries: [Entry], comment: [UInt8] = []) -> Data {
    var archive = Data()
    var central = Data()
    for entry in entries {
      central.append(centralRecord(entry, localHeaderOffset: UInt32(archive.count)))
      archive.append(localRecord(entry))
    }
    let centralOffset = UInt32(archive.count)
    archive.append(central)
    archive.append(endRecord(entryCount: entries.count, centralDirectorySize: central.count, centralDirectoryOffset: centralOffset, comment: comment))
    return archive
  }

  static func localRecord(_ entry: Entry) -> Data {
    var record = Data()
    let size = UInt32(entry.contents.count)
    record.append(le32: 0x04034b50)
    record.append(le16: versionNeeded)
    record.append(le16: 0)
    record.append(le16: 0)
    record.append(le16: 0)
    record.append(le16: dosDate)
    record.append(le32: crc32(entry.contents))
    record.append(le32: size)
    record.append(le32: size)
    record.append(le16: UInt16(entry.name.count))
    record.append(le16: 0)
    record.append(contentsOf: entry.name)
    record.append(entry.contents)
    return record
  }

  static func centralRecord(_ entry: Entry, localHeaderOffset: UInt32) -> Data {
    var record = Data()
    let size = UInt32(entry.contents.count)
    record.append(le32: 0x02014b50)
    record.append(le16: versionMadeByUnix)
    record.append(le16: versionNeeded)
    record.append(le16: 0)
    record.append(le16: 0)
    record.append(le16: 0)
    record.append(le16: dosDate)
    record.append(le32: crc32(entry.contents))
    record.append(le32: entry.compressedSizeField ?? size)
    record.append(le32: size)
    record.append(le16: UInt16(entry.name.count))
    record.append(le16: 0)
    record.append(le16: 0)
    record.append(le16: 0)
    record.append(le16: 0)
    record.append(le32: entry.externalAttributes)
    record.append(le32: localHeaderOffset)
    record.append(contentsOf: entry.name)
    return record
  }

  static func endRecord(entryCount: Int, centralDirectorySize: Int, centralDirectoryOffset: UInt32, comment: [UInt8] = []) -> Data {
    var record = Data()
    record.append(le32: 0x06054b50)
    record.append(le16: 0)
    record.append(le16: 0)
    record.append(le16: UInt16(entryCount))
    record.append(le16: UInt16(entryCount))
    record.append(le32: UInt32(centralDirectorySize))
    record.append(le32: centralDirectoryOffset)
    record.append(le16: UInt16(comment.count))
    record.append(contentsOf: comment)
    return record
  }

  private static func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
    }
    return ~crc
  }
}

private extension Data {
  mutating func append(le16 value: UInt16) {
    append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)])
  }

  mutating func append(le32 value: UInt32) {
    append(contentsOf: (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) })
  }
}

final class ZipEntryScannerTests: XCTestCase {
  private func assertUnsafe(_ entries: [TestZipBuilder.Entry], file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try ZipEntryScanner.scan(TestZipBuilder.build(entries)), file: file, line: line) {
      guard case ZipEntryScannerError.unsafeEntry = $0 else { return XCTFail("expected unsafeEntry, got \($0)", file: file, line: line) }
    }
  }

  func testListsNamesOfANormalNestedArchive() throws {
    let data = TestZipBuilder.build([
      .init(name: "Skin/"),
      .init(name: "Skin/info.json", contents: Data("{}".utf8)),
      .init(name: "Skin/art/bg.png", contents: Data([1, 2, 3]))
    ])
    XCTAssertEqual(try ZipEntryScanner.scan(data).map(\.name), ["Skin/", "Skin/info.json", "Skin/art/bg.png"])
  }

  func testParsesPastATrailingComment() throws {
    let data = TestZipBuilder.build([.init(name: "a.txt")], comment: Array("a perfectly ordinary archive comment".utf8))
    XCTAssertEqual(try ZipEntryScanner.scan(data).map(\.name), ["a.txt"])
  }

  func testEmptyArchiveHasNoEntries() throws {
    XCTAssertEqual(try ZipEntryScanner.scan(TestZipBuilder.build([])), [])
  }

  func testRejectsParentComponent() {
    assertUnsafe([.init(name: "../escape.txt")])
    assertUnsafe([.init(name: "a/../../escape.txt")])
    assertUnsafe([.init(name: "a/..")])
  }

  func testRejectsBackslashParentComponent() {
    assertUnsafe([.init(name: "..\\escape.txt")])
    assertUnsafe([.init(name: "a\\..\\..\\escape.txt")])
  }

  func testRejectsAbsoluteAndDriveLetterPaths() {
    assertUnsafe([.init(name: "/abs.txt")])
    assertUnsafe([.init(name: "\\abs.txt")])
    assertUnsafe([.init(name: "C:/abs.txt")])
    assertUnsafe([.init(name: "c:\\abs.txt")])
  }

  /// Swift's String splits on grapheme clusters, so `/` + a combining mark is ONE Character; the kernel still sees `/`.
  func testRejectsParentComponentsThatFollowCombiningCharacters() {
    assertUnsafe([.init(name: "../\u{301}x")])
    assertUnsafe([.init(name: "../\u{200D}x")])
    assertUnsafe([.init(name: "a\u{600}/../\u{301}b")])
    assertUnsafe([.init(name: "..\\\u{301}x")])
    assertUnsafe([.init(name: "x\u{600}/../y")])
  }

  func testAllowsCombiningMarksInBenignNames() throws {
    let names = ["cafe\u{301}/art.png", "e\u{301}/\u{200D}x/..hidden"]
    XCTAssertEqual(try ZipEntryScanner.scan(TestZipBuilder.build(names.map { .init(name: $0) })).map(\.name), names)
  }

  func testRejectsParentHiddenBehindANulByte() {
    assertUnsafe([.init(rawName: Array("..".utf8) + [0] + Array("/x".utf8))])
  }

  func testAllowsDotsThatAreNotParentComponents() throws {
    let names = ["..hidden", "a/b..c", "a/./b.txt", "name with spaces.json"]
    XCTAssertEqual(try ZipEntryScanner.scan(TestZipBuilder.build(names.map { .init(name: $0) })).map(\.name), names)
  }

  func testRejectsSymlinkEntries() {
    assertUnsafe([.init(name: "link", contents: Data("/etc/passwd".utf8), externalAttributes: TestZipBuilder.unixSymlinkAttributes)])
  }

  func testRejectsZip64Sentinels() {
    XCTAssertThrowsError(try ZipEntryScanner.scan(TestZipBuilder.build([.init(name: "big", compressedSizeField: 0xFFFF_FFFF)]))) {
      XCTAssertEqual($0 as? ZipEntryScannerError, .zip64Unsupported)
    }
  }

  func testRejectsTruncatedAndNonZipData() {
    let data = TestZipBuilder.build([.init(name: "a.txt", contents: Data(count: 40))])
    XCTAssertThrowsError(try ZipEntryScanner.scan(Data("definitely not a zip file".utf8))) {
      XCTAssertEqual($0 as? ZipEntryScannerError, .notAZip)
    }
    XCTAssertThrowsError(try ZipEntryScanner.scan(data.prefix(data.count - 10))) {
      XCTAssertEqual($0 as? ZipEntryScannerError, .truncated, "the end-of-central-directory record is cut short")
    }
    XCTAssertThrowsError(try ZipEntryScanner.scan(data.prefix(data.count - 22))) {
      XCTAssertEqual($0 as? ZipEntryScannerError, .notAZip, "the end-of-central-directory record is gone")
    }
    var damaged = data
    damaged.replaceSubrange((data.count - 22 + 16)..<(data.count - 22 + 20), with: [0xFF, 0x00, 0x00, 0x00])
    XCTAssertThrowsError(try ZipEntryScanner.scan(damaged)) {
      XCTAssertEqual($0 as? ZipEntryScannerError, .inconsistentDirectory, "the central directory offset no longer meets the end record")
    }
  }

  // MARK: - Differential cases: archives the bundled minizip would read differently than a naive scanner

  private static let benign = TestZipBuilder.Entry(name: "info.json", contents: Data("{}".utf8))
  private static let hostile = TestZipBuilder.Entry(name: "../../a.b", contents: Data("owned".utf8))

  /// A real archive whose end-record COMMENT carries a hostile central directory and a second end record.
  /// minizip opens the LAST end record (unzip.c:294-351), i.e. the one inside the comment.
  private func archiveWithHiddenDirectory(trailing: [UInt8]) -> Data {
    let local = TestZipBuilder.localRecord(Self.benign)
    let benignDirectory = TestZipBuilder.centralRecord(Self.benign, localHeaderOffset: 0)
    let hostileDirectory = TestZipBuilder.centralRecord(Self.hostile, localHeaderOffset: 0)
    let hostileDirectoryOffset = local.count + benignDirectory.count + 22
    let fakeEnd = TestZipBuilder.endRecord(entryCount: 1, centralDirectorySize: hostileDirectory.count, centralDirectoryOffset: UInt32(hostileDirectoryOffset))
    var archive = local
    archive.append(benignDirectory)
    archive.append(TestZipBuilder.endRecord(entryCount: 1, centralDirectorySize: benignDirectory.count, centralDirectoryOffset: UInt32(local.count),
                                            comment: Array(hostileDirectory) + Array(fakeEnd) + trailing))
    return archive
  }

  func testRejectsFakeEndRecordInsideTheComment() {
    XCTAssertThrowsError(try ZipEntryScanner.scan(archiveWithHiddenDirectory(trailing: [0x78, 0x78, 0x78]))) {
      XCTAssertEqual($0 as? ZipEntryScannerError, .inconsistentDirectory, "the last end record's comment does not reach the end of the data")
    }
  }

  func testScansTheDirectoryOfAFakeEndRecordThatReachesTheEnd() {
    XCTAssertThrowsError(try ZipEntryScanner.scan(archiveWithHiddenDirectory(trailing: []))) {
      guard case ZipEntryScannerError.unsafeEntry = $0 else { return XCTFail("expected unsafeEntry, got \($0)") }
    }
  }

  func testRejectsGapBetweenDirectoryAndEndRecord() {
    let local = TestZipBuilder.localRecord(Self.benign)
    let benignDirectory = TestZipBuilder.centralRecord(Self.benign, localHeaderOffset: 0)
    let hostileDirectory = TestZipBuilder.centralRecord(Self.hostile, localHeaderOffset: 0)
    XCTAssertEqual(benignDirectory.count, hostileDirectory.count, "same size, so minizip's central_pos - size lands on the hostile one")
    var archive = local
    archive.append(benignDirectory)
    archive.append(hostileDirectory)
    archive.append(TestZipBuilder.endRecord(entryCount: 1, centralDirectorySize: benignDirectory.count, centralDirectoryOffset: UInt32(local.count)))
    XCTAssertThrowsError(try ZipEntryScanner.scan(archive)) {
      XCTAssertEqual($0 as? ZipEntryScannerError, .inconsistentDirectory)
    }
  }

  func testRejectsEntryCountThatDisagreesWithTheDirectory() {
    let local = TestZipBuilder.localRecord(Self.benign)
    let directory = TestZipBuilder.centralRecord(Self.benign, localHeaderOffset: 0)
    for claimed in [0, 2] {
      var archive = local
      archive.append(directory)
      archive.append(TestZipBuilder.endRecord(entryCount: claimed, centralDirectorySize: directory.count, centralDirectoryOffset: UInt32(local.count)))
      XCTAssertThrowsError(try ZipEntryScanner.scan(archive), "claimed \(claimed)") {
        XCTAssertEqual($0 as? ZipEntryScannerError, .inconsistentDirectory)
      }
    }
  }

  func testScansAFileOnDisk() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZipEntryScannerTests-\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: url) }
    try TestZipBuilder.build([.init(name: "a.txt")]).write(to: url)
    XCTAssertEqual(try ZipEntryScanner.scan(fileAt: url).map(\.name), ["a.txt"])
  }
}
