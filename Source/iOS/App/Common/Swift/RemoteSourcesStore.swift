import Combine
import Foundation

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
  private static let log = ICubeLog.logger("RemoteSourcesStore")
  static let shared = RemoteSourcesStore()

  var sources: [any RemoteLibrarySource] {
    coordinator.sources
  }

  /// Scanning state forwarded from coordinator
  var isScanning: Bool { coordinator.isScanning }
  var scanningProgress: Double { coordinator.scanningProgress }

  private let coordinator = RemoteSourcesCoordinator()
  private let defaultsKey = "RemoteSourcesStore.sources"
  private var cancellables = Set<AnyCancellable>()

  init() {
    Self.log.debug("RemoteSourcesStore: init() called")
    // Forward coordinator's objectWillChange to our own
    coordinator.objectWillChange
      .sink { [weak self] in
        self?.objectWillChange.send()
      }
      .store(in: &cancellables)

    Self.log.debug("RemoteSourcesStore: calling hydrate()")
    hydrate()
    Self.log.debug("RemoteSourcesStore: hydrate() completed, sources count: \(coordinator.sources.count)")
  }

  func addWebDAV(name: String, url: URL, username: String?, password: String?, recursive: Bool, interval: TimeInterval, startPath: String?, enablePreCaching: Bool = false) {
    let id = WebDAVSource.generateConsistentId(for: url)
    if let password = password {
      _ = KeychainService.setPassword(password, for: id)
    }
    let source = RemoteSourceFactory.webdavSource(
      id: id,
      name: name,
      url: url,
      username: username,
      password: password,
      recursive: recursive,
      interval: interval,
      startPath: startPath,
      enablePreCaching: enablePreCaching
    )
    coordinator.add(source: source)
    persist()
  }

  func remove(id: String) {
    KeychainService.deletePassword(for: id)
    coordinator.remove(id: id)
    persist()
  }

  private func hydrate() {
    Self.log.debug("RemoteSourcesStore: hydrate() starting")
    guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
      Self.log.debug("RemoteSourcesStore: no saved sources found in UserDefaults")
      return
    }
    guard let list = try? JSONDecoder().decode([PersistedSource].self, from: data) else {
      Self.log.error("RemoteSourcesStore: failed to decode saved sources")
      return
    }
    Self.log.debug("RemoteSourcesStore: found \(list.count) saved sources")
    for (index, p) in list.enumerated() {
      Self.log.debug("RemoteSourcesStore: loading source [\(index)]: \(p.name, privacy: .private) - \(p.url, privacy: .private)")
      guard let url = URL(string: p.url) else {
        Self.log.error("RemoteSourcesStore: invalid URL for source: \(p.url, privacy: .private)")
        continue
      }
      let password = KeychainService.getPassword(for: p.id)
      let src = RemoteSourceFactory.webdavSource(
        id: p.id,
        name: p.name,
        url: url,
        username: p.username,
        password: password,
        recursive: p.recursive,
        interval: p.interval,
        startPath: p.startPath,
        enablePreCaching: p.enablePreCaching
      )
      Self.log.debug("RemoteSourcesStore: adding source to coordinator: \(src.name, privacy: .private)")
      coordinator.add(source: src)
    }
    Self.log.debug("RemoteSourcesStore: hydrate() completed")
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
