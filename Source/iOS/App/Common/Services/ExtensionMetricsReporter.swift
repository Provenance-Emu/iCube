// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if canImport(MetricKit) && !os(tvOS)
import Foundation
import MetricKit
import PVLibrarySnapshot
import Sentry

/// Reads the app extensions' MetricKit signposts (`ExtensionTelemetry` in PVLibrarySnapshot) out
/// of the app's daily metric payload and sends them to Sentry.
///
/// Extensions can't subscribe to MetricKit themselves (Apple DTS: not a supported workflow), and
/// Sentry's own MetricKit integration only takes diagnostic payloads, so without this subscriber
/// the extensions' timing and failure counts are collected and never read. Independent of
/// `options.enableMetricKit`: MetricKit allows any number of subscribers.
enum ExtensionMetricsReporter {
  /// Timing-only payloads arrive daily from every device; send a tenth of them.
  private static let timingSampleRate = 0.1
  /// Private so it stays out of the generated iCube-Swift.h: that header has no `@import MetricKit`,
  /// so an exposed `MXMetricManagerSubscriber` conformance breaks the ObjC side of the build.
  private static let subscriber = Subscriber()

  private final class Subscriber: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
      payloads.forEach(ExtensionMetricsReporter.report)
    }
  }

  static func start() {
    guard !SentryTelemetryService.isUnitTestHost() else { return }
    MXMetricManager.shared.add(subscriber)
  }

  private static func report(_ payload: MXMetricPayload) {
    let samples = (payload.signpostMetrics ?? []).map(ExtensionSignpostSample.init)
    let report = ExtensionMetricsReport(samples: samples)

    let message: String
    let level: SentryLevel
    let fingerprint: [String]
    switch report.decision(sampleRoll: Double.random(in: 0..<1), timingSampleRate: Self.timingSampleRate) {
    case .skip:
      return
    case .failures:
      message = "App extension failures"
      level = .warning
      fingerprint = report.failureFingerprint
    case .timing:
      message = "App extension timing"
      level = .info
      fingerprint = ["app-extension-timing"]
    }

    SentrySDK.capture(message: message) { scope in
      scope.setLevel(level)
      scope.setFingerprint(fingerprint)
      scope.setTag(value: report.failures.keys.sorted().joined(separator: ","), key: "extension_failures")
      scope.setContext(value: report.sentryContext, key: "app_extensions")
      scope.setContext(value: payloadContext(payload), key: "metrickit_payload")
    }
  }

  /// Which window and process the payload covers. `bundleIdentifier` (iOS 26) is the one way to
  /// learn whether the system attributes extension signposts to the app or the extension.
  private static func payloadContext(_ payload: MXMetricPayload) -> [String: Any] {
    let iso = ISO8601DateFormatter()
    var context: [String: Any] = [
      "window_start": iso.string(from: payload.timeStampBegin),
      "window_end": iso.string(from: payload.timeStampEnd),
      "app_version": payload.latestApplicationVersion,
    ]
    if let meta = payload.metaData {
      context["pid"] = Int(meta.pid)
      if #available(iOS 26.0, macCatalyst 26.0, *) {
        context["bundle_id"] = meta.bundleIdentifier
      }
    }
    return context
  }
}
#endif
