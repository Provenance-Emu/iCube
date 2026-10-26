// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SkinCatalogKit
import SkinKitManager
import XCTest
@testable import iCube

@MainActor
final class SkinStoreViewModelTests: XCTestCase {
  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SkinStoreViewModelTests-\(UUID().uuidString)", isDirectory: true)

  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func service(offline: Bool) -> SkinCatalogService {
    SkinCatalogService(catalogURLs: [URL(fileURLWithPath: "/catalog.json")],
                       cacheURL: directory.appendingPathComponent(SkinCatalogService.cacheFileName),
                       fetch: { url in
                         if offline { throw URLError(.notConnectedToInternet) }
                         return (SkinCatalogFixture.data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) ?? URLResponse())
                       })
  }

  private func installer() -> SkinStoreInstaller {
    SkinStoreInstaller(policy: .iCube, downloader: URLSessionSkinStoreDownloader(),
                       record: SkinStoreInstalledRecord(fileURL: directory.appendingPathComponent("store.json")),
                       installStep: { _, _ in throw SkinImportError.unreadableArchive })
  }

  func testLoadGroupsTheCatalogIntoShelves() async {
    let model = SkinStoreViewModel(service: service(offline: false), installer: installer(), library: SkinLibrary(rootURL: directory.appendingPathComponent("Skins")))
    await model.loadIfNeeded()
    XCTAssertEqual(model.loadState, .loaded)
    XCTAssertEqual(model.shelves.map(\.section), [.gameCube, .wii, .nintendo64])
    XCTAssertEqual(model.shelves.map(\.entries.count), [2, 1, 3])
    XCTAssertNil(model.offlineMessage)
  }

  func testOfflineWithNoCacheFails() async {
    let model = SkinStoreViewModel(service: service(offline: true), installer: installer(), library: SkinLibrary(rootURL: directory.appendingPathComponent("Skins")))
    await model.loadIfNeeded()
    guard case .failed = model.loadState else { return XCTFail("expected failed, got \(model.loadState)") }
    XCTAssertTrue(model.shelves.isEmpty)
  }

  func testOfflineWithACacheShowsTheCacheAndSaysSo() async {
    _ = try? await service(offline: false).catalog()
    let model = SkinStoreViewModel(service: service(offline: true), installer: installer(), library: SkinLibrary(rootURL: directory.appendingPathComponent("Skins")))
    await model.refresh()
    XCTAssertEqual(model.loadState, .loaded)
    XCTAssertEqual(model.shelves.count, 3)
    // The banner is built from the error, so it runs through iCube's `L()` lookup like every other store message.
    XCTAssertTrue(model.offlineMessage?.hasPrefix("The skin catalog could not be downloaded:") == true, "\(model.offlineMessage ?? "nil")")
  }
}
#endif
