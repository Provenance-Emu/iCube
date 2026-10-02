// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// The popover-to-sheet sequencing: a destination chosen in a popover is held back until the popover has
/// gone, and the bar stays held up across the whole hand-off.
final class TopBarHandoffTests: XCTestCase {
  private let t0 = Date(timeIntervalSinceReferenceDate: 5000)

  private func later(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

  func testARequestIsNotPresentedUntilTaken() {
    var handoff = TopBarHandoff<String>()
    XCTAssertFalse(handoff.isPending)
    handoff.request("shaders")
    XCTAssertTrue(handoff.isPending)
    XCTAssertEqual(handoff.pending, "shaders")
  }

  func testTakeHandsOverTheDestinationExactlyOnce() {
    var handoff = TopBarHandoff<String>()
    handoff.request("shaders")
    XCTAssertEqual(handoff.take(), "shaders")
    XCTAssertNil(handoff.take())
    XCTAssertFalse(handoff.isPending)
  }

  func testTakeWithNothingPendingIsNil() {
    var handoff = TopBarHandoff<String>()
    XCTAssertNil(handoff.take())
  }

  func testALaterRequestReplacesAnEarlierOne() {
    var handoff = TopBarHandoff<String>()
    handoff.request("shaders")
    handoff.request("fx")
    XCTAssertEqual(handoff.take(), "fx")
  }

  /// Walks the exact order the bar performs and checks the countdown can never run out in between.
  func testTheBarIsHeldUpAcrossThePopoverToSheetHandoff() {
    let farFuture = later(60 * 60)
    let hold = TopBarHandoff<String>.holdID
    var bar = TopBarVisibility()
    var handoff = TopBarHandoff<String>()
    bar.show(now: t0)

    bar.menuOpened("display", now: later(1))
    XCTAssertFalse(bar.shouldHide(at: farFuture), "popover open")

    // Choosing a row: take the hand-off hold, record the request, then the popover goes.
    bar.menuOpened(hold, now: later(2))
    handoff.request("shaders")
    bar.menuClosed("display", now: later(2))
    XCTAssertFalse(bar.shouldHide(at: farFuture), "popover released, hand-off holding")
    XCTAssertTrue(handoff.isPending, "nothing presented yet")

    // The popover reports it is gone: the destination is requested and its own hold takes over...
    XCTAssertEqual(handoff.take(), "shaders")
    bar.menuOpened("childPresentation", now: later(3))
    // ...and only then does the hand-off hold let go.
    bar.menuClosed(hold, now: later(3.2))
    XCTAssertFalse(bar.shouldHide(at: farFuture), "child holding")

    bar.menuClosed("childPresentation", now: later(10))
    XCTAssertFalse(bar.shouldHide(at: later(10 + TopBarVisibility.idleInterval - 0.1)))
    XCTAssertTrue(bar.shouldHide(at: later(10 + TopBarVisibility.idleInterval)))
  }

  func testAHandoffThatNeverPresentsStillReleasesAndCountsDown() {
    let hold = TopBarHandoff<String>.holdID
    var bar = TopBarVisibility()
    bar.show(now: t0)
    bar.menuOpened(hold, now: later(1))
    XCTAssertFalse(bar.shouldHide(at: later(600)))
    bar.menuClosed(hold, now: later(1 + TopBarTiming.handoffGrace))
    XCTAssertTrue(bar.shouldHide(at: later(1 + TopBarTiming.handoffGrace + TopBarVisibility.idleInterval)))
  }

  func testToggleRefreshFiresWhenAChildCloses() {
    XCTAssertTrue(TopBarToggleRefresh.shouldRefresh(childWasPresented: true, childIsPresented: false))
    XCTAssertFalse(TopBarToggleRefresh.shouldRefresh(childWasPresented: false, childIsPresented: true))
    XCTAssertFalse(TopBarToggleRefresh.shouldRefresh(childWasPresented: true, childIsPresented: true))
    XCTAssertFalse(TopBarToggleRefresh.shouldRefresh(childWasPresented: false, childIsPresented: false))
  }

  func testNanosecondsConversion() {
    XCTAssertEqual(TopBarTiming.nanoseconds(1), 1_000_000_000)
    XCTAssertEqual(TopBarTiming.nanoseconds(0.5), 500_000_000)
    XCTAssertEqual(TopBarTiming.nanoseconds(-3), 0)
  }

  func testToastFollowsTheBarsRealHeight() {
    let oneRow = EmulationToastOverlay.topOffset(barHeight: 64, barVisible: true)
    let twoRows = EmulationToastOverlay.topOffset(barHeight: 108, barVisible: true)
    XCTAssertEqual(oneRow, 64 + EmulationToastOverlay.gapBelowBar)
    XCTAssertEqual(twoRows, 108 + EmulationToastOverlay.gapBelowBar)
  }

  func testToastRestsAtTheTopWhenTheBarIsHiddenOrNotMeasuredYet() {
    XCTAssertEqual(EmulationToastOverlay.topOffset(barHeight: 108, barVisible: false), EmulationToastOverlay.restingTopOffset)
    XCTAssertEqual(EmulationToastOverlay.topOffset(barHeight: 0, barVisible: true), EmulationToastOverlay.restingTopOffset)
  }

  func testASurfaceThatPausedTheGameResumesIt() {
    var paused = false
    let owned = PauseOwnership.claim(isPaused: false, pausedFromBar: false, pause: { paused = true })
    XCTAssertTrue(owned)
    XCTAssertTrue(paused)
  }

  func testAPauseTheUserMadeFromTheBarIsNotResumedByTheSurface() {
    var paused = false
    var resumed = 0
    let owned = PauseOwnership.claim(isPaused: true, pausedFromBar: true, pause: { paused = true })
    XCTAssertFalse(owned)
    XCTAssertFalse(paused)
    PauseOwnership.release(owned: owned, resume: { resumed += 1 })
    XCTAssertEqual(resumed, 0)
  }

  func testSomeOtherPauseIsResumedOnCloseAsBefore() {
    var resumed = 0
    let owned = PauseOwnership.claim(isPaused: true, pausedFromBar: false, pause: {})
    XCTAssertTrue(owned)
    PauseOwnership.release(owned: owned, resume: { resumed += 1 })
    XCTAssertEqual(resumed, 1)
  }
}
