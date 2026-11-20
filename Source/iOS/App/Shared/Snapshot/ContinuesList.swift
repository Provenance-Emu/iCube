// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import PVLibrarySnapshot

/// One game with a save state to go back to, and when its newest save state was made.
public struct ContinueEntry: Codable, Equatable, Sendable {
    public let gameID: String
    public let savedAt: Date

    public init(gameID: String, savedAt: Date) {
        self.gameID = gameID
        self.savedAt = savedAt
    }
}

/// The widget's Continue list: games with a save state, newest save first, one entry per game.
///
/// The app writes it to the App Group beside the library snapshot (`LibrarySnapshotWriter`); the
/// widget reads it and looks each game up in the snapshot for its title, cover and platform. It is
/// iCube's own key, not part of the shared PVLibrarySnapshot format, so older and newer builds and
/// the other extensions are unaffected by it.
public enum ContinuesList {
    public static let defaultsKey = "widget.continues.v1"
    /// As many as the largest widget can show, with room to spare.
    public static let maxEntries = 16

    /// Keeps the newest save of each game the library still has, newest first, at most `limit`.
    public static func select(saves: [ContinueEntry], knownGameIDs: Set<String>, limit: Int = maxEntries) -> [ContinueEntry] {
        var seen = Set<String>()
        var result: [ContinueEntry] = []
        for save in saves.sorted(by: { $0.savedAt > $1.savedAt }) where knownGameIDs.contains(save.gameID) {
            guard result.count < limit else { break }
            if seen.insert(save.gameID).inserted { result.append(save) }
        }
        return result
    }

    /// The snapshot's game for each entry, in the list's order. An entry whose game has left the
    /// library since the list was written is dropped.
    public static func games(for entries: [ContinueEntry], in snapshot: LibrarySnapshot) -> [(game: LibrarySnapshotGame, savedAt: Date)] {
        entries.compactMap { entry in snapshot.game(id: entry.gameID).map { ($0, entry.savedAt) } }
    }

    /// Returns false when the App Group is unavailable or encoding failed.
    @discardableResult
    public static func save(_ entries: [ContinueEntry], to defaults: UserDefaults?) -> Bool {
        guard let defaults, let data = try? encoder().encode(entries) else { return false }
        defaults.set(data, forKey: defaultsKey)
        return true
    }

    /// Empty when nothing was written yet, the App Group is unavailable, or the data is unreadable.
    public static func load(from defaults: UserDefaults?) -> [ContinueEntry] {
        guard let data = defaults?.data(forKey: defaultsKey) else { return [] }
        return (try? decoder().decode([ContinueEntry].self, from: data)) ?? []
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
