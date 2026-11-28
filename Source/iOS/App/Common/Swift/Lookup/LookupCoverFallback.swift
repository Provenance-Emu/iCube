// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import ImageIO
import os
import PVLookup
import UniformTypeIdentifiers

/// When the cover fallback may look for a game's cover, and which of the URLs it is given count.
///
/// Pure so it is unit-testable; `LookupCoverLedger` supplies the stored inputs.
enum LookupCoverPolicy {
  /// A game no database had a cover for is asked about again after this long.
  static let retryAfter: TimeInterval = 7 * 24 * 60 * 60
  /// The core already asked GameTDB (`GameFile::DownloadDefaultCover`); asking again finds nothing new.
  static let coreCoverHost = "art.gametdb.com"
  /// The path pieces that mark a front box image on the libretro thumbnail server and on TheGamesDB.
  static let frontBoxPathMarkers = ["/Named_Boxarts/", "/boxart/front/"]

  static func shouldAttempt(
    hasCoverArt: Bool, usesGameCovers: Bool, gametdbID: String, lastAttempt: Date?, attemptedThisLaunch: Bool,
    now: Date = Date()
  ) -> Bool {
    guard !hasCoverArt, usesGameCovers, isCacheName(gametdbID), !attemptedThisLaunch else { return false }
    guard let lastAttempt else { return true }
    return now.timeIntervalSince(lastAttempt) >= retryAfter
  }

  /// The core names a cached cover after the GameTDB ID, so the ID must be a plain file name:
  /// not empty, not `TVGameItem`'s `<unknown>` placeholder, nothing that could leave the folder.
  static func isCacheName(_ gametdbID: String) -> Bool {
    !gametdbID.isEmpty && gametdbID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
  }

  /// Front box art only, libretro's first, without URLs already known dead.
  static func candidates(from urls: [URL], dead: Set<String> = []) -> [URL] {
    let fronts = urls.filter { url in
      url.host?.lowercased() != coreCoverHost && frontBoxPathMarkers.contains { url.path.contains($0) }
    }
    return ArtworkFallbackPlanner.order(
      libretro: fronts.filter(ArtworkFallbackPlanner.isLibretroThumbnail),
      others: fronts.filter { !ArtworkFallbackPlanner.isLibretroThumbnail($0) },
      excluding: dead
    )
  }
}

/// When each game was last asked about, plus the per-launch attempt set. Keyed by GameTDB ID,
/// the name the core caches a cover under, so every disc of a title shares one record.
final class LookupCoverLedger {
  static let keyPrefix = "lookup_cover_last_attempt_"

  private let defaults: UserDefaults
  private var attempted = Set<String>()

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func lastAttempt(for gametdbID: String) -> Date? {
    defaults.object(forKey: Self.keyPrefix + gametdbID) as? Date
  }

  func recordAttempt(for gametdbID: String, at date: Date = Date()) {
    defaults.set(date, forKey: Self.keyPrefix + gametdbID)
  }

  func markAttempted(_ gametdbID: String) { attempted.insert(gametdbID) }
  func unmarkAttempted(_ gametdbID: String) { attempted.remove(gametdbID) }
  func wasAttempted(_ gametdbID: String) -> Bool { attempted.contains(gametdbID) }
}

/// Turns a downloaded image into what the core's cover cache holds: a PNG no larger than a cover is drawn.
enum LookupCoverImage {
  static let maximumPixelSize = 640
  static let requestTimeout: TimeInterval = 30

  static func png(from data: Data) -> Data? {
    guard ArtworkDownloadClassifier.looksLikeImage(data),
          let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
      return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? output as Data : nil
  }

  /// The body and HTTP status of `url`, or nil when the request failed.
  @Sendable static func download(_ url: URL) async -> (data: Data, status: Int?)? {
    var request = URLRequest(url: url)
    request.timeoutInterval = requestTimeout
    guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
    return (data, (response as? HTTPURLResponse)?.statusCode)
  }
}

/// Finds a cover in the shared databases (PVLookup) for games GameTDB had none for.
///
/// GameTDB stays the first source: the core downloads its cover by game ID while it scans. A game
/// still without one afterwards is looked up by the same ID in libretrodb, and the first front box
/// image that downloads is written where the core keeps GameTDB covers, so the library, widgets
/// and Top Shelf pick it up the way they pick up any cover. A cover the player set is never replaced:
/// such a game already has cover art and is skipped.
@MainActor
final class LookupCoverFallback {
  /// What the fallback needs to know about one library game, copied off `TVGameItem`.
  struct Game: Equatable, Sendable {
    var path: String
    var gameID: String
    var platform: Int
    var gametdbID: String
    var hasCoverArt: Bool
  }

  struct Environment {
    var lookup: GameLookup = .live
    var usesGameCovers: @MainActor () -> Bool = { DOLConfigBridge.mainUseGameCovers() }
    var coverDirectory: @MainActor () -> URL = { URL(fileURLWithPath: TVLibraryBridge.coverCacheDirectory(), isDirectory: true) }
    /// The image's bytes and HTTP status, or nil when the request failed.
    var download: @Sendable (URL) async -> (data: Data, status: Int?)? = LookupCoverImage.download
    /// Has the library show the covers just stored. It must not rescan: a rescan drops remote entries.
    var reloadCovers: @MainActor () -> Void = { TVLibraryBridge.reloadCovers() }
    /// Lookups, downloads and the library reload wait for a running game to end.
    var isEmulating: @MainActor () -> Bool = { EmulationState.shared.isActive }
    var now: @Sendable () -> Date = { Date() }
  }

