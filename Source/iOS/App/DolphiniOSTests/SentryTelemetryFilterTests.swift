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

/// ICUBE-9P: the app is the unit-test host, so Sentry started inside test runs and filed XCTest's
/// own main-thread waits as fatal app hangs. Test hosts must not start Sentry.
final class SentryUnitTestHostTests: XCTestCase {
  func testTestHostIsDetectedFromTheXCTestEnvironment() {
    XCTAssertTrue(SentryTelemetryService.isUnitTestHost(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]))
    XCTAssertFalse(SentryTelemetryService.isUnitTestHost(environment: [:]))
  }

  func testThisTestRunIsATestHost() {
    XCTAssertTrue(SentryTelemetryService.isUnitTestHost())
  }
}

final class SentryTraceSamplingPolicyTests: XCTestCase {
  private func rate(_ name: String, operation: String? = nil, active: Bool = true,
                    consent: Bool = true, debug: Bool = false) -> Double {
    SentryTraceSamplingPolicy.rate(name: name, operation: operation ?? name,
                                  emulationActive: active, consentEnabled: consent, isDebug: debug)
  }

  func testBootRemainsSampleableAfterWillStartClosesEmulationGate() {
    XCTAssertEqual(rate("emulation.boot"), 0.2)
    XCTAssertEqual(rate("emulation.boot", debug: true), 1)
  }

  func testAdmittedSessionSummaryIsNotSampledAgainBeforeDidEndClearsGate() {
    // Recorder already admits 10% of Release sessions; its summary precedes gate reopening.
    XCTAssertEqual(rate("emulation.session"), 1)
    XCTAssertEqual(rate("emulation.session", active: false), 1)
  }

  func testOtherActiveEmulationTracesStaySuppressedEvenInDebug() {
    for name in ["ui.load", "http.client", "emulation", "emulation.boot.child", "emulation.session.child"] {
      XCTAssertEqual(rate(name), 0, name)
      XCTAssertEqual(rate(name, debug: true), 0, name)
    }
  }

  func testSummaryAllowanceRequiresExactNameAndOperation() {
    XCTAssertEqual(rate("emulation.session", operation: "http.client"), 0)
    XCTAssertEqual(rate("ui.load", operation: "emulation.session"), 0)
    XCTAssertEqual(rate("emulation.boot", operation: "ui.load"), 0)
    XCTAssertEqual(rate("ui.load", operation: "emulation.boot"), 0)
  }

  func testConsentAlwaysWinsIncludingSummariesAfterEmulationEnds() {
    for name in ["emulation.boot", "emulation.session", "ui.load"] {
      for active in [true, false] {
        XCTAssertEqual(rate(name, active: active, consent: false), 0)
        XCTAssertEqual(rate(name, active: active, consent: false, debug: true), 0)
      }
    }
  }

  func testOrdinaryIdleSamplingKeepsExistingRates() {
    XCTAssertEqual(rate("ui.load", active: false), 0.2)
    XCTAssertEqual(rate("ui.load", active: false, debug: true), 1)
  }
}
