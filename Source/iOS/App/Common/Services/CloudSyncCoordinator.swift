// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVCloudSync
import PVSyncRules
#if canImport(CloudKit)
import CloudKit
#endif

/// How far the current run has got, for the status row.
struct SyncProgress: Equatable {
    var completed: Int
    var total: Int
}

/// Drives sync of the user's data under `User/` — never games.
///
/// This is **glue only**. Every rule worth arguing about lives in `PVCloudSync`
/// and is unit-tested there without a network or a container:
/// - *what may leave the device* — `PVSyncRules.SyncClassifier`, shared with
///   Continuity so the two can never disagree; *which of that the user wants
///   synced right now* — `PVSyncRules.SyncPolicy`
/// - *when* to sync — `SyncLifecyclePolicy`
/// - *what to do about a file* — `SyncPlanner` (including the tombstone table
///   from the design spec) + `TimestampConflictResolver` + `DocumentMergers`
/// - *whether to retry* — `SyncRetryPolicy`
/// - *what this device has synced before* — `SyncIndexStore`
/// - *where removed files go* — `SyncTrash`; nothing is unlinked outright
///
/// ## It has to work with no container
///
/// iCube's CloudKit container is **not provisioned yet** and no entitlements
/// file requests it. That is the state the app ships in, so the whole path has
/// to be inert-but-honest rather than absent: `CloudKitSyncProvider` refuses to
/// construct, `InertSyncProvider` takes its place, and `unavailableReason` is
/// shown in Settings. Nothing here crashes, spins, or silently pretends.
///
/// ## App preferences are deliberately NOT mirrored wholesale
///
/// Of the 44 `@AppStorage` keys, most describe this device's controllers,
/// sensors or debug state; pushing an iPhone's motion configuration onto an
/// Apple TV is a bug. The settings people care about live in `User/Config/*.ini`
/// and `User/GameSettings/*.ini`, already covered by the file mirror, and the
/// handful of library preferences worth sharing (favorites, last played, play
/// stats) ride in `Profiles/library_state.json` through `LibraryStateStore`.
@MainActor
final class CloudSyncCoordinator: ObservableObject {

    static let shared = CloudSyncCoordinator()

    /// Posted after a merged document (`libraryState`, `gameProfile`) was
    /// rewritten on disk by a sync. `userInfo[fileTypeKey]` is the category's
    /// raw value. Stores that own those files reload on it.
    static let documentDidChangeNotification = Notification.Name("CloudSyncDocumentDidChangeNotification")
    static let fileTypeKey = "fileType"

    // MARK: - Observable state

