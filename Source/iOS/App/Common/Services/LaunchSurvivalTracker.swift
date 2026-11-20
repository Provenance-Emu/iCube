// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Where the launch marker is kept between runs.
protocol LaunchSurvivalStore: AnyObject {
  func loadLaunchState() -> Data?
  func saveLaunchState(_ data: Data)
}

/// The previous launch ended before it was marked as survived.
struct LaunchFailureReport: Equatable, Sendable {
  /// The build that failed, which may be older than the one running now.
  let build: String
  /// Whether that launch was the first one of its build: the "first open after an update" case.
  let wasFirstLaunchOfBuild: Bool
  /// From the failed launch's start to this launch. It bounds how long the failed run lasted.
  let secondsUntilNextLaunch: Int
  /// Launches in a row that did not survive, this one's predecessor included.
  let consecutiveFailures: Int

  var title: String { "Previous launch ended in its first seconds" }

  var fingerprint: [String] {
    ["launch-not-survived", wasFirstLaunchOfBuild ? "first-of-build" : "repeat-launch"]
  }

  var sentryTags: [String: String] {
    [
      "launch.build": build,
      "launch.first_of_build": wasFirstLaunchOfBuild ? "yes" : "no",
      "launch.consecutive_failures": String(consecutiveFailures),
    ]
  }
}

/// Notices a launch that never got past its first seconds, and says so on the next launch.
///
/// A launch-watchdog or memory kill raises no signal, so no crash handler reports it, and MetricKit
/// reports it a day later without saying how far the launch got. `beginLaunch` leaves a marker;
/// `markSurvived` clears it once the app has run for a while or the user has left it. A marker
/// still there at the next launch means the run in between died early in the foreground: a crash,
/// a kill, or the user closing the app within those seconds.
struct LaunchSurvivalTracker {
  /// How long a launch has to stay up to count as survived.
  static let survivalInterval: TimeInterval = 10

  private struct State: Codable {
    var build: String
    var startedAt: Date
    var survived: Bool
    var firstLaunchOfBuild: Bool
    var consecutiveFailures: Int
  }

  let store: LaunchSurvivalStore
  let now: () -> Date

  /// Records this launch, and returns a report if the one before it did not survive.
  func beginLaunch(build: String) -> LaunchFailureReport? {
    let previous = load()
    var report: LaunchFailureReport?
    if let previous, !previous.survived {
      report = LaunchFailureReport(
        build: previous.build,
        wasFirstLaunchOfBuild: previous.firstLaunchOfBuild,
        secondsUntilNextLaunch: max(0, Int(now().timeIntervalSince(previous.startedAt))),
        consecutiveFailures: previous.consecutiveFailures + 1)
    }
    save(State(
      build: build, startedAt: now(), survived: false,
      firstLaunchOfBuild: previous?.build != build,
      consecutiveFailures: report?.consecutiveFailures ?? 0))
    return report
  }

  func markSurvived() {
    guard var state = load(), !state.survived else { return }
    state.survived = true
    state.consecutiveFailures = 0
    save(state)
  }

  private func load() -> State? {
    store.loadLaunchState().flatMap { try? JSONDecoder().decode(State.self, from: $0) }
  }

  private func save(_ state: State) {
    if let data = try? JSONEncoder().encode(state) { store.saveLaunchState(data) }
  }
}
