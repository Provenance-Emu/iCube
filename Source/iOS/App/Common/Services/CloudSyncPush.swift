// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

// The decisions behind silent CloudKit pushes, with no CloudKit, UIKit or clock in
// them. `CloudSyncPushService` is the glue that feeds these and carries out the answer.
//
// A push only asks for a run of the existing sync path
// (`CloudSyncCoordinator.syncForRemoteChange()`). Nothing here applies remote data:
// the planner, the conflict rules and the emulation gate decide that, as they do for
// every other trigger.

/// The parts of a CloudKit push this app looks at, lifted out of `CKNotification`.
struct CloudSyncPushNotification: Equatable {
    enum Kind: Equatable {
        /// A `CKDatabaseSubscription` fired.
        case database
        /// Any other CloudKit notification (query, zone, read).
        case other
    }

    var containerIdentifier: String?
    var subscriptionID: String?
    var kind: Kind
}

/// The one subscription iCube keeps: every change in its private database.
///
/// A database subscription rather than a zone one, because it does not need the zone
/// to exist when it is saved and it survives the zone being deleted and recreated.
struct CloudSyncPushSubscription: Equatable {
    let containerIdentifier: String
    let subscriptionID: String
    /// Bump when the subscription's shape changes, so existing installs save the new one.
    let version: Int

    static let iCube = CloudSyncPushSubscription(
        containerIdentifier: ICubeCloudSync.configuration.containerIdentifier,
        subscriptionID: "icube-private-database-changes",
        version: 1
    )

    /// Saving again after this long repairs a subscription the server dropped, for
    /// example when the user deleted iCube's data from iCloud settings.
    static let revalidationInterval: TimeInterval = 7 * 24 * 60 * 60

    func isOurs(_ notification: CloudSyncPushNotification) -> Bool {
        notification.kind == .database &&
            notification.subscriptionID == subscriptionID &&
            notification.containerIdentifier == containerIdentifier
    }

    /// Whether the subscription has to be saved for this account. Without an account
    /// there is no private database to subscribe to, so the answer is no.
    func needsSave(marker: CloudSyncPushSubscriptionMarker?, accountIdentity: String?, now: Date) -> Bool {
        guard let accountIdentity, !accountIdentity.isEmpty else { return false }
        guard let marker else { return true }
        guard marker.containerIdentifier == containerIdentifier,
              marker.subscriptionID == subscriptionID,
              marker.version == version,
              marker.accountIdentity == accountIdentity else { return true }
        // A clock set backwards makes the marker look like it came from the future; save again.
        let age = now.timeIntervalSince(marker.savedAt)
        return age < 0 || age >= Self.revalidationInterval
    }

    func marker(accountIdentity: String, savedAt: Date) -> CloudSyncPushSubscriptionMarker {
        CloudSyncPushSubscriptionMarker(containerIdentifier: containerIdentifier, subscriptionID: subscriptionID,
                                        version: version, accountIdentity: accountIdentity, savedAt: savedAt)
    }
}

/// Written after the server accepted the subscription, so it is not saved again at
/// every launch. Bound to the iCloud account: subscriptions belong to one account's
/// private database.
struct CloudSyncPushSubscriptionMarker: Codable, Equatable {
    var containerIdentifier: String
    var subscriptionID: String
    var version: Int
    var accountIdentity: String
    var savedAt: Date
}

/// What the coordinator reports when a push arrives.
struct CloudSyncPushState: Equatable {
    var isSyncEnabled: Bool
    /// False when this install cannot use CloudKit at all (sideload, simulator).
    var isInstallAvailable: Bool
    /// A game is booting, running or draining: its files must not be touched.
    var isEmulating: Bool
}

enum CloudSyncPushDecision: Equatable {
    /// Not one of ours, or not CloudKit at all.
    case ignore
    /// Ours, but sync is off or cannot run on this install.
    case syncOff
    /// A game holds the files. The trigger is handed to the lifecycle policy, which
    /// remembers it and runs it once the core has drained; the push fetches nothing.
    case deferUntilGameEnds
    /// Run the sync path now.
    case fetch
}