    /// Opt-in, default off. Persisted.
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: PreferenceKey.enabled)
            Task { await apply(.enabledChanged(isEnabled)) }
        }
    }

    /// Which opt-in categories are on and whether large files wait for Wi-Fi.
    /// Persisted; a change rescans so the new switches take effect at once.
    @Published var policy: SyncPolicy {
        didSet {
            guard oldValue != policy else { return }
            Self.store(policy)
            Task { await apply(.trigger(.policyChanged)) }
        }
    }

    @Published private(set) var isSyncing = false
    @Published private(set) var progress: SyncProgress?
    @Published private(set) var statistics = SyncStatistics()
    @Published private(set) var pendingConflicts: [SyncConflict] = []
    @Published private(set) var recentEvents: [SyncEvent] = []
    @Published private(set) var lastError: String?
    /// Non-nil when sync cannot run, with the reason to show the user.
    @Published private(set) var unavailableReason: SyncUnavailableReason?
    /// Files removed by a remote delete, recoverable from Settings.
    @Published private(set) var trashEntries: [SyncTrashEntry] = []
    /// Large files held back this run because the network was metered.
    @Published private(set) var heldForWiFiCount = 0

    // MARK: - Private

    private enum PreferenceKey {
        static let enabled = "icube.cloudSync.enabled"
        static let policy = "icube.cloudSync.policy"
    }

    private var lifecycle: SyncLifecyclePolicy
    private let planner = SyncPlanner()
    private let network: any SyncNetworkObserving
    private var scanner: UserDataScanner?
    private var provider: (any SyncProvider)?
    private var index: SyncIndexStore?
    private var trash: SyncTrash?

    private var watchers: [DirectoryWatcher] = []
    private var backgroundTimerTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var accountObserver: NSObjectProtocol?

    /// Set when the policy says to bail out of an in-flight run. The run checks
    /// it between files, which is the only way to actually stop a sync that is
    /// already looping — an entry guard only blocks new ones.
    private var abortRequested = false

    /// Last known metadata per path, for the statistics pane. In memory only;
    /// the durable record of what was synced is `SyncIndexStore`.
    private var metadataCache: [String: SyncableFileMetadata] = [:]

    /// When a sync run last actually completed (successfully or not). `nil`
    /// until the first run finishes. `refreshStatistics()` runs right after
    /// the local scan, before the remote is consulted, so it must not stamp
    /// "now" — the footer would read "Last Synced: just now" on the same
    /// screen that says sync is unavailable.
    private var lastSyncCompletionDate: Date?

    private init(network: any SyncNetworkObserving = SyncNetworkMonitor()) {
        let enabled = UserDefaults.standard.bool(forKey: PreferenceKey.enabled)
        self.isEnabled = enabled
        self.policy = Self.loadPolicy()
        self.lifecycle = SyncLifecyclePolicy(isEnabled: enabled)
        self.network = network
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
        // Timer ticks stand down in Low Power Mode; the user's own actions and
        // the foreground and game-end triggers still run.
        if case .trigger(.periodicTimer) = event, network.isLowPowerModeEnabled {
            return
        }

        let action = lifecycle.handle(event)
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
        progress = nil
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
        let provider = Self.makeProvider(deviceIdentifier: SyncDeviceIdentity.deviceIdentifier())
        self.provider = provider

        let support = Self.supportDirectory()
        index = SyncIndexStore(fileURL: support
            .appendingPathComponent(provider.kind.rawValue, isDirectory: true)
            .appendingPathComponent("index.json"))
        trash = SyncTrash(rootURL: support.appendingPathComponent("Trash", isDirectory: true))

        do {
            try await provider.initialize()
            unavailableReason = nil
        } catch {
            unavailableReason = await provider.unavailableReason()
                ?? .unknown(error.localizedDescription)
        }
        await installWatchers(root: root)
        installAccountObserver()
        startBackgroundTimer()
        await refreshTrash()
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

    /// Where the index and the trash live. Not under `User/`, so neither is
    /// visible in Files nor ever a candidate for the classifier. tvOS can only
    /// write Caches; a purge there costs one additive run, not correctness.
    private static func supportDirectory() -> URL {
        #if os(tvOS)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("iCubeSync", isDirectory: true)
    }

    /// One watcher per directory: `DISPATCH_SOURCE_TYPE_VNODE` has no recursive
    /// mode, so a watcher on `User/` alone would never see a save state land in
    /// `User/StateSaves/`. The NAND's deep `title/` tree is not watched; it
    /// changes only while a game runs, and the game-end flush covers that.
    private func installWatchers(root: URL) async {
        await tearDownWatchers()
        let watched = ["StateSaves", "GC", "Wii", "GBA", "Config", "GameSettings", "Profiles", "Skins"]
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

    /// A sign-out or account switch must never let one account's index speak
    /// for another's. The identity check in `runSync` is the backstop; this
    /// makes the switch take effect without waiting for the next trigger.
    private func installAccountObserver() {
        #if canImport(CloudKit)
        guard accountObserver == nil else { return }
        accountObserver = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.index?.reset()
                self.addEvent(.info, message: "iCloud account changed; starting fresh")
                await self.handle(.trigger(.accountChanged))
            }
        }
        #endif
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
        if let accountObserver {
            NotificationCenter.default.removeObserver(accountObserver)
            self.accountObserver = nil
        }
        await tearDownWatchers()
        await scanner?.resetCache()
        scanner = nil
        provider = nil
        index = nil
        // The trash is deliberately kept: turning sync off must not throw away
        // the user's recoverable files.
        isSyncing = false
        progress = nil
        abortRequested = false
        metadataCache.removeAll()
        pendingConflicts.removeAll()
        statistics = SyncStatistics()
        lastSyncCompletionDate = nil
        lastError = nil
        heldForWiFiCount = 0
    }

    // MARK: - The sync run

    private func runSync(trigger: SyncTrigger) async {
        guard let scanner, let provider, let index, let trash else { return }

        // A fresh trigger gets a fresh chance to report cleanly.
        lastError = nil
        heldForWiFiCount = 0

        // Scan first, and unconditionally. The local inventory is the half that
        // does not need a cloud, so the settings pane can show what *would*
        // sync on a build with no container at all.
        let local = await scanner.scanLocalFiles(policy: policy)
        rebuildMetadataCache(from: local)
        refreshStatistics()

        if let reason = await provider.unavailableReason() {
            unavailableReason = reason
            addEvent(.info, message: reason.localizedDescription)
            return
        }
        unavailableReason = nil

        let remote: RemoteSyncSnapshot
        do {
            remote = try await provider.fetchRemoteSnapshot()
        } catch {
            // Never treat a failed remote fetch as "the cloud is empty" — that
            // reads as "every local file is new" and re-uploads the library.
            await record(error, during: "fetching the iCloud file list")
            return
        }

        // Bind the index to the account before it is consulted.
        if await index.bind(toAccountIdentity: provider.accountIdentity()) {
            addEvent(.info, message: "Different iCloud account than last time; starting fresh")
        }

        let now = Date()
        // Housekeeping first, both best-effort.
        let purged = await trash.purge(olderThan: now.addingTimeInterval(-CloudSyncConstants.trashRetention))
        if purged > 0 { addEvent(.info, message: "Emptied \(purged) file(s) from Recently Deleted after 30 days") }
        try? await provider.purgeExpiredTombstones(olderThan: now.addingTimeInterval(-CloudSyncConstants.tombstoneRetention))

        let steps = planner.plan(
            local: local,
            remote: remote,
            index: await index.snapshot(),
            policy: policy,
            now: now,
            deviceIdentifier: SyncDeviceIdentity.deviceIdentifier()
        )
        progress = SyncProgress(completed: 0, total: steps.count)

        let metered = network.isConstrainedOrExpensive
        var downloaded = 0

        for step in steps {
            // The only way to actually stop a run that is already going.
            if abortRequested || Task.isCancelled { break }
            defer { progress?.completed += 1 }

            // Large categories wait for Wi-Fi when the user asked them to.
            if metered, let type = step.transferredFileType, policy.requiresUnconstrainedNetwork(for: type) {
                heldForWiFiCount += 1
                continue
            }

            switch step {
            case .markSynced(var metadata):
                metadata.syncStatus = .synced
                metadata.lastSyncDate = now
                metadataCache[metadata.relativePath] = metadata
                await index.record(path: metadata.relativePath, checksum: metadata.checksum, lastModified: metadata.lastModified, syncedAt: now)

            case .upload(let metadata, let reason):
                await upload(metadata, reason: reason, scanner: scanner, provider: provider, index: index)

            case .download(let metadata):
                if await download(metadata, scanner: scanner, provider: provider, index: index) { downloaded += 1 }

            case .restore(let metadata):
                if await download(metadata, scanner: scanner, provider: provider, index: index) {
                    downloaded += 1
                    addEvent(.info, file: metadata.relativePath,
                             message: "Brought back: it was deleted here but changed on another device")
                }

            case .merge(let localMeta, let remoteMeta):
                await merge(local: localMeta, remote: remoteMeta, scanner: scanner, provider: provider, index: index)

            case .writeTombstone(let tombstone):
                do {
                    try await provider.writeTombstone(tombstone)
                    await index.markDeleted(path: tombstone.relativePath, at: now)
                    addEvent(.info, file: tombstone.relativePath, message: "Deleted on your other devices too")
                } catch {
                    addEvent(.error, file: tombstone.relativePath,
                             message: "Could not propagate delete: \(error.localizedDescription)")
                }

            case .trashLocal(let metadata, let tombstone):
                do {
                    _ = try await scanner.moveToTrash(relativePath: metadata.relativePath, trash: trash, now: now)
                    await index.markDeleted(path: metadata.relativePath, at: tombstone.deletedAt)
                    metadataCache.removeValue(forKey: metadata.relativePath)
                    addEvent(.info, file: metadata.relativePath,
                             message: "Removed because it was deleted on another device. Recoverable in Recently Deleted for 30 days")
                } catch {
                    addEvent(.error, file: metadata.relativePath,
                             message: "Could not remove: \(error.localizedDescription)")
                }

            case .markDeleted(let relativePath):
                await index.markDeleted(path: relativePath, at: now)

            case .conflict(let conflict):
                if !pendingConflicts.contains(where: { $0.metadata.relativePath == conflict.metadata.relativePath }) {
                    pendingConflicts.append(conflict)
                    var metadata = conflict.metadata
                    metadata.syncStatus = .conflict
                    metadataCache[metadata.relativePath] = metadata
                    addEvent(.conflict, file: conflict.metadata.relativePath, message: Self.message(for: conflict.kind))
                }
            }
        }

        do {
            try await index.save()
        } catch {
            addEvent(.error, message: "Could not save the sync index: \(error.localizedDescription)")
        }

        if heldForWiFiCount > 0 {
            addEvent(.info, message: "Waiting for Wi-Fi to move \(heldForWiFiCount) large file(s)")
        }
        if trigger == .enabled, downloaded > 0 {
            addEvent(.info, message: "Downloaded \(downloaded) file(s) from iCloud")
        }

        lastSyncCompletionDate = Date()
        refreshStatistics()
        await refreshTrash()
        addEvent(.success, message: "Sync completed (\(trigger.rawValue))")
    }

    private static func message(for kind: SyncConflict.Kind) -> String {
        switch kind {
        case .bothChanged: return "Changed on two devices at once"
        case .deletedRemotelyChangedLocally: return "Deleted on another device, but changed here"
        }
    }

    private func upload(
        _ metadata: SyncableFileMetadata,
        reason: SyncPlanStep.UploadReason,
        scanner: UserDataScanner,
        provider: any SyncProvider,
        index: SyncIndexStore
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
            await index.record(path: metadata.relativePath, checksum: metadata.checksum, lastModified: metadata.lastModified)
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

    /// Returns true when the file was written.
    @discardableResult
    private func download(
        _ metadata: SyncableFileMetadata,
        scanner: UserDataScanner,
        provider: any SyncProvider,
        index: SyncIndexStore
    ) async -> Bool {
        // Belt and braces on top of the planner: never overwrite a local file
        // that is newer than the remote copy, whatever routed us here.
        if let localModified = await scanner.modificationDate(relativePath: metadata.relativePath),
           localModified > metadata.lastModified.addingTimeInterval(CloudSyncConstants.modificationTimeTolerance) {
            return false
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
            await index.record(path: metadata.relativePath, checksum: metadata.checksum, lastModified: metadata.lastModified)
            addEvent(.download, file: metadata.relativePath, message: "Downloaded from iCloud")
            notifyIfDocument(metadata.fileType)
            return true
        } catch {
            working.syncStatus = .error
            working.lastError = error.localizedDescription
            working.syncAttempts += 1
            metadataCache[working.relativePath] = working
            addEvent(.error, file: metadata.relativePath,
                     message: "Download failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Field-level merge for `library_state.json` and `game_profiles.json`.
    /// Neither side is discarded and no conflict is raised. If either copy is
    /// unreadable the merge cannot run, and the newer copy wins instead — a
    /// corrupt file must not block sync forever.
    private func merge(
        local: SyncableFileMetadata,
        remote: SyncableFileMetadata,
        scanner: UserDataScanner,
        provider: any SyncProvider,
        index: SyncIndexStore
    ) async {
        guard let merger = DocumentMergers.merger(for: local.fileType) else {
            // Should not happen: the planner only emits .merge for document kinds.
            if local.lastModified >= remote.lastModified {
                await upload(local, reason: .contentChanged, scanner: scanner, provider: provider, index: index)
            } else {
                await download(remote, scanner: scanner, provider: provider, index: index)
            }
            return
        }

        let path = local.relativePath
        do {
            let localData = try await scanner.readFile(relativePath: path)
            let remoteData = try await provider.download(metadata: remote)
            let merged: Data
            do {
                merged = try merger.merge(local: localData, remote: remoteData)
            } catch {
                addEvent(.error, file: path, message: "Could not merge; keeping the newer copy (\(error.localizedDescription))")
                if local.lastModified >= remote.lastModified {
                    await upload(local, reason: .contentChanged, scanner: scanner, provider: provider, index: index)
                } else {
                    await download(remote, scanner: scanner, provider: provider, index: index)
                }
                return
            }

            let now = Date()
            var result = local
            result.checksum = SyncChecksum.sha256Hex(merged)
            result.fileSize = Int64(merged.count)
            result.lastModified = now
            result.syncStatus = .synced
            result.lastSyncDate = now
            result.lastError = nil

            let localChanged = merged != localData
            if localChanged {
                try await scanner.writeFile(relativePath: path, data: merged, modificationDate: now)
            }
            if merged != remoteData {
                try await provider.upload(metadata: result, data: merged)
            }
            metadataCache[path] = result
            await index.record(path: path, checksum: result.checksum, lastModified: now, syncedAt: now)
            addEvent(.info, file: path, message: localChanged ? "Merged changes from another device" : "Merged this device's changes into iCloud")
            if localChanged { notifyIfDocument(local.fileType) }
        } catch {
            var working = local
            working.syncStatus = .error
            working.lastError = error.localizedDescription
            working.syncAttempts += 1
            metadataCache[path] = working
            addEvent(.error, file: path, message: "Merge failed: \(error.localizedDescription)")
        }
    }

    private func notifyIfDocument(_ type: SyncableFileType) {
        guard type.mergeKind == .document else { return }
        NotificationCenter.default.post(
            name: Self.documentDidChangeNotification,
            object: self,
            userInfo: [Self.fileTypeKey: type.rawValue]
        )
    }

    // MARK: - Conflicts

    func resolve(_ conflict: SyncConflict, as resolution: ConflictResolution) async {
        guard let scanner, let provider, let index, let trash else { return }
        switch (conflict.kind, resolution) {
        case (.bothChanged, .useLocal):
            await upload(conflict.metadata, reason: .conflictKeepLocal, scanner: scanner, provider: provider, index: index)
        case (.bothChanged, .useRemote):
            await download(conflict.metadata, scanner: scanner, provider: provider, index: index)
        case (.bothChanged, .keepBoth):
            await keepBoth(conflict, scanner: scanner, provider: provider, index: index)

        // A delete conflict has no second copy to keep: "keep both" and "keep
        // this device's" both mean the file lives on, which undeletes it.
        case (.deletedRemotelyChangedLocally, .useLocal), (.deletedRemotelyChangedLocally, .keepBoth):
            await upload(conflict.metadata, reason: .undelete, scanner: scanner, provider: provider, index: index)
        case (.deletedRemotelyChangedLocally, .useRemote):
            do {
                _ = try await scanner.moveToTrash(relativePath: conflict.metadata.relativePath, trash: trash)
                await index.markDeleted(path: conflict.metadata.relativePath)
                metadataCache.removeValue(forKey: conflict.metadata.relativePath)
                addEvent(.info, file: conflict.metadata.relativePath, message: "Removed. Recoverable in Recently Deleted for 30 days")
                await refreshTrash()
            } catch {
                addEvent(.error, file: conflict.metadata.relativePath, message: "Could not remove: \(error.localizedDescription)")
            }

        case (_, .manual):
            return
        }
        pendingConflicts.removeAll { $0.id == conflict.id }
        try? await index.save()
        refreshStatistics()
    }

    /// Copy the local version aside under a timestamped name, then take the
    /// remote one. The copy keeps its original extension so Dolphin still sees a
    /// save state in a slot it understands.
    private func keepBoth(
        _ conflict: SyncConflict,
        scanner: UserDataScanner,
        provider: any SyncProvider,
        index: SyncIndexStore
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
            await download(conflict.metadata, scanner: scanner, provider: provider, index: index)
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

    // MARK: - Recently Deleted

    func refreshTrash() async {
        guard let trash else { return }
        trashEntries = await trash.entries()
    }

    /// Put a trashed file back. It is stamped now, so the next run reads it as
    /// an undelete and uploads it, replacing the tombstone everywhere.
    func restoreFromTrash(_ entry: SyncTrashEntry) async {
        guard let trash, let root = scanner?.rootDirectory else { return }
        do {
            try await trash.restore(entry, into: root)
            await index?.remove(path: entry.relativePath)
            try? await index?.save()
            addEvent(.info, file: entry.relativePath, message: "Restored from Recently Deleted")
            await refreshTrash()
            await apply(.trigger(.fileChanged))
        } catch {
            addEvent(.error, file: entry.relativePath, message: "Could not restore: \(error.localizedDescription)")
        }
    }

    func deleteFromTrash(_ entry: SyncTrashEntry) async {
        guard let trash else { return }
        do {
            try await trash.delete(entry)
            await refreshTrash()
        } catch {
            addEvent(.error, file: entry.relativePath, message: "Could not delete: \(error.localizedDescription)")
        }
    }

    // MARK: - Maintenance

    /// Delete every record in iCloud. Local files are never touched. The index
    /// is reset too: with nothing remote, there is nothing to have synced.
    func clearCloudData() async {
        guard let provider else { return }
        do {
            try await provider.purgeAllData()
            await index?.reset()
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

    // MARK: - Policy persistence

    private static func loadPolicy() -> SyncPolicy {
        guard let data = UserDefaults.standard.data(forKey: PreferenceKey.policy),
              let policy = try? JSONDecoder().decode(SyncPolicy.self, from: data) else {
            return .default
        }
        return policy
    }

    private static func store(_ policy: SyncPolicy) {
        if let data = try? JSONEncoder().encode(policy) {
            UserDefaults.standard.set(data, forKey: PreferenceKey.policy)
        }
    }

    // MARK: - Bookkeeping

    /// Rebuild the cache from what is actually on disk, carrying forward what we
    /// already know about files whose bytes have not changed.
    private func rebuildMetadataCache(from local: [SyncableFileMetadata]) {
        var rebuilt: [String: SyncableFileMetadata] = [:]
        for file in local {
            var entry = file
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

private extension SyncPlanStep {
    /// The category whose bytes this step would move, for the Wi-Fi rule.
    var transferredFileType: SyncableFileType? {
        switch self {
        case .upload(let metadata, _), .download(let metadata), .restore(let metadata):
            return metadata.fileType
        case .merge(let local, _):
            return local.fileType
        case .markSynced, .conflict, .writeTombstone, .trashLocal, .markDeleted:
            return nil
        }
    }
}
