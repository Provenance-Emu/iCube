// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class GameBananaDecodingTests: XCTestCase {
  private func fixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json", subdirectory: "GameBanana"))
    return try Data(contentsOf: url)
  }

  private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
    try JSONDecoder().decode(Value.self, from: Data(json.utf8))
  }

  func testNameMatchDecodesGames() throws {
    let page = try JSONDecoder().decode(GameBananaPage<GameBananaGame>.self, from: fixture("NameMatch"))
    XCTAssertEqual(page.records.map(\.id), [5706, 8932])
    XCTAssertEqual(page.records.first?.name, "Super Smash Bros. Melee")
    XCTAssertEqual(page.records.first?.iconURL?.host, "images.gamebanana.com")
    XCTAssertTrue(page.isComplete)
  }

  func testModIndexDecodesSummaryFields() throws {
    let page = try JSONDecoder().decode(GameBananaPage<GameBananaModSummary>.self, from: fixture("ModIndex"))
    XCTAssertEqual(page.recordCount, 490)
    XCTAssertFalse(page.isComplete)
    let mod = try XCTUnwrap(page.records.first)
    XCTAssertEqual(mod.id, 40711)
    XCTAssertEqual(mod.name, "Super Smash Bros. Melee 64")
    XCTAssertEqual(mod.categoryName, "Modpacks")
    XCTAssertEqual(mod.submitter?.name, "ConnorRentz")
    XCTAssertEqual(mod.game?.id, 5706)
    XCTAssertEqual(mod.likeCount, 49)
    XCTAssertTrue(mod.hasFiles)
    XCTAssertEqual(mod.images.count, 2)
  }

  func testImageURLPicksSmallestThumbnailThatIsWideEnough() throws {
    let page = try JSONDecoder().decode(GameBananaPage<GameBananaModSummary>.self, from: fixture("ModIndex"))
    let image = try XCTUnwrap(page.records.first?.images.first)
    XCTAssertEqual(image.url(minimumWidth: 200)?.lastPathComponent, "220-90_5f19af3cab14a.jpg")
    XCTAssertEqual(image.url(minimumWidth: 5000)?.lastPathComponent, "800-90_5f19af3cab14a.jpg")
    let bare = try XCTUnwrap(page.records.first?.images.last)
    XCTAssertEqual(bare.url(minimumWidth: 530)?.lastPathComponent, "100-90_5f19af420ddc3.jpg")
  }

  func testSearchRecordsLackLikeCountButDecode() throws {
    let page = try JSONDecoder().decode(GameBananaPage<GameBananaModSummary>.self, from: fixture("Search"))
    XCTAssertEqual(page.records.count, 2)
    XCTAssertNil(page.records[0].likeCount)
    XCTAssertEqual(page.records[0].game?.name, "Super Smash Bros. Melee")
  }

  func testCategoriesAreABareArray() throws {
    let categories = try JSONDecoder().decode([GameBananaCategory].self, from: fixture("Categories"))
    XCTAssertEqual(categories.map(\.name), ["Effects", "Skins"])
    XCTAssertEqual(categories.last?.itemCount, 385)
  }

  func testProfileDecodesFilesLicenseAndCredits() throws {
    let detail = try JSONDecoder().decode(GameBananaModDetail.self, from: fixture("ProfilePage"))
    XCTAssertEqual(detail.summary.id, 40711)
    XCTAssertEqual(detail.summary.version, "")
    XCTAssertEqual(detail.downloadCount, 46278)
    let file = try XCTUnwrap(detail.files.first)
    XCTAssertEqual(file.id, 476085)
    XCTAssertEqual(file.fileName, "super_smash_bros_melee_64_-_july_20.zip")
    XCTAssertEqual(file.size, 943_512_349)
    XCTAssertEqual(file.downloadURL?.absoluteString, "https://gamebanana.com/dl/476085")
    XCTAssertEqual(file.md5, "05f12a28c7e5cfc027e4ba301270a51d")
    XCTAssertEqual(file.virusScanResult, "clean")
    XCTAssertEqual(file.analysisWarnings["contains_exe"]?.count, 2)
    XCTAssertEqual(detail.licenseChecklist.allowed, ["Download and install this Mod"])
    XCTAssertEqual(detail.licenseChecklist.forbidden, ["Use this Mod or components of this Mod commercially"])
    XCTAssertTrue(detail.licenseHTML.contains("Attribution-NonCommercial-NoDerivs"))
    XCTAssertEqual(detail.credits.first?.name, "Key Authors")
    XCTAssertEqual(detail.credits.first?.members.map(\.name), ["ConnorRentz", "Cjag"])
    XCTAssertEqual(detail.credits.first?.members.first?.role, "Primary Mod Creator")
    XCTAssertEqual(detail.summary.categoryName, "Modpacks")
  }

  func testPhpEmptyArraysDecodeAsEmptyMaps() throws {
    let json = """
    {"_idRow": "12", "_sName": "X", "_aFiles": [{"_idRow": 5, "_sFile": "a.zip", "_nFilesize": 10,
     "_aAnalysisWarnings": [], "_sMd5Checksum": "ABCDEF"}],
     "_aLicenseChecklist": [], "_aRootCategory": null, "_aCredits": [{"_sGroupName": "G",
     "_aAuthors": [{"_idRow": "9", "_sName": "A"}]}]}
    """
    let detail = try decode(GameBananaModDetail.self, json)
    XCTAssertEqual(detail.summary.id, 12)
    XCTAssertEqual(detail.files.first?.analysisWarnings, [:])
    XCTAssertEqual(detail.files.first?.md5, "abcdef")
    XCTAssertEqual(detail.licenseChecklist, .empty)
    XCTAssertNil(detail.summary.categoryName)
    XCTAssertEqual(detail.credits.first?.members.first?.name, "A")
  }

  func testMissingFieldsFallBackInsteadOfThrowing() throws {
    let mod = try decode(GameBananaModSummary.self, #"{"_idRow": 3}"#)
    XCTAssertEqual(mod.name, "")
    XCTAssertFalse(mod.hasFiles)
    XCTAssertTrue(mod.images.isEmpty)
    let page = try decode(GameBananaPage<GameBananaModSummary>.self, "{}")
    XCTAssertTrue(page.records.isEmpty)
  }

  func testRecordWithoutIdThrows() {
    XCTAssertThrowsError(try decode(GameBananaModSummary.self, #"{"_sName": "x"}"#))
  }

  func testAPIErrorBodyDecodes() throws {
    let error = try decode(GameBananaAPIError.self, #"{"_sErrorCode": "INPUT_ERRORS", "_aErrorData": {}}"#)
    XCTAssertEqual(error.code, "INPUT_ERRORS")
  }
}

final class GameBananaClientTests: XCTestCase {
  private final class StubTransport: GameBananaTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [(url: URL, userAgent: String)] = []
    private(set) var concurrent = 0
    private(set) var maxConcurrent = 0
    var status = 200
    var body = Data("{}".utf8)

    func data(from url: URL, userAgent: String) async throws -> (Data, HTTPURLResponse) {
      lock.withLock {
        requests.append((url, userAgent))
        concurrent += 1
        maxConcurrent = max(maxConcurrent, concurrent)
      }
      try await Task.sleep(nanoseconds: 20_000_000)
      lock.withLock { concurrent -= 1 }
      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
      return (body, response)
    }
  }

  func testEndpointsEncodeFilterKeys() {
    let url = GameBananaEndpoint.modIndex(gameID: 5706, categoryID: 9660, sort: .mostLiked, page: 2)
    let query = url.absoluteString.components(separatedBy: "?").last ?? ""
    XCTAssertTrue(query.contains("_aFilters%5BGeneric_Game%5D=5706"))
    XCTAssertTrue(query.contains("_aFilters%5BGeneric_Category%5D=9660"))
    XCTAssertTrue(query.contains("_sSort=Generic_MostLiked"))
    XCTAssertTrue(query.contains("_nPage=2"))
    XCTAssertEqual(url.path, "/apiv11/Mod/Index")
  }

  func testSearchEscapesTheTerm() {
    let url = GameBananaEndpoint.search(gameID: 5896, query: "mario & luigi", page: 1)
    XCTAssertTrue(url.absoluteString.contains("_sSearchString=mario%20%26%20luigi"))
    XCTAssertTrue(url.absoluteString.contains("_idGameRow=5896"))
  }

  func testCategoriesAlwaysSendASort() {
    XCTAssertTrue(GameBananaEndpoint.categories(gameID: 5706).absoluteString.contains("_sSort=a_to_z"))
  }

  func testRequestsCarryTheUserAgentAndAreCached() async throws {
    let transport = StubTransport()
    let client = GameBananaClient(transport: transport, userAgent: "iCube/9.9")
    _ = try await client.mods(gameID: 1)
    _ = try await client.mods(gameID: 1)
    XCTAssertEqual(transport.requests.count, 1)
    XCTAssertEqual(transport.requests.first?.userAgent, "iCube/9.9")
  }

  func testCacheExpires() async throws {
    let transport = StubTransport()
    let clock = ManualClock()
    let client = GameBananaClient(transport: transport, userAgent: "iCube/1", now: { clock.now })
    _ = try await client.mods(gameID: 1)
    clock.advance(by: 1000)
    _ = try await client.mods(gameID: 1)
    XCTAssertEqual(transport.requests.count, 2)
  }

  func testRequestsRunOneAtATime() async throws {
    let transport = StubTransport()
    let client = GameBananaClient(transport: transport, userAgent: "iCube/1")
    try await withThrowingTaskGroup(of: Void.self) { group in
      for gameID in 1...5 {
        group.addTask { _ = try await client.mods(gameID: gameID) }
      }
      try await group.waitForAll()
    }
    XCTAssertEqual(transport.requests.count, 5)
    XCTAssertEqual(transport.maxConcurrent, 1)
  }

  func testNon2xxThrows() async {
    let transport = StubTransport()
    transport.status = 503
    let client = GameBananaClient(transport: transport, userAgent: "iCube/1")
    do {
      _ = try await client.mods(gameID: 1)
      XCTFail("expected a status error")
    } catch let error as GameBananaClientError {
      guard case .status(503) = error else { return XCTFail("wrong error \(error)") }
    } catch {
      XCTFail("wrong error \(error)")
    }
  }

  func testRejectedQueryThrowsInsteadOfReturningAnEmptyPage() async {
    let transport = StubTransport()
    transport.body = Data(#"{"_sErrorCode": "INPUT_ERRORS", "_aErrorData": {"_sSort": {}}}"#.utf8)
    let client = GameBananaClient(transport: transport, userAgent: "iCube/1")
    do {
      _ = try await client.mods(gameID: 1)
      XCTFail("expected an API error")
    } catch let error as GameBananaAPIError {
      XCTAssertEqual(error.code, "INPUT_ERRORS")
    } catch {
      XCTFail("wrong error \(error)")
    }
  }
}

private final class ManualClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_000_000)

  var now: Date { lock.withLock { current } }

  func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}
