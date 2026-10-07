// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import os
import XCTest

@testable import iCube

/// Library background work must not run while a game does: a Wi-Fi flap used to walk the whole
/// Software folder and rewrite the game cache mid-game.
@MainActor
final class RemoteSourcesCoordinatorDeferralTests: XCTestCase {
  private var state: EmulationState!
  private var pushes: [[String]] = []
  private var coordinator: RemoteSourcesCoordinator!

  override func setUp() {
    super.setUp()
    state = EmulationState(center: NotificationCenter())
    pushes = []
    coordinator = RemoteSourcesCoordinator(
      startPathMonitor: false,
      emulationState: state,
      pushToLibrary: { [unowned self] urls in self.pushes.append(urls) })
  }

  private func addRemoteItem(_ urlString: String = "https://example.test/a.iso") {
    let url = URL(string: urlString)!
    coordinator.lastItemsBySource["src"] = [
      RemoteLibraryItem(url: url, displayName: url.lastPathComponent, sizeBytes: nil, etag: nil, lastModified: nil)
    ]
  }

  func test_pathChangeWhileIdlePushesWhenThereAreRemoteItems() {
    addRemoteItem()
    coordinator.handlePathUpdate(satisfied: true)
    XCTAssertEqual(pushes.count, 1)
    XCTAssertFalse(coordinator.needsPush)
  }

  func test_pathChangeDuringEmulationSetsNeedsPushAndDoesNotPush() {
    addRemoteItem()
    state.setActive(true)

    coordinator.handlePathUpdate(satisfied: true)

    XCTAssertTrue(coordinator.needsPush)
    XCTAssertTrue(pushes.isEmpty)
  }

  func test_flushesOnceWhenEmulationEnds() {
    addRemoteItem()
    state.setActive(true)
    coordinator.handlePathUpdate(satisfied: true)
    coordinator.handlePathUpdate(satisfied: false)
    coordinator.handlePathUpdate(satisfied: true)
    XCTAssertTrue(pushes.isEmpty, "a flapping network must not push while a game runs")

    state.setActive(false)

    XCTAssertEqual(pushes.count, 1, "every held-back request collapses into one push")
    XCTAssertFalse(coordinator.needsPush)
  }

  func test_offlineFlapDuringEmulationStillTracksOnlineState() {
    addRemoteItem()
    coordinator.handlePathUpdate(satisfied: true) // initial, idle: pushes
    state.setActive(true)
    coordinator.handlePathUpdate(satisfied: false)
    XCTAssertEqual(pushes.count, 1)
    XCTAssertTrue(coordinator.needsPush)
    state.setActive(false)
    XCTAssertEqual(pushes.count, 2, "the offline state is pushed once the game is over")
  }

  func test_unforcedPushDuringEmulationIsAlsoHeld() {
    state.setActive(true)
    coordinator.pushCacheUpdate()
    XCTAssertTrue(coordinator.needsPush)
    XCTAssertTrue(pushes.isEmpty)
  }

  func test_endWithNothingHeldDoesNotPush() {
    state.setActive(true)
    state.setActive(false)
    XCTAssertTrue(pushes.isEmpty)
  }

  func test_noForcedPushWithZeroSources() {
    // The launch path callback and every Wi-Fi flap: nothing remote to add or remove.
    coordinator.handlePathUpdate(satisfied: true)
    coordinator.handlePathUpdate(satisfied: false)
    coordinator.pushCacheUpdate(forceUpdate: true)
    coordinator.pushCacheUpdate(forceUpdate: true)

    XCTAssertTrue(pushes.isEmpty, "with no remote sources a network change must not walk the library")
  }

  // MARK: - Path sequences

  private func wait(_ seconds: TimeInterval) {
    let done = expectation(description: "waited")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
    wait(for: [done], timeout: seconds + 2)
  }

