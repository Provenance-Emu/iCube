// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
@testable import iCube

final class SkinModelTests: XCTestCase {
  private var fixture: URL {
    Bundle(for: Self.self).url(forResource: "TestCube", withExtension: "deltaskin", subdirectory: "Skins")!
  }

  func testParsesGameTypeAndRepresentations() throws {
    let info = try SkinInfo.load(directory: fixture)
    XCTAssertEqual(info.gameType, .gameCube)
    let portrait = try XCTUnwrap(info.representation(device: .iphone, orientation: .portrait))
    XCTAssertEqual(portrait.mappingSize, CGSize(width: 390, height: 844))
    XCTAssertEqual(portrait.screens.first?.outputFrame, CGRect(x: 0, y: 60, width: 390, height: 292))
    XCTAssertNotNil(info.representation(device: .iphone, orientation: .landscape), "edgeToEdge falls back to standard")
  }

  func testKeepsEveryInputAndPerItemEdges() throws {
    let items = try XCTUnwrap(SkinInfo.load(directory: fixture).representation(device: .iphone, orientation: .portrait)).items
    let multi = try XCTUnwrap(items.first { if case .buttons(let n) = $0.inputs { return n.count == 2 }; return false })
    XCTAssertEqual(multi.inputs, .buttons(["x", "y"]))
    let a = try XCTUnwrap(items.first { $0.inputs == .buttons(["a"]) })
    XCTAssertEqual(a.extendedEdges.left, 20, "item edges override the representation's")
    XCTAssertEqual(a.extendedEdges.top, 5, "unset item edges inherit the representation's")
    XCTAssertEqual(a.asset?.normal, "btn-a.pdf", "Manic per-item asset")
  }

  func testRightThumbstickIsItsOwnStick() throws {
    let items = try XCTUnwrap(SkinInfo.load(directory: fixture).representation(device: .iphone, orientation: .portrait)).items
    let stick = try XCTUnwrap(items.first { $0.thumbstick != nil })
    XCTAssertEqual(stick.inputs, .directional(up: "rightThumbstickUp", down: "rightThumbstickDown",
                                              left: "rightThumbstickLeft", right: "rightThumbstickRight"))
  }

  func testStripsCommentsButNotSlashesInsideStrings() throws {
    let json = """
    // header
    {"name":"https://example.com/skin","identifier":"x","gameTypeIdentifier":"public.aoshuang.game.ngc", // trailing
     "representations":{"iphone":{"standard":{"portrait":{"mappingSize":{"width":1,"height":1}}}}}}
    """
    let info = try SkinInfo.decode(Data(json.utf8))
    XCTAssertEqual(info.name, "https://example.com/skin")
  }

  // MARK: Lenient import: one defect never rejects the whole skin

  private static let ngc = "public.aoshuang.game.ngc"

  private func skinJSON(representations: String) -> Data {
    Data(#"{"name":"N","identifier":"x","gameTypeIdentifier":"\#(Self.ngc)","representations":\#(representations)}"#.utf8)
  }

  private func portrait(of info: SkinInfo) -> SkinRepresentation? {
    info.representation(device: .iphone, orientation: .portrait)
  }

  func testDirectionalItemMissingADirectionIsSkipped() throws {
    let json = skinJSON(representations: """
    {"iphone":{"standard":{"portrait":{"mappingSize":{"width":10,"height":20},"items":[
      {"inputs":{"up":"up","down":"down","left":"left"},"frame":{"x":0,"y":0,"width":1,"height":1}},
      {"inputs":["a"],"frame":{"x":0,"y":0,"width":1,"height":1}}]}}}}
    """)
    let items = try XCTUnwrap(portrait(of: SkinInfo.decode(json))).items
    XCTAssertEqual(items.map(\.inputs), [.buttons(["a"])])
  }

  func testItemWithBadFrameIsSkippedNextToGoodItem() throws {
    let json = skinJSON(representations: """
    {"iphone":{"standard":{"portrait":{"mappingSize":{"width":10,"height":20},"items":[
      {"inputs":["b"],"frame":"nope"},
      {"inputs":["a"],"frame":[1,2,3,4]}]}}}}
    """)
    let items = try XCTUnwrap(portrait(of: SkinInfo.decode(json))).items
    XCTAssertEqual(items.count, 1)
    XCTAssertEqual(items.first?.inputs, .buttons(["a"]))
    XCTAssertEqual(items.first?.frame, CGRect(x: 1, y: 2, width: 3, height: 4))
  }

  func testRepresentationMissingMappingSizeIsDroppedOthersLoad() throws {
    let json = skinJSON(representations: """
    {"iphone":{"standard":{
      "portrait":{"items":[]},
      "landscape":{"mappingSize":{"width":20,"height":10},"items":[]}}}}
    """)
    let info = try SkinInfo.decode(json)
    XCTAssertNil(portrait(of: info))
    XCTAssertEqual(info.representation(device: .iphone, orientation: .landscape)?.mappingSize, CGSize(width: 20, height: 10))
  }

  func testSkinWithOnlyABrokenRepresentationThrowsNoUsableRepresentation() {
    let json = skinJSON(representations: #"{"iphone":{"standard":{"portrait":{"items":[]}}}}"#)
    XCTAssertThrowsError(try SkinInfo.decode(json)) { error in
      XCTAssertEqual(error as? SkinInfoError, .noUsableRepresentation)
    }
  }

  func testRejectsUnsupportedGameType() {
    let json = #"{"name":"N64","identifier":"x","gameTypeIdentifier":"com.rileytestut.delta.game.n64","representations":{}}"#
    XCTAssertThrowsError(try SkinInfo.decode(Data(json.utf8)))
  }
}
#endif
