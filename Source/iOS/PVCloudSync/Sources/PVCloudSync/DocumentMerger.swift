// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVSyncRules

/// Merges two copies of one file field by field instead of picking a winner.
///
/// Used for the categories whose `mergeKind` is `.document`. A merger must be
/// commutative, associative and idempotent: `merge(a, b) == merge(b, a)`,
/// merging a third copy in any order gives the same bytes, and merging a result
/// with itself changes nothing. That is what lets any number of devices converge
/// without coordination, and it is what the tests check.
public protocol DocumentMerger: Sendable {
    func merge(local: Data, remote: Data) throws -> Data
}

public enum DocumentMergeError: Error, Equatable {
    case notAnObject
    case unsupportedCategory
}

/// Which merger handles which category.
public enum DocumentMergers {
    public static func merger(for type: SyncableFileType) -> (any DocumentMerger)? {
        switch type {
        case .libraryState: return LibraryStateDocumentMerger()
        case .gameProfile: return KeyedTimestampDocumentMerger(timestampKey: "updatedAt")
        default: return nil
        }
    }
}

// MARK: - Keyed last-writer-wins

/// Merges a JSON object of records keyed by ID, keeping for each key the record
/// with the newer timestamp field.
///
/// Built for `game_profiles.json`: a `[GameID: GameProfile]` dictionary where
/// each profile carries an optional `updatedAt`. The merger knows nothing about
/// `GameProfile`; it treats each value as an opaque object and reads one field.
///
/// Timestamp forms accepted: a number (seconds since the reference date, which
/// is what `JSONEncoder`'s default date strategy writes, or since 1970 — only
/// the ordering matters and both are monotonic) or an ISO 8601 string. A record
/// with no timestamp counts as oldest, so a stamped edit always beats one made
/// before stamping existed. Two equal stamps are broken by comparing the
/// serialized bytes, so the choice is deterministic rather than side-dependent.
public struct KeyedTimestampDocumentMerger: DocumentMerger {

    public let timestampKey: String

    public init(timestampKey: String) {
        self.timestampKey = timestampKey
    }

    public func merge(local: Data, remote: Data) throws -> Data {
        let a = try Self.object(from: local)
        let b = try Self.object(from: remote)
        var merged: [String: Any] = [:]
        for key in Set(a.keys).union(b.keys) {
            switch (a[key], b[key]) {
            case (let x?, nil): merged[key] = x
            case (nil, let y?): merged[key] = y
            case (let x?, let y?): merged[key] = pick(x, y)
            case (nil, nil): break
            }
        }
        return try Self.canonicalJSON(merged)
    }

    private func pick(_ x: Any, _ y: Any) -> Any {
        let tx = timestamp(of: x)
        let ty = timestamp(of: y)
        if tx != ty { return tx > ty ? x : y }
        // Same stamp (or neither stamped): deterministic tie-break on bytes.
        let sx = (try? Self.canonicalJSON(x)) ?? Data()
        let sy = (try? Self.canonicalJSON(y)) ?? Data()
        return sx.lexicographicallyPrecedes(sy) ? y : x
    }

    private func timestamp(of value: Any) -> Double {
        guard let object = value as? [String: Any], let raw = object[timestampKey] else { return -Double.infinity }
        if let number = raw as? NSNumber { return number.doubleValue }
        if let string = raw as? String {
            if let date = ISO8601DateFormatter().date(from: string) { return date.timeIntervalSinceReferenceDate }
            if let number = Double(string) { return number }
        }
        return -Double.infinity
    }

    static func object(from data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DocumentMergeError.notAnObject
        }
        return object
    }

    /// Sorted keys, so equal content is equal bytes — the property the
    /// idempotence check and the checksum-based "already synced" fast path both
    /// depend on.
    static func canonicalJSON(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}

// MARK: - Library state

