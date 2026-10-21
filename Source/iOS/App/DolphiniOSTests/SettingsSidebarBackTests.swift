// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class SettingsSidebarBackTests: XCTestCase {
  /// About > Help: focus fell to the sidebar while Help loaded, and Menu closed all of Settings.
  func test_pushedPage_popsInsteadOfLeaving() {
    XCTAssertEqual(SettingsSidebarBack.action(paneDepth: 1, honorsPress: true), .popPane)
  }

  /// Controllers > Player 1 > Device, then Left: one Menu goes back to Player 1, not past it.
  func test_deeperPage_popsOneLevel() {
    XCTAssertEqual(SettingsSidebarBack.action(paneDepth: 2, honorsPress: true), .popPane)
  }

  func test_leafAtRoot_leavesSettings() {
    XCTAssertEqual(SettingsSidebarBack.action(paneDepth: 0, honorsPress: true), .leaveSettings)
  }

  /// The release of the press that opened Settings must not close it again.
  func test_leafAtRoot_ignoresTheOpeningPress() {
    XCTAssertEqual(SettingsSidebarBack.action(paneDepth: 0, honorsPress: false), .ignore)
  }
  func test_rootPaneCannotDismissWhenSidebarDoesNotHaveFocus() {
    XCTAssertEqual(SettingsSidebarBack.action(paneDepth: 0, honorsPress: true, sidebarFocused: false), .focusSidebar)
  }

  func test_sidebarFocusIsRequiredToLeaveAfterPaneBack() {
    XCTAssertEqual(SettingsSidebarBack.action(paneDepth: 0, honorsPress: true, sidebarFocused: true), .leaveSettings)
  }

}
