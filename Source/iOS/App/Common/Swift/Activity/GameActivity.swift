import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
public struct GameActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    public let title: String
    public let subtitle: String?
    public let isPaused: Bool
    public let elapsedSeconds: Int
    public init(title: String, subtitle: String?, isPaused: Bool, elapsedSeconds: Int) {
      self.title = title
      self.subtitle = subtitle
      self.isPaused = isPaused
      self.elapsedSeconds = elapsedSeconds
    }
  }

  public let gameId: String
  public init(gameId: String) { self.gameId = gameId }
}

enum GameActivityManager {
  /// Start a Live Activity for a game. Supply plain values to avoid cross-target dependencies.
  static func start(gameId: String, title: String, subtitle: String?, isPaused: Bool) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    let attributes = GameActivityAttributes(gameId: gameId)
    let state = GameActivityAttributes.ContentState(
      title: title,
      subtitle: subtitle,
      isPaused: isPaused,
      elapsedSeconds: 0
    )
    let content = ActivityContent(state: state, staleDate: nil)
    _ = try? Activity<GameActivityAttributes>.request(attributes: attributes, content: content, pushType: nil)
  }

  static func update(isPaused: Bool, elapsedSeconds: Int) {
    let state = GameActivityAttributes.ContentState(
      title: "",
      subtitle: nil,
      isPaused: isPaused,
      elapsedSeconds: elapsedSeconds
    )
    let content = ActivityContent(state: state, staleDate: nil)
    for activity in Activity<GameActivityAttributes>.activities {
      Task { await activity.update(content) }
    }
  }

  static func end() {
    for activity in Activity<GameActivityAttributes>.activities {
      Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
  }
}
#endif
