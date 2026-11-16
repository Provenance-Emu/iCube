// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum ContinuedImportEvent: Equatable {
  /// The scheduler accepted the request.
  case submissionSucceeded
  /// The scheduler refused it (unavailable, not permitted, too many, would not run immediately).
  case submissionFailed
  /// The system called our launch handler: the task is running.
  case systemStarted
  /// The copy work ended (all files, an error, or stopped by us).
  case workEnded(ImportTerminationOutcome)
  /// The task's expiration handler fired: system expiry or a cancel from the system UI.
  case systemExpired
  /// The grace period after an expiration has run out.
  case deadlineElapsed
}

enum ContinuedImportEffect: Equatable {
  /// Make the copy loops stop at their next progress step.
  case cancelWork
  /// Call `setTaskCompletedWithSuccess:` on the system task.
  case completeTask(success: Bool)
  /// Cancel the pending request, because the work finished before the system started the task.
  case withdrawRequest
  /// Start a timer; when it fires, send `.deadlineElapsed`.
  case armExpirationDeadline(seconds: TimeInterval)
}

/// The order-independent protocol between our copy work and one system task.
///
/// Events can arrive in any order: the scheduler's submit callback is asynchronous, so the launch
/// handler can run before it; a small import can finish before the handler runs at all. Every
/// task the system hands over is completed exactly once, as the header requires.
struct ContinuedImportLifecycle: Equatable {
  /// How long the copy gets to unwind after an expiration before the task is completed anyway.
  /// An archive extraction cannot be interrupted, so this bounds the wait.
  static let expirationGraceSeconds: TimeInterval = 5

  enum Phase: Equatable {
    case notSubmitted
    case submitted
    case running
    case ended
  }

  private(set) var phase: Phase = .notSubmitted
  private(set) var workOutcome: ImportTerminationOutcome?
  private(set) var isCancellationRequested = false
  private(set) var taskCompleted = false
  private var submissionRefused = false

  /// True while the system task is (or may yet become) the thing keeping the app alive.
  var isProtected: Bool { phase == .submitted || phase == .running }

  mutating func handle(_ event: ContinuedImportEvent) -> [ContinuedImportEffect] {
    switch event {
    case .submissionSucceeded:
      guard phase == .notSubmitted else { return [] }
      if workOutcome != nil {
        phase = .ended
        return [.withdrawRequest]
      }
      phase = .submitted
      return []

    case .submissionFailed:
      guard phase == .notSubmitted else { return [] }
      submissionRefused = true
      phase = .ended
      return []

    case .systemStarted:
      guard !submissionRefused, !taskCompleted, phase != .running else { return [] }
      phase = .running
      if let outcome = workOutcome {
        return completeTask(for: outcome)
      }
      return []

    case .workEnded(let outcome):
      guard workOutcome == nil else { return [] }
      workOutcome = outcome
      switch phase {
      case .running:
        return completeTask(for: outcome)
      case .submitted:
        phase = .ended
        return [.withdrawRequest]
      case .notSubmitted, .ended:
        return []
      }

    case .systemExpired:
      guard !taskCompleted, workOutcome == nil, !isCancellationRequested else { return [] }
      isCancellationRequested = true
      return [.cancelWork, .armExpirationDeadline(seconds: Self.expirationGraceSeconds)]

    case .deadlineElapsed:
      guard phase == .running, !taskCompleted else { return [] }
      return completeTask(success: false)
    }
  }

  private mutating func completeTask(for outcome: ImportTerminationOutcome) -> [ContinuedImportEffect] {
    completeTask(success: outcome.reportsTaskSuccess)
  }

  private mutating func completeTask(success: Bool) -> [ContinuedImportEffect] {
    taskCompleted = true
    phase = .ended
    return [.completeTask(success: success)]
  }
}
