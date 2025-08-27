import Foundation
import Combine

/// Coordinates multiple remote sources and updates the Dolphin cache with their items.
@MainActor
class RemoteSourcesCoordinator: ObservableObject {
    @Published var sources: [any RemoteLibrarySource] = []
    @Published var lastItemsBySource: [String: [RemoteLibraryItem]] = [:]

    private var tasks: [String: [Task<Void, Never>]] = [:]
    private var lastUpdateTime: Date = .distantPast
    private let updateThrottleInterval: TimeInterval = 2.0 // Minimum 2 seconds between updates

    init() {
        // Listen for refresh requests (do not restart sources; just push current cache state)
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("RefreshRemoteSources"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.pushCacheUpdate()
        }
    }

    func add(source: any RemoteLibrarySource) {
        print("RemoteSourcesCoordinator: adding source \(source.id) (\(source.name))")
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
            print("DEBUG COORDINATOR: Starting items task for source \(source.id)")
            for await items in source.itemsStream {
                print("DEBUG COORDINATOR: *** RECEIVED \(items.count) ITEMS FROM SOURCE \(source.id) ***")
                for (index, item) in items.enumerated() {
                    print("DEBUG COORDINATOR:   [\(index)]: \(item.url.absoluteString)")
                }
                await MainActor.run {
                    print("DEBUG COORDINATOR: Setting lastItemsBySource[\(source.id)] = \(items.count) items")
                    lastItemsBySource[source.id] = items
                    print("DEBUG COORDINATOR: About to call pushCacheUpdate()")
                    pushCacheUpdate()
                    print("DEBUG COORDINATOR: pushCacheUpdate() completed")
                }
            }
            print("DEBUG COORDINATOR: Items task ended for source \(source.id)")
        }

        tasks[source.id] = [onlineTask, itemsTask]
        source.start()
        print("RemoteSourcesCoordinator: source \(source.id) start() called")
    }

    private func stop(sourceId: String) {
        if let source = sources.first(where: { $0.id == sourceId }) {
            source.stop()
        }
        tasks[sourceId]?.forEach { $0.cancel() }
        tasks[sourceId] = nil
    }

    private func pushCacheUpdate(forceUpdate: Bool = false) {
        print("DEBUG PUSH: pushCacheUpdate() called")
        print("DEBUG PUSH: lastItemsBySource has \(lastItemsBySource.count) sources")
        for (sourceId, items) in lastItemsBySource {
            print("DEBUG PUSH:   source \(sourceId): \(items.count) items")
        }

        let allUrls = lastItemsBySource.values.flatMap { $0 }.map { $0.url.absoluteString }
        print("DEBUG PUSH: *** FLATTENED TO \(allUrls.count) TOTAL URLs ***")
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
