// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Metal
import XCTest
@testable import iCube

/// The screen-filter pipeline must be able to start from the shipped app bundle. When release builds
/// moved to the Tuist project, nothing compiled Common/Swift/Shaders/*.metal, the app shipped without
/// default.metallib, FilterChain's init threw and every filter silently drew the unfiltered frame.
final class ShaderPipelineTests: XCTestCase {
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
