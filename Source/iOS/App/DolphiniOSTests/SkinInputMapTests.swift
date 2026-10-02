// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
@testable import iCube

final class SkinInputMapTests: XCTestCase {
  func testGameTypeIdentifiers() {
    XCTAssertEqual(SkinGameType(identifier: "public.aoshuang.game.ngc"), .gameCube)
    XCTAssertEqual(SkinGameType(identifier: "com.rileytestut.delta.game.gc"), .gameCube)
    XCTAssertEqual(SkinGameType(identifier: "gamecube"), .gameCube)
    XCTAssertEqual(SkinGameType(identifier: "public.aoshuang.game.wii"), .wii)
    XCTAssertEqual(SkinGameType(identifier: "com.rileytestut.delta.game.wii"), .wii)
    XCTAssertNil(SkinGameType(identifier: "com.rileytestut.delta.game.n64"))
    XCTAssertEqual(SkinGameType.gameCube.padKinds, [.gameCube])
    XCTAssertEqual(SkinGameType.wii.padKinds, [.wiiRemote, .wiiRemoteSideways, .wiiClassic])
  }

  func testGameCubeButtonsMapToTouchscreenIds() {
    XCTAssertEqual(SkinInputMap.action(for: ["a"], padKind: .gameCube), .control(.button(id: 0)))
    XCTAssertEqual(SkinInputMap.action(for: ["b"], padKind: .gameCube), .control(.button(id: 1)))
    XCTAssertEqual(SkinInputMap.action(for: ["start"], padKind: .gameCube), .control(.button(id: 2)))
    XCTAssertEqual(SkinInputMap.action(for: ["x"], padKind: .gameCube), .control(.button(id: 3)))
    XCTAssertEqual(SkinInputMap.action(for: ["y"], padKind: .gameCube), .control(.button(id: 4)))
    XCTAssertEqual(SkinInputMap.action(for: ["r1"], padKind: .gameCube), .control(.button(id: 5)), "Manic uses r1 for Z")
    XCTAssertEqual(SkinInputMap.action(for: ["z"], padKind: .gameCube), .control(.button(id: 5)))
    XCTAssertEqual(SkinInputMap.action(for: ["l2"], padKind: .gameCube), .control(.axisButton(id: 20)))
    XCTAssertEqual(SkinInputMap.action(for: ["r2"], padKind: .gameCube), .control(.axisButton(id: 21)))
    XCTAssertEqual(SkinInputMap.action(for: ["l"], padKind: .gameCube), .control(.axisButton(id: 20)))
  }

  func testSpecialActions() {
    XCTAssertEqual(SkinInputMap.action(for: ["menu"], padKind: .gameCube), .menu)
    XCTAssertEqual(SkinInputMap.action(for: ["quickSave"], padKind: .wiiRemote), .quickSave)
    XCTAssertEqual(SkinInputMap.action(for: ["quickLoad"], padKind: .wiiClassic), .quickLoad)
  }

  func testSticksAndDpad() {
    XCTAssertEqual(SkinInputMap.stick(prefix: "leftThumbstick", padKind: .gameCube), .stick(baseId: 10))
    XCTAssertEqual(SkinInputMap.stick(prefix: "rightThumbstick", padKind: .gameCube), .stick(baseId: 15), "C-stick")
    XCTAssertEqual(SkinInputMap.stick(prefix: "leftThumbstick", padKind: .wiiRemote), .stick(baseId: 202), "Nunchuk")
    XCTAssertEqual(SkinInputMap.stick(prefix: "rightThumbstick", padKind: .wiiClassic), .stick(baseId: 318))
    XCTAssertNil(SkinInputMap.stick(prefix: "rightThumbstick", padKind: .wiiRemote))
    XCTAssertEqual(SkinInputMap.dpad(padKind: .gameCube), .dpad(baseId: 6))
    XCTAssertEqual(SkinInputMap.dpad(padKind: .wiiClassic), .dpad(baseId: 309))
  }

  func testWiiButtons() {
    XCTAssertEqual(SkinInputMap.action(for: ["a"], padKind: .wiiRemote), .control(.button(id: 100)))
    XCTAssertEqual(SkinInputMap.action(for: ["1"], padKind: .wiiRemote), .control(.button(id: 105)))
    XCTAssertEqual(SkinInputMap.action(for: ["c"], padKind: .wiiRemote), .control(.button(id: 200)))
    XCTAssertEqual(SkinInputMap.action(for: ["zl"], padKind: .wiiClassic), .control(.button(id: 307)))
  }

  func testUnknownInputIsIgnoredAndFirstKnownInputWins() {
    XCTAssertNil(SkinInputMap.action(for: ["toggleFastForward"], padKind: .gameCube))
    XCTAssertEqual(SkinInputMap.action(for: ["nonsense", "a"], padKind: .gameCube), .control(.button(id: 0)))
  }

  func testWiiNamesAreCaseInsensitiveAndAcceptWordsAndDigits() {
    XCTAssertEqual(SkinInputMap.action(for: ["ONE"], padKind: .wiiRemoteSideways), .control(.button(id: 105)))
    XCTAssertEqual(SkinInputMap.action(for: ["two"], padKind: .wiiRemote), .control(.button(id: 106)))
    XCTAssertEqual(SkinInputMap.action(for: ["2"], padKind: .wiiRemote), .control(.button(id: 106)))
    XCTAssertEqual(SkinInputMap.action(for: ["Minus"], padKind: .wiiRemote), .control(.button(id: 102)))
    XCTAssertEqual(SkinInputMap.action(for: ["PLUS"], padKind: .wiiClassic), .control(.button(id: 305)))
    XCTAssertEqual(SkinInputMap.action(for: ["home"], padKind: .wiiClassic), .control(.button(id: 306)))
    XCTAssertEqual(SkinInputMap.action(for: ["Z"], padKind: .wiiRemote), .control(.button(id: 201)))
    XCTAssertEqual(SkinInputMap.action(for: ["ZR"], padKind: .wiiClassic), .control(.button(id: 308)))
    XCTAssertEqual(SkinInputMap.action(for: ["l"], padKind: .wiiClassic), .control(.axisButton(id: 323)))
    XCTAssertEqual(SkinInputMap.action(for: ["R"], padKind: .wiiClassic), .control(.axisButton(id: 324)))
    XCTAssertEqual(SkinInputMap.action(for: ["QUICKSAVE"], padKind: .gameCube), .quickSave)
  }

  func testButtonsAbsentFromAPadAreNotMapped() {
    XCTAssertNil(SkinInputMap.action(for: ["1"], padKind: .wiiClassic), "the Classic has no 1/2")
    XCTAssertNil(SkinInputMap.action(for: ["c"], padKind: .wiiClassic))
    XCTAssertNil(SkinInputMap.action(for: ["start"], padKind: .wiiRemote))
    XCTAssertNil(SkinInputMap.action(for: ["zl"], padKind: .wiiRemote))
  }
}
#endif
