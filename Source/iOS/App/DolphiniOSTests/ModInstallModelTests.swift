// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class ModInstallModelTests: XCTestCase {
  private func file(name: String, url: String? = "https://gamebanana.com/dl/1") throws -> GameBananaFile {
    let link = url.map { #", "_sDownloadUrl": "\#($0)""# } ?? ""
    let json = #"{"_idRow": 1, "_sFile": "\#(name)", "_nFilesize": 10\#(link)}"#
    return try JSONDecoder().decode(GameBananaFile.self, from: Data(json.utf8))
  }

  func testRarArchivesAreBlocked() throws {
    XCTAssertNotNil(ModInstallModel.blockedReason(for: try file(name: "pack.RAR")))
  }

  func testFilesWithoutALinkAreBlocked() throws {
    XCTAssertNotNil(ModInstallModel.blockedReason(for: try file(name: "pack.zip", url: nil)))
  }

  func testZipAndBareFilesAreAllowed() throws {
    XCTAssertNil(ModInstallModel.blockedReason(for: try file(name: "pack.zip")))
    XCTAssertNil(ModInstallModel.blockedReason(for: try file(name: "patch.xdelta")))
    XCTAssertNil(ModInstallModel.blockedReason(for: try file(name: "pack.7z")))
  }

  @MainActor
  func testCleaningUpReopenedFilePreservesPatchAlreadyHandedOff() throws {
    let file = try file(name: "patch.xdelta")
    let handler = LiveModInstallHandler(presentPatches: { _, _ in })
    let original = ModInstallModel(file: file, ownedGame: nil, handler: handler)
    let reopened = ModInstallModel(file: file, ownedGame: nil, handler: handler)
    let fm = FileManager.default
    defer {
      try? fm.removeItem(at: original.workDirectory)
      try? fm.removeItem(at: reopened.workDirectory)
    }
    try fm.createDirectory(at: original.workDirectory, withIntermediateDirectories: true)
    try fm.createDirectory(at: reopened.workDirectory, withIntermediateDirectories: true)
    let patch = original.workDirectory.appendingPathComponent(file.fileName)
    let bytes = Data([0xD6, 0xC3, 0xC4, 0x00])
    try bytes.write(to: patch)
    original.presentDiscPatch([patch], suggestedGameID: nil)
    original.cleanUp()

    reopened.cleanUp()

    XCTAssertFalse(fm.fileExists(atPath: reopened.workDirectory.path))
    XCTAssertEqual(try Data(contentsOf: patch), bytes)
  }

  func testRegionWarningOnlyForTheSameTitleInAnotherRegion() {
    XCTAssertNotNil(ModInstallModel.regionWarning(packID: "GALE01", ownedID: "GALP01"))
    XCTAssertNil(ModInstallModel.regionWarning(packID: "GALE01", ownedID: "GALE01"))
    XCTAssertNil(ModInstallModel.regionWarning(packID: "GALE01", ownedID: nil))
    XCTAssertNil(ModInstallModel.regionWarning(packID: "RMC", ownedID: "RMCP01"))
    XCTAssertNil(ModInstallModel.regionWarning(packID: "readme", ownedID: "RMCP01"))
  }
}
