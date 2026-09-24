import Foundation

/// The one place the App Group id lives on the Swift side. The ObjC mirror is
/// `DOLAppGroupIdentifier` in `Common/SharedDefaults.m`; keep them identical.
public enum LibrarySnapshotAppGroup {
    public static let identifier = "group.com.joemattiello.icube"

    /// `nil` when the running process is not entitled to the group (unsigned CI
    /// build, wildcard profile, test process). Every caller must tolerate nil.
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public static var isAvailable: Bool { containerURL != nil }

    /// Shared suite, or nil when the group is unavailable. `UserDefaults(suiteName:)`
    /// itself never returns nil for a missing entitlement; it just silently fails to
    /// persist, which is why this is gated on `containerURL`.
    public static var defaults: UserDefaults? {
        guard isAvailable else { return nil }
        return UserDefaults(suiteName: identifier)
    }

    /// tvOS only allows writes under Library/Caches inside a group container, so
    /// every platform uses that subtree for uniformity.
    public static var mediaDirectory: URL? {
        containerURL?.appendingPathComponent("Library/Caches/LibraryMedia", isDirectory: true)
    }

    public static func coverFilename(gameID: String) -> String { "cover_\(gameID).jpg" }

    public static func coverURL(gameID: String) -> URL? {
        mediaDirectory?.appendingPathComponent(coverFilename(gameID: gameID), isDirectory: false)
    }
}
