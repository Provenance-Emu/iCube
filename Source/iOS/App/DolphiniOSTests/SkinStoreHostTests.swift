// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SkinCatalogKit
import SkinKitManager
import SkinKitUI
import XCTest
@testable import iCube

/// iCube's side of the shared catalog browser: what it hands SkinKit (`SkinCatalogStoreHost.iCube`), and what that
/// makes the store list from the fixture feed.
@MainActor
final class SkinStoreHostTests: XCTestCase {
  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SkinStoreHostTests-\(UUID().uuidString)", isDirectory: true)

  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func installer() -> SkinStoreInstaller {
    SkinStoreInstaller(policy: .iCube, downloader: URLSessionSkinStoreDownloader(),
                       record: SkinStoreInstalledRecord(fileURL: directory.appendingPathComponent("store.json")),
                       installStep: { _, _ in throw SkinImportError.unreadableArchive })
  }

  private func host() -> SkinCatalogStoreHost {
    SkinCatalogStoreHost.iCube(installer: installer())
  }

  func testTheHostCarriesICubesPolicyAndFiltersByThisDevice() {
    let host = host()
    XCTAssertEqual(host.policy.sections, SkinStorePolicy.iCube.sections)
    XCTAssertEqual(host.device, SkinStoreDevice.current)
    XCTAssertNotNil(host.device, "iCube's store hides skins made for the other device class")
  }

  func testTheFixtureFeedListsOnICubesShelvesInOrder() throws {
    let catalog = try SkinCatalog.decode(SkinCatalogFixture.data)
    let host = host()
    let listing = SkinStoreListing(entries: catalog.skins, policy: host.policy, device: nil)
    XCTAssertEqual(listing.categories.map(\.section), [.gameCube, .wii, .nintendo64])
    XCTAssertEqual(listing.categories.map(\.entryCount), [2, 1, 3])
    XCTAssertEqual(listing.entries.count, 6)
  }

  func testCategoryChipsAndNotesUseICubesWording() {
    let host = host()
    XCTAssertEqual(SkinStorePolicy.iCube.sections.map(host.categoryTitle), ["GameCube", "Wii", "N64-style layout", "NES", "Super NES"])
    XCTAssertNil(host.categoryNote(.gameCube))
    XCTAssertNil(host.categoryNote(.wii))
    XCTAssertTrue(host.categoryNote(.nintendo64)?.hasPrefix("Built for N64-style layouts.") == true)
    XCTAssertTrue(host.categoryNote(.nes)?.hasPrefix("For Virtual Console and WiiWare games.") == true)
    XCTAssertEqual(host.categoryNote(.nes), host.categoryNote(.snes))
  }

  func testLoadFailuresAreDescribedInICubesWords() {
    // The banner is built from the error, so it runs through iCube's `L()` lookup like every other store message.
    let message = host().describeError(SkinCatalogError.network("offline"))
    XCTAssertTrue(message.hasPrefix("The skin catalog could not be downloaded:"), message)
  }

  func testTheBrowsersStringsComeFromTheCoreTable() {
    _ = host()
    XCTAssertEqual(SkinKitLocalization.tableName, "Core")
    // Every string the shared browser draws in a store has an entry, so a translation can be added beside it.
    for key in ["BROWSE SKINS", "Download skins from the community catalog", "Search by name, author, or tag...", "All",
                "SORT:", "Most viewed", "Recent", "A–Z", "Rating", "DOWNLOAD & INSTALL", "INSTALLED", "DOWNLOAD FAILED",
                "Offline. Showing skins from your last visit.", "NO SKINS FOUND", "CLEAR FILTERS", "Skin Catalog",
                "Skin Details", "INSTALL ALL (%lld)", "ALL INSTALLED"] {
      let missing = "\u{1}missing"
      XCTAssertNotEqual(Bundle.main.localizedString(forKey: key, value: missing, table: "Core"), missing, key)
    }
  }
}
#endif
