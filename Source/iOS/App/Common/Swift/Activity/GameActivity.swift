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
    if #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled {
      let attributes = GameActivityAttributes(gameId: gameId)
      let state = GameActivityAttributes.ContentState(
        title: title,
        subtitle: subtitle,
        isPaused: isPaused,
        elapsedSeconds: 0
      )
      let content = ActivityContent(state: state, staleDate: nil)
      _ = try? Activity<GameActivityAttributes>.request(attributes: attributes, content: content, pushType: nil)
    } else if #available(iOS 16.1, *), ActivityAuthorizationInfo().areActivitiesEnabled {
      let attributes = GameActivityAttributes(gameId: gameId)
      let state = GameActivityAttributes.ContentState(
        title: title,
        subtitle: subtitle,
        isPaused: isPaused,
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
        if #available(iOS 16.2, *) {
          let content = ActivityContent(state: state, staleDate: nil)
          Task { await activity.update(content) }
        } else {
          Task { await activity.update(using: state) }
        }
      }
    }
  }

  static func end() {
    if #available(iOS 16.1, *) {
      for activity in Activity<GameActivityAttributes>.activities {
        if #available(iOS 16.2, *) {
          Task { await activity.end(nil, dismissalPolicy: .immediate) }
        } else {
          Task { await activity.end(dismissalPolicy: .immediate) }
        }
      }
    }
  }
}
#endif
