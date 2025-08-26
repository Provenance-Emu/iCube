import Foundation

/// Persisted source model for storage
private struct PersistedSource: Codable {
    let id: String
    let name: String
    let url: String
    let username: String?
    let recursive: Bool
    let interval: TimeInterval
}

/// Stores configured sources, persists them, and uses the coordinator to run them.
@MainActor
final class RemoteSourcesStore: ObservableObject {
    @Published private(set) var coordinator = RemoteSourcesCoordinator()
    @Published private(set) var sources: [RemoteLibrarySource] = []

    private let defaultsKey = "RemoteSourcesStore.sources"

    init() {
        hydrate()
    }

    func addWebDAV(name: String, url: URL, username: String?, password: String?, recursive: Bool, interval: TimeInterval) {
        let id = UUID().uuidString
        if let password, !password.isEmpty { _ = KeychainService.setPassword(password, for: id) }
        let src = WebDAVSource(id: id, name: name, url: url, username: username, password: password, recursive: recursive, interval: interval)
        sources.append(src)
        coordinator.add(src)
        persist()
    }

    func remove(id: String) {
        KeychainService.deletePassword(for: id)
        if let idx = sources.firstIndex(where: { $0.id == id }) {
            sources.remove(at: idx)
        }
        coordinator.remove(id: id)
        persist()
    }

    private func hydrate() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return }
        guard let list = try? JSONDecoder().decode([PersistedSource].self, from: data) else { return }
        for p in list {
            guard let url = URL(string: p.url) else { continue }
            let password = KeychainService.getPassword(for: p.id)
            let src = WebDAVSource(id: p.id, name: p.name, url: url, username: p.username, password: password, recursive: p.recursive, interval: p.interval)
            sources.append(src)
            coordinator.add(src)
        }
    }

    private func persist() {
        let list: [PersistedSource] = sources.compactMap { s in
            guard let s = s as? WebDAVSource else { return nil }
            return PersistedSource(id: s.id, name: s.name, url: s.baseURL.absoluteString, username: nil, recursive: true, interval: 900)
        }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
