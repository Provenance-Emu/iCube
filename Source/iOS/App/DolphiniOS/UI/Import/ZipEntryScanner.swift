// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

struct ZipEntry: Equatable {
  /// The entry's path inside the archive, cut at its first NUL byte (what a C extractor would see).
  let name: String
  /// The central directory's external file attributes; the high 16 bits hold the Unix mode.
  let externalAttributes: UInt32
}

enum ZipEntryScannerError: Error, Equatable {
  /// No end-of-central-directory record, or a central directory entry that does not parse.
  case notAZip
  /// A record, or a range one points to, runs past the end of the archive.
  case truncated
  /// The end record, central directory and entry count do not describe one consistent archive, which is how
  /// a second, hidden directory is smuggled past a scanner that reads the archive differently than the extractor.
  case inconsistentDirectory
  /// The archive (or one of its entries) claims to span several disks, which this scanner does not read.
  case multiDisk
  /// The central directory is larger than the scanner is willing to read into memory.
  case directoryTooLarge
  /// An entry that could write outside the extraction folder, or is a symbolic link. Carries the entry name.
  case unsafeEntry(String)
}

/// Random access to the archive's bytes, so the scanner reads only the few ranges minizip reads.
protocol ZipByteSource {
  var size: UInt64 { get }
  /// Exactly `count` bytes at `offset`, or `ZipEntryScannerError.truncated` when the source ends first.
  func read(at offset: UInt64, count: Int) throws -> Data
}

/// Reads with seeks, never mapping or copying the whole archive: a zipped Wii image is several gigabytes.
struct ZipFileByteSource: ZipByteSource {
  let size: UInt64
  private let handle: FileHandle

  init(url: URL) throws {
    handle = try FileHandle(forReadingFrom: url)
    size = try handle.seekToEnd()
  }

  func read(at offset: UInt64, count: Int) throws -> Data {
    try handle.seek(toOffset: offset)
    var bytes = Data()
    while bytes.count < count {
      guard let chunk = try handle.read(upToCount: count - bytes.count), !chunk.isEmpty else { throw ZipEntryScannerError.truncated }
      bytes.append(chunk)
    }
    return bytes
  }
}

/// Reads a zip's central directory without extracting anything, so an archive can be checked for
/// path-traversal ("zip slip") and symlink entries before an extractor that does not check them runs.
///
/// The bundled extractor is Zip's minizip (`unzOpenInternal` in `unzip.c`). It takes the LAST end-record signature in
/// the final 64 KiB (`unz64local_SearchCentralDir`, unzip.c:294-351) with no consistency check, follows the zip64
/// locator just before it when the end record says so (unzip.c:463-511), and reads the first entry at
/// `central_pos - size_central_dir` (`byte_before_the_zipfile`, unzip.c:539). The scanner picks the records the same way
/// and then refuses any archive where minizip's reading and the declared layout could differ: a comment that does not
/// end at the end of the file, a gap between the directory and the record after it, or a wrong entry count.
enum ZipEntryScanner {
  /// The most central directory bytes the scanner reads. A ROM archive holds a handful of entries; a directory this
  /// large is not one, and reading it would be a memory problem of its own.
  static let maxCentralDirectorySize: UInt64 = 64 << 20
  /// minizip searches only this many bytes back from the end of the file (`max_back`, unzip.c:299, 317-327).
  static let endRecordSearchWindow = 0xFFFF

  private static let endRecordSignature: UInt32 = 0x0605_4B50
  private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
  private static let zip64EndRecordSignature: UInt32 = 0x0606_4B50
  private static let centralEntrySignature: UInt32 = 0x0201_4B50
  private static let endRecordSize = 22
  private static let zip64LocatorSize = 20
  /// The part of the zip64 end record minizip reads (unzip.c:477-508); its extensible data sector is never read.
  private static let zip64EndRecordReadSize = 56
  /// The zip64 end record's size field counts the bytes after itself: the signature (4) and the field (8) are not in it.
  private static let zip64EndRecordSizeFieldBase: UInt64 = 12
  private static let centralEntryHeaderSize = 46
  private static let signatureSize = 4
  private static let zip64Marker16: UInt16 = 0xFFFF
  private static let zip64Marker32: UInt32 = 0xFFFF_FFFF
  private static let unixModeShift: UInt32 = 16
  private static let fileTypeMask: UInt32 = 0o170000
  private static let symlinkType: UInt32 = 0o120000
  private static let nulByte: UInt8 = 0
  private static let slashByte = UInt8(ascii: "/")
  private static let backslashByte = UInt8(ascii: "\\")
  private static let dotByte = UInt8(ascii: ".")
  private static let colonByte = UInt8(ascii: ":")

