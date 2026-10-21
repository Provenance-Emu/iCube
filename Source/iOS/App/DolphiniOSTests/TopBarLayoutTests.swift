// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class TopBarLayoutTests: XCTestCase {
  func testDirectPauseAndSavesDestinationsHaveNoMoreMenuDetour() {
    XCTAssertEqual(TopBarControl.pause.directDestination, .pauseMenu)
    XCTAssertEqual(TopBarControl.saves.directDestination, .saveStates)
    XCTAssertEqual(TopBarControl.shaders.directDestination, .shaders)
    XCTAssertNil(TopBarControl.save.directDestination, "Saving has a separate action, never a navigation side effect")
    XCTAssertNil(TopBarControl.load.directDestination, "Loading has a separate action, never a navigation side effect")
  }

  func testPortraitUsesSingleCompactActionSetOnPhoneAndPad() {
    for size in [CGSize(width: 320, height: 568), CGSize(width: 393, height: 852), CGSize(width: 1024, height: 1366)] {
      XCTAssertFalse(TopBarLayout.usesWideRow(width: size.width, height: size.height, accessibilityType: false))
    }
    XCTAssertEqual(TopBarLayout.compactControls, [.pause, .save, .load, .saves, .options, .hide])
  }

  func testWideLandscapeAndSplitWindowUseAvailableGeometry() {
    XCTAssertTrue(TopBarLayout.usesWideRow(width: 1366, height: 1024, accessibilityType: false))
    XCTAssertFalse(TopBarLayout.usesWideRow(width: 900, height: 600, accessibilityType: false))
    XCTAssertEqual(TopBarLayout.wideControls, [.pause, .save, .load, .saves, .fastForward, .audio, .controller, .display, .shaders, .hide])
  }

  func testStandardToolbarHeightAndMinimumTargets() {
    XCTAssertLessThanOrEqual(TopBarLayout.standardHeight, 80)
    XCTAssertGreaterThanOrEqual(TopBarLayout.minimumTarget, 44)
    XCTAssertGreaterThanOrEqual(TopBarLayout.controlHeight, TopBarLayout.minimumTarget)
    XCTAssertLessThanOrEqual(CGFloat(TopBarLayout.compactControls.count) * TopBarLayout.minimumTarget + 2 * TopBarLayout.horizontalPadding, 320)
  }

  func testAccessibilityTypeKeepsPrimaryActionsInAdaptiveLayout() {
    XCTAssertFalse(TopBarLayout.usesWideRow(width: 1366, height: 1024, accessibilityType: true))
    XCTAssertEqual(Array(TopBarLayout.compactControls.prefix(4)), [.pause, .save, .load, .saves])
  }
}
