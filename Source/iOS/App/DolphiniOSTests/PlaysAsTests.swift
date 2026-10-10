// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// `PlaysAs` (unified menu UX spec §7.1): one value for slot kind + extension + sideways.
final class PlaysAsTests: XCTestCase {
  func test_roundTrip_everyCase() {
    for value in PlaysAs.allCases {
      XCTAssertEqual(PlaysAs(kind: value.kind, wiiExtension: value.wiiExtension, isSideways: value.isSideways), value)
    }
  }

  func test_decompose() {
    XCTAssertEqual(PlaysAs.gameCube.kind, .gameCube)
    XCTAssertEqual(PlaysAs.wiiNunchuk.wiiExtension, 1)
    XCTAssertEqual(PlaysAs.wiiClassic.wiiExtension, 2)
    XCTAssertTrue(PlaysAs.wiiSideways.isSideways)
    XCTAssertEqual(PlaysAs.wiiSideways.wiiExtension, 0)
  }

  func test_unknownCombination_sidewaysWithExtension_readsAsTheExtension() {
    XCTAssertEqual(PlaysAs(kind: .wiiRemote, wiiExtension: 1, isSideways: true), .wiiNunchuk, "the extension wins; sideways is dropped")
    XCTAssertEqual(PlaysAs(kind: .wiiRemote, wiiExtension: 2, isSideways: true), .wiiClassic)
  }

  func test_options_gameCubeTitle_isGameCubeOnly() {
    XCTAssertEqual(PlaysAs.options(for: .gamecube), [.gameCube])
  }

  func test_options_wiiOnly_hasNoGameCubeController() {
    XCTAssertEqual(PlaysAs.options(for: .wii), [.wiiRemote, .wiiNunchuk, .wiiClassic, .wiiSideways])
  }

  func test_options_wiiAndGameCubeAndBoth_offerAllFive_wiiFirst() {
    XCTAssertEqual(PlaysAs.options(for: .wiiAndGameCube), [.wiiRemote, .wiiNunchuk, .wiiClassic, .wiiSideways, .gameCube])
    XCTAssertEqual(PlaysAs.options(for: .both), [.wiiRemote, .wiiNunchuk, .wiiClassic, .wiiSideways, .gameCube])
  }

  func test_current_ofPlayer() {
    let wii = PlayerState(kind: .wiiRemote, port: 2, deviceQualifier: "x", wiiExtension: 2, isSideways: false)
    XCTAssertEqual(PlaysAs.current(of: wii), .wiiClassic)
    let gc = PlayerState(kind: .gameCube, port: 1, deviceQualifier: "x", wiiExtension: 0, isSideways: false)
    XCTAssertEqual(PlaysAs.current(of: gc), .gameCube)
    let hidden = PlayerState(kind: .wiiRemote, port: 1, deviceQualifier: "x", wiiExtension: 1, isSideways: true)
    XCTAssertEqual(PlaysAs.current(of: hidden), .wiiNunchuk, "a stored Nunchuk + Sideways reads as Nunchuk")
  }
}