  func test_initialUnsatisfiedPathIsRecordedAndNothingIsPushed() {
    addRemoteItem()
    coordinator.handlePathUpdate(satisfied: false)
    XCTAssertTrue(pushes.isEmpty, "an offline launch has no online-to-offline transition to announce")
    XCTAssertFalse(coordinator.needsPush)
  }

  func test_reconnectAfterAnOfflineLaunchIsARealReconnectNotTheInitialCallback() {
    addRemoteItem()
    coordinator.onlineSettleDelay = 0.05
    coordinator.handlePathUpdate(satisfied: false)

    coordinator.handlePathUpdate(satisfied: true)
    XCTAssertTrue(pushes.isEmpty, "a real reconnection waits out the settle delay; the initial one pushes at once")

    wait(0.3)
    XCTAssertEqual(pushes.count, 1)
  }

  func test_goingOfflineDuringTheSettleWindowCancelsTheStaleRefresh() {
    addRemoteItem()
    coordinator.onlineSettleDelay = 0.05
    coordinator.handlePathUpdate(satisfied: true) // initial: push 1
    coordinator.handlePathUpdate(satisfied: false) // push 2
    coordinator.handlePathUpdate(satisfied: true) // settle window opens
    coordinator.handlePathUpdate(satisfied: false) // push 3, supersedes the window
    XCTAssertEqual(pushes.count, 3)

    wait(0.3)
    XCTAssertEqual(pushes.count, 3, "no relist, push or Back online snackbar for a path that is offline again")
  }

  func test_onlineDuringPlayAfterAnOfflineLaunchIsNotLostOnceThereIsSomethingToPush() {
    coordinator.handlePathUpdate(satisfied: false) // fresh install, launched offline
    state.setActive(true)
    coordinator.handlePathUpdate(satisfied: true)
    XCTAssertTrue(coordinator.needsPush)
    XCTAssertTrue(pushes.isEmpty)

    addRemoteItem() // a source finished listing
    state.setActive(false)
    XCTAssertEqual(pushes.count, 1)
  }

  func test_onlineDuringPlayWithNothingRemoteDoesNotWalkTheLibrary() {
    coordinator.handlePathUpdate(satisfied: false)
    state.setActive(true)
    coordinator.handlePathUpdate(satisfied: true)
    state.setActive(false)
    XCTAssertTrue(pushes.isEmpty, "no sources and nothing pushed: there is nothing to add or remove")
    XCTAssertFalse(coordinator.needsPush)
  }

  func test_removingASourceStillCleansUpTheCache() {
    // The deleted source's games may be in the persisted cache even if this session never pushed.
    coordinator.pushCacheUpdate(forceUpdate: true, cleanup: true)
    XCTAssertEqual(pushes.count, 1)
  }

  func test_cleanupIsRememberedAcrossASession() {
    state.setActive(true)
    coordinator.pushCacheUpdate(forceUpdate: true, cleanup: true)
    XCTAssertTrue(pushes.isEmpty)
    state.setActive(false)
    XCTAssertEqual(pushes.count, 1, "the deferred push still has to clean up the removed source's games")
  }

  func test_forcedPushStillRunsWhenSourcesWerePushedBefore() {
    addRemoteItem()
    coordinator.pushCacheUpdate(forceUpdate: true)
    XCTAssertEqual(pushes.count, 1)

    // Source removed: the library has to be cleaned up.
    coordinator.lastItemsBySource = [:]
    coordinator.pushCacheUpdate(forceUpdate: true)
    XCTAssertEqual(pushes.count, 2)
    XCTAssertEqual(pushes.last, [])
  }
}

@MainActor
final class LibraryCoordinatorDeferralTests: XCTestCase {
  private var state: EmulationState!
  private var loads = 0
  private var coordinator: LibraryCoordinator!

  override func setUp() {
    super.setUp()
    state = EmulationState(center: NotificationCenter())
    loads = 0
    coordinator = LibraryCoordinator(emulationState: state, gamesProvider: { [unowned self] in
      self.loads += 1
      return []
    })
  }

