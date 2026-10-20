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

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder)
    try? FileManager.default.removeItem(at: folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + "Recovery"))
  }

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

  private func otherIdentity(_ index: Int) -> LibraryMetadataStore.Identity {
    LibraryMetadataStore.Identity.game(gameID: "CACHE\(index)", discNumber: 0, revision: 0)!
  }

  func testFullRecordRetentionIsBoundedAfterManyMaximumCovers() throws {
    let budget = 2 * 1024 * 1024
    let store = try LibraryMetadataStore(directoryURL: folder, cacheByteLimit: budget, cacheCountLimit: 3)
    for index in 0..<40 {
      _ = try store.commit(.init(title: "Game \(index)", coverData: Data(repeating: UInt8(index), count: 256 * 1024)), baseline: .init(), for: otherIdentity(index))
      let stats = try store.cacheStatistics()
      XCTAssertLessThanOrEqual(stats.recordCount, 3)
      XCTAssertLessThanOrEqual(stats.retainedBytes, budget)
    }
    XCTAssertEqual(try store.draft(for: otherIdentity(0)).coverData, Data(repeating: 0, count: 256 * 1024))
  }

  func testSummaryLookupsRetainNoDecodedCovers() throws {
    let writer = try LibraryMetadataStore(directoryURL: folder)
    for index in 0..<20 {
      _ = try writer.commit(.init(title: "Game \(index)", coverData: Data(repeating: 7, count: 256 * 1024), tags: ["Puzzle"]), baseline: .init(), for: otherIdentity(index))
    }
    let reader = try LibraryMetadataStore(directoryURL: folder, cacheByteLimit: 1024 * 1024, cacheCountLimit: 2)
    for index in 0..<20 {
      let summary = try reader.summary(for: otherIdentity(index))
      XCTAssertEqual(summary.title, "Game \(index)")
      XCTAssertEqual(summary.tags, ["Puzzle"])
    }
    let stats = try reader.cacheStatistics()
    XCTAssertEqual(stats.decodedCoverBytes, 0)
    XCTAssertLessThanOrEqual(stats.recordCount, 2)
    XCTAssertLessThanOrEqual(stats.retainedBytes, 1024 * 1024)
  }

  func testEvictedPurgedShardRecoversFullUnknownRecordsAndUneditedCover() throws {
    let future: [String: Any] = ["future": ["opaque": [1, 2]], recordKey("title"): ["updatedAt": 1, "value": "Keep", "futureOption": true], recordKey("cover"): ["updatedAt": 1, "value": Data([1, 2, 3]).base64EncodedString()]]
    try JSONSerialization.data(withJSONObject: future).write(to: file)
    let store = try LibraryMetadataStore(directoryURL: folder, cacheCountLimit: 1)
    let saved = try store.draft(for: identity)
    _ = try store.draft(for: otherIdentity(1)) // Evicts and snapshots full validated bytes.
    try FileManager.default.removeItem(at: file)
    var changed = saved; changed.tags = ["New"]
    let result = try store.commit(changed, baseline: saved, for: identity)
    XCTAssertEqual(result.coverData, Data([1, 2, 3]))
    XCTAssertEqual(result.title, "Keep")
    XCTAssertEqual(try object()["future"] as? NSDictionary, future["future"] as? NSDictionary)
    XCTAssertEqual((try object()[recordKey("title")] as? [String: Any])?["futureOption"] as? Bool, true)
  }

  func testEvictedMalformedShardThrowsThenServesRecoveryWithoutReplacingCorruption() throws {
    let store = try LibraryMetadataStore(directoryURL: folder, cacheCountLimit: 1)
    let saved = try store.commit(.init(title: "Keep", coverData: Data([4])), baseline: .init(), for: identity)
    _ = try store.draft(for: otherIdentity(1))
    let corrupt = Data("broken".utf8); try corrupt.write(to: file)
    XCTAssertThrowsError(try store.draft(for: identity))
    XCTAssertEqual(try store.draft(for: identity), saved)
    XCTAssertThrowsError(try store.commit(.init(title: "New"), baseline: saved, for: identity))
    XCTAssertEqual(try Data(contentsOf: file), corrupt)
  }

  func testRecoveryFailurePrecedesPrimaryCommitAndRetainsAuthoritativeMemory() throws {
    let store = try LibraryMetadataStore(directoryURL: folder, cacheCountLimit: 1, writeRecovery: { _, _ in throw NSError(domain: "recovery", code: 1) })
    let saved = try store.commit(.init(title: "Keep"), baseline: .init(), for: identity)
    let second = otherIdentity(1)
    XCTAssertThrowsError(try store.commit(.init(title: "Must not save"), baseline: .init(), for: second))
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(second.fileName).path))
    try FileManager.default.removeItem(at: file)
    XCTAssertEqual(try store.draft(for: identity), saved)
    XCTAssertEqual(try store.cacheStatistics().recordCount, 1)
  }

  func testPrimaryWriteFailureAfterSnapshotPreflightKeepsPreviousCacheAndBytes() throws {
    var fail = false
    let store = try LibraryMetadataStore(directoryURL: folder, write: { bytes, url in
      if fail { throw NSError(domain: "primary", code: 1) }
      try bytes.write(to: url, options: .atomic)
    }, cacheCountLimit: 1)
    let saved = try store.commit(.init(title: "Keep"), baseline: .init(), for: identity)
    let before = try Data(contentsOf: file)
    fail = true
    XCTAssertThrowsError(try store.commit(.init(title: "Fail"), baseline: .init(), for: otherIdentity(1)))
    XCTAssertEqual(try store.draft(for: identity), saved)
    XCTAssertEqual(try Data(contentsOf: file), before)
    XCTAssertEqual(try store.cacheStatistics().recordCount, 1)
    XCTAssertEqual(try store.summary(for: identity).title, saved.title)
  }

  func testMissingBothCopiesOfKnownEvictedShardReportsUnavailableInsteadOfClear() throws {
    let recovery = folder.appendingPathComponent("recovery")
    let store = try LibraryMetadataStore(directoryURL: folder, recoveryDirectoryURL: recovery, cacheCountLimit: 1)
    _ = try store.commit(.init(title: "Keep"), baseline: .init(), for: identity)
    _ = try store.draft(for: otherIdentity(1))
    try FileManager.default.removeItem(at: file)
    try FileManager.default.removeItem(at: recovery.appendingPathComponent(identity.fileName))
    XCTAssertThrowsError(try store.draft(for: identity))
    XCTAssertThrowsError(try store.commit(.init(tags: ["New"]), baseline: .init(), for: identity))
    XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
  }

  func testRecoverySurvivesNewStoreAndCanceledDraftDoesNotLeakIntoSnapshot() throws {
    let store = try LibraryMetadataStore(directoryURL: folder, cacheCountLimit: 1)
    let saved = try store.commit(.init(title: "Keep", coverData: Data([3])), baseline: .init(), for: identity)
    var canceled = try store.draft(for: identity); canceled.title = "Canceled"; canceled.coverData = Data([9])
    _ = try store.draft(for: otherIdentity(1))
    try FileManager.default.removeItem(at: file)
    let reopened = try LibraryMetadataStore(directoryURL: folder)
    XCTAssertEqual(try reopened.draft(for: identity), saved)
    XCTAssertEqual(canceled.title, "Canceled")
  }

  func testRecentlyUsedRecordStaysResidentWhenRecoveryForItWouldFail() throws {
    let store = try LibraryMetadataStore(directoryURL: folder, cacheCountLimit: 2, writeRecovery: { bytes, url in
      if url.lastPathComponent == self.identity.fileName { throw NSError(domain: "wrong-victim", code: 1) }
      try bytes.write(to: url, options: .atomic)
    })
    _ = try store.commit(.init(title: "Keep"), baseline: .init(), for: identity)
    _ = try store.commit(.init(title: "Older"), baseline: .init(), for: otherIdentity(1))
    _ = try store.summary(for: identity)
    XCTAssertNoThrow(try store.draft(for: otherIdentity(2)))
  }

  func testOlderStoreEvictionCannotRollBackNewerPrimaryOrRecoveryTombstone() throws {
    let lock = NSRecursiveLock()
    let gate: LibraryMetadataStore.FileAccess = { body in lock.lock(); defer { lock.unlock() }; try body() }
    let old = try LibraryMetadataStore(directoryURL: folder, withFileAccess: gate, cacheCountLimit: 1)
    let before = try old.commit(.init(title: "Old", coverData: Data([1])), baseline: .init(), for: identity, at: Date(timeIntervalSinceReferenceDate: 1))
    let fresh = try LibraryMetadataStore(directoryURL: folder, withFileAccess: gate, cacheCountLimit: 1)
    let latest = try fresh.commit(.init(title: "New"), baseline: before, for: identity, at: Date(timeIntervalSinceReferenceDate: 2))
    _ = try fresh.draft(for: otherIdentity(1)) // Snapshot newer title and cover clear.
    try FileManager.default.removeItem(at: file)
    _ = try old.draft(for: otherIdentity(2)) // Old full record must not replace newer snapshot.
    XCTAssertEqual(try LibraryMetadataStore(directoryURL: folder).draft(for: identity), latest)

    // Also prefer a newer primary when it has never reached the recovery path.
    let newer = try LibraryMetadataStore(directoryURL: folder, withFileAccess: gate)
    _ = try newer.commit(.init(title: "Newest", tags: ["Added"]), baseline: latest, for: identity, at: Date(timeIntervalSinceReferenceDate: 3))
    _ = try old.draft(for: identity)
    _ = try newer.commit(.init(title: "Primary latest", tags: ["Added"]), baseline: .init(title: "Newest", tags: ["Added"]), for: identity, at: Date(timeIntervalSinceReferenceDate: 4))
    _ = try old.draft(for: otherIdentity(3))
    try FileManager.default.removeItem(at: file)
    XCTAssertEqual(try LibraryMetadataStore(directoryURL: folder).draft(for: identity).title, "Primary latest")
  }

  func testSummaryValidationRejectsMalformedCoverPaddingAndExactOversize() throws {
    let invalid = ["=AAA", "AA=A", "A===", "AAAA=", "AA\n=", "!!!!", Data(repeating: 1, count: 256 * 1024 + 1).base64EncodedString()]
    for encoded in invalid {
      try JSONSerialization.data(withJSONObject: [recordKey("cover"): ["updatedAt": 1, "value": encoded]]).write(to: file)
      XCTAssertThrowsError(try LibraryMetadataStore(directoryURL: folder).summary(for: identity))
    }
    for data in [Data(), Data([1]), Data([1, 2]), Data([1, 2, 3]), Data(repeating: 5, count: 256 * 1024)] {
      try JSONSerialization.data(withJSONObject: [recordKey("cover"): ["updatedAt": 1, "value": data.base64EncodedString()]]).write(to: file)
      let store = try LibraryMetadataStore(directoryURL: folder)
      XCTAssertNoThrow(try store.summary(for: identity))
      XCTAssertEqual(try store.cacheStatistics().decodedCoverBytes, 0)
      XCTAssertEqual(try store.draft(for: identity).coverData, data)
    }
  }

  func testSummarySurvivesFullEvictionAndRepeatedSortLookupsPerformNoFileIO() throws {
    let recovery = folder.appendingPathComponent("recovery")
    var failSnapshot = false
    let store = try LibraryMetadataStore(directoryURL: folder, recoveryDirectoryURL: recovery, cacheCountLimit: 1, writeRecovery: { bytes, url in
      if failSnapshot { throw NSError(domain: "unexpected-sort-write", code: 1) }
      try bytes.write(to: url, options: .atomic)
    })
    _ = try store.commit(.init(title: "Cached title", coverData: Data(repeating: 1, count: 256 * 1024), tags: ["Cached tag"]), baseline: .init(), for: identity)
    _ = try store.commit(.init(title: "Other"), baseline: .init(), for: otherIdentity(1))
    try FileManager.default.removeItem(at: file)
    try FileManager.default.removeItem(at: recovery.appendingPathComponent(identity.fileName))
    failSnapshot = true
    for _ in 0..<100 {
      let summary = try store.summary(for: identity)
      XCTAssertEqual(summary.title, "Cached title")
      XCTAssertEqual(summary.tags, ["Cached tag"])
    }
    // Full-record reads would hit the missing known-shard guard; projection
    // lookups above can succeed only from the independent lightweight cache.
    XCTAssertThrowsError(try store.draft(for: identity))
    XCTAssertEqual(try store.cacheStatistics().recordCount, 1)
  }

  func testSummaryReloadRefreshesEvictedRecordAndPreservesMalformedOrMissingProjection() throws {
    let recovery = folder.appendingPathComponent("recovery")
    let store = try LibraryMetadataStore(directoryURL: folder, recoveryDirectoryURL: recovery, cacheCountLimit: 1)
    let saved = try store.commit(.init(title: "Old", tags: ["Old tag"]), baseline: .init(), for: identity)
    _ = try store.draft(for: otherIdentity(1))
    let writer = try LibraryMetadataStore(directoryURL: folder)
    _ = try writer.commit(.init(title: "New", tags: ["New tag"]), baseline: saved, for: identity)
    XCTAssertEqual(try store.summary(for: identity).title, "Old")
    try store.reload()
    XCTAssertEqual(try store.summary(for: identity).title, "New")
    _ = try store.draft(for: otherIdentity(2))
    try Data("malformed".utf8).write(to: file)
    try store.reload()
    XCTAssertThrowsError(try store.summary(for: identity))
    XCTAssertEqual(try store.summary(for: identity).tags, ["New tag"])
    _ = try store.draft(for: otherIdentity(3))
    try FileManager.default.removeItem(at: file)
    try FileManager.default.removeItem(at: recovery.appendingPathComponent(identity.fileName))
    try store.reload()
    XCTAssertThrowsError(try store.summary(for: identity))
    XCTAssertEqual(try store.summary(for: identity).title, "New")
  }

  func testSummaryByteAndCountBudgetsBoundLightweightProjectionRetention() throws {
    let store = try LibraryMetadataStore(directoryURL: folder, cacheCountLimit: 1, summaryByteLimit: 2048, summaryCountLimit: 2)
    for index in 0..<20 {
      _ = try store.commit(.init(title: String(repeating: "x", count: 200), tags: ["Tag"]), baseline: .init(), for: otherIdentity(index))
      let stats = try store.cacheStatistics()
      XCTAssertLessThanOrEqual(stats.summaryCount, 2)
      XCTAssertLessThanOrEqual(stats.summaryBytes, 2048)
      XCTAssertLessThanOrEqual(stats.recordCount, 1)
    }
  }

}
