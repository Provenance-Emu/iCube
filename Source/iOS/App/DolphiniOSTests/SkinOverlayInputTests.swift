// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
@testable import iCube

final class SkinOverlayInputTests: XCTestCase {
  private typealias ID = TouchOverlayDefaults.ButtonID

  private static let mappingSize = CGSize(width: 400, height: 800)

  private func item(_ inputs: SkinItemInputs, _ frame: CGRect, edges: UIEdgeInsets = .zero, thumbstick: SkinThumbstick? = nil) -> SkinItem {
    SkinItem(inputs: inputs, frame: frame, extendedEdges: edges, asset: nil, thumbstick: thumbstick)
  }

  /// A 1:1 layout (canvas == mapping size), so the item frames are also the screen frames.
  private func input(_ items: [SkinItem], padKind: TouchOverlayPadKind = .gameCube) -> SkinOverlayInput {
    let rep = SkinRepresentation(mappingSize: Self.mappingSize, items: items, screens: [], background: nil,
                                 translucent: false, extendedEdges: .zero)
    return SkinOverlayInput(layout: SkinLayout.make(rep, canvas: Self.mappingSize), padKind: padKind)
  }

  private func buttonWrites(_ pairs: [(Int, Bool)]) -> [SkinOverlayInput.Write] {
    pairs.map { SkinOverlayInput.Write(channel: .button, id: $0.0, pressed: $0.1) }
  }

  // MARK: Hit testing

