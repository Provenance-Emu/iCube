import Foundation
import Combine

/// Coordinates multiple remote sources and updates the Dolphin cache with their items.
@MainActor
final class RemoteSourcesCoordinator: ObservableObject {
    @Published private(set) var sources: [RemoteLibrarySource] = []
    private var tasks: [String: [Task<Void, Never>]] = [:]
    private var lastItemsBySource: [String: [RemoteLibraryItem]] = [:]

    /// Adds and starts a source
    func add(_ source: RemoteLibrarySource) {
        sources.append(source)
        start(source)
    }

    /// Removes and stops a source
    func remove(id: String) {
        guard let idx = sources.firstIndex(where: { $0.id == id }) else { return }
        let s = sources.remove(at: idx)
        stop(s)
        lastItemsBySource[id] = []
        pushCacheUpdate()
    }

    func start(_ source: RemoteLibrarySource) {
        source.start()
        var ts: [Task<Void, Never>] = []
        ts.append(Task { [weak self] in
            for await online in source.onlineStream {
                await MainActor.run {
                    if let self, !online { self.lastItemsBySource[source.id] = [] }
                }
                await self?.pushCacheUpdate()
            }
        })
        ts.append(Task { [weak self] in
            for await items in source.itemsStream {
                await MainActor.run {
                    if let self { self.lastItemsBySource[source.id] = items }
                }
                await self?.pushCacheUpdate()
            }
        })
        tasks[source.id] = ts
    }

    func stop(_ source: RemoteLibrarySource) {
        source.stop()
        tasks[source.id]?.forEach { $0.cancel() }
        tasks[source.id] = nil
    }

    private func pushCacheUpdate() {
        var urls: [String] = []
        for s in sources where s.isOnline {
            let items = lastItemsBySource[s.id] ?? []
            urls.append(contentsOf: items.map { $0.url.absoluteString })
        }
        TVLibraryBridge.updateLibrary(withRemotePaths: urls, fetchMetadata: true)
    }
}
