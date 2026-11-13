// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation
import PVContinuity
import RomMClient

/// A RomM instance the user connected. Its login lives in the keychain under `id`.
struct RomMServer: Codable, Equatable, Identifiable, Sendable {
  let baseURL: URL
  var id: String { "romm:" + baseURL.absoluteString }
  var name: String {
    baseURL.host.map { host in baseURL.port.map { "\(host):\($0)" } ?? host } ?? baseURL.absoluteString
  }

  init(address: RomMAddress) {
    baseURL = address.baseURL
  }

  func address() throws -> RomMAddress {
    try RomMAddress(baseURL.absoluteString)
  }

  /// Where one game's files live, by RomM game ID.
  func folder(forGameID gameID: Int) throws -> URL {
    let key = baseURL.absoluteString + "\n" + String(gameID)
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return try ContinuityPaths.validatedURL(forRelativePath: "Software/RomM/" + digest)
  }

  func folder(for entry: ContinuityLibraryEntry) throws -> URL {
    guard let gameID = RomMLibrary.gameID(forKey: entry.key) else { throw RomMError.invalidContent }
    return try folder(forGameID: gameID)
  }
}

/// A RomM instance as a paged catalog: its GameCube and Wii platforms, one after the other.
actor RomMLibrary: RemoteGameCatalog {
  /// The most games RomM returns in one page.
  private static let pageSize = 100
  private static let keyPrefix = "romm:"

  private let server: RomMServer
  private let client: RomMClient
  private let covers: RemoteCoverCache
  private var games: [String: RomMGame] = [:]
  private var platforms: ArraySlice<RomMPlatform> = []
  private var offset = 0
  private var search = ""
  private var counted = 0

  init(server: RomMServer, login: RomMSavedLogin?, covers: RemoteCoverCache = .shared) throws {
    self.server = server
    self.covers = covers
    client = try RomMClient(address: server.address(), credential: login?.credential ?? .none,
                            allowHTTP: login?.allowHTTP ?? false)
  }

  init(server: RomMServer, client: RomMClient, covers: RemoteCoverCache = .shared) {
    self.server = server
    self.client = client
    self.covers = covers
  }

  func openCatalog(search: String) async throws -> RemoteCatalogPage {
    let supported = try await client.platforms().filter { Self.platform($0) != nil }
    try Task.checkCancellation()
    platforms = supported[...]
    offset = 0
    counted = 0
    games.removeAll()
    self.search = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return try await continueCatalog()
  }

  func continueCatalog() async throws -> RemoteCatalogPage {
    var entries: [ContinuityLibraryEntry] = []
    while let platform = platforms.first, entries.isEmpty {
      try Task.checkCancellation()
      let page = try await client.games(platformID: platform.id, search: search, offset: offset, limit: Self.pageSize)
      try Task.checkCancellation()
      if offset == 0 { counted += page.total }
      if let next = page.nextOffset {
        offset = next
      } else {
        platforms.removeFirst()
        offset = 0
      }
      guard let name = Self.platform(platform) else { continue }
      for game in page.items where game.isDownloadable {
        let key = Self.keyPrefix + String(game.id)
        guard games.updateValue(game, forKey: key) == nil else { continue }
        entries.append(.init(key: key, game: .init(displayName: game.title, platform: name),
                             sizeBytes: max(0, game.fsSizeBytes), hasArtwork: game.coverPath != nil))
      }
    }
    // A platform whose first page has not been read has not been counted yet.
    let uncounted = platforms.count - (offset == 0 ? 0 : 1)
    return RemoteCatalogPage(entries: entries, hasMore: !platforms.isEmpty, total: uncounted == 0 ? counted : nil)
  }

  /// The platform list already carries each platform's game count.
  func gameCount() async throws -> Int {
    try await client.platforms().filter { Self.platform($0) != nil }.reduce(0) { $0 + max(0, $1.romCount) }
  }

  /// RomM puts a timestamp in the cover path, so a changed cover has a new key and a cached one is current.
  func artwork(for entry: ContinuityLibraryEntry) async -> Data? {
    guard let game = games[entry.key], let path = game.coverPath else { return nil }
    let key = server.id + "\n" + path
    if let cached = await covers.cover(for: key) { return cached.data }
    guard let data = try? await client.cover(for: game) else { return nil }
    return await covers.store(data, etag: nil, for: key)
  }

  func copy(_ entry: ContinuityLibraryEntry, progress: @escaping @Sendable (PullProgress) -> Void) async throws -> [URL] {
    guard let game = games[entry.key] else { throw RomMError.unavailable }
    return try await RomMGameImport.copy(game, from: client, server: server)
  }

  nonisolated func isAccessDenied(_ error: any Error) -> Bool {
    (error as? RomMError) == .accessDenied
  }

  static func gameID(forKey key: String) -> Int? {
    key.hasPrefix(keyPrefix) ? Int(key.dropFirst(keyPrefix.count)) : nil
  }

  /// iCube's platform for a RomM platform, or nil when Dolphin does not run it.
  static func platform(_ platform: RomMPlatform) -> String? {
    let names = platform.identifiers
    if names.contains("wii") { return "wii" }
    if names.contains(where: { ["ngc", "gc", "gamecube"].contains($0) }) { return "gc" }
    return nil
  }
}
