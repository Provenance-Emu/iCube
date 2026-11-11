// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import CoreGraphics
import Foundation
import SkinKit2Core
import XCTest

@testable import iCube

final class TouchOverlayFormat2MigrationTests: XCTestCase {
  private let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)

  private func resolution(ids: [String], unit: Double = 1, canvas: CGRect = CGRect(x: 0, y: 0, width: 400, height: 800)) throws -> Skin2Resolution {
    let children = ids.map { id in
      #"{"type":"control","id":"\#(id)","kind":"button","input":"a","layout":{"anchor":{"x":"center","y":"center"},"size":{"width":40,"height":40}}}"#
    }.joined(separator: ",")
    let shortSide = Double(min(canvas.width, canvas.height)) / unit
    let json = #"{"formatVersion":"2.0","identifier":"test","name":"Test","gameTypes":["gamecube"],"reference":{"shortSide":\#(shortSide),"minScale":1,"maxScale":2},"root":{"type":"group","children":[\#(children)]}}"#
    let document = try JSONDecoder().decode(Skin2Document.self, from: Data(json.utf8))
    return Skin2Resolver.resolve(document, in: Skin2Environment(size: Skin2Size(width: canvas.width, height: canvas.height)))
  }

  private func groupedDocument() throws -> Skin2Document {
    let json = #"{"formatVersion":"2.0","identifier":"test","name":"Test","gameTypes":["gamecube"],"reference":{"shortSide":400,"minScale":1,"maxScale":2},"root":{"type":"group","children":[{"type":"group","id":"gcFaceButtons","layout":{"inset":0},"children":[{"type":"control","id":"gc.a","kind":"button","input":"a","layout":{"size":{"width":40,"height":30},"anchor":{"x":"leading","y":"top"},"offset":{"x":40,"y":70}}},{"type":"control","id":"gc.b","kind":"button","input":"b","layout":{"size":{"width":60,"height":30},"anchor":{"x":"leading","y":"top"},"offset":{"x":100,"y":70}}}]}]}}"#
    return try JSONDecoder().decode(Skin2Document.self, from: Data(json.utf8))
  }

  private func groupedResolution() throws -> Skin2Resolution {
    Skin2Resolver.resolve(try groupedDocument(), in: Skin2Environment(size: Skin2Size(width: 400, height: 800)))
  }

  @MainActor
  private func legacyStore(_ entries: [String: [String: [Double]]], dir: URL) throws -> (TouchOverlayLayoutStore, URL) {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let legacyURL = dir.appendingPathComponent(TouchOverlayLayoutStore.legacyFileName)
    try JSONSerialization.data(withJSONObject: entries).write(to: legacyURL)
    return (TouchOverlayLayoutStore(fileURL: nil, legacyFileURL: legacyURL), legacyURL)
  }

  @MainActor
  func testLegacyPositionAndUniformScaleConvertForEveryPadAndOrientation() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    for pad in TouchOverlayPadKind.allCases {
      for orientation in TouchOverlayOrientation.allCases {
        let group: TouchOverlayGroup
        switch pad {
        case .gameCube: group = .gcDpad
        case .wiiRemote: group = .wiiDpad
        case .wiiRemoteSideways: group = .wiiDpad
        case .wiiClassic: group = .classicDpad
        }
        let id = group.rawValue
        let key = TouchOverlayLayoutStore.key(pad, orientation)
        let (store, legacyURL) = try legacyStore([key: [id: [0.99, 0.25, 1.5], "futureGroup": [0.4, 0.6]]], dir: dir)
        let savedBytes = try Data(contentsOf: legacyURL)
        let result = store.format2Edits(padKind: pad, orientation: orientation,
                                        resolution: try resolution(ids: [id]), bounds: bounds)
        let edit = try XCTUnwrap(result[id])
        XCTAssertEqual(edit.offset?.x ?? .nan, 170, accuracy: 0.001,
                       "the scaled frame is clamped before its centre is converted")
        XCTAssertEqual(edit.offset?.y ?? .nan, -200, accuracy: 0.001)
        XCTAssertEqual(edit.scale, 1.5)
        XCTAssertNotNil(result["futureGroup"])
        let rotatedCanvas = CGRect(x: 0, y: 0, width: 800, height: 400)
        let resized = store.format2Edits(padKind: pad, orientation: orientation,
                                         resolution: try resolution(ids: [id], canvas: rotatedCanvas), bounds: rotatedCanvas)
        XCTAssertEqual(resized[id]?.offset?.x ?? .nan, 370, accuracy: 0.001)
        XCTAssertEqual(resized[id]?.offset?.y ?? .nan, -100, accuracy: 0.001)
        XCTAssertEqual(try Data(contentsOf: legacyURL), savedBytes)
      }
    }
  }

  @MainActor
  func testAnchoredPositionUsesCurrentResolutionAndUnitAndSurvivesReload() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent(TouchOverlayLayoutStore.fileName)
    let id = TouchOverlayGroup.wiiIRPad.rawValue
    let store = TouchOverlayLayoutStore(fileURL: file)
    store.setCenter(CGPoint(x: 400, y: 100), in: bounds, for: .wiiIRPad,
                    padKind: .wiiRemote, orientation: .portrait)
    store.setIRSizeScale(CGSize(width: 1.4, height: 0.8), for: .wiiIRPad,
                         padKind: .wiiRemote, orientation: .portrait, bounds: bounds,
                         baseSize: CGSize(width: 300, height: 700))
    let reloaded = TouchOverlayLayoutStore(fileURL: file)
    let result = reloaded.format2Edits(padKind: .wiiRemote, orientation: .portrait,
                                       resolution: try resolution(ids: [id], unit: 2), bounds: bounds)
    let edit = try XCTUnwrap(result[id])
    XCTAssertEqual(edit.offset?.x ?? .nan, 220.0 / 3, accuracy: 0.001,
                   "independent IR scales clamp the resized footprint before applying the offset")
    XCTAssertEqual(edit.offset?.y ?? .nan, -150, accuracy: 0.001)
    XCTAssertNil(edit.scale)
    XCTAssertEqual(edit.scaleX ?? .nan, 4.0 / 3, accuracy: 0.001)
    XCTAssertEqual(edit.scaleY, 0.8)
  }

  @MainActor
  func testWrapperGroupScaleTransformsDescendantControlsAroundTheirCombinedCenter() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let (store, _) = try legacyStore(
      [TouchOverlayLayoutStore.key(.gameCube, .portrait): ["gcFaceButtons": [0.75, 0.25, 1.5]]], dir: dir)
    let result = store.format2Edits(padKind: .gameCube, orientation: .portrait,
                                    resolution: try groupedResolution(), bounds: bounds)

    let wrapper = try XCTUnwrap(result["gcFaceButtons"])
    XCTAssertNil(wrapper.scale, "the full-canvas wrapper must not be scaled")
    XCTAssertEqual(wrapper.offset?.x ?? .nan, 200, accuracy: 0.001)
    XCTAssertEqual(wrapper.offset?.y ?? .nan, 115, accuracy: 0.001)
    let a = try XCTUnwrap(result["gc.a"])
    let b = try XCTUnwrap(result["gc.b"])
    XCTAssertEqual(a.offset?.x ?? .nan, -20, accuracy: 0.001)
    XCTAssertEqual(b.offset?.x ?? .nan, 15, accuracy: 0.001)
    XCTAssertEqual(a.offset?.y ?? .nan, 0, accuracy: 0.001)
    XCTAssertEqual(a.scale, 1.5)
    XCTAssertEqual(b.scale, 1.5)
  }
  @MainActor
  func testLivePreviewTransformsControlsWithoutSavingOrPrematureClamping() throws {
    let store = TouchOverlayLayoutStore(fileURL: nil)
    let base = try groupedResolution()
    let previews = ["gcFaceButtons": CGRect(x: 350, y: 360, width: 240, height: 60)]
    let edits = store.format2Edits(padKind: .gameCube, orientation: .portrait,
                                  resolution: base, bounds: bounds, previews: previews)
    let document = try groupedDocument()
    let rendered = Skin2Resolver.resolve(document, in: base.environment, edits: edits)
    XCTAssertEqual(rendered.node(id: "gc.a")?.exactFrame,
                   Skin2Rect(x: 350, y: 360, width: 80, height: 60))
    XCTAssertEqual(rendered.node(id: "gc.b")?.exactFrame,
                   Skin2Rect(x: 470, y: 360, width: 120, height: 60))
    XCTAssertFalse(store.hasCustomLayout(padKind: .gameCube, orientation: .portrait))
    XCTAssertTrue(store.format2Edits(padKind: .gameCube, orientation: .portrait,
                                     resolution: base, bounds: bounds).isEmpty)
  }

}
#endif
