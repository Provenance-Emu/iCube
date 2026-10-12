// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class CheatFetchPolicyTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  func test_neverFetched_fetches() {
    XCTAssertTrue(CheatAutoFetchPolicy.shouldFetch(gametdbId: "GALE01", lastFetch: nil, attemptedThisLaunch: false, now: now))
  }

  func test_recentFetch_skips() {
    let yesterday = now.addingTimeInterval(-24 * 60 * 60)
    XCTAssertFalse(CheatAutoFetchPolicy.shouldFetch(gametdbId: "GALE01", lastFetch: yesterday, attemptedThisLaunch: false, now: now))
  }

  func test_staleFetch_fetches() {
    let stale = now.addingTimeInterval(-CheatAutoFetchPolicy.staleAfter)
    XCTAssertTrue(CheatAutoFetchPolicy.shouldFetch(gametdbId: "GALE01", lastFetch: stale, attemptedThisLaunch: false, now: now))
  }

  func test_alreadyAttemptedThisLaunch_skips() {
    XCTAssertFalse(CheatAutoFetchPolicy.shouldFetch(gametdbId: "GALE01", lastFetch: nil, attemptedThisLaunch: true, now: now))
  }

  func test_noGametdbId_skips() {
    XCTAssertFalse(CheatAutoFetchPolicy.shouldFetch(gametdbId: "", lastFetch: nil, attemptedThisLaunch: false, now: now))
  }

  // MARK: Ledger

  private func makeLedger() -> (CheatFetchLedger, UserDefaults) {
    let suite = "CheatFetchPolicyTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    return (CheatFetchLedger(defaults: defaults), defaults)
  }

  func test_ledger_recordsAndReadsBack() {
    let (ledger, defaults) = makeLedger()
    XCTAssertNil(ledger.lastFetch(for: "GALE01"))
    ledger.recordFetch(for: "GALE01", at: now)
    XCTAssertEqual(ledger.lastFetch(for: "GALE01"), now)
    XCTAssertEqual(defaults.object(forKey: CheatFetchLedger.key(for: "GALE01")) as? Date, now)
    XCTAssertNil(ledger.lastFetch(for: "GM4E01"), "keyed per GameTDB id")
  }

  func test_ledger_shouldAutoFetch_combinesPolicyInputs() {
    let (ledger, _) = makeLedger()
    XCTAssertTrue(ledger.shouldAutoFetch(gametdbId: "GALE01", now: now))
    ledger.markAttempted("GALE01")
    XCTAssertFalse(ledger.shouldAutoFetch(gametdbId: "GALE01", now: now), "one attempt per launch, even after a failure")
    XCTAssertTrue(ledger.shouldAutoFetch(gametdbId: "GM4E01", now: now), "the attempt set is per game")

    let (fresh, _) = makeLedger()
    fresh.recordFetch(for: "GALE01", at: now.addingTimeInterval(-60))
    XCTAssertFalse(fresh.shouldAutoFetch(gametdbId: "GALE01", now: now))
    XCTAssertTrue(fresh.shouldAutoFetch(gametdbId: "GALE01", now: now.addingTimeInterval(CheatAutoFetchPolicy.staleAfter + 60)))
  }
}
