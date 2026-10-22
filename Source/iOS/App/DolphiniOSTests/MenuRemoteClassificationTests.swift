// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import GameController
import XCTest
@testable import iCube

/// Which controllers are TV remotes (menu devices) rather than players.
final class MenuRemoteClassificationTests: XCTestCase {
  private func remote(_ category: String, micro: Bool = true, extended: Bool = false) -> Bool {
    GCController.isMenuRemote(hasMicroGamepad: micro, hasExtendedGamepad: extended, productCategory: category)
  }

  func test_siriRemotes_andOtherAppleRemoteCategories_areMenuRemotes() {
    for category in GCController.menuRemoteProductCategories { XCTAssertTrue(remote(category), category) }
    XCTAssertTrue(remote("Some Future Remote"), "any category naming a remote")
  }

  /// Regression: the Switch Online SNES pad has a micro gamepad and no extended one, exactly like the
  /// Siri Remote, and was kept out of every player slot.
  func test_switchOnlineSNESPad_isAPlayer() {
    XCTAssertFalse(remote("Switch SNES Controller"))
  }

  func test_extendedPads_andPadsWithNeitherProfile_arePlayers() {
    XCTAssertFalse(remote("DualSense", extended: true))
    XCTAssertFalse(remote("Siri Remote (2nd Generation)", extended: true), "an extended profile is a pad")
    XCTAssertFalse(remote("Switch N64 Controller", micro: false), "the N64 pad goes through PhysicalProfileController")
    XCTAssertFalse(remote("MFi", micro: false))
  }
}
