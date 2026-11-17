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

extension GameActivityAttributes.ContentState {
  /// The state after a tick or pause change: the game's title and subtitle are kept (they are only
  /// known at `start`), so the lock screen keeps showing the game's name instead of falling back to
  /// the generic "Playing".
  func updating(isPaused: Bool, elapsedSeconds: Int) -> Self {
    Self(title: title, subtitle: subtitle, isPaused: isPaused, elapsedSeconds: elapsedSeconds)
  }
}

enum GameActivityManager {
  /// Start a Live Activity for a game. Supply plain values to avoid cross-target dependencies.
  /// Activities left over from another game (or from a run that was killed before it could end
  /// them) are ended first; a second `start` for the game already shown is a no-op.
  static func start(gameId: String, title: String, subtitle: String?, isPaused: Bool) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
    var alreadyShowing = false
    for activity in Activity<GameActivityAttributes>.activities {
      if activity.attributes.gameId == gameId, !alreadyShowing {
        alreadyShowing = true
      } else {
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
      }
    }
    guard !alreadyShowing else { return }
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
    for activity in Activity<GameActivityAttributes>.activities {
      let state = activity.content.state.updating(isPaused: isPaused, elapsedSeconds: elapsedSeconds)
      Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }
  }

  static func end() {
    for activity in Activity<GameActivityAttributes>.activities {
      Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
  }
}
#endif
