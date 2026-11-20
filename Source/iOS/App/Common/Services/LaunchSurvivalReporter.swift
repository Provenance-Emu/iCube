// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Sentry
import UIKit

/// Runs `LaunchSurvivalTracker` for the app: marks each foreground launch, clears the mark once
/// the app has stayed up or the user has left it, and tells Sentry when the launch before this
/// one never got that far.
enum LaunchSurvivalReporter {
  private final class DefaultsStore: LaunchSurvivalStore {
    private static let key = "icube.launchSurvival.state"

    func loadLaunchState() -> Data? { UserDefaults.standard.data(forKey: Self.key) }
    func saveLaunchState(_ data: Data) { UserDefaults.standard.set(data, forKey: Self.key) }
  }

  private static let tracker = LaunchSurvivalTracker(store: DefaultsStore(), now: Date.init)
  private static var observers: [NSObjectProtocol] = []

  /// Call from `didFinishLaunching`, after Sentry has started and before the launch's real work.
  @MainActor
  static func start(application: UIApplication) {
    // A launch the system started in the background (a silent push) is suspended again within
    // seconds without ever being in front, which is not a failed launch.
    guard !SentryTelemetryService.isUnitTestHost(), application.applicationState != .background else { return }

    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    let report = tracker.beginLaunch(build: build)

    DispatchQueue.main.asyncAfter(deadline: .now() + LaunchSurvivalTracker.survivalInterval) {
      tracker.markSurvived()
    }
    // Leaving the app, or the app being asked to quit, is not a failed launch either.
    for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
        tracker.markSurvived()
      })
    }

    if let report { send(report) }
  }

  private static func send(_ report: LaunchFailureReport) {
    // Stopping a run from Xcode within the first seconds looks exactly like a failed launch.
    #if !DEBUG
    guard SentrySDK.isEnabled else { return }
    let event = Event(level: .error)
    event.message = SentryMessage(formatted: report.title)
    event.tags = report.sentryTags
    event.fingerprint = report.fingerprint
    event.context = [
      "launch": [
        "failed_build": report.build,
        "first_launch_of_build": report.wasFirstLaunchOfBuild,
        "seconds_until_next_launch": report.secondsUntilNextLaunch,
        "consecutive_failures": report.consecutiveFailures,
        "survival_interval_seconds": Int(LaunchSurvivalTracker.survivalInterval),
      ],
    ]
    SentrySDK.capture(event: event)
    #endif
  }
}
