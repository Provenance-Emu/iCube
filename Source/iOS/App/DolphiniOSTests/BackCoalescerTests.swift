// DolphiniOSTests/BackCoalescerTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// Spec §4.1: the release of the press that opened a menu arrives as an exit/back command on tvOS and
/// must not close it. Everything after the window is honoured.
final class BackCoalescerTests: XCTestCase {
  func test_backInsideWindow_isDropped() {
    let opened = Date(timeIntervalSinceReferenceDate: 100)
    XCTAssertFalse(BackCoalescer.shouldHonor(openedAt: opened, now: opened.addingTimeInterval(0.1)))
  }

  func test_backAfterWindow_isHonoured() {
    let opened = Date(timeIntervalSinceReferenceDate: 100)
    XCTAssertTrue(BackCoalescer.shouldHonor(openedAt: opened, now: opened.addingTimeInterval(BackCoalescer.window)))
  }
}
