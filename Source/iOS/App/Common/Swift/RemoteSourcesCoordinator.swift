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
            for await items in source.itemsStream {
                print("RemoteSourcesCoordinator: received \(items.count) items from source \(source.id)")
                for (index, item) in items.enumerated() {
                    print("  [\(index)]: \(item.url.absoluteString)")
                }
                await MainActor.run {
                    lastItemsBySource[source.id] = items
                    pushCacheUpdate()
                }
            }
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

    private func pushCacheUpdate() {
        let allUrls = lastItemsBySource.values.flatMap { $0 }.map { $0.url.absoluteString }
        print("RemoteSourcesCoordinator: updating cache with \(allUrls.count) URLs")
        for (index, url) in allUrls.enumerated() {
            print("  [\(index)]: \(url)")
        }

        // Force metadata fetch for remote games to ensure artwork and database lookups work
        TVLibraryBridge.updateLibrary(withRemotePaths: allUrls, fetchMetadata: true)

        // Notify UI to refresh
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("RemoteLibraryUpdated"), object: nil)
        }
    }

    private func refreshAllSources() {
        for source in sources {
            // Restart each source to trigger fresh enumeration
            stop(sourceId: source.id)
            start(source: source)
        }
    }
}
