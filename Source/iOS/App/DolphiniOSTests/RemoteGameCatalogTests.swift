// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVContinuity
import RomMClient
import UIKit
import XCTest

@testable import iCube

final class RemoteGameCatalogTests: XCTestCase {
  private var folder: URL!

  override func setUp() {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("covers-" + UUID().uuidString, isDirectory: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: folder)
  }

  private static func image(width: CGFloat, height: CGFloat) -> Data {
    UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      return format
    }()).pngData { context in
      UIColor.systemTeal.setFill()
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
  }

  // MARK: - Emulation Server

  func testServerPagesAreFullSizeAndCountEveryLibrary() async throws {
    let transport = CatalogTransport(cover: Self.image(width: 20, height: 30))
    let server = try EmulationServer(address: "covers.local")
    let library = EmulationServerLibrary(server: server, token: "fixture", transport: transport,
                                         covers: RemoteCoverCache(folder: folder))
    let first = try await library.openCatalog(search: "")
    XCTAssertEqual(first.entries.map(\.key), ["source:wii1", "source:outside"])
    XCTAssertEqual(first.entries.map(\.hasArtwork), [true, false], "A cover path outside the API is not followed")
    XCTAssertTrue(first.hasMore)
    XCTAssertNil(first.total, "The second library has not been counted yet")

    let second = try await library.continueCatalog()
    XCTAssertEqual(second.entries.map(\.key), ["source:gc2"])
    XCTAssertFalse(second.hasMore)
    XCTAssertEqual(second.total, 12, "GameCube and Wii counts from both libraries; other systems are left out")
    let after = try await library.continueCatalog()
    XCTAssertTrue(after.entries.isEmpty)

    let browses = await transport.queries(for: "/api/v1/browse")
    XCTAssertEqual(browses.map { $0["limit"] }, ["100", "100"])
    XCTAssertEqual(browses.map { $0["libraryId"] }, ["lib1", "lib2"])
  }

  func testServerCountReadsOneRowPerLibrary() async throws {
    let transport = CatalogTransport(cover: Data())
    let library = EmulationServerLibrary(server: try EmulationServer(address: "count.local"), token: nil,
                                         transport: transport, covers: RemoteCoverCache(folder: folder))
    let count = try await library.gameCount()
    XCTAssertEqual(count, 12)
    let browses = await transport.queries(for: "/api/v1/browse")
    XCTAssertEqual(browses.map { $0["limit"] }, ["1", "1"])
  }

  func testServerCoverIsDownscaledKeptAndRevalidated() async throws {
    let transport = CatalogTransport(cover: Self.image(width: 1200, height: 1800))
    let server = try EmulationServer(address: "art.local")
    let cache = RemoteCoverCache(folder: folder)
    let library = EmulationServerLibrary(server: server, token: "fixture", transport: transport, covers: cache)
    let opened = try await library.openCatalog(search: "")
    let entry = try XCTUnwrap(opened.entries.first)
    let fetched = await library.artwork(for: entry)
    let cover = try XCTUnwrap(fetched.flatMap(UIImage.init(data:)))
    XCTAssertEqual(max(cover.size.width, cover.size.height) * cover.scale, CGFloat(RemoteCoverCache.maximumPixelSize))
    _ = await library.artwork(for: entry)
    var requests = await transport.coverRequests
    XCTAssertEqual(requests.count, 1, "A cover this catalog already checked is read from disk")
    XCTAssertEqual(requests.first?.headers["Authorization"], "Bearer fixture")
    XCTAssertNil(requests.first?.headers["If-None-Match"])

    // A later visit asks the server whether the cover changed, and reuses the file when it has not.
    let later = EmulationServerLibrary(server: server, token: "fixture", transport: transport, covers: cache)
    let reopened = try await later.openCatalog(search: "")
    let again = try XCTUnwrap(reopened.entries.first)
    let reused = await later.artwork(for: again)
    XCTAssertEqual(reused, fetched)
    requests = await transport.coverRequests
    XCTAssertEqual(requests.last?.headers["If-None-Match"], "\"v1\"")

    // Offline, the cover on disk is still shown.
    await transport.goOffline()
    let offline = EmulationServerLibrary(server: server, token: "fixture", transport: OfflineCovers(base: transport), covers: cache)
    let offlinePage = try await offline.openCatalog(search: "")
    let cached = try XCTUnwrap(offlinePage.entries.first)
    let shown = await offline.artwork(for: cached)
    XCTAssertEqual(shown, fetched)
  }

  // MARK: - Writing details back

  func testEditsAreSentAgainstTheRevisionTheyWereReadAt() async throws {
    let transport = EditTransport()
    let library = EmulationServerLibrary(server: try EmulationServer(address: "edit.local"), token: "writer",
                                         transport: transport, covers: RemoteCoverCache(folder: folder))
    try await library.saveDetails(forKey: "source:wii1", title: "New Name", cover: Self.image(width: 4, height: 6))
    var writes = await transport.writes
    XCTAssertEqual(writes.map(\.method), ["PUT", "PUT"])
    XCTAssertEqual(writes.map(\.url.path), ["/api/v1/sources/wii1/details", "/api/v1/sources/wii1/details/cover"])
    XCTAssertEqual(writes.map { $0.headers["If-Match"] }, ["\"rev-3\"", "\"rev-4\""], "The cover follows the title's new revision")
    XCTAssertEqual(writes.map { $0.headers["Content-Type"] }, ["application/json", "image/png"])
    XCTAssertTrue(writes.allSatisfy { $0.headers["Authorization"] == "Bearer writer" })
    let sent = try JSONDecoder().decode([String: String].self, from: try XCTUnwrap(writes.first?.body))
    XCTAssertEqual(sent, ["title": "New Name"], "Only the title is sent, so the server keeps the other details")

    try await library.saveDetails(forKey: "item:gc1", title: "Item Name", cover: nil)
    writes = await transport.writes
    XCTAssertEqual(writes.last?.method, "PATCH")
    XCTAssertEqual(writes.last?.url.path, "/api/v1/items/gc1")
    XCTAssertEqual(writes.last?.headers["If-Match"], "\"rev-7\"")

    try await library.saveDetails(forKey: "source:wii1", title: nil, cover: Data("not an image".utf8))
    let after = await transport.writes
    XCTAssertEqual(after.count, writes.count, "Bytes that are not a PNG or JPEG are not uploaded")
  }

  func testEditRetriesOnceAfterAConflictAndReportsRefusals() async throws {
    let server = try EmulationServer(address: "conflict.local")
    let conflict = EditTransport(statuses: [409, 200])
    try await EmulationServerLibrary(server: server, token: "writer", transport: conflict)
      .saveDetails(forKey: "source:wii1", title: "New Name", cover: nil)
    let reads = await conflict.revisionReads
    let writes = await conflict.writes
    XCTAssertEqual(reads, 2, "The revision is read again before the second try")
    XCTAssertEqual(writes.count, 2)

    for (statuses, expected) in [([409, 409], EmulationServerLibrary.ServerError.editConflict),
                                 ([403], .accessDenied), ([404], .editUnavailable)] {
      let library = EmulationServerLibrary(server: server, token: "reader", transport: EditTransport(statuses: statuses))
      do {
        try await library.saveDetails(forKey: "source:wii1", title: "New Name", cover: nil)
        XCTFail("A refused edit must be reported")
      } catch let error as EmulationServerLibrary.ServerError {
        XCTAssertEqual(String(describing: error), String(describing: expected))
        XCTAssertEqual(library.isAccessDenied(error), statuses == [403])
      }
    }
  }

  func testOriginIsFoundFromADiscInsideItsGameFolder() throws {
    let game = folder.appendingPathComponent("Software/EmulationServer/abc123", isDirectory: true)
    let disc = game.appendingPathComponent("discs/Disc 1.iso")
    try FileManager.default.createDirectory(at: disc.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([1]).write(to: disc)
    XCTAssertNil(RemoteGameOrigin.find(forGameAt: disc.path), "A game copied by an older build has no origin yet")

    let origin = RemoteGameOrigin(server: try XCTUnwrap(URL(string: "http://studio.local:8473")), key: "source:wii1")
    origin.write(in: game)
    XCTAssertEqual(RemoteGameOrigin.find(forGameAt: disc.path), origin)
    XCTAssertEqual(RemoteGameOrigin.find(forGameAt: disc.absoluteString), origin)
    XCTAssertEqual(RemoteGameOrigin.find(forGameAt: game.appendingPathComponent("Game.iso").path), origin)

    let other = folder.appendingPathComponent("Software/Imported/Game.iso")
    try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
    origin.write(in: other.deletingLastPathComponent())
    XCTAssertNil(RemoteGameOrigin.find(forGameAt: other.path), "Only an Emulation Server folder names a server")
  }

  // MARK: - RomM

  func testRomMCatalogWalksDolphinPlatformsAndCountsThem() async throws {
    let transport = RomMFixture(cover: Self.image(width: 20, height: 30))
    let address = try RomMAddress("https://romm.example")
    let client = try RomMClient(address: address, credential: .token("rmm_fixture"), transport: transport)
    let server = RomMServer(address: address)
    let library = RomMLibrary(server: server, client: client, covers: RemoteCoverCache(folder: folder))

    let count = try await library.gameCount()
    XCTAssertEqual(count, 5, "GameCube and Wii only")

    let first = try await library.openCatalog(search: " zelda ")
    XCTAssertEqual(first.entries.map(\.key), ["romm:10"])
    XCTAssertEqual(first.entries.map(\.game.platform), ["gc"])
    XCTAssertEqual(first.entries.map(\.hasArtwork), [true])
    XCTAssertTrue(first.hasMore)
    XCTAssertNil(first.total)
    let second = try await library.continueCatalog()
    XCTAssertEqual(second.entries.map(\.key), ["romm:20"])
    XCTAssertEqual(second.entries.map(\.game.platform), ["wii"])
    XCTAssertFalse(second.hasMore)
    XCTAssertEqual(second.total, 2, "The count of matches, once both platforms have answered")

    let queries = await transport.romQueries
    XCTAssertEqual(queries.map { $0["platform_ids"] }, ["3", "4"])
    XCTAssertTrue(queries.allSatisfy { $0["limit"] == "100" && $0["search_term"] == "zelda" })

    let entry = try XCTUnwrap(first.entries.first)
    let cover = await library.artwork(for: entry)
    XCTAssertNotNil(cover.flatMap(UIImage.init(data:)))
    _ = await library.artwork(for: entry)
    let coverRequests = await transport.coverRequests
    XCTAssertEqual(coverRequests, 1, "RomM cover paths change with the cover, so a kept cover is current")

    XCTAssertEqual(RomMLibrary.gameID(forKey: entry.key), 10)
    XCTAssertNil(RomMLibrary.gameID(forKey: "source:10"))
    XCTAssertEqual(try server.folder(for: entry), try server.folder(forGameID: 10))
    XCTAssertNotEqual(try server.folder(forGameID: 10), try server.folder(forGameID: 20))
    XCTAssertTrue(library.isAccessDenied(RomMError.accessDenied))
    XCTAssertFalse(library.isAccessDenied(RomMError.unavailable))
  }

  func testSourcePillSaysWhatOpeningItDoes() {
    XCTAssertEqual(LibrarySourcePill(id: "a", name: "Studio", glyph: "server.rack").accessibilityLabel, "Studio")
    XCTAssertTrue(LibrarySourcePill(id: "a", name: "Studio", glyph: "server.rack", count: 12).accessibilityLabel.hasPrefix("Studio, 12"))
    XCTAssertTrue(LibrarySourcePill(id: "a", name: "Studio", glyph: "server.rack", needsSetup: true).accessibilityLabel.contains("Studio"))
  }
}

