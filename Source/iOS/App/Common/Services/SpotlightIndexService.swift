import CoreSpotlight
import Foundation
import os
import PVLibrarySnapshot
import UIKit
import UniformTypeIdentifiers

class SpotlightIndexService: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    indexAllGames()
    NotificationCenter.default.addObserver(self, selector: #selector(reindexOnLibraryUpdate), name: NSNotification.Name("RemoteLibraryUpdated"), object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(reindexOnMetadataUpdate(_:)), name: NSNotification.Name("GameFileMetadataUpdated"), object: nil)
    return true
  }

  func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
    #if !os(tvOS)
    guard userActivity.activityType == CSSearchableItemActionType,
          let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
          identifier.hasPrefix("dios.game.") else { return false }
    let gameID = String(identifier.dropFirst("dios.game.".count))
    NotificationCenter.default.post(name: NSNotification.Name("DOLLaunchGameByGameID"), object: nil, userInfo: ["gameID": gameID])
    #endif
    return true
  }

  @MainActor
  @objc private func reindexOnLibraryUpdate() {
    indexAllGames()
  }

  @MainActor
  @objc private func reindexOnMetadataUpdate(_ note: Notification) {
    #if !os(tvOS)
    // Reindex just the one if we have its filePath; otherwise fall back to all
    if let filePath = note.userInfo?["filePath"] as? String {
      SpotlightLibraryIndexer.shared.reindex(filePath: filePath)
    } else {
      SpotlightLibraryIndexer.shared.reindexAll()
    }
    #endif
  }

  @MainActor
  private func indexAllGames() {
    #if !os(tvOS)
    SpotlightLibraryIndexer.shared.reindexAll()
    #endif
  }
}

#if !os(tvOS)
/// Indexes the live library (`TVLibraryBridge.currentGames()`) in Spotlight for
/// `SpotlightIndexService`, on a utility queue: a pass builds a `TVGameItem` and PNG-encodes a cover
/// for every game, so on the main thread it was a hang that grew with the library. Kept out of that
/// class for the same reason as `SpotlightSnapshotIndexer` below: its members are all `@MainActor`.
final class SpotlightLibraryIndexer: @unchecked Sendable {
  static let shared = SpotlightLibraryIndexer()

  private let queue: DispatchQueue
  private let games: () -> [TVGameItem]
  private let submit: ([CSSearchableItem]) -> Void
  /// True while a full pass is queued but not yet started. `RemoteLibraryUpdated` fires per source
  /// emission, so requests arriving in that window fold into the queued pass, which reads the
  /// library when it starts and therefore already sees their changes.
  private let fullPassQueued = OSAllocatedUnfairLock(initialState: false)

  /// `games` and `submit` are injectable so tests can observe where and how often a pass runs.
  init(
    queue: DispatchQueue = DispatchQueue(label: "org.dolphin-ios.spotlight-index", qos: .utility),
    games: @escaping () -> [TVGameItem] = { TVLibraryBridge.currentGames() },
    submit: @escaping ([CSSearchableItem]) -> Void = { CSSearchableIndex.default().indexSearchableItems($0, completionHandler: nil) }
  ) {
    self.queue = queue
    self.games = games
    self.submit = submit
  }

  func reindexAll() {
    let alreadyQueued = fullPassQueued.withLock { queued in
      defer { queued = true }
      return queued
    }
    guard !alreadyQueued else { return }
    queue.async { [self] in
      // Clear before reading the library, so a request that arrives mid-pass queues a fresh one.
      fullPassQueued.withLock { $0 = false }
      submit(games().map(Self.searchableItem(for:)))
    }
  }

  func reindex(filePath: String) {
    queue.async { [self] in
      submit(games().filter { $0.filePath == filePath }.map(Self.searchableItem(for:)))
    }
  }

  static func searchableItem(for game: TVGameItem) -> CSSearchableItem {
    let attr = CSSearchableItemAttributeSet(contentType: UTType.item)
    attr.title = game.title
    var lines: [String] = []
    if !game.makerLong.isEmpty { lines.append(game.makerLong) }
    if let date = game.apploaderDateString, let year = date.split(separator: "/").first { lines.append(String(year)) }
    if !game.countryName.isEmpty { lines.append(game.countryName) }
    if !game.gametdbID.isEmpty { lines.append(game.gametdbID) }
    attr.contentDescription = lines.isEmpty ? game.gameID : (lines.joined(separator: " • "))
    attr.thumbnailData = game.coverImage.pngData()
    return CSSearchableItem(uniqueIdentifier: "dios.game.\(game.gameID)", domainIdentifier: "dios.games", attributeSet: attr)
  }
}
#endif

/// Indexes snapshot games in Spotlight after every snapshot write (`LibrarySnapshotWriter`, via
/// `EcosystemSurfaceRefresher`). A plain `enum` rather than a member of `SpotlightIndexService`
/// above: that class subclasses `UIResponder`, which this SDK annotates `@MainActor` as a whole
/// (every member, including extension members, inherits the isolation) — so anything added there
/// cannot run off the main thread. This indexer only touches `Sendable` snapshot data and
/// `CSSearchableIndex` (thread-safe by design), and its caller already runs off the main thread
/// inside `Task.detached`, so it deliberately isn't main-actor bound.
///
/// Distinct data source from `SpotlightIndexService.indexAllGames()` (which walks
/// `TVLibraryBridge` on launch and library-change notifications) but writes the same
/// `dios.game.<id>` / `dios.games` identifiers, so `scene(_:continue:)` handles items from either.
enum SpotlightSnapshotIndexer {
  static func indexSnapshotGames(_ snapshot: LibrarySnapshot) {
    #if !os(tvOS)
    CSSearchableIndex.default().indexSearchableItems(searchableItems(from: snapshot), completionHandler: nil)
    #endif
  }

  #if !os(tvOS)
  /// Pure item construction, split out for unit testing.
  static func searchableItems(from snapshot: LibrarySnapshot) -> [CSSearchableItem] {
    let discType = UTType("me.oatmealdome.dolphinios.generic-software") ?? .data
    return snapshot.byGameID.values.map { game in
      let attr = CSSearchableItemAttributeSet(contentType: discType)
      attr.title = game.title
      var lines: [String] = [game.platform.displayName]
      if let region = game.region, !region.isEmpty { lines.append(region) }
      if let gametdbID = game.gametdbID, !gametdbID.isEmpty { lines.append(gametdbID) }
      attr.contentDescription = lines.joined(separator: " • ")
      if let coverURL = game.coverURL, let data = try? Data(contentsOf: coverURL) {
        attr.thumbnailData = data
      }
      return CSSearchableItem(uniqueIdentifier: "dios.game.\(game.id)", domainIdentifier: "dios.games", attributeSet: attr)
    }
  }
  #endif
}
