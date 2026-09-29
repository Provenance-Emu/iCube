// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class BindingDisplayTests: XCTestCase {
  func testFamilyFromQualifier() {
    XCTAssertEqual(DeviceFamily.from(qualifier: "MFi/0/Xbox Wireless Controller"), .xbox)
    XCTAssertEqual(DeviceFamily.from(qualifier: "MFi/1/DualSense Wireless Controller"), .playStation)
    XCTAssertEqual(DeviceFamily.from(qualifier: "MFi/0/DUALSHOCK 4 Wireless Controller"), .playStation)
    XCTAssertEqual(DeviceFamily.from(qualifier: "MFi/0/Pro Controller"), .nintendo)
    XCTAssertEqual(DeviceFamily.from(qualifier: "MFi/0/Backbone One"), .genericMFi)
    XCTAssertEqual(DeviceFamily.from(qualifier: "iOS/0/Touchscreen"), .touchscreen)
    XCTAssertEqual(DeviceFamily.from(qualifier: ""), .unknown)
  }

  func testFaceButtonsUseTheFamilysLabels() {
    XCTAssertEqual(BindingDisplay.text(for: "`Button A`", family: .xbox), "A")
    XCTAssertEqual(BindingDisplay.text(for: "`Button A`", family: .playStation), "✕")
    XCTAssertEqual(BindingDisplay.text(for: "`Button B`", family: .playStation), "○")
    XCTAssertEqual(BindingDisplay.text(for: "`Button X`", family: .playStation), "□")
    XCTAssertEqual(BindingDisplay.text(for: "`Button Y`", family: .playStation), "△")
    // GameController reports the button by POSITION, so Nintendo's "A" position is Apple's B.
    XCTAssertEqual(BindingDisplay.text(for: "`Button A`", family: .nintendo), "B")
  }

  func testSticksShouldersAndSystemButtons() {
    XCTAssertEqual(BindingDisplay.text(for: "`L Stick Y+`", family: .xbox), "Left Stick ↑")
    XCTAssertEqual(BindingDisplay.text(for: "`R Stick X-`", family: .xbox), "Right Stick ←")
    XCTAssertEqual(BindingDisplay.text(for: "`D-Pad Left`", family: .xbox), "D-Pad ←")
    XCTAssertEqual(BindingDisplay.text(for: "`R Shoulder`", family: .xbox), "RB")
    XCTAssertEqual(BindingDisplay.text(for: "`R Shoulder`", family: .playStation), "R1")
    XCTAssertEqual(BindingDisplay.text(for: "`L Trigger`", family: .playStation), "L2")
    XCTAssertEqual(BindingDisplay.text(for: "`Menu`", family: .xbox), "≡ Menu")
    XCTAssertEqual(BindingDisplay.text(for: "`Menu`", family: .playStation), "Options")
    XCTAssertEqual(BindingDisplay.text(for: "`L Stick`", family: .xbox), "Left Stick Click")
  }

  func testUnboundAndUnreducibleExpressions() {
    XCTAssertEqual(BindingDisplay.text(for: "", family: .xbox), RemapExpression.unboundDisplay)
    XCTAssertEqual(BindingDisplay.text(for: "  ", family: .xbox), RemapExpression.unboundDisplay)
    XCTAssertEqual(BindingDisplay.text(for: "`Button A` | `Button B`", family: .xbox), "`Button A` | `Button B`")
    XCTAssertEqual(BindingDisplay.text(for: "`Paddle 1`", family: .xbox), "Paddle 1")
  }

  func testTouchscreenInputsKeepTheirName() {
    XCTAssertEqual(BindingDisplay.text(for: "`Button 3`", family: .touchscreen), "On-screen Button 3")
  }
}
