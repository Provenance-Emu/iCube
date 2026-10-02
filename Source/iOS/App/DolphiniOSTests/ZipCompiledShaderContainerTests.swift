// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class ZipCompiledShaderContainerTests: XCTestCase {
  private typealias Decoder = ZipCompiledShaderContainer.Decoder

  private static let shaderJSON = Data(#"{"passes":[],"parameters":[],"luts":[],"historyCount":3,"languageVersion":"version2_4"}"#.utf8)
  private static let largeEntrySize = 256 << 10
  private var cleanup: [URL] = []

  override func tearDown() {
    cleanup.forEach { try? FileManager.default.removeItem(at: $0) }
    cleanup = []
  }

  /// A path in the temp directory, which is where a `../` entry of a shader extraction folder lands.
  private func escapedFile() -> (name: String, url: URL) {
    let name = "zs-shader-escape-\(UUID().uuidString).txt"
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    cleanup.append(url)
    return (name, url)
  }

  private func archiveFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZipCompiledShaderContainerTests-\(UUID().uuidString).zip")
    try data.write(to: url)
    cleanup.append(url)
    return url
  }

  private func assertInvalidArchive(_ body: () throws -> Decoder, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try body(), file: file, line: line) {
      guard case ZipCompiledShaderContainer.Error.invalidArchive = $0 else { return XCTFail("expected invalidArchive, got \($0)", file: file, line: line) }
    }
  }

  func testDecodesAShaderArchive() throws {
    let archive = TestZipBuilder.build([.init(name: "shader.json", contents: Self.shaderJSON)])
    XCTAssertEqual(try Decoder(data: archive).shader.historyCount, 3)
    XCTAssertEqual(try Decoder(url: try archiveFile(archive)).shader.historyCount, 3)
  }

  /// The archive was written beside its extraction, so an entry named `in.zip` truncated it while minizip was still reading
  /// it. The entry is larger than stdio's read buffer, or minizip would have the whole small archive in memory already.
  func testAnEntryNamedLikeTheArchiveDoesNotCorruptTheExtraction() throws {
    let largeEntry = Data((0..<Self.largeEntrySize).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let archive = TestZipBuilder.build([.init(name: "in.zip", contents: largeEntry), .init(name: "shader.json", contents: Self.shaderJSON)])
    let decoder = try Decoder(data: archive)
    XCTAssertEqual(decoder.shader.historyCount, 3)
    decoder.removeExtractedFiles()
  }

  func testRejectsAnEntryThatEscapesTheExtractionFolder() throws {
    let escaped = escapedFile()
    let archive = TestZipBuilder.build([.init(name: "shader.json", contents: Self.shaderJSON), .init(name: "../\(escaped.name)", contents: Data("x".utf8))])
    assertInvalidArchive { try Decoder(data: archive) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.url.path))
    let file = try archiveFile(archive)
    assertInvalidArchive { try Decoder(url: file) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.url.path))
  }

  func testRejectsASymlinkEntry() throws {
    let archive = TestZipBuilder.build([.init(name: "shader.json", contents: Self.shaderJSON),
                                        .init(name: "lut.png", contents: Data("/etc/hosts".utf8), externalAttributes: TestZipBuilder.unixSymlinkAttributes)])
    assertInvalidArchive { try Decoder(data: archive) }
    let file = try archiveFile(archive)
    assertInvalidArchive { try Decoder(url: file) }
  }
}
