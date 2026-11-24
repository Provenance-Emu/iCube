// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

/// Answers each request with the next queued result and counts the requests.
final class FakeDolphinDepotTransport: DolphinDepotTransport, @unchecked Sendable {
  enum Answer {
    case body(String, status: Int = 200)
    case failure(URLError.Code)
  }

  private let lock = NSLock()
  private var answers: [Answer]
  private(set) var requests: [URL] = []
  private(set) var userAgents: [String] = []

  init(_ answers: [Answer]) {
    self.answers = answers
  }

  func data(from url: URL, userAgent: String) async throws -> (Data, HTTPURLResponse) {
    let answer: Answer = lock.withLock {
      requests.append(url)
      userAgents.append(userAgent)
      return answers.isEmpty ? .failure(.notConnectedToInternet) : answers.removeFirst()
    }
    switch answer {
    case .body(let text, let status):
      return (Data(text.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    case .failure(let code):
      throw URLError(code)
    }
  }
}

final class Clock: @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date(timeIntervalSince1970: 1_800_000_000)
  var now: Date { lock.withLock { date } }
  func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

final class DolphinDepotClientTests: XCTestCase {
  private static let one = #"[{"slug": "one", "name": "One"}]"#
  private static let two = #"[{"slug": "one", "name": "One"}, {"slug": "two", "name": "Two"}]"#

  private var cacheFile: URL!

  override func setUpWithError() throws {
    cacheFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("homebrew-client-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("catalogue.json")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: cacheFile.deletingLastPathComponent())
  }

  private func client(_ transport: FakeDolphinDepotTransport, clock: Clock = Clock()) -> DolphinDepotClient {
    DolphinDepotClient(transport: transport, userAgent: "iCube/test", cacheFile: cacheFile, now: { clock.now })
  }

  // MARK: - Endpoints

  func testCatalogueURLIsOneRequestWithPublishedFilters() throws {
    let url = DolphinDepotEndpoint.catalogue
    XCTAssertEqual(url.host, "api.dolphindepot.org")
    XCTAssertEqual(url.path, "/apps")
    let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    XCTAssertEqual(value("is_published"), "eq.true")
    XCTAssertEqual(value("app_versions.is_latest"), "eq.true")
    XCTAssertEqual(value("app_versions.is_published"), "eq.true")
    let select = try XCTUnwrap(value("select"))
    XCTAssertTrue(select.contains("app_version_assets(file_name,file_size)"), select)
    XCTAssertTrue(select.contains("categories(name,display_name,sort_order)"), select)
    XCTAssertTrue(select.contains("app_licenses(spdx,url,notes)"), select)
    // PostgREST reads these characters literally; an encoded parenthesis is a different query.
    XCTAssertFalse(url.absoluteString.contains("%28"), url.absoluteString)
    XCTAssertFalse(url.absoluteString.contains("%2C"), url.absoluteString)
  }

  func testImageURLInsertsImageFolder() {
    XCTAssertEqual(DolphinDepotEndpoint.image(path: "classicube/banner.png")?.absoluteString,
                   "https://cdn.dolphindepot.org/classicube/image/banner.png")
    for path in ["../x.png", "a/b/c.png", "banner.png", "", "a/", "/b.png", "a/.hidden"] {
      XCTAssertNil(DolphinDepotEndpoint.image(path: path), path)
    }
  }

  func testPackageURL() {
    XCTAssertEqual(
      DolphinDepotEndpoint.package(slug: "classicube", fileName: "classicube_2026-11-20-ab02ba3b_dist.zip")?.absoluteString,
      "https://cdn.dolphindepot.org/classicube/release/classicube_2026-11-20-ab02ba3b_dist.zip")
    XCTAssertNil(DolphinDepotEndpoint.package(slug: "classicube", fileName: "../a.zip"))
    XCTAssertNil(DolphinDepotEndpoint.package(slug: "..", fileName: "a.zip"))
  }

  func testPackageURLEncodesSpaces() {
    XCTAssertEqual(DolphinDepotEndpoint.package(slug: "a", fileName: "my game.zip")?.absoluteString,
                   "https://cdn.dolphindepot.org/a/release/my%20game.zip")
  }

  // MARK: - Cache

  func testSecondCallWithinTenMinutesUsesMemory() async throws {
    let transport = FakeDolphinDepotTransport([.body(Self.one)])
    let clock = Clock()
    let client = client(transport, clock: clock)
    let first = try await client.catalogue()
    clock.advance(599)
    let second = try await client.catalogue()
    XCTAssertEqual(transport.requests.count, 1)
    XCTAssertEqual(first.catalogue.titles.map(\.slug), ["one"])
    XCTAssertEqual(second.catalogue.titles.map(\.slug), ["one"])
    XCTAssertFalse(first.isSaved)
    XCTAssertEqual(transport.userAgents, ["iCube/test"])
  }

  func testCallAfterTenMinutesRefetches() async throws {
    let transport = FakeDolphinDepotTransport([.body(Self.one), .body(Self.two)])
    let clock = Clock()
    let client = client(transport, clock: clock)
    _ = try await client.catalogue()
    clock.advance(601)
    let second = try await client.catalogue()
    XCTAssertEqual(transport.requests.count, 2)
    XCTAssertEqual(second.catalogue.titles.count, 2)
  }

  func testForceRefreshRefetches() async throws {
    let transport = FakeDolphinDepotTransport([.body(Self.one), .body(Self.two)])
    let client = client(transport)
    _ = try await client.catalogue()
    let second = try await client.catalogue(forceRefresh: true)
    XCTAssertEqual(transport.requests.count, 2)
    XCTAssertEqual(second.catalogue.titles.count, 2)
  }

  // MARK: - Saved copy

  func testTransportFailureFallsBackToDiskCopy() async throws {
    _ = try await client(FakeDolphinDepotTransport([.body(Self.two)])).catalogue()
    let offline = client(FakeDolphinDepotTransport([.failure(.notConnectedToInternet)]))
    let saved = await offline.saved()
    XCTAssertEqual(saved?.titles.count, 2)
    let loaded = try await offline.catalogue()
    XCTAssertTrue(loaded.isSaved)
    XCTAssertEqual(loaded.catalogue.titles.map(\.slug), ["one", "two"])
  }

  func testTransportFailureWithNoDiskCopyThrows() async {
    let offline = client(FakeDolphinDepotTransport([.failure(.notConnectedToInternet)]))
    let saved = await offline.saved()
    XCTAssertNil(saved)
    do {
      _ = try await offline.catalogue()
      XCTFail("expected an error")
    } catch {}
  }

  func testHTTP500FallsBackAndDoesNotOverwriteDiskCopy() async throws {
    _ = try await client(FakeDolphinDepotTransport([.body(Self.two)])).catalogue()
    let loaded = try await client(FakeDolphinDepotTransport([.body("oops", status: 500)])).catalogue()
    XCTAssertTrue(loaded.isSaved)
    XCTAssertEqual(loaded.catalogue.titles.count, 2)
    XCTAssertEqual(try String(contentsOf: cacheFile, encoding: .utf8), Self.two)
  }

  func testErrorObjectOrEmptyArrayDoesNotOverwriteDiskCopy() async throws {
    _ = try await client(FakeDolphinDepotTransport([.body(Self.two)])).catalogue()
    for body in [#"{"code": "PGRST200", "message": "x"}"#, "[]", #"[{"slug": "../bad", "name": "Bad"}]"#] {
      let loaded = try await client(FakeDolphinDepotTransport([.body(body)])).catalogue()
      XCTAssertTrue(loaded.isSaved, body)
      XCTAssertEqual(loaded.catalogue.titles.count, 2, body)
      XCTAssertEqual(try String(contentsOf: cacheFile, encoding: .utf8), Self.two, body)
    }
  }

  func testEmptyCatalogueWithNoDiskCopyThrows() async {
    do {
      _ = try await client(FakeDolphinDepotTransport([.body("[]")])).catalogue()
      XCTFail("expected an error")
    } catch {}
  }

  func testFailedRefreshKeepsServingTheListInMemory() async throws {
    let transport = FakeDolphinDepotTransport([.body(Self.two), .failure(.timedOut)])
    let client = client(transport)
    _ = try await client.catalogue()
    let second = try await client.catalogue(forceRefresh: true)
    XCTAssertTrue(second.isSaved)
    XCTAssertEqual(second.catalogue.titles.count, 2)
  }

  // MARK: - Other fetches

  func testDataReturnsBodyAndRejectsBadStatus() async throws {
    let url = URL(string: "https://cdn.dolphindepot.org/a/image/b.png")!
    let good = try await client(FakeDolphinDepotTransport([.body("png")])).data(from: url)
    XCTAssertEqual(good, Data("png".utf8))
    do {
      _ = try await client(FakeDolphinDepotTransport([.body("no", status: 404)])).data(from: url)
      XCTFail("expected an error")
    } catch {}
  }
}
