// DolphiniOSTests/PauseArbiterTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// `PauseArbiter` against a fake core and a manual scheduler: the deferred resume runs only when the
/// test says so, which is what lets a release-then-claim within one transition be asserted.
@MainActor
final class PauseArbiterTests: XCTestCase {
  private final class FakeCore {
    var running = true
    var paused = false
    var pauseCalls = 0
    var resumeCalls = 0
    /// A core that is not Running yet ignores a pause.
    var refusePause = false
    var core: PauseArbiter.Core {
      PauseArbiter.Core(
        isRunning: { self.running }, isPaused: { self.paused },
        pause: { self.pauseCalls += 1; if !self.refusePause { self.paused = true } },
        resume: { self.resumeCalls += 1; self.paused = false })
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

  func test_firstClaimPauses_nestedClaimDoesNot() {
    let a = arbiter.claim("menu")
    XCTAssertEqual(fake.pauseCalls, 1)
    let b = arbiter.claim("saves")
    XCTAssertEqual(fake.pauseCalls, 1, "a nested claim must not pause again")
    XCTAssertEqual(arbiter.holders, ["menu", "saves"])
    arbiter.release(b)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 0, "an inner release keeps the game paused")
    arbiter.release(a)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1)
    XCTAssertFalse(arbiter.isHeld)
  }

  func test_outOfOrderRelease_resumesOnlyWhenEmpty() {
    let a = arbiter.claim("menu")
    let b = arbiter.claim("cheats")
    arbiter.release(a)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 0)
    arbiter.release(b)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  func test_doubleRelease_isNoOp() {
    let a = arbiter.claim("menu")
    arbiter.release(a)
    arbiter.release(a)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  func test_releaseThenClaimInSameTurn_doesNotResume() {
    let root = arbiter.claim("menu")
    arbiter.release(root)                 // SwiftUI onDisappear of the covered presenter
    _ = arbiter.claim("shaders")          // the cover's onAppear, same transition
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 0, "the deferred resume must re-check the token count")
    XCTAssertTrue(fake.paused)
  }

  func test_userPause_survivesMenuClose_andUserResumeClearsIt() {
    arbiter.claim("user")
    let menu = arbiter.claim("menu")
    arbiter.release(menu)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 0, "the bar pause outlives the menu")
    XCTAssertTrue(arbiter.isHeld)
    arbiter.userResume()
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1)
    XCTAssertFalse(arbiter.isHeld)
  }

  func test_releaseByReason_removesEveryTokenWithThatReason() {
    arbiter.claim("disconnect")
    arbiter.claim("disconnect")
    arbiter.release(reason: "disconnect")
    runScheduled()
    XCTAssertFalse(arbiter.isHeld)
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  func test_externalPause_isNotResumedByArbiter() {
    fake.paused = true                    // paused by the debug API, no token
    let a = arbiter.claim("menu")
    XCTAssertEqual(fake.pauseCalls, 0, "already paused: nothing to do")
    arbiter.release(a)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 0, "the arbiter never resumes a pause it did not make")
    XCTAssertTrue(fake.paused)
  }

  func test_resumeIfUnheld_resumesExternalPause_butNotAHeldOne() {
    fake.paused = true
    arbiter.resumeIfUnheld()
    XCTAssertEqual(fake.resumeCalls, 1)
    arbiter.claim("menu")
    arbiter.resumeIfUnheld()
    XCTAssertEqual(fake.resumeCalls, 1, "a held pause is not the pill's to resume")
  }

  func test_claimWhileNotRunning_isDeferredUntilStart() {
    fake.running = false
    let a = arbiter.claim("menu")
    XCTAssertEqual(fake.pauseCalls, 0)
    fake.running = true
    arbiter.emulationDidStart()
    XCTAssertEqual(fake.pauseCalls, 1)
    arbiter.release(a)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  func test_emulationDidStop_dropsAllTokens() {
    arbiter.claim("menu")
    arbiter.claim("user")
    arbiter.emulationDidStop()
    XCTAssertFalse(arbiter.isHeld)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 0, "a stopped core is never resumed")
  }

  func test_pendingClaim_isAdoptedOnce_andReplacedByTheNextPending() {
    arbiter.claimPending("pause-menu-request")
    XCTAssertEqual(fake.pauseCalls, 1)
    let adopted = arbiter.adoptPending()
    XCTAssertEqual(adopted?.reason, "pause-menu-request")
    XCTAssertNil(arbiter.adoptPending(), "adopt hands the token over exactly once")
    arbiter.claimPending("again")
    XCTAssertEqual(arbiter.holders, ["pause-menu-request"], "ignored while the adopted menu token is held")
    arbiter.release(adopted!)
    arbiter.claimPending("again")
    arbiter.claimPending("again-2")
    XCTAssertEqual(arbiter.holders, ["again-2"], "an unadopted pending claim is replaced, not leaked")
  }

  func test_userResume_releasesAnUnadoptedPendingToken() {
    arbiter.claimPending("pause-menu-request")
    XCTAssertTrue(arbiter.isHeld)
    arbiter.userResume()
    runScheduled()
    XCTAssertFalse(arbiter.isHeld)
    XCTAssertNil(arbiter.adoptPending())
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  func test_claimPending_isIgnoredWhileTheMenuHoldsAToken() {
    arbiter.claim("pause-menu")
    arbiter.claimPending("pause-menu-request")
    XCTAssertEqual(arbiter.holders, ["pause-menu"])
    XCTAssertNil(arbiter.adoptPending())
  }

  func test_claimWhileCoreRefusesToPause_isDeferred() {
    fake.refusePause = true
    let a = arbiter.claim("menu")
    XCTAssertEqual(fake.pauseCalls, 1)
    XCTAssertFalse(fake.paused)
    fake.refusePause = false              // the core reached Running
    arbiter.emulationDidStart()
    XCTAssertTrue(fake.paused)
    XCTAssertEqual(fake.pauseCalls, 2)
    arbiter.release(a)
    runScheduled()
    XCTAssertEqual(fake.resumeCalls, 1)
  }

  func test_claimWhileHeldButCoreRunning_rePauses() {
    let a = arbiter.claim("menu")
    fake.paused = false                   // something outside resumed under us
    _ = arbiter.claim("saves")
    XCTAssertEqual(fake.pauseCalls, 2, "every claim ensures a running core is paused")
    _ = a
  }
}
