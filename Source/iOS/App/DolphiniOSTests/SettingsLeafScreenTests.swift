// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class SettingsLeafScreenTests: XCTestCase {
  func test_back_withPaneBack_callsItAndDoesNotDismiss() {
    var paneBackCalls = 0
    var dismissCalls = 0
    SettingsLeafScreen.backAction(paneBack: { paneBackCalls += 1 }, dismiss: { dismissCalls += 1 })()
    XCTAssertEqual(paneBackCalls, 1)
    XCTAssertEqual(dismissCalls, 0)
  }

  func test_back_withoutPaneBack_dismisses() {
    var dismissCalls = 0
    SettingsLeafScreen.backAction(paneBack: nil, dismiss: { dismissCalls += 1 })()
    XCTAssertEqual(dismissCalls, 1)
  }

  func test_tvHeader_usesParentTitleAsSubtitle() {
    XCTAssertEqual(SettingsLeafScreen.header(title: "Players", parentTitle: "Controllers").subtitle, "Controllers")
    XCTAssertEqual(SettingsLeafScreen.header(title: "Audio", parentTitle: nil).subtitle, "Settings")
    XCTAssertEqual(SettingsLeafScreen.header(title: "Audio", parentTitle: nil).title, "Audio")
  }
}
