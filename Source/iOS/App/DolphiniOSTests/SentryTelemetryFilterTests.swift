// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class SentryBuildEnvironmentTests: XCTestCase {
  func testDebugBuildIsDevelopmentWhateverTheDistribution() {
    XCTAssertEqual(SentryBuildEnvironment.resolve(isDebug: true, isAppStore: true, isTrollStore: false), .development)
    XCTAssertEqual(SentryBuildEnvironment.resolve(isDebug: true, isAppStore: false, isTrollStore: true), .development)
  }

  func testReleaseBuildsResolveByDistribution() {
    XCTAssertEqual(SentryBuildEnvironment.resolve(isDebug: false, isAppStore: true, isTrollStore: false), .appStore)
    XCTAssertEqual(SentryBuildEnvironment.resolve(isDebug: false, isAppStore: false, isTrollStore: true), .trollStore)
    XCTAssertEqual(SentryBuildEnvironment.resolve(isDebug: false, isAppStore: false, isTrollStore: false), .sideload)
  }

  func testWatchdogTrackingOffOnlyForDevelopment() {
    XCTAssertFalse(SentryBuildEnvironment.development.tracksWatchdogTerminations)
    XCTAssertTrue(SentryBuildEnvironment.appStore.tracksWatchdogTerminations)
    XCTAssertTrue(SentryBuildEnvironment.trollStore.tracksWatchdogTerminations)
    XCTAssertTrue(SentryBuildEnvironment.sideload.tracksWatchdogTerminations)
  }
}

final class SentryBreadcrumbFilterTests: XCTestCase {
  func testDropsTouchControlSpamWhileEmulating() {
    for selector in SentryBreadcrumbFilter.touchControlSelectors {
      XCTAssertFalse(
        SentryBreadcrumbFilter.shouldKeep(category: "touch", message: selector, url: nil, emulationActive: true),
        selector)
    }
  }

  func testKeepsTouchControlsOutsideEmulation() {
    XCTAssertTrue(
      SentryBreadcrumbFilter.shouldKeep(category: "touch", message: "valueChanged:", url: nil, emulationActive: false))
  }

  func testKeepsMenuTouchesWhileEmulating() {
    XCTAssertTrue(
      SentryBreadcrumbFilter.shouldKeep(
        category: "touch", message: "menuActionTriggered:", url: nil, emulationActive: true))
  }

  func testDropsSpotlightSidecarRequests() {
    XCTAssertFalse(
      SentryBreadcrumbFilter.shouldKeep(
        category: "http",
        message: nil,
        url: "http://localhost:\(SentryBreadcrumbFilter.spotlightPort)/stream",
        emulationActive: false))
  }

  func testKeepsOtherHTTPRequests() {
    XCTAssertTrue(
      SentryBreadcrumbFilter.shouldKeep(
        category: "http", message: nil, url: "https://www.gametdb.com/wiitdb.zip", emulationActive: false))
    XCTAssertTrue(
      SentryBreadcrumbFilter.shouldKeep(
        category: "http", message: nil, url: "http://localhost:8723/api/health", emulationActive: false))
  }

  func testKeepsDiagnosticCategoriesWhileEmulating() {
    for category in ["dolphin.msgalert", "jit", "emulation", "device.event"] {
      XCTAssertTrue(
        SentryBreadcrumbFilter.shouldKeep(category: category, message: "x", url: nil, emulationActive: true),
        category)
    }
  }
}
