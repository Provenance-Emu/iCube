// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class QuickMuteTests: XCTestCase {
  func testMutingRemembersTheCurrentVolumeAndZeroesIt() {
    let next = QuickMute.transition(currentVolume: 70, rememberedVolume: nil)
    XCTAssertEqual(next, QuickMute.Transition(volume: 0, rememberedVolume: 70))
    XCTAssertTrue(next.isMuted)
  }

  func testMutingOverwritesAStaleRememberedVolume() {
    let next = QuickMute.transition(currentVolume: 40, rememberedVolume: 90)
    XCTAssertEqual(next.rememberedVolume, 40)
  }

  func testUnmutingRestoresTheRememberedVolume() {
    let next = QuickMute.transition(currentVolume: 0, rememberedVolume: 70)
    XCTAssertEqual(next.volume, 70)
    XCTAssertNil(next.rememberedVolume)
    XCTAssertFalse(next.isMuted)
  }

  func testUnmutingWithNothingRememberedFallsBackToFullVolume() {
    XCTAssertEqual(QuickMute.transition(currentVolume: 0, rememberedVolume: nil).volume, QuickMute.fallbackRestoreVolume)
  }

  func testUnmutingNeverRestoresAZeroVolume() {
    XCTAssertEqual(QuickMute.transition(currentVolume: 0, rememberedVolume: 0).volume, QuickMute.fallbackRestoreVolume)
  }
}
