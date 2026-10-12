// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
@testable import iCube

final class SkinStorePolicyTests: XCTestCase {
  private var catalog: SkinCatalog!

  override func setUpWithError() throws {
    catalog = try SkinCatalog.decode(SkinCatalogFixture.data)
    // Guard against the lossy decoder making every "is hidden" test vacuous.
    XCTAssertEqual(catalog.skins.count, SkinCatalogFixture.entryCount)
  }

  private func section(_ id: String) throws -> SkinStoreSection? {
    let entry = try XCTUnwrap(catalog.skins.first { $0.id == id }, "missing \(id)")
    return SkinStorePolicy.section(for: entry)
  }

  private func entry(id: String = "x", systems: [String], gameType: String? = nil, url: String) throws -> SkinCatalogEntry {
    try SkinCatalogEntry(id: id, name: id, systems: systems, gameTypeIdentifier: gameType, downloadURL: XCTUnwrap(URL(string: url)))
  }

  // MARK: - Sections from the feed

  func testGameCubeAndWiiEntriesLandOnTheirShelves() throws {
    XCTAssertEqual(try section(SkinCatalogFixture.gameCubePocketID), .gameCube)
    XCTAssertEqual(try section(SkinCatalogFixture.mixedCaseGameCubeID), .gameCube, "codes compare lowercased")
    XCTAssertEqual(try section(SkinCatalogFixture.wiiID), .wii)
  }

  func testN64SkinsLandOnTheN64Shelf() throws {
    XCTAssertEqual(try section(SkinCatalogFixture.n64PackID), .nintendo64)
    XCTAssertEqual(try section(SkinCatalogFixture.n64SpaceURLID), .nintendo64)
    XCTAssertEqual(try section(SkinCatalogFixture.n64DeltaTypeID), .nintendo64)
  }

  func testZipsAndExtensionlessLinksAreHidden() throws {
    XCTAssertNil(try section(SkinCatalogFixture.n64ZipID), "an N64 .zip")
    XCTAssertNil(try section(SkinCatalogFixture.gbaZipID))
    XCTAssertNil(try section(SkinCatalogFixture.googleDriveID))
    XCTAssertNil(try SkinStorePolicy.section(for: entry(systems: ["gamecube"], url: "https://example.com/skin")))
  }

  func testOtherSystemsAreHidden() throws {
    XCTAssertNil(try section(SkinCatalogFixture.threeDSID))
    XCTAssertNil(try section(SkinCatalogFixture.gbaSpaceURLID))
    XCTAssertNil(try section(SkinCatalogFixture.unofficialID))
  }

  func testFixtureSectionCounts() {
    let grouped = SkinStorePolicy.sections(for: catalog.skins)
    XCTAssertEqual(grouped.map(\.section), [.gameCube, .wii, .nintendo64])
    XCTAssertEqual(grouped.map(\.entries.count), [2, 1, 3])
    XCTAssertEqual(grouped[0].entries.map(\.id), [SkinCatalogFixture.gameCubePocketID, SkinCatalogFixture.mixedCaseGameCubeID], "feed order kept")
  }

  // MARK: - Rules

  func testGameTypeSuffixPlacesAnEntryWithoutSystems() throws {
    XCTAssertEqual(try SkinStorePolicy.section(for: entry(systems: [], gameType: "public.aoshuang.game.ngc", url: "https://e.com/a.manicskin")), .gameCube)
    XCTAssertEqual(try SkinStorePolicy.section(for: entry(systems: [], gameType: "com.rileytestut.delta.game.wii", url: "https://e.com/a.deltaskin")), .wii)
    XCTAssertEqual(try SkinStorePolicy.section(for: entry(systems: [], gameType: "com.rileytestut.delta.game.n64", url: "https://e.com/a.deltaskin")), .nintendo64)
    XCTAssertNil(try SkinStorePolicy.section(for: entry(systems: [], gameType: "com.rileytestut.delta.game.gba", url: "https://e.com/a.deltaskin")))
  }

  func testExtensionMatchIsCaseInsensitive() throws {
    XCTAssertEqual(try SkinStorePolicy.section(for: entry(systems: ["GameCube"], url: "https://example.com/A.DeltaSkin")), .gameCube)
    XCTAssertEqual(try SkinStorePolicy.section(for: entry(systems: ["WII"], url: "https://example.com/a.MANICSKIN")), .wii)
  }

  func testPlaceholderCodeDoesNotHideARealSystem() throws {
    XCTAssertEqual(try SkinStorePolicy.section(for: entry(systems: ["unknown", "n64"], url: "https://e.com/a.manicskin")), .nintendo64)
  }

  func testGameCubeBeatsWiiBeatsN64() throws {
    XCTAssertEqual(try SkinStorePolicy.section(for: entry(systems: ["n64", "wii", "gamecube"], url: "https://e.com/a.deltaskin")), .gameCube)
    XCTAssertEqual(try SkinStorePolicy.section(for: entry(systems: ["n64", "wii"], url: "https://e.com/a.deltaskin")), .wii)
  }

  func testOrderedSectionsAndEmptySectionsOmitted() throws {
    let entries = try [
      entry(id: "n", systems: ["n64"], url: "https://e.com/n.deltaskin"),
      entry(id: "g", systems: ["gamecube"], url: "https://e.com/g.manicskin")
    ]
    let grouped = SkinStorePolicy.sections(for: entries)
    XCTAssertEqual(grouped.map(\.section), [.gameCube, .nintendo64])
    XCTAssertEqual(SkinStoreSection.ordered, [.gameCube, .wii, .nintendo64])
  }

  func testRetargetOnlyForTheN64Shelf() {
    XCTAssertNil(SkinStoreSection.gameCube.retarget)
    XCTAssertNil(SkinStoreSection.wii.retarget)
    XCTAssertEqual(SkinStoreSection.nintendo64.retarget, .gameCube)
  }

  func testDownloadFileNameUsesEntryIdAndURLExtension() throws {
    let pocket = try XCTUnwrap(catalog.skins.first { $0.id == SkinCatalogFixture.gameCubePocketID })
    XCTAssertEqual(SkinStorePolicy.downloadFileName(for: pocket), "ea60f2003d82ac9e.manicskin")
    XCTAssertEqual(try SkinStorePolicy.downloadFileName(for: entry(id: "a/b:c", systems: [], url: "https://e.com/x.ManicSkin")), "a-b-c.manicskin")
    XCTAssertNil(try SkinStorePolicy.downloadFileName(for: entry(systems: [], url: "https://e.com/x.zip")))
  }
}
#endif
