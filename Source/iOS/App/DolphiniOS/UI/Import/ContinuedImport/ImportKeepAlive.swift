// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UIKit

/// Keeps one user-started import (one file or a whole batch) running after the user leaves the app.
///
/// - Below iOS 26, on tvOS, Catalyst and the iPad app on Mac or Vision, and for small imports:
///   exactly the old behaviour, a UIKit background task around the work.
/// - iOS 26+: additionally a `BGContinuedProcessingTask`, with real byte progress for every file
///   combined into the one task, and a cancel path from the system UI back into the copy.
///
/// Create it on the main thread from the user's action, report progress from the copy, `end` it.
@objc(DOLImportKeepAlive)
public final class ImportKeepAlive: NSObject {
  private let session: ContinuedImportSession?
  private let legacyLock = NSLock()
  private var legacyTask: UIBackgroundTaskIdentifier = .invalid

  /// True when the work should use the progress-reporting, cancellable copier.
  var tracksProgress: Bool { session != nil }

  /// The system asked the import to stop (expired, or cancelled from the system UI).
  @objc public var isCancelled: Bool { session?.isCancellationRequested ?? false }

  /// Internal so tests can build one around a session with a fake host.
  init(session: ContinuedImportSession?) {
    self.session = session
    super.init()
  }

  /// Items are `(name, bytes to copy)`. Pass 0 bytes for files that will be skipped.
  @MainActor
  static func begin(items: [(name: String, totalBytes: Int64)],
                    userInitiated: Bool = true,
                    holdsLegacyTask: Bool = true) -> ImportKeepAlive {
    let total = items.reduce(Int64(0)) { $0 + max(0, $1.totalBytes) }
    let mechanism = ContinuedImportPolicy.mechanism(
      platform: currentPlatform(appIsActive: UIApplication.shared.applicationState == .active),
      totalBytes: total,
      userInitiated: userInitiated)

    var keepAlive: ImportKeepAlive?
    var session: ContinuedImportSession?
    #if os(iOS) && !targetEnvironment(macCatalyst)
    if mechanism == .continuedProcessing, #available(iOS 26.0, *) {
      let names = items.map(\.name)
      session = ContinuedImportScheduler.start(
        items: items,
        title: L("Importing games"),
        subtitle: { finished, count in
          count == 1 ? names[0] : String(format: L("%d of %d files"), min(finished + 1, count), count)
        },
        onTaskStarted: { keepAlive?.endLegacyTask() })
    }
    #endif
    let result = ImportKeepAlive(session: session)
    keepAlive = result
    if holdsLegacyTask {
      result.legacyTask = ImportStaging.beginBackgroundTask()
    }
    return result
  }

  /// For the Objective-C single-file path: sizes come from the files themselves.
  @MainActor
  @objc(beginWithPaths:holdsLegacyTask:)
  public static func begin(paths: [String], holdsLegacyTask: Bool) -> ImportKeepAlive {
    let items = paths.map { path -> (name: String, totalBytes: Int64) in
      let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
      return ((path as NSString).lastPathComponent, size)
    }
    return begin(items: items, holdsLegacyTask: holdsLegacyTask)
  }

  // MARK: - Progress from the copy

  func report(item: Int, copiedBytes: Int64) { session?.update(item: item, copiedBytes: copiedBytes) }

  func finish(item: Int) { session?.finish(item: item) }

  // MARK: - End

  func end(_ outcome: ImportTerminationOutcome) {
    session?.workEnded(outcome)
    endLegacyTask()
  }

  /// Objective-C: ok → completed; not ok → stopped if the system asked us to, else failed.
  @objc(endWithSuccess:)
  public func end(success: Bool) {
    end(success ? .completed : (isCancelled ? .stopped : .failed))
  }

  /// The UIKit task has no expiration handler, so iOS kills the app if it is still open when
  /// background time runs out. Once the continued task is running it must not outlive it.
  fileprivate func endLegacyTask() {
    legacyLock.lock()
    let task = legacyTask
    legacyTask = .invalid
    legacyLock.unlock()
    guard task != .invalid else { return }
    DispatchQueue.main.async { ImportStaging.endBackgroundTask(task) }
  }

  // MARK: - Platform

  @MainActor
  static func currentPlatform(appIsActive: Bool) -> ImportPlatform {
    #if os(iOS)
    var onVision = false
    if #available(iOS 26.1, *) { onVision = ProcessInfo.processInfo.isiOSAppOnVision }
    #if targetEnvironment(macCatalyst)
    let catalyst = true
    #else
    let catalyst = false
    #endif
    return ImportPlatform(isIOS: true,
                          isMacCatalyst: catalyst,
                          isiOSAppOnMac: ProcessInfo.processInfo.isiOSAppOnMac,
                          isiOSAppOnVision: onVision,
                          osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                          appIsActive: appIsActive)
    #else
    return ImportPlatform(isIOS: false, isMacCatalyst: false, isiOSAppOnMac: false, isiOSAppOnVision: false,
                          osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                          appIsActive: appIsActive)
    #endif
  }
}
