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

/// Pure trace policy, kept independent of SDK startup and random session admission.
enum SentryTraceSamplingPolicy {
  static let releaseTraceSampleRate = 0.2

  static func rate(name: String, operation: String, emulationActive: Bool,
                   consentEnabled: Bool, isDebug: Bool) -> Double {
    guard consentEnabled else { return 0 }
    // The recorder already admits 10% of Release sessions. Sample its one summary
    // once, even though DidEnd reports it before reopening the emulation gate.
    if name == "emulation.session", operation == "emulation.session" { return 1 }
    // WillStart closes the gate before creating this bounded boot transaction.
    if name == "emulation.boot", operation == "emulation.boot" {
      return isDebug ? 1 : releaseTraceSampleRate
    }
    if emulationActive { return 0 }
    return isDebug ? 1 : releaseTraceSampleRate
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
  /// The App Store build never tags the game (see SentryEventScrubber).
  #if APPSTORE
  private static let bootTagKeys = ["jit", "cpu_core", "gfx_backend"]
  #else
  private static let bootTagKeys = ["game_id", "jit", "cpu_core", "gfx_backend"]
  #endif
  /// Set once the stuck TXM handshake cookie has been reported, so it is sent once per incident.
  private static let txmCookieReportedKey = "icube.sentry.txmHandshakeCookieReported"

  /// Production trace sample rate when the emulator core is not running.
  private static let releaseTraceSampleRate = SentryTraceSamplingPolicy.releaseTraceSampleRate
  /// Fraction of emulation sessions that upload FPS summaries in Release.
  static let releaseSessionSampleRate = 0.10

  /// The app is also the unit-test host. Sentry started inside test runs filed XCTest's own
  /// main-thread waits and teardowns as fatal app hangs (ICUBE-9P), so test hosts skip it.
  static func isUnitTestHost(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    environment["XCTestConfigurationFilePath"] != nil
  }

  /// Starts the SDK unless the user opted out of crash reports. Safe to call again: it does nothing
  /// while the SDK is running, and starts it again after `applyConsent(false)` closed it.
  static func configure() {
    guard !isUnitTestHost(), TelemetryConsent.isEnabled(), !SentrySDK.isEnabled else { return }

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
      // Capture an unhandled C++ exception's stack where it is thrown rather than in
      // std::terminate. ICUBE-G ("mutex lock failed: Invalid argument", thrown during exit()
      // static destruction) arrived with no frames at all for the throwing thread.
      options.experimental.enableUnhandledCPPExceptionsV2 = true
      // Off everywhere: a SIGTERM is the OS or the user ending the app, never a crash. Debug builds
      // sent Xcode/devicectl stops (ICUBE-6E) and distributed builds sent graceful OS terminations
      // with main idle (ICUBE-72). A foreground SIGTERM now surfaces as a watchdog termination
      // (ICUBE-3), where the emulation/JIT breadcrumbs and tags tell it apart. KSCrash never reports
      // SIGTERM, so `enableSigtermReporting` (deprecated, off by default) is left alone.
      #if DEBUG
      options.debug = true
      options.enableSpotlight = true
      #else
      options.debug = false
      #endif

      options.tracesSampleRate = NSNumber(value: releaseTraceSampleRate)
      options.tracesSampler = { context in
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        return NSNumber(value: SentryTraceSamplingPolicy.rate(
          name: context.transactionContext.name,
          operation: context.transactionContext.operation,
          emulationActive: EmulationTelemetryGate.isEmulationActive,
          consentEnabled: TelemetryConsent.isEnabled(),
          isDebug: isDebug))
      }

      options.enableAutoPerformanceTracing = true
      options.enableAppHangTracking = true
      options.enableReportNonFullyBlockingAppHangs = false
      #if !os(tvOS)
      options.enableMetricKit = true
      #endif
      options.enableTimeToFullDisplayTracing = true
      options.swiftAsyncStacktraces = true
      // Close must not block the main thread on a flush: the consent gate below drops anything queued.
      options.shutdownTimeInterval = 0
      // Events, spans and crash reports from a previous run pass these callbacks, so opting out stops them even
      // before the SDK is closed. Envelopes already written to disk do not pass beforeSend again; deleting the
      // SDK's disk state at opt-out (applyConsent) covers those. beforeSendTransaction only exists under
      // SDK_V10 in 9.30.1, so transactions are scrubbed in beforeSend above; revisit if the SDK moves to v10.
      options.beforeSend = { event in
        guard TelemetryConsent.isEnabled() else { return nil }
        #if APPSTORE
        // Transactions come through here too, with scope and tracer tags merged into `tags`.
        if let tags = event.tags { event.tags = SentryEventScrubber.scrubTags(tags) }
        if let message = event.message?.formatted {
          event.message = SentryMessage(formatted: SentryEventScrubber.scrubMessage(message))
        }
        for exception in event.exceptions ?? [] {
          exception.value = exception.value.map(SentryEventScrubber.scrubMessage)
        }
        for crumb in event.breadcrumbs ?? [] {
          crumb.message = crumb.message.map(SentryEventScrubber.scrubMessage)
          crumb.setData(value: nil, key: "game_id")
          crumb.setData(value: nil, key: "url")
        }
        #endif
        return event
      }
      options.beforeSendSpan = { span in
        guard TelemetryConsent.isEnabled() else { return nil }
        #if APPSTORE
        // Backstop for the file I/O switches below: a file span names the file and carries its full path.
        if span.operation.hasPrefix("file.") { return nil }
        for tag in SentryEventScrubber.strippedTags { span.removeTag(key: tag) }
        #endif
        return span
      }
      #if APPSTORE
      options.enableCaptureFailedRequests = false // failed request URLs can carry user source hosts
      options.enableFileManagerSwizzling = false // file I/O spans carry container paths
      options.enableFileIOTracing = false // `file.read`/`file.write` spans put the file name in the description and the full path in `file.path`
      options.enableDataSwizzling = false // Data(contentsOf:) / write(to:) are traced as file I/O spans too
      // WebDAV sources use URLSession: breadcrumb `url` and `http.client` span names carry the host and ROM file names.
      options.enableNetworkBreadcrumbs = false
      options.enableNetworkTracking = false
      #else
      options.enableCaptureFailedRequests = true
      options.enableFileManagerSwizzling = true
      #endif
      #if DEBUG
      // TODO: Actually add Sentry logs from dolphin's logger
      options.enableLogs = true
      #endif
    }

    if !observersInstalled {
      observersInstalled = true
      installNotificationObservers()
    }
    reportStuckTXMHandshakeIfNeeded()
  }

