// DolphiniOSTests/PauseTileLayoutTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// The pause screen's cards: 4 columns on tvOS; on iPhone and iPad the hero placement and the grid width decide.
final class PauseTileLayoutTests: XCTestCase {
  func test_tv_isFour() {
    XCTAssertEqual(PauseTileLayout.tvColumns, 4)
  }

  func test_hero_bannerOnAPhoneInPortrait_columnElsewhere() {
    XCTAssertEqual(PauseTileLayout.touchHero(width: 402, isCompactHeight: false), PauseTileLayout.bannerHero)
    XCTAssertEqual(PauseTileLayout.touchHero(width: 874, isCompactHeight: true), PauseTileLayout.compactHeightHero)
    XCTAssertEqual(PauseTileLayout.touchHero(width: 1032, isCompactHeight: false), PauseTileLayout.iPadHero)
    XCTAssertEqual(PauseTileLayout.touchHero(width: 1376, isCompactHeight: false), PauseTileLayout.iPadHero)
  }

  func test_cardColumns_byGridWidth() {
    XCTAssertEqual(PauseTileLayout.cardColumns(forGridWidth: 370), 3, "iPhone portrait")
    XCTAssertEqual(PauseTileLayout.cardColumns(forGridWidth: 528), 4, "iPhone landscape beside the hero")
    XCTAssertEqual(PauseTileLayout.cardColumns(forGridWidth: 752), 4, "iPad portrait beside the hero")
    XCTAssertEqual(PauseTileLayout.cardColumns(forGridWidth: 1096), 5, "iPad landscape beside the hero")
  }
}
