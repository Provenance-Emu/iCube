// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import XCTest
import PVCloudSync
import enum PVLibraryMetadata.LibraryMetadataDocument
import PVSyncRules
@testable import iCube

final class AppDocumentMergersTests: XCTestCase {
  private let identity = LibraryMetadataStore.Identity.game(gameID: "GSRE01", discNumber: 0, revision: 0)!
  private func bytes(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
  private func metadataMerger() throws -> any DocumentMerger {
    try XCTUnwrap(AppDocumentMergers.merger(relativePath: "Profiles/LibraryMetadata/" + identity.fileName, fileType: .gameProfile))
  }

  func testMetadataUnknownPrimitiveTiesUseCanonicalFragmentBytesInBothDirections() throws {
    let local = try bytes(["future": 2, "nullable": NSNull()])
    let remote = try bytes(["future": 9, "nullable": "value"])
    let expected = try LibraryMetadataDocument.merge(local: local, remote: remote, filename: identity.fileName)
    let merger = try metadataMerger()
    XCTAssertEqual(try merger.merge(local: local, remote: remote), expected)
    XCTAssertEqual(try merger.merge(local: remote, remote: local), expected)
    XCTAssertEqual((try JSONSerialization.jsonObject(with: expected) as? [String: Any])?["future"] as? Int, 9)
  }

  func testNonfiniteTimestampStringsLoseToFiniteStampAndPreserveNullsAndUnknownFields() throws {
    for stamp in ["inf", "-inf", "nan", "Infinity"] {
      let key = identity.rawValue + ":title"
      let local = try bytes([key: ["value": "stale", "updatedAt": stamp]])
      let remote = try bytes([key: ["value": NSNull(), "updatedAt": 1, "future": ["nested": NSNull()]], "unknown": NSNull()])
      let result = try metadataMerger().merge(local: local, remote: remote)
      XCTAssertEqual(result, try LibraryMetadataDocument.merge(local: local, remote: remote, filename: identity.fileName))
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
      let record = try XCTUnwrap(object[key] as? [String: Any])
      XCTAssertTrue(record["value"] is NSNull)
      XCTAssertTrue(object["unknown"] is NSNull)
      XCTAssertTrue((record["future"] as? [String: Any])?["nested"] is NSNull)
    }
  }

  func testMetadataFilenameMismatchRejects() throws {
    let other = LibraryMetadataStore.Identity.game(gameID: "GZLE01", discNumber: 0, revision: 0)!
    let remote = try bytes([other.rawValue + ":title": ["value": "other", "updatedAt": 1]])
    XCTAssertThrowsError(try metadataMerger().merge(local: bytes([:]), remote: remote))
  }

  func testOtherProfilesAndLibraryStateKeepGenericMergerSelection() throws {
    for path in ["Profiles/game_profiles.json", "Profiles/LibraryMetadata/not-a-shard.json", "elsewhere/" + identity.fileName] {
      let merger = try XCTUnwrap(AppDocumentMergers.merger(relativePath: path, fileType: .gameProfile))
      XCTAssertTrue(merger is KeyedTimestampDocumentMerger)
      let a = try bytes(["game": ["updatedAt": 1, "value": "a"]])
      let b = try bytes(["game": ["updatedAt": 2, "value": "b"]])
      XCTAssertEqual(try merger.merge(local: a, remote: b), try DocumentMergers.merger(for: .gameProfile)!.merge(local: a, remote: b))
    }
    let stateMerger = try XCTUnwrap(AppDocumentMergers.merger(relativePath: "Profiles/library_state.json", fileType: .libraryState))
    XCTAssertTrue(stateMerger is LibraryStateDocumentMerger)
    let localState = try LibraryStateDocument(games: ["game": .init(launches: ["device": 1])]).encoded()
    let remoteState = try LibraryStateDocument(games: ["game": .init(launches: ["device": 2])]).encoded()
    XCTAssertEqual(try stateMerger.merge(local: localState, remote: remoteState),
                   try DocumentMergers.merger(for: .libraryState)!.merge(local: localState, remote: remoteState))
    XCTAssertNil(AppDocumentMergers.merger(relativePath: "StateSaves/game.s01", fileType: .saveState))
  }
}
