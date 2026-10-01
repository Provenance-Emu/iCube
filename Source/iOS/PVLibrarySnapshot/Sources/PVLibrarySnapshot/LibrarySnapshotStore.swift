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
        loadWithOutcome().snapshot
    }

    /// Same snapshot as `load()`, plus why it is empty when it is. The extensions record the
    /// outcome so a broken App Group or unreadable snapshot is visible in telemetry instead of
    /// looking like an empty library.
    public func loadWithOutcome() -> (snapshot: LibrarySnapshot, outcome: LibrarySnapshotLoadOutcome) {
        guard let defaults else { return (.empty, .appGroupUnavailable) }
        guard let data = defaults.data(forKey: LibrarySnapshotKeys.snapshot) else { return (.empty, .neverWritten) }
        guard let snap = try? Self.decoder().decode(LibrarySnapshot.self, from: data) else { return (.empty, .decodeFailed) }
        guard snap.schemaVersion <= LibrarySnapshot.currentSchemaVersion else {
            return (.empty, .newerSchema(snap.schemaVersion))
        }
        return (snap, .loaded)
    }

    /// Returns false when the group is unavailable or encoding failed.
    @discardableResult
    public func save(_ snapshot: LibrarySnapshot) -> Bool {
        guard let defaults, let data = try? Self.encoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: LibrarySnapshotKeys.snapshot)
        return true
    }
}

/// Why `LibrarySnapshotStore.load()` returned what it did.
public enum LibrarySnapshotLoadOutcome: Equatable, Sendable {
    case loaded
    /// No snapshot key yet: the app has not written one on this install. Expected, not a failure.
    case neverWritten
    /// The process is not entitled to the App Group (signing / profile problem).
    case appGroupUnavailable
    case decodeFailed
    /// Written by a newer app than this extension understands; carries the version on disk.
    case newerSchema(Int)

    public var isFailure: Bool {
        switch self {
        case .loaded, .neverWritten: return false
        case .appGroupUnavailable, .decodeFailed, .newerSchema: return true
        }
    }

    /// Stable short code for log lines. Never rename an existing one: logs are searched by it
    /// across app versions. (Signpost names must be `StaticString`, so they are mapped separately.)
    public var reason: String {
        switch self {
        case .loaded: return "loaded"
        case .neverWritten: return "never_written"
        case .appGroupUnavailable: return "no_app_group"
        case .decodeFailed: return "decode_failed"
        case .newerSchema: return "newer_schema"
        }
    }
}
