// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class ContinuedImportPolicyTests: XCTestCase {
  private let big: Int64 = 2 * 1024 * 1024 * 1024

  private func platform(isIOS: Bool = true, catalyst: Bool = false, onMac: Bool = false,
                        onVision: Bool = false, os: Int = 26, active: Bool = true) -> ImportPlatform {
    ImportPlatform(isIOS: isIOS, isMacCatalyst: catalyst, isiOSAppOnMac: onMac, isiOSAppOnVision: onVision,
                   osMajorVersion: os, appIsActive: active)
  }

  func testIOS26UserImportOfBigFileUsesContinuedProcessing() {
    XCTAssertEqual(ContinuedImportPolicy.mechanism(platform: platform(), totalBytes: big, userInitiated: true),
                   .continuedProcessing)
  }

  func testLaterOSVersionsAlsoUseIt() {
    XCTAssertEqual(ContinuedImportPolicy.mechanism(platform: platform(os: 27), totalBytes: big, userInitiated: true),
                   .continuedProcessing)
  }

  func testIOS25AndEarlierKeepTodaysBehaviour() {
    for os in [17, 18, 25] {
      XCTAssertEqual(ContinuedImportPolicy.mechanism(platform: platform(os: os), totalBytes: big, userInitiated: true),
                     .legacyBackgroundTask, "iOS \(os)")
    }
  }

  func testTVOSMacCatalystAndCompatibilityModesKeepTodaysBehaviour() {
    let cases: [(String, ImportPlatform)] = [
      ("tvOS", platform(isIOS: false, os: 26)),
      ("Catalyst", platform(catalyst: true)),
      ("iPad app on Mac", platform(onMac: true)),
      ("iPad app on Vision", platform(onVision: true)),
    ]
    for (name, platform) in cases {
      XCTAssertEqual(ContinuedImportPolicy.mechanism(platform: platform, totalBytes: big, userInitiated: true),
                     .legacyBackgroundTask, name)
    }
  }

  func testNotUserInitiatedOrNotInForegroundKeepsTodaysBehaviour() {
    XCTAssertEqual(ContinuedImportPolicy.mechanism(platform: platform(), totalBytes: big, userInitiated: false),
                   .legacyBackgroundTask)
    XCTAssertEqual(ContinuedImportPolicy.mechanism(platform: platform(active: false), totalBytes: big, userInitiated: true),
                   .legacyBackgroundTask)
  }

  func testSmallImportsDoNotGetSystemProgressUI() {
    let below = ContinuedImportPolicy.minimumTotalBytes - 1
    XCTAssertEqual(ContinuedImportPolicy.mechanism(platform: platform(), totalBytes: below, userInitiated: true),
                   .legacyBackgroundTask)
    XCTAssertEqual(ContinuedImportPolicy.mechanism(platform: platform(), totalBytes: ContinuedImportPolicy.minimumTotalBytes,
                                                   userInitiated: true),
                   .continuedProcessing)
  }

  func testOutcomeMapping() {
    XCTAssertTrue(ImportTerminationOutcome.completed.reportsTaskSuccess)
    XCTAssertFalse(ImportTerminationOutcome.completed.removesStagedFile)
    XCTAssertFalse(ImportTerminationOutcome.completed.showsStoppedMessage)

    XCTAssertFalse(ImportTerminationOutcome.stopped.reportsTaskSuccess)
    XCTAssertTrue(ImportTerminationOutcome.stopped.removesStagedFile)
    XCTAssertTrue(ImportTerminationOutcome.stopped.showsStoppedMessage)

    XCTAssertFalse(ImportTerminationOutcome.failed.reportsTaskSuccess)
    XCTAssertTrue(ImportTerminationOutcome.failed.removesStagedFile)
    XCTAssertFalse(ImportTerminationOutcome.failed.showsStoppedMessage)
  }
}

final class ImportProgressAggregatorTests: XCTestCase {
  func testCombinesSeveralFilesIntoOneFraction() {
    var agg = ImportProgressAggregator(items: [("a.iso", 100), ("b.iso", 300)])
    XCTAssertEqual(agg.totalBytes, 400)
    agg.update(item: 0, copiedBytes: 100)
    agg.update(item: 1, copiedBytes: 100)
    XCTAssertEqual(agg.copiedBytes, 200)
    XCTAssertEqual(agg.fractionCompleted, 0.5, accuracy: 0.0001)
    XCTAssertEqual(agg.unitCounts.total, 400)
    XCTAssertEqual(agg.unitCounts.completed, 200)
  }

