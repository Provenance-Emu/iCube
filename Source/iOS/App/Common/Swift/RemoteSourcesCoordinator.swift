import Combine
import Foundation
import Network

/// Coordinates multiple remote sources and updates the Dolphin cache with their items.
@MainActor
class RemoteSourcesCoordinator: ObservableObject {
  static let shared = RemoteSourcesCoordinator()
  static var isGlobalRefreshRunning: Bool = false
  @Published var sources: [any RemoteLibrarySource] = []
  @Published var lastItemsBySource: [String: [RemoteLibraryItem]] = [:]
  @Published var scanningProgressBySource: [String: Double] = [:]
  @Published var isScanning: Bool = false
  @Published var scanningProgress: Double = 0.0

  private var tasks: [String: [Task<Void, Never>]] = [:]
  private var lastUpdateTime: Date = .distantPast
  private let updateThrottleInterval: TimeInterval = 0.5 // Minimum 0.5 seconds between updates
  private var lastPushTime: Date = .distantPast
  private var lastPushedURLs: Set<String> = []
  private let debounceInterval: TimeInterval = 0.25
  private let smallDeltaThreshold: Int = 6
  private var firstScanStartTime: Date?

  // Reachability (nonisolated backing)
  private let pathMonitor = NWPathMonitor()
  private let pathQueue = DispatchQueue(label: "net.dolphinios.remotesources.reachability")
  private var lastPathSatisfied: Bool = false
  /// Avoid triggering an immediate duplicate refresh on cold boot when we were already online.
  private var suppressNextOnlineRefresh: Bool = true
  /// During cold boot, avoid clearing/rebuilding the library; write only after first full scan completes.
  private var suppressWritesUntilFirstScanComplete: Bool = true
  /// Tracks if system network is currently online; used to filter remote sources while offline.
  private var isSystemOnline: Bool = true

  // MARK: - Disk cache

