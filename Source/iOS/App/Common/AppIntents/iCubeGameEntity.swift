// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import AppIntents
import PVLibrarySnapshot

/// `AppEntity` view of a `LibrarySnapshotGame`, used by Siri/Shortcuts intents. Reads straight
/// from the App Group snapshot the app already maintains (`LibrarySnapshotStore`) — no separate
/// store, so it's automatically in sync with what `LibrarySnapshotWriter` last wrote.
struct iCubeGameEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Game"
    static var defaultQuery = iCubeGameEntityQuery()

    let id: String
    let title: String
    let platformName: String

    init(snapshotGame game: LibrarySnapshotGame) {
        self.id = game.id
        self.title = game.title
        self.platformName = game.platform.displayName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(platformName)")
    }
}

/// Backs `iCubeGameEntity` lookups (by id, by title substring) and Siri/Shortcuts suggestions.
/// The `games...` static functions are pure (snapshot in, games out) so they're unit-testable
/// against a fixture `LibrarySnapshot` without touching the App Group suite.
struct iCubeGameEntityQuery: EntityQuery, EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [iCubeGameEntity] {
        let snapshot = LibrarySnapshotStore().load()
        return Self.games(for: identifiers, in: snapshot).map(iCubeGameEntity.init(snapshotGame:))
    }

    func entities(matching string: String) async throws -> [iCubeGameEntity] {
        let snapshot = LibrarySnapshotStore().load()
        return Self.matchingGames(string, in: snapshot).map(iCubeGameEntity.init(snapshotGame:))
    }

    func suggestedEntities() async throws -> [iCubeGameEntity] {
        let snapshot = LibrarySnapshotStore().load()
        return Self.suggestedGames(from: snapshot).map(iCubeGameEntity.init(snapshotGame:))
    }

    static func games(for identifiers: [String], in snapshot: LibrarySnapshot) -> [LibrarySnapshotGame] {
        identifiers.compactMap { snapshot.game(id: $0) }
    }

    static func matchingGames(_ string: String, in snapshot: LibrarySnapshot) -> [LibrarySnapshotGame] {
        snapshot.byGameID.values
            .filter { string.isEmpty || $0.title.localizedCaseInsensitiveContains(string) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Recently played first (already newest-first from `LibrarySnapshot.build`), then favorites
    /// not already listed. First occurrence wins on duplicate ids.
    static func suggestedGames(from snapshot: LibrarySnapshot) -> [LibrarySnapshotGame] {
        var seen = Set<String>()
        var result: [LibrarySnapshotGame] = []
        for game in snapshot.recentlyPlayed + snapshot.favorites where !seen.contains(game.id) {
            seen.insert(game.id)
            result.append(game)
        }
        return result
    }
}

// iOS 18+: lets Siri Suggestions / Spotlight surface the same entities this query already
// exposes to Shortcuts. iOS-only (mirrors Spotlight indexing, which is iOS-only in this app).
#if os(iOS)
@available(iOS 18.0, *)
extension iCubeGameEntity: IndexedEntity {}
#endif
