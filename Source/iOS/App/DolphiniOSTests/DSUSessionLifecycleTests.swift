// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import XCTest
@testable import iCube

final class DSUSessionLifecycleTests: XCTestCase {
  private let phases: [ScenePhase] = [.active, .inactive, .background]

  func test_backgroundStopsARunningServer() {
    for sessionOpen in [true, false] {
      XCTAssertEqual(
        DSUSessionLifecycle.action(for: .background, serverRunning: true, sessionOpen: sessionOpen), .stop,
        "background, running, sessionOpen=\(sessionOpen)")
    }
    for sessionOpen in [true, false] {
      XCTAssertEqual(
        DSUSessionLifecycle.action(for: .background, serverRunning: false, sessionOpen: sessionOpen), .none,
        "background, stopped, sessionOpen=\(sessionOpen)")
    }
  }

  func test_activeRestartsWhileTheSessionIsOpen() {
    XCTAssertEqual(DSUSessionLifecycle.action(for: .active, serverRunning: false, sessionOpen: true), .start)
    XCTAssertEqual(DSUSessionLifecycle.action(for: .active, serverRunning: true, sessionOpen: true), .none)
    XCTAssertEqual(DSUSessionLifecycle.action(for: .active, serverRunning: false, sessionOpen: false), .none)
    XCTAssertEqual(DSUSessionLifecycle.action(for: .active, serverRunning: true, sessionOpen: false), .none)
  }

  func test_inactiveDoesNothing() {
    for running in [true, false] {
      for open in [true, false] {
        XCTAssertEqual(
          DSUSessionLifecycle.action(for: .inactive, serverRunning: running, sessionOpen: open), .none,
          "inactive, running=\(running), open=\(open)")
      }
    }
  }

  func test_onlyTheThreeRulesProduceAnAction() {
    var nonNone = 0
    for phase in phases {
      for running in [true, false] {
        for open in [true, false] where DSUSessionLifecycle.action(for: phase, serverRunning: running, sessionOpen: open) != .none {
          nonNone += 1
        }
      }
    }
    // background+running (open or not) = 2, active+stopped+open = 1.
    XCTAssertEqual(nonNone, 3)
  }
}
