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

/// Which kind of build this binary is, reported as the Sentry environment. Keyed on the build
/// configuration only: the build number cannot tell a local build apart, because every CI alpha
/// before ca0f5931d1 (2026-09-21) also shipped as CFBundleVersion 13 and sideload users still run them.
enum SentryBuildEnvironment: String {
  case development
  case appStore = "appstore"
  case trollStore = "trollstore"
  case sideload

  static func resolve(isDebug: Bool, isAppStore: Bool, isTrollStore: Bool) -> Self {
    if isDebug { return .development }
    if isAppStore { return .appStore }
    if isTrollStore { return .trollStore }
    return .sideload
  }

  static var current: Self {
    #if DEBUG
    let isDebug = true
    #else
    let isDebug = false
    #endif
    #if APPSTORE
    let isAppStore = true
    #else
    let isAppStore = false
    #endif
    #if TROLLSTORE
    let isTrollStore = true
    #else
    let isTrollStore = false
    #endif
    return resolve(isDebug: isDebug, isAppStore: isAppStore, isTrollStore: isTrollStore)
  }

  /// Sentry's watchdog-termination heuristic reports ANY foreground death that left no crash report.
  /// On debug builds that is mostly devicectl/Xcode reinstalling or terminating the app, and every
  /// local build shares release `1.0.0+13`, so Sentry cannot tell a reinstall from a kill.
  var tracksWatchdogTerminations: Bool {
    self != .development
  }
}

/// Drops breadcrumbs that flood the 100-entry buffer and push out the ones that explain a death.
enum SentryBreadcrumbFilter {
  /// Selectors the on-screen touch controls fire on every frame of input (joystick, TCButton).
  /// About 30 per second while playing, so they fill the whole buffer in a few seconds.
  static let touchControlSelectors: Set<String> = ["valueChanged:", "buttonPressed", "buttonReleased"]
  /// Sentry Spotlight's local sidecar (DEBUG only); every event it forwards records an http crumb.
  static let spotlightPort = 8969

  static func shouldKeep(category: String, message: String?, url: String?, emulationActive: Bool) -> Bool {
    if category == "touch", emulationActive, let message, touchControlSelectors.contains(message) {
      return false
    }
    if category == "http", let url, let components = URLComponents(string: url),
       components.host == "localhost", components.port == spotlightPort {
      return false
    }
    return true
  }
}

/// Central Sentry configuration, emulation-aware sampling, and manual trace helpers.
enum SentryTelemetryService {
  private static let emulationDidStart = Notification.Name("DOLEmulationDidStartNotification")
  private static let emulationDidEnd = Notification.Name("DOLEmulationDidEndNotification")
  private static let emulationWillStart = Notification.Name("DOLEmulationWillStartNotification")

  private static var bootTransaction: Span?
  private static var observersInstalled = false

  /// Scope tags describing the current boot; persisted onto watchdog-termination events.
  private static let bootTagKeys = ["game_id", "jit", "cpu_core", "gfx_backend"]
  /// Set once the stuck TXM handshake cookie has been reported, so it is sent once per incident.
  private static let txmCookieReportedKey = "icube.sentry.txmHandshakeCookieReported"

  /// Production trace sample rate when the emulator core is not running.
  private static let releaseTraceSampleRate = 0.2
  /// Fraction of emulation sessions that upload FPS summaries in Release.
  static let releaseSessionSampleRate = 0.10

  static func configure() {
    guard !observersInstalled else { return }
    observersInstalled = true

    let buildEnvironment = SentryBuildEnvironment.current

    SentrySDK.start { options in
      options.dsn = "https://aa3e806dc811b751d7c2ce91290f1fd6@o199354.ingest.us.sentry.io/4511503509815296"
      options.environment = buildEnvironment.rawValue
      options.enableWatchdogTerminationTracking = buildEnvironment.tracksWatchdogTerminations
      options.beforeBreadcrumb = { crumb in
        SentryBreadcrumbFilter.shouldKeep(
          category: crumb.category,
          message: crumb.message,
          url: crumb.data?["url"] as? String,
          emulationActive: EmulationTelemetryGate.isEmulationActive) ? crumb : nil
      }
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
      #if !os(tvOS)
      options.enableMetricKit = true
      #endif
      options.enableTimeToFullDisplayTracing = true
      options.swiftAsyncStacktraces = true
      options.enableCaptureFailedRequests = true
      options.enableFileManagerSwizzling = true
//      options.enableSigtermReporting = true
      #if DEBUG
      // TODO: Actually add Sentry logs from dolphin's logger
      options.enableLogs = true
      #endif
    }

    installNotificationObservers()
    reportStuckTXMHandshakeIfNeeded()
  }

  /// The TXM handshake cookie is flushed to disk before the brk and only cleared when the brk
  /// returns, so finding it set at launch means the previous process died or hung inside the
  /// handshake. That is the one JIT failure the crash handler cannot see (the debugger owns the
  /// exception, and a hang ends in a SIGKILL), so report it directly, once per stuck cookie.
  private static func reportStuckTXMHandshakeIfNeeded() {
    let defaults = UserDefaults.standard
    let manager = JitManager.shared()
    guard manager.txmHandshakeBlocked else {
      defaults.removeObject(forKey: txmCookieReportedKey)
      return
    }
    guard !defaults.bool(forKey: txmCookieReportedKey) else { return }
    defaults.set(true, forKey: txmCookieReportedKey)

    SentrySDK.capture(message: "Previous TXM JIT handshake never returned") { scope in
      scope.setLevel(.error)
      scope.setTag(value: "txm_handshake", key: "jit_failure")
      scope.setContext(
        value: ["device_has_txm": manager.deviceHasTxm, "debugger_attached_now": manager.debuggerAttached],
        key: "jit")
    }
  }

