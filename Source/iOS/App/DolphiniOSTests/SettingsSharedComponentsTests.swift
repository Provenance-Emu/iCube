// DolphiniOSTests/SettingsSharedComponentsTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class SettingsSharedComponentsTests: XCTestCase {
  func test_overrideBadgeTitle_namesWhoIsDrivingTheKey() {
    XCTAssertEqual(ConfigOverrideBadge.title(for: .auto), L("Auto"))
    XCTAssertEqual(ConfigOverrideBadge.title(for: .game), L("Game"))
    XCTAssertNil(ConfigOverrideBadge.title(for: .none))
  }
}
