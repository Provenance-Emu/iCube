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

  /// GameCube ids 0…21 (ButtonType.h): the on-screen pad's buttons, sticks and triggers.
  func testTouchscreenGameCubeIDsReadAsTheOnScreenControl() {
    XCTAssertEqual(BindingDisplay.text(for: "`Button 0`", family: .touchscreen), "On-screen A")
    XCTAssertEqual(BindingDisplay.text(for: "`Button 2`", family: .touchscreen), "On-screen Start")
    XCTAssertEqual(BindingDisplay.text(for: "`Button 3`", family: .touchscreen), "On-screen X")
    XCTAssertEqual(BindingDisplay.text(for: "`Button 9`", family: .touchscreen), "On-screen D-Pad →")
    XCTAssertEqual(BindingDisplay.text(for: "`Axis 11`", family: .touchscreen), "On-screen Control Stick ↑")
    XCTAssertEqual(BindingDisplay.text(for: "`Axis 18`", family: .touchscreen), "On-screen C-Stick ←")
    XCTAssertEqual(BindingDisplay.text(for: "`Axis 21`", family: .touchscreen), "On-screen R")
  }

  /// Wii Remote, Nunchuk and Classic ids, as the bundled Touchscreen profile binds them.
  func testTouchscreenWiiIDsReadAsTheOnScreenControl() {
    XCTAssertEqual(BindingDisplay.text(for: "`Button 100`", family: .touchscreen), "On-screen A")
    XCTAssertEqual(BindingDisplay.text(for: "`Button 102`", family: .touchscreen), "On-screen −")
    XCTAssertEqual(BindingDisplay.text(for: "`Button 104`", family: .touchscreen), "On-screen Home")
    XCTAssertEqual(BindingDisplay.text(for: "`Button 106`", family: .touchscreen), "On-screen 2")
    XCTAssertEqual(BindingDisplay.text(for: "`Button 108`", family: .touchscreen), "On-screen D-Pad ↓")
    XCTAssertEqual(BindingDisplay.text(for: "`Button 201`", family: .touchscreen), "On-screen Nunchuk Z")
    XCTAssertEqual(BindingDisplay.text(for: "`Axis 205`", family: .touchscreen), "On-screen Nunchuk Stick ←")
    XCTAssertEqual(BindingDisplay.text(for: "`Button 307`", family: .touchscreen), "On-screen Classic ZL")
    XCTAssertEqual(BindingDisplay.text(for: "`Axis 322`", family: .touchscreen), "On-screen Classic Right Stick →")
  }

  /// What the app drives from touch or the device's motion reads by what it moves.
  func testTouchscreenPointerAndMotionIDs() {
    XCTAssertEqual(BindingDisplay.text(for: "`Axis 112`", family: .touchscreen), "Pointer Up")
    XCTAssertEqual(BindingDisplay.text(for: "`Axis 113`", family: .touchscreen), "Pointer Down")
    XCTAssertEqual(BindingDisplay.text(for: "`Axis 114`", family: .touchscreen), "Pointer Left")
    XCTAssertEqual(BindingDisplay.text(for: "`Axis 115`", family: .touchscreen), "Pointer Right")
    XCTAssertEqual(BindingDisplay.text(for: "`Button 118`", family: .touchscreen), "Pointer Hide")
    XCTAssertEqual(BindingDisplay.text(for: "`Axis 124`", family: .touchscreen), "Swing Forward")
    XCTAssertEqual(BindingDisplay.text(for: "`Axis 129`", family: .touchscreen), "Tilt Left")
    XCTAssertEqual(BindingDisplay.text(for: "`Button 133`", family: .touchscreen), "Shake Y")
    XCTAssertEqual(BindingDisplay.text(for: "`Axis 213`", family: .touchscreen), "Nunchuk Swing Backward")
    XCTAssertEqual(BindingDisplay.text(for: "`Axis 625`", family: .touchscreen), "Accelerometer Left")
    XCTAssertEqual(BindingDisplay.text(for: "`Axis 630`", family: .touchscreen), "Accelerometer Down")
    XCTAssertEqual(BindingDisplay.text(for: "`Axis 631`", family: .touchscreen), "Gyroscope Pitch Up")
    XCTAssertEqual(BindingDisplay.text(for: "`Axis 636`", family: .touchscreen), "Gyroscope Yaw Right")
    XCTAssertEqual(BindingDisplay.text(for: "`Axis 904`", family: .touchscreen), "Nunchuk Accelerometer Up")
    XCTAssertEqual(BindingDisplay.text(for: "`Rumble 700`", family: .touchscreen), "Rumble")
  }

  /// An id with no name here (the guitar's frets) keeps its number; a pad's input is never read as
  /// a touchscreen id.
  func testTouchscreenUnknownIDsKeepTheirNumber() {
    XCTAssertEqual(BindingDisplay.text(for: "`Button 402`", family: .touchscreen), "On-screen Button 402")
    XCTAssertEqual(BindingDisplay.text(for: "`Button 10`", family: .touchscreen), "On-screen Button 10")
    XCTAssertEqual(BindingDisplay.text(for: "`Button 100`", family: .xbox), "Button 100")
    XCTAssertNil(BindingDisplay.touchscreenName("Button A"))
    XCTAssertNil(BindingDisplay.touchscreenName("Cursor Y-"))
  }
}