  func test_reloadRunsImmediatelyWhenIdle() {
    coordinator.loadCurrent()
    XCTAssertEqual(loads, 1)
  }

  func test_reloadIsHeldDuringEmulationAndRunsOnceAtTheEnd() {
    state.setActive(true)
    coordinator.loadCurrent()
    coordinator.loadCurrent()
    XCTAssertEqual(loads, 0)
    XCTAssertTrue(coordinator.needsReload)

    state.setActive(false)
    XCTAssertEqual(loads, 1)
    XCTAssertFalse(coordinator.needsReload)
  }

  func test_firstLoadAlwaysRuns() {
    state.setActive(true)
    coordinator.start()
    XCTAssertEqual(loads, 1, "a library opened mid-session has nothing to show without it")
  }

  func test_endingWithinTheDebounceWindowReloadsOnce() {
    state.setActive(true)
    NotificationCenter.default.post(name: NSNotification.Name("RemoteLibraryUpdated"), object: nil)
    wait(0.5) // the debounce fires mid-game: held
    XCTAssertEqual(loads, 0)
    XCTAssertTrue(coordinator.needsReload)

    NotificationCenter.default.post(name: NSNotification.Name("RemoteLibraryUpdated"), object: nil)
    state.setActive(false) // inside the new debounce window
    XCTAssertEqual(loads, 1)

    wait(0.5)
    XCTAssertEqual(loads, 1, "the end-of-session reload covers the pending debounced one")
  }

  private func wait(_ seconds: TimeInterval) {
    let done = expectation(description: "waited")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
    wait(for: [done], timeout: seconds + 2)
  }

  func test_endingWithALocalRefreshOwedAndADebouncePendingReloadsOnce() {
    // Its own state and counter: the fixture coordinator also listens for the notifications.
    let ownState = EmulationState(center: NotificationCenter())
    var ownLoads = 0
    var rescanDone: (() -> Void)?
    let own = LibraryCoordinator(
      emulationState: ownState,
      gamesProvider: {
        ownLoads += 1
        return []
      },
      localRescan: { rescanDone = $0 })
    ownState.setActive(true)
    NotificationCenter.default.post(name: NSNotification.Name("RemoteLibraryUpdated"), object: nil)
    wait(0.5) // the debounce fires mid-game: held
    own.refreshLocalWhenIdle()
    XCTAssertTrue(own.needsLocalRefresh)

    NotificationCenter.default.post(name: NSNotification.Name("RemoteLibraryUpdated"), object: nil)
    ownState.setActive(false) // starts the rescan; a debounce is still pending
    wait(0.5)
    XCTAssertEqual(ownLoads, 0, "nothing may reload while the rescan is still scanning")

    rescanDone?()
    wait(0.6)
    XCTAssertEqual(ownLoads, 1, "the rescan's completion is the single reload")
  }

  func test_initialRescanWaitsForTheSessionToEnd() {
    state.setActive(true)
    coordinator.refreshLocalWhenIdle()
    XCTAssertTrue(coordinator.needsLocalRefresh)
    XCTAssertEqual(loads, 0)
  }
}

@MainActor
final class LibrarySnapshotSchedulerTests: XCTestCase {
  private var state: EmulationState!
  private var scheduled: [(delay: TimeInterval, work: DispatchWorkItem)] = []
  private var writes = 0
  /// Completions of writes that have started and not yet been reported saved or failed.
  private var running: [@MainActor (Bool) -> Void] = []
  /// When true the fake writer reports saved immediately; otherwise the test completes it.
  private var autoComplete = true
  private var backgroundTasksBegun = 0
  private var backgroundTasksEnded = 0
  private var scheduler: LibrarySnapshotScheduler!

