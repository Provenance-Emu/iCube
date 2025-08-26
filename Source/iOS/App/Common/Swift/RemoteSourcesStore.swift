import Foundation
import Combine

/// Persisted source model for storage
private struct PersistedSource: Codable {
    let id: String
    let name: String
    let url: String
    let username: String?
    let recursive: Bool
    let interval: TimeInterval
    let startPath: String?
    let enablePreCaching: Bool // New option
}

/// Stores configured sources, persists them, and uses the coordinator to run them.
@MainActor
class RemoteSourcesStore: ObservableObject {
    /// Shared singleton instance that starts automatically
    static let shared = RemoteSourcesStore()

    var sources: [any RemoteLibrarySource] {
        coordinator.sources
    }

    private let coordinator = RemoteSourcesCoordinator()
    private let defaultsKey = "RemoteSourcesStore.sources"
    private var cancellables = Set<AnyCancellable>()

    init() {
        print("RemoteSourcesStore: init() called")
        // Forward coordinator's objectWillChange to our own
        coordinator.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        print("RemoteSourcesStore: calling hydrate()")
        hydrate()
        print("RemoteSourcesStore: hydrate() completed, sources count: \(coordinator.sources.count)")
    }

    func addWebDAV(name: String, url: URL, username: String?, password: String?, recursive: Bool, interval: TimeInterval, startPath: String?, enablePreCaching: Bool = false) {
        let id = UUID().uuidString
        if let password = password {
            KeychainService.setPassword(password, for: id)
        }
        let source = WebDAVSource(id: id, name: name, url: url, username: username, password: password, recursive: recursive, interval: interval, startPath: startPath, enablePreCaching: enablePreCaching)
        coordinator.add(source: source)
        persist()
    }

    func remove(id: String) {
        KeychainService.deletePassword(for: id)
        coordinator.remove(id: id)
        persist()
    }

    private func hydrate() {
        print("RemoteSourcesStore: hydrate() starting")
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            print("RemoteSourcesStore: no saved sources found in UserDefaults")
            return
        }
        guard let list = try? JSONDecoder().decode([PersistedSource].self, from: data) else {
            print("RemoteSourcesStore: failed to decode saved sources")
            return
        }
        print("RemoteSourcesStore: found \(list.count) saved sources")
        for (index, p) in list.enumerated() {
            print("RemoteSourcesStore: loading source [\(index)]: \(p.name) - \(p.url)")
            guard let url = URL(string: p.url) else {
                print("RemoteSourcesStore: invalid URL for source: \(p.url)")
                continue
            }
            let password = KeychainService.getPassword(for: p.id)
            let src = WebDAVSource(id: p.id, name: p.name, url: url, username: p.username, password: password, recursive: p.recursive, interval: p.interval, startPath: p.startPath, enablePreCaching: p.enablePreCaching)
            print("RemoteSourcesStore: adding source to coordinator: \(src.name)")
            coordinator.add(source: src)
        }
        print("RemoteSourcesStore: hydrate() completed")
    }

    private func persist() {
        let list: [PersistedSource] = coordinator.sources.compactMap { s in
            guard let s = s as? WebDAVSource else { return nil }
            return PersistedSource(
                id: s.id,
                name: s.name,
                url: s.baseURL.absoluteString,
                username: s.userName,
                recursive: s.isRecursive,
                interval: s.refreshInterval,
                startPath: s.startPathComponent,
                enablePreCaching: s.enablePreCaching
            )
        }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
