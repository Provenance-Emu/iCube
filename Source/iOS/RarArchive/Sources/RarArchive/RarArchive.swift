// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CLibArchiveRAR
import Foundation

/// Reads RAR and RAR5 archives. Extraction only: nothing here can create one.
///
/// Encrypted archives are refused, as are archives whose entries would be written outside the
/// destination. Links, devices and other entries that are not plain files are never written.
public enum RarArchive {
  public struct Entry: Equatable {
    /// Path inside the archive, `/`-separated.
    public let path: String
    public let size: Int64
    public let isDirectory: Bool
    /// False for links and anything else that is neither a file nor a folder.
    public let isRegularFile: Bool
  }

  public enum Failure: Error, Equatable {
    case cannotOpen(String)
    case encrypted
    case damaged(String)
    /// An entry whose path is absolute or climbs out of the destination.
    case unsafePath(String)
    /// The archive unpacks to more than the caller allowed.
    case tooLarge(limit: Int64)
  }

  private static let blockSize = 64 * 1024
  private static let signatures: [[UInt8]] = [
    [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00],        // RAR 1.5 to 4
    [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00],  // RAR 5
  ]

  /// Whether the file starts with a RAR signature, whatever it is called.
  public static func isRarFile(at url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    let head = [UInt8]((try? handle.read(upToCount: 8)) ?? Data())
    return signatures.contains { head.starts(with: $0) }
  }

  /// Every entry of the archive, in archive order.
  public static func entries(ofArchiveAt url: URL) throws -> [Entry] {
    try withUTF8Locale {
      try withReader(url) { reader in
        var entries: [Entry] = []
        while let header = try nextHeader(reader) {
          entries.append(try describe(header))
          archive_read_data_skip(reader)
        }
        return entries
      }
    }
  }

  /// Unpacks the archive's plain files under `destination`, which is created if needed. Every path
  /// is checked before the first byte is written, so a refused archive writes nothing. Returns
  /// the files written.
  @discardableResult
  public static func extract(archiveAt url: URL, to destination: URL, maximumBytes: Int64? = nil) throws -> [URL] {
    let listed = try entries(ofArchiveAt: url)
    if let maximumBytes {
      let total = listed.reduce(Int64(0)) { $0 + max(0, $1.size) }
      guard total <= maximumBytes else { throw Failure.tooLarge(limit: maximumBytes) }
    }
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

    return try withUTF8Locale {
      try withReader(url) { reader in
        var written: [URL] = []
        var writtenBytes: Int64 = 0
        while let header = try nextHeader(reader) {
          let entry = try describe(header)
          guard entry.isRegularFile else {
            archive_read_data_skip(reader)
            continue
          }
          let target = entry.path.split(separator: "/").reduce(destination) { $0.appendingPathComponent(String($1)) }
          try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
          try? fileManager.removeItem(at: target)
          guard fileManager.createFile(atPath: target.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
          }
          let handle = try FileHandle(forWritingTo: target)
          defer { try? handle.close() }
          try copyData(of: reader, to: handle, writtenBytes: &writtenBytes, maximumBytes: maximumBytes)
          written.append(target)
        }
        return written
      }
    }
  }

  // MARK: - Reading

  private static func withReader<Result>(_ url: URL, _ body: (OpaquePointer) throws -> Result) throws -> Result {
    guard let reader = archive_read_new() else { throw Failure.cannotOpen("out of memory") }
    defer { archive_read_free(reader) }
    archive_read_support_format_rar(reader)
    archive_read_support_format_rar5(reader)
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw Failure.cannotOpen(String(cString: strerror(errno))) }
    defer { close(descriptor) }
    guard archive_read_open_fd(reader, descriptor, blockSize) == ARCHIVE_OK else {
      throw Failure.cannotOpen(message(of: reader))
    }
    return try body(reader)
  }

  /// The next entry's header, or nil at the end of the archive.
  private static func nextHeader(_ reader: OpaquePointer) throws -> OpaquePointer? {
    var header: OpaquePointer?
    let status = archive_read_next_header(reader, &header)
    if status == ARCHIVE_EOF { return nil }
    if archive_read_has_encrypted_entries(reader) > 0 { throw Failure.encrypted }
    guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let header else {
      let text = message(of: reader)
      throw text.localizedCaseInsensitiveContains("encrypt") ? Failure.encrypted : Failure.damaged(text)
    }
    if archive_entry_is_encrypted(header) != 0 { throw Failure.encrypted }
    return header
  }

  private static func describe(_ header: OpaquePointer) throws -> Entry {
    let raw = (archive_entry_pathname_utf8(header) ?? archive_entry_pathname(header)).map { String(cString: $0) } ?? ""
    let path = raw.replacingOccurrences(of: "\\", with: "/")
    // "." alone names the destination itself, which an entry must never replace.
    let components = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
    guard !components.isEmpty, !path.hasPrefix("/"), !components.contains(".."), !path.contains("\0") else {
      throw Failure.unsafePath(raw)
    }
    let type = archive_entry_filetype(header)
    let isLink = archive_entry_symlink(header) != nil || archive_entry_hardlink(header) != nil
    return Entry(
      path: components.joined(separator: "/"),
      size: archive_entry_size(header),
      isDirectory: type == mode_t(S_IFDIR),
      isRegularFile: type == mode_t(S_IFREG) && !isLink
    )
  }

  private static func copyData(of reader: OpaquePointer, to handle: FileHandle, writtenBytes: inout Int64,
                               maximumBytes: Int64?) throws {
    var buffer: UnsafeRawPointer?
    var size = 0
    var offset: Int64 = 0
    while true {
      let status = archive_read_data_block(reader, &buffer, &size, &offset)
      if status == ARCHIVE_EOF { return }
      guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
        let text = message(of: reader)
        throw text.localizedCaseInsensitiveContains("encrypt") ? Failure.encrypted : Failure.damaged(text)
      }
      guard let buffer, size > 0 else { continue }
      writtenBytes += Int64(size)
      // The sizes in the headers are only a claim; the bytes that really come out are counted too.
      if let maximumBytes, writtenBytes > maximumBytes { throw Failure.tooLarge(limit: maximumBytes) }
      try handle.seek(toOffset: UInt64(offset))
      try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: buffer), count: size, deallocator: .none))
    }
  }

  private static func message(of reader: OpaquePointer) -> String {
    archive_error_string(reader).map { String(cString: $0) } ?? "unknown error"
  }

  /// RAR 4 stores names as UTF-16 and libarchive converts them to the thread's character set, which
  /// is plain ASCII in an app that never called `setlocale`. This gives the calling thread a UTF-8
  /// locale for the duration of `body`, without touching the process-wide one.
  private static func withUTF8Locale<Result>(_ body: () throws -> Result) rethrows -> Result {
    guard let utf8 = newlocale(LC_CTYPE_MASK, "en_US.UTF-8", nil) else { return try body() }
    let previous = uselocale(utf8)
    defer {
      uselocale(previous)
      freelocale(utf8)
    }
    return try body()
  }
}

extension RarArchive.Failure: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .cannotOpen(let detail): return "The RAR archive could not be opened (\(detail))."
    case .encrypted: return "The RAR archive is password-protected."
    case .damaged(let detail): return "The RAR archive could not be read (\(detail))."
    case .unsafePath(let path): return "The RAR archive holds a file that would be written outside its folder (\(path))."
    case .tooLarge: return "The RAR archive unpacks to more than is allowed here."
    }
  }
}