  static let shared = LookupCoverFallback()
  /// Posted by the library cache when games were added or refreshed.
  static let libraryUpdated = Notification.Name("RemoteLibraryUpdated")

  private static let log = ICubeLog.logger("LookupCoverFallback")

  private let environment: Environment
  private let ledger: LookupCoverLedger
  private var queue: [Game] = []
  private var worker: Task<Void, Never>?
  private var observer: NSObjectProtocol?
  /// Runs the sweep now, or when the running game ends.
  private var deferral: EmulationDeferral?

  init(environment: Environment = Environment(), ledger: LookupCoverLedger = LookupCoverLedger()) {
    self.environment = environment
    self.ledger = ledger
  }

  /// Looks again whenever the library changes. The launch scan calls `sweep` itself when it ends.
  func start() {
    guard observer == nil else { return }
    deferral = EmulationDeferral { [weak self] in self?.sweepNow() }
    observer = NotificationCenter.default.addObserver(forName: Self.libraryUpdated, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.sweepLibrary() }
    }
  }

  /// Sweeps the library, after the running game if there is one.
  func sweepLibrary() {
    if let deferral {
      deferral.request()
    } else {
      sweepNow()
    }
  }

  private func sweepNow() {
    sweep(TVLibraryBridge.currentGames().map {
      Game(path: $0.filePath, gameID: $0.gameID, platform: $0.platform, gametdbID: $0.gametdbID, hasCoverArt: $0.hasCoverArt)
    })
  }

  /// Queues every game that may be looked up now. Returns once queued; `waitUntilIdle` awaits the work.
  func sweep(_ games: [Game]) {
    guard !environment.isEmulating() else { return }
    let usesGameCovers = environment.usesGameCovers()
    let now = environment.now()
    for game in games where LookupCoverPolicy.shouldAttempt(
      hasCoverArt: game.hasCoverArt, usesGameCovers: usesGameCovers, gametdbID: game.gametdbID,
      lastAttempt: ledger.lastAttempt(for: game.gametdbID), attemptedThisLaunch: ledger.wasAttempted(game.gametdbID), now: now
    ) {
      ledger.markAttempted(game.gametdbID)
      queue.append(game)
    }
    guard worker == nil, !queue.isEmpty else { return }
    worker = Task { [weak self] in
      await self?.drain()
    }
  }

  func waitUntilIdle() async {
    await worker?.value
  }

  private func drain() async {
    var stored = false
    while !queue.isEmpty {
      if environment.isEmulating() {
        // A game started: leave the rest for the sweep that follows it.
        queue.forEach { ledger.unmarkAttempted($0.gametdbID) }
        queue.removeAll()
        deferral?.request()
        break
      }
      let game = queue.removeFirst()
      switch await fetchCover(for: game) {
      case .stored:
        stored = true
      case .noCover:
        ledger.recordAttempt(for: game.gametdbID, at: environment.now())
      case .tryLater:
        // Offline, a server error or a database that would not open: the next launch asks again.
        break
      }
    }
    worker = nil
    guard stored else { return }
    if environment.isEmulating() {
      // The covers are on disk; the sweep after the game reloads them with whatever it finds.
      deferral?.request()
    } else {
      environment.reloadCovers()
    }
  }

  private enum Outcome {
    /// The cover is in the core's cover cache.
    case stored
    /// No database has a front box image that downloads.
    case noCover
    case tryLater
  }

  private func fetchCover(for game: Game) async -> Outcome {
    guard let query = GameLookupQuery(gameID: game.gameID, platform: game.platform) else { return .noCover }
    let urls: [URL]
    do {
      // A lookup that fails is not a game without a cover.
      guard let metadata = try await environment.lookup.search(query) else { return .noCover }
      urls = try await environment.lookup.artwork(metadata)
    } catch {
      Self.log.error("Cover lookup for \(query.serial, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
      return .tryLater
    }
    var outcome = Outcome.noCover
    for url in LookupCoverPolicy.candidates(from: urls) {
      guard let response = await environment.download(url) else {
        outcome = .tryLater
        continue
      }
      switch ArtworkDownloadClassifier.classify(statusCode: response.status, data: response.data) {
      case .dead:
        continue
      case .transient:
        outcome = .tryLater
        continue
      case .image:
        break
      }
      guard let png = LookupCoverImage.png(from: response.data) else { continue }
      let directory = environment.coverDirectory()
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(game.gametdbID + ".png"), options: .atomic)
        Self.log.info("Cover for \(game.gametdbID, privacy: .public) from \(url.host ?? "", privacy: .public)")
        return .stored
      } catch {
        Self.log.error("Could not store the cover for \(game.gametdbID, privacy: .public): \(error.localizedDescription, privacy: .public)")
        return .tryLater
      }
    }
    return outcome
  }
}
