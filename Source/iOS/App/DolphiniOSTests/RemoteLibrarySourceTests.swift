// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVContinuity
import PVRemoteLibrary
import PVSystems
import UIKit
import XCTest

@testable import iCube

final class RemoteLibrarySourceTests: XCTestCase {
  private var folder: URL!

  override func setUp() {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("sources-" + UUID().uuidString, isDirectory: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: folder)
  }

  private static let melee = ContinuityLibraryEntry(
    key: "id:GALE01|d0|r2",
    game: GameIdentity(gameID: "GALE01", md5: "ABCDEF", displayName: "Super Smash Bros. Melee", platform: "gc", discNumber: 0, revision: 2),
    sizeBytes: 1_459_978_240, hasArtwork: true)
  private static let galaxy = ContinuityLibraryEntry(
    key: "romm:40", game: GameIdentity(displayName: "Super Mario Galaxy", platform: "wii"), sizeBytes: 0, hasArtwork: false)

  private static func image() -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: 20, height: 30), format: format).pngData {
      UIColor.systemTeal.setFill()
      $0.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
    }
  }

  // MARK: - The shared model

  func testACatalogEntryBecomesASourceGame() {
    let source = LibrarySourceID(rawValue: "ecs:http://server.local:8473")
    let game = LibraryGame(entry: Self.melee, source: source)
    XCTAssertEqual(game.id, "ecs:http://server.local:8473|id:GALE01|d0|r2")
    XCTAssertEqual(game.sourceGameID, Self.melee.key)
    XCTAssertEqual(game.title, "Super Smash Bros. Melee")
    XCTAssertEqual(game.system, .GameCube)
    XCTAssertEqual(game.gameID, "GALE01")
    XCTAssertEqual(game.discNumber, 0)
    XCTAssertEqual(game.revision, 2)
    XCTAssertEqual(game.md5, "abcdef")
    XCTAssertEqual(game.sizeBytes, 1_459_978_240)
    XCTAssertEqual(game.artKey, Self.melee.key)

    let bare = LibraryGame(entry: Self.galaxy, source: source)
    XCTAssertEqual(bare.system, .Wii)
    XCTAssertNil(bare.artKey, "No cover is asked for when the source has none")
    XCTAssertNil(bare.gameID)
  }

  func testTheEntryHandedBackToAClientKeepsItsKeyAndIdentity() {
    let source = LibrarySourceID(rawValue: "peer:abc")
    for entry in [Self.melee, Self.galaxy] {
      let back = ContinuityLibraryEntry(game: LibraryGame(entry: entry, source: source))
      XCTAssertEqual(back.key, entry.key)
      XCTAssertEqual(back.game.stableKey, entry.game.stableKey)
      XCTAssertEqual(back.game.platform, entry.game.platform)
      XCTAssertEqual(back.sizeBytes, entry.sizeBytes)
      XCTAssertEqual(back.hasArtwork, entry.hasArtwork)
    }
  }

  func testOnlyDolphinPlatformsHaveASystem() {
    XCTAssertEqual(GameIdentity(displayName: "a", platform: "gc").system, .GameCube)
    XCTAssertEqual(GameIdentity(displayName: "a", platform: "wii").system, .Wii)
    XCTAssertNil(GameIdentity(displayName: "a", platform: "dreamcast").system)
    XCTAssertEqual(GameIdentity.platformSlug(for: .GameCube), "gc")
    XCTAssertNil(GameIdentity.platformSlug(for: .Dreamcast))
    let unknown = LibraryGame(
      entry: .init(key: "k", game: .init(displayName: "a", platform: "dreamcast"), sizeBytes: 0, hasArtwork: false),
      source: .init(rawValue: "s"))
    XCTAssertEqual(ContinuityLibraryEntry(game: unknown).game.platform, "dreamcast", "An unmapped platform goes back as it came")
  }

  // MARK: - Servers

  func testAServerCatalogPagesThroughTheSource() async throws {
    let catalog = FakeCatalog(pages: [[Self.melee], [Self.galaxy]], kind: .romm)
    let source = RemoteCatalogSource(catalog: catalog, name: "Shelf")
    XCTAssertEqual(source.info.id.rawValue, "fake-catalog")
    XCTAssertEqual(source.info.kind, .romm)
    XCTAssertEqual(source.info.name, "Shelf")
    XCTAssertEqual(source.capabilities, [.serverSearch, .paging])

    let first = try await source.page(CatalogueQuery(search: "mario"), after: nil)
    XCTAssertEqual(first.games.map(\.sourceGameID), [Self.melee.key])
    XCTAssertEqual(first.games.map(\.source), [source.info.id])
    let cursor = try XCTUnwrap(first.next)
    let second = try await source.page(CatalogueQuery(search: "mario"), after: cursor)
    XCTAssertEqual(second.games.map(\.system), [.Wii])
    XCTAssertNil(second.next)
    let searches = await catalog.searches
    XCTAssertEqual(searches, ["mario"], "The first page opens the catalog; the next continues it")

    let wiiOnly = try await RemoteCatalogSource(catalog: FakeCatalog(pages: [[Self.melee, Self.galaxy]], kind: .romm))
      .page(CatalogueQuery(systems: [.Wii]), after: nil)
    XCTAssertEqual(wiiOnly.games.map(\.title), ["Super Mario Galaxy"])
  }

  func testAServerThatPlaysTemporarilyHandsItsFilesOver() async throws {
    let catalog = FakeCatalog(pages: [[Self.melee]], kind: .contentServer, temporaryFile: "melee.iso")
    let source = RemoteCatalogSource(catalog: catalog)
    XCTAssertTrue(source.capabilities.contains(.temporaryPlay))
    let game = LibraryGame(entry: Self.melee, source: source.info.id)

    let fetched = try await source.fetch(game, into: folder) { _ in }
    XCTAssertEqual(fetched.files.map(\.lastPathComponent), ["melee.iso"])
    XCTAssertEqual(fetched.directory.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fetched.files[0].path))
    let asked = await catalog.temporaryCopies
    XCTAssertEqual(asked, [Self.melee.key])
  }

  func testAServerThatImportsDirectlyHasNoFilesToHandOver() async throws {
    let source = RemoteCatalogSource(catalog: FakeCatalog(pages: [[Self.galaxy]], kind: .romm))
    let game = LibraryGame(entry: Self.galaxy, source: source.info.id)
    do {
      _ = try await source.fetch(game, into: folder) { _ in }
      XCTFail("A RomM copy goes through the background downloader")
    } catch {
      XCTAssertEqual(error as? RemoteSourceError, .importsDirectly)
    }
    let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    XCTAssertEqual(left, [], "A fetch that fails leaves no folder behind")
  }

  // MARK: - Nearby devices

  func testANearbyDeviceListsItsCatalogAndKeepsCoversOnDisk() async throws {
    let transport = PeerTransport(entries: [Self.melee, Self.galaxy], cover: Self.image())
    let client = ContinuityLibraryClient(identity: ContinuityPeerIdentity(name: "Tester"), transport: transport)
    let baseURL = try XCTUnwrap(URL(string: "http://peer.local:8080"))
    let source = NearbyPeerSource(peerID: "peer-1", name: "Living Room", client: client, baseURL: baseURL)
    XCTAssertEqual(source.info.id.rawValue, "peer:peer-1")
    XCTAssertEqual(source.info.kind, .peer)

    let page = try await source.page(CatalogueQuery(), after: nil)
    XCTAssertEqual(page.games.map(\.sourceGameID), [Self.melee.key, Self.galaxy.key])
    XCTAssertNil(page.next)

    let cache = RemoteCoverCache(directory: folder)
    let game = try XCTUnwrap(page.games.first)
    let cover = await cache.cover(for: game, from: source)
    XCTAssertNotNil(cover.flatMap(UIImage.init(data:)))
    let none = await cache.cover(for: page.games[1], from: source)
    XCTAssertNil(none)
    var artRequests = await transport.artKeys
    XCTAssertEqual(artRequests, [Self.melee.key], "A game without a cover is not asked about")

    // The device has gone: the cover kept on disk is still shown.
    await transport.dropCovers()
    let kept = await cache.cover(for: game, from: source)
    XCTAssertEqual(kept, cover)
    artRequests = await transport.artKeys
    XCTAssertEqual(artRequests.count, 2)

    do {
      _ = try await source.fetch(game, into: folder) { _ in }
      XCTFail("A pull from a device runs in the browse controller")
    } catch {
      XCTAssertEqual(error as? RemoteSourceError, .importsDirectly)
    }
  }
}

