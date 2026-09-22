// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What went wrong, reduced to the facts the retry decision actually needs.
///
/// A plain struct rather than a `CKError` so the policy is testable without
/// CloudKit and without synthesising server errors. The CloudKit layer maps into
/// this (see `SyncRetryFacts.init(ckError:)` in `CloudKitErrorMapping.swift`).
public struct SyncRetryFacts: Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable {
        /// CloudKit is throttling us. `retryAfterSeconds` is authoritative.
        case rateLimited
        /// Server-side transient: service unavailable, zone busy.
        case serviceTransient
        /// Connectivity. Worth retrying, but not worth many attempts.
        case network
        /// The record changed underneath us — the caller must re-read and merge,
        /// not blindly retry the same write.
        case recordChanged
        /// No point trying again: not signed in, out of quota, asset gone,
        /// permission denied, bad request.
        case permanent
        case unknown
    }

    public var kind: Kind
    /// `CKErrorRetryAfterKey`, when the server supplied one.
    public var retryAfterSeconds: Double?

    public init(kind: Kind, retryAfterSeconds: Double? = nil) {
        self.kind = kind
        self.retryAfterSeconds = retryAfterSeconds
    }
}

public enum SyncRetryDecision: Sendable, Equatable {
    case retry(afterSeconds: Double)
    case giveUp
}

/// How long to wait before trying a failed CloudKit operation again.
///
/// This is where iCube deliberately improves on iFly, which has generic
/// exponential backoff over three attempts and **never reads
/// `CKErrorRetryAfterKey`** and **never special-cases
/// `CKError.requestRateLimited`**. Both matter: when CloudKit throttles a client
/// it says how long to wait, and retrying sooner than that earns a longer
/// throttle. Honouring the server's number is strictly better than guessing, and
/// it is the difference between a sync that recovers in one interval and one
/// that spends the session being rate-limited harder.
///
/// Rules:
/// - A server-supplied `retryAfterSeconds` **always wins** over the computed
///   backoff, for every retryable kind, clamped only by `maximumServerDelay` so
///   a nonsense value cannot wedge the engine for an hour.
/// - Rate limiting and server-transient errors get the full attempt budget.
/// - Network errors get a shorter budget — offline is better handled by the next
///   trigger than by sitting in a retry loop.
/// - `recordChanged` and `permanent` never retry. `recordChanged` needs a
///   re-read, which is the caller's job, not a sleep.
public struct SyncRetryPolicy: Sendable, Equatable {

    public let baseDelay: TimeInterval
    public let maximumAttempts: Int
    /// Ceiling on the *computed* exponential delay.
    public let maximumComputedDelay: TimeInterval
    /// Ceiling on a *server-supplied* delay. Higher than the computed ceiling
    /// because a throttle we were explicitly told about is worth waiting out.
    public let maximumServerDelay: TimeInterval
    /// Attempt budget for connectivity failures.
    public let maximumNetworkAttempts: Int

    public init(
        baseDelay: TimeInterval = 2.0,
        maximumAttempts: Int = 5,
        maximumComputedDelay: TimeInterval = 60,
        maximumServerDelay: TimeInterval = 120,
        maximumNetworkAttempts: Int = 2
    ) {
        self.baseDelay = baseDelay
        self.maximumAttempts = maximumAttempts
        self.maximumComputedDelay = maximumComputedDelay
        self.maximumServerDelay = maximumServerDelay
        self.maximumNetworkAttempts = maximumNetworkAttempts
    }

    /// - Parameter attempt: 1 for the first failure, 2 for the second, and so on.
    public func decide(facts: SyncRetryFacts, attempt: Int) -> SyncRetryDecision {
        guard attempt >= 1 else { return .giveUp }

        switch facts.kind {
        case .permanent, .recordChanged:
            return .giveUp

        case .rateLimited, .serviceTransient:
            guard attempt < maximumAttempts else { return .giveUp }
            return .retry(afterSeconds: delay(facts: facts, attempt: attempt))

        case .network:
            guard attempt < maximumNetworkAttempts else { return .giveUp }
            return .retry(afterSeconds: delay(facts: facts, attempt: attempt))

        case .unknown:
            // One cautious retry: a genuinely unknown failure is as likely to be
            // a blip as a bug, but looping on it hides the bug.
            guard attempt < 2 else { return .giveUp }
            return .retry(afterSeconds: delay(facts: facts, attempt: attempt))
        }
    }

    /// The server's number if there is one, otherwise exponential backoff.
    private func delay(facts: SyncRetryFacts, attempt: Int) -> TimeInterval {
        if let serverDelay = facts.retryAfterSeconds, serverDelay > 0 {
            return min(serverDelay, maximumServerDelay)
        }
        let exponential = baseDelay * pow(2.0, Double(attempt - 1))
        return min(exponential, maximumComputedDelay)
    }
}
