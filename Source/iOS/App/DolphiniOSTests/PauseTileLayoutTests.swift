// DolphiniOSTests/PauseTileLayoutTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// Spec §5.1: 6 columns on tvOS, 3 on an iPhone in portrait, 4 in landscape, 4–6 on iPad by width.
final class PauseTileLayoutTests: XCTestCase {
  func test_tv_isAlwaysSix() {
    XCTAssertEqual(PauseTileLayout.columns(forWidth: 1920, isTV: true), 6)
    XCTAssertEqual(PauseTileLayout.columns(forWidth: 100, isTV: true), 6)
  }

  func test_phonePortrait_three_landscape_four() {
    XCTAssertEqual(PauseTileLayout.columns(forWidth: 393, isTV: false), 3)
    XCTAssertEqual(PauseTileLayout.columns(forWidth: 852, isTV: false), 4)
  }

  func test_ipad_fourToSixByWidth() {
    XCTAssertEqual(PauseTileLayout.columns(forWidth: 744, isTV: false), 4)
    XCTAssertEqual(PauseTileLayout.columns(forWidth: 1024, isTV: false), 5)
    XCTAssertEqual(PauseTileLayout.columns(forWidth: 1366, isTV: false), 6)
  }

  func test_compactHeight_wideWindowGetsSixColumns() {
    XCTAssertEqual(PauseTileLayout.columns(forWidth: 852, isTV: false, isCompactHeight: true), 6)
    XCTAssertEqual(PauseTileLayout.columns(forWidth: 852, isTV: false, isCompactHeight: false), 4)
  }
}
