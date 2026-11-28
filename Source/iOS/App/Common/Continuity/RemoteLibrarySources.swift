// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVContinuity
import PVRemoteLibrary
import PVSystems

// iCube's remote libraries as the shared library model (PVRemoteLibrary): an Emulation Server, a RomM
// instance and a nearby device each present as a `RemoteLibrarySource`, and their games as `LibraryGame`.
// Nothing here changes what is sent to a server or to another device: the sources call the same clients.

/// The shared protocol, by its full name: iCube's own `RemoteLibrarySource` (WebDAV and FTP folders that are
/// scanned into the library, `Common/Swift/RemoteLibrarySource.swift`) has the same one.
typealias SharedLibrarySource = PVRemoteLibrary.RemoteLibrarySource

extension GameIdentity {
  /// The platform slugs catalogs and nearby devices exchange.
  static let gameCubeSlug = "gc"
  static let wiiSlug = "wii"

  /// The shared system for the platform slug, or nil for a slug iCube does not send.
  var system: SystemIdentifier? {
    switch platform {
    case Self.gameCubeSlug: return .GameCube
    case Self.wiiSlug: return .Wii
    default: return nil
    }
  }

  static func platformSlug(for system: SystemIdentifier?) -> String? {
    switch system {
    case .GameCube: return gameCubeSlug
    case .Wii: return wiiSlug
    default: return nil
    }
  }
}

extension LibraryGame {
  /// A catalog entry as a source's game. The entry's key is the source's own id for it.
  init(entry: ContinuityLibraryEntry, source: LibrarySourceID) {
    self.init(
      source: source, sourceGameID: entry.key, title: entry.game.displayName, system: entry.game.system,
      platformName: entry.game.platform, md5: entry.game.md5, sizeBytes: entry.sizeBytes,
      artKey: entry.hasArtwork ? entry.key : nil, gameID: entry.game.gameID, discNumber: entry.game.discNumber,
      revision: entry.game.revision)
  }
}

extension ContinuityLibraryEntry {
  /// The catalog entry a source's game was made from, to hand back to the client that listed it.
  init(game: LibraryGame) {
    self.init(
      key: game.sourceGameID,
      game: GameIdentity(
        gameID: game.gameID, md5: game.md5, displayName: game.title,
        platform: GameIdentity.platformSlug(for: game.system) ?? game.platformName,
        discNumber: game.discNumber, revision: game.revision),
      sizeBytes: game.sizeBytes, hasArtwork: game.artKey != nil)
  }
}

extension FetchProgress {
  /// The shared model reports a fraction; the byte and file counts stay with the transfer screens.
  init(_ progress: PullProgress) {
    self = .downloading(progress.fractionComplete)
  }
}

enum RemoteSourceError: LocalizedError, Equatable {
  /// The source finishes the import itself (background download, checks, the move into the library), so
  /// it has no loose files to hand over. Copies from it go through `RemoteGameDownloads` or the pull.
  case importsDirectly
  /// The device was asked for a cover and sent none.
  case coverUnavailable

  var errorDescription: String? {
    switch self {
    case .importsDirectly: return L("This library copies games straight into your library.")
    case .coverUnavailable: return L("The cover could not be loaded.")
    }
  }
}

/// An Emulation Server or a RomM instance as a `RemoteLibrarySource`.
actor RemoteCatalogSource: SharedLibrarySource {
  /// A cursor only says "the page after the last one": the catalog keeps its own position.
  private static let nextPage = CatalogueCursor("next")

  nonisolated let info: LibrarySourceInfo
  nonisolated let capabilities: SourceCapabilities
  private let catalog: any RemoteGameCatalog

  init(catalog: any RemoteGameCatalog, name: String = "") {
    self.catalog = catalog
    let kind = catalog.sourceKind
    info = LibrarySourceInfo(
      id: LibrarySourceID(rawValue: catalog.downloadSourceID), kind: kind, name: name,
      symbol: kind == .romm ? "externaldrive.connected.to.line.below" : "server.rack")
    capabilities = kind == .contentServer ? [.serverSearch, .paging, .temporaryPlay] : [.serverSearch, .paging]
  }

  func page(_ query: CatalogueQuery, after cursor: CatalogueCursor?) async throws -> CataloguePage {
    let page = try await cursor == nil ? catalog.openCatalog(search: query.search) : catalog.continueCatalog()
    let games = page.entries.map { LibraryGame(entry: $0, source: info.id) }
    return CataloguePage(
      games: query.systems.map { systems in games.filter { $0.system.map(systems.contains) ?? false } } ?? games,
      next: page.hasMore ? Self.nextPage : nil)
  }

  func artwork(for game: LibraryGame, etag: String?) async throws -> ArtworkResult {
    try await catalog.artwork(for: ContinuityLibraryEntry(game: game), etag: etag)
  }

  /// Only a server that plays a game without keeping it hands its files over; the others import directly.
  func fetch(
    _ game: LibraryGame, into directory: URL, progress: @escaping @Sendable (FetchProgress) -> Void
  ) async throws -> FetchedGame {
    let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    do {
      progress(.preparing)
      let files = try await catalog.copyTemporarily(ContinuityLibraryEntry(game: game), into: folder) {
        progress(FetchProgress($0))
      }
      return FetchedGame(directory: folder, files: files)
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
  }
}

/// A nearby device's shared library as a `RemoteLibrarySource`, over the PVContinuity client the browse
/// screen already paired and authorized with. The requests are the client's own.
actor NearbyPeerSource: SharedLibrarySource {
  static let idPrefix = "peer:"

  nonisolated let info: LibrarySourceInfo
  nonisolated let capabilities: SourceCapabilities = []
  private let client: ContinuityLibraryClient
  private let baseURL: URL

  init(peerID: String, name: String = "", client: ContinuityLibraryClient, baseURL: URL) {
    info = LibrarySourceInfo(
      id: LibrarySourceID(rawValue: Self.idPrefix + peerID), kind: .peer, name: name, symbol: "iphone.gen3")
    self.client = client
    self.baseURL = baseURL
  }

  /// A device sends its whole catalog at once; the browser filters it.
  func page(_ query: CatalogueQuery, after cursor: CatalogueCursor?) async throws -> CataloguePage {
    guard cursor == nil else { return CataloguePage(games: []) }
    let games = try await client.catalog(from: baseURL).entries.map { LibraryGame(entry: $0, source: info.id) }
    return CataloguePage(games: query.systems.map { systems in games.filter { $0.system.map(systems.contains) ?? false } } ?? games)
  }

  /// A device sends no ETag, so a cover is asked for again on each visit. One that does not arrive is an
  /// error, which lets the cover cache show the copy it kept.
  func artwork(for game: LibraryGame, etag: String?) async throws -> ArtworkResult {
    guard game.artKey != nil else { return .none }
    guard let data = await client.artwork(from: baseURL, key: game.sourceGameID) else {
      throw RemoteSourceError.coverUnavailable
    }
    return .image(data, etag: nil)
  }

  /// A pull from a device is approved by its owner, verified file by file and resumed in place, all in the
  /// browse controller: there are no loose files to hand over.
  func fetch(
    _ game: LibraryGame, into directory: URL, progress: @escaping @Sendable (FetchProgress) -> Void
  ) async throws -> FetchedGame {
    throw RemoteSourceError.importsDirectly
  }
}