  func testUpdatesAreClampedAndNeverMoveBackwards() {
    var agg = ImportProgressAggregator(items: [("a", 100)])
    agg.update(item: 0, copiedBytes: 60)
    agg.update(item: 0, copiedBytes: 20)
    XCTAssertEqual(agg.copiedBytes, 60)
    agg.update(item: 0, copiedBytes: 5000)
    XCTAssertEqual(agg.copiedBytes, 100)
    agg.update(item: 0, copiedBytes: -4)
    XCTAssertEqual(agg.copiedBytes, 100)
  }

  func testOutOfRangeIndexIsIgnored() {
    var agg = ImportProgressAggregator(items: [("a", 100)])
    agg.update(item: 7, copiedBytes: 50)
    agg.finish(item: -1)
    XCTAssertEqual(agg.copiedBytes, 0)
    XCTAssertEqual(agg.finishedCount, 0)
  }

  func testSkippedFilesAddNothingAndCountAsFinished() {
    var agg = ImportProgressAggregator(items: [("already.iso", 0), ("new.iso", 200)])
    agg.finish(item: 0)
    XCTAssertEqual(agg.totalBytes, 200)
    XCTAssertEqual(agg.fractionCompleted, 0)
    XCTAssertEqual(agg.currentName, "new.iso")
    agg.update(item: 1, copiedBytes: 100)
    XCTAssertEqual(agg.fractionCompleted, 0.5, accuracy: 0.0001)
  }

  func testFinishFillsTheItemAndStopsFurtherUpdates() {
    var agg = ImportProgressAggregator(items: [("a", 100), ("b", 100)])
    agg.finish(item: 0)
    agg.update(item: 0, copiedBytes: 3)
    XCTAssertEqual(agg.copiedBytes, 100)
    XCTAssertEqual(agg.finishedCount, 1)
    XCTAssertEqual(agg.currentName, "b")
  }

  func testNegativeSizesCountAsZeroAndZeroTotalNeverReportsZeroUnits() {
    var agg = ImportProgressAggregator(items: [("a", -5)])
    XCTAssertEqual(agg.totalBytes, 0)
    XCTAssertEqual(agg.unitCounts.total, 1)
    XCTAssertEqual(agg.unitCounts.completed, 0)
    XCTAssertEqual(agg.fractionCompleted, 0)
    agg.finish(item: 0)
    XCTAssertEqual(agg.unitCounts.completed, 1)
    XCTAssertEqual(agg.fractionCompleted, 1)
  }
}

final class ContinuedImportLifecycleTests: XCTestCase {
  private func run(_ events: [ContinuedImportEvent]) -> (ContinuedImportLifecycle, [[ContinuedImportEffect]]) {
    var lifecycle = ContinuedImportLifecycle()
    var all: [[ContinuedImportEffect]] = []
    for event in events { all.append(lifecycle.handle(event)) }
    return (lifecycle, all)
  }

  func testNormalRunCompletesTheTaskOnceWithSuccess() {
    let (lifecycle, effects) = run([.submissionSucceeded, .systemStarted, .workEnded(.completed)])
    XCTAssertEqual(effects.flatMap { $0 }, [.completeTask(success: true)])
    XCTAssertTrue(lifecycle.taskCompleted)
  }

  func testLaunchHandlerMayRunBeforeTheSubmitCallback() {
    let (lifecycle, effects) = run([.systemStarted, .submissionSucceeded, .workEnded(.completed)])
    XCTAssertEqual(effects.flatMap { $0 }, [.completeTask(success: true)])
    XCTAssertTrue(lifecycle.taskCompleted)
  }

  func testWorkFinishingBeforeTheSystemStartsWithdrawsTheRequestAndCompletesALateTask() {
    var lifecycle = ContinuedImportLifecycle()
    XCTAssertEqual(lifecycle.handle(.submissionSucceeded), [])
    XCTAssertEqual(lifecycle.handle(.workEnded(.completed)), [.withdrawRequest])
    // The withdraw raced with the system, which ran the handler anyway: complete it at once.
    XCTAssertEqual(lifecycle.handle(.systemStarted), [.completeTask(success: true)])
    XCTAssertEqual(lifecycle.handle(.systemStarted), [])
  }

