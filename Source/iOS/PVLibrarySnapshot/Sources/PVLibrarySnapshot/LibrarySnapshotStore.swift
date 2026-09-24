import Foundation

/// Reads and writes the snapshot in the shared suite. Nothing here traps or throws:
/// a missing group, a newer schema, or corrupt data all read as `.empty`.
public struct LibrarySnapshotStore {
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = LibrarySnapshotAppGroup.defaults) {
        self.defaults = defaults
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    public func load() -> LibrarySnapshot {
        guard let data = defaults?.data(forKey: LibrarySnapshotKeys.snapshot),
              let snap = try? Self.decoder().decode(LibrarySnapshot.self, from: data),
              snap.schemaVersion <= LibrarySnapshot.currentSchemaVersion else {
            return .empty
        }
        return snap
    }

    /// Returns false when the group is unavailable or encoding failed.
    @discardableResult
    public func save(_ snapshot: LibrarySnapshot) -> Bool {
        guard let defaults, let data = try? Self.encoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: LibrarySnapshotKeys.snapshot)
        return true
    }
}
