// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

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
  private var scheduler: LibrarySnapshotScheduler!

  override func setUp() {
    super.setUp()
    state = EmulationState(center: NotificationCenter())
    scheduled = []
    writes = 0
    scheduler = LibrarySnapshotScheduler(
      state: state,
      write: { [unowned self] in self.writes += 1 },
      schedule: { [unowned self] delay, work in self.scheduled.append((delay, work)) })
    scheduler.installEmulationGate()
  }

  private func runScheduled() {
    for item in scheduled { item.work.perform() }
    scheduled = []
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

  func test_backgroundingMidGameWritesWhatWasHeld() {
    // The app can be killed before the session ever ends.
    state.setActive(true)
    scheduler.requestWrite(after: 2)
    XCTAssertEqual(writes, 0)

    scheduler.flushHeldWriteForBackground()
    XCTAssertEqual(writes, 1)
    XCTAssertFalse(scheduler.writeHeldForSession)

    state.setActive(false)
    runScheduled()
    XCTAssertEqual(writes, 1, "nothing changed since the background write, so the end owes none")
  }

  func test_backgroundFlushIsOneShotAndSkippedWhenIdle() {
    scheduler.flushHeldWriteForBackground()
    XCTAssertEqual(writes, 0)
    state.setActive(true)
    scheduler.flushHeldWriteForBackground()
    XCTAssertEqual(writes, 1, "a session start owes a write (last-played changed at boot)")
    scheduler.flushHeldWriteForBackground()
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
