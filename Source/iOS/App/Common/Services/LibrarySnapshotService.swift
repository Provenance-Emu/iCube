// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import UIKit

/// Owns when the App Group snapshot is rewritten: launch, foreground, library
/// changes, favorites, and every game boot (which also stamps last-played).
final class LibrarySnapshotService: UIResponder, UIApplicationDelegate {
  private static let debounce = LibrarySnapshotScheduler.defaultDebounce

  private var observers: [NSObjectProtocol] = []

  deinit {
    let nc = NotificationCenter.default
    for token in observers { nc.removeObserver(token) }
  }

  /// Coalesces bursts (a rescan posts many metadata updates) into one write.
  ///
  /// While a game runs the write is held until it ends (see `LibrarySnapshotScheduler`).
  static func requestWrite(after delay: TimeInterval = debounce) {
    LibrarySnapshotScheduler.shared.requestWrite(after: delay)
  }

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    SharedDefaults.migrateIfNeeded()
    LibrarySnapshotScheduler.shared.installEmulationGate()
    let nc = NotificationCenter.default
    observers.append(nc.addObserver(forName: NSNotification.Name("DOLEmulationWillStartNotification"), object: nil, queue: .main) { [weak self] note in
      self?.emulationWillStart(note)
    })
    for name in ["FavoritesChanged", "RemoteLibraryUpdated", "GameFileMetadataUpdated"] {
      observers.append(nc.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
        self?.libraryChanged()
      })
    }
    return true
  }

  func applicationDidBecomeActive(_ application: UIApplication) {
    Self.requestWrite(after: 3)
  }

  /// A game's session can end with the process (jetsam, a swipe-kill from the app switcher), and
  /// then a write held or scheduled for the session end never happens. Backgrounding pauses the
  /// game, so write what is owed now, under a background task.
  func applicationDidEnterBackground(_ application: UIApplication) {
    LibrarySnapshotScheduler.shared.flushForBackground()
  }

  private func libraryChanged() {
    Self.requestWrite()
  }

  /// Called on the main queue (via `queue: .main` on the observer registration).
  ///
  /// Stamps last-played now, but does not write the snapshot: the write used to land 0.5 s after
  /// boot, in the middle of shader compilation. `LibrarySnapshotScheduler` writes it when the
  /// session ends, so the widget and Top Shelf pick up the new last-played then.
  private func emulationWillStart(_ note: Notification) {
    if let path = note.userInfo?["path"] as? String,
       let item = TVLibraryBridge.currentGames().first(where: { $0.filePath == path }) {
      LastPlayedStore.record(gameID: item.gameID)
    }
  }
}

/// Debounces App Group snapshot writes and holds them while a game is running.
///
/// A request made during a session (a rescan finishing, a favorite toggled, the app foregrounded
/// mid-game) is remembered and written once, shortly after the session ends. A write that was already
/// scheduled when the session started is cancelled for the same reason. The write is idempotent and
/// reads current state when it runs, so one write after the game covers every request.
///
/// "Written" means durable: the writer reports back once the snapshot is saved, and a held write stays
/// held until then. Backgrounding writes whatever is owed (held, scheduled, or behind a write already
/// in flight) under a background task, because the process can be suspended or killed right after.
@MainActor
final class LibrarySnapshotScheduler {
  /// Starts a write and reports, on the main actor, whether the snapshot was saved.
  typealias Writer = @MainActor (_ completion: @escaping @MainActor (Bool) -> Void) -> Void

  static let defaultDebounce: TimeInterval = 2
  static let shared = LibrarySnapshotScheduler()

  /// Delay between the end of a session and the held-back write; lets the library settle first.
  static let postSessionDelay: TimeInterval = 1

