// DolphiniOSTests/PauseLifecycleTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// Resign-active / become-active against the arbiter: the app-inactive claim must pause a running game
/// and must never resume one that another holder (pause menu, Settings, the user's pause) keeps paused.
@MainActor
final class PauseLifecycleTests: XCTestCase {
  /// Models TVEmulationBridge: every pause or resume, sync or async, bumps a generation at call time; a queued
  /// async job runs only if it is still the newest and the core is in the state it expects.
  private final class FakeCore {
    var running = true
    var paused = false
    /// Blocking calls on the calling (main) thread.
    var pauseCalls = 0
    /// Resumes that took effect, from either path.
    var resumeCalls = 0
    var generation = 0
    /// Newest generation applied or dropped; behind `generation` while an async job is queued.
    var settled = 0
    /// Async requests queued for the host queue, run in order by `runHost()`.
    var hostJobs: [() -> Void] = []
    var core: PauseArbiter.Core {
      PauseArbiter.Core(
        isRunning: { self.running }, isPaused: { self.paused },
        pause: { self.bumpSync(); self.pauseCalls += 1; self.paused = true },
        resume: { self.bumpSync(); self.resumeCalls += 1; self.paused = false },
        pauseAsync: {
          self.generation += 1
          let issued = self.generation
          self.hostJobs.append {
            if issued == self.generation, self.running, !self.paused { self.paused = true }
            self.settled = max(self.settled, issued)
          }
        },
        resumeAsync: {
          self.generation += 1
          let issued = self.generation
          self.hostJobs.append {
            if issued == self.generation, self.paused { self.resumeCalls += 1; self.paused = false }
            self.settled = max(self.settled, issued)
          }
        },
        hasQueuedRequest: { self.settled < self.generation })
    }
    private func bumpSync() {
      generation += 1
      settled = generation
    }
    func runHost() {
      let jobs = hostJobs
      hostJobs = []
      jobs.forEach { $0() }
    }
  }

  private var fake = FakeCore()
  private var scheduled: [() -> Void] = []
  private var arbiter: PauseArbiter!

  override func setUp() {
    super.setUp()
    fake = FakeCore()
    scheduled = []
    arbiter = PauseArbiter(core: fake.core, schedule: { self.scheduled.append($0) })
  }

  private func runScheduled() {
    let work = scheduled
    scheduled = []
    work.forEach { $0() }
  }

  /// The system-driven round trip: resign, then (after any time inactive) become active.
  private func switchAwayAndBack(whileAway: () -> Void = {}) {
    arbiter.appWillResignActive()
    fake.runHost()
    runScheduled()
    whileAway()
    arbiter.appDidBecomeActive()
    fake.runHost()
    runScheduled()
  }

  // (c) running, no claim

  func test_runningGame_pausesOnResign_resumesOnBecomeActive() {
    arbiter.appWillResignActive()
    XCTAssertEqual(fake.pauseCalls, 0, "resign-active runs on main and must not block on the core")
    fake.runHost()
    XCTAssertTrue(fake.paused, "an inactive app must not keep emulating")
    XCTAssertEqual(arbiter.holders, [PauseArbiter.Reason.appInactive])
    arbiter.appDidBecomeActive()
    XCTAssertEqual(fake.pauseCalls, 0)
    fake.runHost()
    runScheduled()
    XCTAssertFalse(fake.paused)
    XCTAssertEqual(fake.resumeCalls, 1)
    XCTAssertFalse(arbiter.isHeld)
  }

  // (a) pause menu open

