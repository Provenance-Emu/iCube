// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class QuickSaveHistoryPersistenceTests: XCTestCase {
  private var root: URL!
  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

  @discardableResult private func existing(_ age: Int, kept: Bool = false, name: String? = nil,
                                            metadataGame: String = "GALE01") throws -> URL {
    let url = root.appendingPathComponent(name ?? "GALE01.quick-\(UUID().uuidString).s01")
    try Data("state".utf8).write(to: url)
    XCTAssertTrue(SaveStateMetadataStore.write(SaveStateMetadata(title: "Existing", gameID: metadataGame,
      savedAt: Date(timeIntervalSince1970: Double(age)), isQuickSave: true, isKept: kept), forStateFile: url))
    try Data("png".utf8).write(to: url.appendingPathExtension("png"))
    return url
  }

  private func store(current: @escaping () -> Bool = { true }, writer: ((URL) -> SaveStateCompletedSnapshot?)? = nil,
                     metadata: @escaping (SaveStateMetadata, URL) -> Bool = { SaveStateMetadataStore.write($0, forStateFile: $1) },
                     remove: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> QuickSaveHistoryPersistence {
    QuickSaveHistoryPersistence(root: root, writeSnapshot: writer ?? { url in
      try? Data("new".utf8).write(to: url)
      return SaveStateCompletedSnapshot(filePath: url.path, gameID: "GALE01", playTimeSeconds: 42,
                                        savedAt: Date(timeIntervalSince1970: 100), sessionIdentifier: 7)
    }, isCurrentSession: current, writeMetadata: metadata, removeFile: remove)
  }

  func testSuccessfulSaveCommitsUniqueStateAndMatchingMetadata() throws {
    let first = try XCTUnwrap(store().save(gameID: "GALE01", sessionIdentifier: 7).snapshot)
    let second = try XCTUnwrap(store().save(gameID: "GALE01", sessionIdentifier: 7).snapshot)
    XCTAssertNotEqual(first.filePath, second.filePath)
    let url = URL(fileURLWithPath: first.filePath)
    XCTAssertEqual(QuickSaveHistoryPolicy.historyGameID(for: url), "GALE01")
    XCTAssertEqual(SaveStateMetadataStore.read(forStateFile: url)?.isQuickSave, true)
    XCTAssertEqual(SaveStateMetadataStore.read(forStateFile: url)?.playTimeSeconds, 42)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
  }
  func testWriteFailureRetainsEveryPreviousSave() throws {
    let old = try (0..<11).map { try existing($0) }
    XCTAssertNil(store(writer: { _ in nil }).save(gameID: "GALE01", sessionIdentifier: 7).snapshot)
    XCTAssertTrue(old.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
  }
  func testMetadataFailureDoesNotPruneAndRemovesOnlyNewFile() throws {
    let old = try (0..<11).map { try existing($0) }
    XCTAssertNil(store(metadata: { _, _ in false }).save(gameID: "GALE01", sessionIdentifier: 7).snapshot)
    XCTAssertTrue(old.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count, 33)
  }
  func testPruningRunsOnlyAfterMetadataHasCommitted() throws {
    _ = try (0..<11).map { try existing($0) }
    var committed = false
    let result = store(metadata: { meta, url in
      committed = SaveStateMetadataStore.write(meta, forStateFile: url)
      return committed
    }, remove: { url in
      XCTAssertTrue(committed)
      try FileManager.default.removeItem(at: url)
    }).save(gameID: "GALE01", sessionIdentifier: 7)
    XCTAssertNotNil(result.snapshot)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { QuickSaveHistoryPolicy.historyGameID(for: $0) != nil }.count, 10)
  }
  func testKeptClassicAutoForeignAndMalformedFilesNeverRotate() throws {
    let protected = try [existing(-10, kept: true), existing(-9, name: "GALE01.s01"),
      existing(-8, name: "GALE01.auto"), existing(-7, metadataGame: "RSBE01"),
      existing(-6, name: "GALE01.quick-not-a-uuid.s01"), existing(-5, name: "GALE01.s99")]
    _ = try (0..<11).map { try existing($0) }
    XCTAssertNotNil(store().save(gameID: "GALE01", sessionIdentifier: 7).snapshot)
    XCTAssertTrue(protected.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
  }
  func testPruningCleansStateMetadataAndThumbnailTogether() throws {
    let oldest = try existing(-1)
    _ = try (0..<10).map { try existing($0) }
    XCTAssertNotNil(store().save(gameID: "GALE01", sessionIdentifier: 7).snapshot)
    for url in [oldest, oldest.appendingPathExtension("json"), oldest.appendingPathExtension("png")] {
      XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
  }
  func testFreshSaveSurvivesClockRollbackWhileRetentionStaysTen() throws {
    _ = try (101..<112).map { try existing($0) }
    let saved = try XCTUnwrap(store().save(gameID: "GALE01", sessionIdentifier: 7).snapshot)
    XCTAssertTrue(FileManager.default.fileExists(atPath: saved.filePath))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { QuickSaveHistoryPolicy.historyGameID(for: $0) != nil }.count, 10)
  }
  func testSessionChangeDuringMetadataCommitNeverPrunes() throws {
    let old = try (0..<11).map { try existing($0) }
    var current = true
    let result = store(current: { current }, metadata: { metadata, url in
      let written = SaveStateMetadataStore.write(metadata, forStateFile: url)
      current = false
      return written
    }).save(gameID: "GALE01", sessionIdentifier: 7)
    XCTAssertTrue(result.cancelled)
    XCTAssertTrue(old.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
  }
  func testCleanupFailureStillReportsCommittedSaveWithWarning() throws {
    _ = try (0..<11).map { try existing($0) }
    let result = store(remove: { _ in throw CocoaError(.fileWriteNoPermission) }).save(gameID: "GALE01", sessionIdentifier: 7)
    XCTAssertNotNil(result.snapshot)
    XCTAssertTrue(result.cleanupFailed)
  }
  func testChangedSessionBeforeWriteDoesNotInvokeWriterOrPrune() throws {
    let old = try existing(1)
    var called = false
    let result = store(current: { false }, writer: { _ in called = true; return nil }).save(gameID: "GALE01", sessionIdentifier: 7)
    XCTAssertTrue(result.cancelled)
    XCTAssertFalse(called)
    XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
  }
  func testChangedSessionAfterDiskCompletionNeverPublishesOrPrunes() throws {
    let old = try (0..<11).map { try existing($0) }
    var current = true
    let result = store(current: { current }, writer: { url in
      try? Data("new".utf8).write(to: url)
      current = false
      return SaveStateCompletedSnapshot(filePath: url.path, gameID: "GALE01", playTimeSeconds: 0,
        savedAt: Date(), sessionIdentifier: 7)
    }).save(gameID: "GALE01", sessionIdentifier: 7)
    XCTAssertTrue(result.cancelled)
    XCTAssertNil(result.snapshot)
    XCTAssertTrue(old.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
  }
  func testKeepUpdatesOnlySelectedMetadata() throws {
    let first = try existing(1), second = try existing(2)
    XCTAssertTrue(store().setKept(true, at: first, gameID: "GALE01"))
    XCTAssertEqual(SaveStateMetadataStore.read(forStateFile: first)?.isKept, true)
    XCTAssertEqual(SaveStateMetadataStore.read(forStateFile: second)?.isKept, false)
    XCTAssertEqual(SaveStateMetadataStore.read(forStateFile: first)?.savedAt, Date(timeIntervalSince1970: 1))
  }
  func testKeepFailureLeavesExistingMetadataUntouched() throws {
    let url = try existing(1)
    XCTAssertFalse(store(metadata: { _, _ in false }).setKept(true, at: url, gameID: "GALE01"))
    XCTAssertEqual(SaveStateMetadataStore.read(forStateFile: url)?.isKept, false)
  }
  func testHomebrewAndShortGameIDsCreateValidUniqueHistory() throws {
    for gameID in ["ID-Slot-3", "ID-Homebrew 日本語.quick-demo", "HBW"] {
      let persistence = store(writer: { url in
        try? Data("state".utf8).write(to: url)
        return SaveStateCompletedSnapshot(filePath: url.path, gameID: gameID,
          playTimeSeconds: 1, savedAt: Date(), sessionIdentifier: 7)
      })
      let saved = try XCTUnwrap(persistence.save(gameID: gameID, sessionIdentifier: 7).snapshot)
      XCTAssertEqual(QuickSaveHistoryPolicy.historyGameID(for: URL(fileURLWithPath: saved.filePath)), gameID)
    }
  }
  func testWrongGameOrSessionSnapshotNeverCommitsMetadataOrPrunes() throws {
    let old = try (0..<11).map { try existing($0) }
    for identity in [("RSBE01", UInt64(7)), ("GALE01", UInt64(8))] {
      let result = store(writer: { url in
        try? Data("state".utf8).write(to: url)
        return SaveStateCompletedSnapshot(filePath: url.path, gameID: identity.0,
          playTimeSeconds: 1, savedAt: Date(), sessionIdentifier: identity.1)
      }).save(gameID: "GALE01", sessionIdentifier: 7)
      XCTAssertTrue(result.cancelled)
    }
    XCTAssertTrue(old.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count, 33)
  }
  func testTraversalGameIDIsRejectedBeforeWriter() {
    var called = false
    let persistence = store(writer: { _ in called = true; return nil })
    XCTAssertNil(persistence.save(gameID: "../GALE01", sessionIdentifier: 7).snapshot)
    XCTAssertFalse(called)
  }
  func testCanonicalNamedDirectoryIsNeverPruned() throws {
    let directory = root.appendingPathComponent("GALE01.quick-\(UUID().uuidString).s01")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    XCTAssertTrue(SaveStateMetadataStore.write(SaveStateMetadata(title: "Directory", gameID: "GALE01",
      savedAt: Date(timeIntervalSince1970: -1), isQuickSave: true), forStateFile: directory))
    _ = try (0..<11).map { try existing($0) }
    XCTAssertNotNil(store().save(gameID: "GALE01", sessionIdentifier: 7).snapshot)
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
  }
  func testFailedWriterCleansOnlyItsPartialUniqueFile() throws {
    let old = try (0..<11).map { try existing($0) }
    let result = store(writer: { url in
      try? Data("partial".utf8).write(to: url)
      return nil
    }).save(gameID: "GALE01", sessionIdentifier: 7)
    XCTAssertNil(result.snapshot)
    XCTAssertTrue(old.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count, 33)
  }
  func testSidecarCleanupFailureKeepsSuccessfulNewSnapshot() throws {
    _ = try (0..<11).map { try existing($0) }
    let result = store(remove: { url in
      if url.pathExtension == "png" { throw CocoaError(.fileWriteNoPermission) }
      try FileManager.default.removeItem(at: url)
    }).save(gameID: "GALE01", sessionIdentifier: 7)
    let saved = try XCTUnwrap(result.snapshot)
    XCTAssertTrue(result.cleanupFailed)
    XCTAssertTrue(FileManager.default.fileExists(atPath: saved.filePath))
    XCTAssertNotNil(SaveStateMetadataStore.read(forStateFile: URL(fileURLWithPath: saved.filePath)))
  }
  func testKeepRejectsClassicAndOutsideRootAndSymlink() throws {
    let classic = try existing(1, name: "GALE01.s01")
    XCTAssertFalse(store().setKept(true, at: classic, gameID: "GALE01"))
    let outside = root.deletingLastPathComponent().appendingPathComponent("GALE01.quick-\(UUID().uuidString).s01")
    XCTAssertFalse(store().setKept(true, at: outside, gameID: "GALE01"))
    let link = root.appendingPathComponent("GALE01.quick-\(UUID().uuidString).s01")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: classic)
    XCTAssertFalse(store().setKept(true, at: link, gameID: "GALE01"))
  }
}
