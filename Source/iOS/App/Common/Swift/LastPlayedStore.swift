// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// `[gameID: unix seconds]` in the shared suite. Written from the emulation launch
/// chokepoint (see LibrarySnapshotService), read by the snapshot writer.
enum LastPlayedStore {
  static let key = "last_played_v1"

  static func record(gameID: String, date: Date = Date(), in defaults: UserDefaults = SharedDefaults.suite) {
    guard !gameID.isEmpty else { return }
    var map = load(from: defaults)
    map[gameID] = date.timeIntervalSince1970
    defaults.set(map, forKey: key)
  }

  static func lastPlayed(gameID: String, in defaults: UserDefaults = SharedDefaults.suite) -> Date? {
    load(from: defaults)[gameID].map { Date(timeIntervalSince1970: $0) }
  }

  static func all(in defaults: UserDefaults = SharedDefaults.suite) -> [String: Date] {
    load(from: defaults).mapValues { Date(timeIntervalSince1970: $0) }
  }

  private static func load(from defaults: UserDefaults) -> [String: TimeInterval] {
    defaults.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
  }
}
