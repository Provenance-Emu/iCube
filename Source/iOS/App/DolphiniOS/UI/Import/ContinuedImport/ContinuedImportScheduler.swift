// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS) && !targetEnvironment(macCatalyst)

import BackgroundTasks
import Foundation

/// Adapts `BGContinuedProcessingTask` (iOS 26, iOS only: the header marks it unavailable on tvOS,
/// macOS, Catalyst and visionOS) to the platform-neutral `ContinuedImportSession`.
///
/// Registration is dynamic, not at launch: Apple's documentation (and the header, which exempts
/// continued-processing tasks from the register-before-launch rule) has the handler registered
/// right before the request is submitted, under the same unique identifier. Registering one
/// identifier twice kills the app, so every batch gets its own.
@available(iOS 26.0, *)
final class ContinuedImportScheduler: ContinuedImportSessionHost {
  /// `<bundle id>.import.` — the Info.plist permits `$(PRODUCT_BUNDLE_IDENTIFIER).import.*`.
  static var identifierPrefix: String { (Bundle.main.bundleIdentifier ?? "iCube") + ".import." }

  private let identifier: String

  private init(identifier: String) { self.identifier = identifier }

  /// Registers a launch handler, builds the session and submits the request off the main thread.
  /// Returns nil (so the caller keeps today's behaviour) if the handler could not be registered.
  /// A refused submission arrives later through `ContinuedImportSession.submissionFinished`.
  static func start(items: [(name: String, totalBytes: Int64)],
                    title: String,
                    subtitle: @escaping (_ finished: Int, _ count: Int) -> String,
                    onTaskStarted: @escaping () -> Void) -> ContinuedImportSession? {
    let identifier = identifierPrefix + UUID().uuidString
    let scheduler = ContinuedImportScheduler(identifier: identifier)
    let session = ContinuedImportSession(items: items, host: scheduler, title: title, subtitle: subtitle)

    let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
      guard let task = task as? BGContinuedProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      // Set before anything else: a task with no expiration handler is marked failed, not warned.
      task.expirationHandler = { session.taskExpired() }
      session.taskStarted(port: BGContinuedImportPort(task: task))
      onTaskStarted()
    }
    guard registered else { return nil }

    let request = BGContinuedProcessingTaskRequest(identifier: identifier,
                                                   title: title,
                                                   subtitle: session.initialSubtitle)
    // The copy is already running; if the system cannot run the task now, say so rather than queue.
    request.strategy = .fail
    // The header says not to submit from the main thread or other performance-critical contexts.
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        try BGTaskScheduler.shared.submit(request)
        session.submissionFinished(error: nil)
      } catch {
        NSLog("[Import] continued processing refused: %@", error.localizedDescription)
        session.submissionFinished(error: error)
      }
    }
    return session
  }

  func withdrawRequest() {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
  }

  func scheduleDeadline(seconds: TimeInterval, fire: @escaping () -> Void) {
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: fire)
  }
}

@available(iOS 26.0, *)
private final class BGContinuedImportPort: ContinuedImportTaskPort {
  private let task: BGContinuedProcessingTask

  init(task: BGContinuedProcessingTask) { self.task = task }

  func setProgress(total: Int64, completed: Int64) {
    task.progress.totalUnitCount = total
    task.progress.completedUnitCount = completed
  }

  func setText(title: String, subtitle: String) {
    task.updateTitle(title, subtitle: subtitle)
  }

  func completeTask(success: Bool) {
    task.setTaskCompleted(success: success)
  }
}

#endif
