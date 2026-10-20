// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVCloudSync
import PVSyncRules
import UIKit

/// Feeds app and emulation lifecycle into `CloudSyncCoordinator`.
///
/// Same shape as WS-3's `WebServerLifecycleService`: a thin
/// `UIApplicationDelegate` registered in `ServiceManager.services`, whose
/// `applicationDidBecomeActive` / `applicationDidEnterBackground` are invoked
/// from every scene's callbacks in `MainDisplaySceneDelegate` — including at
/// cold launch, so sync runs on a fresh install that never opens Settings.
///
/// WillStart closes local file admission synchronously. The boot worker releases it only
/// after Core is truly Uninitialized; the earlier UI DidEnd event does not release it.
/// This keeps memory cards, save states and NAND untouched throughout core teardown.
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
            ) { _ in
                // Close admission before EmulationCoordinator dispatches the boot worker.
                let generation = SyncLocalIOGate.shared.beginEmulation()
                Task { @MainActor in
                    await CloudSyncCoordinator.shared.handleEmulationWillStart(generation: generation)
                }
            },
            // A merged document was rewritten on disk: the store that owns it
            // reloads so the UI reflects the other device's changes.
            center.addObserver(
                forName: CloudSyncCoordinator.documentDidChangeNotification,
                object: nil, queue: .main
            ) { note in
                guard let raw = note.userInfo?[CloudSyncCoordinator.fileTypeKey] as? String,
                      let type = SyncableFileType(rawValue: raw) else { return }
                switch type {
                case .libraryState: LibraryStateStore.shared.reloadAfterSync()
                case .gameProfile:
                    if let path = note.userInfo?[CloudSyncCoordinator.relativePathKey] as? String,
                       SyncClassifier.isLibraryMetadataShard(relativePath: path) {
                        LibraryMetadataService.reloadAfterSync()
                    } else { GameProfiles.shared.reloadAfterSync() }
                default: break
                }
            }
        ]
    }

    private func send(_ event: SyncLifecycleEvent) {
        Task { @MainActor in
            await CloudSyncCoordinator.shared.handle(event)
        }
    }
}

/// Called only by the emulation worker. Independent of sync opt-in/startup: zero leases
/// returns immediately, and an in-flight actor file write drains before the core opens it.
@objc(ICubeCloudSyncBootGate)
final class ICubeCloudSyncBootGate: NSObject {
    @objc static func waitForLocalIO() {
        SyncLocalIOGate.shared.waitForLocalIO()
    }

    @objc static func currentGeneration() -> UInt64 { SyncLocalIOGate.shared.currentGeneration }

    @objc static func ensureEmulationForWorker(_ generation: UInt64) -> Bool {
        SyncLocalIOGate.shared.ensureEmulation(generation: generation)
    }

    @objc static func isCurrentEmulation(_ generation: UInt64) -> Bool {
        SyncLocalIOGate.shared.isCurrentEmulation(generation)
    }

    @objc static func finishCoreDrain(_ generation: UInt64) {
        guard SyncLocalIOGate.shared.finishCoreDrain(generation: generation) else { return }
        Task { @MainActor in
            await CloudSyncCoordinator.shared.handleCoreDidDrain(generation: generation)
            guard SyncLocalIOGate.shared.isCurrentDrain(generation) else { return }
            ContinuityManager.shared.libraryMirror.environmentChanged()
            LibraryMetadataService.resumeContentIdentityWarming()
        }
    }

}
