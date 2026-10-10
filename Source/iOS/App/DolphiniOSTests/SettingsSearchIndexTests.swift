// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class SettingsSearchIndexTests: XCTestCase {
  private let sections = SettingsRootModelBuilder.sections(isIOS: true, achievements: true)
  private lazy var index = SettingsSearchIndex(sections: sections)

  /// Spec §9: search covers every root row title.
  func test_everyRootRowTitle_isFound() {
    for entry in sections.flatMap(\.entries) {
      XCTAssertTrue(index.hits(query: entry.title).contains(SettingsSearchHit(entryID: entry.id, rowTitle: nil)), entry.title)
    }
  }

  func test_leafRowTitle_matches_withTheRowNamed() {
    let hits = index.hits(query: "v-sync")
    XCTAssertTrue(hits.contains { $0.entryID == "graphics-video" && $0.rowTitle == "V-Sync" })
  }

  /// Migrated leaves are found through their generated row titles, not hand-kept keywords.
  func test_migratedLeafRows_areFoundByTheirOwnTitles() {
    XCTAssertTrue(index.hits(query: "msaa").contains { $0.entryID == "graphics-enhancements" && ($0.rowTitle ?? "").contains("MSAA") })
    XCTAssertTrue(index.hits(query: "texture cache").contains { $0.entryID == "graphics-hacks" })
    XCTAssertTrue(index.hits(query: "adaptive clock").contains { $0.entryID == "performance-tuning" })
  }

  func test_advancedRows_areFoundByTheirOwnTitles() {
    XCTAssertTrue(index.hits(query: "memory size").contains { $0.entryID == "advanced" && ($0.rowTitle ?? "").contains("Memory Size") })
  }

  func test_graphicsAdvancedRows_areFoundByTheirOwnTitles() {
    XCTAssertTrue(index.hits(query: "present drawable").contains { $0.entryID == "graphics-advanced" && ($0.rowTitle ?? "").contains("Present Drawable") })
    XCTAssertTrue(index.hits(query: "prefetch").contains { $0.entryID == "graphics-advanced" && ($0.rowTitle ?? "").contains("Prefetch") })
  }

  func test_gameCubeRows_areFoundByTheirOwnTitles() {
    XCTAssertTrue(index.hits(query: "main menu").contains { $0.entryID == "console-gamecube" })
  }

  func test_wiiRows_areFoundByTheirOwnTitles() {
    XCTAssertTrue(index.hits(query: "sensor bar").contains { $0.entryID == "console-wii" })
  }

  func test_audioRows_areFoundByTheirOwnTitles() {
    XCTAssertTrue(index.hits(query: "audio stretching").contains { $0.entryID == "audio" })
  }

  func test_interfaceRows_areFoundByTheirOwnTitles() {
    XCTAssertTrue(index.hits(query: "panic handlers").contains { $0.entryID == "interface" })
  }

  func test_generalRows_areFoundByTheirOwnTitles() {
    XCTAssertTrue(index.hits(query: "dual core").contains { $0.entryID == "general" })
  }

  func test_validatorRows_areSearchable() {
    XCTAssertTrue(index.hits(query: "Validate").contains { $0.entryID == "performance-tuning" })
  }

  /// A hand-built leaf has no model, so its title, description and keywords still count.
  func test_handBuiltLeaf_isFoundByItsDescription() {
    XCTAssertTrue(index.hits(query: "wi-fi").contains(SettingsSearchHit(entryID: "web-ui", rowTitle: nil)))
  }

  func test_debugRows_areFoundByTheirOwnTitles() {
    XCTAssertTrue(index.hits(query: "fastmem").contains { $0.entryID == "debug" })
    XCTAssertTrue(index.hits(query: "wireframe").contains { $0.entryID == "debug" })
  }

  /// Punctuation and spacing do not matter: these worked on develop through hand-kept keywords.
  func test_query_ignoresPunctuationAndSpacing() {
    XCTAssertTrue(index.hits(query: "vsync").contains { $0.entryID == "graphics-video" && $0.rowTitle == "V-Sync" })
    XCTAssertTrue(index.hits(query: "fast forward").contains { $0.entryID == "performance-tuning" && ($0.rowTitle ?? "").contains("Fast-Forward") })
    XCTAssertEqual(SettingsSearchIndex.fold(" Fast-Forward CTR "), "fastforwardctr")
  }

  func test_punctuationOnlyQuery_hasNoHits() {
    XCTAssertTrue(index.hits(query: "- -").isEmpty)
  }

  func test_emptyQuery_hasNoHits() {
    XCTAssertTrue(index.hits(query: "  ").isEmpty)
  }
}
