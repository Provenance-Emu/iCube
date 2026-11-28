// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Metal
import XCTest
@testable import iCube

/// The screen filters must be given the game picture, not the whole frame. On a view wider than the picture
/// the frame has black bars; a preset that draws its own TV then shrank the game, and one that assumes a 4:3
/// source zoomed in and cropped it.
final class ShaderPictureGeometryTests: XCTestCase {
  private let wideFrame = CGSize(width: 2556, height: 1179)

  func testAPictureWithBarsBesideItIsCutOut() {
    let picture = CGRect(x: 492, y: 0, width: 1572, height: 1179)
    XCTAssertEqual(ShaderPictureGeometry.pictureRect(reported: picture, textureSize: wideFrame), picture)
  }

  func testAPictureWithBarsAboveAndBelowIsCutOut() {
    let picture = CGRect(x: 0, y: 150, width: 1179, height: 884)
    XCTAssertEqual(ShaderPictureGeometry.pictureRect(reported: picture, textureSize: CGSize(width: 1179, height: 1184)), picture)
  }

  func testAPictureThatFillsTheFrameTakesTheWholeFrame() {
    let frame = CGSize(width: 1440, height: 1080)
    XCTAssertNil(ShaderPictureGeometry.pictureRect(reported: CGRect(origin: .zero, size: frame), textureSize: frame))
  }

  func testAPictureLargerThanTheFrameIsLimitedToIt() {
    // A zoomed picture: the core's rectangle reaches past the frame on both sides.
    let reported = CGRect(x: -200, y: 0, width: 2956, height: 1179)
    XCTAssertNil(ShaderPictureGeometry.pictureRect(reported: reported, textureSize: wideFrame))
    let offCentre = CGRect(x: 300, y: -50, width: 2556, height: 1279)
    XCTAssertEqual(ShaderPictureGeometry.pictureRect(reported: offCentre, textureSize: wideFrame),
                   CGRect(x: 300, y: 0, width: 2256, height: 1179))
  }

  func testFractionalEdgesLandOnWholePixels() {
    let picture = ShaderPictureGeometry.pictureRect(reported: CGRect(x: 491.5, y: 0, width: 1572.6, height: 1179),
                                                    textureSize: wideFrame)
    XCTAssertEqual(picture, CGRect(x: 491, y: 0, width: 1574, height: 1179))
  }

  func testUnusableRectanglesTakeTheWholeFrame() {
    let unusable: [CGRect] = [.null, .infinite, .zero, CGRect(x: 0, y: 0, width: 0, height: 1179),
                              CGRect(x: 3000, y: 0, width: 100, height: 100),
                              CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
                              CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)]
    for rect in unusable {
      XCTAssertNil(ShaderPictureGeometry.pictureRect(reported: rect, textureSize: wideFrame), "\(rect)")
    }
    XCTAssertNil(ShaderPictureGeometry.pictureRect(reported: CGRect(x: 0, y: 0, width: 10, height: 10), textureSize: .zero))
  }

  func testTheFilterChainDrawsIntoTheRectangleItIsGiven() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let chain = try FilterChain(device: device)
    let picture = CGRect(x: 492, y: 0, width: 1572, height: 1179)
    chain.drawableSize = wideFrame
    chain.setSourceRect(CGRect(origin: .zero, size: picture.size), aspect: picture.size)
    chain.outputRect = picture
    XCTAssertEqual(chain.outputBounds, picture)

    // An off-centre picture is not where an aspect fit would put it.
    let offCentre = CGRect(x: 100, y: 0, width: 1572, height: 1179)
    chain.outputRect = offCentre
    XCTAssertEqual(chain.outputBounds, offCentre)

    // Without one, the picture's shape is fitted into the drawable, centred, as before.
    chain.outputRect = nil
    XCTAssertEqual(chain.outputBounds, picture)
  }
}
