// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class PlaysAsTransitionTests: XCTestCase {
  private let pad = "MFi/0/Xbox Wireless Controller"

  private func wii(_ port: Int, ext: Int = 0, sideways: Bool = false, device: String? = nil) -> PlayerState {
    PlayerState(kind: .wiiRemote, port: port, deviceQualifier: device ?? pad, wiiExtension: ext, isSideways: sideways)
  }

  private func gc(_ port: Int, device: String? = nil) -> PlayerState {
    PlayerState(kind: .gameCube, port: port, deviceQualifier: device ?? pad, wiiExtension: 0, isSideways: false)
  }

  func test_sameValue_isNoOp() {
    XCTAssertEqual(PlaysAsTransition.plan(from: wii(1, ext: 1), to: .wiiNunchuk), [])
    XCTAssertEqual(PlaysAsTransition.plan(from: wii(1, sideways: true), to: .wiiSideways), [])
  }

  func test_wiiToWii_changesExtensionAndSidewaysOnly() {
    XCTAssertEqual(PlaysAsTransition.plan(from: wii(2), to: .wiiClassic), [.setExtension(wiimote: 2, value: 2), .setSideways(wiimote: 2, enabled: false)])
    XCTAssertEqual(PlaysAsTransition.plan(from: wii(2, ext: 2), to: .wiiSideways), [.setExtension(wiimote: 2, value: 0), .setSideways(wiimote: 2, enabled: true)])
  }

  func test_storedNunchukPlusSideways_readsAsNunchuk_andEveryNonSidewaysTargetClearsTheFlag() {
    let hidden = wii(1, ext: 1, sideways: true)
    XCTAssertEqual(PlaysAs.current(of: hidden), .wiiNunchuk)
    XCTAssertEqual(PlaysAsTransition.plan(from: hidden, to: .wiiNunchuk), [.setExtension(wiimote: 1, value: 1), .setSideways(wiimote: 1, enabled: false)],
                   "the target equals what the player reads as, but the hidden flag is still cleared")
    XCTAssertEqual(PlaysAsTransition.plan(from: hidden, to: .wiiClassic), [.setExtension(wiimote: 1, value: 2), .setSideways(wiimote: 1, enabled: false)])
    XCTAssertEqual(PlaysAsTransition.plan(from: hidden, to: .wiiRemote), [.setExtension(wiimote: 1, value: 0), .setSideways(wiimote: 1, enabled: false)])
  }

  func test_wiiToGameCube_movesTheDeviceToTheSamePortNumber() {
    XCTAssertEqual(PlaysAsTransition.plan(from: wii(3, ext: 1), to: .gameCube), [
      .moveDevice(qualifier: pad, from: PlayerSlot(kind: .wiiRemote, port: 3), to: PlayerSlot(kind: .gameCube, port: 3)),
    ])
  }

  func test_gameCubeToWii_movesThenSetsExtensionAndSideways() {
    XCTAssertEqual(PlaysAsTransition.plan(from: gc(1), to: .wiiNunchuk), [
      .moveDevice(qualifier: pad, from: PlayerSlot(kind: .gameCube, port: 1), to: PlayerSlot(kind: .wiiRemote, port: 1)),
      .setExtension(wiimote: 1, value: 1),
      .setSideways(wiimote: 1, enabled: false),
    ])
  }

  func test_unboundPort_changingKind_clearsTheOldSlotOnly() {
    XCTAssertEqual(PlaysAsTransition.plan(from: wii(4, device: ""), to: .gameCube), [
      .clearSlot(PlayerSlot(kind: .wiiRemote, port: 4)),
    ])
  }
}
