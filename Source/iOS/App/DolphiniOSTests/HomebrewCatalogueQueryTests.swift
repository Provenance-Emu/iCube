// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

enum HomebrewTestData {
  static let games = HomebrewCategory(name: "games", displayName: "Games", sortOrder: 1)
  static let emulators = HomebrewCategory(name: "emulators", displayName: "Emulators", sortOrder: 2)
  static let utilities = HomebrewCategory(name: "utilities", displayName: "Utilities", sortOrder: 3)

  static func version(_ slug: String = "10", size: Int64 = 100, fileName: String = "pkg.zip") -> HomebrewVersion {
    HomebrewVersion(version: slug, versionSlug: slug, size: size, fileName: fileName, releaseDate: nil, changelog: nil)
  }

  static func title(_ slug: String, name: String? = nil, author: String = "", summary: String = "",
                    category: HomebrewCategory? = games, downloads: Int = 0, updated: TimeInterval? = nil,
                    latest: HomebrewVersion? = version(), screenshots: [String] = [],
                    platforms: [String] = []) -> HomebrewTitle {
    HomebrewTitle(slug: slug, name: name ?? slug, author: author, summary: summary, details: "", category: category,
                  bannerPath: nil, heroPath: nil, screenshotPaths: screenshots, downloads: downloads, likes: 0,
                  updatedAt: updated.map(Date.init(timeIntervalSince1970:)), latest: latest, licence: nil, links: [],
                  hardware: [], platforms: platforms)
  }
}

final class HomebrewCatalogueQueryTests: XCTestCase {
  private typealias Data = HomebrewTestData

  func testSectionsFollowSortOrderAndPreviewMostDownloaded() {
    let catalogue = HomebrewCatalogue(titles: [
      Data.title("tool", category: Data.utilities, downloads: 9),
      Data.title("b", downloads: 5),
      Data.title("a", downloads: 5),
      Data.title("c", downloads: 50),
      Data.title("d", downloads: 1),
      Data.title("emu", category: Data.emulators),
    ])
    let sections = HomebrewCatalogueQuery.sections(catalogue, previewCount: 3)
    XCTAssertEqual(sections.map(\.category.name), ["games", "emulators", "utilities"])
    XCTAssertEqual(sections.map(\.count), [4, 1, 1])
    XCTAssertEqual(sections[0].preview.map(\.slug), ["c", "a", "b"])
  }

  func testTitlesWithoutCategoryAreInNoSection() {
    let catalogue = HomebrewCatalogue(titles: [Data.title("loose", category: nil), Data.title("a")])
    XCTAssertEqual(HomebrewCatalogueQuery.sections(catalogue, previewCount: 4).flatMap(\.preview).map(\.slug), ["a"])
  }

  func testSearchStillFindsTitlesWithoutCategory() {
    let catalogue = HomebrewCatalogue(titles: [Data.title("loose", category: nil)])
    XCTAssertEqual(HomebrewCatalogueQuery.search("loose", in: catalogue).map(\.slug), ["loose"])
  }

  func testSortByName() {
    let catalogue = HomebrewCatalogue(titles: [
      Data.title("1", name: "zebra"), Data.title("2", name: "Éclair"), Data.title("3", name: "apple"),
      Data.title("4", name: "Mango", category: Data.utilities),
    ])
    XCTAssertEqual(HomebrewCatalogueQuery.titles(in: Data.games, of: catalogue, sort: .name).map(\.name),
                   ["apple", "Éclair", "zebra"])
  }

  func testSortByMostDownloaded() {
    let catalogue = HomebrewCatalogue(titles: [
      Data.title("b", downloads: 2), Data.title("a", downloads: 2), Data.title("c", downloads: 7),
    ])
    XCTAssertEqual(HomebrewCatalogueQuery.titles(in: Data.games, of: catalogue, sort: .mostDownloaded).map(\.slug),
                   ["c", "a", "b"])
  }

  func testSortByRecentlyUpdated() {
    let catalogue = HomebrewCatalogue(titles: [
      Data.title("never"), Data.title("old", updated: 10), Data.title("new", updated: 20),
    ])
    XCTAssertEqual(HomebrewCatalogueQuery.titles(in: Data.games, of: catalogue, sort: .recentlyUpdated).map(\.slug),
                   ["new", "old", "never"])
  }

  func testSearchMatchesNameAuthorAndSummary() {
    let catalogue = HomebrewCatalogue(titles: [
      Data.title("1", name: "Pokémon Clone", author: "Ann"),
      Data.title("2", name: "Blocks", author: "Pokefan"),
      Data.title("3", name: "Racer", summary: "A poke at racing"),
      Data.title("4", name: "Other"),
    ])
    XCTAssertEqual(HomebrewCatalogueQuery.search("POKE", in: catalogue).map(\.name), ["Blocks", "Pokémon Clone", "Racer"])
    XCTAssertEqual(HomebrewCatalogueQuery.search("  clone   ann ", in: catalogue).map(\.name), ["Pokémon Clone"])
    XCTAssertEqual(HomebrewCatalogueQuery.search("clone bob", in: catalogue).map(\.name), [])
  }

  func testBlankSearchReturnsNothing() {
    let catalogue = HomebrewCatalogue(titles: [Data.title("a")])
    XCTAssertEqual(HomebrewCatalogueQuery.search("   ", in: catalogue), [])
    XCTAssertEqual(HomebrewCatalogueQuery.search("", in: catalogue), [])
  }

  func testEverySortHasATitle() {
    XCTAssertEqual(Set(HomebrewSort.allCases.map(\.title)).count, HomebrewSort.allCases.count)
  }
}
