#if os(iOS) && DEBUG
import CoreGraphics
import SkinKit2Core
import UIKit
import XCTest
@testable import iCube

@MainActor
final class DefaultSkin2DocumentTests: XCTestCase {
  func testAllFourDocumentsMatchTheLegacyGroupGeometry() throws {
    for kind in TouchOverlayPadKind.allCases {
      let document = try DefaultSkin2Pad.document(for: kind)
      for device in TouchOverlayPreviewDevice.all {
        for orientation in TouchOverlayOrientation.allCases {
          let size = device.size(orientation)
          let bounds = CGRect(origin: .zero, size: size)
          let environment = DefaultSkin2Pad.environment(canvas: size, safeArea: device.insets(orientation),
                                                        flags: ["microphone"], isPad: device.isPad)
          let prepared = DefaultSkin2Pad.documentForCanvas(document, for: kind, environment: environment)
          let resolution = Skin2Resolver.resolve(prepared, in: environment)
          let groups = Dictionary(uniqueKeysWithValues: DefaultSkin2Pad.groups(in: resolution).map { ($0.group, $0) })
          let legacy = TouchOverlayDefaults.layout(for: kind, orientation: orientation, canvas: size,
                                                  safeArea: device.insets(orientation))
          XCTAssertEqual(Set(groups.keys), Set(legacy.map(\.group)), "\(kind) \(device.name) \(orientation)")
          let store = TouchOverlayLayoutStore(fileURL: nil)
          for group in legacy {
            let expected = store.resolvedBox(for: group, padKind: kind, orientation: orientation, in: bounds)
            let actual = try XCTUnwrap(groups[group.group]).placement.box(in: bounds)
            let context = "\(kind) \(device.name) \(orientation) \(group.group)"
            XCTAssertEqual(Double(actual.minX), Double(expected.minX), accuracy: 0.5, context)
            XCTAssertEqual(Double(actual.minY), Double(expected.minY), accuracy: 0.5, context)
            XCTAssertEqual(Double(actual.width), Double(expected.width), accuracy: 0.5, context)
            XCTAssertEqual(Double(actual.height), Double(expected.height), accuracy: 0.5, context)
          }
        }
      }
    }
  }

  func testSavedGroupMovesAndSizesReachEveryControlInTheBundledDocuments() throws {
    for kind in TouchOverlayPadKind.allCases {
      let document = try DefaultSkin2Pad.document(for: kind)
      for device in TouchOverlayPreviewDevice.all {
        for orientation in TouchOverlayOrientation.allCases {
          let size = device.size(orientation)
          let bounds = CGRect(origin: .zero, size: size)
          let environment = DefaultSkin2Pad.environment(canvas: size, safeArea: device.insets(orientation),
                                                        flags: ["microphone"], isPad: device.isPad)
          let prepared = DefaultSkin2Pad.documentForCanvas(document, for: kind, environment: environment)
          let base = Skin2Resolver.resolve(prepared, in: environment)
          let legacy = TouchOverlayDefaults.layout(for: kind, orientation: orientation, canvas: size,
                                                  safeArea: device.insets(orientation))
          let store = TouchOverlayLayoutStore(fileURL: nil)
          for group in legacy {
            store.setCenter(CGPoint(x: bounds.width * 0.4, y: bounds.height * 0.6), in: bounds,
                            for: group.group, padKind: kind, orientation: orientation)
            if group.group == .wiiIRPad {
              store.setIRSizeScale(CGSize(width: 0.7, height: 0.9), for: group.group, padKind: kind,
                                   orientation: orientation, bounds: bounds,
                                   baseSize: group.placement.resolvedSize(in: bounds))
            } else {
              store.setSizeScale(1.25, for: group.group, padKind: kind, orientation: orientation, in: bounds)
            }
          }
          let edits = store.format2Edits(padKind: kind, orientation: orientation, resolution: base, bounds: bounds)
          let edited = Skin2Resolver.resolve(prepared, in: environment, edits: edits)
          for group in legacy {
            let box = store.resolvedBox(for: group, padKind: kind, orientation: orientation, in: bounds)
            let scale = store.sizeScaleXY(for: group.group, padKind: kind, orientation: orientation)
            for control in group.controls where group.group != .wiiIRPad {
              let actual = try XCTUnwrap(edited.node(id: control.id)).exactFrame
              let expected = CGRect(x: box.minX + control.frame.minX * scale.width,
                                    y: box.minY + control.frame.minY * scale.height,
                                    width: control.frame.width * scale.width, height: control.frame.height * scale.height)
              let context = "\(kind) \(device.name) \(orientation) \(control.id)"
              XCTAssertEqual(Double(actual.x), Double(expected.minX), accuracy: 0.5, context)
              XCTAssertEqual(Double(actual.y), Double(expected.minY), accuracy: 0.5, context)
              XCTAssertEqual(Double(actual.width), Double(expected.width), accuracy: 0.5, context)
              XCTAssertEqual(Double(actual.height), Double(expected.height), accuracy: 0.5, context)
            }
          }
        }
      }
    }
  }

  func testEveryBakedFallbackLoadsForBothDevicesAndOrientations() throws {
    let root = try XCTUnwrap(Bundle.main.url(forResource: "DefaultSkins", withExtension: nil))
    for kind in TouchOverlayPadKind.allCases {
      let directory = root.appendingPathComponent(kind.rawValue)
      let info = try SkinInfo.load(directory: directory)
      for device in SkinDevice.allCases {
        for orientation in TouchOverlayOrientation.allCases {
          let representation = try XCTUnwrap(info.representation(device: device, orientation: orientation))
          XCTAssertFalse(representation.items.isEmpty)
        }
      }
      let files = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("bake"),
                                                               includingPropertiesForKeys: nil)
      let pdfs = files.filter { $0.pathExtension == "pdf" }
      XCTAssertGreaterThanOrEqual(pdfs.count, 6)
      for file in pdfs {
        XCTAssertNotNil(CGPDFDocument(file as CFURL), file.lastPathComponent)
      }
      XCTAssertNotNil(UIImage(contentsOfFile: directory.appendingPathComponent("preview.png").path))
    }
  }

  func testMicrophoneVisibilityKeepsItsSavedIdentity() throws {
    let document = try DefaultSkin2Pad.document(for: .gameCube)
    let size = CGSize(width: 393, height: 852)
    let hidden = DefaultSkin2Pad.environment(canvas: size, safeArea: .zero, flags: [])
    let shown = DefaultSkin2Pad.environment(canvas: size, safeArea: .zero, flags: ["microphone"])
    let hiddenResolution = Skin2Resolver.resolve(document, in: hidden)
    XCTAssertNil(hiddenResolution.node(id: "gc.mic"))
    XCTAssertFalse(DefaultSkin2Pad.groups(in: hiddenResolution).contains { $0.group == .gcMicrophone })
    XCTAssertNotNil(Skin2Resolver.resolve(document, in: shown).node(id: "gc.mic"))
  }
}
#endif