/// A server catalog that returns fixed pages.
private actor FakeCatalog: RemoteGameCatalog {
  private let pages: [[ContinuityLibraryEntry]]
  private let temporaryFile: String?
  private var next = 0
  private(set) var searches: [String] = []
  private(set) var temporaryCopies: [String] = []
  nonisolated let sourceKind: LibrarySourceInfo.Kind

  init(pages: [[ContinuityLibraryEntry]], kind: LibrarySourceInfo.Kind, temporaryFile: String? = nil) {
    self.pages = pages
    self.temporaryFile = temporaryFile
    sourceKind = kind
  }

  func openCatalog(search: String) async throws -> RemoteCatalogPage {
    searches.append(search)
    next = 0
    return try await continueCatalog()
  }

  func continueCatalog() async throws -> RemoteCatalogPage {
    defer { next += 1 }
    return RemoteCatalogPage(entries: pages[next], hasMore: next + 1 < pages.count, total: nil)
  }

  func gameCount() async throws -> Int { pages.joined().count }
  func artwork(for entry: ContinuityLibraryEntry, etag: String?) async throws -> ArtworkResult { .none }
  func copy(_ entry: ContinuityLibraryEntry, progress: @escaping @Sendable (PullProgress) -> Void) async throws -> [URL] { [] }

  func copyTemporarily(
    _ entry: ContinuityLibraryEntry, into folder: URL, progress: @escaping @Sendable (PullProgress) -> Void
  ) async throws -> [URL] {
    guard let temporaryFile else { throw RemoteSourceError.importsDirectly }
    temporaryCopies.append(entry.key)
    let file = folder.appendingPathComponent(temporaryFile)
    try Data("disc".utf8).write(to: file)
    return [file]
  }

  nonisolated func isAccessDenied(_ error: any Error) -> Bool { false }
  nonisolated var downloadSourceID: String { "fake-catalog" }
}