  private var cacheDirURL: URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    let dir = base.appendingPathComponent("RemoteSourcesCache", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func cacheFileURL(for sourceId: String) -> URL {
    cacheDirURL.appendingPathComponent("\(sourceId).json")
  }

  private struct PersistedListing: Codable { let urls: [String] }
  private func loadCachedListing(for sourceId: String) -> [RemoteLibraryItem] {
    let url = cacheFileURL(for: sourceId)
    guard let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(PersistedListing.self, from: data) else { return [] }
    return decoded.urls.compactMap { s in
      guard let u = URL(string: s) else { return nil }
      return RemoteLibraryItem(url: u, displayName: u.lastPathComponent, sizeBytes: nil, etag: nil, lastModified: nil)
    }
  }

  private func saveCachedListing(for sourceId: String, items: [RemoteLibraryItem]) {
    let urls = items.map { $0.url.absoluteString }
    let payload = PersistedListing(urls: urls)
    if let data = try? JSONEncoder().encode(payload) {
      try? data.write(to: cacheFileURL(for: sourceId), options: .atomic)
    }
  }

  init() {
    // Listen for refresh requests - trigger in-place refresh on sources without resetting streams
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("RefreshRemoteSources"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      if Self.isGlobalRefreshRunning { print("DEBUG REFRESH: Global refresh already running; coalescing request")
        return
      }
      Self.isGlobalRefreshRunning = true
      print("DEBUG REFRESH: RefreshRemoteSources notification received - in-place refresh")
      for src in self.sources {
        if let w = src as? WebDAVSource {
          w.requestRefresh()
        } else {
          // For non-WebDAV, fall back to start() if needed
          src.start()
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Self.isGlobalRefreshRunning = false }
    }

    // Start reachability monitoring
    pathMonitor.pathUpdateHandler = { @MainActor [weak self] path in
      guard let self else { return }
      let satisfied = path.status == .satisfied

      // Capture current state to avoid main actor isolation issues
      let wasOffline = !self.lastPathSatisfied
      let wasOnline = self.lastPathSatisfied

      if satisfied, wasOffline {
        DispatchQueue.main.async {
          self.isSystemOnline = true
          // On cold boot, skip the first "back online" refresh to avoid duplicate scans.
          if self.suppressNextOnlineRefresh {
            print("Reachability: Online detected (initial). Suppressing first refresh.")
            self.lastPathSatisfied = true
            self.suppressNextOnlineRefresh = false
            // Rebuild union to re-include remote sources immediately
            self.pushCacheUpdate(forceUpdate: true)
            return
          }
          self.lastPathSatisfied = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            print("Reachability: Online detected, refreshing remote sources")
            for src in self.sources {
              if let w = src as? WebDAVSource { w.requestRefresh() }
            }
            // Rebuild union to include remote sources while new items stream in
            self.pushCacheUpdate(forceUpdate: true)
            NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Back online — refreshing library…")])
          }
        }
      } else if !satisfied, wasOnline {
        DispatchQueue.main.async {
          self.isSystemOnline = false
          self.lastPathSatisfied = false
          // Prune remote WebDAV items while offline
          self.pushCacheUpdate(forceUpdate: true)
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
      // Load cached listing for smoother UX
      let cached = loadCachedListing(for: source.id)
      if !cached.isEmpty { lastItemsBySource[source.id] = cached
        pushCacheUpdate()
      }
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
        print("RemoteSourcesCoordinator: duplicate WebDAV source detected for root=\(newRoot); requesting refresh on existing")
        if let existing = sources.first(where: { ($0 as? WebDAVSource)?.rootURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() == newRoot }) {
          (existing as? WebDAVSource)?.requestRefresh()
          let cached = loadCachedListing(for: existing.id)
          if !cached.isEmpty { lastItemsBySource[existing.id] = cached
            pushCacheUpdate()
          }
        }
        return
      }
    }

    sources.append(source)
    print("RemoteSourcesCoordinator: total sources now: \(sources.count)")
    start(source: source)
    print("RemoteSourcesCoordinator: source \(source.id) added and started")
    // Load cached listing immediately
    let cached = loadCachedListing(for: source.id)
    if !cached.isEmpty { lastItemsBySource[source.id] = cached
      pushCacheUpdate()
    }
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
    // Remove persisted listing
    try? FileManager.default.removeItem(at: cacheFileURL(for: id))
  }

  private func start(source: any RemoteLibrarySource) {
    print("RemoteSourcesCoordinator: starting source \(source.id) (\(source.name))")

    // Stop any existing tasks for this source to prevent conflicts
    if let existingTasks = tasks[source.id] {
      print("RemoteSourcesCoordinator: stopping existing tasks for source \(source.id)")
      for task in existingTasks { task.cancel() }
      tasks[source.id] = nil
    }

    // Start the source FIRST so fresh streams are created
    source.start()
    if firstScanStartTime == nil { firstScanStartTime = Date() }
    print("RemoteSourcesCoordinator: source \(source.id) start() called, now creating tasks for fresh streams")

    let onlineTask = Task {
      for await isOnline in source.onlineStream {
        print("RemoteSourcesCoordinator: source \(source.id) online status changed to \(isOnline)")
        await MainActor.run {
          self.objectWillChange.send()
        }
      }
    }

    let itemsTask = Task {
      print("DEBUG COORDINATOR: Starting NEW items task for source \(source.id), stream=\(source.itemsStream)")
      print("DEBUG COORDINATOR: About to iterate over itemsStream for source \(source.id)")
      for await items in source.itemsStream {
        print("DEBUG COORDINATOR: *** RECEIVED \(items.count) ITEMS FROM SOURCE \(source.id) ***")
        await MainActor.run {
          let prev = self.lastItemsBySource[source.id] ?? []
          let prevSet = Set(prev.map { $0.url.absoluteString })
          let newSet = Set(items.map { $0.url.absoluteString })
          let removed = prevSet.subtracting(newSet)
          let added = newSet.subtracting(prevSet)
          print("DEBUG COORDINATOR: source \(source.id) removed=\(removed.count), added=\(added.count)")

          // Guard: ignore empty emissions mid-scan to avoid flicker
          let progress = self.scanningProgressBySource[source.id] ?? 0.0
          if items.isEmpty && !prev.isEmpty && progress < 1.0 {
            print("DEBUG COORDINATOR: Ignoring empty emission mid-scan for \(source.id)")
            return
          }

          // Replace in-memory list with new snapshot (stable union across sources prevents full clear)
          self.lastItemsBySource[source.id] = items

          // Persist per-source for next launch
          self.saveCachedListing(for: source.id, items: items)

          // Push a full union update (without clearing other sources), debounced inside
          self.pushCacheUpdate()

          // Notify UI to soft refresh
          NotificationCenter.default.post(name: NSNotification.Name("RemoteLibraryUpdated"), object: nil)
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
            // Clamp to [0,1]
            let clamped = max(0.0, min(1.0, p))
            self.scanningProgressBySource[source.id] = clamped
            // Compute aggregate progress as mean of active sources with entries
            let values = Array(self.scanningProgressBySource.values)
            if !values.isEmpty {
              self.scanningProgress = values.reduce(0, +) / Double(values.count)
              self.isScanning = self.scanningProgress < 1.0
            } else {
              self.scanningProgress = 0
              self.isScanning = false
            }
            // When all sources report completion (>=1.0), lift first-scan suppression and commit
            let allDone = self.sources.allSatisfy { self.scanningProgressBySource[$0.id] ?? 1.0 >= 1.0 }
            if allDone && self.suppressWritesUntilFirstScanComplete {
              self.suppressWritesUntilFirstScanComplete = false
              self.pushCacheUpdate(forceUpdate: true)
            }
            // Safety: if first scan is taking too long, force a commit after 15s to avoid partial UI state
            if self.suppressWritesUntilFirstScanComplete, let start = self.firstScanStartTime, Date().timeIntervalSince(start) > 15 {
              print("DEBUG PUSH: Forcing commit due to slow first scan (>15s)")
              self.suppressWritesUntilFirstScanComplete = false
              self.pushCacheUpdate(forceUpdate: true)
            }
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

  /// Keep cached directory listings and force fresh scans from all sources (in-place)
  private func refreshAllSources() {
    print("DEBUG REFRESH: In-place refresh for all \(sources.count) sources")
    for source in sources {
      if let w = source as? WebDAVSource {
        w.requestRefresh()
      }
    }
    // Maintain current union in library until new items flow in
    pushCacheUpdate()
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
          if s.isEmpty { print("DEBUG PUSH: WARNING - empty URL for item=\(item)")
            continue
          }
          allUrls.append(s)
        }
        continue
      }

      // While offline, exclude WebDAV sources entirely from updates
      if !isSystemOnline, source is WebDAVSource {
        print("DEBUG PUSH: Skipping WebDAV source \(sourceId) due to offline state")
        continue
      }

      if let webdav = source as? WebDAVSource {
        for item in items {
          let converted = webdav.httpURL(for: item.url)
          if converted.isEmpty { print("DEBUG PUSH: WARNING - empty converted URL for item=\(item)")
            continue
          }
          print("DEBUG PUSH: URL transform (WebDAV -> HTTP): \(item.url.absoluteString) -> \(converted)")
          allUrls.append(converted)
        }
      } else {
        for item in items {
          let s = item.url.absoluteString
          if s.isEmpty { print("DEBUG PUSH: WARNING - empty URL for item=\(item)")
            continue
          }
          allUrls.append(s)
        }
      }
    }
    print("DEBUG PUSH: *** FLATTENED TO \(allUrls.count) TOTAL URLs (after filtering empty) ***")
    for (index, url) in allUrls.enumerated() {
      print("DEBUG PUSH:   [\(index)]: \(url)")
    }

    // During cold boot, avoid writing to the core cache until the first scan is complete
    if suppressWritesUntilFirstScanComplete && !forceUpdate {
      // Safety timeout: if we're stuck >15s since first scan start, allow a one-time forced write
      if let start = firstScanStartTime, Date().timeIntervalSince(start) > 15 {
        print("DEBUG PUSH: Overriding first-scan suppression due to timeout (>15s)")
      } else {
        print("DEBUG PUSH: Suppressing updateLibrary write until first scan completes; posting UI update only")
        DispatchQueue.main.async {
          NotificationCenter.default.post(name: NSNotification.Name("RemoteLibraryUpdated"), object: nil)
        }
        return
      }
    }

    // Avoid nuking the cache with an empty remote list during startup/refresh
    guard !allUrls.isEmpty || forceUpdate else {
      print("DEBUG PUSH: Skipping updateLibrary because URL list is empty and not forced")
      return
    }

    // Debounce small deltas to coalesce frequent updates
    let newSet = Set(allUrls)
    let added = newSet.subtracting(lastPushedURLs)
    let removed = lastPushedURLs.subtracting(newSet)
    let deltaCount = added.count + removed.count
    let elapsed = Date().timeIntervalSince(lastPushTime)
    if !forceUpdate, deltaCount <= smallDeltaThreshold, elapsed < debounceInterval {
      print("DEBUG PUSH: Debounced small delta (\(deltaCount)) within \(elapsed)s")
      return
    }

    print("DEBUG PUSH: Calling TVLibraryBridge.updateLibrary with \(allUrls.count) URLs")
    // Force metadata fetch for remote games to ensure artwork and database lookups work
    TVLibraryBridge.updateLibrary(withRemotePaths: allUrls, fetchMetadata: true)

    if forceUpdate, allUrls.isEmpty {
      print("DEBUG PUSH: *** FORCE UPDATE: Cleaned up library after source deletion ***")
    }

    print("DEBUG PUSH: TVLibraryBridge.updateLibrary completed")

    // Notify UI to refresh
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: NSNotification.Name("RemoteLibraryUpdated"), object: nil)
    }
    print("DEBUG PUSH: pushCacheUpdate() finished")

    // Update debounce state
    lastPushedURLs = newSet
    lastPushTime = Date()
    // After the first successful push, allow future back-online refreshes
    suppressNextOnlineRefresh = false
  }
}

@MainActor
/// Centralizes library updates across local and remote (WebDAV) sources and publishes the current game list.
final class LibraryCoordinator: ObservableObject {
  static let shared = LibraryCoordinator()

