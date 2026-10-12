// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UIKit

/// Records launches and play time into `LibraryStateStore`.
///
/// A launch is counted on `DOLEmulationWillStartNotification`, resolving the
/// GameID from the notification's `path` the same way `LibrarySnapshotService`
/// does for last-played. Seconds are added when the session ends.
///
/// Seconds are also flushed on `applicationDidEnterBackground`, not only at
/// session end. A backgrounded game can be killed by jetsam or swiped away
/// without `DOLEmulationDidEndNotification` ever being posted, which would lose
/// the whole session. Flushing on backgrounding bounds the loss to the time
/// since the last flush; the session resumes counting on `applicationDidBecomeActive`.
final class PlayStatsRecorderService: NSObject, UIApplicationDelegate {

  /// A session longer than a day is a clock jump or a stuck state, not play time.
  private static let maxSessionSeconds: TimeInterval = 86_400

  private var observers: [NSObjectProtocol] = []
  private var gameID: String?
  private var sessionStart: Date?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    installObserversIfNeeded()
    return true
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    flush()
    sessionStart = nil
  }

  func applicationDidBecomeActive(_ application: UIApplication) {
    if gameID != nil, sessionStart == nil { sessionStart = Date() }
  }

  private func installObserversIfNeeded() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: Notification.Name("DOLEmulationWillStartNotification"),
        object: nil, queue: .main
      ) { [weak self] note in self?.sessionStarted(note) },
      center.addObserver(
        forName: Notification.Name("DOLEmulationDidEndNotification"),
        object: nil, queue: .main
      ) { [weak self] _ in self?.sessionEnded() }
    ]
  }

  private func sessionStarted(_ note: Notification) {
    guard let path = note.userInfo?["path"] as? String,
          let item = TVLibraryBridge.currentGames().first(where: { $0.filePath == path }) else { return }
    let id = item.gameID
    guard !id.isEmpty else { return }
    LibraryStateStore.shared.recordLaunch(gameID: id)
    gameID = id
    sessionStart = Date()
  }

  private func sessionEnded() {
    flush()
    gameID = nil
    sessionStart = nil
  }

  /// Adds the seconds since `sessionStart` and restarts the clock so a later
  /// flush does not count them twice.
  private func flush() {
    guard let gameID, let start = sessionStart else { return }
    let elapsed = min(max(Date().timeIntervalSince(start), 0), Self.maxSessionSeconds)
    let seconds = Int(elapsed)
    guard seconds > 0 else { return }
    LibraryStateStore.shared.addPlaySeconds(seconds, gameID: gameID)
    sessionStart = Date()
  }
}