  /// Settings → Privacy flips this; call it on the main thread (`close()` hops to main synchronously).
  ///
  /// Turning it off, in this order: persists the choice (from then on `beforeSend` and `beforeSendSpan` drop
  /// every event, span and queued envelope), closes the SDK (crash handler and integrations are removed;
  /// later `SentrySDK` calls are no-ops), then deletes the SDK's on-disk state so nothing captured before the
  /// opt-out is sent if the user opts in again. A report already being uploaded by the OS network stack
  /// cannot be recalled. Turning it on starts the SDK again.
  @MainActor
  static func applyConsent(_ on: Bool) {
    TelemetryConsent.set(on)
    if on {
      configure()
    } else {
      if SentrySDK.isEnabled { SentrySDK.close() }
      removeSDKDiskState()
    }
  }

  /// Directories the SDK keeps in Library/Caches (sentry-cocoa 9.30.1): `io.sentry` holds the envelope queue,
  /// sessions, breadcrumbs and scope state (SentryFileManagerHelper); `SentryCrash` and `KSCrash` hold crash
  /// reports waiting for the next launch (SentryCrashIntegration, SentryKSCrash+Integration).
  static let sdkCacheDirectoryNames = ["io.sentry", "SentryCrash", "KSCrash"]

  /// Deletes the SDK's queued envelopes and pending crash reports. Runs after `close()`, so the SDK holds
  /// no writers; errors are ignored because a missing directory is the expected case.
  static func removeSDKDiskState(
    cachesDirectory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
    fileManager: FileManager = .default
  ) {
    guard let cachesDirectory else { return }
    for name in sdkCacheDirectoryNames {
      try? fileManager.removeItem(at: cachesDirectory.appendingPathComponent(name))
    }
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
    #if !APPSTORE
    transaction.setTag(value: "pending", key: "game_id")
    #endif
    bootTransaction = transaction
  }

  static func handleEmulationDidStart() {
    #if !APPSTORE
    let gameID = TVEmulationBridge.currentGameID()
    #endif
    if let transaction = bootTransaction {
      #if !APPSTORE
      if !gameID.isEmpty {
        transaction.setTag(value: gameID, key: "game_id")
      }
      #endif
      transaction.finish(status: .ok)
      bootTransaction = nil
    }
    #if APPSTORE
    addEmulationBreadcrumb("started")
    #else
    addEmulationBreadcrumb("started", data: ["game_id": gameID])
    if !gameID.isEmpty {
      SentrySDK.configureScope { $0.setTag(value: gameID, key: "game_id") }
    }
    #endif
    EmulationPerfSessionRecorder.shared.begin()
  }

  static func handleEmulationDidEnd() {
    EmulationPerfSessionRecorder.shared.finishAndReportIfSampled()
    EmulationTelemetryGate.setEmulationActive(false)
    SentrySDK.resumeAppHangTracking()
    // jit / cpu_core (and game_id outside the App Store build) stay set: a death right after leaving a game
    // is still about that boot.
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
    crumb.setData(data)
    SentrySDK.addBreadcrumb(crumb)
  }

  /// One crumb for the whole one-time settings repair (the buffer holds only 100).
  static func recordSettingsRepair(version: Int, deleted: [String: String], removedDefaults: [String]) {
    let crumb = Breadcrumb(level: .info, category: "settings.repair")
    crumb.message = "settings repair v\(version): \(deleted.count) config keys, \(removedDefaults.count) defaults"
    crumb.setData([
      "deleted": deleted.keys.sorted().map { "\($0)=\(deleted[$0] ?? "")" },
      "removed_defaults": removedDefaults,
    ])
    SentrySDK.addBreadcrumb(crumb)
  }

  // MARK: - Private

  private static func addEmulationBreadcrumb(_ message: String, data: [String: Any] = [:]) {
    let crumb = Breadcrumb(level: .info, category: "emulation")
    crumb.message = message
    crumb.setData(data)
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

private extension Breadcrumb {
  /// `data`'s setter is deprecated; the per-key setter is the supported way to fill it.
  func setData(_ values: [String: Any]) {
    for (key, value) in values { setData(value: value, key: key) }
  }
}
