// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

@MainActor
final class HomebrewBrowserModelTests: XCTestCase {
  private static let one = #"[{"slug": "one", "name": "One"}]"#
  private static let two = #"[{"slug": "one", "name": "One"}, {"slug": "two", "name": "Two"}]"#

  private var scratch: HomebrewScratch!
  private var root: URL!
  private var cacheFile: URL!

  override func setUp() async throws {
    scratch = try HomebrewScratch()
    root = scratch.root.appendingPathComponent("Homebrew", isDirectory: true)
    cacheFile = scratch.root.appendingPathComponent("cache/catalogue.json")
  }

  override func tearDown() async throws {
    scratch = nil
  }

  private func model(_ answers: [FakeDolphinDepotTransport.Answer]) -> (HomebrewBrowserModel, FakeDolphinDepotTransport) {
    let transport = FakeDolphinDepotTransport(answers)
    let client = DolphinDepotClient(transport: transport, userAgent: "iCube/test", cacheFile: cacheFile)
    return (HomebrewBrowserModel(client: client, root: root), transport)
  }

  func testLoadShowsTheFreshList() async {
    let (model, transport) = model([.body(Self.two)])
    await model.load()
    XCTAssertEqual(model.catalogue?.titles.map(\.slug), ["one", "two"])
    XCTAssertFalse(model.isShowingSavedList)
    XCTAssertNil(model.errorMessage)
    XCTAssertFalse(model.isLoading)
    XCTAssertEqual(transport.requests.count, 1)
  }

  func testLoadWithNoNetworkAndNoCopySetsErrorMessage() async {
    let (model, _) = model([.failure(.notConnectedToInternet)])
    await model.load()
    XCTAssertNil(model.catalogue)
    XCTAssertNotNil(model.errorMessage)
    XCTAssertFalse(model.isLoading)
  }

  func testLoadWithNoNetworkButACopyFlagsSavedList() async {
    let (first, _) = model([.body(Self.two)])
    await first.load()
    let (offline, _) = model([.failure(.notConnectedToInternet)])
    await offline.load()
    XCTAssertEqual(offline.catalogue?.titles.count, 2)
    XCTAssertTrue(offline.isShowingSavedList)
    XCTAssertNil(offline.errorMessage)
  }

  func testRetryAfterAnErrorClearsIt() async {
    let (model, _) = model([.failure(.timedOut), .body(Self.one)])
    await model.load()
    XCTAssertNotNil(model.errorMessage)
    await model.refresh()
    XCTAssertNil(model.errorMessage)
    XCTAssertEqual(model.catalogue?.titles.count, 1)
  }

  func testRefreshForcesARequest() async {
    let (model, transport) = model([.body(Self.one), .body(Self.two)])
    await model.load()
    await model.refresh()
    XCTAssertEqual(transport.requests.count, 2)
    XCTAssertEqual(model.catalogue?.titles.count, 2)
  }

  func testLoadSweepsOrphans() async throws {
    try scratch.file("Homebrew/gone/apps/gone/opening.bnr")
    try scratch.file("Homebrew/kept/apps/kept/kept.dol")
    var index = HomebrewInstalledIndex()
    index.titles["gone"] = .init(versionSlug: "1", version: "1", programPath: "gone/apps/gone/gone.dol")
    index.titles["kept"] = .init(versionSlug: "1", version: "1", programPath: "kept/apps/kept/kept.dol")
    try index.save(root: root)

    let (model, _) = model([.body(Self.one)])
    await model.load()
    XCTAssertEqual(Array(model.index.titles.keys), ["kept"])
    XCTAssertEqual(Array(HomebrewInstalledIndex.load(root: root).titles.keys), ["kept"])
    XCTAssertFalse(scratch.exists("Homebrew/gone"))
    XCTAssertTrue(scratch.exists("Homebrew/kept/apps/kept/kept.dol"))
  }

  func testStateOfATitleFollowsTheIndex() async throws {
    try scratch.file("Homebrew/one/one.dol")
    var index = HomebrewInstalledIndex()
    index.titles["one"] = .init(versionSlug: "1", version: "1", programPath: "one/one.dol")
    try index.save(root: root)
    let (model, _) = model([.body(Self.two)])
    await model.load()
    let titles = try XCTUnwrap(model.catalogue?.titles)
    XCTAssertEqual(model.state(of: titles[0]), .installed)
    XCTAssertEqual(model.state(of: titles[1]), .notInstalled)
    try FileManager.default.removeItem(at: root.appendingPathComponent("one/one.dol"))
    model.reloadIndex()
    XCTAssertEqual(model.state(of: titles[0]), .notInstalled)
  }

  func testNoRootMeansNothingIsInstalled() async throws {
    let transport = FakeDolphinDepotTransport([.body(Self.one)])
    let client = DolphinDepotClient(transport: transport, userAgent: "iCube/test", cacheFile: cacheFile)
    let model = HomebrewBrowserModel(client: client, root: nil)
    await model.load()
    XCTAssertEqual(model.state(of: try XCTUnwrap(model.catalogue?.titles.first)), .notInstalled)
  }
}