/// The library routes of a nearby device, answered from memory.
private actor PeerTransport: ContinuityTransport {
  private let entries: [ContinuityLibraryEntry]
  private var cover: Data?
  private(set) var artKeys: [String] = []

  init(entries: [ContinuityLibraryEntry], cover: Data) {
    self.entries = entries
    self.cover = cover
  }

  func dropCovers() { cover = nil }

  func request(_ request: ContinuityRequest) async throws -> ContinuityResponse {
    let path = request.url.path
    if path.hasSuffix("/library/auth/start") {
      return try json(["authId": "auth-1", "serverId": "peer-1", "nonce": Data("nonce".utf8).base64EncodedString()])
    }
    if path.hasSuffix("/library/auth/complete") {
      return try json(["libraryToken": "token-1"])
    }
    if path.hasSuffix("/library/catalog") {
      let catalog = ContinuityLibraryCatalog(
        sourceDevice: SourceDevice(name: "Living Room", platform: "tvOS", appVersion: "1.0"), entries: entries)
      return ContinuityResponse(status: 200, body: try JSONEncoder().encode(catalog))
    }
    if path.hasSuffix("/library/art") {
      let key = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "key" }?.value
      artKeys.append(key ?? "")
      guard let cover else { throw URLError(.cannotConnectToHost) }
      return ContinuityResponse(status: 200, headers: ["Content-Type": "image/png"], body: cover)
    }
    return ContinuityResponse(status: 404)
  }

  func download(
    _ request: ContinuityRequest, to destination: URL, resumeOffset: Int64, progress: (@Sendable (Int64, Int64?) -> Void)?
  ) async throws -> Int64 {
    throw URLError(.unsupportedURL)
  }

  private func json(_ object: [String: String]) throws -> ContinuityResponse {
    ContinuityResponse(status: 200, body: try JSONSerialization.data(withJSONObject: object))
  }
}
