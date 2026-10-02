// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
import Compression
import ImageIO
import UIKit
@testable import iCube

final class SkinAssetRendererTests: XCTestCase {
  private static let pdfName = "pad.pdf"
  private static let pngName = "pad.png"
  private static let pixelCap = 4096

  private var scratch: URL!
  private var skinDirectory: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SkinAssetRendererTests-\(UUID().uuidString)")
    skinDirectory = scratch.appendingPathComponent("skin")
    try FileManager.default.createDirectory(at: skinDirectory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  @discardableResult
  private func writePDF(named name: String, in directory: URL, pageSize: CGSize = CGSize(width: 100, height: 50)) throws -> URL {
    let url = directory.appendingPathComponent(name)
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
    try renderer.writePDF(to: url) { context in
      context.beginPage()
      UIColor.red.setFill()
      context.fill(CGRect(origin: .zero, size: pageSize))
    }
    return url
  }

  @discardableResult
  private func writePNG(named name: String, in directory: URL, pixels: Int = 8) throws -> URL {
    let url = directory.appendingPathComponent(name)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels), format: format).image { context in
      UIColor.blue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    }
    try image.pngData()!.write(to: url)
    return url
  }

  private func pixelSize(_ image: UIImage) -> (Int, Int) {
    (image.cgImage!.width, image.cgImage!.height)
  }

  func testPDFRendersToSizeTimesScalePixels() throws {
    try writePDF(named: Self.pdfName, in: skinDirectory)
    let image = try XCTUnwrap(SkinAssetRenderer.image(named: Self.pdfName, in: skinDirectory, size: CGSize(width: 120, height: 60), scale: 3))
    let (width, height) = pixelSize(image)
    XCTAssertEqual(width, 360)
    XCTAssertEqual(height, 180)
    XCTAssertEqual(image.size, CGSize(width: 120, height: 60))
  }

  func testPDFFillsTheTargetRect() throws {
    try writePDF(named: Self.pdfName, in: skinDirectory)
    let image = try XCTUnwrap(SkinAssetRenderer.image(named: Self.pdfName, in: skinDirectory, size: CGSize(width: 40, height: 40), scale: 1))
    let cgImage = try XCTUnwrap(image.cgImage)
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cgImage, in: CGRect(x: -20, y: -20, width: 40, height: 40))
    XCTAssertGreaterThan(pixel[0], 200, "centre of the page should be red")
    XCTAssertLessThan(pixel[2], 50)
  }

  func testPNGPassesThrough() throws {
    try writePNG(named: Self.pngName, in: skinDirectory, pixels: 8)
    let image = try XCTUnwrap(SkinAssetRenderer.image(named: Self.pngName, in: skinDirectory, size: CGSize(width: 100, height: 100), scale: 2))
    let (width, height) = pixelSize(image)
    XCTAssertEqual(width, 8)
    XCTAssertEqual(height, 8)
  }

  func testMissingFileReturnsNil() {
    XCTAssertNil(SkinAssetRenderer.image(named: "nope.pdf", in: skinDirectory, size: CGSize(width: 10, height: 10), scale: 1))
  }

  func testEmptyNameReturnsNil() throws {
    try writePNG(named: Self.pngName, in: skinDirectory)
    XCTAssertNil(SkinAssetRenderer.image(named: "", in: skinDirectory, size: CGSize(width: 10, height: 10), scale: 1))
  }

  func testDegenerateSizeReturnsNil() throws {
    try writePDF(named: Self.pdfName, in: skinDirectory)
    XCTAssertNil(SkinAssetRenderer.image(named: Self.pdfName, in: skinDirectory, size: .zero, scale: 1))
    XCTAssertNil(SkinAssetRenderer.image(named: Self.pdfName, in: skinDirectory, size: CGSize(width: 10, height: 10), scale: 0))
  }

  func testHugeRequestIsClampedPreservingAspect() throws {
    try writePDF(named: Self.pdfName, in: skinDirectory)
    let image = try XCTUnwrap(SkinAssetRenderer.image(named: Self.pdfName, in: skinDirectory, size: CGSize(width: 10_000, height: 5_000), scale: 1))
    let (width, height) = pixelSize(image)
    XCTAssertEqual(width, Self.pixelCap)
    XCTAssertEqual(height, Self.pixelCap / 2)
    XCTAssertEqual(image.size.width / image.size.height, 2, accuracy: 0.001)
  }

  func testCapAppliesToSizeTimesScale() throws {
    try writePDF(named: Self.pdfName, in: skinDirectory)
    let image = try XCTUnwrap(SkinAssetRenderer.image(named: Self.pdfName, in: skinDirectory, size: CGSize(width: 2_000, height: 4_000), scale: 3))
    let (width, height) = pixelSize(image)
    XCTAssertEqual(height, Self.pixelCap)
    XCTAssertEqual(width, Self.pixelCap / 2)
  }

  func testParentTraversalReturnsNil() throws {
    try writePNG(named: "outside.png", in: scratch)
    XCTAssertNil(SkinAssetRenderer.image(named: "../outside.png", in: skinDirectory, size: CGSize(width: 10, height: 10), scale: 1))
  }

  func testAbsolutePathReturnsNil() throws {
    let outside = try writePNG(named: "outside.png", in: scratch)
    XCTAssertNil(SkinAssetRenderer.image(named: outside.path, in: skinDirectory, size: CGSize(width: 10, height: 10), scale: 1))
  }

  func testSymlinkEscapingTheSkinDirectoryReturnsNil() throws {
    let outside = try writePNG(named: "outside.png", in: scratch)
    try FileManager.default.createSymbolicLink(at: skinDirectory.appendingPathComponent("link.png"), withDestinationURL: outside)
    XCTAssertNil(SkinAssetRenderer.image(named: "link.png", in: skinDirectory, size: CGSize(width: 10, height: 10), scale: 1))
  }

  func testNestedRelativePathWorks() throws {
    let nested = skinDirectory.appendingPathComponent("assets")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try writePNG(named: Self.pngName, in: nested)
    XCTAssertNotNil(SkinAssetRenderer.image(named: "assets/\(Self.pngName)", in: skinDirectory, size: CGSize(width: 10, height: 10), scale: 1))
  }

  func testRepeatRequestIsServedFromCache() throws {
    try writePDF(named: Self.pdfName, in: skinDirectory)
    let size = CGSize(width: 30, height: 30)
    let first = try XCTUnwrap(SkinAssetRenderer.image(named: Self.pdfName, in: skinDirectory, size: size, scale: 2))
    let second = try XCTUnwrap(SkinAssetRenderer.image(named: Self.pdfName, in: skinDirectory, size: size, scale: 2))
    XCTAssertTrue(first === second)
  }

  // MARK: Memory bounds

  /// A valid 1-bit grey PNG of `side` x `side` pixels that is all zeros: about 50 KB on disk for `side` 20,000, yet decoding
  /// it takes `side` x `side` x 4 bytes (1.6 GB). ImageIO reports the dimensions only when the data stream is plausible
  /// for them, so the stream has to be real.
  private func bombPNGData(side: Int) -> Data {
    func bigEndian(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> UInt32(24 - 8 * $0)) & 0xFF) } }
    func crc32(_ bytes: [UInt8]) -> UInt32 {
      var crc: UInt32 = 0xFFFF_FFFF
      for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
      }
      return ~crc
    }
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
      let typed = Array(type.utf8) + body
      return bigEndian(UInt32(body.count)) + typed + bigEndian(crc32(typed))
    }
    // Every scanline is a filter byte plus side / 8 zero bytes. Compression's zlib output is raw deflate; the zlib
    // wrapper is a 2-byte header and the Adler-32 of the data, which for all-zero data is (length mod 65521) << 16 | 1.
    let raw = [UInt8](repeating: 0, count: (1 + side / 8) * side)
    var deflated = [UInt8](repeating: 0, count: 1 << 20)
    let count = compression_encode_buffer(&deflated, deflated.count, raw, raw.count, nil, COMPRESSION_ZLIB)
    XCTAssertGreaterThan(count, 0, "the deflated stream fits the buffer")
    let adler = UInt32(raw.count % 65_521) << 16 | 1
    let stream: [UInt8] = [0x78, 0x01] + deflated[0..<count] + bigEndian(adler)

    let header = bigEndian(UInt32(side)) + bigEndian(UInt32(side)) + [1, 0, 0, 0, 0]
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    return Data(signature + chunk("IHDR", header) + chunk("IDAT", stream) + chunk("IEND", []))
  }

  func testHugeDeclaredRasterIsRefusedWithoutDecoding() throws {
    let url = skinDirectory.appendingPathComponent("bomb.png")
    let data = bombPNGData(side: 20_000)
    XCTAssertLessThan(data.count, 1 << 20, "the fixture is a small file")
    try data.write(to: url)
    // The fixture really does declare 400 million pixels (so a nil below means "refused", not "not an image").
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 20_000)
    XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 20_000)
    XCTAssertGreaterThan(20_000 * 20_000, SkinAssetRenderer.maxDeclaredPixelCount)

    XCTAssertNil(SkinAssetRenderer.image(named: "bomb.png", in: skinDirectory, size: CGSize(width: 100, height: 100), scale: 3))
  }

  func testRasterIsDecodedNoLargerThanRequested() throws {
    try writePNG(named: Self.pngName, in: skinDirectory, pixels: 64)
    let image = try XCTUnwrap(SkinAssetRenderer.image(named: Self.pngName, in: skinDirectory, size: CGSize(width: 8, height: 8), scale: 2))
    let (width, height) = pixelSize(image)
    XCTAssertLessThanOrEqual(max(width, height), 16)
    XCTAssertGreaterThan(max(width, height), 0)
  }

  func testRasterIsCappedAtTheMaximumPixelDimension() throws {
    try writePNG(named: Self.pngName, in: skinDirectory, pixels: 64)
    let image = try XCTUnwrap(SkinAssetRenderer.image(named: Self.pngName, in: skinDirectory, size: CGSize(width: 90_000, height: 90_000), scale: 3))
    XCTAssertLessThanOrEqual(CGFloat(max(pixelSize(image).0, pixelSize(image).1)), SkinAssetRenderer.maxPixelDimension)
  }

  func testNonImageFileReturnsNil() throws {
    try Data("not an image".utf8).write(to: skinDirectory.appendingPathComponent("junk.png"))
    XCTAssertNil(SkinAssetRenderer.image(named: "junk.png", in: skinDirectory, size: CGSize(width: 10, height: 10), scale: 1))
  }

  func testCacheHasAByteBudgetAndChargesDecodedBytes() throws {
    XCTAssertEqual(SkinAssetRenderer.cacheTotalCostLimit, SkinAssetRenderer.cacheCostLimit)
    XCTAssertGreaterThan(SkinAssetRenderer.cacheTotalCostLimit, 0)
    try writePNG(named: Self.pngName, in: skinDirectory, pixels: 8)
    let image = try XCTUnwrap(SkinAssetRenderer.image(named: Self.pngName, in: skinDirectory, size: CGSize(width: 8, height: 8), scale: 1))
    let cgImage = try XCTUnwrap(image.cgImage)
    XCTAssertEqual(SkinAssetRenderer.cacheCost(of: image), cgImage.bytesPerRow * cgImage.height)
    XCTAssertGreaterThanOrEqual(SkinAssetRenderer.cacheCost(of: image), 8 * 8 * 4)
  }

  func testClearCacheForgetsDecodedImages() throws {
    try writePNG(named: Self.pngName, in: skinDirectory, pixels: 8)
    let size = CGSize(width: 8, height: 8)
    let first = try XCTUnwrap(SkinAssetRenderer.image(named: Self.pngName, in: skinDirectory, size: size, scale: 1))
    SkinAssetRenderer.clearCache()
    let second = try XCTUnwrap(SkinAssetRenderer.image(named: Self.pngName, in: skinDirectory, size: size, scale: 1))
    XCTAssertFalse(first === second)
  }
}
#endif
