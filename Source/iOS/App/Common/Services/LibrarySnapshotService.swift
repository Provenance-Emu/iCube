// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import UIKit

/// Owns when the App Group snapshot is rewritten: launch, foreground, library
/// changes, favorites, and every game boot (which also stamps last-played).
final class LibrarySnapshotService: UIResponder, UIApplicationDelegate {
  private static let debounce: TimeInterval = 2
  private static var pending: DispatchWorkItem?

  /// Coalesces bursts (a rescan posts many metadata updates) into one write.
  static func requestWrite(after delay: TimeInterval = debounce) {
    pending?.cancel()
    let work = DispatchWorkItem { LibrarySnapshotWriter.writeNow() }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    SharedDefaults.migrateIfNeeded()
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(emulationWillStart(_:)), name: NSNotification.Name("DOLEmulationWillStartNotification"), object: nil)
    for name in ["FavoritesChanged", "RemoteLibraryUpdated", "GameFileMetadataUpdated"] {
      nc.addObserver(self, selector: #selector(libraryChanged), name: NSNotification.Name(name), object: nil)
    }
    return true
  }

  func applicationDidBecomeActive(_ application: UIApplication) {
    Self.requestWrite(after: 3)
  }

  @objc private func libraryChanged() {
    Self.requestWrite()
  }

  @MainActor
  @objc private func emulationWillStart(_ note: Notification) {
    if let path = note.userInfo?["path"] as? String,
       let item = TVLibraryBridge.currentGames().first(where: { $0.filePath == path }) {
      LastPlayedStore.record(gameID: item.gameID)
    }
    Self.requestWrite(after: 0.5)
  }
}
