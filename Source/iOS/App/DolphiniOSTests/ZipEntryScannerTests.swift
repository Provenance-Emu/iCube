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
    /// Puts 0xFFFFFFFF in the central directory's sizes and offset and the real values in a zip64 extra field.
    var zip64Fields = false
    var diskStart: UInt16 = 0

    init(name: String, contents: Data = Data(), externalAttributes: UInt32 = 0, zip64Fields: Bool = false, diskStart: UInt16 = 0) {
      self.name = Array(name.utf8)
      self.contents = contents
      self.externalAttributes = externalAttributes
      self.zip64Fields = zip64Fields
      self.diskStart = diskStart
    }

    init(rawName: [UInt8], contents: Data = Data()) {
      name = rawName
      self.contents = contents
    }
  }

  /// The zip64 end record, locator and plain end record fields a test may falsify. `nil` means "the true value".
  struct Zip64Tail {
    var entriesOnDisk: UInt64?
    var totalEntries: UInt64?
    var centralDirectorySize: UInt64?
    var disk: UInt32 = 0
    var centralDirectoryDisk: UInt32 = 0
    /// Counted in the zip64 end record's size field, as the format allows.
    var extensibleData = Data()
    /// Written between the zip64 end record and the locator without being counted in the record's size.
    var uncountedBytes = Data()
    var locatorDisk: UInt32 = 0
    var totalDisks: UInt32 = 1
    var endRecordOffset: UInt64?
    /// The plain end record's fields. The defaults are what `zip -fz` writes: real count and size, offset 0xFFFFFFFF.
    var plainEntryCount: Int?
    var plainCentralDirectorySize: Int?
    var plainCentralDirectoryOffset: UInt32 = TestZipBuilder.zip64Marker32
  }

  static let unixSymlinkAttributes: UInt32 = 0o120777 << 16
  static let zip64Marker16 = 0xFFFF
  static let zip64Marker32: UInt32 = 0xFFFF_FFFF
  static let zip64EndRecordSize = 56
  static let zip64LocatorSize = 20
  static let endRecordSize = 22
  private static let zip64ExtraFieldID: UInt16 = 0x0001
  /// The zip64 end record's size field leaves out its signature and the field itself.
  private static let zip64EndRecordUncountedSize = 12
  private static let versionMadeByUnix: UInt16 = 0x031E
  private static let versionNeeded: UInt16 = 20
  private static let versionNeededZip64: UInt16 = 45
  private static let dosDate: UInt16 = 0x2821

  static func build(_ entries: [Entry], comment: [UInt8] = []) -> Data {
    var archive = Data()
    var central = Data()
    for entry in entries {
      central.append(centralRecord(entry, localHeaderOffset: UInt64(archive.count)))
      archive.append(localRecord(entry))
    }
    let centralOffset = UInt32(archive.count)
    archive.append(central)
    archive.append(endRecord(entryCount: entries.count, centralDirectorySize: central.count, centralDirectoryOffset: centralOffset, comment: comment))
    return archive
  }

  /// A zip64 archive whose first byte will sit at `baseOffset` in the file (the bytes before it are left to the caller).
  static func buildZip64(_ entries: [Entry], tail: Zip64Tail = Zip64Tail(), comment: [UInt8] = [], baseOffset: UInt64 = 0) -> Data {
    var archive = Data()
    var central = Data()
    for entry in entries {
      central.append(centralRecord(entry, localHeaderOffset: baseOffset + UInt64(archive.count)))
      archive.append(localRecord(entry))
    }
    archive.append(zip64Directory(central, entryCount: entries.count, centralDirectoryOffset: baseOffset + UInt64(archive.count), tail: tail, comment: comment))
    return archive
  }

  /// The central directory followed by the zip64 end record, the zip64 locator and the plain end record.
  static func zip64Directory(_ central: Data, entryCount: Int, centralDirectoryOffset: UInt64, tail: Zip64Tail = Zip64Tail(), comment: [UInt8] = []) -> Data {
    let recordOffset = centralDirectoryOffset + UInt64(central.count)
    var bytes = central
    bytes.append(le32: 0x06064b50)
    bytes.append(le64: UInt64(zip64EndRecordSize - zip64EndRecordUncountedSize + tail.extensibleData.count))
    bytes.append(le16: versionMadeByUnix)
    bytes.append(le16: versionNeededZip64)
    bytes.append(le32: tail.disk)
    bytes.append(le32: tail.centralDirectoryDisk)
    bytes.append(le64: tail.entriesOnDisk ?? UInt64(entryCount))
    bytes.append(le64: tail.totalEntries ?? UInt64(entryCount))
    bytes.append(le64: tail.centralDirectorySize ?? UInt64(central.count))
    bytes.append(le64: centralDirectoryOffset)
    bytes.append(tail.extensibleData)
    bytes.append(tail.uncountedBytes)
    bytes.append(le32: 0x07064b50)
    bytes.append(le32: tail.locatorDisk)
    bytes.append(le64: tail.endRecordOffset ?? recordOffset)
    bytes.append(le32: tail.totalDisks)
    bytes.append(endRecord(entryCount: tail.plainEntryCount ?? entryCount, centralDirectorySize: tail.plainCentralDirectorySize ?? central.count,
                           centralDirectoryOffset: tail.plainCentralDirectoryOffset, comment: comment))
    return bytes
  }

  static func localRecord(_ entry: Entry) -> Data {
    var record = Data()
    let size = UInt32(entry.contents.count)
    record.append(le32: 0x04034b50)
    record.append(le16: entry.zip64Fields ? versionNeededZip64 : versionNeeded)
    record.append(le16: 0)
    record.append(le16: 0)
    record.append(le16: 0)
    record.append(le16: dosDate)
    record.append(le32: crc32(entry.contents))
    record.append(le32: entry.zip64Fields ? zip64Marker32 : size)
    record.append(le32: entry.zip64Fields ? zip64Marker32 : size)
    record.append(le16: UInt16(entry.name.count))
    let extra = entry.zip64Fields ? zip64Extra([UInt64(size), UInt64(size)]) : Data()
    record.append(le16: UInt16(extra.count))
    record.append(contentsOf: entry.name)
    record.append(extra)
    record.append(entry.contents)
    return record
  }

  static func centralRecord(_ entry: Entry, localHeaderOffset: UInt64) -> Data {
    var record = Data()
    let size = UInt32(entry.contents.count)
    let extra = entry.zip64Fields ? zip64Extra([UInt64(size), UInt64(size), localHeaderOffset]) : Data()
    record.append(le32: 0x02014b50)
    record.append(le16: versionMadeByUnix)
    record.append(le16: entry.zip64Fields ? versionNeededZip64 : versionNeeded)
    record.append(le16: 0)
    record.append(le16: 0)
    record.append(le16: 0)
    record.append(le16: dosDate)
    record.append(le32: crc32(entry.contents))
    record.append(le32: entry.zip64Fields ? zip64Marker32 : size)
    record.append(le32: entry.zip64Fields ? zip64Marker32 : size)
    record.append(le16: UInt16(entry.name.count))
    record.append(le16: UInt16(extra.count))
    record.append(le16: 0)
    record.append(le16: entry.diskStart)
    record.append(le16: 0)
    record.append(le32: entry.externalAttributes)
    record.append(le32: entry.zip64Fields ? zip64Marker32 : UInt32(localHeaderOffset))
    record.append(contentsOf: entry.name)
    record.append(extra)
    return record
  }

  static func endRecord(entryCount: Int, centralDirectorySize: Int, centralDirectoryOffset: UInt32, comment: [UInt8] = [], disk: UInt16 = 0) -> Data {
    var record = Data()
    record.append(le32: 0x06054b50)
    record.append(le16: disk)
    record.append(le16: disk)
    record.append(le16: UInt16(entryCount))
    record.append(le16: UInt16(entryCount))
    record.append(le32: UInt32(centralDirectorySize))
    record.append(le32: centralDirectoryOffset)
    record.append(le16: UInt16(comment.count))
    record.append(contentsOf: comment)
    return record
  }

  private static func zip64Extra(_ values: [UInt64]) -> Data {
    var extra = Data()
    extra.append(le16: zip64ExtraFieldID)
    extra.append(le16: UInt16(values.count * MemoryLayout<UInt64>.size))
    values.forEach { extra.append(le64: $0) }
    return extra
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

  mutating func append(le64 value: UInt64) {
    append(contentsOf: (0..<8).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) })
  }
}

