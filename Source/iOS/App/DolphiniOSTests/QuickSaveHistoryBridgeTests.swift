// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class QuickSaveHistoryBridgeTests: XCTestCase {
  func testOutsideRootSnapshotAndLoadAreRefusedWithoutQueueing() {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("GALE01.quick-\(UUID().uuidString).s01").path
    XCTAssertNil(TVEmulationBridge.saveStateSnapshot(toPath: path, expectedGameID: "GALE01",
      expectedSessionIdentifier: 0))
    XCTAssertFalse(TVEmulationBridge.loadState(fromPath: path, expectedGameID: "GALE01",
      expectedSessionIdentifier: 0))
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
  }
  func testStaleIdentityCannotWriteOrQueueAStateOperation() throws {
    let root = try XCTUnwrap(DolphinPaths.stateSavesURL())
    let path = root.appendingPathComponent("GALE01.quick-\(UUID().uuidString).s01").path
    XCTAssertNil(TVEmulationBridge.saveStateSnapshot(toPath: path, expectedGameID: "GALE01",
      expectedSessionIdentifier: 0))
    XCTAssertFalse(TVEmulationBridge.loadState(fromPath: path, expectedGameID: "GALE01",
      expectedSessionIdentifier: 0))
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
  }
}