  /// Field offsets within the end record, the zip64 locator, the zip64 end record and a central directory entry header.
  private enum EndRecord {
    static let disk = 4
    static let centralDirectoryDisk = 6
    static let entriesOnDisk = 8
    static let totalEntries = 10
    static let centralDirectorySize = 12
    static let centralDirectoryOffset = 16
    static let commentLength = 20
  }

  private enum Zip64Locator {
    static let endRecordDisk = 4
    static let endRecordOffset = 8
    static let totalDisks = 16
  }

  private enum Zip64EndRecord {
    static let recordSize = 4
    static let disk = 16
    static let centralDirectoryDisk = 20
    static let entriesOnDisk = 24
    static let totalEntries = 32
    static let centralDirectorySize = 40
    static let centralDirectoryOffset = 48
  }

  private enum CentralEntry {
    static let nameLength = 28
    static let extraLength = 30
    static let commentLength = 32
    static let diskStart = 34
    static let externalAttributes = 38
  }

  /// Where minizip will read the central directory, and how many entries it was told to expect.
  private struct Directory {
    let offset: UInt64
    let size: UInt64
    let entryCount: UInt64
  }

  static func scan(fileAt url: URL) throws -> [ZipEntry] {
    try scan(ZipFileByteSource(url: url))
  }

  /// Returns every entry, or throws when the archive cannot be read or any entry is unsafe to extract.
  static func scan(_ source: ZipByteSource) throws -> [ZipEntry] {
    let (endPosition, end) = try endRecord(in: source)
    // minizip refuses an end record whose two entry counts differ, before it looks for zip64 (unzip.c:442-450).
    guard end.le16(EndRecord.entriesOnDisk) == end.le16(EndRecord.totalEntries) else { throw ZipEntryScannerError.inconsistentDirectory }
    guard endPosition + UInt64(endRecordSize) + UInt64(end.le16(EndRecord.commentLength)) == source.size else {
      throw ZipEntryScannerError.inconsistentDirectory
    }
    let count = end.le16(EndRecord.totalEntries)
    let size = end.le32(EndRecord.centralDirectorySize)
    let offset = end.le32(EndRecord.centralDirectoryOffset)
    // The exact zip64 switch minizip makes; note it tests the 32-bit size against 0xFFFF, not 0xFFFFFFFF (unzip.c:463-464).
    let directory: Directory
    let directoryEnd: UInt64
    if count == zip64Marker16 || size == UInt32(zip64Marker16) || offset == zip64Marker32 {
      (directory, directoryEnd) = try zip64Directory(in: source, endPosition: endPosition)
    } else {
      guard end.le16(EndRecord.disk) == 0, end.le16(EndRecord.centralDirectoryDisk) == 0 else { throw ZipEntryScannerError.multiDisk }
      directory = Directory(offset: UInt64(offset), size: UInt64(size), entryCount: UInt64(count))
      directoryEnd = endPosition
    }
    guard directory.size <= maxCentralDirectorySize else { throw ZipEntryScannerError.directoryTooLarge }
    // No gap: minizip starts reading at `central_pos - size` (unzip.c:539, 722), so any slack between the directory and the
    // record minizip chose is a second directory. `central_pos` is the zip64 end record when there is one (unzip.c:467).
    let (declaredEnd, overflow) = directory.offset.addingReportingOverflow(directory.size)
    guard !overflow, declaredEnd == directoryEnd else { throw ZipEntryScannerError.inconsistentDirectory }
    let entries = try parseEntries(try source.read(at: directory.offset, count: Int(directory.size)))
    guard UInt64(entries.count) == directory.entryCount else { throw ZipEntryScannerError.inconsistentDirectory }
    return entries
  }

