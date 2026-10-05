// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// The live seam's pure parts: the owner mapping the bridge calls rely on, and that `check` runs
/// the core's parser (the app-side bridge, no core change).
final class PlayerScreenIOTests: XCTestCase {

  func test_ownerMapping() {
    XCTAssertEqual(RemapGroupOwner.gcPad.controlGroupOwner, .gcPad)
    XCTAssertEqual(RemapGroupOwner.wiimote.controlGroupOwner, .wiimote)
    XCTAssertEqual(RemapGroupOwner.nunchuk.controlGroupOwner, .nunchuk)
    XCTAssertEqual(RemapGroupOwner.classic.controlGroupOwner, .classic)
  }

  @MainActor
  func test_liveCheck_usesTheCoresParser() {
    let io = LivePlayerScreenIO()
    XCTAssertTrue(io.check("`Button A`").canSave)
    XCTAssertTrue(io.check("").canSave, "blank unbinds")
    XCTAssertFalse(io.check("(`Button A`").canSave)
  }

  /// The builder finds the pointer's Vertical Offset by the core's untranslated name in the IR group.
  @MainActor
  func test_liveNumericSettings_carryTheCoresNameForVerticalOffset() throws {
    let settings = LivePlayerScreenIO().numericSettings(owner: .wiimote, group: AdvancedSettingGroups.pointerGroup, port: 4)
    try XCTSkipIf(settings.isEmpty, "no Wii Remote config in this host")
    let offset = try XCTUnwrap(settings.first { $0.coreName == AdvancedSettingGroups.verticalOffsetName })
    XCTAssertTrue(PlayerScreenModelBuilder.isVerticalOffset(offset))
    XCTAssertEqual(offset.defaultValue, 10)
  }
}
