// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// The launch seeds: a default the app prefers is written only where the user never chose.
final class LaunchDefaultsTests: XCTestCase {
  private static let wiiLinkKey = "Dolphin.Core.EnableWiiLink"

  /// The host's Base layer before the test: these tests delete and change a real key.
  private var savedBase: [String: String] = [:]

  override func setUp() {
    super.setUp()
    savedBase = DOLConfigBridge.baseLayerSnapshot()
  }

  override func tearDown() {
    DOLConfigBridge.restoreBaseLayerSnapshot(savedBase)
    DOLConfigBridge.flushSettingsToDisk()
    super.tearDown()
  }

  private func seed() {
    DolphinCoreService.seedLaunchDefaults(fastmemAvailable: FastmemManager.shared().fastmemAvailable)
  }

  func testWiiConnect24IsOnForAnInstallThatNeverChoseIt() {
    DOLConfigBridge.deleteBaseLayerKeys([Self.wiiLinkKey])
    XCTAssertNil(DOLConfigBridge.baseLayerSnapshot()[Self.wiiLinkKey])
    XCTAssertFalse(DOLConfigBridge.mainWiiWiiLinkEnable(), "The compiled default is off")

    seed()

    XCTAssertTrue(DOLConfigBridge.mainWiiWiiLinkEnable())
    XCTAssertEqual(DOLConfigBridge.baseLayerSnapshot()[Self.wiiLinkKey], "True")
  }

  func testAStoredWiiConnect24ChoiceIsNeverOverridden() {
    DOLConfigBridge.setMainWiiWiiLinkEnable(false)
    seed()
    XCTAssertFalse(DOLConfigBridge.mainWiiWiiLinkEnable(), "Turned off by the user stays off")

    DOLConfigBridge.setMainWiiWiiLinkEnable(true)
    seed()
    XCTAssertTrue(DOLConfigBridge.mainWiiWiiLinkEnable())
  }
}
