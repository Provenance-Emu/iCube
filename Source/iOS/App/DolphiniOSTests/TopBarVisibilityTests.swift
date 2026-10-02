// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class TopBarVisibilityTests: XCTestCase {
  private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

  private func later(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

  func testStartsHiddenWithNoDeadline() {
    let bar = TopBarVisibility()
    XCTAssertFalse(bar.isVisible)
    XCTAssertNil(bar.deadline)
    XCTAssertFalse(bar.shouldHide(at: later(1000)))
  }

  func testShowArmsTheIdleCountdown() {
    var bar = TopBarVisibility()
    bar.show(now: t0)
    XCTAssertTrue(bar.isVisible)
    XCTAssertEqual(bar.deadline, later(TopBarVisibility.idleInterval))
  }

  func testHidesOnlyOnceTheIdleIntervalHasPassed() {
    var bar = TopBarVisibility()
    bar.show(now: t0)
    XCTAssertFalse(bar.shouldHide(at: later(TopBarVisibility.idleInterval - 0.1)))
    XCTAssertTrue(bar.shouldHide(at: later(TopBarVisibility.idleInterval)))
  }

  func testInteractionRestartsTheCountdown() {
    var bar = TopBarVisibility()
    bar.show(now: t0)
    bar.interaction(now: later(2))
    XCTAssertEqual(bar.deadline, later(2 + TopBarVisibility.idleInterval))
    XCTAssertFalse(bar.shouldHide(at: later(TopBarVisibility.idleInterval)))
    XCTAssertTrue(bar.shouldHide(at: later(2 + TopBarVisibility.idleInterval)))
  }

  func testInteractionOnAHiddenBarDoesNotRevealIt() {
    var bar = TopBarVisibility()
    bar.interaction(now: t0)
    XCTAssertFalse(bar.isVisible)
    XCTAssertNil(bar.deadline)
  }

  func testAnOpenMenuSuspendsHidingIndefinitely() {
    var bar = TopBarVisibility()
    bar.show(now: t0)
    bar.menuOpened("slot", now: later(1))
    XCTAssertNil(bar.deadline)
    XCTAssertFalse(bar.shouldHide(at: later(60 * 60)))
    XCTAssertTrue(bar.isVisible)
  }

  func testClosingTheMenuRestartsTheCountdownFromThen() {
    var bar = TopBarVisibility()
    bar.show(now: t0)
    bar.menuOpened("slot", now: later(1))
    bar.menuClosed("slot", now: later(30))
    XCTAssertEqual(bar.deadline, later(30 + TopBarVisibility.idleInterval))
    XCTAssertFalse(bar.shouldHide(at: later(30 + TopBarVisibility.idleInterval - 0.1)))
    XCTAssertTrue(bar.shouldHide(at: later(30 + TopBarVisibility.idleInterval)))
  }

  func testInteractionWhileAMenuIsOpenDoesNotRearmTheCountdown() {
    var bar = TopBarVisibility()
    bar.show(now: t0)
    bar.menuOpened("more", now: later(1))
    bar.interaction(now: later(2))
    XCTAssertNil(bar.deadline)
  }

  func testTheBarStaysUpUntilEveryOpenMenuIsClosed() {
    var bar = TopBarVisibility()
    bar.show(now: t0)
    bar.menuOpened("controller", now: later(1))
    bar.menuOpened("perf", now: later(2))
    bar.menuClosed("controller", now: later(3))
    XCTAssertNil(bar.deadline)
    XCTAssertFalse(bar.shouldHide(at: later(100)))
    bar.menuClosed("perf", now: later(4))
    XCTAssertEqual(bar.deadline, later(4 + TopBarVisibility.idleInterval))
  }

  func testOpeningTheSameMenuTwiceNeedsOnlyOneClose() {
    var bar = TopBarVisibility()
    bar.show(now: t0)
    bar.menuOpened("slot", now: later(1))
    bar.menuOpened("slot", now: later(2))
    bar.menuClosed("slot", now: later(3))
    XCTAssertNotNil(bar.deadline)
  }

  func testClosingAMenuThatWasNeverOpenedChangesNothing() {
    var bar = TopBarVisibility()
    bar.show(now: t0)
    bar.menuClosed("ghost", now: later(1))
    XCTAssertEqual(bar.deadline, later(TopBarVisibility.idleInterval))
  }

  func testHideNowHidesImmediatelyAndForgetsOpenMenus() {
    var bar = TopBarVisibility()
    bar.show(now: t0)
    bar.menuOpened("more", now: later(1))
    bar.hideNow()
    XCTAssertFalse(bar.isVisible)
    XCTAssertNil(bar.deadline)
    bar.show(now: later(10))
    XCTAssertEqual(bar.deadline, later(10 + TopBarVisibility.idleInterval), "a stale hold must not pin the bar open")
  }

  func testShowWhileAMenuIsOpenKeepsTheBarUp() {
    var bar = TopBarVisibility()
    bar.menuOpened("pause", now: t0)
    bar.show(now: later(1))
    XCTAssertTrue(bar.isVisible)
    XCTAssertNil(bar.deadline)
    bar.menuClosed("pause", now: later(5))
    XCTAssertEqual(bar.deadline, later(5 + TopBarVisibility.idleInterval))
  }

  func testClosingAMenuOnAHiddenBarDoesNotArmTheCountdown() {
    var bar = TopBarVisibility()
    bar.menuOpened("pause", now: t0)
    bar.menuClosed("pause", now: later(1))
    XCTAssertFalse(bar.isVisible)
    XCTAssertNil(bar.deadline)
  }

  func testIdleIntervalIsInTheThreeToFourSecondBand() {
    XCTAssertGreaterThanOrEqual(TopBarVisibility.idleInterval, 3)
    XCTAssertLessThanOrEqual(TopBarVisibility.idleInterval, 4)
  }
}
