// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVCloudSync

/// Owner of `<UserFolder>/Profiles/library_state.json`: favorites, last played,
/// launch counts and play time per game, as a `LibraryStateDocument` that
/// `PVCloudSync` merges across devices.
///
/// Favorites and last-played also live in the shared `UserDefaults` suite, where
/// TopShelf, the snapshot writer and the Objective-C favorites toggle read and
/// write them. This store keeps the two in step: it imports from the suite at
/// init (missing records only) and whenever `FavoritesChanged` fires.
/// `reloadAfterSync()` writes a merged document back into the suite so every existing reader keeps working.
final class LibraryStateStore {
  static let shared = LibraryStateStore()

  /// Posted by the Objective-C favorites writer and, with `object: self`, by
  /// `reloadAfterSync()` so UI refreshes. The import ignores our own posts.
  static let favoritesChangedNotification = Notification.Name("FavoritesChanged")

  private static let favoritesKey = "favorites_by_gameid"

  // Sync's scanner transaction and every store instance use the same short lock.
  // It never spans network I/O; recursive acquisition permits store helpers.
  private static let fileAccessLock = NSRecursiveLock()
  private let lock = LibraryStateStore.fileAccessLock

  static func withFileAccess<T>(_ operation: () throws -> T) rethrows -> T {
    fileAccessLock.lock()
    defer { fileAccessLock.unlock() }
    return try operation()
  }
  private let fileURL: URL?
  private let defaults: UserDefaults
  private let deviceID: String
  private var lastMirroredFavorites: [String: Bool] = [:]
  private var document: LibraryStateDocument
  private var observer: NSObjectProtocol?

  private convenience init() {
    self.init(fileURL: Self.defaultFileURL(), defaults: SharedDefaults.suite, deviceID: SyncDeviceIdentity.deviceIdentifier())
  }

