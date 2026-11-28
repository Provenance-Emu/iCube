// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class ShaderBrowserCatalogTests: XCTestCase {
  private let royale = "iCube.app/compiled_shaders/crt/crt-royale.oecompiledshader"
  private let lottes = "compiled_shaders/crt/crt-lottes.oecompiledshader"
  private let fxaa = "compiled_shaders/anti-aliasing/fxaa.oecompiledshader"
  private let lcd = "compiled_shaders/handheld/lcd-grid-v2.oecompiledshader"
  private let bilinear = "compiled_shaders/bilinear.oecompiledshader"
  private let mine = "/var/mobile/Documents/Shaders/Café Glow.oecompiledshader"
  private let nested = "compiled_shaders/crt/shaders/guest/crt-guest-advanced.oecompiledshader"

  private var catalog: ShaderBrowserCatalog {
    ShaderBrowserCatalog(presets: [royale, lottes, fxaa, lcd, bilinear, mine, nested].map {
      ($0, URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent)
    })
  }

  // MARK: - Categories

  func testCategoryIsTheTopFolderOfTheBundledLibrary() {
    XCTAssertEqual(ShaderBrowserCatalog.category(forPath: royale), "crt")
    XCTAssertEqual(ShaderBrowserCatalog.category(forPath: nested), "crt", "a preset deeper in a folder stays in that folder's group")
    XCTAssertEqual(ShaderBrowserCatalog.category(forPath: bilinear), "", "a preset at the top of the library")
    XCTAssertEqual(ShaderBrowserCatalog.category(forPath: mine), ShaderBrowserCatalog.userCategory)
  }

  func testCategoryTitles() {
    XCTAssertEqual(ShaderBrowserCatalog.categoryTitle("crt"), "CRT")
    XCTAssertEqual(ShaderBrowserCatalog.categoryTitle("anti-aliasing"), "Anti Aliasing")
    XCTAssertEqual(ShaderBrowserCatalog.categoryTitle("nes_raw_palette"), "NES Raw Palette")
    XCTAssertEqual(ShaderBrowserCatalog.categoryTitle("pixel-art-scaling"), "Pixel Art Scaling")
    XCTAssertEqual(ShaderBrowserCatalog.categoryTitle(""), L("Basic"))
    XCTAssertEqual(ShaderBrowserCatalog.categoryTitle(ShaderBrowserCatalog.userCategory), L("My Shaders"))
  }

  func testCategoriesPutThePlayersOwnFirstThenBasicThenByTitle() {
    XCTAssertEqual(catalog.categories, [ShaderBrowserCatalog.userCategory, "", "anti-aliasing", "crt", "handheld"])
  }

  // MARK: - Looks

  func testLooksComeFromThePathAndTheFolder() {
    XCTAssertEqual(ShaderLook.looks(path: lottes, category: "crt"), [.crt])
    XCTAssertEqual(ShaderLook.looks(path: fxaa, category: "anti-aliasing"), [.smoothing])
    XCTAssertEqual(ShaderLook.looks(path: lcd, category: "handheld"), [.lcd, .handheld])
    XCTAssertEqual(ShaderLook.looks(path: bilinear, category: ""), [])
  }

  func testOnlyLooksSomePresetHasAreOffered() {
    XCTAssertEqual(catalog.availableLooks, [.crt, .lcd, .handheld, .smoothing])
    XCTAssertEqual(ShaderBrowserCatalog(presets: []).availableLooks, [])
  }

  // MARK: - Search

  func testSearchMatchesEveryWordAcrossNameCategoryAndPath() {
    XCTAssertEqual(catalog.search("royale").map(\.path), [royale])
    XCTAssertEqual(Set(catalog.search("crt").map(\.path)), [royale, lottes, nested])
    XCTAssertEqual(catalog.search("crt guest").map(\.path), [nested])
    XCTAssertEqual(catalog.search("anti aliasing").map(\.path), [fxaa], "the category's title is searched")
    XCTAssertEqual(catalog.search("royale fxaa"), [], "every word must match")
  }

  func testSearchIgnoresCaseDiacriticsAndExtraSpace() {
    XCTAssertEqual(catalog.search("  CAFE   glow ").map(\.path), [mine])
    XCTAssertEqual(catalog.search("my shaders").map(\.path), [mine])
    XCTAssertEqual(catalog.search("").count, catalog.entries.count)
  }

  func testLooksNarrowTheSearchAndMustAllMatch() {
    XCTAssertEqual(Set(catalog.search("", looks: [.crt]).map(\.path)), [royale, lottes, nested])
    XCTAssertEqual(catalog.search("lottes", looks: [.crt]).map(\.path), [lottes])
    XCTAssertEqual(catalog.search("", looks: [.lcd, .handheld]).map(\.path), [lcd])
    XCTAssertEqual(catalog.search("", looks: [.crt, .lcd]), [])
  }

  // MARK: - Sections

  func testUnfilteredSectionsAreFavoritesRecentsThenEveryCategory() {
    let sections = catalog.sections(query: "", looks: [], favorites: [fxaa], recents: [lottes, fxaa, "gone.oecompiledshader", royale])
    XCTAssertEqual(sections.map(\.id), [
      ShaderBrowserCatalog.favoritesSectionID, ShaderBrowserCatalog.recentSectionID,
      "category:user", "category:", "category:anti-aliasing", "category:crt", "category:handheld",
    ])
    XCTAssertEqual(sections[0].entries.map(\.path), [fxaa])
    XCTAssertEqual(sections[1].entries.map(\.path), [lottes, royale], "most recent first, without favorites or presets that are gone")
    XCTAssertEqual(sections.last?.title, "Handheld")
    XCTAssertEqual(sections.filter { $0.id.hasPrefix("category:") }.flatMap(\.entries).count, catalog.entries.count, "every preset is in exactly one category")
  }

  func testEmptyFavoritesAndRecentsHaveNoSection() {
    let ids = catalog.sections(query: "", looks: [], favorites: [], recents: []).map(\.id)
    XCTAssertFalse(ids.contains(ShaderBrowserCatalog.favoritesSectionID))
    XCTAssertFalse(ids.contains(ShaderBrowserCatalog.recentSectionID))
  }

  func testFilteredSectionsAreOnlyTheCategoriesWithAMatch() {
    let sections = catalog.sections(query: "crt", looks: [], favorites: [royale], recents: [lottes])
    XCTAssertEqual(sections.map(\.id), ["category:crt"])
    XCTAssertEqual(sections[0].entries.count, 3)
    XCTAssertEqual(catalog.sections(query: "", looks: [.smoothing], favorites: [], recents: []).map(\.id), ["category:anti-aliasing"])
    XCTAssertEqual(catalog.sections(query: "nothing matches this", looks: [], favorites: [], recents: []), [])
  }

  func testIsFiltering() {
    XCTAssertFalse(ShaderBrowserCatalog.isFiltering(query: "  ", looks: []))
    XCTAssertTrue(ShaderBrowserCatalog.isFiltering(query: "c", looks: []))
    XCTAssertTrue(ShaderBrowserCatalog.isFiltering(query: "", looks: [.crt]))
  }

  // MARK: - Preview frame

  func testThePauseFrameIsCurrentForItsOwnSessionHoweverOldItIs() {
    XCTAssertTrue(ShaderPreviewFrame.isCurrent(captureSession: 7, runningSession: 7, fileExists: true))
    XCTAssertFalse(ShaderPreviewFrame.isCurrent(captureSession: 6, runningSession: 7, fileExists: true), "another game's frame")
    XCTAssertFalse(ShaderPreviewFrame.isCurrent(captureSession: nil, runningSession: 7, fileExists: true), "nothing was captured")
    XCTAssertFalse(ShaderPreviewFrame.isCurrent(captureSession: 7, runningSession: 7, fileExists: false))
  }
}
