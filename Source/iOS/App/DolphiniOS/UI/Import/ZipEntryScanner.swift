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
  /// An entry or the end record runs past the end of the data.
  case truncated
  /// The end record, central directory and entry count do not describe one consistent archive, which is how
  /// a second, hidden directory is smuggled past a scanner that reads the archive differently than the extractor.
  case inconsistentDirectory
  /// The archive uses zip64 (or spans disks), which this scanner does not read.
  case zip64Unsupported
  /// An entry that could write outside the extraction folder, or is a symbolic link. Carries the entry name.
  case unsafeEntry(String)
}

/// Reads a zip's central directory without extracting anything, so an archive can be checked for
/// path-traversal ("zip slip") and symlink entries before an extractor that does not check them runs.
///
/// The bundled extractor (Zip's minizip, `unzOpenInternal` in `unzip.c`) takes the LAST end-record signature in
/// the final 64 KiB (`unz64local_SearchCentralDir`, unzip.c:294-351) with no consistency check, and reads the
/// first entry at `central_pos - size_central_dir` (`byte_before_the_zipfile`, unzip.c:541). The scanner locates
/// the end record the same way and then refuses any archive where those two readings could differ: a comment that
/// does not end at the end of the data, a gap between the directory and the end record, or a wrong entry count.
enum ZipEntryScanner {
  private static let endRecordSignature: UInt32 = 0x0605_4B50
  private static let centralEntrySignature: UInt32 = 0x0201_4B50
  private static let endRecordSize = 22
  private static let centralEntryHeaderSize = 46
  private static let maxCommentLength = 0xFFFF
  private static let signatureSize = 4
  private static let zip64Marker16: UInt16 = 0xFFFF
  private static let zip64Marker32: UInt32 = 0xFFFF_FFFF
  private static let unixModeShift: UInt32 = 16
  private static let fileTypeMask: UInt32 = 0o170000
  private static let symlinkType: UInt32 = 0o120000
  private static let slashByte = UInt8(ascii: "/")
  private static let backslashByte = UInt8(ascii: "\\")
  private static let dotByte = UInt8(ascii: ".")
  private static let colonByte = UInt8(ascii: ":")

  /// Entry field offsets within the end record and a central directory entry header.
  private enum EndRecord {
    static let disk = 4
    static let centralDirectoryDisk = 6
    static let entriesOnDisk = 8
    static let totalEntries = 10
    static let centralDirectorySize = 12
    static let centralDirectoryOffset = 16
  }

  private enum CentralEntry {
    static let compressedSize = 20
    static let uncompressedSize = 24
    static let nameLength = 28
    static let extraLength = 30
    static let commentLength = 32
    static let diskStart = 34
    static let externalAttributes = 38
    static let localHeaderOffset = 42
  }

  static func scan(fileAt url: URL) throws -> [ZipEntry] {
    try scan(Data(contentsOf: url, options: .mappedIfSafe))
  }