  /// The zip64 locator immediately before the end record, then the zip64 end record it points to
  /// (`unz64local_SearchCentralDir64`, unzip.c:353-390), read the way `unzOpenInternal` reads it (unzip.c:467-511).
  /// Returns the directory it describes and the position the directory must end at: the zip64 end record itself.
  private static func zip64Directory(in source: ZipByteSource, endPosition: UInt64) throws -> (Directory, UInt64) {
    // minizip fails the open when the locator is missing (unzip.c:510-511); never fall back to the plain fields.
    guard endPosition >= UInt64(zip64LocatorSize) else { throw ZipEntryScannerError.notAZip }
    let locatorPosition = endPosition - UInt64(zip64LocatorSize)
    let locator = try source.read(at: locatorPosition, count: zip64LocatorSize)
    guard locator.le32(0) == zip64LocatorSignature else { throw ZipEntryScannerError.notAZip }
    // minizip ignores both disk fields of the locator (unzip.c:371-379); a single-disk archive has 0 and 1 (or 0) there.
    guard locator.le32(Zip64Locator.endRecordDisk) == 0, locator.le32(Zip64Locator.totalDisks) <= 1 else { throw ZipEntryScannerError.multiDisk }
    let recordPosition = locator.le64(Zip64Locator.endRecordOffset)
    let (readEnd, overflow) = recordPosition.addingReportingOverflow(UInt64(zip64EndRecordReadSize))
    guard !overflow, readEnd <= source.size else { throw ZipEntryScannerError.truncated }
    guard readEnd <= locatorPosition else { throw ZipEntryScannerError.inconsistentDirectory }
    let record = try source.read(at: recordPosition, count: zip64EndRecordReadSize)
    guard record.le32(0) == zip64EndRecordSignature else { throw ZipEntryScannerError.notAZip }
    // minizip never reads past the fixed fields, so bytes between the record and the locator would go unseen: the record's
    // own size must run exactly up to the locator.
    let (recordEnd, sizeOverflow) = (recordPosition + zip64EndRecordSizeFieldBase).addingReportingOverflow(record.le64(Zip64EndRecord.recordSize))
    guard !sizeOverflow, recordEnd == locatorPosition else { throw ZipEntryScannerError.inconsistentDirectory }
    guard record.le32(Zip64EndRecord.disk) == 0, record.le32(Zip64EndRecord.centralDirectoryDisk) == 0 else { throw ZipEntryScannerError.multiDisk }
    // The same count check as the plain record, on the 64-bit counts (unzip.c:495-502).
    let count = record.le64(Zip64EndRecord.totalEntries)
    guard record.le64(Zip64EndRecord.entriesOnDisk) == count else { throw ZipEntryScannerError.inconsistentDirectory }
    let directory = Directory(offset: record.le64(Zip64EndRecord.centralDirectoryOffset),
                              size: record.le64(Zip64EndRecord.centralDirectorySize), entryCount: count)
    return (directory, recordPosition)
  }

