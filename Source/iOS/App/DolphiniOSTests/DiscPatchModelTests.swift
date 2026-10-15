// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// The sheet's rule that the original is only replaced by a patch that can check itself against it.
@MainActor
final class DiscPatchModelTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("DiscPatchModelTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func makeModel(patch bytes: [UInt8], named name: String) throws -> DiscPatchModel {
    let url = root.appendingPathComponent(name)
    try Data(bytes).write(to: url)
    let directories = DiscPatchDirectories(user: root.appendingPathComponent("User"), software: root.appendingPathComponent("Software"))
    return DiscPatchModel(patchURLs: [url], suggestedGameID: nil, directories: directories)
  }

  /// A BPS patch for an empty disc: the smallest patch that carries source and target checksums.
  private let emptyBPS: [UInt8] = [0x42, 0x50, 0x53, 0x31, 0x80, 0x80, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x93, 0x1F, 0xD8, 0x5E]
  private let emptyIPS: [UInt8] = Array("PATCHEOF".utf8)

  func testAPatchWithChecksumsMayReplaceTheOriginal() throws {
    let model = try makeModel(patch: emptyBPS, named: "checked.bps")
    XCTAssertNil(model.patchProblem)
    XCTAssertTrue(model.canReplaceOriginal)
  }

  func testAPatchWithoutChecksumsCannotReplaceTheOriginal() throws {
    let model = try makeModel(patch: emptyIPS, named: "blind.ips")
    XCTAssertNil(model.patchProblem)
    XCTAssertFalse(model.canReplaceOriginal)
  }

  func testChoosingAPatchWithoutChecksumsLeavesReplaceMode() throws {
    let model = try makeModel(patch: emptyBPS, named: "checked.bps")
    model.mode = .replaceOriginal
    let blind = root.appendingPathComponent("blind.ips")
    try Data(emptyIPS).write(to: blind)

    model.choosePatch(blind)

    XCTAssertEqual(model.mode, .saveCopy)
  }
}
