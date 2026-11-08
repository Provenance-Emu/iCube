// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

#if !os(tvOS)
/// What the iPad library dashboard shows, worked out from plain values so tests do not need the UI.
enum LibraryDashboardBuilder {
  /// Cap for the Recent Saves strip.
  static let recentSavesLimit = 12
  /// One game's saves stop short of filling the strip, so other games stay on it.
  static let recentSavesPerGame = 3

  /// Recently played game IDs among `games`, newest first. The first is the Continue Playing hero.
  static func recentGameIDs(in games: [LibraryGameRef], lastPlayed: [String: Date]) -> [String] {
    LibrarySectionBuilder.homeShelves(games: games, favoriteIDs: [], lastPlayed: lastPlayed)
      .first { $0.id == LibrarySectionBuilder.recentShelfID }?
      .gameIDs ?? []
  }

  /// The newest saves of the games on screen, newest first. The resume auto-state is left out: the Recently
  /// Played shelf right below boots into it anyway, and it is usually a game's newest state, so it would
  /// push the saves the player actually made off the strip.
  static func recentSaves(
    groups: [String: [SaveStateInfo]],
    visibleGameIDs: Set<String>,
    limit: Int = recentSavesLimit,
    perGame: Int = recentSavesPerGame
  ) -> [SaveStateInfo] {
    let candidates = groups
      .filter { visibleGameIDs.contains($0.key) }
      .flatMap { _, states in
        states.filter { !$0.isAuto }.sorted(by: QuickSaveHistoryPolicy.newestFirst).prefix(max(0, perGame))
      }
    return Array(candidates.sorted(by: QuickSaveHistoryPolicy.newestFirst).prefix(max(0, limit)))
  }

  /// Every save the Save States browser lists, which is where the tile leads. The browser has no platform
  /// filter, so neither does the count.
  static func saveCount(groups: [String: [SaveStateInfo]]) -> Int {
    groups.values.reduce(0) { $0 + $1.count }
  }

  /// Whether a boot of `gameID` would load its auto-state. `SaveStateService.hasAutoState` only knows about
  /// the running game, so this asks the save index.
  static func canResume(gameID: String, groups: [String: [SaveStateInfo]], resumeEnabled: Bool) -> Bool {
    resumeEnabled && (groups[gameID]?.contains(where: \.isAuto) ?? false)
  }
}

/// The dashboard's save index and play history. Reads the disk off the main actor, and only on `reload()`:
/// the library's body re-evaluates on every pinch and focus change.
@MainActor
final class LibraryDashboardModel: ObservableObject {
  @Published private(set) var saveGroups: [String: [SaveStateInfo]] = [:]
  @Published private(set) var lastPlayed: [String: Date] = [:]
  /// False until the first scan lands, so the save count never reads 0 while it runs.
  @Published private(set) var hasLoadedSaves = false

  private let provider: SaveStateProviding
  private var loadTask: Task<Void, Never>?

  init(provider: SaveStateProviding = FilesystemSaveStateProvider()) {
    self.provider = provider
  }

  func reload() {
    lastPlayed = LastPlayedStore.all()
    loadTask?.cancel()
    loadTask = Task { [provider] in
      let groups = await provider.statesGroupedByGame()
      guard !Task.isCancelled else { return }
      saveGroups = groups
      hasLoadedSaves = true
    }
  }
}
#endif
