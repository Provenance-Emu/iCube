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
  /// The central directory runs past the end of the data, or its entry count disagrees with its contents.
  case truncated
  /// The archive uses zip64 (or spans disks), which this scanner does not read.
  case zip64Unsupported
  /// An entry that could write outside the extraction folder, or is a symbolic link. Carries the entry name.
  case unsafeEntry(String)
}

/// Reads a zip's central directory without extracting anything, so an archive can be checked for
/// path-traversal ("zip slip") and symlink entries before an extractor that does not check them runs.
enum ZipEntryScanner {
  private static let endRecordSignature: UInt32 = 0x0605_4B50
  private static let centralEntrySignature: UInt32 = 0x0201_4B50
  private static let endRecordSize = 22
  private static let centralEntryHeaderSize = 46
  private static let maxCommentLength = 0xFFFF
  private static let zip64Marker16: UInt16 = 0xFFFF
  private static let zip64Marker32: UInt32 = 0xFFFF_FFFF
  private static let unixModeShift: UInt32 = 16
  private static let fileTypeMask: UInt32 = 0o170000
  private static let symlinkType: UInt32 = 0o120000
  private static let parentComponent = ".."

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
    let count = data.le16(end + EndRecord.totalEntries)
    let size = data.le32(end + EndRecord.centralDirectorySize)
    let offset = data.le32(end + EndRecord.centralDirectoryOffset)
    if count == zip64Marker16 || size == zip64Marker32 || offset == zip64Marker32 { throw ZipEntryScannerError.zip64Unsupported }
    guard Int(offset) + Int(size) <= end else { throw ZipEntryScannerError.truncated }

    var entries: [ZipEntry] = []
    var cursor = Int(offset)
    let limit = Int(offset) + Int(size)
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
      try validate(entry)
      entries.append(entry)
      cursor += centralEntryHeaderSize + variableLength
    }
    guard entries.count == Int(count) else { throw ZipEntryScannerError.truncated }
    return entries
  }

  /// The end record is the last 22 bytes unless the archive carries a trailing comment, so look backwards for it.
  private static func endRecordOffset(in data: Data) throws -> Int {
    guard data.count >= endRecordSize else { throw ZipEntryScannerError.notAZip }
    let lowest = max(0, data.count - endRecordSize - maxCommentLength)
    var candidate = data.count - endRecordSize
    while candidate >= lowest {
      if data.le32(candidate) == endRecordSignature {
        let commentLength = Int(data.le16(candidate + endRecordSize - 2))
        if candidate + endRecordSize + commentLength == data.count { return candidate }
      }
      candidate -= 1
    }
    throw ZipEntryScannerError.notAZip
  }

  private static func validate(_ entry: ZipEntry) throws {
    let path = entry.name.replacingOccurrences(of: "\\", with: "/")
    let characters = Array(path)
    let hasDriveLetter = characters.count >= 2 && characters[1] == ":" && characters[0].isASCII && characters[0].isLetter
    let isSymlink = (entry.externalAttributes >> unixModeShift) & fileTypeMask == symlinkType
    if path.hasPrefix("/") || hasDriveLetter || isSymlink || path.split(separator: "/", omittingEmptySubsequences: false).contains(Substring(parentComponent)) {
      throw ZipEntryScannerError.unsafeEntry(entry.name)
    }
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
