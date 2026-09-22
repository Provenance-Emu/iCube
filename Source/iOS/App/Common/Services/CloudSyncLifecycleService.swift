// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVCloudSync
import UIKit

/// Feeds app and emulation lifecycle into `CloudSyncCoordinator`.
///
/// Same shape as WS-3's `WebServerLifecycleService`: a thin
/// `UIApplicationDelegate` registered in `ServiceManager.services`, whose
/// `applicationDidBecomeActive` / `applicationDidEnterBackground` are invoked
/// from every scene's callbacks in `MainDisplaySceneDelegate` — including at
/// cold launch, so sync runs on a fresh install that never opens Settings.
///
/// Emulation gating uses `DOLEmulationWillStartNotification` /
/// `DOLEmulationDidEndNotification`, already posted by `EmulationCoordinator`
/// and already used for exactly this purpose by the web server. Dolphin holds
/// save states, memory cards and the Wii NAND open while a game runs; syncing
/// underneath it is how a save gets corrupted. The coordinator's policy defers
/// that work and flushes it on stop.
final class CloudSyncLifecycleService: NSObject, UIApplicationDelegate {

    private var observers: [NSObjectProtocol] = []

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        installObserversIfNeeded()
        Task { @MainActor in
            await CloudSyncCoordinator.shared.start()
        }
        return true
    }

    /// Pull remote changes down when we come back to the foreground.
    func applicationDidBecomeActive(_ application: UIApplication) {
        send(.trigger(.appForegrounded))
    }

    /// Push local changes up on the way out. Best-effort: no background task
    /// assertion is taken, so a long upload may not finish. The next foreground
    /// trigger catches whatever did not.
    func applicationDidEnterBackground(_ application: UIApplication) {
        send(.trigger(.appBackgrounded))
    }

    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: Notification.Name("DOLEmulationWillStartNotification"),
                object: nil, queue: .main
            ) { [weak self] _ in self?.send(.emulationWillStart) },
            center.addObserver(
                forName: Notification.Name("DOLEmulationDidEndNotification"),
                object: nil, queue: .main
            ) { [weak self] _ in self?.send(.emulationDidEnd) }
        ]
    }

    private func send(_ event: SyncLifecycleEvent) {
        Task { @MainActor in
            await CloudSyncCoordinator.shared.handle(event)
        }
    }
}