  func test_pauseMenuOpen_staysPausedAcrossAppSwitch() {
    let menu = arbiter.claim(PauseArbiter.Reason.pauseMenu)
    switchAwayAndBack()
    XCTAssertTrue(fake.paused, "the game must not run behind the pause menu")
    XCTAssertEqual(fake.resumeCalls, 0)
    XCTAssertEqual(arbiter.holders, [PauseArbiter.Reason.pauseMenu])
    arbiter.release(menu)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1, "closing the menu still resumes")
  }

  // (b) Settings over a paused game

  func test_settingsOpen_staysPausedAcrossAppSwitch() {
    let menu = arbiter.claim(PauseArbiter.Reason.pauseMenu)
    let settings = arbiter.claim("settings")
    switchAwayAndBack()
    XCTAssertTrue(fake.paused)
    XCTAssertEqual(fake.resumeCalls, 0)
    arbiter.release(settings)
    runScheduled()
    XCTAssertTrue(fake.paused, "the menu underneath still holds")
    arbiter.release(menu)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  func test_settingsOnly_staysPausedAcrossAppSwitch() {
    _ = arbiter.claim("settings")
    switchAwayAndBack()
    XCTAssertTrue(fake.paused)
    XCTAssertEqual(fake.resumeCalls, 0)
  }

  // (d) the user's own pause

  func test_userPause_staysPausedAcrossAppSwitch() {
    arbiter.claim(PauseArbiter.Reason.user)
    switchAwayAndBack()
    XCTAssertTrue(fake.paused, "the user's pause survives an app switch")
    XCTAssertEqual(fake.resumeCalls, 0)
    arbiter.release(reason: PauseArbiter.Reason.user)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  // Edge cases

  func test_claimReleasedWhileInactive_resumesOnlyOnBecomeActive() {
    let menu = arbiter.claim(PauseArbiter.Reason.pauseMenu)
    arbiter.appWillResignActive()
    fake.runHost()
    arbiter.release(menu)
    runScheduled()
    XCTAssertTrue(fake.paused, "still inactive: stay paused regardless of other holders")
    XCTAssertEqual(fake.resumeCalls, 0)
    arbiter.appDidBecomeActive()
    fake.runHost()
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1)
    XCTAssertFalse(fake.paused)
  }

  func test_claimMadeWhileInactive_isHonouredOnBecomeActive() {
    arbiter.appWillResignActive()
    let sheet = arbiter.claim("settings")
    arbiter.appDidBecomeActive()
    fake.runHost()
    runScheduled()
    XCTAssertTrue(fake.paused)
    XCTAssertEqual(fake.resumeCalls, 0)
    arbiter.release(sheet)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1)
    XCTAssertFalse(fake.paused)
  }

  func test_claimMadeAfterInactivePauseLanded_takesOverThePause() {
    arbiter.appWillResignActive()
    fake.runHost()
    let sheet = arbiter.claim("settings")
    XCTAssertEqual(fake.pauseCalls, 0, "the core was already paused")
    arbiter.appDidBecomeActive()
    fake.runHost()
    runScheduled()
    XCTAssertTrue(fake.paused)
    arbiter.release(sheet)
    runScheduled()
    XCTAssertFalse(fake.paused, "the last release resumes the pause the inactive transition made")
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  func test_becomeActiveBeforeTheAsyncPauseRuns_endsRunning() {
    arbiter.appWillResignActive()
    arbiter.appDidBecomeActive()
    fake.runHost()
    runScheduled()
    XCTAssertFalse(fake.paused, "a busy host queue must not leave the game paused")
    XCTAssertFalse(arbiter.isHeld)
  }

  func test_pauseNotMadeByArbiter_isNeverResumed() {
    fake.paused = true
    switchAwayAndBack()
    XCTAssertTrue(fake.paused, "a pause the arbiter did not make is not its to undo")
    XCTAssertEqual(fake.pauseCalls, 0)
    XCTAssertEqual(fake.resumeCalls, 0)
    XCTAssertTrue(fake.hostJobs.isEmpty, "no async request is made for an already paused core")
  }

  func test_noGameRunning_resignClaimsNothing() {
    fake.running = false
    arbiter.appWillResignActive()
    XCTAssertFalse(arbiter.isHeld)
    arbiter.appDidBecomeActive()
    fake.runHost()
    runScheduled()
    XCTAssertEqual(fake.pauseCalls, 0)
    XCTAssertEqual(fake.resumeCalls, 0)
    XCTAssertTrue(fake.hostJobs.isEmpty)
  }

  func test_repeatedResign_holdsOneClaim() {
    arbiter.appWillResignActive()
    arbiter.appWillResignActive()
    XCTAssertEqual(arbiter.holders, [PauseArbiter.Reason.appInactive])
    fake.runHost()
    arbiter.appDidBecomeActive()
    fake.runHost()
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  func test_becomeActiveWithoutResign_isNoOp() {
    arbiter.appDidBecomeActive()
    fake.runHost()
    runScheduled()
    XCTAssertEqual(fake.pauseCalls, 0)
    XCTAssertEqual(fake.resumeCalls, 0)
  }

  func test_emulationStopWhileInactive_doesNotBlockTheNextGame() {
    arbiter.appWillResignActive()
    arbiter.emulationDidStop()
    arbiter.appDidBecomeActive()
    fake.hostJobs = []
    runScheduled()
    fake.paused = false
    arbiter.appWillResignActive()
    XCTAssertEqual(arbiter.holders, [PauseArbiter.Reason.appInactive])
    fake.runHost()
    XCTAssertTrue(fake.paused)
  }

  func test_tvOSBackground_pendingMenuClaimOutlivesTheInactiveClaim() {
    arbiter.appWillResignActive()
    arbiter.claimPending(PauseArbiter.Reason.pauseMenuRequest)
    arbiter.appDidBecomeActive()
    fake.runHost()
    runScheduled()
    XCTAssertTrue(fake.paused, "the menu has not appeared yet: its pending claim keeps the game paused")
    XCTAssertEqual(fake.resumeCalls, 0)
    guard let adopted = arbiter.adoptPending() else { return XCTFail("the pending claim was lost") }
    arbiter.release(adopted)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  // A resume still queued on the host queue (isPaused() reads true until it runs)

  func test_claimAfterBecomeActive_beforeQueuedResumeRuns_staysPaused() {
    arbiter.appWillResignActive()
    fake.runHost()
    arbiter.appDidBecomeActive()
    XCTAssertTrue(fake.paused, "the queued resume has not run yet")
    let sheet = arbiter.claim("settings")
    fake.runHost()
    runScheduled()
    XCTAssertTrue(fake.paused, "the claim cancelled the queued resume")
    XCTAssertEqual(fake.resumeCalls, 0)
    arbiter.release(sheet)
    runScheduled()
    XCTAssertFalse(fake.paused, "and owns the pause, so its release resumes")
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  func test_resignActiveResign_beforeQueuedResumeRuns_staysPausedWhileInactive() {
    arbiter.appWillResignActive()
    fake.runHost()
    arbiter.appDidBecomeActive()
    arbiter.appWillResignActive()
    fake.runHost()
    runScheduled()
    XCTAssertTrue(fake.paused, "the second inactive period must not run the game")
    XCTAssertEqual(fake.resumeCalls, 0)
    arbiter.appDidBecomeActive()
    fake.runHost()
    runScheduled()
    XCTAssertFalse(fake.paused)
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  func test_resignActiveResign_resumeLandedFirst_pausesAgain() {
    arbiter.appWillResignActive()
    fake.runHost()
    arbiter.appDidBecomeActive()
    fake.runHost()
    XCTAssertFalse(fake.paused)
    arbiter.appWillResignActive()
    fake.runHost()
    XCTAssertTrue(fake.paused)
    arbiter.appDidBecomeActive()
    fake.runHost()
    XCTAssertFalse(fake.paused)
  }

  func test_becomeActive_claim_resign_beforeAnyJobRuns() {
    arbiter.appWillResignActive()
    fake.runHost()
    arbiter.appDidBecomeActive()
    let sheet = arbiter.claim("settings")
    arbiter.appWillResignActive()
    fake.runHost()
    arbiter.appDidBecomeActive()
    fake.runHost()
    runScheduled()
    XCTAssertTrue(fake.paused)
    arbiter.release(sheet)
    runScheduled()
    XCTAssertFalse(fake.paused)
  }

  // Resign while the game is still booting

  func test_resignWhileStarting_pausesOnceBootCompletes() {
    fake.running = true
    fake.paused = false
    arbiter.appWillResignActive()
    // Starting: the async pause finds a core that is not Running yet and does nothing.
    fake.running = false
    fake.runHost()
    XCTAssertFalse(fake.paused)
    fake.running = true
    arbiter.emulationDidStart()
    XCTAssertTrue(fake.paused, "booted while inactive: pause it")
    arbiter.appDidBecomeActive()
    fake.runHost()
    runScheduled()
    XCTAssertFalse(fake.paused)
  }

  // A pause made outside the arbiter after its queued resume has landed (N1)

  func test_externalPauseAfterResumeLanded_staysPausedAcrossAppSwitch() {
    switchAwayAndBack()
    XCTAssertFalse(fake.paused)
    fake.paused = true  // the debug API pauses the core directly
    switchAwayAndBack()
    XCTAssertTrue(fake.paused, "a landed resume must not let the arbiter take over a foreign pause")
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  func test_externalPauseAfterResumeLanded_claimReleaseDoesNotResume() {
    switchAwayAndBack()
    fake.paused = true
    let sheet = arbiter.claim("settings")
    XCTAssertEqual(fake.pauseCalls, 0, "the core is already paused and no resume of ours is queued")
    arbiter.release(sheet)
    runScheduled()
    XCTAssertTrue(fake.paused)
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  // coreWouldRun: the controller-disconnect gate

  func test_coreWouldRun_runningGame() {
    XCTAssertTrue(arbiter.coreWouldRun)
  }

  func test_coreWouldRun_whileInactivePauseHolds() {
    arbiter.appWillResignActive()
    fake.runHost()
    XCTAssertTrue(fake.paused)
    XCTAssertTrue(arbiter.coreWouldRun, "the game resumes on become-active, so a disconnect must still pause")
  }

  func test_coreWouldRun_whileQueuedResumeIsPending() {
    arbiter.appWillResignActive()
    fake.runHost()
    arbiter.appDidBecomeActive()
    XCTAssertTrue(fake.paused)
    XCTAssertTrue(arbiter.coreWouldRun)
  }

  func test_menuReleasedWhileInactive_disconnectStillPauses() {
    let menu = arbiter.claim(PauseArbiter.Reason.pauseMenu)
    arbiter.appWillResignActive()
    fake.runHost()
    arbiter.release(menu)
    runScheduled()
    XCTAssertTrue(fake.paused, "the inactive claim still holds")
    XCTAssertTrue(arbiter.coreWouldRun, "the menu's pause resumes on become-active, so a disconnect must claim")
    arbiter.claim(PauseArbiter.Reason.disconnect)
    arbiter.appDidBecomeActive()
    fake.runHost()
    runScheduled()
    XCTAssertTrue(fake.paused, "the disconnect keeps the game paused")
    arbiter.release(reason: PauseArbiter.Reason.disconnect)
    runScheduled()
    XCTAssertFalse(fake.paused)
  }

  func test_coreWouldRun_falseWhileMenuHoldsAcrossResign() {
    _ = arbiter.claim(PauseArbiter.Reason.pauseMenu)
    arbiter.appWillResignActive()
    fake.runHost()
    XCTAssertFalse(arbiter.coreWouldRun)
  }

  func test_coreWouldRun_falseForMenuOrExternalPause() {
    let menu = arbiter.claim(PauseArbiter.Reason.pauseMenu)
    XCTAssertFalse(arbiter.coreWouldRun)
    arbiter.release(menu)
    runScheduled()
    fake.paused = true
    XCTAssertFalse(arbiter.coreWouldRun, "a foreign pause keeps the game stopped anyway")
  }

  func test_disconnectWhileInactive_staysPausedOnReturn_andReconnectResumes() {
    arbiter.appWillResignActive()
    fake.runHost()
    if arbiter.coreWouldRun { arbiter.claim(PauseArbiter.Reason.disconnect) }
    arbiter.appDidBecomeActive()
    fake.runHost()
    runScheduled()
    XCTAssertTrue(fake.paused, "a pad that dropped while locked must leave the game paused")
    XCTAssertEqual(arbiter.holders, [PauseArbiter.Reason.disconnect])
    arbiter.release(reason: PauseArbiter.Reason.disconnect)
    runScheduled()
    XCTAssertFalse(fake.paused, "reconnecting resumes the pause the arbiter took over")
  }

  func test_disconnectRightAfterBecomeActive_cancelsTheQueuedResume() {
    arbiter.appWillResignActive()
    fake.runHost()
    arbiter.appDidBecomeActive()
    if arbiter.coreWouldRun { arbiter.claim(PauseArbiter.Reason.disconnect) }
    fake.runHost()
    runScheduled()
    XCTAssertTrue(fake.paused)
    arbiter.release(reason: PauseArbiter.Reason.disconnect)
    runScheduled()
    XCTAssertFalse(fake.paused)
  }
}
