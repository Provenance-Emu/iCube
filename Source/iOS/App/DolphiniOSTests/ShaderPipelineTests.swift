// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Metal
import XCTest
@testable import iCube

/// The screen-filter pipeline must be able to start from the shipped app bundle. When release builds
/// moved to the Tuist project, nothing compiled Common/Swift/Shaders/*.metal, the app shipped without
/// default.metallib, FilterChain's init threw and every filter silently drew the unfiltered frame.
final class ShaderPipelineTests: XCTestCase {
  func testClearTextureLayoutAcceptsExactRGBA32FloatLimit() throws {
    let gib = 1_073_741_824
    let layout = try XCTUnwrap(FilterChain.clearTextureLayout(
      width: 8192, height: 8192, bytesPerPixel: MTLPixelFormat.rgba32Float.bytesPerPixel,
      maxBufferLength: gib))
    XCTAssertEqual(layout.bytesPerRow, 131_072)
    XCTAssertEqual(layout.bytesPerImage, gib)
    XCTAssertNil(FilterChain.clearTextureLayout(
      width: 8192, height: 8192, bytesPerPixel: MTLPixelFormat.rgba32Float.bytesPerPixel,
      maxBufferLength: 268_435_456))
  }

  func testClearTextureLayoutRejectsOneByteOverLimit() {
    XCTAssertNil(FilterChain.clearTextureLayout(
      width: 8192, height: 8192, bytesPerPixel: 16, maxBufferLength: 1_073_741_823))
    XCTAssertNil(FilterChain.clearTextureLayout(
      width: 65, height: 1, bytesPerPixel: 1, maxBufferLength: 64))
  }

  func testClearTextureLayoutPreservesPixelStrides() throws {
    for bytesPerPixel in [1, 2, 4, 8, 16] {
      let imageBytes = 35 * bytesPerPixel
      let layout = try XCTUnwrap(FilterChain.clearTextureLayout(
        width: 7, height: 5, bytesPerPixel: bytesPerPixel, maxBufferLength: imageBytes))
      XCTAssertEqual(layout.bytesPerRow, 7 * bytesPerPixel)
      XCTAssertEqual(layout.bytesPerImage, imageBytes)
      XCTAssertNil(FilterChain.clearTextureLayout(
        width: 7, height: 5, bytesPerPixel: bytesPerPixel, maxBufferLength: imageBytes - 1))
    }
  }

  func testClearTextureLayoutRejectsNonpositiveOrUnknownLayouts() {
    let invalidLayouts = [(0, 1, 4, 64), (-1, 1, 4, 64), (1, 0, 4, 64), (1, -1, 4, 64),
                          (1, 1, 0, 64), (1, 1, -1, 64), (1, 1, 4, 0), (1, 1, 4, -1)]
    for (width, height, bytesPerPixel, limit) in invalidLayouts {
      XCTAssertNil(FilterChain.clearTextureLayout(
        width: width, height: height, bytesPerPixel: bytesPerPixel, maxBufferLength: limit))
    }
    XCTAssertNil(FilterChain.clearTextureLayout(
      width: 1, height: 1, bytesPerPixel: MTLPixelFormat.invalid.bytesPerPixel, maxBufferLength: 64))
  }

  func testClearTextureLayoutRejectsOverflow() {
    XCTAssertNil(FilterChain.clearTextureLayout(
      width: Int.max, height: 1, bytesPerPixel: 2, maxBufferLength: Int.max))
    XCTAssertNil(FilterChain.clearTextureLayout(
      width: Int.max, height: 2, bytesPerPixel: 1, maxBufferLength: Int.max))
  }

  func testTheAppBundleCarriesTheFilterChainShaders() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let library = try device.makeDefaultLibrary(bundle: Bundle(for: FilterChain.self))
    XCTAssertNotNil(library.makeFunction(name: "basic_vertex_proj_tex"))
    XCTAssertNotNil(library.makeFunction(name: "basic_fragment_proj_tex"))
  }

  func testFilterChainStarts() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    XCTAssertNoThrow(try FilterChain(device: device))
  }

  func testABundledPresetLoadsIntoTheChain() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let chain = try FilterChain(device: device)
    let preset = try XCTUnwrap(Bundle(for: FilterChain.self).url(
      forResource: "gameboy-advance-dot-matrix", withExtension: "oecompiledshader",
      subdirectory: "compiled_shaders/handheld"))
    let container = try ZipCompiledShaderContainer.Decoder(url: preset)
    defer { container.removeExtractedFiles() }
    XCTAssertNoThrow(try chain.setCompiledShader(container))
  }
}
