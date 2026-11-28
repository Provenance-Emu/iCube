// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Decides, before a byte is fetched, whether a server game fits on this device.
enum RemoteDownloadSpace {
  /// Kept free beyond the game itself, for the journal, covers and whatever else writes meanwhile.
  static let margin: Int64 = 256 * 1024 * 1024

  /// A game that does not fit, with both numbers for the message.
  struct Shortfall: LocalizedError, Equatable {
    let needed: Int64
    let available: Int64

    var errorDescription: String? {
      String(format: L("Not enough free space: this needs about %@ and %@ is available."),
             ByteCountFormatter.string(fromByteCount: needed, countStyle: .file),
             ByteCountFormatter.string(fromByteCount: available, countStyle: .file))
    }
  }

  /// One file of the game: its size on the server, and whether it is unpacked after it arrives.
  struct File: Equatable {
    var bytes: Int64
    var isArchive: Bool
  }

  /// The most disk the game needs at one moment beyond what is already here. A plain disc image is
  /// renamed from the download into the library, so it is on disk once. An archive is on disk
  /// beside what it unpacks to, which is at least its own size. `storedBytes` is what an earlier
  /// attempt already brought in: counting it again would refuse a game that is already on disk.
  static func neededBytes(files: [File], storedBytes: Int64) -> Int64 {
    let download = files.reduce(Int64(0)) { $0.addingClamped(max(0, $1.bytes)) }
    let unpacked = files.filter(\.isArchive).reduce(Int64(0)) { $0.addingClamped(max(0, $1.bytes)) }
    let remaining = max(0, download - max(0, storedBytes))
    return remaining.addingClamped(unpacked).addingClamped(margin)
  }

  /// Nil when the game fits, or when the free space is unknown: a refusal needs a measurement.
  static func shortfall(files: [File], storedBytes: Int64, availableBytes: Int64?) -> Shortfall? {
    guard let availableBytes else { return nil }
    let needed = neededBytes(files: files, storedBytes: storedBytes)
    return availableBytes < needed ? Shortfall(needed: needed, available: availableBytes) : nil
  }

  /// The free space to trust out of the two the system reports. "Important usage" counts what the
  /// system would purge to make room and is the larger one when it works, but it has been seen to
  /// report zero or far too little; the plain figure is what is free this instant. The larger of
  /// the two is the best lower bound on what a download can use.
  static func trustedAvailableBytes(importantUsage: Int64?, plain: Int64?) -> Int64? {
    switch (importantUsage, plain) {
    case (nil, nil): return nil
    case (let value?, nil), (nil, let value?): return value
    case (let important?, let plain?): return max(important, plain)
    }
  }

  /// Free space on the volume holding `url`.
  static func availableBytes(at url: URL) -> Int64? {
    let plain = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
    #if os(tvOS)
    // tvOS has no "important usage" capacity.
    return trustedAvailableBytes(importantUsage: nil, plain: plain)
    #else
    let important = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
      .volumeAvailableCapacityForImportantUsage
    return trustedAvailableBytes(importantUsage: important, plain: plain)
    #endif
  }

  /// Free space where the app keeps its games and downloads.
  static func availableBytesForGames() -> Int64? {
    availableBytes(at: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
  }
}

private extension Int64 {
  func addingClamped(_ other: Int64) -> Int64 {
    let (sum, overflow) = addingReportingOverflow(other)
    return overflow ? .max : sum
  }
}
