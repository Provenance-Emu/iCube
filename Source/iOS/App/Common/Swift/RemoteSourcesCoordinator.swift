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
  /// Bumped on every real path transition; a delayed follow-up that finds it changed has been superseded.
  private var pathGeneration = 0
  /// How long a regained network settles before WebDAV is relisted.
  var onlineSettleDelay: TimeInterval = 0.75
  /// Avoid triggering an immediate duplicate refresh on cold boot when we were already online.
  private var suppressNextOnlineRefresh: Bool = true
  /// During cold boot, avoid clearing/rebuilding the library; write only after first full scan completes.
  private var suppressWritesUntilFirstScanComplete: Bool = true
  /// Tracks if system network is currently online; used to filter remote sources while offline.
  private var isSystemOnline: Bool = true

  // MARK: - Emulation deferral

  /// Whether a game is running. While one is, nothing here may walk the Software folder or rewrite
  /// the game cache: a Wi-Fi flap used to do both, mid-game.
  private let isEmulationActive: @MainActor () -> Bool
  /// Pushes the flattened URL list into the game cache. Injectable so tests can count pushes.
  private let pushToLibrary: ([String]) -> Void
  /// A push was requested while emulation was active; it runs once, when the session ends.
  private(set) var needsPush = false
  /// The deferred push includes a forced one (an offline/online transition or a source removal).
  private var deferredPushWasForced = false
  /// WebDAV sources need a fresh listing once the session ends (the network came back mid-game).
  private var needsSourceRefresh = false
  /// The deferred push must also clean up after a removed source (it bypasses the no-sources skip).
  private var deferredPushWasCleanup = false

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

  init(
    startPathMonitor: Bool = true,
    emulationState: EmulationState? = nil,
    pushToLibrary: @escaping ([String]) -> Void = { urls in
      // Force metadata fetch for remote games to ensure artwork and database lookups work
      TVLibraryBridge.updateLibrary(withRemotePaths: urls, fetchMetadata: true)
    }
  ) {
    let state = emulationState ?? .shared
    self.isEmulationActive = { state.isActive }
    self.pushToLibrary = pushToLibrary
    state.addTransitionHandler { [weak self] active in
      if !active { self?.emulationDidEnd() }
    }

    // Listen for refresh requests - trigger in-place refresh on sources without resetting streams
    NotificationCenter.default.addObserver(
      forName: NSNotification.Name("RefreshRemoteSources"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        if Self.isGlobalRefreshRunning {
          print("DEBUG REFRESH: Global refresh already running; coalescing request")
          return
        }
        Self.isGlobalRefreshRunning = true
        print("DEBUG REFRESH: RefreshRemoteSources notification received - in-place refresh")
        for src in self.sources {
          if let w = src as? WebDAVSource {
            w.requestRefresh()
          } else {
            src.start()
          }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { Self.isGlobalRefreshRunning = false }
      }
    }

    // Start reachability monitoring
    guard startPathMonitor else { return }
    pathMonitor.pathUpdateHandler = { [weak self] path in
      let satisfied = path.status == .satisfied
      Task { @MainActor in
        self?.handlePathUpdate(satisfied: satisfied)
      }
    }
    pathMonitor.start(queue: pathQueue)
  }

  /// Reacts to a network path change. Always keeps the online flags current (they are cheap and
  /// `pushCacheUpdate` reads them), but while a game is running defers the library work to
  /// `emulationDidEnd()`: no snackbars, no WebDAV relisting, no cache walk.
  func handlePathUpdate(satisfied: Bool) {
    if satisfied {
      guard !lastPathSatisfied else { return }
      isSystemOnline = true
      if suppressNextOnlineRefresh {
        print("Reachability: Online detected (initial). Suppressing first refresh.")
        lastPathSatisfied = true
        suppressNextOnlineRefresh = false
        // A game may already be running; its end owes the sources a fresh listing.
        if isEmulationActive() { needsSourceRefresh = true }
        pushCacheUpdate(forceUpdate: true)
        return
      }
      lastPathSatisfied = true
      pathGeneration += 1
      if isEmulationActive() {
        needsSourceRefresh = true
        pushCacheUpdate(forceUpdate: true)
        return
      }
      let generation = pathGeneration
      DispatchQueue.main.asyncAfter(deadline: .now() + onlineSettleDelay) { [weak self] in
        guard let self else { return }
        // The path flapped again during the settle window; that callback owns the follow-up.
        guard generation == self.pathGeneration, self.isSystemOnline else { return }
        if self.isEmulationActive() {
          // A game booted during the settle delay.
          self.needsSourceRefresh = true
          self.pushCacheUpdate(forceUpdate: true)
          return
        }
        print("Reachability: Online detected, refreshing remote sources")
        self.refreshWebDAVSources()
        self.pushCacheUpdate(forceUpdate: true)
        NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Back online — refreshing library…")])
      }
    } else {
      // Every offline callback is recorded: the first callback of the launch can be unsatisfied, and
      // the reconnection after it is a real one, not the "initial online" the suppress flag is for.
      let wasOnline = lastPathSatisfied
      isSystemOnline = false
      lastPathSatisfied = false
      suppressNextOnlineRefresh = false
      pathGeneration += 1
      // Only a real online-to-offline transition has anything to push or announce.
      guard wasOnline else { return }
      let quiet = isEmulationActive()
      pushCacheUpdate(forceUpdate: true)
      if !quiet {
        NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": L("Offline — some sources unavailable")])
      }
    }
  }

  private func refreshWebDAVSources() {
    for src in sources {
      if let w = src as? WebDAVSource { w.requestRefresh() }
    }
  }

  /// Runs everything that was held back while a game was running, once.
  func emulationDidEnd() {
    if needsSourceRefresh, isSystemOnline {
      refreshWebDAVSources()
    }
    needsSourceRefresh = false
    guard needsPush else { return }
    let forced = deferredPushWasForced
    let cleanup = deferredPushWasCleanup
    needsPush = false
    deferredPushWasForced = false
    deferredPushWasCleanup = false
    pushCacheUpdate(forceUpdate: forced, cleanup: cleanup)
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

    pushCacheUpdate(forceUpdate: true, cleanup: true) // Force update to clean up games from deleted source
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

  /// - Parameter cleanup: the push removes a deleted source's games from the cache, so it must run
  ///   even when this session never pushed anything for that source.
  func pushCacheUpdate(forceUpdate: Bool = false, cleanup: Bool = false) {
    // The push walks the whole Software folder and rewrites the game cache, then fans out to the
    // library UI, Spotlight and the widget snapshot. None of that may compete with a running game.
    if isEmulationActive() {
      needsPush = true
      deferredPushWasForced = deferredPushWasForced || forceUpdate
      deferredPushWasCleanup = deferredPushWasCleanup || cleanup
      return
    }

    // No sources and nothing ever pushed: a forced push (a Wi-Fi flap, or the first path callback
    // at launch) would only repeat a Software-folder walk the launch rescan already did. Removing a
    // source is the exception: its games may still be in the persisted cache.
    if forceUpdate, !cleanup, sources.isEmpty, lastItemsBySource.isEmpty, lastPushedURLs.isEmpty {
      return
    }

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
    SentryTelemetryService.trace(
      "library.remote_sync",
      op: "library.remote_sync",
      tags: ["url_count": "\(allUrls.count)"]) {
        pushToLibrary(allUrls)
      }

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
  private let emulationState: EmulationState
  private let gamesProvider: () -> [TVGameItem]
  /// A reload was requested while a game was running; it runs when the session ends.
  private(set) var needsReload = false
  /// A reload is waiting out the debounce. The end-of-session reload covers it and clears this, so a
  /// game ending inside the debounce window does not reload twice.
  private var debouncedReloadPending = false
  /// Runs the local Software-folder rescan and calls back when it finishes. Injectable for tests.
  private let localRescan: (@escaping () -> Void) -> Void
  /// The first-appearance local rescan was requested while a game was running.
  private(set) var needsLocalRefresh = false

  private convenience init() {
    self.init(emulationState: .shared, gamesProvider: { TVLibraryBridge.currentGames() })
  }

  /// `internal` so tests can build one against their own `EmulationState`; the app uses `shared`.
  init(
    emulationState: EmulationState,
    gamesProvider: @escaping () -> [TVGameItem],
    localRescan: @escaping (@escaping () -> Void) -> Void = { TVLibraryBridge.rescanLocalAndFetchMetadata($0) }
  ) {
    self.emulationState = emulationState
    self.gamesProvider = gamesProvider
    self.localRescan = localRescan
    emulationState.addTransitionHandler { [weak self] active in
      guard let self, !active else { return }
      if self.needsLocalRefresh {
        // The rescan reloads the list itself when it finishes.
        self.needsLocalRefresh = false
        self.needsReload = false
        // The rescan's completion is the one reload; a debounce still pending would load mid-scan.
        self.debouncedReloadPending = false
        self.refreshLocal()
      } else if self.needsReload {
        self.needsReload = false
        self.debouncedReloadPending = false
        self.loadCurrent()
      }
    }

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
        guard let self, self.debouncedReloadPending else { return }
        self.debouncedReloadPending = false
        #if DEBUG
        print("LibraryCoordinator: Debounced reload executing loadCurrent()")
        #endif
        self.loadCurrent()
      }
      .store(in: &cancellables)
  }

  /// Starts the coordinator and loads the current game list immediately
  func start() {
    loadCurrent(force: true)
  }

  /// `refreshLocal` for background-initiated rescans (the library's first appearance): a full
  /// Software-folder walk must not overlap a boot, so during a session it waits for the session to end.
  func refreshLocalWhenIdle() {
    if emulationState.isActive {
      needsLocalRefresh = true
    } else {
      refreshLocal()
    }
  }

  /// Refreshes only local files and metadata, leaving remote streams intact
  func refreshLocal(completion: (() -> Void)? = nil) {
    isUpdating = true
    let trace = SentryTelemetryService.beginTrace("library.rescan", op: "library.rescan", tags: ["source": "local"])
    localRescan { [weak self] in
      SentryTelemetryService.finishTrace(trace)
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
    let trace = SentryTelemetryService.beginTrace("library.rescan", op: "library.rescan", tags: ["source": "all"])
    NotificationCenter.default.post(name: NSNotification.Name("RefreshRemoteSources"), object: nil)
    localRescan { [weak self] in
      SentryTelemetryService.finishTrace(trace)
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
    debouncedReloadPending = true
    reloadSubject.send(())
  }

  /// Publishing `games` regroups the whole library and re-evaluates the grid, so while a game is
  /// running a reload is held until it ends. `force` is for the first load, which has nothing to show yet.
  func loadCurrent(force: Bool = false) {
    if emulationState.isActive, !force {
      needsReload = true
      return
    }
    games = gamesProvider()
  }
}
