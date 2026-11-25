// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics
import XCTest
@testable import iCube

/// A preset's render targets are sized from the frame it filters, and nothing bounded their total.
/// On an iPad Pro (2732 x 2048) one bundled preset asked for 3.8 GB and iOS killed the app for
/// memory a second after the game started (2026-11-25).
final class ShaderRenderTargetBudgetTests: XCTestCase {
  private typealias Request = FilterChain.RenderTargetRequest
  private let mib = 1_048_576.0

  private func bytes(_ requests: [Request], _ sizes: [CGSize]) -> Double {
    zip(requests, sizes).reduce(0) { $0 + $1.0.bytes(at: $1.1) }
  }

  func testBudgetIsAnEighthOfMemoryWithinBounds() {
    let gib: UInt64 = 1_073_741_824
    XCTAssertEqual(FilterChain.renderTargetBudget(physicalMemory: 6 * gib), 768 * 1_048_576)
    XCTAssertEqual(FilterChain.renderTargetBudget(physicalMemory: 1 * gib), 256 * 1_048_576, "floor")
    XCTAssertEqual(FilterChain.renderTargetBudget(physicalMemory: 96 * gib), 2048 * 1_048_576, "ceiling")
  }

  func testChainInsideTheBudgetIsLeftAlone() {
    let requests = [
      Request(size: CGSize(width: 640, height: 480), bytesPerPixel: 4, copies: 1, canShrink: true),
      Request(size: CGSize(width: 1280, height: 960), bytesPerPixel: 8, copies: 2, canShrink: true),
      Request(size: CGSize(width: 2732, height: 2048), bytesPerPixel: 4, copies: 0, canShrink: false)
    ]
    XCTAssertEqual(FilterChain.fitRenderTargets(requests, fixedBytes: 0, budget: 708 * mib), requests.map(\.size))
  }

  /// The shape of the preset that was killed: 4x passes over a display-sized source.
  func testOversizedChainShrinksUnderTheBudgetAndKeepsPassRatios() throws {
    let source = CGSize(width: 2732, height: 2048)
    let requests = [
      Request(size: source, bytesPerPixel: 8, copies: 1, canShrink: true),
      Request(size: CGSize(width: source.width * 4, height: source.height * 4), bytesPerPixel: 4, copies: 1, canShrink: true),
      Request(size: CGSize(width: source.width * 4, height: source.height * 4), bytesPerPixel: 8, copies: 2, canShrink: true),
      Request(size: source, bytesPerPixel: 4, copies: 0, canShrink: false)
    ]
    let budget = 708 * mib
    XCTAssertGreaterThan(bytes(requests, requests.map(\.size)), 1700 * mib)

    let sizes = try XCTUnwrap(FilterChain.fitRenderTargets(requests, fixedBytes: 0, budget: budget))

    XCTAssertLessThanOrEqual(bytes(requests, sizes), budget)
    XCTAssertGreaterThan(bytes(requests, sizes), budget * 0.95, "No smaller than the budget requires")
    XCTAssertEqual(sizes[1].width / sizes[0].width, 4, accuracy: 0.01)
    XCTAssertEqual(sizes[1].height / sizes[0].height, 4, accuracy: 0.01)
    XCTAssertEqual(sizes[0].width / sizes[0].height, source.width / source.height, accuracy: 0.01)
    XCTAssertEqual(sizes[3], source, "The output pass keeps the output's size")
  }

  func testFixedTargetsAndHistoryCountButDoNotShrink() throws {
    let lut = Request(size: CGSize(width: 1024, height: 1024), bytesPerPixel: 4, copies: 1, canShrink: false)
    let big = Request(size: CGSize(width: 8192, height: 8192), bytesPerPixel: 4, copies: 1, canShrink: true)
    let history = 100 * mib
    let budget = 300 * mib

    let sizes = try XCTUnwrap(FilterChain.fitRenderTargets([lut, big], fixedBytes: history, budget: budget))

    XCTAssertEqual(sizes[0], lut.size)
    XCTAssertLessThan(sizes[1].width, big.size.width)
    XCTAssertLessThanOrEqual(bytes([lut, big], sizes) + history, budget)
  }

  func testChainThatCannotFitIsRefused() {
    let fixed = Request(size: CGSize(width: 16384, height: 16384), bytesPerPixel: 4, copies: 1, canShrink: false)
    XCTAssertNil(FilterChain.fitRenderTargets([fixed], fixedBytes: 0, budget: 708 * mib))
    let small = Request(size: CGSize(width: 64, height: 64), bytesPerPixel: 4, copies: 1, canShrink: true)
    XCTAssertNil(FilterChain.fitRenderTargets([small], fixedBytes: 800 * mib, budget: 708 * mib), "History alone is over")
    XCTAssertNil(FilterChain.fitRenderTargets([small], fixedBytes: .infinity, budget: 708 * mib))
  }

  func testShrunkTargetNeverReachesZero() throws {
    let wide = Request(size: CGSize(width: 16000, height: 1), bytesPerPixel: 16, copies: 2, canShrink: true)
    let sizes = try XCTUnwrap(FilterChain.fitRenderTargets([wide], fixedBytes: 0, budget: 1024))
    XCTAssertGreaterThanOrEqual(sizes[0].width, 1)
    XCTAssertGreaterThanOrEqual(sizes[0].height, 1)
  }
}
