// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
@testable import iCube

final class SkinLayoutTests: XCTestCase {
  private func rep(mapping: CGSize, items: [SkinItem], screen: CGRect?) -> SkinRepresentation {
    SkinRepresentation(mappingSize: mapping, items: items, screens: screen.map { [SkinScreen(outputFrame: $0)] } ?? [],
                       background: nil, translucent: false, extendedEdges: .zero)
  }

  func testAspectFitsAndBottomAnchorsInPortrait() {
    let item = SkinItem(inputs: .buttons(["a"]), frame: CGRect(x: 10, y: 800, width: 40, height: 40),
                        extendedEdges: UIEdgeInsets(top: 5, left: 5, bottom: 5, right: 5), asset: nil, thumbstick: nil)
    let layout = SkinLayout.make(rep(mapping: CGSize(width: 390, height: 844), items: [item],
                                     screen: CGRect(x: 0, y: 60, width: 390, height: 292)),
                                 canvas: CGSize(width: 780, height: 1800))
    // Scale = min(780/390, 1800/844) = 2; skin is 780x1688, bottom-anchored: origin y = 1800-1688.
    XCTAssertEqual(layout.skinRect, CGRect(x: 0, y: 112, width: 780, height: 1688))
    XCTAssertEqual(layout.items[0].drawFrame, CGRect(x: 20, y: 112 + 1600, width: 80, height: 80))
    XCTAssertEqual(layout.items[0].hitFrame, CGRect(x: 10, y: 112 + 1590, width: 100, height: 100), "extendedEdges scale too")
    XCTAssertEqual(layout.gameRect, CGRect(x: 0, y: 112 + 120, width: 780, height: 584))
  }

  func testCentresInLandscapeAndHasNoGameRectWithoutScreens() {
    let layout = SkinLayout.make(rep(mapping: CGSize(width: 844, height: 390), items: [], screen: nil),
                                 canvas: CGSize(width: 1000, height: 390))
    XCTAssertEqual(layout.skinRect, CGRect(x: 78, y: 0, width: 844, height: 390))
    XCTAssertNil(layout.gameRect)
  }
}
#endif
