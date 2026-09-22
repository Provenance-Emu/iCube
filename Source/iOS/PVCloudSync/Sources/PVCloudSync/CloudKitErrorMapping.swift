// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if canImport(CloudKit)
import CloudKit

extension SyncRetryFacts {

    /// Reduce a `CKError` to the facts the retry policy needs.
    ///
    /// Two things iFly never does, both done here:
    ///
    /// - **`requestRateLimited` is classified explicitly.** iFly lumps it into
    ///   "retry with exponential backoff", which retries sooner than CloudKit
    ///   asked and earns a longer throttle.
    /// - **`CKErrorRetryAfterKey` is read.** CloudKit supplies it on
    ///   `requestRateLimited`, `serviceUnavailable` and `zoneBusy`, and it is
    ///   authoritative. It lives in `userInfo`, not on a typed property, and —
    ///   critically — on a `partialFailure` it is on the **inner** per-item
    ///   errors, not the outer one. `bestRetryAfter(from:)` below unwraps that.
    public init(ckError: CKError) {
        self.init(
            kind: SyncRetryFacts.classify(ckError),
            retryAfterSeconds: SyncRetryFacts.bestRetryAfter(from: ckError)
        )
    }

    /// Facts for any error, CloudKit or not.
    public init(error: Error) {
        if let ckError = error as? CKError {
            self.init(ckError: ckError)
        } else {
            self.init(kind: .unknown, retryAfterSeconds: nil)
        }
    }

    private static func classify(_ error: CKError) -> Kind {
        switch error.code {
        case .requestRateLimited:
            return .rateLimited

        case .serviceUnavailable, .zoneBusy:
            return .serviceTransient

        case .networkUnavailable, .networkFailure:
            return .network

        case .serverRecordChanged:
            // Needs a re-read and a merge, not a sleep and the same write again.
            return .recordChanged

        case .notAuthenticated, .quotaExceeded, .permissionFailure,
             .managedAccountRestricted, .badContainer, .badDatabase,
             .invalidArguments, .assetFileNotFound, .assetFileModified,
             .constraintViolation, .referenceViolation, .unknownItem,
             .incompatibleVersion, .serverRejectedRequest, .limitExceeded:
            return .permanent

        case .partialFailure:
            // The outer error is a container. The kind that matters is the worst
            // of the inner ones; if any inner error is retryable, so is the batch.
            return worstInnerKind(of: error) ?? .permanent

        default:
            return .unknown
        }
    }

    /// Most-retryable inner kind of a `partialFailure`, or nil when there are no
    /// inner errors.
    private static func worstInnerKind(of error: CKError) -> Kind? {
        guard let partial = error.partialErrorsByItemID, !partial.isEmpty else { return nil }
        var kinds: [Kind] = []
        for case let inner as CKError in partial.values {
            kinds.append(classify(inner))
        }
        guard !kinds.isEmpty else { return nil }
        // Retryable beats non-retryable: a batch where one item was throttled
        // should be retried, not abandoned.
        if kinds.contains(.rateLimited) { return .rateLimited }
        if kinds.contains(.serviceTransient) { return .serviceTransient }
        if kinds.contains(.network) { return .network }
        if kinds.contains(.recordChanged) { return .recordChanged }
        if kinds.contains(.unknown) { return .unknown }
        return .permanent
    }

    /// Largest `CKErrorRetryAfterKey` anywhere in this error, outer or inner.
    ///
    /// The largest rather than the first: if CloudKit told us to wait 30 s for
    /// one item and 2 s for another, waiting 2 s gets the first one throttled
    /// again.
    static func bestRetryAfter(from error: CKError) -> Double? {
        var candidates: [Double] = []
        if let outer = error.retryAfterSeconds, outer > 0 {
            candidates.append(outer)
        }
        if let partial = error.partialErrorsByItemID {
            for case let inner as CKError in partial.values {
                if let value = inner.retryAfterSeconds, value > 0 {
                    candidates.append(value)
                }
            }
        }
        return candidates.max()
    }
}

extension SyncUnavailableReason {
    /// Map an account-status / operation failure onto a reason the settings pane
    /// can show.
    public init(ckError: CKError) {
        switch ckError.code {
        case .notAuthenticated: self = .notSignedIn
        case .managedAccountRestricted, .permissionFailure: self = .accountRestricted
        case .serviceUnavailable, .zoneBusy, .requestRateLimited: self = .accountTemporarilyUnavailable
        case .networkUnavailable, .networkFailure: self = .networkUnavailable
        default: self = .unknown(ckError.localizedDescription)
        }
    }

    /// Map a `CKAccountStatus`. Returns `nil` when the account is usable.
    public static func forAccountStatus(_ status: CKAccountStatus) -> SyncUnavailableReason? {
        switch status {
        case .available: return nil
        case .noAccount: return .notSignedIn
        case .restricted: return .accountRestricted
        case .temporarilyUnavailable: return .accountTemporarilyUnavailable
        case .couldNotDetermine: return .unknown("Could not determine iCloud account status.")
        @unknown default: return .unknown("Unrecognised iCloud account status.")
        }
    }
}
#endif