  override func setUp() {
    super.setUp()
    state = EmulationState(center: NotificationCenter())
    scheduled = []
    writes = 0
    running = []
    autoComplete = true
    backgroundTasksBegun = 0
    backgroundTasksEnded = 0
    scheduler = LibrarySnapshotScheduler(
      state: state,
      write: { [unowned self] completion in
        self.writes += 1
        if self.autoComplete { completion(true) } else { self.running.append(completion) }
      },
      schedule: { [unowned self] delay, work in self.scheduled.append((delay, work)) },
      beginBackgroundTask: { [unowned self] _ in
        self.backgroundTasksBegun += 1
        return UIBackgroundTaskIdentifier(rawValue: 42)
      },
      endBackgroundTask: { [unowned self] _ in self.backgroundTasksEnded += 1 })
    scheduler.installEmulationGate()
  }

  private func runScheduled() {
    let items = scheduled
    scheduled = []
    for item in items { item.work.perform() }
  }

  private func finishRunningWrite(saved: Bool) {
    let completion = running.removeFirst()
    completion(saved)
  }

  func test_idleRequestSchedulesAWrite() {
    scheduler.requestWrite(after: 2)
    XCTAssertEqual(scheduled.map(\.delay), [2])
    runScheduled()
    XCTAssertEqual(writes, 1)
  }

  func test_burstOfRequestsWritesOnce() {
    scheduler.requestWrite(after: 2)
    scheduler.requestWrite(after: 2)
    scheduler.requestWrite(after: 2)
    runScheduled() // cancelled items do not run
    XCTAssertEqual(writes, 1)
  }

  func test_requestDuringASessionWritesNothingUntilItEnds() {
    state.setActive(true)
    scheduler.requestWrite(after: 0.5)
    XCTAssertTrue(scheduled.isEmpty)
    XCTAssertTrue(scheduler.writeHeldForSession)
    runScheduled()
    XCTAssertEqual(writes, 0)

    state.setActive(false)
    XCTAssertEqual(scheduled.map(\.delay), [LibrarySnapshotScheduler.postSessionDelay])
    runScheduled()
    XCTAssertEqual(writes, 1)
    XCTAssertFalse(scheduler.writeHeldForSession)
  }

  func test_writeScheduledBeforeBootIsCancelledAndRunsAfterTheGame() {
    scheduler.requestWrite(after: 3) // e.g. foreground at launch, then auto-resume boots
    state.setActive(true)
    runScheduled()
    XCTAssertEqual(writes, 0, "the pending write must not land in the boot")

    state.setActive(false)
    runScheduled()
    XCTAssertEqual(writes, 1)
  }

  func test_sessionStartAlwaysOwesAWriteAtTheEnd() {
    // Last-played is stamped at boot; the widget needs the snapshot even if nothing else asked.
    state.setActive(true)
    state.setActive(false)
    runScheduled()
    XCTAssertEqual(writes, 1)
  }

  func test_endWithoutASessionDoesNotWrite() {
    state.setActive(false)
    runScheduled()
    XCTAssertEqual(writes, 0)
  }

  func test_installingTheGateTwiceDoesNotDoubleTheFlush() {
    scheduler.installEmulationGate()
    state.setActive(true)
    state.setActive(false)
    runScheduled()
    XCTAssertEqual(writes, 1)
  }

  // MARK: - Durability

  func test_heldWriteStaysHeldUntilTheSaveCompletes() {
    autoComplete = false
    state.setActive(true)
    state.setActive(false)
    runScheduled()
    XCTAssertEqual(writes, 1)
    XCTAssertTrue(scheduler.writeHeldForSession, "launching the write is not the same as saving it")

    finishRunningWrite(saved: true)
    XCTAssertFalse(scheduler.writeHeldForSession)
  }

  func test_failedSaveKeepsTheWriteOwed() {
    autoComplete = false
    state.setActive(true)
    state.setActive(false)
    runScheduled()
    finishRunningWrite(saved: false)
    XCTAssertTrue(scheduler.writeHeldForSession)
  }

  func test_aDebtIncurredDuringAWriteSurvivesItsCompletion() {
    autoComplete = false
    state.setActive(true)
    state.setActive(false)
    runScheduled() // write 1 in flight
    state.setActive(true) // a new session owes another write
    finishRunningWrite(saved: true)
    XCTAssertTrue(scheduler.writeHeldForSession, "the write that finished predates the new debt")
  }