/// `Profiles/library_state.json`: favorites, last played, launches and play
/// time per game. Version 1.
///
/// Counters are kept per device (a G-Counter): each device only ever raises its
/// own slot, and the merge takes the maximum per slot. That makes the merge
/// idempotent, which a plain sum is not, and it means two devices that each
/// played for an hour show two hours, not one and not four.
public struct LibraryStateDocument: Codable, Equatable, Sendable {

    public static let currentVersion = 1

    public struct TimestampedBool: Codable, Equatable, Sendable {
        public var value: Bool
        public var updatedAt: Date

        public init(value: Bool, updatedAt: Date) {
            self.value = value
            self.updatedAt = updatedAt
        }

        /// Newer wins; on an exact tie `true` wins so the result does not
        /// depend on which side was local.
        static func merge(_ a: TimestampedBool?, _ b: TimestampedBool?) -> TimestampedBool? {
            switch (a, b) {
            case (nil, nil): return nil
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (let x?, let y?):
                if x.updatedAt != y.updatedAt { return x.updatedAt > y.updatedAt ? x : y }
                return TimestampedBool(value: x.value || y.value, updatedAt: x.updatedAt)
            }
        }
    }

    public struct GameState: Codable, Equatable, Sendable {
        public var favorite: TimestampedBool?
        public var lastPlayed: Date?
        /// Device identifier → launches from that device.
        public var launches: [String: Int]
        /// Device identifier → seconds played on that device.
        public var playSeconds: [String: Int]

        public init(
            favorite: TimestampedBool? = nil,
            lastPlayed: Date? = nil,
            launches: [String: Int] = [:],
            playSeconds: [String: Int] = [:]
        ) {
            self.favorite = favorite
            self.lastPlayed = lastPlayed
            self.launches = launches
            self.playSeconds = playSeconds
        }

        public var isFavorite: Bool { favorite?.value ?? false }
        public var totalLaunches: Int { launches.values.reduce(0, +) }
        public var totalPlaySeconds: Int { playSeconds.values.reduce(0, +) }

        /// Nothing recorded: safe to drop from the file.
        public var isEmpty: Bool {
            favorite == nil && lastPlayed == nil && launches.isEmpty && playSeconds.isEmpty
        }

        static func merge(_ a: GameState, _ b: GameState) -> GameState {
            GameState(
                favorite: TimestampedBool.merge(a.favorite, b.favorite),
                lastPlayed: Self.later(a.lastPlayed, b.lastPlayed),
                launches: a.launches.merging(b.launches, uniquingKeysWith: max),
                playSeconds: a.playSeconds.merging(b.playSeconds, uniquingKeysWith: max)
            )
        }

        private static func later(_ a: Date?, _ b: Date?) -> Date? {
            switch (a, b) {
            case (nil, nil): return nil
            case (let x?, nil): return x
            case (nil, let y?): return y
            case (let x?, let y?): return max(x, y)
            }
        }
    }

    public var version: Int
    /// GameID → state.
    public var games: [String: GameState]

    public init(version: Int = LibraryStateDocument.currentVersion, games: [String: GameState] = [:]) {
        self.version = version
        self.games = games
    }

    public static func merge(_ a: LibraryStateDocument, _ b: LibraryStateDocument) -> LibraryStateDocument {
        var games = a.games
        for (id, state) in b.games {
            if let existing = games[id] {
                games[id] = GameState.merge(existing, state)
            } else {
                games[id] = state
            }
        }
        return LibraryStateDocument(version: max(a.version, b.version, currentVersion), games: games)
    }

    // MARK: Serialization

    /// Canonical bytes: ISO 8601 dates, sorted keys, no whitespace. Two equal
    /// documents produce equal bytes, so checksums agree across devices.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> LibraryStateDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryStateDocument.self, from: data)
    }
}

public struct LibraryStateDocumentMerger: DocumentMerger {
    public init() {}

    public func merge(local: Data, remote: Data) throws -> Data {
        let a = try LibraryStateDocument.decode(local)
        let b = try LibraryStateDocument.decode(remote)
        return try LibraryStateDocument.merge(a, b).encoded()
    }
}
