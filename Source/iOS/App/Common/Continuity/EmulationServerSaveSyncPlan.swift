// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One save file as three checksums: the file on this device, the server's live file, and what this device
/// and the server last agreed on. The third is what tells "I changed it" from "another device changed it";
/// the server keeps no file time and no device per save, so clocks are not used at all.
struct SaveSyncState: Equatable, Sendable {
  var local: String?
  var remote: String?
  var base: String?
}

enum SaveSyncStep: Equatable, Sendable {
  /// Send this device's file; it becomes the server's live file and the server keeps the old one as a copy.
  case upload
  /// Take the server's file; the file it replaces here goes to Recently Deleted.
  case download
  /// Both sides already hold the same bytes: remember that.
  case settle
  /// Changed on both sides, or never synced and different: only the user may pick one.
  case conflict
}

enum SaveSyncPlanner {
  /// What to do with one file, or nil when there is nothing to do.
  ///
  /// Deletions are deliberately not carried across: a save deleted here stays deleted here and stays on the
  /// server, and a save missing from the server is sent again. Nothing is ever removed on either side.
  static func step(for state: SaveSyncState) -> SaveSyncStep? {
    switch (state.local, state.remote) {
    case (nil, nil):
      return nil
    case (.some, nil):
      return .upload
    case (nil, .some(let remote)):
      // Deleted here after it was synced, and unchanged there since: leave both as they are.
      return remote == state.base ? nil : .download
    case (.some(let local), .some(let remote)):
      if local == remote { return local == state.base ? nil : .settle }
      if state.base == local { return .download }
      if state.base == remote { return .upload }
      return .conflict
    }
  }

  /// Every file that needs something done, by path relative to the user folder.
  static func plan(local: [String: String], remote: [String: String], base: [String: String]) -> [String: SaveSyncStep] {
    var steps: [String: SaveSyncStep] = [:]
    for path in Set(local.keys).union(remote.keys) {
      steps[path] = step(for: SaveSyncState(local: local[path], remote: remote[path], base: base[path]))
    }
    return steps
  }
}

/// Where synced saves live inside the server's backup destination. Per-device backups sit beside it under
/// `iCube/<device id>/`, so the two never collide.
enum SaveSyncPaths {
  static let prefix = "iCube/shared/"
  /// The server renames a save it keeps as history or parks as a conflict to `<path>.conflict-<8 hex>`.
  private static let copyMarker = ".conflict-"
  private static let copySuffixLength = 8

  static func remotePath(for relativePath: String) -> String {
    prefix + relativePath
  }

  /// The local path of a live shared save, or nil for anything else in the destination.
  static func relativePath(fromRemote path: String) -> String? {
    guard path.hasPrefix(prefix), !isServerCopy(path) else { return nil }
    let relative = String(path.dropFirst(prefix.count))
    return relative.isEmpty ? nil : relative
  }

  static func isServerCopy(_ path: String) -> Bool {
    guard let marker = path.range(of: copyMarker, options: .backwards) else { return false }
    let suffix = path[marker.upperBound...]
    return suffix.count == copySuffixLength && suffix.allSatisfy { $0.isHexDigit }
  }
}
