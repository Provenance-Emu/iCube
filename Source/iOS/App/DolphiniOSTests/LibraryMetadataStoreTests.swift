// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import XCTest
@testable import iCube

final class LibraryMetadataStoreTests: XCTestCase {
  private var folder: URL!
  private var file: URL!
  private let identity = LibraryMetadataStore.Identity.game(gameID: "GSRE01", discNumber: 0, revision: 0)!

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    file = folder.appendingPathComponent(identity.fileName)
  }

  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

  private func object() throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
  }

  private func recordKey(_ field: String) -> String { identity.rawValue + ":" + field }

  func testTitleCoverTagsCommitAndReopenWithNormalizedValues() throws {
    let store = try LibraryMetadataStore(directoryURL: folder)
    let baseline = try store.draft(for: identity)
    let changed = LibraryMetadataStore.Draft(title: "  My Game \n", coverData: Data([1, 2, 3]), tags: [" RPG ", "rpg", "Co-op", ""])
    let saved = try store.commit(changed, baseline: baseline, for: identity)
    XCTAssertEqual(saved.title, "My Game")
    XCTAssertEqual(saved.tags, ["RPG", "Co-op"])
    let reopened = try LibraryMetadataStore(directoryURL: folder)
    XCTAssertEqual(try reopened.draft(for: identity), saved)
    XCTAssertEqual(saved.coverData, Data([1, 2, 3]))
  }

  func testUncommittedDraftHasNoSideEffects() throws {
    let store = try LibraryMetadataStore(directoryURL: folder)
    var draft = try store.draft(for: identity)
    draft.title = "Canceled edit"
    XCTAssertNil(try store.draft(for: identity).title)
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  func testOnlyChangedFieldsOverwriteConcurrentDiskEdits() throws {
    let a = try LibraryMetadataStore(directoryURL: folder)
    let b = try LibraryMetadataStore(directoryURL: folder)
    let baseline = try a.draft(for: identity)
    var first = baseline; first.tags = ["Remote tag"]
    _ = try b.commit(first, baseline: baseline, for: identity)
    var second = baseline; second.title = "Local title"
    let merged = try a.commit(second, baseline: baseline, for: identity)
    XCTAssertEqual(merged.title, "Local title")
    XCTAssertEqual(merged.tags, ["Remote tag"])
    XCTAssertEqual(try LibraryMetadataStore(directoryURL: folder).draft(for: identity), merged)
  }

  func testClearWritesTimestampedNullTombstonesAndClockRollbackCannotResurrect() throws {
    let store = try LibraryMetadataStore(directoryURL: folder)
    let baseline = try store.draft(for: identity)
    let initial = try store.commit(.init(title: "Old", coverData: Data([5]), tags: ["Old"]), baseline: baseline, for: identity, at: Date(timeIntervalSinceReferenceDate: 100))
    _ = try store.commit(.init(), baseline: initial, for: identity, at: Date(timeIntervalSinceReferenceDate: 1))
    let json = try object()
    for field in ["title", "cover", "tags"] {
      let record = try XCTUnwrap(json[recordKey(field)] as? [String: Any])
      XCTAssertTrue(record["value"] is NSNull)
      XCTAssertGreaterThan(try XCTUnwrap(record["updatedAt"] as? Double), 100)
    }
    XCTAssertEqual(try LibraryMetadataStore(directoryURL: folder).draft(for: identity), .init())
  }

  func testInvalidEditsPreservePreviousFileAndMemory() throws {
    let store = try LibraryMetadataStore(directoryURL: folder)
    let saved = try store.commit(.init(title: "Keep"), baseline: .init(), for: identity)
    let before = try Data(contentsOf: file)
    for invalid in [
      LibraryMetadataStore.Draft(title: String(repeating: "x", count: 201)),
      .init(coverData: Data(repeating: 0, count: 256 * 1024 + 1)),
      .init(tags: (0..<33).map { "Tag\($0)" }),
      .init(tags: [String(repeating: "x", count: 41)])
    ] {
      XCTAssertThrowsError(try store.commit(invalid, baseline: saved, for: identity))
      XCTAssertEqual(try Data(contentsOf: file), before)
      XCTAssertEqual(try store.draft(for: identity), saved)
    }
  }

  func testWriteFailurePreservesPriorRecordAndSurfacesError() throws {
    let initial = try LibraryMetadataStore(directoryURL: folder)
    let saved = try initial.commit(.init(title: "Keep"), baseline: .init(), for: identity)
    let before = try Data(contentsOf: file)
    let failing = try LibraryMetadataStore(directoryURL: folder, write: { _, _ in throw NSError(domain: "write", code: 1) })
    XCTAssertThrowsError(try failing.commit(.init(title: "Lost"), baseline: saved, for: identity))
    XCTAssertEqual(try Data(contentsOf: file), before)
    XCTAssertEqual(try failing.draft(for: identity), saved)
  }

  func testCorruptReloadAndCommitPreserveMemoryAndCorruptBytes() throws {
    let store = try LibraryMetadataStore(directoryURL: folder)
    let saved = try store.commit(.init(title: "Keep"), baseline: .init(), for: identity)
    let corrupt = Data("not json".utf8); try corrupt.write(to: file)
    try store.reload()
    XCTAssertThrowsError(try store.draft(for: identity))
    XCTAssertEqual(try store.draft(for: identity), saved)
    XCTAssertThrowsError(try store.commit(.init(title: "New"), baseline: saved, for: identity))
    XCTAssertEqual(try Data(contentsOf: file), corrupt)
  }

  func testUnknownRootRecordsAndKnownRecordFieldsSurviveSave() throws {
    let unknown: [String: Any] = ["future": ["updatedAt": 99, "v2": ["a", "b"]], recordKey("title"): ["updatedAt": 1, "value": "Before", "futureOption": true]]
    try JSONSerialization.data(withJSONObject: unknown).write(to: file)
    let store = try LibraryMetadataStore(directoryURL: folder)
    let baseline = try store.draft(for: identity)
    _ = try store.commit(.init(title: "After"), baseline: baseline, for: identity)
    let json = try object()
    XCTAssertEqual((json["future"] as? NSDictionary), unknown["future"] as? NSDictionary)
    XCTAssertEqual((json[recordKey("title")] as? [String: Any])?["futureOption"] as? Bool, true)
  }

  func testDiscRevisionAndContentHashIdentitiesDoNotAlias() throws {
    XCTAssertNil(LibraryMetadataStore.Identity.game(gameID: "", discNumber: 0, revision: 0))
    XCTAssertNil(LibraryMetadataStore.Identity.game(gameID: "G", discNumber: -1, revision: 0))
    XCTAssertNil(LibraryMetadataStore.Identity.contentHash("same-filename.iso"))
    let ids = [identity,
      LibraryMetadataStore.Identity.game(gameID: "GSRE01", discNumber: 1, revision: 0)!,
      LibraryMetadataStore.Identity.game(gameID: "GSRE01", discNumber: 0, revision: 1)!,
      LibraryMetadataStore.Identity.contentHash(String(repeating: "a", count: 64))!,
      LibraryMetadataStore.Identity.contentHash(String(repeating: "b", count: 64))!]
    XCTAssertEqual(Set(ids).count, 5)
    let store = try LibraryMetadataStore(directoryURL: folder)
    _ = try store.commit(.init(title: "First only"), baseline: .init(), for: identity)
    for other in ids.dropFirst() { XCTAssertNil(try store.draft(for: other).title) }
  }

  func testMalformedKnownRecordReloadKeepsPreviousValidProjection() throws {
    let store = try LibraryMetadataStore(directoryURL: folder)
    let saved = try store.commit(.init(title: "Keep"), baseline: .init(), for: identity)
    let malformed = try JSONSerialization.data(withJSONObject: [recordKey("title"): ["updatedAt": 3, "value": 42]])
    try malformed.write(to: file)
    try store.reload()
    XCTAssertThrowsError(try store.draft(for: identity))
    XCTAssertEqual(try store.draft(for: identity), saved)
    XCTAssertThrowsError(try store.commit(.init(title: "New"), baseline: saved, for: identity))
    XCTAssertEqual(try Data(contentsOf: file), malformed)
  }

  func testNoOpDraftDoesNotStampOrRewriteAnyRecord() throws {
    let store = try LibraryMetadataStore(directoryURL: folder)
    let saved = try store.commit(.init(title: "Keep", tags: ["Puzzle"]), baseline: .init(), for: identity)
    let bytes = try Data(contentsOf: file)
    _ = try store.commit(saved, baseline: saved, for: identity, at: Date(timeIntervalSinceReferenceDate: 999999999))
    XCTAssertEqual(try Data(contentsOf: file), bytes)
  }

  func testAllMaximumFieldValuesRoundTripAndBlankTitleClearsOnlyTitle() throws {
    let store = try LibraryMetadataStore(directoryURL: folder)
    let maximum = LibraryMetadataStore.Draft(title: String(repeating: "x", count: 200), coverData: Data(repeating: 7, count: 256 * 1024), tags: (0..<32).map { String(repeating: "x", count: 38) + String(format: "%02d", $0) })
    let saved = try store.commit(maximum, baseline: .init(), for: identity)
    XCTAssertEqual(saved, maximum)
    var clearTitle = saved; clearTitle.title = "  \n "
    let cleared = try store.commit(clearTitle, baseline: saved, for: identity)
    XCTAssertNil(cleared.title)
    XCTAssertEqual(cleared.tags, maximum.tags)
    XCTAssertEqual(cleared.coverData, maximum.coverData)
  }


  func testEachGameWritesOnlyItsOwnShard() throws {
    let store = try LibraryMetadataStore(directoryURL: folder)
    let second = LibraryMetadataStore.Identity.game(gameID: "OTHER", discNumber: 0, revision: 0)!
    _ = try store.commit(.init(title: "First"), baseline: .init(), for: identity)
    let firstBytes = try Data(contentsOf: file)
    _ = try store.commit(.init(title: "Second"), baseline: .init(), for: second)
    XCTAssertEqual(try Data(contentsOf: file), firstBytes, "Editing another game must not rewrite this game's cover/title shard")
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    XCTAssertEqual(files.filter { $0.pathExtension == "json" }.count, 2)
  }


  func testCloudValidationChecksBoundsTypesAndShardIdentity() throws {
    let valid = try JSONSerialization.data(withJSONObject: [recordKey("title"): ["updatedAt": 42.5, "value": "Cloud title"]])
    XCTAssertNoThrow(try LibraryMetadataStore.validateDocument(data: valid, filename: identity.fileName))
    let other = LibraryMetadataStore.Identity.game(gameID: "OTHER", discNumber: 0, revision: 0)!
    XCTAssertThrowsError(try LibraryMetadataStore.validateDocument(data: valid, filename: other.fileName))
    let malformed = try JSONSerialization.data(withJSONObject: [recordKey("cover"): ["updatedAt": 1, "value": "not-base64!"]])
    XCTAssertThrowsError(try LibraryMetadataStore.validateDocument(data: malformed, filename: identity.fileName))
    let oversizedCover = try JSONSerialization.data(withJSONObject: [recordKey("cover"): ["updatedAt": 1, "value": Data(repeating: 1, count: 256 * 1024 + 1).base64EncodedString()]])
    XCTAssertThrowsError(try LibraryMetadataStore.validateDocument(data: oversizedCover))
    XCTAssertThrowsError(try LibraryMetadataStore.validateDocument(data: Data(repeating: 32, count: 1024 * 1024 + 1)))
    XCTAssertThrowsError(try LibraryMetadataStore.validateDocument(data: Data("[]".utf8)))
    XCTAssertTrue(LibraryMetadataStore.isValidShardFilename(identity.fileName))
    for invalid in [identity.fileName.uppercased(), "../" + identity.fileName, "folder/" + identity.fileName, "metadata.json", identity.fileName + ".tmp"] {
      XCTAssertFalse(LibraryMetadataStore.isValidShardFilename(invalid))
    }
  }

  func testMissingShardDuringSessionPreservesUneditedFieldsOnNextCommit() throws {
    let store = try LibraryMetadataStore(directoryURL: folder)
    let saved = try store.commit(.init(title: "Keep", coverData: Data([1, 2, 3])), baseline: .init(), for: identity)
    try FileManager.default.removeItem(at: file)
    var changed = saved; changed.tags = ["New"]
    let result = try store.commit(changed, baseline: saved, for: identity)
    XCTAssertEqual(result.title, "Keep")
    XCTAssertEqual(result.coverData, Data([1, 2, 3]))
    XCTAssertEqual(result.tags, ["New"])
  }


  func testDiscSerialCaseAndWhitespaceDoNotSplitTheSameGame() {
    let normalized = LibraryMetadataStore.Identity.game(gameID: " gsre01 ", discNumber: 0, revision: 0)
    XCTAssertEqual(normalized, identity)
    XCTAssertEqual(normalized?.fileName, identity.fileName)
  }


  func testRepeatedDraftReadsShareTheImmutableCoverBufferUntilMetadataChanges() throws {
    let store = try LibraryMetadataStore(directoryURL: folder)
    _ = try store.commit(.init(title: "Keep", coverData: Data(repeating: 7, count: 256 * 1024)), baseline: .init(), for: identity)
    let first = try XCTUnwrap(store.draft(for: identity).coverData)
    let second = try XCTUnwrap(store.draft(for: identity).coverData)
    // Keep both values alive: re-decoding base64 for each title/sort lookup
    // allocates a distinct 256 KiB buffer. Cached immutable Data shares storage.
    first.withUnsafeBytes { firstBytes in
      second.withUnsafeBytes { secondBytes in
        XCTAssertEqual(firstBytes.baseAddress, secondBytes.baseAddress)
      }
    }
    XCTAssertEqual(first.count, 256 * 1024)
  }


  func testReloadInvalidatesCachedProjectionAfterAnotherStoreCommits() throws {
    let first = try LibraryMetadataStore(directoryURL: folder)
    let old = try first.commit(.init(title: "Old", coverData: Data([1]), tags: ["Old"]), baseline: .init(), for: identity)
    _ = try first.draft(for: identity)
    let second = try LibraryMetadataStore(directoryURL: folder)
    let fresh = try second.commit(.init(title: "New", coverData: Data([2]), tags: ["New"]), baseline: old, for: identity)
    XCTAssertEqual(try first.draft(for: identity), old)
    try first.reload()
    XCTAssertEqual(try first.draft(for: identity), fresh)
  }

}
