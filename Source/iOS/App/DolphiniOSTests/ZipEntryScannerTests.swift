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
      let crc = crc32(entry.contents)
      let size = UInt32(entry.contents.count)
      let offset = UInt32(archive.count)
      archive.append(le32: 0x04034b50)
      archive.append(le16: versionNeeded)
      archive.append(le16: 0)
      archive.append(le16: 0)
      archive.append(le16: 0)
      archive.append(le16: dosDate)
      archive.append(le32: crc)
      archive.append(le32: size)
      archive.append(le32: size)
      archive.append(le16: UInt16(entry.name.count))
      archive.append(le16: 0)
      archive.append(contentsOf: entry.name)
      archive.append(entry.contents)

      central.append(le32: 0x02014b50)
      central.append(le16: versionMadeByUnix)
      central.append(le16: versionNeeded)
      central.append(le16: 0)
      central.append(le16: 0)
      central.append(le16: 0)
      central.append(le16: dosDate)
      central.append(le32: crc)
      central.append(le32: entry.compressedSizeField ?? size)
      central.append(le32: size)
      central.append(le16: UInt16(entry.name.count))
      central.append(le16: 0)
      central.append(le16: 0)
      central.append(le16: 0)
      central.append(le16: 0)
      central.append(le32: entry.externalAttributes)
      central.append(le32: offset)
      central.append(contentsOf: entry.name)
    }
    let centralOffset = UInt32(archive.count)
    archive.append(central)
    archive.append(le32: 0x06054b50)
    archive.append(le16: 0)
    archive.append(le16: 0)
    archive.append(le16: UInt16(entries.count))
    archive.append(le16: UInt16(entries.count))
    archive.append(le32: UInt32(central.count))
    archive.append(le32: centralOffset)
    archive.append(le16: UInt16(comment.count))
    archive.append(contentsOf: comment)
    return archive
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
    let data = TestZipBuilder.build([.init(name: "a.txt")], comment: Array("a comment, PK\u{5}\u{6} and all".utf8))
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
      XCTAssertEqual($0 as? ZipEntryScannerError, .notAZip, "the end-of-central-directory record is gone")
    }
    var damaged = data
    damaged.replaceSubrange((data.count - 22 + 16)..<(data.count - 22 + 20), with: [0xFF, 0x00, 0x00, 0x00])
    XCTAssertThrowsError(try ZipEntryScanner.scan(damaged)) {
      XCTAssertEqual($0 as? ZipEntryScannerError, .truncated, "the central directory offset points past the data")
    }
  }

  func testScansAFileOnDisk() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZipEntryScannerTests-\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: url) }
    try TestZipBuilder.build([.init(name: "a.txt")]).write(to: url)
    XCTAssertEqual(try ZipEntryScanner.scan(fileAt: url).map(\.name), ["a.txt"])
  }
}