  /// `fileURL == nil` keeps the document in memory only (tests).
  init(fileURL: URL?, defaults: UserDefaults, deviceID: String) {
    self.fileURL = fileURL
    self.defaults = defaults
    self.deviceID = deviceID
    self.document = LibraryStateDocument()
    self.document = Self.load(from: fileURL)
    importFromSharedDefaults(onlyMissingFavorites: true)
    reloadAfterSync()
    observer = NotificationCenter.default.addObserver(
      forName: Self.favoritesChangedNotification, object: nil, queue: nil
    ) { [weak self] note in
      guard let self, (note.object as AnyObject?) !== self else { return }
      self.importFromSharedDefaults()
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  // MARK: - Reads

  func state(for gameID: String) -> LibraryStateDocument.GameState? {
    guard !gameID.isEmpty else { return nil }
    return locked { document.games[gameID] }
  }

  func playSeconds(for gameID: String) -> Int {
    state(for: gameID)?.totalPlaySeconds ?? 0
  }

  func launchCount(for gameID: String) -> Int {
    state(for: gameID)?.totalLaunches ?? 0
  }

  func lastPlayed(for gameID: String) -> Date? {
    state(for: gameID)?.lastPlayed
  }

  func isFavorite(_ gameID: String) -> Bool {
    state(for: gameID)?.isFavorite ?? false
  }

  var totalPlaySeconds: Int {
    locked { document.games.values.reduce(0) { $0 + $1.totalPlaySeconds } }
  }

  // MARK: - Writes

  /// Counts a launch on this device and raises last-played to `date`.
  func recordLaunch(gameID: String, at date: Date = Date()) {
    mutate(gameID) { state in
      state.launches[deviceID, default: 0] += 1
      state.lastPlayed = Self.later(state.lastPlayed, Self.wholeSeconds(date))
    }
  }

  /// Adds play time to this device's slot.
  func addPlaySeconds(_ seconds: Int, gameID: String) {
    guard seconds > 0 else { return }
    mutate(gameID) { state in
      state.playSeconds[deviceID, default: 0] += seconds
    }
  }

  func setFavorite(_ value: Bool, gameID: String, at date: Date = Date()) {
    mutate(gameID) { state in
      guard state.favorite?.value != value else { return }
      // Whole-second serialization must still order rapid favorite/unfavorite edits.
      let stamp = max(Self.wholeSeconds(date), state.favorite.map { $0.updatedAt.addingTimeInterval(1) } ?? .distantPast)
      state.favorite = .init(value: value, updatedAt: stamp)
    }
    reloadAfterSync()
  }

  /// Raises last-played to `date` if it is later than what is recorded.
  func recordLastPlayed(gameID: String, date: Date) {
    mutate(gameID) { state in
      state.lastPlayed = Self.later(state.lastPlayed, Self.wholeSeconds(date))
    }
  }

  // MARK: - Mirroring with the shared suite

  /// Pulls favorites and last-played out of the suite. A favorite that differs
  /// from the document's value is stamped `now`; last-played takes the later
  /// date. Saves only when something changed.
  func importFromSharedDefaults(now: Date = Date(), onlyMissingFavorites: Bool = false) {
    let favorites = defaults.dictionary(forKey: Self.favoritesKey) as? [String: Bool] ?? [:]
    let lastPlayed = LastPlayedStore.all(in: defaults)
    let stamp = Self.wholeSeconds(now)
    lock.lock()
    defer { lock.unlock() }
    let current = LibraryStateDocument.merge(document, Self.load(from: fileURL))
    var changed = current != document
    document = current
    for (gameID, value) in favorites where !gameID.isEmpty {
      // A notification for one local edit must not restamp unrelated stale
      // mirror values over remote edits committed just before the reload.
      guard onlyMissingFavorites || lastMirroredFavorites[gameID] != value else { continue }
      var state = document.games[gameID] ?? .init()
      if state.favorite?.value != value && (!onlyMissingFavorites || state.favorite == nil) {
        state.favorite = .init(value: value, updatedAt: max(stamp, state.favorite.map { $0.updatedAt.addingTimeInterval(1) } ?? .distantPast))
        document.games[gameID] = state
        changed = true
      }
    }
    for (gameID, date) in lastPlayed where !gameID.isEmpty {
      var state = document.games[gameID] ?? .init()
      let date = Self.wholeSeconds(date)
      if let existing = state.lastPlayed, existing >= date { continue }
      state.lastPlayed = date
      document.games[gameID] = state
      changed = true
    }
    lastMirroredFavorites = favorites
    if changed { saveLocked() }
  }

  /// Call after sync wrote a merged `library_state.json`: reloads it, copies
  /// favorites and later last-played dates into the suite, and posts
  /// `FavoritesChanged` (with `object: self`) so UI and snapshot writers refresh.
  /// Retain in-memory edits if a transfer used an older snapshot of this file.
  func reloadAfterSync() {
    lock.lock()
    let disk = Self.load(from: fileURL)
    let merged = LibraryStateDocument.merge(document, disk)
    document = merged
    // Preserve edits made during a transfer and recover missing/purged files.
    if merged != disk { saveLocked() }
    var favorites = defaults.dictionary(forKey: Self.favoritesKey) as? [String: Bool] ?? [:]
    var lastPlayed = LastPlayedStore.all(in: defaults)
    var played: [String: TimeInterval] = [:]
    for (gameID, state) in document.games {
      if let favorite = state.favorite { favorites[gameID] = favorite.value }
      if let date = state.lastPlayed, date > (lastPlayed[gameID] ?? .distantPast) {
        lastPlayed[gameID] = date
        played[gameID] = date.timeIntervalSince1970
      }
    }
    lastMirroredFavorites = favorites
    defaults.set(favorites, forKey: Self.favoritesKey)
    if !played.isEmpty {
      let merged = lastPlayed.mapValues { $0.timeIntervalSince1970 }
      defaults.set(merged, forKey: LastPlayedStore.key)
    }
    lock.unlock()
    NotificationCenter.default.post(name: Self.favoritesChangedNotification, object: self)
  }

  // MARK: - Internals

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private func mutate(_ gameID: String, _ change: (inout LibraryStateDocument.GameState) -> Void) {
    guard !gameID.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    // A sync commit may have finished before its UI reload notification arrives.
    // Always incorporate its file before a new local edit can write stale memory.
    document = LibraryStateDocument.merge(document, Self.load(from: fileURL))
    var state = document.games[gameID] ?? .init()
    let before = state
    change(&state)
    guard state != before else { return }
    document.games[gameID] = state.isEmpty ? nil : state
    saveLocked()
  }

  /// Caller holds `lock`.
  private func saveLocked() {
    guard let fileURL else { return }
    do {
      try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try document.encoded().write(to: fileURL, options: .atomic)
    } catch {
      NSLog("[LibraryStateStore] save failed: \(error)")
    }
  }

  private static func load(from fileURL: URL?) -> LibraryStateDocument {
    guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return LibraryStateDocument() }
    do {
      return try LibraryStateDocument.decode(data)
    } catch {
      NSLog("[LibraryStateStore] could not decode library_state.json: \(error)")
      return LibraryStateDocument()
    }
  }

  private static func defaultFileURL() -> URL? {
    let base = UserFolderUtil.getUserFolder()
    let dir = URL(fileURLWithPath: base).appendingPathComponent("Profiles", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("library_state.json")
  }

  /// The document stores ISO 8601 without fractions, so truncate up front;
  /// otherwise a date would never compare equal to its own round trip and the
  /// import would rewrite the file every time.
  private static func wholeSeconds(_ date: Date) -> Date {
    Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
  }

  private static func later(_ a: Date?, _ b: Date) -> Date {
    guard let a else { return b }
    return max(a, b)
  }
}
