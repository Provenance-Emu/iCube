// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVCloudSync
import PVSyncRules

/// Drives iCloud sync of everything under `User/` except ROMs.
///
/// This is **glue only**. Every rule worth arguing about lives in `PVCloudSync`
/// and is unit-tested there without a network or a container:
/// - *when* to sync — `SyncLifecyclePolicy`
/// - *what* to do about a file — `SyncPlanner` + `TimestampConflictResolver`
/// - *whether to retry* — `SyncRetryPolicy`
/// - *what may leave the device at all* — `PVSyncRules.SyncClassifier`, shared
///   with WS-4's continuity manifest so the two can never disagree.
///
/// Same split as WS-3's `WebServerLifecycleService` / `WebServerLifecyclePolicy`.
///
/// ## It has to work with no container
///
/// iCube's CloudKit container is **not provisioned yet** and no entitlements
/// file requests it. That is the state the app ships in, so the whole path has
/// to be inert-but-honest rather than absent: `CloudKitSyncProvider` refuses to
/// construct, `InertSyncProvider` takes its place, and `unavailableReason` is
/// shown in Settings. Nothing here crashes, spins, or silently pretends.
///
/// ## App preferences are deliberately NOT synced (WS-5 item 6)
///
/// `UserDefaults` / `@AppStorage` is not covered by a file mirror, and
/// `NSUbiquitousKeyValueStore` is the usual answer. iCube does not adopt it, on
/// the evidence rather than on taste. Of the 44 distinct `@AppStorage` keys in
/// the app:
///
/// - **~18 are debug or device-capability keys** — the `shader_debug_*` family,
///   `adaptive_clock_enable`, `icube_vertex_loader_mode`, `shader_precopy_enabled`,
///   `gfx_overscan_fullscreen`, `motion_debug_*`, `ui_show_dsu_debug_hud`.
/// - **~18 are peripheral-specific** — the `dsu_*` and `motion_*` families,
///   `rumble_destination`, `virtual_mfi_connect`. These describe *this* device's
///   controllers and sensors. An Apple TV has no gyro; pushing an iPhone's
///   motion configuration onto it is a bug, not a feature.
/// - **8 are genuinely device-independent**, and 7 of those are library view
///   preferences (`library_sort_field`, `library_grid_column_offset`, …) plus
///   `resume_where_left_off`.
///
/// So KVS would carry real risk for eight keys of cosmetic value, while the
/// settings people actually care about — everything Dolphin itself persists —
/// live in `User/Config/*.ini` and `User/GameSettings/*.ini` and are **already
/// covered by this file mirror**. Adding an empty KVS scaffold to "leave the
/// door open" would be dead code. If this is revisited, the right shape is an
/// explicit allow-list of those eight keys, not a blanket KVS mirror.
@MainActor
final class CloudSyncCoordinator: ObservableObject {

    static let shared = CloudSyncCoordinator()

    // MARK: - Observable state

