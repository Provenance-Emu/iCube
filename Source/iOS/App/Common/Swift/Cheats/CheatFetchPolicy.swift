// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What the cheats pane knows about the on-demand Gecko download for the current game.
enum CheatFetchStatus: Equatable {
  case idle
  case fetching
  case fetched(downloaded: Int, added: Int)
  case failed
  /// The title has no GameTDB ID (homebrew, some channels), so there is nothing to look up.
  case unavailable
}

/// Decides whether opening the cheats pane should hit codes.rc24.xyz for this game.
///
/// Pure so it is unit-testable; `CheatFetchLedger` supplies the inputs. Fetch when the game
/// has never been fetched, or its last fetch is older than `staleAfter`, but at most once
/// per app launch so an offline device does not retry on every pause.
enum CheatAutoFetchPolicy {
  static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

  static func shouldFetch(gametdbId: String, lastFetch: Date?, attemptedThisLaunch: Bool, now: Date = Date()) -> Bool {
    guard !gametdbId.isEmpty, !attemptedThisLaunch else { return false }
    guard let lastFetch else { return true }
    return now.timeIntervalSince(lastFetch) >= staleAfter
  }
}

/// Per-game record of the last successful Gecko download, plus the per-launch attempt set.
/// Keyed by GameTDB ID (what rc24 is queried with), not game ID, so every region disc of a
/// title shares one record.
final class CheatFetchLedger {
  static let shared = CheatFetchLedger(defaults: .standard)

  static let keyPrefix = "cheats_last_fetch_"
  static func key(for gametdbId: String) -> String { keyPrefix + gametdbId }

  private let defaults: UserDefaults
  private var attempted = Set<String>()

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  func lastFetch(for gametdbId: String) -> Date? {
    defaults.object(forKey: Self.key(for: gametdbId)) as? Date
  }

  func recordFetch(for gametdbId: String, at date: Date = Date()) {
    defaults.set(date, forKey: Self.key(for: gametdbId))
  }

  func markAttempted(_ gametdbId: String) { attempted.insert(gametdbId) }
  func wasAttempted(_ gametdbId: String) -> Bool { attempted.contains(gametdbId) }

  func shouldAutoFetch(gametdbId: String, now: Date = Date()) -> Bool {
    CheatAutoFetchPolicy.shouldFetch(
      gametdbId: gametdbId, lastFetch: lastFetch(for: gametdbId),
      attemptedThisLaunch: wasAttempted(gametdbId), now: now)
  }
}
