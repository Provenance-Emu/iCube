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
  /// then the write held for the session end never happens. Backgrounding pauses the game, so it
  /// is a safe moment to write what was held.
  func applicationDidEnterBackground(_ application: UIApplication) {
    LibrarySnapshotScheduler.shared.flushHeldWriteForBackground()
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
@MainActor
final class LibrarySnapshotScheduler {
  static let defaultDebounce: TimeInterval = 2
  static let shared = LibrarySnapshotScheduler()

  /// Delay between the end of a session and the held-back write; lets the library settle first.
  static let postSessionDelay: TimeInterval = 1

  private let state: EmulationState
  private let write: @MainActor () -> Void
  private let schedule: (TimeInterval, DispatchWorkItem) -> Void
  private var pending: DispatchWorkItem?
  private var gateInstalled = false
  /// A write was requested (or cancelled by a session start) and has not happened yet.
  private(set) var writeHeldForSession = false

  init(
    state: EmulationState = .shared,
    write: @escaping @MainActor () -> Void = { LibrarySnapshotWriter.writeNow() },
    schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
  ) {
    self.state = state
    self.write = write
    self.schedule = schedule
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
        self.writeHeldForSession = true
      } else if self.writeHeldForSession {
        self.writeHeldForSession = false
        self.requestWrite(after: Self.postSessionDelay)
      }
    }
  }

  /// Writes now what a running game was holding back. No-op when nothing is held or no game runs
  /// (an idle app's debounced write is already on its way).
  func flushHeldWriteForBackground() {
    guard state.isActive, writeHeldForSession else { return }
    writeHeldForSession = false
    write()
  }

  func requestWrite(after delay: TimeInterval) {
    if state.isActive {
      pending?.cancel()
      pending = nil
      writeHeldForSession = true
      return
    }
    pending?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.pending = nil
      self?.write()
    }
    pending = work
    schedule(delay, work)
  }
}
