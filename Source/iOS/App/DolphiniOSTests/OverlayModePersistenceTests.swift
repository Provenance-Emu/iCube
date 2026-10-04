// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// The hub's Overlay Style survives a relaunch (`controller_overlay_mode`). Exercised through the
/// static read and write `ControllerManager.overlayMode` uses, against a scratch defaults suite, so
/// the singleton and its controller side effects stay out of it.
final class OverlayModePersistenceTests: XCTestCase {
  private let suite = "OverlayModePersistenceTests"
  private var store: UserDefaults!

  override func setUp() {
    super.setUp()
    UserDefaults().removePersistentDomain(forName: suite)
    store = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: suite)
    super.tearDown()
  }

  func testAFreshInstallReadsAuto() {
    XCTAssertEqual(ControllerManager.storedOverlayMode(in: store), .auto)
  }

  func testEveryStyleSurvivesARelaunch() {
    for mode in [ControllerManager.OverlayMode.gamecube, .wii, .auto] {
      ControllerManager.storeOverlayMode(mode, in: store)
      let relaunched = UserDefaults(suiteName: suite)!
      XCTAssertEqual(ControllerManager.storedOverlayMode(in: relaunched), mode)
    }
  }

  func testAnUnknownStoredValueReadsAuto() {
    store.set(7, forKey: ControllerManager.overlayModeDefaultsKey)
    XCTAssertEqual(ControllerManager.storedOverlayMode(in: store), .auto)
  }
}
