// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// The DiscIO bridge against real files. A file that is not a disc is read by DiscIO as a plain image,
/// which is enough to exercise the conversion plumbing without shipping a game.
final class DiscImageBridgeTests: XCTestCase {
  private var folder: URL!

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("DiscImageBridgeTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: folder)
  }

  private func makeImage(named name: String, megabytes: Int) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try Data((0..<(megabytes << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) }).write(to: url)
    return url
  }

  func test_aFileThatIsNotADiscCannotBeInspected() throws {
    let url = try makeImage(named: "junk.iso", megabytes: 1)
    XCTAssertNil(DiscImageBridge.inspectImage(atPath: url.path))
  }

  func test_aMissingFileCannotBeInspected() {
    XCTAssertNil(DiscImageBridge.inspectImage(atPath: folder.appendingPathComponent("missing.iso").path))
  }

  func test_convertToPlainCopiesTheImageAndReportsProgress() throws {
    let source = try makeImage(named: "source.iso", megabytes: 4)
    let destination = folder.appendingPathComponent("plain.iso")
    var fractions: [Double] = []
    try DiscImageBridge.convertToPlain(from: source.path, to: destination.path, token: DOLDiscConversionToken(),
                                       progress: { fractions.append($0) })
    XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    XCTAssertFalse(fractions.isEmpty)
    XCTAssertEqual(fractions, fractions.sorted())
  }

  func test_aCancelledConversionThrowsAndLeavesNothingBehind() throws {
    let source = try makeImage(named: "source.iso", megabytes: 4)
    let destination = folder.appendingPathComponent("plain.iso")
    let token = DOLDiscConversionToken()
    token.cancel()
    XCTAssertThrowsError(try DiscImageBridge.convertToPlain(from: source.path, to: destination.path, token: token, progress: { _ in }))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
  }

  func test_convertingAMissingImageThrows() {
    XCTAssertThrowsError(try DiscImageBridge.convertToRVZ(
      from: folder.appendingPathComponent("missing.iso").path, to: folder.appendingPathComponent("out.rvz").path,
      token: DOLDiscConversionToken(), progress: { _ in }))
  }
}
