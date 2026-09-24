import Foundation

public enum LibrarySnapshotKeys {
    public static let snapshot = "snapshot.v1"
}

public struct LibrarySnapshot: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maxRecentlyPlayed = 12
    public static let maxFavorites = 16

    public var schemaVersion: Int
    public var updatedAt: Date
    public var recentlyPlayed: [LibrarySnapshotGame]
    public var favorites: [LibrarySnapshotGame]
    /// Every game, keyed by game id. Quick Look uses this; Top Shelf does not.
    public var byGameID: [String: LibrarySnapshotGame]

    public init(schemaVersion: Int = LibrarySnapshot.currentSchemaVersion, updatedAt: Date,
                recentlyPlayed: [LibrarySnapshotGame], favorites: [LibrarySnapshotGame],
                byGameID: [String: LibrarySnapshotGame]) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.recentlyPlayed = recentlyPlayed
        self.favorites = favorites
        self.byGameID = byGameID
    }

    public static let empty = LibrarySnapshot(updatedAt: .distantPast, recentlyPlayed: [], favorites: [], byGameID: [:])

    /// Builds the derived lists. Recents: games with a `lastPlayed`, newest first.
    /// Favorites: alphabetical by title. First occurrence wins on duplicate ids.
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
        return LibrarySnapshot(updatedAt: now, recentlyPlayed: Array(recents),
                               favorites: Array(favorites), byGameID: byID)
    }

    public func game(id: String) -> LibrarySnapshotGame? { byGameID[id] }

    /// Last-path-component match, for containers whose header cannot be parsed.
    public func game(filename: String) -> LibrarySnapshotGame? {
        guard !filename.isEmpty else { return nil }
        return byGameID.values.first { $0.filename == filename }
    }
}
