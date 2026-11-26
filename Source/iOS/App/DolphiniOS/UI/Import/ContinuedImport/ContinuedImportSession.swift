// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The system task as the session sees it. `BGContinuedProcessingTask` is adapted to this in
/// `ContinuedImportScheduler`; tests use a fake.
protocol ContinuedImportTaskPort: AnyObject {
  func setProgress(total: Int64, completed: Int64)
  func setText(title: String, subtitle: String)
  func completeTask(success: Bool)
}

/// What the session needs from its surroundings besides the task itself.
protocol ContinuedImportSessionHost: AnyObject {
  /// Cancel the submitted request (the work finished before the system started it).
  func withdrawRequest()
  /// Run `fire` once after `seconds`.
  func scheduleDeadline(seconds: TimeInterval, fire: @escaping () -> Void)
}

/// One batch of imports reported to one system task: the aggregator, the lifecycle, and the
/// glue that turns lifecycle effects into calls on the task. Safe to call from any thread; the
/// copy runs on a background queue while the system calls in on its own.
final class ContinuedImportSession {
  /// Progress is pushed to the system after at least this many bytes, so a fast copy does not
  /// flood it. Finishing an item always pushes.
  static let progressPushIntervalBytes: Int64 = 1024 * 1024

  private let lock = NSLock()
  private var aggregator: ImportProgressAggregator
  private var lifecycle = ContinuedImportLifecycle()
  private var host: ContinuedImportSessionHost?
  private var port: ContinuedImportTaskPort?
  private let title: String
  private let subtitle: (_ finished: Int, _ count: Int) -> String
  private var lastPushedBytes: Int64 = 0
  private var lastPushedFinished = 0

  init(items: [(name: String, totalBytes: Int64)],
       host: ContinuedImportSessionHost,
       title: String,
       subtitle: @escaping (_ finished: Int, _ count: Int) -> String) {
    aggregator = ImportProgressAggregator(items: items)
    self.host = host
    self.title = title
    self.subtitle = subtitle
  }

  var totalBytes: Int64 { locked { aggregator.totalBytes } }
  var isCancellationRequested: Bool { locked { lifecycle.isCancellationRequested } }
  var isProtected: Bool { locked { lifecycle.isProtected } }
  var fractionCompleted: Double { locked { aggregator.fractionCompleted } }

  var initialSubtitle: String {
    locked { subtitle(aggregator.finishedCount, aggregator.itemCount) }
  }

  // MARK: - Events from the scheduler

  func submissionFinished(error: Error?) {
    send(error == nil ? .submissionSucceeded : .submissionFailed)
  }

  /// The launch handler ran. Everything copied so far is reported at once.
  func taskStarted(port: ContinuedImportTaskPort) {
    var snapshot: (counts: (total: Int64, completed: Int64), text: String)?
    locked {
      self.port = port
      snapshot = (aggregator.unitCounts, subtitle(aggregator.finishedCount, aggregator.itemCount))
      lastPushedBytes = aggregator.copiedBytes
      lastPushedFinished = aggregator.finishedCount
    }
    if let snapshot {
      port.setText(title: title, subtitle: snapshot.text)
      port.setProgress(total: snapshot.counts.total, completed: snapshot.counts.completed)
    }
    send(.systemStarted)
  }

  /// The expiration handler ran: system expiry or a cancel from the system UI.
  func taskExpired() { send(.systemExpired) }

  // MARK: - Events from the copy work

  func update(item: Int, copiedBytes: Int64) {
    var push: (counts: (total: Int64, completed: Int64), port: ContinuedImportTaskPort)?
    locked {
      aggregator.update(item: item, copiedBytes: copiedBytes)
      guard let port, lifecycle.phase == .running else { return }
      let copied = aggregator.copiedBytes
      guard copied - lastPushedBytes >= Self.progressPushIntervalBytes else { return }
      lastPushedBytes = copied
      push = (aggregator.unitCounts, port)
    }
    if let push { push.port.setProgress(total: push.counts.total, completed: push.counts.completed) }
  }

  func finish(item: Int) {
    var push: (counts: (total: Int64, completed: Int64), text: String?, port: ContinuedImportTaskPort)?
    locked {
      aggregator.finish(item: item)
      guard let port, lifecycle.phase == .running else { return }
      lastPushedBytes = aggregator.copiedBytes
      var text: String?
      if aggregator.finishedCount != lastPushedFinished {
        lastPushedFinished = aggregator.finishedCount
        text = subtitle(aggregator.finishedCount, aggregator.itemCount)
      }
      push = (aggregator.unitCounts, text, port)
    }
    if let push {
      if let text = push.text { push.port.setText(title: title, subtitle: text) }
      push.port.setProgress(total: push.counts.total, completed: push.counts.completed)
    }
  }

  /// A completed batch reports 100% (an archive's progress only moves when it ends) before the task completes.
  func workEnded(_ outcome: ImportTerminationOutcome) {
    if outcome == .completed {
      for index in 0 ..< locked({ aggregator.itemCount }) { finish(item: index) }
    }
    send(.workEnded(outcome))
  }

  // MARK: - Dispatch

  private func send(_ event: ContinuedImportEvent) {
    var effects: [ContinuedImportEffect] = []
    var port: ContinuedImportTaskPort?
    locked {
      effects = lifecycle.handle(event)
      port = self.port
    }
    for effect in effects {
      switch effect {
      case .cancelWork:
        break // `isCancellationRequested` is already set; the copy loop reads it.
      case .completeTask(let success):
        port?.completeTask(success: success)
        locked { self.port = nil }
      case .withdrawRequest:
        host?.withdrawRequest()
      case .armExpirationDeadline(let seconds):
        host?.scheduleDeadline(seconds: seconds) { [weak self] in self?.send(.deadlineElapsed) }
      }
    }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}
