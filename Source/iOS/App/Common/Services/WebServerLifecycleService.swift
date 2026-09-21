// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVWebServer
import UIKit

/// Single lifecycle owner for the WebDAV/HTTP upload server (`PVWebServer`).
///
/// WS-3: before this, nobody owned start/stop. iOS started the server only from
/// `SettingsRootView`'s `.task` (never if the user never opened Settings), tvOS
/// started it from `TVRootView`'s `.onAppear`, and `PVWebServer.shared.stopServers()`
/// was never called by the app at all. Both start sites now route through here, and
/// the actual decision logic lives in `WebServerLifecyclePolicy` (PVWebServer module,
/// unit-tested independent of UIKit) — this class is just the thin NotificationCenter/
/// UIApplicationDelegate glue that feeds it events and applies its answer.
///
/// Registered in `ServiceManager.services`, whose `applicationDidBecomeActive` /
/// `applicationDidEnterBackground` are invoked from every scene's lifecycle callbacks
/// in `MainDisplaySceneDelegate` (unconditionally, on both iOS and tvOS) — including at
/// cold launch, which is what makes the server reachable on a fresh install that never
/// opens Settings.
///
/// Emulation pause/resume: gated on `DOLEmulationWillStartNotification` /
/// `DOLEmulationDidEndNotification` (already posted by `EmulationCoordinator`). iCube
/// has no live-stats page or continuity consumer today (that's WS-4, not yet built) that
/// would need the server reachable mid-game, so — unlike keeping it always on — pausing
/// removes a real, if narrow, I/O contention risk for free: Dolphin streams large
/// ISO/WBFS/RVZ images from the same storage volume a simultaneous multi-GB WebDAV/HTTP
/// upload would be writing to. The one exception is an upload already in flight when a
/// game starts (`WebServerLifecyclePolicy.uploadsInFlight`), so booting a game a moment
/// after starting a transfer never truncates it.
///
/// Known limitations (WS-3, not fixed here — narrow enough to defer):
/// - `startServers()` binds its `NWListener` asynchronously. If a game is launched fast
///   enough that the bind is still in flight when `emulationWillStart` fires, `isRunning`
///   reads false, so the pause is skipped and the server ends up running for that whole
///   session once the bind completes. Not a regression (the server always ran during
///   gameplay before this task); just not a airtight pause.
/// - The in-game pause menu's Settings screen (`SettingsRootView` with `isPauseMenuStyle`)
///   shows the upload URL. While a game is paused, this service has stopped the server, so
///   that row now reads blank instead of a working URL — previously it force-started the
///   server itself. No error is surfaced explaining why.
final class WebServerLifecycleService: NSObject, UIApplicationDelegate {
    private let lock = NSLock()
    private var policy = WebServerLifecyclePolicy()
    private var observers: [NSObjectProtocol] = []

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        installObserversIfNeeded()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        apply(.appForegrounded)
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        apply(.appBackgrounded)
    }

    private func installObserversIfNeeded() {
        lock.lock()
        guard observers.isEmpty else { lock.unlock(); return }
        lock.unlock()

        let center = NotificationCenter.default
        let tokens: [NSObjectProtocol] = [
            center.addObserver(
                forName: Notification.Name("DOLEmulationWillStartNotification"),
                object: nil, queue: .main
            ) { [weak self] _ in self?.apply(.emulationWillStart) },
            center.addObserver(
                forName: Notification.Name("DOLEmulationDidEndNotification"),
                object: nil, queue: .main
            ) { [weak self] _ in self?.apply(.emulationDidEnd) },
            center.addObserver(
                forName: Notification.Name(PVWebServerFileUploadStartedNotificationName),
                object: nil, queue: .main
            ) { [weak self] _ in self?.apply(.uploadStarted) },
            center.addObserver(
                forName: Notification.Name(PVWebServerFileUploadCompletedNotificationName),
                object: nil, queue: .main
            ) { [weak self] _ in self?.apply(.uploadEnded) }
        ]

        lock.lock(); observers = tokens; lock.unlock()
    }

    private func apply(_ event: WebServerLifecycleEvent) {
        lock.lock()
        let action = policy.handle(event, serverIsRunning: PVWebServer.shared.isWWWUploadServerRunning)
        lock.unlock()

        switch action {
        case .start: PVWebServer.shared.startServers()
        case .stop: PVWebServer.shared.stopServers()
        case .none: break
        }
    }
}
