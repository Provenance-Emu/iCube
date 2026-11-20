// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if canImport(MetricKit) && !os(tvOS)
import Foundation
import MetricKit
import Sentry

/// Sends the terminations Sentry's crash handler cannot see: MetricKit's crash diagnostics and
/// its daily count of app exits by cause.
///
/// The handler only reports a crash that raises a signal inside the process after the SDK has
/// started. A launch-watchdog or memory-limit kill is a SIGKILL, and sentry-cocoa's MetricKit
/// integration (`options.enableMetricKit`) forwards hangs, CPU and disk-write diagnostics but not
/// crashes. TestFlight reports of "crashed on first open" arrived with no log and no Sentry event
/// for that reason. MetricKit delivers these a day later, on the next launch.
enum MetricKitDiagnosticsReporter {
  /// Private so it stays out of the generated iCube-Swift.h, like `ExtensionMetricsReporter`'s.
  private static let subscriber = Subscriber()

  private final class Subscriber: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
      payloads.forEach(MetricKitDiagnosticsReporter.reportExits)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
      for payload in payloads {
        (payload.crashDiagnostics ?? []).forEach(MetricKitDiagnosticsReporter.reportCrash)
      }
    }
  }

  static func start() {
    guard !SentryTelemetryService.isUnitTestHost() else { return }
    MXMetricManager.shared.add(subscriber)
  }

  private static func reportCrash(_ crash: MXCrashDiagnostic) {
    let json = crash.callStackTree.jsonRepresentation()
    let report = MetricKitCrashReport(
      callStackTreeJSON: json,
      exceptionType: crash.exceptionType?.intValue,
      exceptionCode: crash.exceptionCode?.intValue,
      signal: crash.signal?.intValue,
      terminationReason: crash.terminationReason,
      build: crash.metaData.applicationBuildVersion)

    var details: [String: Any] = ["exception": report.exceptionLabel, "frames": report.contextFrames]
    details["termination_reason"] = report.terminationReason
    details["vm_region"] = crash.virtualMemoryRegionInfo
    details["objc_reason"] = crash.exceptionReason?.composedMessage
    details["parse_error"] = report.parseError
    details["os_version"] = crash.metaData.osVersion
    details["device_type"] = crash.metaData.deviceType

    whenSentryEnabled {
      let event = Event(level: report.severity == .fatal ? .fatal : .error)
      event.message = SentryMessage(formatted: report.title)
      event.tags = report.sentryTags
      event.fingerprint = report.fingerprint
      event.context = ["metrickit_crash": details]
      SentrySDK.capture(event: event) { scope in
        scope.addAttachment(Attachment(data: json, filename: "callStackTree.json", contentType: "application/json"))
      }
    }
  }

  private static func reportExits(_ payload: MXMetricPayload) {
    guard let exits = payload.applicationExitMetrics else { return }
    let summary = AppExitSummary(exits)
    guard summary.isWorthReporting else { return }

    let iso = ISO8601DateFormatter()
    let context: [String: Any] = [
      "foreground": summary.foreground.summaryLine,
      "background": summary.background.summaryLine,
      "window_start": iso.string(from: payload.timeStampBegin),
      "window_end": iso.string(from: payload.timeStampEnd),
      "app_version": payload.latestApplicationVersion,
    ]
    whenSentryEnabled {
      let event = Event(level: .warning)
      event.message = SentryMessage(formatted: summary.title)
      event.tags = summary.sentryTags
      event.fingerprint = ["metrickit-app-exits", summary.dominantClass]
      event.context = ["app_exit": context]
      SentrySDK.capture(event: event)
    }
  }

  /// MetricKit delivers on a background queue, possibly while the SDK is still starting or after
  /// the user opted out of crash reports (the SDK is closed then).
  private static func whenSentryEnabled(_ capture: @escaping () -> Void) {
    DispatchQueue.main.async {
      guard SentrySDK.isEnabled else { return }
      capture()
    }
  }
}

private extension AppExitCounts {
  /// `MXForegroundExitData` has no memory-pressure, CPU-limit, locked-file or background-task
  /// counters; those stay 0.
  init(_ data: MXForegroundExitData) {
    self.init(
      normal: Int(data.cumulativeNormalAppExitCount),
      memoryResourceLimit: Int(data.cumulativeMemoryResourceLimitExitCount),
      badAccess: Int(data.cumulativeBadAccessExitCount),
      abnormal: Int(data.cumulativeAbnormalExitCount),
      illegalInstruction: Int(data.cumulativeIllegalInstructionExitCount),
      watchdog: Int(data.cumulativeAppWatchdogExitCount))
  }

  init(_ data: MXBackgroundExitData) {
    self.init(
      normal: Int(data.cumulativeNormalAppExitCount),
      memoryResourceLimit: Int(data.cumulativeMemoryResourceLimitExitCount),
      memoryPressure: Int(data.cumulativeMemoryPressureExitCount),
      cpuResourceLimit: Int(data.cumulativeCPUResourceLimitExitCount),
      badAccess: Int(data.cumulativeBadAccessExitCount),
      abnormal: Int(data.cumulativeAbnormalExitCount),
      illegalInstruction: Int(data.cumulativeIllegalInstructionExitCount),
      watchdog: Int(data.cumulativeAppWatchdogExitCount),
      suspendedWithLockedFile: Int(data.cumulativeSuspendedWithLockedFileExitCount),
      backgroundTaskAssertionTimeout: Int(data.cumulativeBackgroundTaskAssertionTimeoutExitCount))
  }
}

private extension AppExitSummary {
  init(_ metric: MXAppExitMetric) {
    self.init(
      foreground: AppExitCounts(metric.foregroundExitData),
      background: AppExitCounts(metric.backgroundExitData))
  }
}
#endif