  func testWorkFinishingBeforeTheSubmitCallbackWithdrawsWhenItArrives() {
    var lifecycle = ContinuedImportLifecycle()
    XCTAssertEqual(lifecycle.handle(.workEnded(.completed)), [])
    XCTAssertEqual(lifecycle.handle(.submissionSucceeded), [.withdrawRequest])
  }

  func testRefusedSubmissionLeavesNothingToDo() {
    let (lifecycle, effects) = run([.submissionFailed, .workEnded(.completed), .systemStarted])
    XCTAssertEqual(effects.flatMap { $0 }, [])
    XCTAssertFalse(lifecycle.taskCompleted)
    XCTAssertFalse(lifecycle.isProtected)
  }

  func testExpirationCancelsTheWorkAndCompletesTheTaskAsFailedWhenItUnwinds() {
    var lifecycle = ContinuedImportLifecycle()
    _ = lifecycle.handle(.submissionSucceeded)
    _ = lifecycle.handle(.systemStarted)
    XCTAssertEqual(lifecycle.handle(.systemExpired),
                   [.cancelWork, .armExpirationDeadline(seconds: ContinuedImportLifecycle.expirationGraceSeconds)])
    XCTAssertTrue(lifecycle.isCancellationRequested)
    XCTAssertEqual(lifecycle.handle(.workEnded(.stopped)), [.completeTask(success: false)])
    // The grace timer firing afterwards, or a second expiration, does nothing.
    XCTAssertEqual(lifecycle.handle(.deadlineElapsed), [])
    XCTAssertEqual(lifecycle.handle(.systemExpired), [])
  }

  func testExpirationWithWorkThatCannotUnwindCompletesAtTheDeadline() {
    var lifecycle = ContinuedImportLifecycle()
    _ = lifecycle.handle(.submissionSucceeded)
    _ = lifecycle.handle(.systemStarted)
    _ = lifecycle.handle(.systemExpired)
    XCTAssertEqual(lifecycle.handle(.deadlineElapsed), [.completeTask(success: false)])
    // The stuck work finally ends: the task is already completed, so nothing more is sent.
    XCTAssertEqual(lifecycle.handle(.workEnded(.stopped)), [])
  }

  func testExpirationRepeatedDoesNotRearmTheDeadline() {
    var lifecycle = ContinuedImportLifecycle()
    _ = lifecycle.handle(.systemStarted)
    XCTAssertEqual(lifecycle.handle(.systemExpired).count, 2)
    XCTAssertEqual(lifecycle.handle(.systemExpired), [])
  }

  func testFailureReportsUnsuccessfulCompletion() {
    let (_, effects) = run([.submissionSucceeded, .systemStarted, .workEnded(.failed)])
    XCTAssertEqual(effects.flatMap { $0 }, [.completeTask(success: false)])
  }

  func testExpirationAfterTheWorkFinishedIsIgnored() {
    var lifecycle = ContinuedImportLifecycle()
    _ = lifecycle.handle(.systemStarted)
    _ = lifecycle.handle(.workEnded(.completed))
    XCTAssertEqual(lifecycle.handle(.systemExpired), [])
    XCTAssertFalse(lifecycle.isCancellationRequested)
  }
}

private final class FakeTask: ContinuedImportTaskPort {
  var progress: [(Int64, Int64)] = []
  var texts: [String] = []
  var completions: [Bool] = []
  func setProgress(total: Int64, completed: Int64) { progress.append((total, completed)) }
  func setText(title: String, subtitle: String) { texts.append(subtitle) }
  func completeTask(success: Bool) { completions.append(success) }
}

private final class FakeHost: ContinuedImportSessionHost {
  var withdrawn = 0
  var deadlines: [TimeInterval] = []
  var fireDeadline: (() -> Void)?
  func withdrawRequest() { withdrawn += 1 }
  func scheduleDeadline(seconds: TimeInterval, fire: @escaping () -> Void) {
    deadlines.append(seconds)
    fireDeadline = fire
  }
}

