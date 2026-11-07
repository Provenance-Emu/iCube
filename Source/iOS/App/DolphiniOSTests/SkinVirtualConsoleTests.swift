// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SkinCatalogKit
import XCTest
@testable import iCube

/// NES and Super NES skins for Virtual Console titles (SkinKit#87): their game types, the pads they can
/// replace, and every row of the button tables, which follow Nintendo's VC mapping by name.
final class SkinVirtualConsoleTests: XCTestCase {
  private typealias ID = TouchOverlayDefaults.ButtonID

  private func control(_ name: String, _ padKind: TouchOverlayPadKind, _ gameType: SkinGameType) -> SkinAction? {
    SkinInputMap.action(for: [name], padKind: padKind, gameType: gameType)
  }

  // MARK: Game types

  func testDeltaAndManicSpellings() {
    XCTAssertEqual(SkinGameType(identifier: "com.rileytestut.delta.game.nes"), .nes)
    XCTAssertEqual(SkinGameType(identifier: "public.aoshuang.game.nes"), .nes)
    XCTAssertEqual(SkinGameType(identifier: "com.example.game.fds"), .nes, "the catalog files FDS under NES")
    XCTAssertEqual(SkinGameType(identifier: "com.rileytestut.delta.game.snes"), .snes)
    XCTAssertEqual(SkinGameType(identifier: "public.aoshuang.game.SNES"), .snes)
    XCTAssertEqual(SkinGameType(identifier: "com.example.game.sfc"), .snes)
    XCTAssertNil(SkinGameType(identifier: "com.rileytestut.delta.game.n64"))
    XCTAssertEqual(SkinGameType.nes.manicIdentifier, "public.aoshuang.game.nes")
    XCTAssertEqual(SkinGameType.snes.manicIdentifier, "public.aoshuang.game.snes")
  }

  func testPadsEachTypeCanReplace() {
    XCTAssertEqual(SkinGameType.nes.padKinds, [.gameCube, .wiiClassic, .wiiRemoteSideways])
    XCTAssertEqual(SkinGameType.snes.padKinds, [.gameCube, .wiiClassic], "SNES VC does not use the sideways remote")
    XCTAssertEqual(SkinGameType.gameCube.padKinds, [.gameCube])
  }