  private let state: EmulationState
  private let write: Writer
  private let schedule: (TimeInterval, DispatchWorkItem) -> Void
  private let beginBackgroundTask: (@escaping () -> Void) -> UIBackgroundTaskIdentifier
  private let endBackgroundTask: (UIBackgroundTaskIdentifier) -> Void
  private var pending: DispatchWorkItem?
  private var gateInstalled = false
  private var backgroundTask = UIBackgroundTaskIdentifier.invalid
  /// A write is running (started, not yet reported saved or failed).
  private var inFlight = false
  /// Something was owed while a write was in flight, so another follows it.
  private var rewriteAfterInFlight = false
  /// Bumped whenever a write becomes owed; a write that started earlier cannot clear a later debt.
  private var owedGeneration = 0
  /// A write is owed and has not been saved yet.
  private(set) var writeHeldForSession = false

  init(
    state: EmulationState = .shared,
    write: @escaping Writer = { completion in LibrarySnapshotWriter.writeNow(completion: completion) },
    schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    },
    beginBackgroundTask: @escaping (@escaping () -> Void) -> UIBackgroundTaskIdentifier = { expiration in
      UIApplication.shared.beginBackgroundTask(withName: "icube.librarysnapshot", expirationHandler: expiration)
    },
    endBackgroundTask: @escaping (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }
  ) {
    self.state = state
    self.write = write
    self.schedule = schedule
    self.beginBackgroundTask = beginBackgroundTask
    self.endBackgroundTask = endBackgroundTask
  }

  /// Registers the end-of-session flush and the start-of-session cancel. Idempotent.
  func installEmulationGate() {
    guard !gateInstalled else { return }
    gateInstalled = true
    state.addTransitionHandler { [weak self] active in
      guard let self else { return }
      if active {
        // Last-played changed at boot, so a write is owed at the end even if none was pending.
        self.pending?.cancel()
        self.pending = nil
        self.markOwed()
      } else if self.writeHeldForSession {
        // Stays held until the write reports saved.
        self.requestWrite(after: Self.postSessionDelay)
      }
    }
  }

  /// Writes what is owed before the process can be suspended: a held write, a scheduled one (it
  /// would not fire in time), or one already running. Does not depend on a game being active: the
  /// session may have ended a moment ago with its write still scheduled.
  func flushForBackground() {
    guard writeHeldForSession || pending != nil || inFlight else { return }
    let owedBeyondInFlight = writeHeldForSession || pending != nil
    pending?.cancel()
    pending = nil
    beginBackgroundTaskIfNeeded()
    if inFlight {
      if owedBeyondInFlight { rewriteAfterInFlight = true }
    } else {
      performWrite()
    }
  }

  func requestWrite(after delay: TimeInterval) {
    if state.isActive {
      pending?.cancel()
      pending = nil
      markOwed()
      return
    }
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.pending = nil
      self?.performWrite()
    }
    pending = work
    schedule(delay, work)
  }

  private func markOwed() {
    writeHeldForSession = true
    owedGeneration += 1
  }

  private func performWrite() {
    guard !inFlight else {
      rewriteAfterInFlight = true
      return
    }
    inFlight = true
    let generation = owedGeneration
    write { [weak self] saved in
      guard let self else { return }
      self.inFlight = false
      if saved {
        if self.owedGeneration == generation { self.writeHeldForSession = false }
      } else {
        // Not durable: keep it owed so the session end, the next background or the next foreground retries.
        self.markOwed()
      }
      if self.rewriteAfterInFlight, saved {
        self.rewriteAfterInFlight = false
        self.performWrite()
      } else {
        self.rewriteAfterInFlight = false
        if self.pending == nil { self.endBackgroundTaskIfIdle() }
      }
    }
  }

  private func beginBackgroundTaskIfNeeded() {
    guard backgroundTask == .invalid else { return }
    backgroundTask = beginBackgroundTask { [weak self] in
      // Out of time: the write stays owed (it is still held or failed), only the assertion goes.
      Task { @MainActor in self?.endBackgroundTaskIfIdle(force: true) }
    }
  }

  private func endBackgroundTaskIfIdle(force: Bool = false) {
    guard backgroundTask != .invalid, force || !inFlight else { return }
    endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }
}