/// An archive held in memory.
private struct DataByteSource: ZipByteSource {
  let data: Data

  init(_ data: Data) {
    self.data = Data(data) // zero-based indices whatever slice the caller passed
  }

  var size: UInt64 { UInt64(data.count) }

  func read(at offset: UInt64, count: Int) throws -> Data {
    guard offset <= size, UInt64(count) <= size - offset else { throw ZipEntryScannerError.truncated }
    return data.subdata(in: Int(offset)..<(Int(offset) + count))
  }
}

/// Counts the bytes the scanner asks for, to prove it reads only the end of the archive and the central directory.
private final class CountingByteSource: ZipByteSource {
  private let base: ZipByteSource
  private(set) var bytesRead = 0

  init(_ base: ZipByteSource) {
    self.base = base
  }

  var size: UInt64 { base.size }

  func read(at offset: UInt64, count: Int) throws -> Data {
    bytesRead += count
    return try base.read(at: offset, count: count)
  }
}

final class ZipEntryScannerTests: XCTestCase {
  private func scan(_ data: Data) throws -> [ZipEntry] {
    try ZipEntryScanner.scan(DataByteSource(data))
  }

  private func assertRejects(_ data: Data, _ expected: ZipEntryScannerError, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try scan(data), message, file: file, line: line) {
      XCTAssertEqual($0 as? ZipEntryScannerError, expected, message, file: file, line: line)
    }
  }

  private func assertUnsafe(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try scan(data), file: file, line: line) {
      guard case ZipEntryScannerError.unsafeEntry = $0 else { return XCTFail("expected unsafeEntry, got \($0)", file: file, line: line) }
    }
  }

  private func assertUnsafe(_ entries: [TestZipBuilder.Entry], file: StaticString = #filePath, line: UInt = #line) {
    assertUnsafe(TestZipBuilder.build(entries), file: file, line: line)
  }

  func testListsNamesOfANormalNestedArchive() throws {
    let data = TestZipBuilder.build([
      .init(name: "Skin/"),
      .init(name: "Skin/info.json", contents: Data("{}".utf8)),
      .init(name: "Skin/art/bg.png", contents: Data([1, 2, 3]))
    ])
    XCTAssertEqual(try scan(data).map(\.name), ["Skin/", "Skin/info.json", "Skin/art/bg.png"])
  }

  func testParsesPastATrailingComment() throws {
    let data = TestZipBuilder.build([.init(name: "a.txt")], comment: Array("a perfectly ordinary archive comment".utf8))
    XCTAssertEqual(try scan(data).map(\.name), ["a.txt"])
  }

  /// minizip's end-record search returns 0 for "not found" (unzip.c:342-347), so it cannot open an archive whose end
  /// record is its first byte: the scanner refuses it too rather than vouch for a file the extractor reads differently.
  func testRejectsAnEndRecordAtTheStartOfTheFileLikeMinizip() {
    assertRejects(TestZipBuilder.build([]), .notAZip)
    XCTAssertEqual(try scan(Data([0]) + TestZipBuilder.endRecord(entryCount: 0, centralDirectorySize: 0, centralDirectoryOffset: 1)), [])
  }

  /// minizip's `max_back` (unzip.c:299), spelled out here so the test does not borrow the scanner's own constant.
  private static let minizipSearchWindow = 0xFFFF

  /// minizip looks for the end record only in the last 0xFFFF bytes (unzip.c:299, 317-327).
  func testFindsTheEndRecordOnlyWhereMinizipLooks() throws {
    let entry = TestZipBuilder.Entry(name: "a.txt")
    let longestFoundComment = Self.minizipSearchWindow - TestZipBuilder.endRecordSize
    XCTAssertEqual(try scan(TestZipBuilder.build([entry], comment: Array(repeating: 0, count: longestFoundComment))).map(\.name), ["a.txt"])
    assertRejects(TestZipBuilder.build([entry], comment: Array(repeating: 0, count: longestFoundComment + 1)), .notAZip)
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
    XCTAssertEqual(try scan(TestZipBuilder.build(names.map { .init(name: $0) })).map(\.name), names)
  }

  func testRejectsParentHiddenBehindANulByte() {
    assertUnsafe([.init(rawName: Array("..".utf8) + [0] + Array("/x".utf8))])
  }

  func testAllowsDotsThatAreNotParentComponents() throws {
    let names = ["..hidden", "a/b..c", "a/./b.txt", "name with spaces.json"]
    XCTAssertEqual(try scan(TestZipBuilder.build(names.map { .init(name: $0) })).map(\.name), names)
  }

  func testRejectsSymlinkEntries() {
    assertUnsafe([.init(name: "link", contents: Data("/etc/passwd".utf8), externalAttributes: TestZipBuilder.unixSymlinkAttributes)])
  }

  /// A zip64 extra field changes only an entry's sizes and offset in minizip (unzip.c:849-879), so it is read past.
  func testAcceptsZip64EntryFieldsInAPlainArchive() throws {
    let data = TestZipBuilder.build([.init(name: "game.iso", contents: Data([1, 2, 3]), zip64Fields: true), .init(name: "readme.txt")])
    XCTAssertEqual(try scan(data).map(\.name), ["game.iso", "readme.txt"])
  }

  func testRejectsMultiDiskArchives() {
    let directory = TestZipBuilder.centralRecord(.init(name: "a.txt"), localHeaderOffset: 0)
    var spanned = TestZipBuilder.localRecord(.init(name: "a.txt"))
    let offset = UInt32(spanned.count)
    spanned.append(directory)
    spanned.append(TestZipBuilder.endRecord(entryCount: 1, centralDirectorySize: directory.count, centralDirectoryOffset: offset, disk: 1))
    assertRejects(spanned, .multiDisk)
    assertRejects(TestZipBuilder.build([.init(name: "a.txt", diskStart: 1)]), .multiDisk)
  }

  func testRejectsTruncatedAndNonZipData() {
    let data = TestZipBuilder.build([.init(name: "a.txt", contents: Data(count: 40))])
    assertRejects(Data("definitely not a zip file".utf8), .notAZip)
    assertRejects(data.prefix(data.count - 10), .truncated, "the end-of-central-directory record is cut short")
    assertRejects(data.prefix(data.count - 22), .notAZip, "the end-of-central-directory record is gone")
    var damaged = data
    damaged.replaceSubrange((data.count - 22 + 16)..<(data.count - 22 + 20), with: [0xFF, 0x00, 0x00, 0x00])
    assertRejects(damaged, .inconsistentDirectory, "the central directory offset no longer meets the end record")
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
    assertRejects(archiveWithHiddenDirectory(trailing: [0x78, 0x78, 0x78]), .inconsistentDirectory, "the last end record's comment does not reach the end of the data")
  }

  func testScansTheDirectoryOfAFakeEndRecordThatReachesTheEnd() {
    assertUnsafe(archiveWithHiddenDirectory(trailing: []))
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
    assertRejects(archive, .inconsistentDirectory)
  }

  func testRejectsEntryCountThatDisagreesWithTheDirectory() {
    let local = TestZipBuilder.localRecord(Self.benign)
    let directory = TestZipBuilder.centralRecord(Self.benign, localHeaderOffset: 0)
    for claimed in [0, 2] {
      var archive = local
      archive.append(directory)
      archive.append(TestZipBuilder.endRecord(entryCount: claimed, centralDirectorySize: directory.count, centralDirectoryOffset: UInt32(local.count)))
      assertRejects(archive, .inconsistentDirectory, "claimed \(claimed)")
    }
  }

  // MARK: - Zip64

  private static let nestedNames = ["Game/", "Game/disc.iso", "Game/Saves/a.sav"]
  private static let nestedEntries = nestedNames.map { TestZipBuilder.Entry(name: $0, contents: Data($0.utf8), zip64Fields: $0.hasSuffix(".iso")) }

  func testListsNamesOfAZip64Archive() throws {
    XCTAssertEqual(try scan(TestZipBuilder.buildZip64(Self.nestedEntries)).map(\.name), Self.nestedNames)
    let withExtensibleData = TestZipBuilder.Zip64Tail(extensibleData: Data(count: 8))
    XCTAssertEqual(try scan(TestZipBuilder.buildZip64(Self.nestedEntries, tail: withExtensibleData)).map(\.name), Self.nestedNames)
  }

  /// minizip switches to zip64 on any one of: 0xFFFF entries, a 0xFFFF (sic, not 0xFFFFFFFF) directory size, or a
  /// 0xFFFFFFFF directory offset (unzip.c:463-464), and then uses only the zip64 record's values (unzip.c:496-508).
  func testFollowsEachOfMinizipsZip64Triggers() throws {
    let triggers = [
      TestZipBuilder.Zip64Tail(),
      TestZipBuilder.Zip64Tail(plainEntryCount: TestZipBuilder.zip64Marker16, plainCentralDirectoryOffset: 0),
      TestZipBuilder.Zip64Tail(plainCentralDirectorySize: TestZipBuilder.zip64Marker16, plainCentralDirectoryOffset: 0)
    ]
    for tail in triggers {
      XCTAssertEqual(try scan(TestZipBuilder.buildZip64(Self.nestedEntries, tail: tail)).map(\.name), Self.nestedNames, "\(tail)")
    }
  }

  /// Without a trigger minizip ignores the zip64 records and reads the directory `central_pos - (offset + size)` bytes
  /// late (unzip.c:539, 722): the 76 bytes of zip64 end record and locator count as a gap.
  func testRejectsZip64RecordsTheEndRecordDoesNotPointTo() {
    let local = TestZipBuilder.localRecord(Self.benign)
    let directory = TestZipBuilder.centralRecord(Self.benign, localHeaderOffset: 0)
    let tail = TestZipBuilder.Zip64Tail(plainCentralDirectoryOffset: UInt32(local.count))
    assertRejects(local + TestZipBuilder.zip64Directory(directory, entryCount: 1, centralDirectoryOffset: UInt64(local.count), tail: tail), .inconsistentDirectory)
  }

  /// When the end record asks for zip64 and there is no locator minizip fails the open (unzip.c:510-511): never fall back.
  func testRejectsATriggerWithoutAZip64Locator() {
    let local = TestZipBuilder.localRecord(Self.benign)
    let directory = TestZipBuilder.centralRecord(Self.benign, localHeaderOffset: 0)
    let end = TestZipBuilder.endRecord(entryCount: 1, centralDirectorySize: directory.count, centralDirectoryOffset: TestZipBuilder.zip64Marker32)
    assertRejects(local + directory + end, .notAZip)
    assertRejects(Data([0]) + TestZipBuilder.endRecord(entryCount: 0, centralDirectorySize: 0, centralDirectoryOffset: TestZipBuilder.zip64Marker32), .notAZip,
                  "too close to the start of the file for a locator")
  }

  func testRejectsZip64LocatorsThatPointOutOfBoundsOrAtTheWrongRecord() {
    let cases: [(UInt64, ZipEntryScannerError)] = [
      (UInt64.max - 8, .truncated),
      (1 << 40, .truncated),
      (0, .notAZip) // a local header, not a zip64 end record
    ]
    for (offset, expected) in cases {
      assertRejects(TestZipBuilder.buildZip64(Self.nestedEntries, tail: .init(endRecordOffset: offset)), expected, "locator -> \(offset)")
    }
    let archive = TestZipBuilder.buildZip64(Self.nestedEntries)
    let locator = archive.count - TestZipBuilder.endRecordSize - TestZipBuilder.zip64LocatorSize
    let overlapping = UInt64(locator - TestZipBuilder.zip64EndRecordSize + 1)
    assertRejects(TestZipBuilder.buildZip64(Self.nestedEntries, tail: .init(endRecordOffset: overlapping)), .inconsistentDirectory, "record runs into the locator")
  }

  func testRejectsBytesBetweenTheZip64EndRecordAndTheLocator() {
    assertRejects(TestZipBuilder.buildZip64(Self.nestedEntries, tail: .init(uncountedBytes: Data(count: 8))), .inconsistentDirectory)
  }

  func testRejectsZip64EntryCountsThatDisagree() {
    let count = UInt64(Self.nestedEntries.count)
    let tails = [
      TestZipBuilder.Zip64Tail(entriesOnDisk: count + 1),
      TestZipBuilder.Zip64Tail(entriesOnDisk: 0, totalEntries: 0),
      TestZipBuilder.Zip64Tail(entriesOnDisk: count + 1, totalEntries: count + 1)
    ]
    for tail in tails {
      assertRejects(TestZipBuilder.buildZip64(Self.nestedEntries, tail: tail), .inconsistentDirectory, "\(tail)")
    }
    var plainCountsDisagree = TestZipBuilder.buildZip64(Self.nestedEntries)
    plainCountsDisagree[plainCountsDisagree.count - TestZipBuilder.endRecordSize + 8] += 1 // entries on this disk (unzip.c:449)
    assertRejects(plainCountsDisagree, .inconsistentDirectory)
  }

  func testRejectsMultiDiskZip64Archives() {
    for tail in [TestZipBuilder.Zip64Tail(disk: 1), .init(centralDirectoryDisk: 1), .init(locatorDisk: 1), .init(totalDisks: 2)] {
      assertRejects(TestZipBuilder.buildZip64(Self.nestedEntries, tail: tail), .multiDisk, "\(tail)")
    }
  }

  func testRejectsGapBetweenZip64DirectoryAndEndRecord() {
    let local = TestZipBuilder.localRecord(Self.benign)
    let benignDirectory = TestZipBuilder.centralRecord(Self.benign, localHeaderOffset: 0)
    let hostileDirectory = TestZipBuilder.centralRecord(Self.hostile, localHeaderOffset: 0)
    let tail = TestZipBuilder.Zip64Tail(centralDirectorySize: UInt64(benignDirectory.count))
    let archive = local + TestZipBuilder.zip64Directory(benignDirectory + hostileDirectory, entryCount: 1, centralDirectoryOffset: UInt64(local.count), tail: tail)
    assertRejects(archive, .inconsistentDirectory)
  }

  /// The zip64 version of the hidden directory: a whole zip64 tail (directory, zip64 end record, locator, end record) in the
  /// comment. minizip follows the LAST end record, so the scanner must read the same hidden directory or refuse the file.
  private func zip64ArchiveWithHiddenDirectory(trailing: [UInt8]) -> Data {
    let local = TestZipBuilder.localRecord(Self.benign)
    let benignDirectory = TestZipBuilder.centralRecord(Self.benign, localHeaderOffset: 0)
    let hostileDirectory = TestZipBuilder.centralRecord(Self.hostile, localHeaderOffset: 0)
    let tailSize = TestZipBuilder.zip64EndRecordSize + TestZipBuilder.zip64LocatorSize + TestZipBuilder.endRecordSize
    let hiddenOffset = UInt64(local.count + benignDirectory.count + tailSize)
    let hidden = TestZipBuilder.zip64Directory(hostileDirectory, entryCount: 1, centralDirectoryOffset: hiddenOffset)
    return local + TestZipBuilder.zip64Directory(benignDirectory, entryCount: 1, centralDirectoryOffset: UInt64(local.count), comment: Array(hidden) + trailing)
  }

  func testRejectsFakeZip64EndRecordInsideTheComment() {
    assertRejects(zip64ArchiveWithHiddenDirectory(trailing: [0x78, 0x78, 0x78]), .inconsistentDirectory)
    assertUnsafe(zip64ArchiveWithHiddenDirectory(trailing: []))
  }

  func testRejectsUnsafeNamesInAZip64Archive() {
    let hostileEntries: [TestZipBuilder.Entry] = [
      .init(name: "../escape.iso", zip64Fields: true),
      .init(name: "Game/..\\..\\escape.iso"),
      .init(name: "/abs.iso", zip64Fields: true),
      .init(name: "C:\\abs.iso"),
      .init(name: "Game/../\u{301}x"),
      .init(rawName: Array("..".utf8) + [0] + Array("/x".utf8)),
      .init(name: "link", contents: Data("/etc".utf8), externalAttributes: TestZipBuilder.unixSymlinkAttributes, zip64Fields: true)
    ]
    for entry in hostileEntries {
      assertUnsafe(TestZipBuilder.buildZip64(Self.nestedEntries + [entry]))
    }
  }

  func testRejectsADirectoryLargerThanTheCapBeforeReadingIt() {
    let source = CountingByteSource(DataByteSource(TestZipBuilder.buildZip64(Self.nestedEntries, tail: .init(centralDirectorySize: ZipEntryScanner.maxCentralDirectorySize + 1))))
    XCTAssertThrowsError(try ZipEntryScanner.scan(source)) { XCTAssertEqual($0 as? ZipEntryScannerError, .directoryTooLarge) }
    XCTAssertLessThanOrEqual(source.bytesRead, ZipEntryScanner.endRecordSearchWindow + TestZipBuilder.zip64LocatorSize + TestZipBuilder.zip64EndRecordSize)
  }

  /// `zip -X -fz -r fz.zip Game` (Info-ZIP 3.0): a real writer's zip64 archive, offset 0xFFFFFFFF in the end record.
  private static let infoZipZip64Fixture = """
    UEsDBC0AAAAAAIijQV0AAAAA//////////8FABQAR2FtZS8BABAAAAAAAAAAAAAAAAAAAAAAAFBLAwQtAAAAAACIo0FdAAAAAP//////////CwAUAEdhbWUvU2F2ZXMvAQAQAAAAAAAAAAAAAAAAAAAAAABQSwME
    LQAAAAAAiKNBXd46ZlX//////////xAAFABHYW1lL1NhdmVzL2Euc2F2AQAQAAQAAAAAAAAABAAAAAAAAABzYXZlUEsDBC0AAAAAAIijQV1Kqonw//////////8OABQAR2FtZS9pbmZvLmpzb24BABAACwAAAAAA
    AAALAAAAAAAAAHsiaWQiOiJ4In0KUEsBAh4DCgAAAAAAiKNBXQAAAAAAAAAA/////wUADAAAAAAAAAAQAO1BAAAAAEdhbWUvAQAIAAAAAAAAAAAAUEsBAh4DCgAAAAAAiKNBXQAAAAAAAAAA/////wsADAAAAAAA
    AAAQAO1BNwAAAEdhbWUvU2F2ZXMvAQAIAAAAAAAAAAAAUEsBAh4DLQAAAAAAiKNBXd46ZlUEAAAA/////xAADAAAAAAAAQAAAKSBdAAAAEdhbWUvU2F2ZXMvYS5zYXYBAAgABAAAAAAAAABQSwECHgMtAAAAAACI
    o0FdSqqJ8AsAAAD/////DgAMAAAAAAABAAAApIG6AAAAR2FtZS9pbmZvLmpzb24BAAgACwAAAAAAAABQSwYGLAAAAAAAAAAeAy0AAAAAAAAAAAAEAAAAAAAAAAQAAAAAAAAAFgEAAAAAAAAFAQAAAAAAAFBLBgcA
    AAAAGwIAAAAAAAABAAAAUEsFBgAAAAAEAAQAFgEAAP////8AAA==
    """

  func testAcceptsAnInfoZipZip64Archive() throws {
    let fixture = try XCTUnwrap(Data(base64Encoded: Self.infoZipZip64Fixture, options: .ignoreUnknownCharacters))
    XCTAssertEqual(try scan(fixture).map(\.name), ["Game/", "Game/Saves/", "Game/Saves/a.sav", "Game/info.json"])
  }

  // MARK: - Streaming

  func testReadsOnlyTheEndOfTheArchiveAndTheDirectory() throws {
    let entries = [TestZipBuilder.Entry(name: "Game/disc.iso", contents: Data(count: 4 * ZipEntryScanner.endRecordSearchWindow))] + Self.nestedEntries
    let archive = TestZipBuilder.buildZip64(entries)
    let directorySize = entries.reduce(0) { $0 + TestZipBuilder.centralRecord($1, localHeaderOffset: 0).count }
    let source = CountingByteSource(DataByteSource(archive))
    XCTAssertEqual(try ZipEntryScanner.scan(source).count, entries.count)
    XCTAssertLessThanOrEqual(source.bytesRead, ZipEntryScanner.endRecordSearchWindow + TestZipBuilder.zip64LocatorSize + TestZipBuilder.zip64EndRecordSize + directorySize)
  }

  /// A file of `gap` sparse bytes followed by `archive`; APFS stores the gap without allocating it.
  private func sparseFile(gap: UInt64, then archive: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZipEntryScannerTests-\(UUID().uuidString).zip")
    XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: gap)
    try handle.seekToEnd()
    try handle.write(contentsOf: archive)
    return url
  }

  private static let sparseGap: UInt64 = 6 << 30
  private static let sparseScanTimeLimit: TimeInterval = 1

  func testScansAMultiGigabyteZip64ArchiveWithoutReadingIt() throws {
    let entries = Self.nestedNames.map { TestZipBuilder.Entry(name: $0, contents: Data($0.utf8), zip64Fields: true) }
    let url = try sparseFile(gap: Self.sparseGap, then: TestZipBuilder.buildZip64(entries, baseOffset: Self.sparseGap))
    defer { try? FileManager.default.removeItem(at: url) }
    let directorySize = entries.reduce(0) { $0 + TestZipBuilder.centralRecord($1, localHeaderOffset: 0).count }
    let source = CountingByteSource(try ZipFileByteSource(url: url))
    let start = Date()
    XCTAssertEqual(try ZipEntryScanner.scan(source).map(\.name), Self.nestedNames)
    XCTAssertLessThan(Date().timeIntervalSince(start), Self.sparseScanTimeLimit)
    XCTAssertLessThanOrEqual(source.bytesRead, ZipEntryScanner.endRecordSearchWindow + TestZipBuilder.zip64LocatorSize + TestZipBuilder.zip64EndRecordSize + directorySize)
  }

  /// A plain archive whose offsets count from its own start, appended after other data: minizip would read its directory
  /// `byte_before_the_zipfile` bytes late (unzip.c:539), so it is refused like any other gap.
  func testRejectsAPlainArchiveAppendedAfterAGap() throws {
    let url = try sparseFile(gap: Self.sparseGap, then: TestZipBuilder.build(Self.nestedEntries))
    defer { try? FileManager.default.removeItem(at: url) }
    XCTAssertThrowsError(try ZipEntryScanner.scan(fileAt: url)) { XCTAssertEqual($0 as? ZipEntryScannerError, .inconsistentDirectory) }
  }

  func testScansAFileOnDisk() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZipEntryScannerTests-\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: url) }
    try TestZipBuilder.build([.init(name: "a.txt")]).write(to: url)
    XCTAssertEqual(try ZipEntryScanner.scan(fileAt: url).map(\.name), ["a.txt"])
  }

  // MARK: - isSafeRelativePath

  func testSafeRelativePathRuleOnStrings() {
    let unsafe = ["../x", "a/../../x", "a/..", "..", "..\\x", "a\\..\\x", "/abs", "\\abs", "C:/x", "c:\\x", "z:",
                  "../\u{301}x", "../\u{200D}x", "a\u{600}/../\u{301}b", "..\\\u{301}x", "..\u{0}/x"]
    let safe = ["", "a.txt", "Game/disc.iso", "..hidden", "a/b..c", "a/./b", "cafe\u{301}/art.png", "e\u{301}/\u{200D}x/..hidden",
                "1:x", "a\u{0}/../x"]
    for name in unsafe { XCTAssertFalse(ZipEntryScanner.isSafeRelativePath(name), name.debugDescription) }
    for name in safe { XCTAssertTrue(ZipEntryScanner.isSafeRelativePath(name), name.debugDescription) }
  }
}
