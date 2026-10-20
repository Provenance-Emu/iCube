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

enum SyncConflictResolutionResult {
    case resolved
    case deferred(String)
    case failed(String)

    var message: String? {
        switch self {
        case .resolved: return nil
        case .deferred(let message), .failed(let message): return message
        }
    }
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
/// ## Availability is checked for the current installation
///
/// `ICubeCloudSync` declares the provisioned container. Actual availability still
/// depends on the installed build's entitlements and the current iCloud account;
/// the declaration alone does not establish Production sync readiness. When a
/// provider cannot be constructed, `InertSyncProvider` takes its place and
/// `unavailableReason` is shown in Settings instead of reporting a successful sync.
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

    /// These whole files contain account credentials or device-local network endpoints.
    /// Keep the pinned package classifier unchanged; apply this app privacy boundary in both directions.
    static func isEligibleForCloudSync(relativePath: String) -> Bool {
        var components: [String] = []
        for component in relativePath.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            if component == "." { continue }
            if component == ".." { if !components.isEmpty { components.removeLast() }; continue }
            components.append(String(component).lowercased())
        }
        let path = components.joined(separator: "/")
        return path != "config/retroachievements.ini" && path != "config/dsuclient.ini"
    }

    // MARK: - Observable state

    /// Opt-in, default off. Persisted.
    @Published var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            let enabled = isEnabled
            if !enabled { transferGeneration &+= 1 }
            UserDefaults.standard.set(enabled, forKey: PreferenceKey.enabled)
            Task { await apply(.enabledChanged(enabled)) }
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
    @Published private(set) var isEmulating = false
    @Published private(set) var isResolvingConflict = false

    var conflictResolutionUnavailableReason: String? {
        if isEmulating || localIOGate.isEmulating { return L("Stop emulation to resolve sync conflicts.") }
        if !isEnabled { return L("Turn on iCloud sync to resolve conflicts.") }
        if isSyncing || isResolvingConflict || isRestoringTrash { return L("Wait for the current sync operation to finish.") }
        if scanner == nil || provider == nil || index == nil || trash == nil {
            return L("Sync is not ready. Try again after it reconnects.")
        }
        return nil
    }
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
    private var recoveryRoot: URL?
    private var recoveryIndex: SyncIndexStore?
    @Published private(set) var isRestoringTrash = false
    private var recoveryDeferredEvents: [SyncLifecycleEvent] = []

    private var watchers: [DirectoryWatcher] = []
    private var backgroundTimerTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var accountObserver: NSObjectProtocol?

    /// Set when the policy says to bail out of an in-flight run. The run checks
    /// it between files, which is the only way to actually stop a sync that is
    /// already looping — an entry guard only blocks new ones.
    private var abortRequested = false
    private let localIOGate: SyncLocalIOGate
    private var transferGeneration: UInt64 = 0
    private var deferredFileWork = false

    private struct TransferEpoch {
        let policy: UInt64
        let boot: UInt64
    }

    private func captureTransferEpoch() -> TransferEpoch {
        TransferEpoch(policy: transferGeneration, boot: localIOGate.currentGeneration)
    }

    private enum TransferDeferred: Error { case interrupted }

    private func requireTransferAccess(generation: TransferEpoch) throws {
        guard isEnabled, !abortRequested, !Task.isCancelled, !isRestoringTrash,
              generation.policy == transferGeneration && generation.boot == localIOGate.currentGeneration, !localIOGate.isEmulating,
              !lifecycle.isEmulating else {
            deferredFileWork = true
            throw TransferDeferred.interrupted
        }
    }

    private func canContinueTransfer(generation: TransferEpoch) -> Bool {
        do { try requireTransferAccess(generation: generation); return true }
        catch { return false }
    }

    /// Counter leases include the scanner actor hop, but never a provider/network await.
    private func withLocalIO<T>(generation: TransferEpoch, _ operation: () async throws -> T) async throws -> T {
        try requireTransferAccess(generation: generation)
        guard localIOGate.beginLocalIO(generation: generation.boot) else {
            deferredFileWork = true
            throw TransferDeferred.interrupted
        }
        defer { localIOGate.endLocalIO() }
        return try await operation()
    }

    /// Last known metadata per path, for the statistics pane. In memory only;
    /// the durable record of what was synced is `SyncIndexStore`.
    private var metadataCache: [String: SyncableFileMetadata] = [:]

    /// When a sync run last actually completed (successfully or not). `nil`
    /// until the first run finishes. `refreshStatistics()` runs right after
    /// the local scan, before the remote is consulted, so it must not stamp
    /// "now" — the footer would read "Last Synced: just now" on the same
    /// screen that says sync is unavailable.
    private var lastSyncCompletionDate: Date?

    init(network: any SyncNetworkObserving = SyncNetworkMonitor(),
         enabled: Bool? = nil, scanner: UserDataScanner? = nil,
         provider: (any SyncProvider)? = nil, index: SyncIndexStore? = nil,
         trash: SyncTrash? = nil, localIOGate: SyncLocalIOGate = .shared,
         pendingConflicts: [SyncConflict] = []) {
        let enabled = enabled ?? UserDefaults.standard.bool(forKey: PreferenceKey.enabled)
        self.isEnabled = enabled
        self.policy = Self.loadPolicy()
        self.lifecycle = SyncLifecyclePolicy(isEnabled: enabled)
        self.network = network
        self.scanner = scanner
        self.provider = provider
        self.index = index
        self.trash = trash
        self.recoveryRoot = scanner?.rootDirectory
        self.recoveryIndex = index
        self.localIOGate = localIOGate
        self.pendingConflicts = pendingConflicts.filter { Self.isEligibleForCloudSync(relativePath: $0.metadata.relativePath) }
    }

    // MARK: - Events in

    /// Feed a lifecycle event to the policy and carry out its answer.
    func handle(_ event: SyncLifecycleEvent) async {
        if case .emulationWillStart = event {
            await handleEmulationWillStart(generation: localIOGate.ensureEmulation())
            return
        }
        // UI DidEnd deliberately precedes core teardown and must not reopen admission.
        if case .emulationDidEnd = event, localIOGate.isEmulating { return }
        await apply(event)
    }

    func handleEmulationWillStart(generation: UInt64) async {
        guard localIOGate.isCurrentEmulation(generation) else { return }
        isEmulating = true
        transferGeneration &+= 1
        await apply(.emulationWillStart)
    }

    func handleCoreDidDrain(generation: UInt64) async {
        guard localIOGate.isCurrentDrain(generation) else { return }
        isEmulating = false
        await apply(.emulationDidEnd)
        if deferredFileWork, localIOGate.isCurrentDrain(generation) {
            deferredFileWork = false
            await apply(.trigger(.fileChanged))
        }
    }

    func syncNow() async {
        await apply(.trigger(.manual))
    }

    func waitForCurrentSyncCompletion() async {
        await syncTask?.value
    }

    /// Called once at launch by `CloudSyncLifecycleService`.
    func start() async {
        guard isEnabled else {
            if let root = DolphinPaths.userDirectoryURL() {
                prepareLocalRecovery(root: root, kind: Self.makeProvider(deviceIdentifier: SyncDeviceIdentity.deviceIdentifier()).kind)
                await refreshTrash()
            }
            // Still resolve availability so Settings can explain itself before
            // the user ever turns sync on.
            await refreshAvailability()
            return
        }
        await apply(.enabledChanged(true))
    }

    private func apply(_ event: SyncLifecycleEvent) async {
        if isRestoringTrash {
            recoveryDeferredEvents.append(event)
            return
        }
        if isResolvingConflict, case .trigger = event {
            deferredFileWork = true
            return
        }
        if case .enabledChanged(false) = event { transferGeneration &+= 1 }
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

    private func prepareLocalRecovery(root: URL, kind: SyncProviderKind) {
        recoveryRoot = root
        let support = Self.supportDirectory()
        if recoveryIndex == nil {
            recoveryIndex = SyncIndexStore(fileURL: support
                .appendingPathComponent(kind.rawValue, isDirectory: true)
                .appendingPathComponent("index.json"))
        }
        if trash == nil { trash = SyncTrash(rootURL: support.appendingPathComponent("Trash", isDirectory: true)) }
    }

    private func prepare() async {
        guard let root = DolphinPaths.userDirectoryURL() else {
            unavailableReason = .unknown("Could not locate iCube's User directory.")
            return
        }
        scanner = UserDataScanner(rootDirectory: root)
        let provider = Self.makeProvider(deviceIdentifier: SyncDeviceIdentity.deviceIdentifier())
        self.provider = provider

        prepareLocalRecovery(root: root, kind: provider.kind)
        index = recoveryIndex

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
        if let reason = CloudKitAvailability.buildLevelUnavailableReason(for: ICubeCloudSync.configuration) {
            return InertSyncProvider(reason: reason)
        }
        if let cloudKit = CloudKitSyncProvider(configuration: ICubeCloudSync.configuration, deviceIdentifier: deviceIdentifier) {
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
                await self.handleAccountChange()
            }
        }
        #endif
    }

    func handleAccountChange() async {
        transferGeneration &+= 1
        // Versions and choices belong to one account; disabling sync alone retains them.
        pendingConflicts.removeAll()
        metadataCache.removeAll()
        refreshStatistics()
        await index?.reset()
        addEvent(.info, message: "iCloud account changed; starting fresh")
        await handle(.trigger(.accountChanged))
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
        // Keep unresolved choices when disabling interrupts a transfer; failed work is retryable.
        statistics = SyncStatistics()
        lastSyncCompletionDate = nil
        lastError = nil
        heldForWiFiCount = 0
    }

    // MARK: - The sync run

    private func runSync(trigger: SyncTrigger) async {
        guard let scanner, let provider, let index, let trash else { return }
        let generation = captureTransferEpoch()

        // A fresh trigger gets a fresh chance to report cleanly.
        lastError = nil
        heldForWiFiCount = 0

        // Scan first, and unconditionally. The local inventory is the half that
        // does not need a cloud, so the settings pane can show what *would*
        // sync on a build with no container at all.
        let local = await scanner.scanLocalFiles(policy: policy)
            .filter { Self.isEligibleForCloudSync(relativePath: $0.relativePath) }
        guard canContinueTransfer(generation: generation) else { return }
        rebuildMetadataCache(from: local)
        refreshStatistics()

        let reason = await provider.unavailableReason()
        guard canContinueTransfer(generation: generation) else { return }
        if let reason {
            unavailableReason = reason
            addEvent(.info, message: reason.localizedDescription)
            return
        }
        unavailableReason = nil

        let remote: RemoteSyncSnapshot
        do {
            let snapshot = try await provider.fetchRemoteSnapshot()
            guard canContinueTransfer(generation: generation) else { return }
            remote = RemoteSyncSnapshot(
                files: snapshot.files.filter { Self.isEligibleForCloudSync(relativePath: $0.relativePath) },
                tombstones: snapshot.tombstones.filter { Self.isEligibleForCloudSync(relativePath: $0.relativePath) },
                cursor: snapshot.cursor)
        } catch {
            guard canContinueTransfer(generation: generation) else { return }
            // Never treat a failed remote fetch as "the cloud is empty" — that
            // reads as "every local file is new" and re-uploads the library.
            await record(error, during: "fetching the iCloud file list")
            return
        }

        // Bind the index to the account before it is consulted.
        let identity = await provider.accountIdentity()
        guard canContinueTransfer(generation: generation) else { return }
        let changedAccount = await index.bind(toAccountIdentity: identity)
        guard canContinueTransfer(generation: generation) else { return }
        if changedAccount {
            addEvent(.info, message: "Different iCloud account than last time; starting fresh")
        }

        let now = Date()
        // Housekeeping first, both best-effort.
        let purged = await trash.purge(olderThan: now.addingTimeInterval(-CloudSyncConstants.trashRetention))
        guard canContinueTransfer(generation: generation) else { return }
        if purged > 0 { addEvent(.info, message: "Emptied \(purged) file(s) from Recently Deleted after 30 days") }
        try? await provider.purgeExpiredTombstones(olderThan: now.addingTimeInterval(-CloudSyncConstants.tombstoneRetention))
        guard canContinueTransfer(generation: generation) else { return }

        let storedIndex = await index.snapshot()
        guard canContinueTransfer(generation: generation) else { return }
        let steps = planner.plan(
            local: local,
            remote: remote,
            index: SyncIndexSnapshot(entries: storedIndex.entries.filter { Self.isEligibleForCloudSync(relativePath: $0.key) }),
            policy: policy,
            now: now,
            deviceIdentifier: SyncDeviceIdentity.deviceIdentifier()
        )
        progress = SyncProgress(completed: 0, total: steps.count)

        let metered = network.isConstrainedOrExpensive
        var downloaded = 0

        for step in steps {
            // The only way to actually stop a run that is already going.
            if !canContinueTransfer(generation: generation) { break }
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
                guard canContinueTransfer(generation: generation) else { return }

            case .upload(let metadata, let reason):
                await upload(metadata, reason: reason, scanner: scanner, provider: provider, index: index, generation: generation)

            case .download(let metadata):
                if await download(metadata, scanner: scanner, provider: provider, index: index, generation: generation) { downloaded += 1 }

            case .restore(let metadata):
                if await download(metadata, scanner: scanner, provider: provider, index: index, generation: generation) {
                    downloaded += 1
                    addEvent(.info, file: metadata.relativePath,
                             message: "Brought back: it was deleted here but changed on another device")
                }

            case .merge(let localMeta, let remoteMeta):
                await merge(local: localMeta, remote: remoteMeta, scanner: scanner, provider: provider, index: index, generation: generation)

            case .writeTombstone(let tombstone):
                do {
                    try await provider.writeTombstone(tombstone)
                    guard canContinueTransfer(generation: generation) else { return }
                    await index.markDeleted(path: tombstone.relativePath, at: now)
                    guard canContinueTransfer(generation: generation) else { return }
                    addEvent(.info, file: tombstone.relativePath, message: "Deleted on your other devices too")
                } catch {
                    addEvent(.error, file: tombstone.relativePath,
                             message: "Could not propagate delete: \(error.localizedDescription)")
                }

            case .trashLocal(let metadata, let tombstone):
                do {
                    _ = try await withLocalIO(generation: generation) {
                        try await scanner.moveToTrash(relativePath: metadata.relativePath, trash: trash, now: now)
                    }
                    try requireTransferAccess(generation: generation)
                    await index.markDeleted(path: metadata.relativePath, at: tombstone.deletedAt)
                    guard canContinueTransfer(generation: generation) else { return }
                    metadataCache.removeValue(forKey: metadata.relativePath)
                    addEvent(.info, file: metadata.relativePath,
                             message: "Removed because it was deleted on another device. Recoverable in Recently Deleted for 30 days")
                } catch {
                    addEvent(.error, file: metadata.relativePath,
                             message: "Could not remove: \(error.localizedDescription)")
                }

            case .markDeleted(let relativePath):
                await index.markDeleted(path: relativePath, at: now)
                guard canContinueTransfer(generation: generation) else { return }

            case .conflict(let conflict):
                recordConflict(conflict)
            }
        }

        guard canContinueTransfer(generation: generation) else { return }
        do {
            try await index.save()
            guard canContinueTransfer(generation: generation) else { return }
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

    func recordConflict(_ conflict: SyncConflict) {
        guard Self.isEligibleForCloudSync(relativePath: conflict.metadata.relativePath) else { return }
        let existing = pendingConflicts.firstIndex { $0.metadata.relativePath == conflict.metadata.relativePath }
        if let existing {
            let previous = pendingConflicts[existing]
            if previous.kind != conflict.kind || previous.localVersion != conflict.localVersion ||
                previous.remoteVersion != conflict.remoteVersion {
                pendingConflicts[existing] = conflict
            }
        } else {
            pendingConflicts.append(conflict)
            addEvent(.conflict, file: conflict.metadata.relativePath, message: Self.message(for: conflict.kind))
        }
        var metadata = conflict.metadata
        metadata.syncStatus = .conflict
        metadataCache[metadata.relativePath] = metadata
    }

    private static func message(for kind: SyncConflict.Kind) -> String {
        switch kind {
        case .bothChanged: return "Changed on two devices at once"
        case .deletedRemotelyChangedLocally: return "Deleted on another device, but changed here"
        }
    }

    @discardableResult
    private func upload(
        _ metadata: SyncableFileMetadata,
        reason: SyncPlanStep.UploadReason,
        scanner: UserDataScanner,
        provider: any SyncProvider,
        index: SyncIndexStore,
        generation requestedGeneration: TransferEpoch? = nil
    ) async -> Bool {
        guard Self.isEligibleForCloudSync(relativePath: metadata.relativePath) else { return false }
        let generation = requestedGeneration ?? captureTransferEpoch()
        var working = metadata
        working.syncStatus = .uploading
        metadataCache[working.relativePath] = working
        do {
            let data = try await withLocalIO(generation: generation) {
                try await scanner.readFile(relativePath: metadata.relativePath)
            }
            try requireTransferAccess(generation: generation)
            try await provider.upload(metadata: metadata, data: data)
            try requireTransferAccess(generation: generation)
            working.syncStatus = .synced
            working.lastSyncDate = Date()
            working.lastError = nil
            metadataCache[working.relativePath] = working
            await index.record(path: metadata.relativePath, checksum: metadata.checksum, lastModified: metadata.lastModified)
            addEvent(.upload, file: metadata.relativePath, message: "Uploaded (\(reason.rawValue))")
            return true
        } catch is TransferDeferred {
            return false
        } catch {
            guard generation.policy == transferGeneration && generation.boot == localIOGate.currentGeneration, isEnabled else { return false }
            working.syncStatus = .error
            working.lastError = error.localizedDescription
            working.syncAttempts += 1
            metadataCache[working.relativePath] = working
            addEvent(.error, file: metadata.relativePath,
                     message: "Upload failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Returns true only after committing the downloaded file and recording its actual metadata.
    @discardableResult
    private func download(
        _ metadata: SyncableFileMetadata,
        scanner: UserDataScanner,
        provider: any SyncProvider,
        index: SyncIndexStore,
        userSelectedRemote: Bool = false,
        generation requestedGeneration: TransferEpoch? = nil
    ) async -> Bool {
        guard Self.isEligibleForCloudSync(relativePath: metadata.relativePath) else { return false }
        let generation = requestedGeneration ?? captureTransferEpoch()
        var working = metadata
        working.syncStatus = .downloading
        metadataCache[working.relativePath] = working
        do {
            if !userSelectedRemote,
               let localModified = await scanner.modificationDate(relativePath: metadata.relativePath),
               localModified > metadata.lastModified.addingTimeInterval(CloudSyncConstants.modificationTimeTolerance) {
                return false
            }
            try requireTransferAccess(generation: generation)
            let data = try await provider.download(metadata: metadata)
            guard !data.isEmpty else { throw SyncProviderError.invalidData }
            try await withLocalIO(generation: generation) {
                try await scanner.writeFile(relativePath: metadata.relativePath, data: data,
                                            modificationDate: metadata.lastModified)
            }
            try requireTransferAccess(generation: generation)
            working.syncStatus = .synced
            working.lastSyncDate = Date()
            working.lastError = nil
            metadataCache[working.relativePath] = working
            await index.record(path: metadata.relativePath, checksum: metadata.checksum, lastModified: metadata.lastModified)
            addEvent(.download, file: metadata.relativePath, message: "Downloaded from iCloud")
            notifyIfDocument(metadata.fileType)
            return true
        } catch is TransferDeferred {
            return false
        } catch {
            guard generation.policy == transferGeneration && generation.boot == localIOGate.currentGeneration, isEnabled else { return false }
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
        index: SyncIndexStore,
        generation requestedGeneration: TransferEpoch? = nil
    ) async {
        guard Self.isEligibleForCloudSync(relativePath: local.relativePath),
              Self.isEligibleForCloudSync(relativePath: remote.relativePath) else { return }
        let generation = requestedGeneration ?? captureTransferEpoch()
        guard let merger = DocumentMergers.merger(for: local.fileType) else {
            // Should not happen: the planner only emits .merge for document kinds.
            if local.lastModified >= remote.lastModified {
                await upload(local, reason: .contentChanged, scanner: scanner, provider: provider, index: index, generation: generation)
            } else {
                await download(remote, scanner: scanner, provider: provider, index: index, generation: generation)
            }
            return
        }

        let path = local.relativePath
        do {
            let localData = try await withLocalIO(generation: generation) {
                try await scanner.readFile(relativePath: path)
            }
            let remoteData = try await provider.download(metadata: remote)
            try requireTransferAccess(generation: generation)
            let merged: Data
            do {
                merged = try merger.merge(local: localData, remote: remoteData)
            } catch {
                addEvent(.error, file: path, message: "Could not merge; keeping the newer copy (\(error.localizedDescription))")
                if local.lastModified >= remote.lastModified {
                    await upload(local, reason: .contentChanged, scanner: scanner, provider: provider, index: index, generation: generation)
                } else {
                    await download(remote, scanner: scanner, provider: provider, index: index, generation: generation)
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
                try await withLocalIO(generation: generation) {
                    try await scanner.writeFile(relativePath: path, data: merged, modificationDate: now)
                }
            }
            try requireTransferAccess(generation: generation)
            if merged != remoteData {
                try await provider.upload(metadata: result, data: merged)
            }
            try requireTransferAccess(generation: generation)
            metadataCache[path] = result
            await index.record(path: path, checksum: result.checksum, lastModified: now, syncedAt: now)
            addEvent(.info, file: path, message: localChanged ? "Merged changes from another device" : "Merged this device's changes into iCloud")
            if localChanged { notifyIfDocument(local.fileType) }
        } catch is TransferDeferred {
            return
        } catch {
            guard canContinueTransfer(generation: generation) else { return }
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

    @discardableResult
    func resolve(_ conflict: SyncConflict, as resolution: ConflictResolution) async -> SyncConflictResolutionResult {
        guard Self.isEligibleForCloudSync(relativePath: conflict.metadata.relativePath) else {
            pendingConflicts.removeAll { !Self.isEligibleForCloudSync(relativePath: $0.metadata.relativePath) }
            metadataCache.removeValue(forKey: conflict.metadata.relativePath)
            refreshStatistics()
            return .deferred(L("The conflict could not be resolved. Review its latest versions and try again."))
        }
        if let reason = conflictResolutionUnavailableReason { return .deferred(reason) }
        let failure = L("The conflict could not be resolved. Review its latest versions and try again.")
        guard let scanner, let provider, let index, let trash,
              !isSyncing, !isResolvingConflict,
              pendingConflicts.contains(where: { $0.id == conflict.id }) else { return .deferred(failure) }
        let generation = captureTransferEpoch()
        do { try requireTransferAccess(generation: generation) }
        catch { return .deferred(conflictResolutionUnavailableReason ?? failure) }
        isResolvingConflict = true
        defer { isResolvingConflict = false }
        let succeeded: Bool
        switch (conflict.kind, resolution) {
        case (.bothChanged, .useLocal):
            succeeded = await upload(conflict.metadata, reason: .conflictKeepLocal, scanner: scanner, provider: provider, index: index, generation: generation)
        case (.bothChanged, .useRemote):
            succeeded = await download(Self.remoteMetadata(for: conflict), scanner: scanner,
                                       provider: provider, index: index, userSelectedRemote: true, generation: generation)
        case (.bothChanged, .keepBoth):
            succeeded = await keepBoth(conflict, scanner: scanner, provider: provider, index: index, generation: generation)
        case (.deletedRemotelyChangedLocally, .useLocal), (.deletedRemotelyChangedLocally, .keepBoth):
            succeeded = await upload(conflict.metadata, reason: .undelete, scanner: scanner, provider: provider, index: index, generation: generation)
        case (.deletedRemotelyChangedLocally, .useRemote):
            do {
                _ = try await withLocalIO(generation: generation) {
                    try await scanner.moveToTrash(relativePath: conflict.metadata.relativePath, trash: trash)
                }
                try requireTransferAccess(generation: generation)
                await index.markDeleted(path: conflict.metadata.relativePath)
                metadataCache.removeValue(forKey: conflict.metadata.relativePath)
                addEvent(.info, file: conflict.metadata.relativePath, message: "Removed. Recoverable in Recently Deleted for 30 days")
                await refreshTrash()
                succeeded = true
            } catch is TransferDeferred {
                succeeded = false
            } catch {
                addEvent(.error, file: conflict.metadata.relativePath, message: "Could not remove: \(error.localizedDescription)")
                succeeded = false
            }
        case (_, .manual):
            return .deferred(failure)
        }
        guard succeeded else {
            if let reason = conflictResolutionUnavailableReason, isEmulating || !isEnabled {
                return .deferred(reason)
            }
            return .failed(metadataCache[conflict.metadata.relativePath]?.lastError ?? failure)
        }
        do {
            try requireTransferAccess(generation: generation)
            try await index.save()
            try requireTransferAccess(generation: generation)
            pendingConflicts.removeAll { $0.id == conflict.id }
            refreshStatistics()
            return .resolved
        } catch is TransferDeferred {
            return .deferred(conflictResolutionUnavailableReason ?? failure)
        } catch {
            addEvent(.error, file: conflict.metadata.relativePath,
                     message: "Could not save the sync index: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    private static func remoteMetadata(for conflict: SyncConflict) -> SyncableFileMetadata {
        var remote = conflict.metadata
        remote.lastModified = conflict.remoteVersion.modifiedDate
        remote.fileSize = conflict.remoteVersion.size
        remote.checksum = conflict.remoteVersion.checksum
        // Conflict.metadata is the local version; use the stable path for the remote lookup.
        remote.cloudKitRecordID = nil
        return remote
    }

    /// Preserve the local copy before taking the explicitly selected remote version.
    private func keepBoth(
        _ conflict: SyncConflict,
        scanner: UserDataScanner,
        provider: any SyncProvider,
        index: SyncIndexStore,
        generation requestedGeneration: TransferEpoch? = nil
    ) async -> Bool {
        guard Self.isEligibleForCloudSync(relativePath: conflict.metadata.relativePath) else { return false }
        let generation = requestedGeneration ?? captureTransferEpoch()
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
            let localData = try await withLocalIO(generation: generation) {
                try await scanner.readFile(relativePath: relativePath)
            }
            try await withLocalIO(generation: generation) {
                try await scanner.writeFile(relativePath: copyPath, data: localData, modificationDate: nil)
            }
            guard await download(Self.remoteMetadata(for: conflict), scanner: scanner, provider: provider,
                                 index: index, userSelectedRemote: true, generation: generation) else { return false }
            addEvent(.info, file: relativePath, message: "Kept both (this device's copy saved as \(copyName))")
            return true
        } catch is TransferDeferred {
            return false
        } catch {
            addEvent(.error, file: relativePath, message: "Could not keep both: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func resolveAllConflicts(as resolution: ConflictResolution) async -> SyncConflictResolutionResult {
        var result = SyncConflictResolutionResult.resolved
        for conflict in pendingConflicts {
            let outcome = await resolve(conflict, as: resolution)
            if outcome.message != nil { result = outcome }
            if conflictResolutionUnavailableReason != nil { break }
        }
        return result
    }

    // MARK: - Recently Deleted

    func refreshTrash() async {
        guard let trash else { return }
        trashEntries = await trash.entries()
    }

    /// Put a trashed file back. It is stamped now, so the next run reads it as
    /// an undelete and uploads it, replacing the tombstone everywhere.
    func restoreFromTrash(_ entry: SyncTrashEntry) async {
        guard !isRestoringTrash, !isSyncing, !isResolvingConflict,
              let trash, let root = recoveryRoot, let recoveryIndex else { return }
        let bootGeneration = localIOGate.currentGeneration
        guard !Task.isCancelled, !localIOGate.isEmulating,
              localIOGate.beginLocalIO(generation: bootGeneration) else { return }
        isRestoringTrash = true
        // Keep the lease and defer lifecycle starts until the durable undelete is complete.
        // A disabled sync still has its index: forgetting the old tombstone is local recovery.
        do {
            await recoveryIndex.remove(path: entry.relativePath)
            try await recoveryIndex.save()
            try await trash.restore(entry, into: root)
            addEvent(.info, file: entry.relativePath, message: "Restored from Recently Deleted")
            await refreshTrash()
            recoveryDeferredEvents.append(.trigger(.fileChanged))
        } catch {
            addEvent(.error, file: entry.relativePath, message: "Could not restore: \(error.localizedDescription)")
        }
        localIOGate.endLocalIO()
        isRestoringTrash = false
        let events = recoveryDeferredEvents
        recoveryDeferredEvents.removeAll()
        for event in events { await apply(event) }
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
        if let buildReason = CloudKitAvailability.buildLevelUnavailableReason(for: ICubeCloudSync.configuration) {
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
        for file in local where Self.isEligibleForCloudSync(relativePath: file.relativePath) {
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
