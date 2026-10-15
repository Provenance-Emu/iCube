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

  func testRegionWarningOnlyForTheSameTitleInAnotherRegion() {
    XCTAssertNotNil(ModInstallModel.regionWarning(packID: "GALE01", ownedID: "GALP01"))
    XCTAssertNil(ModInstallModel.regionWarning(packID: "GALE01", ownedID: "GALE01"))
    XCTAssertNil(ModInstallModel.regionWarning(packID: "GALE01", ownedID: nil))
    XCTAssertNil(ModInstallModel.regionWarning(packID: "RMC", ownedID: "RMCP01"))
    XCTAssertNil(ModInstallModel.regionWarning(packID: "readme", ownedID: "RMCP01"))
  }
}