  /// Walks the directory the way `unzGoToNextFile` does (unzip.c:1679-1680): each entry is the fixed header plus its name,
  /// extra and comment lengths. A zip64 extra field changes only an entry's sizes and offset (unzip.c:849-879), never the
  /// name or the step to the next entry, so 0xFFFFFFFF size and offset fields need no special handling.
  private static func parseEntries(_ directory: Data) throws -> [ZipEntry] {
    var entries: [ZipEntry] = []
    var cursor = 0
    while cursor < directory.count {
      guard cursor + centralEntryHeaderSize <= directory.count else { throw ZipEntryScannerError.truncated }
      guard directory.le32(cursor) == centralEntrySignature else { throw ZipEntryScannerError.notAZip }
      // minizip reads this as 16 bits and so never takes it from the zip64 extra (unzip.c:760, 873): 0 is the only single disk.
      guard directory.le16(cursor + CentralEntry.diskStart) == 0 else { throw ZipEntryScannerError.multiDisk }
      let nameLength = Int(directory.le16(cursor + CentralEntry.nameLength))
      let variableLength = nameLength + Int(directory.le16(cursor + CentralEntry.extraLength)) + Int(directory.le16(cursor + CentralEntry.commentLength))
      guard cursor + centralEntryHeaderSize + variableLength <= directory.count else { throw ZipEntryScannerError.truncated }
      let nameStart = directory.startIndex + cursor + centralEntryHeaderSize
      let rawName = directory[nameStart..<(nameStart + nameLength)].prefix { $0 != nulByte }
      // Lossy decoding on purpose: a failable decode would turn a name with one bad byte into "" and skip the checks.
      // swiftlint:disable:next optional_data_string_conversion
      let entry = ZipEntry(name: String(decoding: rawName, as: UTF8.self), externalAttributes: directory.le32(cursor + CentralEntry.externalAttributes))
      let isSymlink = (entry.externalAttributes >> unixModeShift) & fileTypeMask == symlinkType
      guard isSafeRelativePath(bytes: rawName), !isSymlink else { throw ZipEntryScannerError.unsafeEntry(entry.name) }
      entries.append(entry)
      cursor += centralEntryHeaderSize + variableLength
    }
    return entries
  }

  /// The LAST end-record signature minizip's backwards search finds (unzip.c:294-351), and the record itself. That search
  /// covers only the final 0xFFFF bytes, and a signature at offset 0 doubles as its "not found" value (unzip.c:342-347,
  /// 514-515), so neither is accepted here. Whether the record is consistent with the rest of the archive is the caller's check.
  private static func endRecord(in source: ZipByteSource) throws -> (position: UInt64, record: Data) {
    let windowSize = Int(min(source.size, UInt64(endRecordSearchWindow)))
    let windowStart = source.size - UInt64(windowSize)
    let window = try source.read(at: windowStart, count: windowSize)
    var candidate = windowSize - signatureSize
    while candidate >= 0 {
      if window.le32(candidate) == endRecordSignature {
        let position = windowStart + UInt64(candidate)
        guard position != 0 else { throw ZipEntryScannerError.notAZip }
        guard candidate + endRecordSize <= windowSize else { throw ZipEntryScannerError.truncated }
        let recordStart = window.startIndex + candidate
        return (position, window.subdata(in: recordStart..<(recordStart + endRecordSize)))
      }
      candidate -= 1
    }
    throw ZipEntryScannerError.notAZip
  }

  /// Whether extracting an entry with this name stays inside the destination folder. Checked on the UTF-8 bytes, cut at
  /// the first NUL the way `String(cString:)` cuts them: `\` counts as `/`, and a leading `/`, a drive letter or any
  /// `..` component is unsafe.
  static func isSafeRelativePath(_ name: String) -> Bool {
    isSafeRelativePath(bytes: name.utf8.prefix { $0 != nulByte })
  }

  /// Checked on the raw bytes, never on Swift `String` / `Character` operations: those group a `/` with a following
  /// combining mark into one grapheme, so a `..` component would hide from them while the kernel still sees the `/`.
  private static func isSafeRelativePath<Bytes: Collection>(bytes: Bytes) -> Bool where Bytes.Element == UInt8 {
    let path = bytes.map { $0 == backslashByte ? slashByte : $0 }
    let hasDriveLetter = path.count >= 2 && path[1] == colonByte && isASCIILetter(path[0])
    let hasParentComponent = path.split(separator: slashByte, omittingEmptySubsequences: false).contains { $0.elementsEqual([dotByte, dotByte]) }
    return path.first != slashByte && !hasDriveLetter && !hasParentComponent
  }

  private static func isASCIILetter(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
  }
}

private extension Data {
  func le16(_ offset: Int) -> UInt16 {
    UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
  }

  func le32(_ offset: Int) -> UInt32 {
    UInt32(le16(offset)) | UInt32(le16(offset + 2)) << 16
  }

  func le64(_ offset: Int) -> UInt64 {
    UInt64(le32(offset)) | UInt64(le32(offset + 4)) << 32
  }
}