  /// Current list of games after merging local cache and remote entries
  @Published private(set) var games: [TVGameItem] = []
  /// True while a refresh is running
  @Published private(set) var isUpdating: Bool = false

  private var cancellables = Set<AnyCancellable>()
  private let reloadSubject = PassthroughSubject<Void, Never>()

  private init() {
    NotificationCenter.default.publisher(for: NSNotification.Name("RemoteLibraryUpdated"))
      .sink { [weak self] _ in
        #if DEBUG
        print("LibraryCoordinator: RemoteLibraryUpdated notification received")
        #endif
        self?.triggerReload()
      }
      .store(in: &cancellables)

    reloadSubject
      .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
      .sink { [weak self] in
        guard let self else { return }
        #if DEBUG
        print("LibraryCoordinator: Debounced reload executing loadCurrent()")
        #endif
        self.loadCurrent()
      }
      .store(in: &cancellables)
  }

  /// Starts the coordinator and loads the current game list immediately
  func start() {
    loadCurrent()
  }

  /// Refreshes only local files and metadata, leaving remote streams intact
  func refreshLocal(completion: (() -> Void)? = nil) {
    isUpdating = true
    TVLibraryBridge.rescanLocalAndFetchMetadata { [weak self] in
      Task { @MainActor in
        self?.isUpdating = false
        self?.triggerReload()
        completion?()
      }
    }
  }

  /// Triggers remote WebDAV refresh and a local rescan; debounced updates are published to subscribers
  func refreshAll(completion: (() -> Void)? = nil) {
    isUpdating = true
    NotificationCenter.default.post(name: NSNotification.Name("RefreshRemoteSources"), object: nil)
    TVLibraryBridge.rescanLocalAndFetchMetadata { [weak self] in
      Task { @MainActor in
        self?.isUpdating = false
        self?.triggerReload()
        NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Library refreshed")])
        completion?()
      }
    }
  }

  private func triggerReload() {
    #if DEBUG
    print("LibraryCoordinator.triggerReload(): Triggering reload")
    #endif
    reloadSubject.send(())
  }

  private func loadCurrent() {
    let items = TVLibraryBridge.currentGames()
    games = items
  }
}
