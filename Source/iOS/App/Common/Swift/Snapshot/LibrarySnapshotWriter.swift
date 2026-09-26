// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import PVLibrarySnapshot
#if os(tvOS)
import TVServices
#endif

/// Projects the core's game list into the App Group snapshot. Collects on the main
/// actor (TVGameItem is main-thread), encodes and mirrors on a utility task.
@MainActor
enum LibrarySnapshotWriter {
  static func writeNow() {
    let items = TVLibraryBridge.currentGames().filter { !$0.isDemoItem }
    let lastPlayed = LastPlayedStore.all()
    var games: [LibrarySnapshotGame] = []
    var jobs: [CoverJob] = []
    games.reserveCapacity(items.count)

    for item in items {
      let gameID = item.gameID
      guard !gameID.isEmpty else { continue }
      let hasCover = item.hasCoverArt
      games.append(LibrarySnapshotGame(
        id: gameID,
        title: item.title,
        filePath: item.filePath,
        platform: LibraryPlatform(discIOPlatform: item.platform),
        gametdbID: item.gametdbID.isEmpty ? nil : item.gametdbID,
        region: item.countryName.isEmpty ? nil : item.countryName,
        lastPlayed: lastPlayed[gameID],
        isFavorite: item.isFavorite,
        dateAdded: LibraryAddedDateStore.resolvedAddedDate(forPath: item.filePath),
        coverFilename: hasCover ? LibrarySnapshotAppGroup.coverFilename(gameID: gameID) : nil))
      if hasCover { jobs.append(CoverJob(gameID: gameID, image: item.coverImage)) }
    }

    Task.detached(priority: .utility) {
      CoverMirror.mirror(jobs)
      let snapshot = LibrarySnapshot.build(from: games)
      let saved = LibrarySnapshotStore().save(snapshot)
      NSLog("[Snapshot] wrote %d games (%d recent, %d favorites) saved=%d",
            snapshot.byGameID.count, snapshot.recentlyPlayed.count, snapshot.favorites.count, saved ? 1 : 0)
      guard saved else { return }
      #if os(tvOS)
      TVTopShelfContentProvider.topShelfContentDidChange()
      #else
      await EcosystemSurfaceRefresher.refresh(with: snapshot)
      #endif
    }
  }
}
