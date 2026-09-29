// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class PointerModeControllerTests: XCTestCase {
  private var stored = 1
  private var center: NotificationCenter!
  private var controller: PointerModeController!

  override func setUp() {
    super.setUp()
    stored = 1
    center = NotificationCenter()
    controller = PointerModeController(
      read: { [unowned self] in self.stored },
      write: { [unowned self] in self.stored = $0 },
      notificationCenter: center)
  }

  func testRawValuesMatchTheCoreConfig() {
    XCTAssertEqual(PointerMode.gyro.rawValue, 0)
    XCTAssertEqual(PointerMode.touchFollow.rawValue, 1)
    XCTAssertEqual(PointerMode.touchDrag.rawValue, 2)
  }

  func testSetWritesTheConfigAndReadsBack() {
    controller.set(.gyro)
    XCTAssertEqual(stored, 0)
    XCTAssertEqual(controller.mode, .gyro)
  }

  func testSetPostsTheChangeNotification() {
    let posted = expectation(forNotification: .DOLPointerModeDidChange, object: nil, notificationCenter: center)
    controller.set(.touchDrag)
    wait(for: [posted], timeout: 1)
  }

  func testUnknownRawValueFallsBackToTouchFollow() {
    controller.set(rawValue: 7)
    XCTAssertEqual(stored, PointerMode.touchFollow.rawValue)
    stored = 9
    XCTAssertEqual(controller.mode, .touchFollow)
  }
}
