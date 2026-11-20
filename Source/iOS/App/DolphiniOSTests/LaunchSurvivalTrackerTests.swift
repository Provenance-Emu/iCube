// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class LaunchSurvivalTrackerTests: XCTestCase {
  private final class MemoryStore: LaunchSurvivalStore {
    var data: Data?
    func loadLaunchState() -> Data? { data }
    func saveLaunchState(_ data: Data) { self.data = data }
  }

  private var store = MemoryStore()
  private var now = Date(timeIntervalSince1970: 1_795_000_000)

  private func tracker() -> LaunchSurvivalTracker {
    LaunchSurvivalTracker(store: store, now: { [unowned self] in self.now })
  }

  override func setUp() {
    store = MemoryStore()
    now = Date(timeIntervalSince1970: 1_795_000_000)
  }

  func testTheFirstLaunchEverReportsNothing() {
    XCTAssertNil(tracker().beginLaunch(build: "100"))
  }

  func testALaunchThatSurvivedReportsNothingNextTime() {
    let tracker = tracker()
    _ = tracker.beginLaunch(build: "100")
    tracker.markSurvived()
    XCTAssertNil(tracker.beginLaunch(build: "100"))
  }

  /// The case the TestFlight reports describe: a new build is opened for the first time and is
  /// gone seconds later. The next launch says so.
  func testAFirstLaunchOfABuildThatNeverSurvivedIsReportedOnTheNextLaunch() {
    let tracker = tracker()
    _ = tracker.beginLaunch(build: "100")
    tracker.markSurvived()
    _ = tracker.beginLaunch(build: "101")
    now += 42

    let report = tracker.beginLaunch(build: "101")

    XCTAssertEqual(report, LaunchFailureReport(
      build: "101", wasFirstLaunchOfBuild: true, secondsUntilNextLaunch: 42, consecutiveFailures: 1))
    XCTAssertEqual(report?.sentryTags["launch.first_of_build"], "yes")
    XCTAssertEqual(report?.sentryTags["launch.build"], "101")
    XCTAssertEqual(report?.fingerprint, ["launch-not-survived", "first-of-build"])
  }

  func testALaterLaunchOfTheSameBuildIsNotAFirstLaunch() {
    let tracker = tracker()
    _ = tracker.beginLaunch(build: "100")
    tracker.markSurvived()
    _ = tracker.beginLaunch(build: "100")

    let report = tracker.beginLaunch(build: "100")

    XCTAssertEqual(report?.wasFirstLaunchOfBuild, false)
    XCTAssertEqual(report?.fingerprint, ["launch-not-survived", "repeat-launch"])
  }

  /// A launch loop counts up until one launch survives.
  func testFailuresInARowAreCountedAndResetBySurvival() {
    let tracker = tracker()
    _ = tracker.beginLaunch(build: "100")
    XCTAssertEqual(tracker.beginLaunch(build: "100")?.consecutiveFailures, 1)
    XCTAssertEqual(tracker.beginLaunch(build: "100")?.consecutiveFailures, 2)
    tracker.markSurvived()
    XCTAssertNil(tracker.beginLaunch(build: "100"))
    XCTAssertEqual(tracker.beginLaunch(build: "100")?.consecutiveFailures, 1)
  }

  func testTheReportNamesTheBuildThatFailedNotTheOneRunningNow() {
    let tracker = tracker()
    _ = tracker.beginLaunch(build: "100")
    XCTAssertEqual(tracker.beginLaunch(build: "101")?.build, "100")
  }

  func testUnreadableStateIsTreatedAsNoHistory() {
    store.data = Data("garbage".utf8)
    XCTAssertNil(tracker().beginLaunch(build: "100"))
  }
}
