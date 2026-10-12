// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
@testable import iCube

/// Decoding against a slice of the live feed. The count assertion comes first everywhere: the
/// decoder is lossy by design, so a test that only checks "the .zip entry is hidden" would also
/// pass if that entry had silently failed to decode.
final class SkinCatalogDecodingTests: XCTestCase {
  private func decodeFixture() throws -> SkinCatalog {
    try SkinCatalog.decode(SkinCatalogFixture.data)
  }

  private func entry(_ id: String, in catalog: SkinCatalog) throws -> SkinCatalogEntry {
    try XCTUnwrap(catalog.skins.first { $0.id == id }, "missing \(id)")
  }

  func testEveryFixtureEntryDecodes() throws {
    let catalog = try decodeFixture()
    XCTAssertEqual(catalog.skins.count, SkinCatalogFixture.entryCount)
    XCTAssertEqual(catalog.droppedEntryCount, 0)
  }

  func testRootFields() throws {
    let catalog = try decodeFixture()
    XCTAssertEqual(catalog.version, 2)
    XCTAssertEqual(catalog.totalSkins, 1358)
    let root = try XCTUnwrap(catalog.lastUpdated)
    XCTAssertEqual(root.timeIntervalSince1970, 1_791_090_684, accuracy: 1) // 2026-10-04T05:11:24Z
  }

  func testDateOnlyLastUpdatedParses() throws {
    let catalog = try decodeFixture()
    let dated = try entry(SkinCatalogFixture.mixedCaseGameCubeID, in: catalog)
    let date = try XCTUnwrap(dated.lastUpdated)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    XCTAssertEqual([parts.year, parts.month, parts.day], [2025, 9, 23])
  }

  func testNullFieldsDecodeAsNil() throws {
    let catalog = try decodeFixture()
    let pocket = try entry(SkinCatalogFixture.gameCubePocketID, in: catalog)
    XCTAssertEqual(pocket.name, "GameCube Pocket")
    XCTAssertEqual(pocket.author, "starvingartist")
    XCTAssertNil(pocket.thumbnailURL)
    XCTAssertNil(pocket.downloadCount)
    XCTAssertNil(pocket.lastUpdated)
    XCTAssertNil(pocket.groupId)
    XCTAssertEqual(pocket.gameTypeIdentifier, "public.aoshuang.game.ngc")
    XCTAssertEqual(pocket.gameTypeSuffix, "ngc")
  }

  func testGroupFields() throws {
    let catalog = try decodeFixture()
    let pack = try entry(SkinCatalogFixture.n64PackID, in: catalog)
    XCTAssertEqual(pack.groupId, "deltastyles:551")
    XCTAssertEqual(pack.groupOrder, 1)
  }

  /// Two feed URLs carry raw spaces; they must decode rather than drop the entry.
  func testURLWithRawSpacesDecodes() throws {
    let catalog = try decodeFixture()
    let n64 = try entry(SkinCatalogFixture.n64SpaceURLID, in: catalog)
    XCTAssertEqual(n64.downloadURL.host, "deltastyles.com")
    XCTAssertEqual(n64.downloadURL.pathExtension.lowercased(), "deltaskin")
    let gba = try entry(SkinCatalogFixture.gbaSpaceURLID, in: catalog)
    XCTAssertEqual(gba.downloadURL.lastPathComponent, "328%20Black%20GBA.deltaskin")
  }

  func testSystemsAreNormalisedForComparison() throws {
    let catalog = try decodeFixture()
    let threeDS = try entry(SkinCatalogFixture.threeDSID, in: catalog)
    XCTAssertEqual(threeDS.systems, ["threeDS"])
    XCTAssertEqual(threeDS.normalizedSystems, ["threeds"])
    let mixed = try entry(SkinCatalogFixture.mixedCaseGameCubeID, in: catalog)
    XCTAssertEqual(mixed.normalizedSystems, ["gamecube"])
  }

  func testSourceHost() throws {
    let catalog = try decodeFixture()
    XCTAssertEqual(try entry(SkinCatalogFixture.gameCubePocketID, in: catalog).sourceHost, "deltastyles.com")
    // `owner/repo` is not a host: fall back to the download URL's host.
    XCTAssertEqual(try entry(SkinCatalogFixture.unofficialID, in: catalog).sourceHost, "raw.githubusercontent.com")
    XCTAssertEqual(try entry(SkinCatalogFixture.mixedCaseGameCubeID, in: catalog).sourceHost, "example.com")
  }

  /// One malformed entry must not cost the rest of the catalog.
  func testBadEntryIsDroppedNotFatal() throws {
    let json = #"""
    {
      "version": 2,
      "lastUpdated": "not a date",
      "skins": [
        { "id": "good", "name": "Good", "systems": ["gamecube"],
          "downloadURL": "https://example.com/good.manicskin", "rating": "five stars" },
        { "id": "no-url", "name": "No URL", "systems": ["gamecube"] },
        { "id": 42, "name": "Numeric id", "systems": ["gamecube"],
          "downloadURL": "https://example.com/x.manicskin" },
        { "id": "no-systems", "name": "No systems",
          "downloadURL": "https://example.com/y.deltaskin", "lastUpdated": "2025-13-45" }
      ]
    }
    """#
    let catalog = try SkinCatalog.decode(Data(json.utf8))
    XCTAssertEqual(catalog.skins.map(\.id), ["good", "no-systems"])
    XCTAssertEqual(catalog.droppedEntryCount, 2)
    XCTAssertNil(catalog.lastUpdated)
    XCTAssertNil(catalog.skins[0].rating, "a mistyped optional drops the field, not the entry")
    XCTAssertEqual(catalog.skins[1].systems, [])
    XCTAssertNil(catalog.skins[1].lastUpdated)
    XCTAssertNil(catalog.skins[1].gameTypeSuffix)
  }

  func testNonCatalogJSONThrows() {
    XCTAssertThrowsError(try SkinCatalog.decode(Data("[1, 2, 3]".utf8)))
    XCTAssertThrowsError(try SkinCatalog.decode(Data("<html>".utf8)))
  }
}
#endif
