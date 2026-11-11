#if os(iOS)
import SkinKit2Core
import SkinKit2Render
import XCTest
@testable import iCube

@MainActor
final class DefaultSkin2InputTests: XCTestCase {
  func testOverlaidIRSurfacePassesTouchesThroughToControlsInEveryMode() {
    let surface = TouchOverlayIRPadView.IRSurfaceView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    surface.passesThroughExcludedFrames = true
    surface.excludedFrames = [CGRect(x: 20, y: 30, width: 40, height: 50)]
    for mode in [TCWiiTouchIRMode.gyro, .drag, .follow] {
      surface.mode = mode
      XCTAssertFalse(surface.point(inside: CGPoint(x: 40, y: 50), with: nil))
      XCTAssertTrue(surface.point(inside: CGPoint(x: 120, y: 120), with: nil))
    }
  }

  func testButtonsAndDpadRetainEachPadsInputTable() {
    let expectedA: [TouchOverlayPadKind: Int] = [.gameCube: 0, .wiiRemote: 100, .wiiRemoteSideways: 100, .wiiClassic: 300]
    let expectedUp: [TouchOverlayPadKind: Int] = [.gameCube: 6, .wiiRemote: 107, .wiiRemoteSideways: 107, .wiiClassic: 309]
    for kind in TouchOverlayPadKind.allCases {
      var writes: [(Int, Bool)] = []
      let input = DefaultSkin2Input(padKind: kind, deviceId: 999, writeButton: { writes.append(($0, $1)) },
                                    writeAxis: { _, _ in XCTFail("Unexpected axis write") })
      input.press("a")
      input.release("a")
      XCTAssertEqual(writes.map(\.0), [expectedA[kind]!, expectedA[kind]!])
      XCTAssertEqual(writes.map(\.1), [true, false])
      writes.removeAll()
      input.press("up")
      input.release("up")
      XCTAssertEqual(writes.map(\.0), [expectedUp[kind]!, expectedUp[kind]!])
      XCTAssertEqual(writes.map(\.1), [true, false])
    }
  }

  func testPressureOnlyChangesAndReleaseRetainAnalogTriggerValues() throws {
    for kind in [TouchOverlayPadKind.gameCube, .wiiClassic] {
      var writes: [(Int, Float)] = []
      var haptics: [TouchHapticEvent] = []
      let input = DefaultSkin2Input(padKind: kind, deviceId: 999, writeButton: { _, _ in XCTFail("Digital trigger") },
                                    writeAxis: { writes.append(($0, $1)) }, playHaptic: { haptics.append($0) })
      let document = try Skin2Document.load(data: Data("""
      { "formatVersion": "2.0", "requires": [], "identifier": "test", "name": "Test",
        "gameTypes": ["com.provenance.gamecube"],
        "reference": { "shortSide": 390, "minScale": 1, "maxScale": 1 },
        "root": { "type": "group", "children": [
          { "type": "control", "id": "l", "kind": "trigger", "input": "l",
            "layout": { "frame": [0, 0, 80, 40] } } ] } }
      """.utf8))
      let resolution = Skin2Resolver.resolve(document, in: Skin2Environment(size: Skin2Size(width: 390, height: 844)))
      let tester = Skin2HitTester(resolution)
      var tracker = Skin2TouchTracker<Int>(tester: tester)
      tracker.began(1, x: 20, y: 20, pressure: 0.25)
      var previous = Skin2TouchSnapshot.empty
      var next = tracker.snapshot()
      skin2InputEvents(from: previous, to: next, tester: tester).forEach(input.handle)
      previous = next
      tracker.moved(1, x: 20, y: 20, pressure: 0.75)
      next = tracker.snapshot()
      skin2InputEvents(from: previous, to: next, tester: tester).forEach(input.handle)
      input.releaseAll()
      XCTAssertEqual(writes.map(\.0), Array(repeating: kind == .gameCube ? 20 : 323, count: 3))
      XCTAssertEqual(writes.map(\.1), [0.25, 0.75, 0])
      XCTAssertEqual(haptics, [.press])
    }
  }

  func testStickHapticsRetainTouchDownAndRimHysteresis() throws {
    var haptics: [TouchHapticEvent] = []
    let input = DefaultSkin2Input(padKind: .gameCube, deviceId: 999, writeButton: { _, _ in },
                                  writeAxis: { _, _ in }, playHaptic: { haptics.append($0) })
    let document = try Skin2Document.load(data: Data("""
    { "formatVersion": "2.0", "requires": ["controls.thumbstick"], "identifier": "test", "name": "Test",
      "gameTypes": ["ngc"], "reference": { "shortSide": 390, "minScale": 1, "maxScale": 1 },
      "root": { "type": "group", "children": [
        { "type": "control", "id": "stick", "kind": "thumbstick", "input": "leftThumbstick",
          "travel": 20, "layout": { "frame": [20, 20, 80, 80] } } ] } }
    """.utf8))
    let tester = Skin2HitTester(Skin2Resolver.resolve(document, in: Skin2Environment(size: .init(width: 390, height: 844))))
    var tracker = Skin2TouchTracker<Int>(tester: tester)
    var previous = Skin2TouchSnapshot.empty
    let emit = {
      let next = tracker.snapshot()
      skin2InputEvents(from: previous, to: next, tester: tester).forEach(input.handle)
      previous = next
    }
    tracker.began(1, x: 60, y: 60)
    emit()
    tracker.moved(1, x: 78, y: 60)
    emit()
    tracker.moved(1, x: 80, y: 60)
    emit()
    tracker.moved(1, x: 70, y: 60)
    emit()
    tracker.moved(1, x: 80, y: 60)
    emit()
    tracker.ended(1)
    emit()
    XCTAssertEqual(haptics, [.stickTouchDown, .stickRim, .stickRim])
  }

  func testMicrophoneRetainsSlotBButtonMapping() {
    var writes: [(Int, Bool)] = []
    let input = DefaultSkin2Input(padKind: .gameCube, deviceId: 999,
                                  writeButton: { writes.append(($0, $1)) }, writeAxis: { _, _ in })
    input.press("mic")
    input.release("mic")
    XCTAssertEqual(writes.map(\.0), [22, 22])
    XCTAssertEqual(writes.map(\.1), [true, false])
  }

  func testBothSticksRetainTheFourHalfAxisConvention() {
    let mappings: [TouchOverlayPadKind: [String: Int]] = [
      .gameCube: ["leftThumbstick": 10, "rightThumbstick": 15],
      .wiiRemote: ["leftThumbstick": 202],
      .wiiRemoteSideways: ["leftThumbstick": 202],
      .wiiClassic: ["leftThumbstick": 313, "rightThumbstick": 318],
    ]
    for kind in TouchOverlayPadKind.allCases {
      for (name, base) in mappings[kind]! {
        var writes: [(Int, Float)] = []
        let input = DefaultSkin2Input(padKind: kind, deviceId: 999, writeButton: { _, _ in },
                                      writeAxis: { writes.append(($0, $1)) })
        input.stick(name, x: -0.5, y: 0.75)
        let expected = TouchOverlayInput.stickWrites(x: -0.5, y: 0.75, baseId: base)
        XCTAssertEqual(writes.map(\.0), expected.map(\.id))
        XCTAssertEqual(writes.map(\.1), expected.map(\.value))
      }
    }
  }
}
#endif
