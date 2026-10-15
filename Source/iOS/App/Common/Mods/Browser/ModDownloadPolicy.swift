// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation

/// Decides, before a byte is fetched, whether a download may start.
enum ModDownloadPolicy {
  /// An archive is on disk three times at the peak: as downloaded, as the extractor's private
  /// copy, and unpacked.
  static let diskMultiplier: Int64 = 3

  enum Verdict: Equatable {
    case allowed
    /// Fine to download, but big enough that the user should confirm.
    case confirmLargeDownload(bytes: Int64)
    case insufficientSpace(needed: Int64, available: Int64)
  }

  static func verdict(fileSize: Int64, availableBytes: Int64?) -> Verdict {
    if let availableBytes, fileSize * diskMultiplier > availableBytes {
      return .insufficientSpace(needed: fileSize * diskMultiplier, available: availableBytes)
    }
    return fileSize > ModBrowser.largeDownloadBytes ? .confirmLargeDownload(bytes: fileSize) : .allowed
  }

  /// Space the system would free for an important download on the volume holding `url`.
  static func availableBytes(at url: URL) -> Int64? {
    #if os(tvOS)
    // tvOS has no "important usage" capacity.
    return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
    #else
    return try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
    #endif
  }

  /// Lowercase hex MD5 of a file, read in chunks so a multi-gigabyte download costs no memory.
  /// MD5 is only the integrity check GameBanana publishes, not a security measure.
  static func md5(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = Insecure.MD5()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Checks `url` against GameBanana's published checksum; a file with none passes.
  static func verifyChecksum(of url: URL, expected: String?) throws {
    guard let expected, !expected.isEmpty else { return }
    let actual = try md5(of: url)
    guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
      throw ModDownloadError.checksumMismatch(expected: expected.lowercased(), actual: actual)
    }
  }
}

enum ModDownloadError: LocalizedError, Equatable {
  case noDownloadURL
  case unsafeFileName(String)
  case status(Int)
  case checksumMismatch(expected: String, actual: String)

  var errorDescription: String? {
    switch self {
    case .noDownloadURL: return L("GameBanana lists no download link for this file.")
    case .unsafeFileName(let name): return String(format: L("The file name “%@” is not safe to save."), name)
    case .status(let code): return String(format: L("The download server answered with HTTP %d."), code)
    case .checksumMismatch: return L("The downloaded file does not match GameBanana's checksum, so it was discarded.")
    }
  }
}
