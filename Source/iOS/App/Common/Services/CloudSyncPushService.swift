// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVCloudSync
import UIKit
#if canImport(CloudKit)
import CloudKit
#endif

/// Silent CloudKit pushes in, sync runs out.
///
/// Another device saving a record makes CloudKit send a content-available push. It
/// wakes iCube in the background, and the push becomes one run of the existing sync
/// path (`CloudSyncCoordinator.syncForRemoteChange()`). Every decision lives in
/// `CloudSyncPush.swift`; this is glue.
///
/// - No permission prompt: silent pushes need none, and none is shown.
/// - Builds without the `aps-environment` entitlement (every non-App Store config)
///   fail to register. That is logged and otherwise ignored; sync still runs on
///   foreground, as before.
/// - The push never applies data itself. While a game runs it only hands the trigger
///   to the lifecycle policy, which defers it until the core has drained.
@MainActor
final class CloudSyncPushService {
    static let shared = CloudSyncPushService()

    private var coalescer = CloudSyncPushCoalescer()
    private var handlers: [Int: (UIBackgroundFetchResult) -> Void] = [:]
    private var nextToken = 0
    /// The coordinator's counters when the current run started; nil between runs.
    private var runStartCounters: CloudSyncRemoteChangeCounters?

    // MARK: - Registration

    func register(_ application: UIApplication) {
        application.registerForRemoteNotifications()
    }

    func didFailToRegister(_ error: Error) {
        // Expected on builds signed without `aps-environment`.
        NSLog("iCloud sync: remote notifications unavailable: %@", error.localizedDescription)
    }

    // MARK: - Delivery

    func receive(_ userInfo: [AnyHashable: Any], completion: @escaping (UIBackgroundFetchResult) -> Void) {
        let coordinator = CloudSyncCoordinator.shared
        switch CloudSyncPushPolicy.decide(Self.notification(from: userInfo), subscription: .iCube,
                                          state: coordinator.pushState) {
        case .ignore, .syncOff:
            completion(.noData)

        case .deferUntilGameEnds:
            // The lifecycle policy records it as deferred work and runs it after the core drains.
            Task { await coordinator.handle(.trigger(.fileChanged)) }
            completion(.noData)

        case .fetch:
            let token = nextToken
            nextToken += 1
            handlers[token] = completion
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.nanoseconds(CloudSyncPushTiming.completionDeadline))
                self?.expire(token)
            }
            if coalescer.arrive(token) == .scheduleRun { scheduleRun() }
        }
    }

    private func scheduleRun() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.nanoseconds(CloudSyncPushTiming.coalescingWindow))
            await self?.run()
        }
    }

    private func run() async {
        guard coalescer.beginRun() else { return }
        let coordinator = CloudSyncCoordinator.shared
        let before = coordinator.remoteChangeCounters
        runStartCounters = before
        await coordinator.syncForRemoteChange()
        let result = CloudSyncPushResult.resolve(before: before, after: coordinator.remoteChangeCounters,
                                                 finished: true, unavailable: coordinator.unavailableReason != nil)
        runStartCounters = nil
        let finish = coalescer.finishRun()
        for token in finish.answered { handlers.removeValue(forKey: token)?(result.backgroundFetchResult) }
        if finish.runAgain { scheduleRun() }
    }

    /// The deadline passed before a run answered this push: report what has landed so far.
    private func expire(_ token: Int) {
        guard coalescer.expire(token), let handler = handlers.removeValue(forKey: token) else { return }
        let now = CloudSyncCoordinator.shared.remoteChangeCounters
        let result = CloudSyncPushResult.resolve(before: runStartCounters ?? now, after: now,
                                                 finished: false, unavailable: false)
        handler(result.backgroundFetchResult)
    }

    private static func notification(from userInfo: [AnyHashable: Any]) -> CloudSyncPushNotification? {
        #if canImport(CloudKit)
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return nil }
        return CloudSyncPushNotification(
            containerIdentifier: notification.containerIdentifier,
            subscriptionID: notification.subscriptionID,
            kind: notification.notificationType == .database ? .database : .other)
        #else
        return nil
        #endif
    }

    private static func nanoseconds(_ interval: TimeInterval) -> UInt64 {
        UInt64(interval * 1_000_000_000)
    }
}

private extension CloudSyncPushResult {
    var backgroundFetchResult: UIBackgroundFetchResult {
        switch self {
        case .newData: return .newData
        case .noData: return .noData
        case .failed: return .failed
        }
    }
}

/// Saves the private-database subscription once per account, and again after
/// `CloudSyncPushSubscription.revalidationInterval`.
@MainActor
final class CloudSyncPushSubscriber {
    static let shared = CloudSyncPushSubscriber()

    private static let markerKey = "icube.cloudSync.pushSubscription"
    private var isSaving = false

    /// The installed build and whether it is a Debug one, which is what decides the
    /// CloudKit environment (Development or Production) the subscription lives in.
    /// Any update saves the subscription once more, which is cheap.
    private static let installation: String = {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        #if DEBUG
        return build + "-debug"
        #else
        return build
        #endif
    }()

    /// Called from a sync run once CloudKit is known to work and the account is bound.
    func ensureSubscribed(accountIdentity: String?) {
        let subscription = CloudSyncPushSubscription.iCube
        guard !isSaving, let accountIdentity,
              subscription.needsSave(marker: Self.loadMarker(), accountIdentity: accountIdentity,
                                     installation: Self.installation, now: Date()) else { return }
        #if canImport(CloudKit)
        guard let container = CloudKitAvailability.makeContainer(for: ICubeCloudSync.configuration) else { return }
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            let ckSubscription = CKDatabaseSubscription(subscriptionID: subscription.subscriptionID)
            let info = CKSubscription.NotificationInfo()
            // Silent: no alert, badge or sound, so no notification permission is needed.
            info.shouldSendContentAvailable = true
            ckSubscription.notificationInfo = info
            do {
                _ = try await container.privateCloudDatabase.save(ckSubscription)
                Self.store(subscription.marker(accountIdentity: accountIdentity, installation: Self.installation, savedAt: Date()))
            } catch {
                // Not marked, so the next sync run tries again.
                NSLog("iCloud sync: could not save the change subscription: %@", error.localizedDescription)
            }
        }
        #endif
    }

    private static func loadMarker() -> CloudSyncPushSubscriptionMarker? {
        guard let data = UserDefaults.standard.data(forKey: markerKey) else { return nil }
        return try? JSONDecoder().decode(CloudSyncPushSubscriptionMarker.self, from: data)
    }

    private static func store(_ marker: CloudSyncPushSubscriptionMarker) {
        guard let data = try? JSONEncoder().encode(marker) else { return }
        UserDefaults.standard.set(data, forKey: markerKey)
    }
}
