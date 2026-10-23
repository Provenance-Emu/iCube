// DolphiniOSTests/BonjourServicesTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// Local-network policy silently drops any Bonjour type the app does not declare in `NSBonjourServices`,
/// so a missing entry shows up only on device as "no phone found".
final class BonjourServicesTests: XCTestCase {
  private var declaredServices: [String] {
    Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String] ?? []
  }

  func test_dsuServiceType_isDeclaredForLocalNetworkPolicy() {
    XCTAssertTrue(declaredServices.contains("_dolphin-dsu._udp"))
  }

  func test_continuityServiceType_isStillDeclared() {
    XCTAssertTrue(declaredServices.contains("_icube-continuity._tcp"))
  }
}
