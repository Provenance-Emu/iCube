// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// `PointerModeController` is `@MainActor`, so each test is too, and the controller is built per test
/// (not in the nonisolated `setUp`), following `LocalGameDeleterTests`.
final class PointerModeControllerTests: XCTestCase {
  /// Stands in for the core config: a Base value and an optional CurrentRun override on top.
  private final class Layers {
    var base = 1
    var currentRun: Int?
  }

  @MainActor
  private func makeController(_ layers: Layers, center: NotificationCenter = NotificationCenter()) -> PointerModeController {
    PointerModeController(
      read: { layers.currentRun ?? layers.base },
      write: { layers.base = $0 },
      writeCurrentRun: { layers.currentRun = $0 },
      notificationCenter: center)
  }

  @MainActor
  func testRawValuesMatchTheCoreConfig() {
    XCTAssertEqual(PointerMode.gyro.rawValue, 0)
    XCTAssertEqual(PointerMode.touchFollow.rawValue, 1)
    XCTAssertEqual(PointerMode.touchDrag.rawValue, 2)
  }

  @MainActor
  func testSetWritesTheConfigAndReadsBack() {
    let layers = Layers()
    let controller = makeController(layers)
    controller.set(.gyro)
    XCTAssertEqual(layers.base, 0)
    XCTAssertEqual(controller.mode, .gyro)
  }

  @MainActor
  func testSetPostsTheChangeNotification() {
    let center = NotificationCenter()
    let controller = makeController(Layers(), center: center)
    let posted = expectation(forNotification: .DOLPointerModeDidChange, object: nil, notificationCenter: center)
    controller.set(.touchDrag)
    wait(for: [posted], timeout: 1)
  }

  @MainActor
  func testUnknownRawValueFallsBackToTouchFollow() {
    let layers = Layers()
    let controller = makeController(layers)
    controller.set(rawValue: 7)
    XCTAssertEqual(layers.base, PointerMode.touchFollow.rawValue)
    layers.base = 9
    XCTAssertEqual(controller.mode, .touchFollow)
  }

  @MainActor
  func testSetCurrentRunWritesOnlyTheCurrentRunLayer() {
    let layers = Layers()
    let controller = makeController(layers)
    controller.setCurrentRun(.gyro)
    XCTAssertEqual(layers.currentRun, 0)
    XCTAssertEqual(layers.base, 1, "a per-game override must not become the global setting")
    XCTAssertEqual(controller.mode, .gyro, "mode reads the active layer, so it reports the override")
  }

  @MainActor
  func testSetCurrentRunPostsTheChangeNotification() {
    let center = NotificationCenter()
    let controller = makeController(Layers(), center: center)
    let posted = expectation(forNotification: .DOLPointerModeDidChange, object: nil, notificationCenter: center)
    controller.setCurrentRun(rawValue: 2)
    wait(for: [posted], timeout: 1)
  }
}