  // MARK: - Backgrounding

  func test_backgroundingMidGameWritesWhatWasHeldUnderABackgroundTask() {
    autoComplete = false
    state.setActive(true)
    scheduler.requestWrite(after: 2)
    XCTAssertEqual(writes, 0)

    scheduler.flushForBackground()
    XCTAssertEqual(writes, 1)
    XCTAssertEqual(backgroundTasksBegun, 1)
    XCTAssertEqual(backgroundTasksEnded, 0, "the assertion lasts until the snapshot is saved")
    XCTAssertTrue(scheduler.writeHeldForSession)

    finishRunningWrite(saved: true)
    XCTAssertFalse(scheduler.writeHeldForSession)
    XCTAssertEqual(backgroundTasksEnded, 1)

    state.setActive(false)
    runScheduled()
    XCTAssertEqual(writes, 1, "nothing changed since the background write, so the end owes none")
  }

  func test_backgroundingJustAfterTheGameEndedFlushesTheScheduledWrite() {
    state.setActive(true)
    state.setActive(false) // the post-session write is scheduled 1 s out, state is no longer active
    XCTAssertEqual(writes, 0)

    scheduler.flushForBackground()

    XCTAssertEqual(writes, 1)
    XCTAssertFalse(scheduler.writeHeldForSession)
    runScheduled() // the cancelled scheduled item must not write again
    XCTAssertEqual(writes, 1)
  }

  func test_backgroundingWithAnIdleScheduledWriteFlushesIt() {
    scheduler.requestWrite(after: 2)
    scheduler.flushForBackground()
    XCTAssertEqual(writes, 1)
    XCTAssertEqual(backgroundTasksEnded, 1)
  }

  func test_backgroundingWithNothingOwedDoesNothing() {
    scheduler.flushForBackground()
    XCTAssertEqual(writes, 0)
    XCTAssertEqual(backgroundTasksBegun, 0)
  }

  func test_backgroundingDuringAWriteInFlightQueuesOneMoreAndHoldsTheTask() {
    autoComplete = false
    scheduler.requestWrite(after: 2)
    runScheduled() // write 1 in flight
    scheduler.requestWrite(after: 2) // a change after it started
    scheduler.flushForBackground()
    XCTAssertEqual(writes, 1, "one write at a time")
    XCTAssertEqual(backgroundTasksBegun, 1)

    finishRunningWrite(saved: true)
    XCTAssertEqual(writes, 2, "the change made during the first write is saved too")
    XCTAssertEqual(backgroundTasksEnded, 0)

    finishRunningWrite(saved: true)
    XCTAssertEqual(backgroundTasksEnded, 1)
  }

  func test_backgroundingDuringTheInFlightPostSessionWriteWithNoNewDebtWritesOnce() {
    autoComplete = false
    state.setActive(true)
    state.setActive(false)
    runScheduled() // the post-session write is in flight and its debt is still held
    XCTAssertEqual(writes, 1)

    scheduler.flushForBackground()
    XCTAssertEqual(backgroundTasksBegun, 1)
    finishRunningWrite(saved: true)

    XCTAssertEqual(writes, 1, "the running write already covers that debt")
    XCTAssertFalse(scheduler.writeHeldForSession)
    XCTAssertEqual(backgroundTasksEnded, 1)
  }

  func test_backgroundingDuringAnInFlightWriteWithNewDebtWritesAgain() {
    autoComplete = false
    state.setActive(true)
    state.setActive(false)
    runScheduled()
    state.setActive(true) // a new session: new debt
    scheduler.flushForBackground()
    finishRunningWrite(saved: true)
    XCTAssertEqual(writes, 2)
  }