  /// Returns every entry, or throws when the archive cannot be read or any entry is unsafe to extract.
  static func scan(_ data: Data) throws -> [ZipEntry] {
    let data = Data(data) // zero-based indices whatever slice the caller passed
    let end = try endRecordOffset(in: data)
    guard data.le16(end + EndRecord.disk) == 0, data.le16(end + EndRecord.centralDirectoryDisk) == 0,
          data.le16(end + EndRecord.entriesOnDisk) == data.le16(end + EndRecord.totalEntries) else {
      throw ZipEntryScannerError.zip64Unsupported
    }
    guard end + endRecordSize + Int(data.le16(end + endRecordSize - 2)) == data.count else {
      throw ZipEntryScannerError.inconsistentDirectory
    }
    let count = data.le16(end + EndRecord.totalEntries)
    let size = data.le32(end + EndRecord.centralDirectorySize)
    let offset = data.le32(end + EndRecord.centralDirectoryOffset)
    // minizip also switches to its zip64 reader when the directory size is 0xFFFF (unzip.c:473).
    if count == zip64Marker16 || size == UInt32(zip64Marker16) || size == zip64Marker32 || offset == zip64Marker32 { throw ZipEntryScannerError.zip64Unsupported }
    // No gap: minizip starts at `end - size`, so any slack between directory and end record is a second directory.
    guard Int(offset) + Int(size) == end else { throw ZipEntryScannerError.inconsistentDirectory }

    var entries: [ZipEntry] = []
    var cursor = Int(offset)
    let limit = end
    while cursor < limit {
      guard cursor + centralEntryHeaderSize <= limit else { throw ZipEntryScannerError.truncated }
      guard data.le32(cursor) == centralEntrySignature else { throw ZipEntryScannerError.notAZip }
      if data.le32(cursor + CentralEntry.compressedSize) == zip64Marker32 || data.le32(cursor + CentralEntry.uncompressedSize) == zip64Marker32
        || data.le32(cursor + CentralEntry.localHeaderOffset) == zip64Marker32 || data.le16(cursor + CentralEntry.diskStart) == zip64Marker16 {
        throw ZipEntryScannerError.zip64Unsupported
      }
      let nameLength = Int(data.le16(cursor + CentralEntry.nameLength))
      let variableLength = nameLength + Int(data.le16(cursor + CentralEntry.extraLength)) + Int(data.le16(cursor + CentralEntry.commentLength))
      guard cursor + centralEntryHeaderSize + variableLength <= limit else { throw ZipEntryScannerError.truncated }
      let nameStart = cursor + centralEntryHeaderSize
      let rawName = data[nameStart..<(nameStart + nameLength)].prefix { $0 != 0 }
      // Lossy decoding on purpose: a failable decode would turn a name with one bad byte into "" and skip the checks.
      // swiftlint:disable:next optional_data_string_conversion
      let entry = ZipEntry(name: String(decoding: rawName, as: UTF8.self), externalAttributes: data.le32(cursor + CentralEntry.externalAttributes))
      try validate(entry, nameBytes: Array(rawName))
      entries.append(entry)
      cursor += centralEntryHeaderSize + variableLength
    }
    guard entries.count == Int(count) else { throw ZipEntryScannerError.inconsistentDirectory }
    return entries
  }

  /// The LAST end-record signature in the final 64 KiB (plus the record itself), as minizip finds it. Whether that
  /// record is consistent with the rest of the archive is the caller's check, not part of choosing it.
  private static func endRecordOffset(in data: Data) throws -> Int {
    let lowest = max(0, data.count - endRecordSize - maxCommentLength)
    var candidate = data.count - signatureSize
    while candidate >= lowest {
      if data.le32(candidate) == endRecordSignature {
        guard candidate + endRecordSize <= data.count else { throw ZipEntryScannerError.truncated }
        return candidate
      }
      candidate -= 1
    }
    throw ZipEntryScannerError.notAZip
  }

  /// Checked on the raw bytes, never on Swift `String` / `Character` operations: those group a `/` with a following
  /// combining mark into one grapheme, so a `..` component would hide from them while the kernel still sees the `/`.
  private static func validate(_ entry: ZipEntry, nameBytes: [UInt8]) throws {
    let path = nameBytes.map { $0 == backslashByte ? slashByte : $0 }
    let hasDriveLetter = path.count >= 2 && path[1] == colonByte && isASCIILetter(path[0])
    let isSymlink = (entry.externalAttributes >> unixModeShift) & fileTypeMask == symlinkType
    let hasParentComponent = path.split(separator: slashByte, omittingEmptySubsequences: false).contains { $0.elementsEqual([dotByte, dotByte]) }
    if path.first == slashByte || hasDriveLetter || isSymlink || hasParentComponent {
      throw ZipEntryScannerError.unsafeEntry(entry.name)
    }
  }

  private static func isASCIILetter(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
  }
}

private extension Data {
  func le16(_ offset: Int) -> UInt16 {
    UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
  }

  func le32(_ offset: Int) -> UInt32 {
    UInt32(le16(offset)) | UInt32(le16(offset + 2)) << 16
  }
}