    /// Opt-in, default off. Persisted.
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: PreferenceKey.enabled)
            Task { await apply(.enabledChanged(isEnabled)) }
        }
    }

    @Published private(set) var isSyncing = false
    @Published private(set) var statistics = SyncStatistics()
    @Published private(set) var pendingConflicts: [SyncConflict] = []
    @Published private(set) var recentEvents: [SyncEvent] = []
    @Published private(set) var lastError: String?
    /// Non-nil when sync cannot run, with the reason to show the user.
    @Published private(set) var unavailableReason: SyncUnavailableReason?

    // MARK: - Private

    private enum PreferenceKey {
        static let enabled = "icube.cloudSync.enabled"
        /// Stable per-install identifier. Preferred over
        /// `identifierForVendor`, which changes when the last app from a vendor
        /// is deleted — that would orphan the "which device wrote this" field.
        static let deviceIdentifier = "icube.cloudSync.deviceIdentifier"
    }

    private var policy: SyncLifecyclePolicy
    private let planner = SyncPlanner()
    private var scanner: UserDataScanner?
    private var provider: (any SyncProvider)?

    private var watchers: [DirectoryWatcher] = []
    private var backgroundTimerTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?

    /// Set when the policy says to bail out of an in-flight run. The run checks
    /// it between files, which is the only way to actually stop a sync that is
    /// already looping — an entry guard only blocks new ones.
    private var abortRequested = false

    /// Last known metadata per path, for the statistics pane. In memory only:
    /// iCube has no ORM and this is not worth inventing one for.
    private var metadataCache: [String: SyncableFileMetadata] = [:]

    /// When a sync run last actually completed (successfully or not). `nil`
    /// until the first run finishes.
    ///
    /// `refreshStatistics()` is called from `runSync` right after the local
    /// scan — before the availability/remote checks — so the settings pane can
    /// show real per-category counts on a build with no container at all. That
    /// call must not stamp "now" as the sync date, or the footer would read
    /// "Last Synced: just now" on the same screen that says "iCloud sync is not
    /// available in this build yet." Only the trigger that runs a call site
    /// which reaches the end of `runSync` moves this forward.
    private var lastSyncCompletionDate: Date?

    private init() {
        let enabled = UserDefaults.standard.bool(forKey: PreferenceKey.enabled)
        self.isEnabled = enabled
        self.policy = SyncLifecyclePolicy(isEnabled: enabled)
    }

    // MARK: - Events in

    /// Feed a lifecycle event to the policy and carry out its answer.
    func handle(_ event: SyncLifecycleEvent) async {
        await apply(event)
    }

    func syncNow() async {
        await apply(.trigger(.manual))
    }

    /// Called once at launch by `CloudSyncLifecycleService`.
    func start() async {
        guard isEnabled else {
            // Still resolve availability so Settings can explain itself before
            // the user ever turns sync on.
            await refreshAvailability()
            return
        }
        await apply(.enabledChanged(true))
    }

    private func apply(_ event: SyncLifecycleEvent) async {
        let action = policy.handle(event)
        switch action {
        case .none, .deferUntilIdle:
            break

        case .abortInFlightAndDefer:
            abortRequested = true

        case .shutDown:
            await shutDown()

        case .startSync(let trigger):
            if scanner == nil || provider == nil {
                await prepare()
            }
            abortRequested = false
            isSyncing = true
            syncTask = Task { [weak self] in
                await self?.runSync(trigger: trigger)
                await self?.finishSync()
            }
        }
    }

    private func finishSync() async {
        isSyncing = false
        syncTask = nil
        await apply(.syncFinished)
    }

    // MARK: - Setup / teardown

    private func prepare() async {
        guard let root = DolphinPaths.userDirectoryURL() else {
            unavailableReason = .unknown("Could not locate iCube's User directory.")
            return
        }
        scanner = UserDataScanner(rootDirectory: root)
        provider = Self.makeProvider(deviceIdentifier: deviceIdentifier())

        if let provider {
            do {
                try await provider.initialize()
                unavailableReason = nil
            } catch {
                unavailableReason = await provider.unavailableReason()
                    ?? .unknown(error.localizedDescription)
            }
        }
        await installWatchers(root: root)
        startBackgroundTimer()
    }

    /// The real provider when this build can use CloudKit, otherwise an inert
    /// one carrying the reason. Never optional at the call site: the sync path
    /// runs unchanged either way and simply finds nothing to do.
    private static func makeProvider(deviceIdentifier: String) -> any SyncProvider {
        if let reason = CloudKitAvailability.buildLevelUnavailableReason() {
            return InertSyncProvider(reason: reason)
        }
        if let cloudKit = CloudKitSyncProvider(deviceIdentifier: deviceIdentifier) {
            return cloudKit
        }
        return InertSyncProvider(reason: .entitlementMissing)
    }

    private func deviceIdentifier() -> String {
        if let existing = UserDefaults.standard.string(forKey: PreferenceKey.deviceIdentifier) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: PreferenceKey.deviceIdentifier)
        return fresh
    }

    /// One watcher per directory: `DISPATCH_SOURCE_TYPE_VNODE` has no recursive
    /// mode, so a watcher on `User/` alone would never see a save state land in
    /// `User/StateSaves/`.
    private func installWatchers(root: URL) async {
        await tearDownWatchers()
        let watched = ["StateSaves", "GC", "Wii", "Config", "GameSettings"]
        for directory in watched {
            let watcher = DirectoryWatcher(url: root.appendingPathComponent(directory, isDirectory: true))
            await watcher.setOnChange { [weak self] in
                await self?.handle(.trigger(.fileChanged))
            }
            // A directory that cannot be watched (permissions, missing volume)
            // costs us promptness, not correctness — the 30-minute timer and the
            // foreground trigger still catch its changes.
            try? await watcher.startWatching()
            watchers.append(watcher)
        }
    }

    private func tearDownWatchers() async {
        for watcher in watchers {
            await watcher.stopWatching()
        }
        watchers.removeAll()
    }

    private func startBackgroundTimer() {
        backgroundTimerTask?.cancel()
        backgroundTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(CloudSyncConstants.backgroundSyncInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.handle(.trigger(.periodicTimer))
            }
        }
    }

    private func shutDown() async {
        syncTask?.cancel()
        syncTask = nil
        backgroundTimerTask?.cancel()
        backgroundTimerTask = nil
        await tearDownWatchers()
        await scanner?.resetCache()
        scanner = nil
        provider = nil
        isSyncing = false
        abortRequested = false
        metadataCache.removeAll()
        pendingConflicts.removeAll()
        statistics = SyncStatistics()
        lastSyncCompletionDate = nil
        lastError = nil
    }

    // MARK: - The sync run

    private func runSync(trigger: SyncTrigger) async {
        guard let scanner, let provider else { return }

        // A fresh trigger gets a fresh chance to report cleanly. Without this,
        // one transient fetch failure leaves red error text in the status
        // footer for the rest of the session, even after a later run succeeds
        // without incident — nothing else on the success path clears it.
        lastError = nil

        // Scan first, and unconditionally. The local inventory is the half that
        // does not need a cloud, so the settings pane can show what *would*
        // sync — and the classifier can be seen doing its job — on a build with
        // no container at all. It also means the counts are real before the
        // first successful round trip rather than after it.
        let local = await scanner.scanLocalFiles()
        rebuildMetadataCache(from: local)
        refreshStatistics()

        if let reason = await provider.unavailableReason() {
            unavailableReason = reason
            addEvent(.info, message: reason.localizedDescription)
            return
        }
        unavailableReason = nil

        let remote: [SyncableFileMetadata]
        do {
            remote = try await provider.fetchRemoteMetadata()
        } catch {
            // Never treat a failed remote fetch as "the cloud is empty" — that
            // reads as "every local file is new" and re-uploads the library.
            await record(error, during: "fetching the iCloud file list")
            return
        }

        for step in planner.plan(local: local, remote: remote) {
            // The only way to actually stop a run that is already going.
            if abortRequested || Task.isCancelled { return }

            switch step {
            case .markSynced(var metadata):
                metadata.syncStatus = .synced
                metadata.lastSyncDate = Date()
                metadataCache[metadata.relativePath] = metadata

            case .upload(let metadata, let reason):
                await upload(metadata, reason: reason, scanner: scanner, provider: provider)

            case .download(let metadata):
                await download(metadata, scanner: scanner, provider: provider)

            case .conflict(let conflict):
                if !pendingConflicts.contains(where: { $0.metadata.relativePath == conflict.metadata.relativePath }) {
                    pendingConflicts.append(conflict)
                    var metadata = conflict.metadata
                    metadata.syncStatus = .conflict
                    metadataCache[metadata.relativePath] = metadata
                    addEvent(.conflict, file: conflict.metadata.relativePath,
                             message: "Changed on two devices at once")
                }
            }
        }

        lastSyncCompletionDate = Date()
        refreshStatistics()
        addEvent(.success, message: "Sync completed (\(trigger.rawValue))")
    }

    private func upload(
        _ metadata: SyncableFileMetadata,
        reason: SyncPlanStep.UploadReason,
        scanner: UserDataScanner,
        provider: any SyncProvider
    ) async {
        var working = metadata
        working.syncStatus = .uploading
        metadataCache[working.relativePath] = working
        do {
            let data = try await scanner.readFile(relativePath: metadata.relativePath)
            try await provider.upload(metadata: metadata, data: data)
            working.syncStatus = .synced
            working.lastSyncDate = Date()
            working.lastError = nil
            metadataCache[working.relativePath] = working
            addEvent(.upload, file: metadata.relativePath, message: "Uploaded (\(reason.rawValue))")
        } catch {
            working.syncStatus = .error
            working.lastError = error.localizedDescription
            working.syncAttempts += 1
            metadataCache[working.relativePath] = working
            addEvent(.error, file: metadata.relativePath,
                     message: "Upload failed: \(error.localizedDescription)")
        }
    }

    private func download(
        _ metadata: SyncableFileMetadata,
        scanner: UserDataScanner,
        provider: any SyncProvider
    ) async {
        // Belt and braces on top of the planner: never overwrite a local file
        // that is newer than the remote copy, whatever routed us here.
        if let localModified = await scanner.modificationDate(relativePath: metadata.relativePath),
           localModified > metadata.lastModified.addingTimeInterval(CloudSyncConstants.modificationTimeTolerance) {
            return
        }

        var working = metadata
        working.syncStatus = .downloading
        metadataCache[working.relativePath] = working
        do {
            let data = try await provider.download(metadata: metadata)
            // Never write an empty blob over a real save.
            guard !data.isEmpty else { throw SyncProviderError.invalidData }
            try await scanner.writeFile(
                relativePath: metadata.relativePath,
                data: data,
                modificationDate: metadata.lastModified
            )
            working.syncStatus = .synced
            working.lastSyncDate = Date()
            working.lastError = nil
            metadataCache[working.relativePath] = working
            addEvent(.download, file: metadata.relativePath, message: "Downloaded from iCloud")
        } catch {
            working.syncStatus = .error
            working.lastError = error.localizedDescription
            working.syncAttempts += 1
            metadataCache[working.relativePath] = working
            addEvent(.error, file: metadata.relativePath,
                     message: "Download failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Conflicts

    func resolve(_ conflict: SyncConflict, as resolution: ConflictResolution) async {
        guard let scanner, let provider else { return }
        switch resolution {
        case .useLocal:
            await upload(conflict.metadata, reason: .conflictKeepLocal, scanner: scanner, provider: provider)
        case .useRemote:
            await download(conflict.metadata, scanner: scanner, provider: provider)
        case .keepBoth:
            await keepBoth(conflict, scanner: scanner, provider: provider)
        case .manual:
            return
        }
        pendingConflicts.removeAll { $0.id == conflict.id }
        refreshStatistics()
    }

    /// Copy the local version aside under a timestamped name, then take the
    /// remote one. The copy keeps its original extension so Dolphin still sees a
    /// save state in a slot it understands.
    private func keepBoth(
        _ conflict: SyncConflict,
        scanner: UserDataScanner,
        provider: any SyncProvider
    ) async {
        let relativePath = conflict.metadata.relativePath
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let directory = (relativePath as NSString).deletingLastPathComponent
        let fileName = (relativePath as NSString).lastPathComponent
        let stem = (fileName as NSString).deletingPathExtension
        let fileExtension = (fileName as NSString).pathExtension
        let copyName = fileExtension.isEmpty
            ? "\(stem)_thisdevice_\(stamp)"
            : "\(stem)_thisdevice_\(stamp).\(fileExtension)"
        let copyPath = directory.isEmpty ? copyName : (directory as NSString).appendingPathComponent(copyName)

        do {
            let localData = try await scanner.readFile(relativePath: relativePath)
            try await scanner.writeFile(relativePath: copyPath, data: localData, modificationDate: nil)
            await download(conflict.metadata, scanner: scanner, provider: provider)
            addEvent(.info, file: relativePath, message: "Kept both (this device's copy saved as \(copyName))")
        } catch {
            addEvent(.error, file: relativePath, message: "Could not keep both: \(error.localizedDescription)")
        }
    }

    func resolveAllConflicts(as resolution: ConflictResolution) async {
        for conflict in pendingConflicts {
            await resolve(conflict, as: resolution)
        }
    }

    // MARK: - Maintenance

    /// Delete every record in iCloud. Local files are never touched.
    func clearCloudData() async {
        guard let provider else { return }
        do {
            try await provider.purgeAllData()
            metadataCache.removeAll()
            pendingConflicts.removeAll()
            refreshStatistics()
            addEvent(.info, message: "Cleared all iCloud sync data")
        } catch {
            await record(error, during: "clearing iCloud data")
        }
    }

    func refreshAvailability() async {
        if let buildReason = CloudKitAvailability.buildLevelUnavailableReason() {
            unavailableReason = buildReason
            return
        }
        unavailableReason = await provider?.unavailableReason()
    }

    // MARK: - Bookkeeping

    /// Rebuild the cache from what is actually on disk, carrying forward what we
    /// already know about files whose bytes have not changed.
    ///
    /// Rebuilt rather than mutated in place because a cache that is only ever
    /// added to drifts: delete a save state and its entry — and its bytes —
    /// stay in the totals for the rest of the session, so the per-category
    /// counts climb and never come back down.
    private func rebuildMetadataCache(from local: [SyncableFileMetadata]) {
        var rebuilt: [String: SyncableFileMetadata] = [:]
        for file in local {
            var entry = file
            // Same bytes as last pass: keep the sync state we learned, so a
            // synced file does not flip back to "local" on every scan.
            if let previous = metadataCache[file.relativePath],
               previous.checksum == file.checksum {
                entry.syncStatus = previous.syncStatus
                entry.lastSyncDate = previous.lastSyncDate
                entry.cloudKitRecordID = previous.cloudKitRecordID
                entry.lastError = previous.lastError
                entry.syncAttempts = previous.syncAttempts
            }
            rebuilt[file.relativePath] = entry
        }
        metadataCache = rebuilt

        // A conflict over a file that is no longer on disk cannot be resolved,
        // and leaving it in the list is a dead end for the user.
        pendingConflicts.removeAll { rebuilt[$0.metadata.relativePath] == nil }
    }

    private func refreshStatistics() {
        statistics = SyncStatistics.summarize(
            metadataCache.values,
            conflictCount: pendingConflicts.count,
            lastSyncDate: lastSyncCompletionDate
        )
    }

    private func record(_ error: Error, during activity: String) async {
        lastError = error.localizedDescription
        if let providerError = error as? SyncProviderError,
           case .unavailable(let reason) = providerError {
            unavailableReason = reason
        }
        addEvent(.error, message: "Error \(activity): \(error.localizedDescription)")
    }

    private func addEvent(_ kind: SyncEvent.Kind, file: String? = nil, message: String) {
        recentEvents.insert(SyncEvent(kind: kind, file: file, message: message), at: 0)
        if recentEvents.count > 100 {
            recentEvents = Array(recentEvents.prefix(100))
        }
    }
}