final class ContinuedImportSessionTests: XCTestCase {
  private func makeSession(host: FakeHost, items: [(String, Int64)] = [("a.iso", 4_000_000), ("b.iso", 4_000_000)])
    -> ContinuedImportSession {
    ContinuedImportSession(items: items, host: host, title: "Importing",
                           subtitle: { finished, count in "\(finished)/\(count)" })
  }

  func testOneTaskCarriesCombinedProgressOfEveryFile() {
    let host = FakeHost(), task = FakeTask()
    let session = makeSession(host: host)
    session.submissionFinished(error: nil)
    session.taskStarted(port: task)
    XCTAssertEqual(task.progress.last?.0, 8_000_000)
    XCTAssertEqual(task.progress.last?.1, 0)

    session.update(item: 0, copiedBytes: 4_000_000)
    session.finish(item: 0)
    XCTAssertEqual(task.progress.last?.1, 4_000_000)
    XCTAssertEqual(task.texts.last, "1/2")

    session.update(item: 1, copiedBytes: 2_500_000)
    XCTAssertEqual(task.progress.last?.1, 6_500_000)
    XCTAssertEqual(task.progress.last?.0, 8_000_000)

    session.finish(item: 1)
    session.workEnded(.completed)
    XCTAssertEqual(task.progress.last?.1, 8_000_000)
    XCTAssertEqual(task.completions, [true])
  }

  func testProgressIsThrottledButTheFinalValueIsAlwaysPushed() {
    let host = FakeHost(), task = FakeTask()
    let session = makeSession(host: host, items: [("a", 100_000_000)])
    session.taskStarted(port: task)
    let pushedAtStart = task.progress.count
    for bytes in stride(from: Int64(1), through: 900_000, by: 1000) { session.update(item: 0, copiedBytes: bytes) }
    XCTAssertEqual(task.progress.count, pushedAtStart, "under one interval of progress must not be pushed")
    session.update(item: 0, copiedBytes: ContinuedImportSession.progressPushIntervalBytes + 1)
    XCTAssertEqual(task.progress.count, pushedAtStart + 1)
  }

  func testProgressBeforeTheTaskStartsIsReportedWhenItDoes() {
    let host = FakeHost(), task = FakeTask()
    let session = makeSession(host: host)
    session.update(item: 0, copiedBytes: 3_000_000)
    session.taskStarted(port: task)
    XCTAssertEqual(task.progress.last?.1, 3_000_000)
  }

  func testExpirationRequestsCancellationAndCompletesAsFailed() {
    let host = FakeHost(), task = FakeTask()
    let session = makeSession(host: host)
    session.submissionFinished(error: nil)
    session.taskStarted(port: task)
    XCTAssertFalse(session.isCancellationRequested)

    session.taskExpired()
    XCTAssertTrue(session.isCancellationRequested)
    XCTAssertEqual(host.deadlines, [ContinuedImportLifecycle.expirationGraceSeconds])
    XCTAssertTrue(task.completions.isEmpty, "wait for the copy to unwind")

    session.workEnded(.stopped)
    XCTAssertEqual(task.completions, [false])
    host.fireDeadline?()
    XCTAssertEqual(task.completions, [false], "completed exactly once")
  }

  func testDeadlineCompletesATaskWhoseWorkCannotStop() {
    let host = FakeHost(), task = FakeTask()
    let session = makeSession(host: host)
    session.taskStarted(port: task)
    session.taskExpired()
    host.fireDeadline?()
    XCTAssertEqual(task.completions, [false])
    session.workEnded(.stopped)
    XCTAssertEqual(task.completions, [false])
  }

  func testSmallImportThatEndsBeforeTheSystemStartsWithdrawsTheRequest() {
    let host = FakeHost(), task = FakeTask()
    let session = makeSession(host: host)
    session.submissionFinished(error: nil)
    session.workEnded(.completed)
    XCTAssertEqual(host.withdrawn, 1)
    session.taskStarted(port: task)
    XCTAssertEqual(task.completions, [true])
  }

  func testRefusedSubmissionNeverTouchesTheTask() {
    let host = FakeHost()
    let session = makeSession(host: host)
    session.submissionFinished(error: NSError(domain: "test", code: 1))
    session.workEnded(.completed)
    XCTAssertEqual(host.withdrawn, 0)
    XCTAssertFalse(session.isProtected)
  }
}
