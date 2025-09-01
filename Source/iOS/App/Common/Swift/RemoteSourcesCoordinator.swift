import Foundation
import Combine
import Network

/// Coordinates multiple remote sources and updates the Dolphin cache with their items.
@MainActor
class RemoteSourcesCoordinator: ObservableObject {
    @Published var sources: [any RemoteLibrarySource] = []
    @Published var lastItemsBySource: [String: [RemoteLibraryItem]] = [:]
    @Published var scanningProgressBySource: [String: Double] = [:]
    @Published var isScanning: Bool = false
    @Published var scanningProgress: Double = 0.0

    private var tasks: [String: [Task<Void, Never>]] = [:]
    private var lastUpdateTime: Date = .distantPast
    private let updateThrottleInterval: TimeInterval = 0.5 // Minimum 0.5 seconds between updates

    // Reachability (nonisolated backing)
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "net.dolphinios.remotesources.reachability")
    private var lastPathSatisfied: Bool = false

    init() {
        // Listen for refresh requests - clear caches and fetch fresh directory listings
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("RefreshRemoteSources"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            print("DEBUG REFRESH: RefreshRemoteSources notification received - clearing caches and rescanning")
            Task { @MainActor in
                self.clearCachesAndRefresh()
            }
        }

        // Start reachability monitoring
        pathMonitor.pathUpdateHandler = { @MainActor [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied

            // Capture current state to avoid main actor isolation issues
            let wasOffline = !self.lastPathSatisfied
            let wasOnline = self.lastPathSatisfied

            if satisfied && wasOffline {
                DispatchQueue.main.async {
                    self.lastPathSatisfied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                        print("Reachability: Online detected, refreshing remote sources")
                        self.clearCachesAndRefresh()
                        NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Back online — refreshing library…")])
                    }
                }
            } else if !satisfied && wasOnline {
                DispatchQueue.main.async {
                    self.lastPathSatisfied = false
                    NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Offline — some sources unavailable")])
                }
            }
        }
        pathMonitor.start(queue: pathQueue)
    }

    func add(source: any RemoteLibrarySource) {
        print("RemoteSourcesCoordinator: adding source \(source.id) (\(source.name))")

        // Check if we already have this source
        if sources.contains(where: { $0.id == source.id }) {
            print("RemoteSourcesCoordinator: source \(source.id) already exists, updating and restarting")
            // Replace existing instance reference to avoid duplicates in array
            sources.removeAll { $0.id == source.id }
            sources.append(source)
            start(source: source)
            return
        }

        // Also check for duplicates by normalized URL and name (handles regenerated IDs)
        if let webdav = source as? WebDAVSource {
            let newRoot = webdav.rootURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            if sources.contains(where: { s in
                guard let w = s as? WebDAVSource else { return false }
                let existingRoot = w.rootURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
                return existingRoot == newRoot && w.name.caseInsensitiveCompare(webdav.name) == .orderedSame
            }) {
                print("RemoteSourcesCoordinator: duplicate WebDAV source detected for root=\(newRoot); restarting existing")
                // Restart the existing one; do not append a new one
                if let existing = sources.first(where: { ($0 as? WebDAVSource)?.rootURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == newRoot }) {
                    start(source: existing)
                }
                return
            }
        }

        sources.append(source)
        print("RemoteSourcesCoordinator: total sources now: \(sources.count)")
        start(source: source)
        print("RemoteSourcesCoordinator: source \(source.id) added and started")
    }

    func remove(id: String) {
        stop(sourceId: id)

        // Clean up cached files for WebDAV sources
        if let webdavSource = sources.first(where: { $0.id == id }) as? WebDAVSource {
            Task {
                try? await webdavSource.clearCache()
            }
        }

        sources.removeAll { $0.id == id }
        lastItemsBySource.removeValue(forKey: id)

        // Remove from factory to clean up singleton instance
        RemoteSourceFactory.removeSource(id: id)

        pushCacheUpdate(forceUpdate: true) // Force update to clean up games from deleted source
    }

        private func start(source: any RemoteLibrarySource) {
        print("RemoteSourcesCoordinator: starting source \(source.id) (\(source.name))")

        // Stop any existing tasks for this source to prevent conflicts
        if let existingTasks = tasks[source.id] {
            print("RemoteSourcesCoordinator: stopping existing tasks for source \(source.id)")
            for task in existingTasks {
                task.cancel()
            }
            tasks[source.id] = nil
        }

        // Start the source FIRST so fresh streams are created
        source.start()
        print("RemoteSourcesCoordinator: source \(source.id) start() called, now creating tasks for fresh streams")

        let onlineTask = Task {
            for await isOnline in source.onlineStream {
                print("RemoteSourcesCoordinator: source \(source.id) online status changed to \(isOnline)")
                await MainActor.run {
                    // Trigger UI update when online status changes
                    self.objectWillChange.send()
                    pushCacheUpdate()
                }
            }
        }

        let itemsTask = Task {
            print("DEBUG COORDINATOR: Starting NEW items task for source \(source.id), stream=\(source.itemsStream)")
            print("DEBUG COORDINATOR: About to iterate over itemsStream for source \(source.id)")
            for await items in source.itemsStream {
                print("DEBUG COORDINATOR: *** RECEIVED \(items.count) ITEMS FROM SOURCE \(source.id) ***")
                for (index, item) in items.enumerated() {
                    print("DEBUG COORDINATOR:   [\(index)]: \(item.url.absoluteString)")
                }
                                    await MainActor.run {
                        print("DEBUG COORDINATOR: Setting lastItemsBySource[\(source.id)] = \(items.count) items")
                        lastItemsBySource[source.id] = items
                        print("DEBUG COORDINATOR: About to call pushCacheUpdate()")

                        // Force immediate cache update for better UX - don't wait for throttling
                        pushCacheUpdate(forceUpdate: true)
                        print("DEBUG COORDINATOR: pushCacheUpdate() completed")

                        // Trigger UI reload after WebDAV update for better UX
                        NotificationCenter.default.post(name: NSNotification.Name("RemoteLibraryUpdated"), object: nil)
                        print("DEBUG COORDINATOR: Posted RemoteLibraryUpdated notification")
                    }
            }
            print("DEBUG COORDINATOR: Items task ended normally (stream finished) for source \(source.id)")
        }

        var progressTask: Task<Void, Never>?
        if let progressStream = source.scanningProgressStream {
            progressTask = Task { [weak self] in
                guard let self else { return }
                for await p in progressStream {
                    await MainActor.run {
                        self.scanningProgressBySource[source.id] = p
                        // Compute aggregate progress as mean of active sources with entries
                        let values = Array(self.scanningProgressBySource.values)
                        if !values.isEmpty {
                            self.scanningProgress = values.reduce(0, +) / Double(values.count)
                            self.isScanning = self.scanningProgress < 1.0
                        } else {
                            self.scanningProgress = 0
                            self.isScanning = false
                        }
                    }
                }
                await MainActor.run {
                    self.scanningProgressBySource[source.id] = 1.0
                    let values = Array(self.scanningProgressBySource.values)
                    if !values.isEmpty {
                        self.scanningProgress = values.reduce(0, +) / Double(values.count)
                        self.isScanning = self.scanningProgress < 1.0
                    } else {
                        self.scanningProgress = 0
                        self.isScanning = false
                    }
                }
            }
        }

        tasks[source.id] = [onlineTask, itemsTask].compactMap { $0 } + (progressTask != nil ? [progressTask!] : [])
        print("RemoteSourcesCoordinator: tasks created and stored for source \(source.id)")
    }

    private func stop(sourceId: String) {
        if let source = sources.first(where: { $0.id == sourceId }) {
            source.stop()
        }
        tasks[sourceId]?.forEach { $0.cancel() }
        tasks[sourceId] = nil
        scanningProgressBySource.removeValue(forKey: sourceId)
        let values = Array(scanningProgressBySource.values)
        if !values.isEmpty {
            scanningProgress = values.reduce(0, +) / Double(values.count)
            isScanning = scanningProgress < 1.0
        } else {
            scanningProgress = 0
            isScanning = false
        }
    }

    /// Clear cached directory listings and force fresh scans from all sources
    private func clearCachesAndRefresh() {
        print("DEBUG REFRESH: Clearing lastItemsBySource cache (had \(lastItemsBySource.count) sources)")
        lastItemsBySource.removeAll() // Clear cached directory listings

        print("DEBUG REFRESH: Restarting all \(sources.count) sources to fetch fresh listings")
        for source in sources {
            print("DEBUG REFRESH: Restarting source \(source.id) (\(source.name))")
            stop(sourceId: source.id) // Stop existing tasks
            start(source: source)     // Start fresh scan
        }
    }

    private func pushCacheUpdate(forceUpdate: Bool = false) {
        print("DEBUG PUSH: pushCacheUpdate() called")
        print("DEBUG PUSH: lastItemsBySource has \(lastItemsBySource.count) sources")
        for (sourceId, items) in lastItemsBySource {
            print("DEBUG PUSH:   source \(sourceId): \(items.count) items")
        }

        // Build flattened list of URLs, converting WebDAV URLs to HTTP(S) with credentials
        var allUrls: [String] = []
        for (sourceId, items) in lastItemsBySource {
            guard let source = sources.first(where: { $0.id == sourceId }) else {
                print("DEBUG PUSH: WARNING - no matching source found for id=\(sourceId)")
                // Fallback: append raw URLs
                for item in items {
                    let s = item.url.absoluteString
                    if s.isEmpty { print("DEBUG PUSH: WARNING - empty URL for item=\(item)"); continue }
                    allUrls.append(s)
                }
                continue
            }

            if let webdav = source as? WebDAVSource {
                for item in items {
                    let converted = webdav.httpURL(for: item.url)
                    if converted.isEmpty { print("DEBUG PUSH: WARNING - empty converted URL for item=\(item)"); continue }
                    print("DEBUG PUSH: URL transform (WebDAV -> HTTP): \(item.url.absoluteString) -> \(converted)")
                    allUrls.append(converted)
                }
            } else {
                for item in items {
                    let s = item.url.absoluteString
                    if s.isEmpty { print("DEBUG PUSH: WARNING - empty URL for item=\(item)"); continue }
                    allUrls.append(s)
                }
            }
        }
        print("DEBUG PUSH: *** FLATTENED TO \(allUrls.count) TOTAL URLs (after filtering empty) ***")
        for (index, url) in allUrls.enumerated() {
            print("DEBUG PUSH:   [\(index)]: \(url)")
        }

        // Avoid nuking the cache with an empty remote list during startup/refresh
        guard !allUrls.isEmpty || forceUpdate else {
            print("DEBUG PUSH: Skipping updateLibrary because URL list is empty and not forced")
            return
        }

        print("DEBUG PUSH: Calling TVLibraryBridge.updateLibrary with \(allUrls.count) URLs")
        // Force metadata fetch for remote games to ensure artwork and database lookups work
        TVLibraryBridge.updateLibrary(withRemotePaths: allUrls, fetchMetadata: true)

        if forceUpdate && allUrls.isEmpty {
            print("DEBUG PUSH: *** FORCE UPDATE: Cleaned up library after source deletion ***")
        }

        print("DEBUG PUSH: TVLibraryBridge.updateLibrary completed")

        // Notify UI to refresh
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("RemoteLibraryUpdated"), object: nil)
        }
        print("DEBUG PUSH: pushCacheUpdate() finished")
    }

    private func refreshAllSources() {
        for source in sources {
            // Restart each source to trigger fresh enumeration
            stop(sourceId: source.id)
            start(source: source)
        }
    }
}
