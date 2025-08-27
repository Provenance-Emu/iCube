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
        // Listen for refresh requests
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("RefreshRemoteSources"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAllSources()
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
        sources.removeAll { $0.id == id }
        lastItemsBySource.removeValue(forKey: id)
        pushCacheUpdate()
    }

    private func start(source: any RemoteLibrarySource) {
        print("RemoteSourcesCoordinator: starting source \(source.id) (\(source.name))")
        print("RemoteSourcesCoordinator: existing tasks for this source: \(tasks[source.id]?.count ?? 0)")

        // Check if tasks already exist for this source and are still active
        if let existingTasks = tasks[source.id] {
            let activeTasks = existingTasks.filter { !$0.isCancelled }
            if !activeTasks.isEmpty {
                print("RemoteSourcesCoordinator: source \(source.id) already has \(activeTasks.count) active tasks, skipping start")
                return
            } else {
                print("RemoteSourcesCoordinator: source \(source.id) has cancelled tasks, cleaning up")
                tasks[source.id] = nil
            }
        }

        let onlineTask = Task {
            print("RemoteSourcesCoordinator: onlineTask started for source \(source.id)")
            do {
                for await isOnline in source.onlineStream {
                    print("RemoteSourcesCoordinator: source \(source.id) online status changed to \(isOnline)")
                    await MainActor.run {
                        // Trigger UI update when online status changes
                        self.objectWillChange.send()
                        // Schedule cache update on background thread
                        self.pushCacheUpdate()
                    }
                }
                print("RemoteSourcesCoordinator: onlineTask for await loop completed for source \(source.id)")
            } catch {
                print("RemoteSourcesCoordinator: onlineTask error for source \(source.id): \(error)")
            }
            print("RemoteSourcesCoordinator: onlineTask ended for source \(source.id)")
        }

        let itemsTask = Task {
            print("RemoteSourcesCoordinator: itemsTask started for source \(source.id)")
            do {
                for await items in source.itemsStream {
                    print("RemoteSourcesCoordinator: received \(items.count) items from source \(source.id)")
                    for (index, item) in items.enumerated() {
                        print("  [\(index)]: \(item.url.absoluteString)")
                    }
                    await MainActor.run {
                        print("RemoteSourcesCoordinator: storing \(items.count) items for source \(source.id)")
                        self.lastItemsBySource[source.id] = items
                        print("RemoteSourcesCoordinator: calling pushCacheUpdate() from itemsTask")
                        // Schedule cache update on background thread
                        self.pushCacheUpdate()
                    }
                }
                print("RemoteSourcesCoordinator: itemsTask for await loop completed for source \(source.id)")
            } catch {
                print("RemoteSourcesCoordinator: itemsTask error for source \(source.id): \(error)")
            }
            print("RemoteSourcesCoordinator: itemsTask ended for source \(source.id)")
        }

        tasks[source.id] = [onlineTask, itemsTask]
        print("RemoteSourcesCoordinator: tasks stored, calling source.start()")
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

    private func pushCacheUpdate() {
        // Capture the data we need on the main thread
        let sourcesCopy = sources
        let itemsBySourceCopy = lastItemsBySource

        // Do ALL the work on a background thread
        Task.detached {
            let allUrls = itemsBySourceCopy.values.flatMap { $0 }.map { $0.url.absoluteString }
            print("RemoteSourcesCoordinator: pushCacheUpdate() called")
            print("RemoteSourcesCoordinator: lastItemsBySource has \(itemsBySourceCopy.count) sources")
            for (sourceId, items) in itemsBySourceCopy {
                print("  Source \(sourceId): \(items.count) items")
                for (index, item) in items.enumerated() {
                    print("    [\(index)]: \(item.url.absoluteString)")
                }
            }
            print("RemoteSourcesCoordinator: updating cache with \(allUrls.count) URLs")
            for (index, url) in allUrls.enumerated() {
                print("  [\(index)]: \(url)")
            }

            // Don't update cache with empty URLs if we have sources that are still starting up
            if allUrls.isEmpty && !sourcesCopy.isEmpty {
                let onlineSources = sourcesCopy.filter { $0.isOnline }
                if !onlineSources.isEmpty {
                    print("RemoteSourcesCoordinator: skipping cache update - sources are online but no items received yet")
                    return
                }
            }

            // Force metadata fetch for remote games to ensure artwork and database lookups work
            TVLibraryBridge.updateLibrary(withRemotePaths: allUrls, fetchMetadata: true)

            // Notify UI to refresh (back on main thread)
            await MainActor.run {
                NotificationCenter.default.post(name: NSNotification.Name("RemoteLibraryUpdated"), object: nil)
            }
        }
    }

    private func refreshAllSources() {
        print("RemoteSourcesCoordinator: refreshAllSources() called")
        // Don't stop and restart sources - just trigger a refresh
        // The existing tasks will continue to run and receive new data
        for source in sources {
            print("RemoteSourcesCoordinator: triggering refresh for source \(source.id)")
            source.refresh()
        }
        // Force an immediate cache update with current data
        pushCacheUpdate()
    }
}