// MARK: - Fixtures

/// Two libraries of scanned games, with counts, and one cover that answers a matching ETag with 304.
private actor CatalogTransport: ContinuityTransport {
  private let cover: Data
  private(set) var requests: [ContinuityRequest] = []
  private var offline = false

  init(cover: Data) {
    self.cover = cover
  }

  static let coverPath = "/api/v1/sources/wii1/matches/selections/artwork/content"

  var coverRequests: [ContinuityRequest] { requests.filter { $0.url.path == Self.coverPath } }

  func goOffline() { offline = true }
  var isOffline: Bool { offline }

  func queries(for path: String) -> [[String: String]] {
    requests.filter { $0.url.path == path }.map { request in
      let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }
  }

  func request(_ request: ContinuityRequest) async throws -> ContinuityResponse {
    requests.append(request)
    let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let body: String
    switch request.url.path {
    case "/api/v1/capabilities":
      body = #"{"protocol":{"major":1}}"#
    case "/api/v1/browse-libraries":
      body = #"{"items":[{"id":"lib1"},{"id":"lib2"}],"nextCursor":null}"#
    case "/api/v1/browse" where query.contains(where: { $0.name == "libraryId" && $0.value == "lib1" }):
      body = """
      {"items":[
        {"entityType":"source","source":{"id":"wii1","name":"Wii.rvz","title":"Wii title","systemId":"com.provenance.wii","size":10,
          "availability":"local","artworkAvailable":true,"artworkPath":"\(Self.coverPath)"}},
        {"entityType":"source","source":{"id":"outside","name":"Other.iso","systemId":"com.provenance.wii","size":10,
          "availability":"local","artworkAvailable":true,"artworkPath":"/api/v1/../../ui/secret"}}
      ],"systemCounts":[{"systemId":"com.provenance.gamecube","count":3},{"systemId":"com.provenance.wii","count":4},
        {"systemId":"com.provenance.jaguar","count":9}],"nextCursor":null}
      """
    case "/api/v1/browse":
      body = """
      {"items":[{"entityType":"source","source":{"id":"gc2","name":"Cube.iso","systemId":"com.provenance.gamecube","size":10,"availability":"local"}}],
       "systemCounts":[{"systemId":"com.provenance.gamecube","count":5}],"nextCursor":null}
      """
    case Self.coverPath:
      if request.headers["If-None-Match"] == "\"v1\"" { return ContinuityResponse(status: 304) }
      return ContinuityResponse(status: 200, headers: ["etag": "\"v1\""], body: cover)
    default:
      throw URLError(.unsupportedURL)
    }
    return ContinuityResponse(status: 200, body: Data(body.utf8))
  }

  func download(_ request: ContinuityRequest, to destination: URL, resumeOffset: Int64,
                progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> Int64 {
    throw URLError(.unsupportedURL)
  }
}

/// A server that accepts edits: the game is at revision 3, the item at 7, and each write answers the next
/// status in `statuses` (200 once they run out) with the revision after it.
private actor EditTransport: ContinuityTransport {
  private var statuses: [Int]
  private(set) var writes: [ContinuityRequest] = []
  private(set) var revisionReads = 0

  init(statuses: [Int] = []) {
    self.statuses = statuses
  }

  func request(_ request: ContinuityRequest) async throws -> ContinuityResponse {
    if request.method == "GET" {
      switch request.url.path {
      case "/api/v1/sources/wii1/matches/selections":
        revisionReads += 1
        return ContinuityResponse(status: 200, body: Data(#"{"sourceId":"wii1","revision":3,"matches":[]}"#.utf8))
      case "/api/v1/items/gc1":
        return ContinuityResponse(status: 200, body: Data(#"{"id":"gc1","revision":7}"#.utf8))
      default:
        throw URLError(.unsupportedURL)
      }
    }
    writes.append(request)
    let status = statuses.isEmpty ? 200 : statuses.removeFirst()
    guard status == 200 else { return ContinuityResponse(status: status) }
    let sent = request.headers["If-Match"].flatMap { Int($0.filter(\.isNumber)) } ?? 0
    return ContinuityResponse(status: 200, body: Data(#"{"sourceId":"wii1","revision":\#(sent + 1),"matches":[]}"#.utf8))
  }

  func download(_ request: ContinuityRequest, to destination: URL, resumeOffset: Int64,
                progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> Int64 {
    throw URLError(.unsupportedURL)
  }
}

/// The catalog still answers; cover requests fail as they do without a network.
private struct OfflineCovers: ContinuityTransport {
  let base: CatalogTransport

  func request(_ request: ContinuityRequest) async throws -> ContinuityResponse {
    if request.url.path == CatalogTransport.coverPath { throw URLError(.notConnectedToInternet) }
    return try await base.request(request)
  }

  func download(_ request: ContinuityRequest, to destination: URL, resumeOffset: Int64,
                progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> Int64 {
    throw URLError(.unsupportedURL)
  }
}

/// A RomM instance with a GameCube, a Wii and a Dreamcast platform, one game on each Dolphin platform.
private actor RomMFixture: RomMTransport {
  private let cover: Data
  private(set) var romQueries: [[String: String]] = []
  private(set) var coverRequests = 0

  init(cover: Data) {
    self.cover = cover
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) else {
      throw URLError(.badURL)
    }
    let body: Any
    switch url.path {
    case "/api/platforms":
      body = [
        ["id": 3, "slug": "ngc", "fs_slug": "gc", "name": "GameCube", "rom_count": 2],
        ["id": 4, "slug": "wii", "fs_slug": "wii", "name": "Wii", "rom_count": 3],
        ["id": 7, "slug": "dc", "fs_slug": "dreamcast", "name": "Dreamcast", "rom_count": 40],
      ]
    case "/api/roms":
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
      romQueries.append(query)
      let platform = Int(query["platform_ids"] ?? "") ?? 0
      let wii = platform == 4
      var game: [String: Any] = ["id": wii ? 20 : 10, "name": wii ? "Wii Game" : "Cube Game", "fs_name": "game.rvz",
                                 "platform_id": platform, "platform_slug": wii ? "wii" : "ngc", "fs_size_bytes": 99]
      if !wii { game["path_cover_small"] = "roms/3/10/cover/small.png?ts=1" }
      // One game matches the search on each platform, so each platform is a single page.
      body = ["items": [game], "limit": 100, "total": 1, "offset": 0]
    case "/assets/romm/resources/roms/3/10/cover/small.png":
      coverRequests += 1
      return (cover, response)
    default:
      throw URLError(.unsupportedURL)
    }
    return (try JSONSerialization.data(withJSONObject: body), response)
  }

  func download(for request: URLRequest) async throws -> (URL, URLResponse) {
    throw URLError(.unsupportedURL)
  }
}
