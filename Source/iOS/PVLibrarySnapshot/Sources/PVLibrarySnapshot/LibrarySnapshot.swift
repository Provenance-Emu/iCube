import Foundation

public enum LibrarySnapshotKeys {
    public static let snapshot = "snapshot.v1"
}

public struct LibrarySnapshot: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maxRecentlyPlayed = 12
    public static let maxFavorites = 16
    public static let maxRecentlyAdded = 12

    public var schemaVersion: Int
    public var updatedAt: Date
    public var recentlyPlayed: [LibrarySnapshotGame]
    public var favorites: [LibrarySnapshotGame]
    /// Newest-imported games, newest first (falls back to title order when no game in the
    /// batch has a known import date; see `build(from:now:)`).
    public var recentlyAdded: [LibrarySnapshotGame]
    /// Every game, keyed by game id. Quick Look uses this; Top Shelf does not.
    public var byGameID: [String: LibrarySnapshotGame]

    public init(schemaVersion: Int = LibrarySnapshot.currentSchemaVersion, updatedAt: Date,
                recentlyPlayed: [LibrarySnapshotGame], favorites: [LibrarySnapshotGame],
                recentlyAdded: [LibrarySnapshotGame] = [],
                byGameID: [String: LibrarySnapshotGame]) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.recentlyPlayed = recentlyPlayed
        self.favorites = favorites
        self.recentlyAdded = recentlyAdded
        self.byGameID = byGameID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, updatedAt, recentlyPlayed, favorites, recentlyAdded, byGameID
    }

    /// Custom decode so a snapshot written before `recentlyAdded` existed (no such key on
    /// disk) still parses instead of failing decode entirely. `encode(to:)` stays synthesized.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        recentlyPlayed = try container.decode([LibrarySnapshotGame].self, forKey: .recentlyPlayed)
        favorites = try container.decode([LibrarySnapshotGame].self, forKey: .favorites)
        recentlyAdded = try container.decodeIfPresent([LibrarySnapshotGame].self, forKey: .recentlyAdded) ?? []
        byGameID = try container.decode([String: LibrarySnapshotGame].self, forKey: .byGameID)
    }

    public static let empty = LibrarySnapshot(updatedAt: .distantPast, recentlyPlayed: [], favorites: [],
                                               recentlyAdded: [], byGameID: [:])

    /// Builds the derived lists. Recents: games with a `lastPlayed`, newest first.
    /// Favorites: alphabetical by title. Recently added: newest `dateAdded` first, with
    /// games missing a `dateAdded` sorted after ones that have it, and title order as the
    /// final tiebreak (also the whole-list fallback when no game in the batch has a
    /// `dateAdded`). First occurrence wins on duplicate ids.
    public static func build(from games: [LibrarySnapshotGame], now: Date = Date()) -> LibrarySnapshot {
        var byID: [String: LibrarySnapshotGame] = [:]
        for g in games where byID[g.id] == nil { byID[g.id] = g }
        let unique = Array(byID.values)
        let recents = unique
            .filter { $0.lastPlayed != nil }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(maxRecentlyPlayed)
        let favorites = unique
            .filter(\.isFavorite)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .prefix(maxFavorites)
        let recentlyAdded = unique
            .sorted { lhs, rhs in
                switch (lhs.dateAdded, rhs.dateAdded) {
                case let (l?, r?):
                    return l > r
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
            }
            .prefix(maxRecentlyAdded)
        return LibrarySnapshot(updatedAt: now, recentlyPlayed: Array(recents),
                               favorites: Array(favorites), recentlyAdded: Array(recentlyAdded), byGameID: byID)
    }

    public func game(id: String) -> LibrarySnapshotGame? { byGameID[id] }

    /// Last-path-component match, for containers whose header cannot be parsed.
    public func game(filename: String) -> LibrarySnapshotGame? {
        guard !filename.isEmpty else { return nil }
        return byGameID.values.first { $0.filename == filename }
    }
}
