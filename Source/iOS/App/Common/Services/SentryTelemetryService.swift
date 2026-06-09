// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import Sentry

/// Thread-safe gate read by `tracesSampler` and trace helpers during active emulation.
enum EmulationTelemetryGate {
  private static let lock = NSLock()
  private static var _isActive = false

  static var isEmulationActive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _isActive
  }

  static func setEmulationActive(_ active: Bool) {
    lock.lock()
    _isActive = active
    lock.unlock()
  }
}

/// Central Sentry configuration, emulation-aware sampling, and manual trace helpers.
enum SentryTelemetryService {
  private static let emulationDidStart = Notification.Name("DOLEmulationDidStartNotification")
  private static let emulationDidEnd = Notification.Name("DOLEmulationDidEndNotification")
  private static let emulationWillStart = Notification.Name("DOLEmulationWillStartNotification")

  private static var bootTransaction: Span?
  private static var observersInstalled = false

  /// Production trace sample rate when the emulator core is not running.
  private static let releaseTraceSampleRate = 0.2
  /// Fraction of emulation sessions that upload FPS summaries in Release.
  static let releaseSessionSampleRate = 0.10

  static func configure() {
    guard !observersInstalled else { return }
    observersInstalled = true

    SentrySDK.start { options in
      options.dsn = "https://aa3e806dc811b751d7c2ce91290f1fd6@o199354.ingest.us.sentry.io/4511503509815296"
      options.enableCrashHandler = true
      options.enableSigtermReporting = true
      #if DEBUG
      options.debug = true
      options.enableSpotlight = true
      #else
      options.debug = false
      #endif

      options.tracesSampleRate = NSNumber(value: releaseTraceSampleRate)
      options.tracesSampler = { _ in
        if EmulationTelemetryGate.isEmulationActive {
          return NSNumber(value: 0.0)
        }
        #if DEBUG
        return NSNumber(value: 1.0)
        #else
        return NSNumber(value: releaseTraceSampleRate)
        #endif
      }

      options.enableAutoPerformanceTracing = true
      options.enableAppHangTracking = true
      options.enableReportNonFullyBlockingAppHangs = false
      options.enableMetricKit = true
      options.enableTimeToFullDisplayTracing = true
      options.swiftAsyncStacktraces = true
      options.enableCaptureFailedRequests = true
    }

    installNotificationObservers()
  }

  // MARK: - Emulation lifecycle

  static func handleEmulationWillStart() {
    EmulationTelemetryGate.setEmulationActive(true)
    SentrySDK.pauseAppHangTracking()

    let transaction = SentrySDK.startTransaction(
      name: "emulation.boot",
      operation: "emulation.boot",
      bindToScope: false)
    transaction.setTag(value: "pending", key: "game_id")
    bootTransaction = transaction
  }

  static func handleEmulationDidStart() {
    if let transaction = bootTransaction {
      let gameID = TVEmulationBridge.currentGameID()
      if !gameID.isEmpty {
        transaction.setTag(value: gameID, key: "game_id")
      }
      transaction.finish(status: .ok)
      bootTransaction = nil
    }
    EmulationPerfSessionRecorder.shared.begin()
  }

  static func handleEmulationDidEnd() {
    EmulationPerfSessionRecorder.shared.finishAndReportIfSampled()
    EmulationTelemetryGate.setEmulationActive(false)
    SentrySDK.resumeAppHangTracking()

    if let transaction = bootTransaction {
      transaction.finish(status: .cancelled)
      bootTransaction = nil
    }
  }

  // MARK: - Manual tracing

  /// Starts a transaction that the caller must finish when async work completes.
  static func beginTrace(
    _ name: String,
    op: String,
    tags: [String: String] = [:],
    force: Bool = false
  ) -> Span? {
    guard force || !EmulationTelemetryGate.isEmulationActive else {
      return nil
    }

    let transaction = SentrySDK.startTransaction(name: name, operation: op, bindToScope: false)
    for (key, value) in tags {
      transaction.setTag(value: value, key: key)
    }
    return transaction
  }

  static func finishTrace(_ span: Span?, status: SentrySpanStatus = .ok) {
    span?.finish(status: status)
  }

  /// Runs `work` inside a Sentry transaction when auto tracing is allowed.
  static func trace<T>(
    _ name: String,
    op: String,
    tags: [String: String] = [:],
    force: Bool = false,
    _ work: () throws -> T
  ) rethrows -> T {
    guard force || !EmulationTelemetryGate.isEmulationActive else {
      return try work()
    }

    let transaction = SentrySDK.startTransaction(name: name, operation: op, bindToScope: false)
    for (key, value) in tags {
      transaction.setTag(value: value, key: key)
    }
    defer { transaction.finish() }
    return try work()
  }

  /// Async variant of `trace`.
  static func traceAsync<T>(
    _ name: String,
    op: String,
    tags: [String: String] = [:],
    force: Bool = false,
    _ work: () async throws -> T
  ) async rethrows -> T {
    guard force || !EmulationTelemetryGate.isEmulationActive else {
      return try await work()
    }

    let transaction = SentrySDK.startTransaction(name: name, operation: op, bindToScope: false)
    for (key, value) in tags {
      transaction.setTag(value: value, key: key)
    }
    defer { transaction.finish() }
    return try await work()
  }

  // MARK: - Private

  private static func installNotificationObservers() {
    let center = NotificationCenter.default
    center.addObserver(
      forName: emulationWillStart,
      object: nil,
      queue: .main) { _ in
        handleEmulationWillStart()
      }
    center.addObserver(
      forName: emulationDidStart,
      object: nil,
      queue: .main) { _ in
        handleEmulationDidStart()
      }
    center.addObserver(
      forName: emulationDidEnd,
      object: nil,
      queue: .main) { _ in
        handleEmulationDidEnd()
      }
  }
}

/// Objective-C entry points for EmulationCoordinator and GameFileCacheManager.
@objc(DOLSentryTelemetryBridge)
@objcMembers
final class DOLSentryTelemetryBridge: NSObject {
  @objc(configure)
  static func configure() {
    SentryTelemetryService.configure()
  }

  @objc(emulationWillStart)
  static func emulationWillStart() {
    SentryTelemetryService.handleEmulationWillStart()
  }

  @objc(traceSyncWithName:operation:tags:work:)
  static func traceSync(
    name: String,
    operation: String,
    tags: [String: String],
    work: () -> Void
  ) {
    SentryTelemetryService.trace(name, op: operation, tags: tags) {
      work()
    }
  }
}
