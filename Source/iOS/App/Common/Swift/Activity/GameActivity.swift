import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(ActivityKit)
struct GameActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        let title: String
        let subtitle: String?
        let isPaused: Bool
        let elapsedSeconds: Int
    }
    let gameId: String
}

enum GameActivityManager {
    static func start(game: TVGameItem) {
        if #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled {
            let attributes = GameActivityAttributes(gameId: game.gameID)
            let state = GameActivityAttributes.ContentState(
                title: game.title,
                subtitle: game.makerLong,
                isPaused: TVEmulationBridge.isPaused(),
                elapsedSeconds: 0
            )
            _ = try? Activity<GameActivityAttributes>.request(attributes: attributes, contentState: state, pushType: nil)
        }
    }

    static func update(isPaused: Bool, elapsedSeconds: Int) {
        if #available(iOS 16.1, *) {
            let state = GameActivityAttributes.ContentState(
                title: "",
                subtitle: nil,
                isPaused: isPaused,
                elapsedSeconds: elapsedSeconds
            )
            for activity in Activity<GameActivityAttributes>.activities {
                Task { await activity.update(using: state) }
            }
        }
    }

    static func end() {
        if #available(iOS 16.1, *) {
            for activity in Activity<GameActivityAttributes>.activities {
                Task { await activity.end(dismissalPolicy: .immediate) }
            }
        }
    }
}
#endif
