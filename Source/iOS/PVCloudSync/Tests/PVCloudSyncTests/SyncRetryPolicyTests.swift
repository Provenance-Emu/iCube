// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import PVCloudSync

/// The failure handling iFly does not have: an explicit rate-limit case and an
/// honoured `retryAfterSeconds`.
final class SyncRetryPolicyTests: XCTestCase {

    private let policy = SyncRetryPolicy()

    // MARK: - Server-supplied delay wins

    func testRateLimitHonoursServerRetryAfterInsteadOfBackoff() {
        let facts = SyncRetryFacts(kind: .rateLimited, retryAfterSeconds: 37)
        XCTAssertEqual(policy.decide(facts: facts, attempt: 1), .retry(afterSeconds: 37))
        // Even on a later attempt the server's number wins over the exponential.
        XCTAssertEqual(policy.decide(facts: facts, attempt: 3), .retry(afterSeconds: 37))
    }

    func testServerRetryAfterIsClampedSoANonsenseValueCannotWedgeSync() {
        let facts = SyncRetryFacts(kind: .rateLimited, retryAfterSeconds: 9999)
        XCTAssertEqual(policy.decide(facts: facts, attempt: 1),
                       .retry(afterSeconds: policy.maximumServerDelay))
    }

    func testNonPositiveServerRetryAfterFallsBackToBackoff() {
        let facts = SyncRetryFacts(kind: .rateLimited, retryAfterSeconds: 0)
        XCTAssertEqual(policy.decide(facts: facts, attempt: 1), .retry(afterSeconds: 2))
    }

    // MARK: - Backoff shape

    func testRateLimitWithoutServerHintUsesExponentialBackoff() {
        let facts = SyncRetryFacts(kind: .rateLimited)
        XCTAssertEqual(policy.decide(facts: facts, attempt: 1), .retry(afterSeconds: 2))
        XCTAssertEqual(policy.decide(facts: facts, attempt: 2), .retry(afterSeconds: 4))
        XCTAssertEqual(policy.decide(facts: facts, attempt: 3), .retry(afterSeconds: 8))
        XCTAssertEqual(policy.decide(facts: facts, attempt: 4), .retry(afterSeconds: 16))
    }

    func testComputedBackoffIsCapped() {
        let tight = SyncRetryPolicy(baseDelay: 2, maximumAttempts: 20, maximumComputedDelay: 10)
        XCTAssertEqual(tight.decide(facts: SyncRetryFacts(kind: .serviceTransient), attempt: 6),
                       .retry(afterSeconds: 10))
    }

    // MARK: - Attempt budgets

    func testRateLimitGivesUpAfterTheAttemptBudget() {
        let facts = SyncRetryFacts(kind: .rateLimited, retryAfterSeconds: 5)
        XCTAssertEqual(policy.decide(facts: facts, attempt: 4), .retry(afterSeconds: 5))
        XCTAssertEqual(policy.decide(facts: facts, attempt: 5), .giveUp)
    }

    func testNetworkFailuresGetAShorterBudgetThanThrottling() {
        let network = SyncRetryFacts(kind: .network)
        XCTAssertEqual(policy.decide(facts: network, attempt: 1), .retry(afterSeconds: 2))
        XCTAssertEqual(policy.decide(facts: network, attempt: 2), .giveUp)
    }

    func testUnknownFailuresRetryExactlyOnce() {
        let unknown = SyncRetryFacts(kind: .unknown)
        XCTAssertEqual(policy.decide(facts: unknown, attempt: 1), .retry(afterSeconds: 2))
        XCTAssertEqual(policy.decide(facts: unknown, attempt: 2), .giveUp)
    }

    // MARK: - Never retried

    func testPermanentFailuresNeverRetry() {
        XCTAssertEqual(policy.decide(facts: SyncRetryFacts(kind: .permanent), attempt: 1), .giveUp)
        // Not even when the server attached a retry hint.
        XCTAssertEqual(
            policy.decide(facts: SyncRetryFacts(kind: .permanent, retryAfterSeconds: 5), attempt: 1),
            .giveUp
        )
    }

    /// `serverRecordChanged` needs a re-read and a merge, not a sleep and the
    /// same write again.
    func testRecordChangedNeverRetries() {
        XCTAssertEqual(policy.decide(facts: SyncRetryFacts(kind: .recordChanged), attempt: 1), .giveUp)
    }

    func testAttemptZeroIsRejected() {
        XCTAssertEqual(policy.decide(facts: SyncRetryFacts(kind: .rateLimited), attempt: 0), .giveUp)
    }
}
