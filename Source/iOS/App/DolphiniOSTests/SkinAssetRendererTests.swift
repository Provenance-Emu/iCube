// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
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
}
#endif
