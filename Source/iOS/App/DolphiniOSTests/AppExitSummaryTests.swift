// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class AppExitSummaryTests: XCTestCase {
  /// A clean run: only normal exits, nothing to report.
  private let clean = AppExitCounts(
    normal: 12, memoryResourceLimit: 0, badAccess: 0, abnormal: 0, illegalInstruction: 0, watchdog: 0)

  func testCleanCountersReportNoAbnormalExits() {
    XCTAssertEqual(clean.abnormalTotal, 0)
    XCTAssertFalse(clean.hasAbnormalExits)
    XCTAssertTrue(clean.nonZeroCounters.isEmpty)
    XCTAssertEqual(clean.summaryLine, "normal=12")
  }

  func testMemoryKillsCombineTheLimitAndPressureCounters() {
    let counts = AppExitCounts(
      normal: 3, memoryResourceLimit: 4, memoryPressure: 2, badAccess: 0, abnormal: 0, illegalInstruction: 0,
      watchdog: 0)
    XCTAssertEqual(counts.memoryKillTotal, 6)
    XCTAssertEqual(counts.abnormalTotal, 6)
    XCTAssertTrue(counts.hasAbnormalExits)
  }

  func testZeroCountersAreLeftOutOfTheSummaryLine() {
    let counts = AppExitCounts(
      normal: 0, memoryResourceLimit: 7, badAccess: 0, abnormal: 0, illegalInstruction: 0, watchdog: 1)
    XCTAssertEqual(counts.summaryLine, "normal=0 memoryResourceLimit=7 watchdog=1")
  }

  func testDominantClassPicksTheLargestBucketAcrossBothScopes() {
    let summary = AppExitSummary(
      foreground: AppExitCounts(
        normal: 5, memoryResourceLimit: 1, badAccess: 2, abnormal: 0, illegalInstruction: 0, watchdog: 0),
      background: AppExitCounts(
        normal: 8, memoryResourceLimit: 9, badAccess: 0, abnormal: 0, illegalInstruction: 0, watchdog: 0))
    XCTAssertEqual(summary.dominantClass, "memoryResourceLimit")
    XCTAssertTrue(summary.hasAbnormalExits)
  }

  func testDominantClassIsNoneWhenEverythingExitedCleanly() {
    let summary = AppExitSummary(foreground: clean, background: clean)
    XCTAssertEqual(summary.dominantClass, "none")
    XCTAssertFalse(summary.hasAbnormalExits)
  }

  func testDominantClassBreaksTiesByName() {
    let counts = AppExitCounts(
      normal: 0, memoryResourceLimit: 2, badAccess: 2, abnormal: 0, illegalInstruction: 0, watchdog: 0)
    XCTAssertEqual(AppExitSummary(foreground: counts, background: clean).dominantClass, "badAccess")
  }

  /// A launch that takes too long is a foreground watchdog exit: the count the first-open reports
  /// are expected to move.
  func testTagsExposeForegroundWatchdogAndMemoryKills() {
    let summary = AppExitSummary(
      foreground: AppExitCounts(
        normal: 4, memoryResourceLimit: 1, badAccess: 0, abnormal: 0, illegalInstruction: 0, watchdog: 3),
      background: AppExitCounts(
        normal: 2, memoryResourceLimit: 3, memoryPressure: 1, badAccess: 0, abnormal: 0, illegalInstruction: 0,
        watchdog: 0, suspendedWithLockedFile: 2))
    let tags = summary.sentryTags
    XCTAssertEqual(tags["exit.foreground.watchdog"], "3")
    XCTAssertEqual(tags["exit.foreground.memory"], "1")
    XCTAssertEqual(tags["exit.background.memory"], "4")
    XCTAssertEqual(tags["exit.background.locked_file"], "2")
    XCTAssertEqual(tags["exit.dominant_class"], "memoryResourceLimit")
    XCTAssertEqual(summary.title, "MetricKit app exits: memoryResourceLimit")
  }

  /// Background memory and CPU reclaims happen on every device every day and would bury the rest.
  func testBackgroundReclaimsAloneAreNotWorthAnEvent() {
    let reclaimed = AppExitCounts(
      normal: 2, memoryResourceLimit: 1, memoryPressure: 6, cpuResourceLimit: 2, badAccess: 0, abnormal: 0,
      illegalInstruction: 0, watchdog: 0)
    XCTAssertFalse(AppExitSummary(foreground: clean, background: reclaimed).isWorthReporting)
    XCTAssertFalse(AppExitSummary(foreground: clean, background: clean).isWorthReporting)
  }

  func testForegroundKillsAndBackgroundFaultsAreWorthAnEvent() {
    let foregroundWatchdog = AppExitCounts(
      normal: 1, memoryResourceLimit: 0, badAccess: 0, abnormal: 0, illegalInstruction: 0, watchdog: 1)
    XCTAssertTrue(AppExitSummary(foreground: foregroundWatchdog, background: clean).isWorthReporting)

    let foregroundMemory = AppExitCounts(
      normal: 1, memoryResourceLimit: 1, badAccess: 0, abnormal: 0, illegalInstruction: 0, watchdog: 0)
    XCTAssertTrue(AppExitSummary(foreground: foregroundMemory, background: clean).isWorthReporting)

    let backgroundLockedFile = AppExitCounts(
      normal: 0, memoryResourceLimit: 0, memoryPressure: 9, badAccess: 0, abnormal: 0, illegalInstruction: 0,
      watchdog: 0, suspendedWithLockedFile: 1)
    XCTAssertTrue(AppExitSummary(foreground: clean, background: backgroundLockedFile).isWorthReporting)
  }
}
