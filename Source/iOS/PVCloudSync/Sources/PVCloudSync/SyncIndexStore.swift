// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What this device last knew about one synced path.
public struct SyncIndexEntry: Codable, Equatable, Sendable {
    /// Checksum of the content as of the last successful sync of this path.
    public var checksum: String
    /// Local modification date as of that sync.
    public var lastModified: Date
    /// When that sync happened.
    public var syncedAt: Date
    /// Set once this device has applied or emitted a delete for the path. A
    /// path with `deletedAt` set is known-gone; a live remote record for it
    /// means somebody brought it back.
    public var deletedAt: Date?

    public init(checksum: String, lastModified: Date, syncedAt: Date, deletedAt: Date? = nil) {
        self.checksum = checksum
        self.lastModified = lastModified
        self.syncedAt = syncedAt
        self.deletedAt = deletedAt
    }

    /// The path is one we synced and have not since seen deleted.
    public var isLive: Bool { deletedAt == nil }
}

/// An immutable copy of the index for the planner, which is pure and must not
/// touch an actor.
public struct SyncIndexSnapshot: Equatable, Sendable {
    public var entries: [String: SyncIndexEntry]

    public init(entries: [String: SyncIndexEntry] = [:]) {
        self.entries = entries
    }

    public static let empty = SyncIndexSnapshot()

    public subscript(path: String) -> SyncIndexEntry? { entries[path] }
}

/// Persistent memory of what this device has synced.
///
/// Without it the engine cannot tell "deleted here since last sync" from
/// "never had it", and so could never emit a tombstone. It is a small JSON
/// file: a few hundred paths at most, rewritten after each run.
///
/// Where it lives is the caller's choice. On iOS that is Application Support;
/// on tvOS only Caches is writable, so the index can be purged. That is
/// tolerated: a missing index means one additive run (nothing is deleted on the
/// strength of an empty index) while the index is rebuilt from what that run
/// uploads and downloads.
///
/// The index also remembers which account it belongs to. Two iCloud accounts
/// must never share one, or a sign-out and sign-in would read one account's
/// deletions as the other's.
public actor SyncIndexStore {

    private struct OnDisk: Codable {
        var version: Int
        var accountIdentity: String?
        var entries: [String: SyncIndexEntry]
    }

    private static let formatVersion = 1

    public let fileURL: URL
    private var entries: [String: SyncIndexEntry] = [:]
    private var accountIdentity: String?
    private var loaded = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - Reading

    public func snapshot() -> SyncIndexSnapshot {
        loadIfNeeded()
        return SyncIndexSnapshot(entries: entries)
    }

    public func entry(for path: String) -> SyncIndexEntry? {
        loadIfNeeded()
        return entries[path]
    }

    public func storedAccountIdentity() -> String? {
        loadIfNeeded()
        return accountIdentity
    }

    public var count: Int {
        loadIfNeeded()
        return entries.count
    }

    // MARK: - Writing

    /// Record a successful sync of `path` with this content.
    public func record(path: String, checksum: String, lastModified: Date, syncedAt: Date = Date()) {
        loadIfNeeded()
        entries[path] = SyncIndexEntry(checksum: checksum, lastModified: lastModified, syncedAt: syncedAt)
    }

    /// Record that `path` is gone: this device trashed its copy because of a
    /// remote tombstone, or emitted a tombstone because the user deleted it.
    public func markDeleted(path: String, at date: Date = Date()) {
        loadIfNeeded()
        if var existing = entries[path] {
            existing.deletedAt = date
            entries[path] = existing
        } else {
            entries[path] = SyncIndexEntry(checksum: "", lastModified: date, syncedAt: date, deletedAt: date)
        }
    }

    /// Forget a path entirely.
    public func remove(path: String) {
        loadIfNeeded()
        entries.removeValue(forKey: path)
    }

    /// Bind the index to an account. If it already belongs to a different one,
    /// it is wiped first and `true` is returned so the caller can log it.
    @discardableResult
    public func bind(toAccountIdentity identity: String?) -> Bool {
        loadIfNeeded()
        guard let identity else { return false }
        if let existing = accountIdentity, existing != identity {
            entries.removeAll()
            accountIdentity = identity
            return true
        }
        accountIdentity = identity
        return false
    }

    /// Wipe everything, including the account binding.
    public func reset() {
        loaded = true
        entries.removeAll()
        accountIdentity = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Persist. Atomic, so a crash mid-write leaves the previous index intact.
    public func save() throws {
        loadIfNeeded()
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(OnDisk(version: Self.formatVersion, accountIdentity: accountIdentity, entries: entries))
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Loading

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // An unreadable index is treated as absent: one additive run, then it
        // is rebuilt. Never let a corrupt file stop sync.
        guard let onDisk = try? decoder.decode(OnDisk.self, from: data),
              onDisk.version == Self.formatVersion else { return }
        entries = onDisk.entries
        accountIdentity = onDisk.accountIdentity
    }
}
