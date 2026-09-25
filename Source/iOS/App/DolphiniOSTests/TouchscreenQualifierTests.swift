// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// The touch overlay writes to the Touchscreen instance named by the bound qualifier
/// (`iOS/<id>/Touchscreen`): GC pads 0-3, Wii Remotes 4-7.
final class TouchscreenQualifierTests: XCTestCase {
  func testParsesInstanceId() {
    XCTAssertEqual(ControllerManager.touchscreenDeviceId(fromQualifier: "iOS/0/Touchscreen"), 0)
    XCTAssertEqual(ControllerManager.touchscreenDeviceId(fromQualifier: "iOS/4/Touchscreen"), 4)
    XCTAssertEqual(ControllerManager.touchscreenDeviceId(fromQualifier: "iOS/7/Touchscreen"), 7)
  }

  func testRejectsOtherDevices() {
    XCTAssertNil(ControllerManager.touchscreenDeviceId(fromQualifier: ""))
    XCTAssertNil(ControllerManager.touchscreenDeviceId(fromQualifier: "MFi/0/Gamepad A"))
    XCTAssertNil(ControllerManager.touchscreenDeviceId(fromQualifier: "DSUClient/0/Pad"))
    XCTAssertNil(ControllerManager.touchscreenDeviceId(fromQualifier: "Bluetooth/0/Wii Remote"))
    XCTAssertNil(ControllerManager.touchscreenDeviceId(fromQualifier: "iOS/x/Touchscreen"))
    XCTAssertNil(ControllerManager.touchscreenDeviceId(fromQualifier: "iOS/Touchscreen"))
  }

  func testWiimoteIdBaseMatchesBackend() {
    XCTAssertEqual(ControllerManager.touchscreenWiimoteIdBase, 4)
  }
}
