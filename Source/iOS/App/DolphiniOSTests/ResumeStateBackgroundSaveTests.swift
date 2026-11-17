// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// The app saves the resume state each time it goes to the background. Most backgrounding happens
/// in the library, with no game booted: that must be a refusal, not a wait on the core.
final class ResumeStateBackgroundSaveTests: XCTestCase {
  private var savedPreference: Any?

  override func setUp() {
    super.setUp()
    savedPreference = UserDefaults.standard.object(forKey: SaveStateService.resumeDefaultsKey)
  }

  override func tearDown() {
    UserDefaults.standard.set(savedPreference, forKey: SaveStateService.resumeDefaultsKey)
    super.tearDown()
  }

  func testNothingIsSavedWithoutARunningGame() throws {
    try XCTSkipIf(TVEmulationBridge.isStateOperationAllowed(), "A game is running in the test host")
    UserDefaults.standard.set(true, forKey: SaveStateService.resumeDefaultsKey)
    XCTAssertFalse(TVEmulationBridge.saveResumeStateKeepingGameRunning())
  }

  func testNothingIsSavedWhenResumeIsOff() {
    UserDefaults.standard.set(false, forKey: SaveStateService.resumeDefaultsKey)
    XCTAssertFalse(TVEmulationBridge.saveResumeStateKeepingGameRunning())
  }
}
