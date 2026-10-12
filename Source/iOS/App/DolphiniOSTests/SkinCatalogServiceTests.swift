// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
@testable import iCube

/// Cache and TTL behaviour with an injected fetch and clock; no network.
final class SkinCatalogServiceTests: XCTestCase {
  private final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _fetches = 0
    private var _status = 200
    private var _offline = false

    var fetches: Int { lock.withLock { _fetches } }
    func set(status: Int) { lock.withLock { _status = status } }
    func set(offline: Bool) { lock.withLock { _offline = offline } }

    func respond(_ url: URL) throws -> (Data, URLResponse) {
      let (status, offline) = lock.withLock {
        _fetches += 1
        return (_status, _offline)
      }
      if offline { throw URLError(.notConnectedToInternet) }
      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
      return (SkinCatalogFixture.data, response ?? URLResponse())
    }
  }

  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { _now } }
    func advance(_ seconds: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(seconds) } }
  }

  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SkinCatalogServiceTests-\(UUID().uuidString)", isDirectory: true)
  private let server = FakeServer()
  private let clock = Clock()
  private var cacheURL: URL { directory.appendingPathComponent(SkinCatalogService.cacheFileName) }

  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func makeService() -> SkinCatalogService {
    let server = server
    let clock = clock
    return SkinCatalogService(catalogURLs: [URL(fileURLWithPath: "/catalog.json")], cacheURL: cacheURL,
                              ttl: 24 * 60 * 60, now: { clock.now }, fetch: { url in try server.respond(url) })
  }

  func testFirstFetchHitsNetworkAndWritesCache() async throws {
    let catalog = try await makeService().catalog()
    XCTAssertEqual(catalog.skins.count, SkinCatalogFixture.entryCount)
    XCTAssertEqual(server.fetches, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
  }

  func testWithinTTLServesMemoryWithoutFetching() async throws {
    let service = makeService()
    _ = try await service.catalog()
    clock.advance(60 * 60)
    _ = try await service.catalog()
    XCTAssertEqual(server.fetches, 1)
  }

  /// A fresh launch (new service instance) must honour the disk cache's age, not refetch every time.
  func testFreshDiskCacheIsUsedAcrossInstances() async throws {
    _ = try await makeService().catalog()
    clock.advance(23 * 60 * 60)
    let catalog = try await makeService().catalog()
    XCTAssertEqual(catalog.skins.count, SkinCatalogFixture.entryCount)
    XCTAssertEqual(server.fetches, 1)
  }

  func testExpiredCacheRefetches() async throws {
    let service = makeService()
    _ = try await service.catalog()
    clock.advance(25 * 60 * 60)
    _ = try await service.catalog()
    XCTAssertEqual(server.fetches, 2)
  }

  func testForceRefreshAlwaysFetches() async throws {
    let service = makeService()
    _ = try await service.catalog()
    _ = try await service.catalog(forceRefresh: true)
    XCTAssertEqual(server.fetches, 2)
  }

  func testOfflineFallsBackToStaleDiskCacheAndSaysSo() async throws {
    _ = try await makeService().catalog()
    clock.advance(30 * 24 * 60 * 60)
    server.set(offline: true)
    let load = try await makeService().load()
    XCTAssertEqual(load.catalog.skins.count, SkinCatalogFixture.entryCount)
    XCTAssertTrue(load.isFallback)
    XCTAssertNotNil(load.networkError)
  }

  func testHTTPErrorFallsBackToCacheOrThrows() async throws {
    server.set(status: 503)
    do {
      _ = try await makeService().catalog()
      XCTFail("expected a throw with no cache")
    } catch let error as SkinCatalogError {
      guard case .httpStatus(503) = error else { return XCTFail("unexpected \(error)") }
    }
    server.set(status: 200)
    let service = makeService()
    _ = try await service.catalog()
    server.set(status: 500)
    let fallback = try await service.catalog(forceRefresh: true)
    XCTAssertEqual(fallback.skins.count, SkinCatalogFixture.entryCount)
  }

  func testSecondURLIsTriedWhenFirstFails() async throws {
    let failing = URL(fileURLWithPath: "/down.json")
    let working = URL(fileURLWithPath: "/catalog.json")
    let server = server
    let service = SkinCatalogService(catalogURLs: [failing, working], cacheURL: cacheURL, fetch: { url in
      if url == failing { throw URLError(.cannotFindHost) }
      return try server.respond(url)
    })
    let catalog = try await service.catalog()
    XCTAssertEqual(catalog.skins.count, SkinCatalogFixture.entryCount)
  }

  func testCachedCatalogNeverTouchesNetwork() async throws {
    let empty = await makeService().cachedCatalog()
    XCTAssertNil(empty)
    _ = try await makeService().catalog()
    let cached = await makeService().cachedCatalog()
    XCTAssertEqual(cached?.skins.count, SkinCatalogFixture.entryCount)
    XCTAssertEqual(server.fetches, 1)
  }

  func testCorruptDiskCacheIsDiscarded() async throws {
    try Data("<html>".utf8).write(to: cacheURL)
    let catalog = try await makeService().catalog()
    XCTAssertEqual(catalog.skins.count, SkinCatalogFixture.entryCount)
    XCTAssertEqual(server.fetches, 1)
  }
}
#endif
