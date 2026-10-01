// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import ObjectiveC
import XCTest

/// Sentry is linked statically, without -ObjC, so an Objective-C category the SDK defines in an
/// object file nothing else references never reaches the app binary. sentry-cocoa 9.29.1 shipped
/// `-[SentryEvent isMetricKitEvent]` that way and SentryClient sends it while preparing events:
/// every MetricKit diagnostic crashed the app with "unrecognized selector" (ICUBE-A6).
///
/// The tests run hosted in iCube.app, so this inspects the app's own link of Sentry. It looks the
/// class up at runtime because the Sentry module is not importable from this target.
final class SentryStaticLinkTests: XCTestCase {
  func testSentryEventKeepsMetricKitCategory() throws {
    let eventClass: AnyClass = try XCTUnwrap(NSClassFromString("SentryEvent"), "Sentry is not linked into the host app")
    XCTAssertNotNil(
      class_getInstanceMethod(eventClass, NSSelectorFromString("isMetricKitEvent")),
      "SentryEvent lost its isMetricKitEvent category; event preparation will crash (ICUBE-A6)")
  }
}