  // MARK: - Emulation lifecycle

  static func handleEmulationWillStart() {
    EmulationTelemetryGate.setEmulationActive(true)
    SentrySDK.pauseAppHangTracking()
    addEmulationBreadcrumb("will start")
    // Reset before the JIT handshake: a boot that hangs at the brk must not report the previous
    // boot's settings. recordEmulationBoot / handleEmulationDidStart fill these in.
    SentrySDK.configureScope { scope in
      scope.setTag(value: "true", key: "emulating")
      for key in bootTagKeys {
        scope.setTag(value: "pending", key: key)
      }
    }

    let transaction = SentrySDK.startTransaction(
      name: "emulation.boot",
      operation: "emulation.boot",
      bindToScope: false)
    transaction.setTag(value: "pending", key: "game_id")
    bootTransaction = transaction
  }

  static func handleEmulationDidStart() {
    let gameID = TVEmulationBridge.currentGameID()
    if let transaction = bootTransaction {
      if !gameID.isEmpty {
        transaction.setTag(value: gameID, key: "game_id")
      }
      transaction.finish(status: .ok)
      bootTransaction = nil
    }
    addEmulationBreadcrumb("started", data: ["game_id": gameID])
    if !gameID.isEmpty {
      SentrySDK.configureScope { $0.setTag(value: gameID, key: "game_id") }
    }
    EmulationPerfSessionRecorder.shared.begin()
  }

  static func handleEmulationDidEnd() {
    EmulationPerfSessionRecorder.shared.finishAndReportIfSampled()
    EmulationTelemetryGate.setEmulationActive(false)
    SentrySDK.resumeAppHangTracking()
    // game_id / jit / cpu_core stay set: a death right after leaving a game is still about that game.
    addEmulationBreadcrumb("ended")
    SentrySDK.configureScope { $0.setTag(value: "false", key: "emulating") }

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

  /// Records how the core was set up for this boot. The watchdog-termination tracker persists scope
  /// tags, so a SIGKILL during boot (e.g. a JIT codesigning kill) still reports which JIT path ran.
  static func recordEmulationBoot(jitMode: String, cpuCore: Int, gfxBackend: String) {
    addEmulationBreadcrumb(
      "boot configured",
      data: ["jit": jitMode, "cpu_core": cpuCore, "gfx_backend": gfxBackend])
    SentrySDK.configureScope { scope in
      scope.setTag(value: jitMode, key: "jit")
      scope.setTag(value: String(cpuCore), key: "cpu_core")
      scope.setTag(value: gfxBackend, key: "gfx_backend")
    }
  }

  /// Marks a step of JIT acquisition. Breadcrumbs are written to disk as they are added, so the
  /// last one survives a kill the crash handler cannot see.
  static func recordJitStep(_ step: String, data: [String: Any] = [:]) {
    let crumb = Breadcrumb(level: .info, category: "jit")
    crumb.message = step
    crumb.data = data
    SentrySDK.addBreadcrumb(crumb)
  }

  // MARK: - Private

  private static func addEmulationBreadcrumb(_ message: String, data: [String: Any] = [:]) {
    let crumb = Breadcrumb(level: .info, category: "emulation")
    crumb.message = message
    crumb.data = data
    SentrySDK.addBreadcrumb(crumb)
  }

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

  @objc(recordEmulationBootWithJitMode:cpuCore:gfxBackend:)
  static func recordEmulationBoot(jitMode: String, cpuCore: Int, gfxBackend: String) {
    SentryTelemetryService.recordEmulationBoot(jitMode: jitMode, cpuCore: cpuCore, gfxBackend: gfxBackend)
  }

  @objc(recordJitStep:data:)
  static func recordJitStep(_ step: String, data: [String: Any]) {
    SentryTelemetryService.recordJitStep(step, data: data)
  }

  /// Records a Dolphin MsgAlert (PanicAlert / ASSERT dialog) as a breadcrumb. Without this, crash
  /// reports only show a UIAlertController titled "Warning": an ASSERT answered "No" calls
  /// Crash() (brk -> EXC_BREAKPOINT), and the assert's condition/file/line never reached Sentry.
  @objc(recordMsgAlertWithCaption:text:question:)
  static func recordMsgAlert(caption: String, text: String, question: Bool) {
    let crumb = Breadcrumb(level: .warning, category: "dolphin.msgalert")
    crumb.message = "\(caption)\(question ? " (question)" : ""): \(text)"
    SentrySDK.addBreadcrumb(crumb)
  }

  /// Records the user's answer to a MsgAlert question. "No" on an ASSERT dialog crashes on purpose.
  @objc(recordMsgAlertAnswer:)
  static func recordMsgAlertAnswer(_ confirmed: Bool) {
    let crumb = Breadcrumb(level: .warning, category: "dolphin.msgalert")
    crumb.message = confirmed ? "answered Yes/OK" : "answered No"
    SentrySDK.addBreadcrumb(crumb)
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
