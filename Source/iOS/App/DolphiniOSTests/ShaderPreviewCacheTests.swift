// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics
import XCTest
@testable import iCube

/// Covers the pure, Metal-free surfaces of the shader preview pipeline:
/// `LRUCache`'s eviction/keying (used by `ShaderPreviewCache`),
/// `ShaderPreviewCacheKey`'s `Hashable` conformance, and
/// `ShaderPreviewRenderer.downscaledCGImage` (plain CoreGraphics, no device
/// needed). Actual Metal rendering is NOT exercised here — the renderer is
/// specified to return `nil` on the Simulator (where these tests run), which
/// is covered separately by `testRenderPreviewReturnsNilOnSimulator`.
final class ShaderPreviewCacheTests: XCTestCase {
  // MARK: - LRUCache

  func testInsertAndFetch() {
    var cache = LRUCache<String, Int>(capacity: 3)
    cache.setValue(1, forKey: "a")
    XCTAssertEqual(cache.value(forKey: "a"), 1)
    XCTAssertNil(cache.value(forKey: "b"))
    XCTAssertEqual(cache.count, 1)
  }

  func testOverwritingExistingKeyDoesNotGrowCount() {
    var cache = LRUCache<String, Int>(capacity: 3)
    cache.setValue(1, forKey: "a")
    cache.setValue(2, forKey: "a")
    XCTAssertEqual(cache.count, 1)
    XCTAssertEqual(cache.value(forKey: "a"), 2)
  }

  func testEvictsLeastRecentlyUsedWhenOverCapacity() {
    var cache = LRUCache<String, Int>(capacity: 2)
    cache.setValue(1, forKey: "a")
    cache.setValue(2, forKey: "b")
    cache.setValue(3, forKey: "c") // over capacity -> evicts "a" (least recently used)

    XCTAssertNil(cache.value(forKey: "a"))
    XCTAssertEqual(cache.value(forKey: "b"), 2)
    XCTAssertEqual(cache.value(forKey: "c"), 3)
    XCTAssertEqual(cache.count, 2)
  }

  func testMarkUsedProtectsFromEviction() {
    var cache = LRUCache<String, Int>(capacity: 2)
    cache.setValue(1, forKey: "a")
    cache.setValue(2, forKey: "b")
    // Touch "a" so it becomes MOST recently used, leaving "b" as the next to evict.
    cache.markUsed("a")
    cache.setValue(3, forKey: "c")

    XCTAssertEqual(cache.value(forKey: "a"), 1, "recently-used key should survive eviction")
    XCTAssertNil(cache.value(forKey: "b"), "least-recently-used key should be evicted")
    XCTAssertEqual(cache.value(forKey: "c"), 3)
  }

  func testMarkUsedOnMissingKeyIsANoOp() {
    var cache = LRUCache<String, Int>(capacity: 2)
    cache.markUsed("missing") // must not crash or insert a value
    XCTAssertEqual(cache.count, 0)
    XCTAssertNil(cache.value(forKey: "missing"))
  }

  func testRemoveValue() {
    var cache = LRUCache<String, Int>(capacity: 3)
    cache.setValue(1, forKey: "a")
    cache.removeValue(forKey: "a")
    XCTAssertNil(cache.value(forKey: "a"))
    XCTAssertEqual(cache.count, 0)
  }

  func testRemoveAll() {
    var cache = LRUCache<String, Int>(capacity: 3)
    cache.setValue(1, forKey: "a")
    cache.setValue(2, forKey: "b")
    cache.removeAll()
    XCTAssertEqual(cache.count, 0)
    XCTAssertNil(cache.value(forKey: "a"))
    XCTAssertNil(cache.value(forKey: "b"))
  }

  func testCapacityIsClampedToAtLeastOne() {
    let cache = LRUCache<String, Int>(capacity: 0)
    XCTAssertEqual(cache.capacity, 1)
  }

  // MARK: - ShaderPreviewCacheKey