  func testSkinInfoDecodesNESAndSNES() {
    func decode(_ identifier: String) -> SkinInfo? {
      try? SkinInfo.decode(Data(#"{"name":"N","identifier":"x","gameTypeIdentifier":"\#(identifier)","representations":{"iphone":{"standard":{"portrait":{"mappingSize":{"width":1,"height":1}}}}}}"#.utf8))
    }
    XCTAssertEqual(decode("com.rileytestut.delta.game.nes")?.gameType, .nes)
    XCTAssertEqual(decode("public.aoshuang.game.nes")?.gameType, .nes)
    XCTAssertEqual(decode("com.rileytestut.delta.game.snes")?.gameType, .snes)
    XCTAssertNil(decode("com.rileytestut.delta.game.gba"))
  }

  // MARK: NES

  func testNESOnTheGameCubePad() {
    XCTAssertEqual(control("a", .gameCube, .nes), .control(.button(id: ID.gcA)))
    XCTAssertEqual(control("b", .gameCube, .nes), .control(.button(id: ID.gcB)))
    XCTAssertEqual(control("start", .gameCube, .nes), .control(.button(id: ID.gcStart)))
    XCTAssertEqual(control("select", .gameCube, .nes), .control(.button(id: ID.gcZ)))
  }

  func testNESOnTheClassicController() {
    XCTAssertEqual(control("a", .wiiClassic, .nes), .control(.button(id: ID.classicA)))
    XCTAssertEqual(control("b", .wiiClassic, .nes), .control(.button(id: ID.classicB)))
    XCTAssertEqual(control("start", .wiiClassic, .nes), .control(.button(id: ID.classicPlus)))
    XCTAssertEqual(control("select", .wiiClassic, .nes), .control(.button(id: ID.classicMinus)))
  }

  func testNESOnTheSidewaysRemote() {
    XCTAssertEqual(control("a", .wiiRemoteSideways, .nes), .control(.button(id: ID.wiiTwo)))
    XCTAssertEqual(control("b", .wiiRemoteSideways, .nes), .control(.button(id: ID.wiiOne)))
    XCTAssertEqual(control("start", .wiiRemoteSideways, .nes), .control(.button(id: ID.wiiPlus)))
    XCTAssertEqual(control("select", .wiiRemoteSideways, .nes), .control(.button(id: ID.wiiMinus)))
  }

  func testNESMapsNothingItDoesNotHave() {
    XCTAssertNil(control("x", .gameCube, .nes), "a NES skin's x is not the GameCube X")
    XCTAssertNil(control("l", .wiiClassic, .nes))
    XCTAssertNil(control("a", .wiiRemote, .nes), "the upright remote is not a NES pad")
  }

  // MARK: SNES

  func testSNESOnTheGameCubePad() {
    XCTAssertEqual(control("a", .gameCube, .snes), .control(.button(id: ID.gcA)))
    XCTAssertEqual(control("b", .gameCube, .snes), .control(.button(id: ID.gcB)))
    XCTAssertEqual(control("x", .gameCube, .snes), .control(.button(id: ID.gcX)))
    XCTAssertEqual(control("y", .gameCube, .snes), .control(.button(id: ID.gcY)))
    XCTAssertEqual(control("l", .gameCube, .snes), .control(.axisButton(id: ID.gcTriggerL)))
    XCTAssertEqual(control("r", .gameCube, .snes), .control(.axisButton(id: ID.gcTriggerR)))
    XCTAssertEqual(control("start", .gameCube, .snes), .control(.button(id: ID.gcStart)))
    XCTAssertEqual(control("select", .gameCube, .snes), .control(.button(id: ID.gcZ)))
  }

  func testSNESOnTheClassicController() {
    XCTAssertEqual(control("a", .wiiClassic, .snes), .control(.button(id: ID.classicA)))
    XCTAssertEqual(control("b", .wiiClassic, .snes), .control(.button(id: ID.classicB)))
    XCTAssertEqual(control("x", .wiiClassic, .snes), .control(.button(id: ID.classicX)))
    XCTAssertEqual(control("y", .wiiClassic, .snes), .control(.button(id: ID.classicY)))
    XCTAssertEqual(control("l", .wiiClassic, .snes), .control(.axisButton(id: ID.classicTriggerL)))
    XCTAssertEqual(control("r", .wiiClassic, .snes), .control(.axisButton(id: ID.classicTriggerR)))
    XCTAssertEqual(control("start", .wiiClassic, .snes), .control(.button(id: ID.classicPlus)))
    XCTAssertEqual(control("select", .wiiClassic, .snes), .control(.button(id: ID.classicMinus)))
  }

  func testSNESDoesNotUseTheSidewaysRemote() {
    XCTAssertNil(control("a", .wiiRemoteSideways, .snes))
  }

  // MARK: Shared rules

  func testAppActionsAndCaseInsensitivityStillApply() {
    XCTAssertEqual(control("menu", .gameCube, .nes), .menu)
    XCTAssertEqual(control("quickSave", .wiiClassic, .snes), .quickSave)
    XCTAssertEqual(control("SELECT", .gameCube, .snes), .control(.button(id: ID.gcZ)))
  }

  func testGameCubeAndWiiSkinsAreUnaffected() {
    XCTAssertEqual(SkinInputMap.action(for: ["x"], padKind: .gameCube, gameType: .gameCube), .control(.button(id: ID.gcX)))
    XCTAssertEqual(SkinInputMap.action(for: ["r1"], padKind: .gameCube, gameType: .gameCube), .control(.button(id: ID.gcZ)))
    XCTAssertEqual(SkinInputMap.action(for: ["a"], padKind: .wiiRemoteSideways, gameType: .wii), .control(.button(id: ID.wiiA)))
    XCTAssertNil(SkinInputMap.action(for: ["select"], padKind: .gameCube), "select means nothing to a GameCube skin")
  }

  func testDpadIsThePadsOwn() {
    XCTAssertEqual(SkinInputMap.dpad(padKind: .gameCube), .dpad(baseId: ID.gcDpadUp))
    XCTAssertEqual(SkinInputMap.dpad(padKind: .wiiClassic), .dpad(baseId: ID.classicDpadUp))
    XCTAssertEqual(SkinInputMap.dpad(padKind: .wiiRemoteSideways), .dpad(baseId: ID.wiiDpadUp))
  }

  // MARK: Store

  func testStoreShelvesListNESAndSNESAfterN64() {
    XCTAssertEqual(SkinStorePolicy.iCube.sections, [.gameCube, .wii, .nintendo64, .nes, .snes])
    let nes = SkinCatalogEntry(id: "n", name: "n", systems: ["nes"], downloadURL: URL(string: "https://e.com/n.deltaskin")!)
    let snes = SkinCatalogEntry(id: "s", name: "s", systems: [], gameTypeIdentifier: "com.rileytestut.delta.game.snes",
                                downloadURL: URL(string: "https://e.com/s.deltaskin")!)
    XCTAssertEqual(SkinStorePolicy.iCube.section(for: nes), .nes)
    XCTAssertEqual(SkinStorePolicy.iCube.section(for: snes), .snes)
  }

  func testShelvesCollapseAfterTheLimit() {
    func shelf(_ count: Int) -> SkinStoreShelf {
      let families = (0 ..< count).map { index in
        let entry = SkinCatalogEntry(id: "\(index)", name: "\(index)", systems: ["nes"],
                                     downloadURL: URL(string: "https://e.com/\(index).deltaskin")!)
        return SkinFamily(id: "entry:\(index)", groupId: nil, name: entry.name, members: [entry], labels: [:])
      }
      return SkinStoreShelf(section: .nes, families: families)
    }
    let limit = SkinStoreShelf.collapsedFamilyLimit
    let big = shelf(limit + 3)
    XCTAssertTrue(big.isCollapsible)
    XCTAssertEqual(big.visibleFamilies(expanded: false).count, limit)
    XCTAssertEqual(big.visibleFamilies(expanded: true).count, limit + 3)
    let small = shelf(limit)
    XCTAssertFalse(small.isCollapsible)
    XCTAssertEqual(small.visibleFamilies(expanded: false).count, limit)
  }
}
#endif
