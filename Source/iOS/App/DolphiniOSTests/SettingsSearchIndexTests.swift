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

  func test_validatorRows_areSearchable() {
    XCTAssertTrue(index.hits(query: "Validate").contains { $0.entryID == "performance-tuning" })
  }

  /// A hand-built leaf has no model, so its keywords still count.
  func test_keyword_matchesAHandBuiltLeaf() {
    XCTAssertTrue(index.hits(query: "fastmem").contains(SettingsSearchHit(entryID: "debug", rowTitle: nil)))
  }

  func test_emptyQuery_hasNoHits() {
    XCTAssertTrue(index.hits(query: "  ").isEmpty)
  }
}
