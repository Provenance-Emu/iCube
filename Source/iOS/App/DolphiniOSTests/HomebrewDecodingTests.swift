// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class HomebrewDecodingTests: XCTestCase {
  private func catalogue() throws -> HomebrewCatalogue {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "catalogue", withExtension: "json", subdirectory: "Homebrew"))
    return try HomebrewCatalogue.decode(Data(contentsOf: url))
  }

  private func titleNamed(_ slug: String) throws -> HomebrewTitle {
    try XCTUnwrap(try catalogue().titles.first { $0.slug == slug })
  }

  private func row(_ extra: String) throws -> HomebrewTitle {
    let json = #"[{"slug": "t", "name": "T"\#(extra)}]"#
    return try XCTUnwrap(try HomebrewCatalogue.decode(Data(json.utf8)).titles.first)
  }

  func testDecodesFullRow() throws {
    let title = try titleNamed("block-quest")
    XCTAssertEqual(title.name, "Block Quest")
    XCTAssertEqual(title.author, "Example Author")
    XCTAssertEqual(title.summary, "A block puzzle for the test suite")
    XCTAssertEqual(title.details, "Push blocks. Reach the exit.")
    XCTAssertEqual(title.category?.name, "games")
    XCTAssertEqual(title.category?.displayName, "Games")
    XCTAssertEqual(title.downloads, 172)
    XCTAssertEqual(title.likes, 6)
    XCTAssertNotNil(title.updatedAt)
    XCTAssertEqual(title.latest?.fileName, "block-quest_2026-11-20-ab02ba3b_dist.zip")
    XCTAssertEqual(title.latest?.size, 711_640)
    XCTAssertEqual(title.latest?.version, "2026-11-20-ab02ba3b")
    XCTAssertEqual(title.latest?.versionSlug, "20261120ab02ba3b")
    XCTAssertNotNil(title.latest?.releaseDate)
    XCTAssertEqual(title.licence?.spdx, "MIT")
    XCTAssertEqual(title.licence?.url?.host, "example.org")
    XCTAssertEqual(title.hardware, ["Controller", "SD Gecko"])
    XCTAssertEqual(title.platforms, ["GameCube"])
    XCTAssertEqual(title.links, [HomebrewLink(label: "Level pack", url: URL(string: "https://example.org/levels")!)])
  }

  func testRowWithoutVersionIsListedWithoutDownload() throws {
    let title = try titleNamed("no-release")
    XCTAssertNil(title.latest)
    XCTAssertEqual(title.name, "No Release Yet")
  }

  func testMissingOptionalsDoNotDropTheRow() throws {
    let title = try titleNamed("bare")
    XCTAssertNil(title.category)
    XCTAssertEqual(title.screenshotPaths, [])
    XCTAssertNil(title.licence)
    XCTAssertEqual(title.details, "")
    XCTAssertEqual(title.author, "")
    XCTAssertEqual(title.downloads, 0)
    XCTAssertNil(title.latest)
  }

  func testUnsafeSlugIsDropped() throws {
    XCTAssertEqual(try catalogue().titles.map(\.slug), ["block-quest", "no-release", "bare"])
  }

  func testUnsafeFileNameMeansNoDownload() throws {
    let version = #""version": "1", "version_slug": "1", "size": 5"#
    XCTAssertNil(try row(#", "app_versions": [{\#(version), "app_version_assets": [{"file_name": "a/b.zip", "file_size": 5}]}]"#).latest)
    XCTAssertNil(try row(#", "app_versions": [{\#(version), "app_version_assets": [{"file_name": "a.rar", "file_size": 5}]}]"#).latest)
    XCTAssertNil(try row(#", "app_versions": [{\#(version), "app_version_assets": []}]"#).latest)
    XCTAssertEqual(try row(#", "app_versions": [{\#(version), "app_version_assets": [{"file_name": "a.zip", "file_size": 5}]}]"#).latest?.fileName, "a.zip")
  }

  func testRowsThatAreNotObjectsAreSkipped() throws {
    let data = Data(#"[7, {"slug": "ok", "name": "OK"}, {"slug": "nameless"}, "text"]"#.utf8)
    XCTAssertEqual(try HomebrewCatalogue.decode(data).titles.map(\.slug), ["ok"])
  }

  func testCoverPathPrefersScreenshotThenHeroThenBanner() throws {
    XCTAssertEqual(try titleNamed("block-quest").coverPath, "block-quest/screenshot0.png")
    XCTAssertEqual(try row(#", "hero_path": "t/hero.png", "banner_path": "t/banner.png""#).coverPath, "t/hero.png")
    XCTAssertEqual(try row(#", "banner_path": "t/banner.png""#).coverPath, "t/banner.png")
    XCTAssertNil(try row("").coverPath)
  }

  func testEmulatorsAndMediaUseFilesOnTheSDCard() throws {
    func category(_ name: String) throws -> HomebrewTitle {
      try row(#", "categories": {"name": "\#(name)", "display_name": "X", "sort_order": 1}"#)
    }
    XCTAssertTrue(try category("emulators").usesFilesOnSDCard)
    XCTAssertTrue(try category("media").usesFilesOnSDCard)
    XCTAssertFalse(try category("games").usesFilesOnSDCard)
    XCTAssertFalse(try row("").usesFilesOnSDCard)
  }

  func testListedForDolphinReadsThePlatformList() throws {
    func platforms(_ names: [(String, String)]) throws -> HomebrewTitle {
      let rows = names.map { #"{"platforms": {"id": "1", "name": "\#($0.0)", "display_name": "\#($0.1)"}}"# }
      return try row(#", "app_platforms": [\#(rows.joined(separator: ","))]"#)
    }
    XCTAssertTrue(try platforms([("gamecube", "GameCube"), ("dolphin", "Dolphin")]).listedForDolphin)
    XCTAssertFalse(try platforms([("gamecube", "GameCube"), ("panasonic_q", "Panasonic Q")]).listedForDolphin)
    XCTAssertFalse(try titleNamed("block-quest").listedForDolphin)
    XCTAssertFalse(try row("").listedForDolphin)
  }

  func testCategoriesAreDistinctAndOrdered() throws {
    XCTAssertEqual(try catalogue().categories.map(\.name), ["games", "utilities"])
  }

  func testHomebrewNameSafety() {
    for name in ["classicube", "240p-test-suite", "a_1.20_dist.zip"] {
      XCTAssertTrue(HomebrewName.isSafe(name), name)
    }
    for name in ["", ".hidden", "a/b", "..", "a\\b", "a\0b", "."] {
      XCTAssertFalse(HomebrewName.isSafe(name), name)
    }
  }
}
