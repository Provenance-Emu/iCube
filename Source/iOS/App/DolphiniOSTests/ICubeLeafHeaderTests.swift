// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class ICubeLeafHeaderTests: XCTestCase {
  func test_subtitle_isSettingsAtTheRoot_andTheParentWhenPushed() {
    XCTAssertEqual(ICubeLeafHeader.subtitle(parentTitle: nil), "Settings")
    XCTAssertEqual(ICubeLeafHeader.subtitle(parentTitle: "Controllers"), "Controllers")
  }

  func test_iconBadge_isOnTheSpacingScaleOrTheOneAllowedSize() {
    XCTAssertEqual(ICubeDesign.IconBadge.size, 44)
  }
}