  func testTouchInExtendedEdgesButOutsideDrawFramePresses() {
    let sut = input([item(.buttons(["a"]), CGRect(x: 100, y: 100, width: 40, height: 40),
                          edges: UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 0))])
    XCTAssertEqual(sut.hits(at: CGPoint(x: 90, y: 120), previous: []), [.item(0)], "inside hitFrame, outside drawFrame")
    XCTAssertEqual(sut.hits(at: CGPoint(x: 70, y: 120), previous: []), [], "outside the extended hitFrame")
  }

  func testOverlappingHitFramesPreferTheItemDrawnUnderTheFinger() {
    let edges = UIEdgeInsets(top: 0, left: 30, bottom: 0, right: 30)
    let sut = input([item(.buttons(["a"]), CGRect(x: 100, y: 100, width: 40, height: 40), edges: edges),
                     item(.buttons(["b"]), CGRect(x: 150, y: 100, width: 40, height: 40), edges: edges)])
    XCTAssertEqual(sut.hits(at: CGPoint(x: 160, y: 120), previous: []), [.item(1)], "inside B's art although A's hit frame reaches it")
    XCTAssertEqual(sut.hits(at: CGPoint(x: 130, y: 120), previous: []), [.item(0)])
    XCTAssertEqual(sut.hits(at: CGPoint(x: 144, y: 120), previous: []), [.item(0)], "in the gap: the nearer centre wins")
  }

  func testItemsTheCurrentPadDoesNotKnowAreIgnored() {
    let sut = input([item(.buttons(["zl"]), CGRect(x: 100, y: 100, width: 40, height: 40))])
    XCTAssertEqual(sut.hits(at: CGPoint(x: 120, y: 120), previous: []), [], "zl does not exist on the GameCube pad")
  }

  func testDpadResolvesDirectionsWithDpadDirections() {
    let dpad = item(.directional(up: "up", down: "down", left: "left", right: "right"), CGRect(x: 0, y: 200, width: 100, height: 100))
    let sut = input([dpad])
    XCTAssertEqual(sut.hits(at: CGPoint(x: 50, y: 210), previous: []), [.direction(item: 0, .up)])
    XCTAssertEqual(sut.hits(at: CGPoint(x: 85, y: 215), previous: []), [.direction(item: 0, .up), .direction(item: 0, .right)])
    XCTAssertEqual(sut.hits(at: CGPoint(x: 50, y: 250), previous: []), [], "dead zone")
  }

  func testSticksAreNotHitByTheButtonSurface() {
    let stick = item(.directional(up: "rightThumbstickUp", down: "rightThumbstickDown", left: "rightThumbstickLeft", right: "rightThumbstickRight"),
                     CGRect(x: 200, y: 600, width: 140, height: 140))
    let sut = input([stick])
    XCTAssertEqual(sut.hits(at: CGPoint(x: 270, y: 670), previous: []), [])
    XCTAssertEqual(sut.sticks.count, 1)
  }

  // MARK: Writes

  func testItemWithTwoInputsPressesBoth() {
    let sut = input([item(.buttons(["x", "y"]), CGRect(x: 100, y: 100, width: 40, height: 40))])
    XCTAssertEqual(sut.writes(now: [.item(0)], previous: []), buttonWrites([(ID.gcX, true), (ID.gcY, true)]))
  }

  func testAnalogTriggerWritesOnTheAxisChannel() {
    let sut = input([item(.buttons(["l"]), CGRect(x: 10, y: 10, width: 80, height: 40))])
    XCTAssertEqual(sut.writes(now: [.item(0)], previous: []), [SkinOverlayInput.Write(channel: .axis, id: ID.gcTriggerL, pressed: true)])
  }

  func testDpadWritesTheDirectionButtons() {
    let dpad = item(.directional(up: "up", down: "down", left: "left", right: "right"), CGRect(x: 0, y: 200, width: 100, height: 100))
    let sut = input([dpad])
    let now: Set<SkinOverlayInput.Hit> = [.direction(item: 0, .up), .direction(item: 0, .right)]
    XCTAssertEqual(sut.writes(now: now, previous: []), buttonWrites([(ID.gcDpadUp, true), (ID.gcDpadUp + 3, true)]))
    XCTAssertEqual(sut.writes(now: [.direction(item: 0, .right)], previous: now), buttonWrites([(ID.gcDpadUp, false)]),
                   "sliding off up only releases up")
  }

  func testReleasingEveryTouchReleasesEveryId() {
    let sut = input([item(.buttons(["a"]), CGRect(x: 100, y: 100, width: 40, height: 40)),
                     item(.buttons(["x", "y"]), CGRect(x: 200, y: 100, width: 40, height: 40)),
                     item(.directional(up: "up", down: "down", left: "left", right: "right"), CGRect(x: 0, y: 200, width: 100, height: 100))])
    let held: Set<SkinOverlayInput.Hit> = [.item(0), .item(1), .direction(item: 2, .up), .direction(item: 2, .left)]
    let writes = sut.writes(now: [], previous: held)
    XCTAssertEqual(Set(writes.map(\.id)), [ID.gcA, ID.gcX, ID.gcY, ID.gcDpadUp, ID.gcDpadUp + 2])
    XCTAssertTrue(writes.allSatisfy { !$0.pressed })
    XCTAssertEqual(sut.writes(now: held, previous: held), [], "nothing changed, nothing written")
  }

  func testTwoItemsOnOneIdKeepItDownUntilBothAreReleased() {
    let sut = input([item(.buttons(["a"]), CGRect(x: 100, y: 100, width: 40, height: 40)),
                     item(.buttons(["a"]), CGRect(x: 200, y: 100, width: 40, height: 40))])
    XCTAssertEqual(sut.writes(now: [.item(0), .item(1)], previous: [.item(0)]), [], "id already down")
    XCTAssertEqual(sut.writes(now: [.item(1)], previous: [.item(0), .item(1)]), [], "still held by the other item")
    XCTAssertEqual(sut.writes(now: [], previous: [.item(1)]), buttonWrites([(ID.gcA, false)]))
  }

  func testReleaseUsesTheIdsThatWereWrittenEvenAfterTheLayoutChanged() {
    let portrait = input([item(.buttons(["a"]), CGRect(x: 100, y: 100, width: 40, height: 40)),
                          item(.buttons(["x", "y"]), CGRect(x: 200, y: 100, width: 40, height: 40))])
    let held = portrait.keys(of: [.item(0), .item(1)])
    let landscape = input([])
    XCTAssertEqual(landscape.keys(of: [.item(0), .item(1)]), [], "hits from the old layout point at nothing and are ignored")
    let writes = SkinOverlayInput.writes(from: held, to: landscape.keys(of: []))
    XCTAssertEqual(Set(writes.map(\.id)), [ID.gcA, ID.gcX, ID.gcY])
    XCTAssertTrue(writes.allSatisfy { !$0.pressed })
  }

  // MARK: Actions

  func testMenuFiresOnceOnTouchDownOnly() {
    let sut = input([item(.buttons(["menu"]), CGRect(x: 100, y: 100, width: 40, height: 40)),
                     item(.buttons(["quickSave"]), CGRect(x: 200, y: 100, width: 40, height: 40))])
    XCTAssertEqual(sut.actions(now: [.item(0)], previous: []), [.menu])
    XCTAssertEqual(sut.actions(now: [.item(0)], previous: [.item(0)]), [], "still held")
    XCTAssertEqual(sut.actions(now: [], previous: [.item(0)]), [], "release fires nothing")
    XCTAssertEqual(sut.actions(now: [.item(0), .item(1)], previous: [.item(0)]), [.quickSave])
    XCTAssertEqual(sut.writes(now: [.item(0)], previous: []), [], "actions never write to the pad")
  }

  // MARK: Sticks

  func testRightThumbstickWritesTheCStickHalfAxes() throws {
    let thumb = SkinThumbstick(name: "stick.pdf", width: 60, height: 60)
    let sut = input([item(.directional(up: "rightThumbstickUp", down: "rightThumbstickDown", left: "rightThumbstickLeft", right: "rightThumbstickRight"),
                          CGRect(x: 200, y: 600, width: 140, height: 140),
                          edges: UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10), thumbstick: thumb)])
    let stick = try XCTUnwrap(sut.sticks.first)
    XCTAssertEqual(stick.baseId, ID.gcCStick)
    XCTAssertEqual(stick.hitFrame, CGRect(x: 190, y: 590, width: 160, height: 160))
    XCTAssertEqual(stick.center, CGPoint(x: 80, y: 80), "centre of the art, in hit-frame coordinates")
    XCTAssertEqual(stick.travel, 40, accuracy: 0.001, "(140 - 60) / 2: the knob stays inside the art")

    let fullRight = CGPoint(x: stick.center.x + 400, y: stick.center.y)
    let expected = TouchOverlayInput.stickWrites(x: 1, y: 0, baseId: ID.gcCStick)
    let writes = stick.writes(touch: fullRight)
    XCTAssertEqual(writes.map(\.id), expected.map(\.id))
    XCTAssertEqual(writes.map(\.value), expected.map(\.value))
    XCTAssertEqual(stick.knobOffset(touch: fullRight), CGSize(width: 40, height: 0))

    let released = stick.writes(touch: nil)
    XCTAssertEqual(released.map(\.value), [0, 0, 0, 0])
    XCTAssertEqual(released.map(\.id), expected.map(\.id))
    XCTAssertEqual(stick.knobOffset(touch: nil), .zero)
  }

  func testStickWithoutThumbstickImageTravelsAThirdOfItsWidth() throws {
    let sut = input([item(.directional(up: "leftThumbstickUp", down: "leftThumbstickDown", left: "leftThumbstickLeft", right: "leftThumbstickRight"),
                          CGRect(x: 20, y: 600, width: 120, height: 120))])
    let stick = try XCTUnwrap(sut.sticks.first)
    XCTAssertEqual(stick.baseId, ID.gcMainStick)
    XCTAssertEqual(stick.travel, 40, accuracy: 0.001)
  }

  func testStickTheCurrentPadLacksIsIgnored() {
    let right = item(.directional(up: "rightThumbstickUp", down: "rightThumbstickDown", left: "rightThumbstickLeft", right: "rightThumbstickRight"),
                     CGRect(x: 200, y: 600, width: 140, height: 140))
    XCTAssertTrue(input([right], padKind: .wiiRemote).sticks.isEmpty, "the Nunchuk only has one stick")
  }

  func testStickDrawScalesWithTheCanvas() throws {
    let rep = SkinRepresentation(mappingSize: Self.mappingSize,
                                 items: [item(.directional(up: "leftThumbstickUp", down: "leftThumbstickDown", left: "leftThumbstickLeft", right: "leftThumbstickRight"),
                                              CGRect(x: 0, y: 0, width: 100, height: 100), thumbstick: SkinThumbstick(name: "s", width: 40, height: 40))],
                                 screens: [], background: nil, translucent: false, extendedEdges: .zero)
    let sut = SkinOverlayInput(layout: SkinLayout.make(rep, canvas: CGSize(width: 800, height: 1600)), padKind: .gameCube)
    let stick = try XCTUnwrap(sut.sticks.first)
    XCTAssertEqual(stick.thumbSize, CGSize(width: 80, height: 80))
    XCTAssertEqual(stick.travel, 60, accuracy: 0.001, "(200 - 80) / 2")
  }

  // MARK: Representation choice

  private static let iphoneOnlyInfo = """
  {"name":"P","identifier":"p","gameTypeIdentifier":"public.aoshuang.game.ngc","representations":{
    "iphone":{"edgeToEdge":{"portrait":{"mappingSize":{"width":100,"height":200},"items":[]}}}}}
  """

  private static let bothDevicesInfo = """
  {"name":"B","identifier":"b","gameTypeIdentifier":"public.aoshuang.game.ngc","representations":{
    "iphone":{"edgeToEdge":{"portrait":{"mappingSize":{"width":100,"height":200},"items":[]}}},
    "ipad":{"edgeToEdge":{"portrait":{"mappingSize":{"width":300,"height":400},"items":[]}}}}}
  """

  func testIPadFallsBackToIPhoneAndIPhoneNeverUsesIPad() throws {
    let phoneOnly = try SkinInfo.decode(Data(Self.iphoneOnlyInfo.utf8))
    let both = try SkinInfo.decode(Data(Self.bothDevicesInfo.utf8))
    XCTAssertEqual(SkinOverlayInput.representation(info: phoneOnly, isPad: true, orientation: .portrait)?.mappingSize, CGSize(width: 100, height: 200))
    XCTAssertEqual(SkinOverlayInput.representation(info: both, isPad: true, orientation: .portrait)?.mappingSize, CGSize(width: 300, height: 400))
    XCTAssertEqual(SkinOverlayInput.representation(info: both, isPad: false, orientation: .portrait)?.mappingSize, CGSize(width: 100, height: 200))
    XCTAssertNil(SkinOverlayInput.representation(info: both, isPad: false, orientation: .landscape))
  }
}
#endif