  func test_failedBackgroundSaveEndsTheTaskAndStaysOwed() {
    autoComplete = false
    state.setActive(true)
    scheduler.flushForBackground()
    finishRunningWrite(saved: false)
    XCTAssertEqual(backgroundTasksEnded, 1)
    XCTAssertTrue(scheduler.writeHeldForSession)
  }
}

/// A WebDAV scan must not run PROPFINDs through a boot or a session: `TVEmulationBridge.isRunning()`
/// is false until the core reaches Starting, and a scan already under way used to ignore the game.
final class WebDAVSessionGateTests: XCTestCase {
  private func makeSource(active: OSAllocatedUnfairLock<Bool>) -> WebDAVSource {
    let source = WebDAVSource(name: "t", url: URL(string: "https://example.test/dav")!, username: nil, password: nil, recursive: true)
    source.isEmulationSessionActive = { active.withLock { $0 } }
    source.sessionPollInterval = 0.02
    return source
  }

  func test_waitReturnsAtOnceWhenNoSessionIsActive() async {
    let source = makeSource(active: OSAllocatedUnfairLock(initialState: false))
    let start = Date()
    await source.waitWhileEmulationActive()
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
  }

  func test_waitHoldsUntilTheSessionEnds() async {
    let active = OSAllocatedUnfairLock(initialState: true)
    let source = makeSource(active: active)
    let finished = OSAllocatedUnfairLock(initialState: false)
    let task = Task {
      await source.waitWhileEmulationActive()
      finished.withLock { $0 = true }
    }
    try? await Task.sleep(nanoseconds: 200_000_000)
    XCTAssertFalse(finished.withLock { $0 }, "an in-flight scan must stay paused for the whole session")

    active.withLock { $0 = false }
    await task.value
    XCTAssertTrue(finished.withLock { $0 })
  }

  func test_waitEndsWhenTheScanIsCancelled() async {
    let source = makeSource(active: OSAllocatedUnfairLock(initialState: true))
    let task = Task { await source.waitWhileEmulationActive() }
    try? await Task.sleep(nanoseconds: 100_000_000)
    task.cancel()
    await task.value
  }

  @MainActor
  func test_onlyTheSharedStatePublishesTheProcessWideFlag() {
    let state = EmulationState(center: NotificationCenter())
    state.setActive(true)
    XCTAssertFalse(EmulationState.isSessionActive, "a test instance must not flip the app's flag")
  }
}

final class PadPollThrottleTests: XCTestCase {
  func test_idleRunsEveryTick() {
    let throttle = PadPollThrottle()
    for tick in 0 ..< 10 {
      XCTAssertTrue(throttle.shouldRun(at: Double(tick) / 60, emulating: false))
    }
  }

  func test_emulatingRunsAtHalfRate() {
    let throttle = PadPollThrottle()
    let ran = (0 ..< 60).filter { throttle.shouldRun(at: Double($0) / 60, emulating: true) }
    XCTAssertEqual(ran.count, 30)
  }

  func test_emulatingToleratesTimerJitter() {
    let throttle = PadPollThrottle()
    XCTAssertTrue(throttle.shouldRun(at: 1.000, emulating: true))
    XCTAssertFalse(throttle.shouldRun(at: 1.0167, emulating: true))
    // 31 ms after the last run: a hair early, still accepted.
    XCTAssertTrue(throttle.shouldRun(at: 1.031, emulating: true))
  }

  func test_firstTickWhileEmulatingRuns() {
    XCTAssertTrue(PadPollThrottle().shouldRun(at: 0.001, emulating: true))
  }
}

final class LibraryAnimatedBackgroundTests: XCTestCase {
  func test_geometryIsDeterministicAndInRange() {
    for index in 0 ..< 8 {
      for salt in 1 ... 10 {
        let value = LibraryAnimatedBackground.unit(index, salt: salt)
        XCTAssertEqual(value, LibraryAnimatedBackground.unit(index, salt: salt), "body must not draw new random values")
        XCTAssertTrue((0 ..< 1).contains(value))
      }
    }
  }
}