enum CloudSyncPushPolicy {
    static func decide(_ notification: CloudSyncPushNotification?,
                       subscription: CloudSyncPushSubscription,
                       state: CloudSyncPushState) -> CloudSyncPushDecision {
        guard let notification, subscription.isOurs(notification) else { return .ignore }
        guard state.isSyncEnabled, state.isInstallAvailable else { return .syncOff }
        guard !state.isEmulating else { return .deferUntilGameEnds }
        return .fetch
    }
}

/// Process-lifetime counts the coordinator keeps, so a push can say what its run did.
struct CloudSyncRemoteChangeCounters: Equatable {
    /// Files written, merged or moved to Recently Deleted because of a remote change.
    var appliedFromRemote = 0
    /// Transfers or runs that failed.
    var failures = 0
}

/// The answer a push's completion handler gets. Mapped to `UIBackgroundFetchResult`.
enum CloudSyncPushResult: Equatable {
    case newData
    case noData
    case failed

    /// - Parameters:
    ///   - finished: false when the deadline passed before the run ended.
    ///   - unavailable: the run ended because iCloud could not be used.
    static func resolve(before: CloudSyncRemoteChangeCounters,
                        after: CloudSyncRemoteChangeCounters,
                        finished: Bool,
                        unavailable: Bool) -> CloudSyncPushResult {
        // Data that landed is reported even when something else failed or time ran out.
        if after.appliedFromRemote > before.appliedFromRemote { return .newData }
        if !finished || unavailable || after.failures > before.failures { return .failed }
        return .noData
    }
}

enum CloudSyncPushTiming {
    /// Pushes this close together share one run. CloudKit sends one per saved record,
    /// so a device uploading ten saves produces ten pushes in a few seconds.
    static let coalescingWindow: TimeInterval = 2
    /// The system gives a silent push about 30 seconds; answer before that.
    static let completionDeadline: TimeInterval = 25
}

/// One run per burst of pushes.
///
/// Every push delivers a completion handler that must be called exactly once. Each is
/// a token here, answered either by the run that covers it or by its own deadline.
/// Pushes that arrive while a run is going wait for one more run, because the run in
/// progress may already have read the zone before their change landed.
struct CloudSyncPushCoalescer: Equatable {
    enum Phase: Equatable {
        case idle
        /// Waiting out the coalescing window before the next run.
        case collecting
        case running
    }

    enum Arrival: Equatable {
        /// Start the coalescing window, then call `beginRun()`.
        case scheduleRun
        /// Another push already scheduled or started a run; this one rides along.
        case joined
    }

    private(set) var phase: Phase = .idle
    /// Tokens the next run will answer.
    private(set) var queued: [Int] = []
    /// Tokens the current run will answer.
    private(set) var running: [Int] = []

    mutating func arrive(_ token: Int) -> Arrival {
        queued.append(token)
        guard phase == .idle else { return .joined }
        phase = .collecting
        return .scheduleRun
    }

    /// The coalescing window closed. Returns false when there is nothing to start.
    mutating func beginRun() -> Bool {
        guard phase == .collecting else { return false }
        running = queued
        queued = []
        phase = .running
        return true
    }

    /// The run ended. Returns the tokens it answers and whether pushes that arrived
    /// during it need another run (scheduled through the window again).
    mutating func finishRun() -> (answered: [Int], runAgain: Bool) {
        guard phase == .running else { return ([], false) }
        let answered = running
        running = []
        if queued.isEmpty {
            phase = .idle
            return (answered, false)
        }
        phase = .collecting
        return (answered, true)
    }

    /// A token's deadline passed. Returns true when it was still waiting, in which case
    /// the caller answers it now and the run that would have covered it will not.
    mutating func expire(_ token: Int) -> Bool {
        if let index = queued.firstIndex(of: token) {
            queued.remove(at: index)
            return true
        }
        if let index = running.firstIndex(of: token) {
            running.remove(at: index)
            return true
        }
        return false
    }
}
