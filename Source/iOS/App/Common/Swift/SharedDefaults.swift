// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import PVLibrarySnapshot

enum SharedDefaults {
  /// Same object the ObjC side returns, so favorites written from TVGameItem.mm and
  /// last-played written here land in one suite.
  static var suite: UserDefaults { DOLSharedUserDefaults() }

  static var isAppGroupBacked: Bool { LibrarySnapshotAppGroup.isAvailable }

  private static let migratedKey = "shared_defaults_migrated_v1"
  static let migratedKeys = ["favorites_by_gameid", "library_added_dates_v1"]

  /// One-time copy of extension-relevant keys from `.standard` into the suite. The
  /// old values are left in place so a downgrade keeps working.
  static func migrateIfNeeded(from source: UserDefaults = .standard, to target: UserDefaults = suite) {
    guard source !== target, !target.bool(forKey: migratedKey) else { return }
    for key in migratedKeys where target.object(forKey: key) == nil {
      if let value = source.object(forKey: key) { target.set(value, forKey: key) }
    }
    target.set(true, forKey: migratedKey)
  }
}
