import Foundation

/// The WidgetKit kind identifier for `RecentGamesWidget` (LiveActivityExtension appex). Lives
/// here — not duplicated in the app and the appex — because it genuinely crosses that module
/// boundary: the app calls `WidgetCenter.shared.reloadTimelines(ofKind:)` with it, the appex's
/// widget declares itself with it, and both already depend on this package.
public enum RecentGamesWidgetKind {
    public static let identifier = "com.joemattiello.icube.RecentGamesWidget"
}
