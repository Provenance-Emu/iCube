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

  // MARK: Rules SkinKitCore does not apply on its own (`DeltaSkin.DecodingOptions.lenient`)

  func testOnlyGameCubeAndWiiAreAcceptedBySuffix() throws {
    func decode(_ identifier: String) -> SkinInfo? {
      try? SkinInfo.decode(Data(#"{"name":"N","identifier":"x","gameTypeIdentifier":"\#(identifier)","representations":{"iphone":{"standard":{"portrait":{"mappingSize":{"width":1,"height":1}}}}}}"#.utf8))
    }
    XCTAssertEqual(decode("public.aoshuang.game.ngc")?.gameType, .gameCube)
    XCTAssertEqual(decode("com.rileytestut.delta.game.GC")?.gameType, .gameCube)
    XCTAssertEqual(decode("com.rileytestut.delta.game.wii")?.gameType, .wii)
    XCTAssertNil(decode("com.example.game.gcn"), "SkinKitCore reads gcn as GameCube; iCube never did")
    XCTAssertNil(decode("com.example.game.nintendogamecube"))
    XCTAssertNil(decode("com.rileytestut.delta.game.n64"))
  }

  func testPartialRepresentationEdgesFillWithZeroAndItemsInheritThem() throws {
    let json = skinJSON(representations: """
    {"iphone":{"standard":{"portrait":{"mappingSize":{"width":10,"height":20},"extendedEdges":{"left":7},"items":[
      {"inputs":["a"],"frame":[0,0,1,1]},
      {"inputs":["b"],"frame":[0,0,1,1],"extendedEdges":{"top":3,"left":null}}]}}}}
    """)
    let rep = try XCTUnwrap(portrait(of: SkinInfo.decode(json)))
    XCTAssertEqual(rep.extendedEdges, UIEdgeInsets(top: 0, left: 7, bottom: 0, right: 0))
    XCTAssertEqual(rep.items[0].extendedEdges, UIEdgeInsets(top: 0, left: 7, bottom: 0, right: 0))
    XCTAssertEqual(rep.items[1].extendedEdges, UIEdgeInsets(top: 3, left: 7, bottom: 0, right: 0), "a null side is absent, so it inherits")
  }

  func testWrongTypesDropTheRepresentationNotTheSkin() throws {
    let json = skinJSON(representations: """
    {"iphone":{"standard":{
      "portrait":{"mappingSize":{"width":10,"height":20},"translucent":"yes"},
      "landscape":{"mappingSize":{"width":20,"height":10},"items":"nope"}}},
     "ipad":{"standard":{"portrait":{"mappingSize":{"width":10,"height":20},"assets":{"resizable":3}},
                          "landscape":{"mappingSize":{"width":20,"height":10}}}}}
    """)
    let info = try SkinInfo.decode(json)
    XCTAssertNil(info.representation(device: .iphone, orientation: .portrait))
    XCTAssertNil(info.representation(device: .iphone, orientation: .landscape))
    XCTAssertNil(info.representation(device: .ipad, orientation: .portrait))
    XCTAssertNotNil(info.representation(device: .ipad, orientation: .landscape))
  }

  func testBucketsTheOverlayDoesNotUseAreIgnored() throws {
    let json = skinJSON(representations: """
    {"tv":{"standard":{"portrait":{"mappingSize":{"width":10,"height":20}}}},
     "iphone":{"splitView":{"portrait":{"mappingSize":{"width":10,"height":20}}},
               "standard":{"portrait":{"mappingSize":{"width":10,"height":20}},"upsideDown":{"mappingSize":{"width":10,"height":20}}}}}
    """)
    let info = try SkinInfo.decode(json)
    XCTAssertEqual(info.representations.keys.map(\.rawValue), ["iphone"])
    XCTAssertEqual(info.representations[.iphone]?.keys.map(\.rawValue), ["standard"])
    XCTAssertEqual(info.representations[.iphone]?[.standard]?.keys.map(\.rawValue), ["portrait"])
  }

  func testThingsTheOverlayNeverReadsCannotRejectASkin() throws {
    let json = skinJSON(representations: """
    {"iphone":{"standard":{"portrait":{"mappingSize":{"width":10,"height":20},
      "screens":[{"outputFrame":[0,0,10,10],"filters":"garbage","placement":42}],
      "items":[{"inputs":["a"],"frame":[0,0,1,1],"haptic":"???","states":[1,2]}],
      "backgroundAnimation":"oops","gameScreenFrame":"nope"}}}}
    """)
    let rep = try XCTUnwrap(portrait(of: SkinInfo.decode(json)))
    XCTAssertEqual(rep.screens.map(\.outputFrame), [CGRect(x: 0, y: 0, width: 10, height: 10)])
    XCTAssertEqual(rep.items.count, 1)
  }

  func testScreenInputFrameIsKeptAndABadOneDropsTheScreen() throws {
    let json = skinJSON(representations: """
    {"iphone":{"standard":{"portrait":{"mappingSize":{"width":10,"height":20},"screens":[
      {"outputFrame":[0,0,10,10],"inputFrame":{"x":0,"y":0,"width":320,"height":240}},
      {"outputFrame":[0,0,5,5],"inputFrame":"bad"},
      {"inputFrame":[0,0,1,1]}]}}}}
    """)
    let screens = try XCTUnwrap(portrait(of: SkinInfo.decode(json))).screens
    XCTAssertEqual(screens, [SkinScreen(outputFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
                                        inputFrame: CGRect(x: 0, y: 0, width: 320, height: 240))])
  }

  func testBackgroundAssetKeysComeThrough() throws {
    let json = skinJSON(representations: """
    {"iphone":{"standard":{"portrait":{"mappingSize":{"width":10,"height":20},
      "assets":{"resizable":"bg.pdf","large":"l.png","medium":"m.png","small":"s.png"}}}}}
    """)
    let background = try XCTUnwrap(portrait(of: SkinInfo.decode(json))?.background)
    XCTAssertEqual(background, SkinAsset(resizable: "bg.pdf", small: "s.png", medium: "m.png", large: "l.png"))
  }

  func testThumbstickSizesAreLimitedAndABadOneDropsOnlyItsItem() throws {
    func items(width: String) throws -> [SkinItem] {
      let json = skinJSON(representations: """
      {"iphone":{"standard":{"portrait":{"mappingSize":{"width":10,"height":20},"items":[
        {"inputs":{"up":"rightThumbstickUp","down":"rightThumbstickDown","left":"rightThumbstickLeft","right":"rightThumbstickRight"},
         "frame":[0,0,10,10],"thumbstick":{"name":"stick.pdf","width":\(width),"height":8}},
        {"inputs":["a"],"frame":[1,2,3,4]}]}}}}
      """)
      return try XCTUnwrap(portrait(of: SkinInfo.decode(json))).items
    }
    // -1e999 parses to -infinity; re-serialising that would raise an uncatchable Objective-C exception.
    for bad in ["-1e999", "-5", "1e308", "100001"] {
      XCTAssertEqual(try items(width: bad).map(\.inputs), [.buttons(["a"])], "width \(bad) drops the thumbstick item")
    }
    let kept = try items(width: "6")
    XCTAssertEqual(kept.count, 2)
    XCTAssertEqual(kept.first?.thumbstick, SkinThumbstick(name: "stick.pdf", width: 6, height: 8))
  }

  // MARK: Frame sanity

  func testItemFramesOutOfRangeAreDroppedNextToGoodItem() throws {
    let json = skinJSON(representations: """
    {"iphone":{"standard":{"portrait":{"mappingSize":{"width":10,"height":20},"items":[
      {"inputs":["huge"],"frame":{"x":0,"y":0,"width":1e308,"height":1}},
      {"inputs":["negative"],"frame":{"x":0,"y":0,"width":-5,"height":1}},
      {"inputs":["hugeArray"],"frame":[0,0,1,1e308]},
      {"inputs":["negativeArray"],"frame":[0,0,1,-1]},
      {"inputs":["farOrigin"],"frame":{"x":-1e308,"y":0,"width":1,"height":1}},
      {"inputs":["a"],"frame":[1,2,3,4]}]}}}}
    """)
    let items = try XCTUnwrap(portrait(of: SkinInfo.decode(json))).items
    XCTAssertEqual(items.map(\.inputs), [.buttons(["a"])])
  }

  func testScreenFrameOutOfRangeIsDropped() throws {
    let json = skinJSON(representations: """
    {"iphone":{"standard":{"portrait":{"mappingSize":{"width":10,"height":20},"items":[],"screens":[
      {"outputFrame":{"x":0,"y":0,"width":1e308,"height":1}},
      {"outputFrame":[0,0,10,10]}]}}}}
    """)
    let screens = try XCTUnwrap(portrait(of: SkinInfo.decode(json))).screens
    XCTAssertEqual(screens.map(\.outputFrame), [CGRect(x: 0, y: 0, width: 10, height: 10)])
  }

  func testItemWithAbsurdEdgesIsDropped() throws {
    let json = skinJSON(representations: """
    {"iphone":{"standard":{"portrait":{"mappingSize":{"width":10,"height":20},"items":[
      {"inputs":["bad"],"frame":[0,0,1,1],"extendedEdges":{"left":1e308}},
      {"inputs":["a"],"frame":[1,2,3,4],"extendedEdges":{"left":5}}]}}}}
    """)
    let items = try XCTUnwrap(portrait(of: SkinInfo.decode(json))).items
    XCTAssertEqual(items.map(\.inputs), [.buttons(["a"])])
  }

  func testRepresentationWithBadMappingSizeIsDroppedOthersLoad() throws {
    let json = skinJSON(representations: """
    {"iphone":{"standard":{
      "portrait":{"mappingSize":{"width":0,"height":20},"items":[]},
      "landscape":{"mappingSize":{"width":1e308,"height":10},"items":[]}}},
     "ipad":{"standard":{
      "portrait":{"mappingSize":{"width":-10,"height":20},"items":[]},
      "landscape":{"mappingSize":{"width":20,"height":10},"items":[]}}}}
    """)
    let info = try SkinInfo.decode(json)
    XCTAssertNil(info.representation(device: .iphone, orientation: .portrait))
    XCTAssertNil(info.representation(device: .iphone, orientation: .landscape))
    XCTAssertNil(info.representation(device: .ipad, orientation: .portrait))
    XCTAssertNotNil(info.representation(device: .ipad, orientation: .landscape))
  }

  func testFrameLimitsRejectNonFiniteAndAbsurdValues() {
    XCTAssertTrue(SkinFrameLimits.isSane(CGRect(x: -10, y: 0, width: 390, height: 844)))
    XCTAssertFalse(SkinFrameLimits.isSane(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)))
    XCTAssertFalse(SkinFrameLimits.isSane(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1)))
    XCTAssertFalse(SkinFrameLimits.isSane(CGRect(x: 0, y: 0, width: 1, height: -CGFloat.infinity)))
    XCTAssertFalse(SkinFrameLimits.isSane(CGRect(x: 0, y: 1e308, width: 1, height: 1)))
    XCTAssertFalse(SkinFrameLimits.isSane(CGSize(width: CGFloat.nan, height: 1)))
    XCTAssertFalse(SkinFrameLimits.isSane(CGSize(width: 1, height: -1)))
    XCTAssertFalse(SkinFrameLimits.isSane(CGFloat.nan))
    XCTAssertFalse(SkinFrameLimits.isSane(SkinFrameLimits.maxMagnitude * 2))
  }
}
#endif