  func testCacheKeyEqualityRequiresAllFieldsToMatch() {
    let a = ShaderPreviewCacheKey(presetPath: "/a/CRT.oecompiledshader", sourceMTime: 100, thumbnailWidth: 320)
    let b = ShaderPreviewCacheKey(presetPath: "/a/CRT.oecompiledshader", sourceMTime: 100, thumbnailWidth: 320)
    let differentPath = ShaderPreviewCacheKey(presetPath: "/a/Other.oecompiledshader", sourceMTime: 100, thumbnailWidth: 320)
    let differentMTime = ShaderPreviewCacheKey(presetPath: "/a/CRT.oecompiledshader", sourceMTime: 200, thumbnailWidth: 320)
    let differentWidth = ShaderPreviewCacheKey(presetPath: "/a/CRT.oecompiledshader", sourceMTime: 100, thumbnailWidth: 160)

    XCTAssertEqual(a, b)
    XCTAssertNotEqual(a, differentPath)
    XCTAssertNotEqual(a, differentMTime)
    XCTAssertNotEqual(a, differentWidth)
  }

  func testCacheKeyDefaultsThumbnailWidthToRendererConstant() {
    let key = ShaderPreviewCacheKey(presetPath: "/a/CRT.oecompiledshader", sourceMTime: 100)
    XCTAssertEqual(key.thumbnailWidth, Int(ShaderPreviewRenderer.thumbnailSize.width))
  }

  // A stale pause frame (older mtime) must key differently from a fresh one —
  // this is the entire invalidation mechanism, see the key's doc comment.
  func testCacheKeyChangesWhenSourceFrameMTimeChanges() {
    let stale = ShaderPreviewCacheKey(presetPath: "/a/CRT.oecompiledshader", sourceMTime: 1000)
    let fresh = ShaderPreviewCacheKey(presetPath: "/a/CRT.oecompiledshader", sourceMTime: 2000)
    XCTAssertNotEqual(stale, fresh)
    XCTAssertNotEqual(stale.hashValue, fresh.hashValue)
  }

  // MARK: - ShaderPreviewRenderer.downscaledCGImage (pure CoreGraphics)

  private func makeCGImage(width: Int, height: Int) -> CGImage? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }

  func testDownscaleReturnsOriginalWhenAlreadyNarrowEnough() throws {
    let image = try XCTUnwrap(makeCGImage(width: 200, height: 100))
    let result = ShaderPreviewRenderer.downscaledCGImage(image, maxWidth: 640)
    XCTAssertEqual(result.width, 200)
    XCTAssertEqual(result.height, 100)
  }

  func testDownscalePreservesAspectRatio() throws {
    let image = try XCTUnwrap(makeCGImage(width: 1280, height: 720))
    let result = ShaderPreviewRenderer.downscaledCGImage(image, maxWidth: 640)
    XCTAssertEqual(result.width, 640)
    XCTAssertEqual(result.height, 360, accuracy: 1)
  }

  func testDownscaleWithZeroMaxWidthReturnsOriginalUnchanged() throws {
    let image = try XCTUnwrap(makeCGImage(width: 1280, height: 720))
    let result = ShaderPreviewRenderer.downscaledCGImage(image, maxWidth: 0)
    XCTAssertEqual(result.width, 1280)
    XCTAssertEqual(result.height, 720)
  }

  // MARK: - ShaderPreviewRenderer Simulator/no-device guard

  /// Tests run on the Simulator, so `ShaderPreviewRenderer.isSupported` must be
  /// `false` there per spec (regardless of whether the Simulator's own Metal
  /// backend happens to work) — this exercises that guard rather than mocking it.
  func testIsSupportedIsFalseOnSimulator() throws {
    #if targetEnvironment(simulator)
    XCTAssertFalse(ShaderPreviewRenderer.isSupported)
    #else
    throw XCTSkip("Only meaningful on the Simulator; see testRenderPreviewReturnsNilOnDeviceWithoutValidPreset for device coverage intent.")
    #endif
  }

  func testRenderPreviewReturnsNilOnSimulator() async throws {
    #if targetEnvironment(simulator)
    let image = try XCTUnwrap(makeCGImage(width: 64, height: 64))
    let bogusURL = URL(fileURLWithPath: "/nonexistent/Fake.oecompiledshader")
    let result = await ShaderPreviewRenderer.renderPreview(presetURL: bogusURL, sourceImage: image, timeout: 1)
    XCTAssertNil(result)
    #else
    throw XCTSkip("This asserts the Simulator-specific guard; not meaningful on device.")
    #endif
  }
}
