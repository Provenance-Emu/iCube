// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

private final class NoopHost: ContinuedImportSessionHost {
  func withdrawRequest() {}
  func scheduleDeadline(seconds: TimeInterval, fire: @escaping () -> Void) {}
}

/// The progress-reporting copier used on the iOS 26 path. The staging rules (a `.importing` name,
/// a size check, a rename; nothing left under the real name) must hold exactly as for `copyItem`.
final class ImportStagingTrackedCopyTests: XCTestCase {
  private var root: URL!
  private var host = NoopHost()

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("ImportStagingTrackedCopyTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    ImportStaging.cloneEnabled = false
  }

  override func tearDownWithError() throws {
    ImportStaging.cloneEnabled = true
    try? FileManager.default.removeItem(at: root)
  }

  private func makeFile(_ name: String, megabytes: Int) throws -> String {
    let path = root.appendingPathComponent(name).path
    let chunk = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    FileManager.default.createFile(atPath: path, contents: nil)
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    for _ in 0..<megabytes { handle.write(chunk) }
    try handle.close()
    return path
  }

  private func keepAlive(items: [(String, Int64)]) -> (ImportKeepAlive, ContinuedImportSession) {
    let session = ContinuedImportSession(items: items, host: host, title: "t", subtitle: { _, _ in "s" })
    return (ImportKeepAlive(session: session), session)
  }

  func testTrackedCopyLandsCompleteAndReportsEveryByte() throws {
    let source = try makeFile("a.iso", megabytes: 8)
    let destination = root.appendingPathComponent("lib-a.iso").path
    let (keepAlive, session) = keepAlive(items: [("a.iso", 8 * 1024 * 1024)])

    try ImportStaging.stagedCopy(fromPath: source, toPath: destination, keepAlive: keepAlive, itemIndex: 0)

    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)), try Data(contentsOf: URL(fileURLWithPath: source)))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination + ImportStaging.stagingSuffix))
    XCTAssertEqual(session.fractionCompleted, 1, accuracy: 0.0001)
  }

  func testStoppedCopyLeavesNothingUnderTheRealNameOrStaged() throws {
    let source = try makeFile("b.iso", megabytes: 8)
    let destination = root.appendingPathComponent("lib-b.iso").path
    let (keepAlive, session) = keepAlive(items: [("b.iso", 8 * 1024 * 1024)])
    session.taskExpired()
    XCTAssertTrue(keepAlive.isCancelled)

    XCTAssertThrowsError(try ImportStaging.stagedCopy(fromPath: source, toPath: destination, keepAlive: keepAlive, itemIndex: 0)) {
      XCTAssertEqual(($0 as NSError).code, ImportStaging.stoppedErrorCode)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination + ImportStaging.stagingSuffix))
    XCTAssertEqual(session.fractionCompleted, 0, accuracy: 0.5, "the stop happens within the first step")
  }

  func testUntrackedCallUsesTheOriginalCopy() throws {
    let source = try makeFile("c.iso", megabytes: 1)
    let destination = root.appendingPathComponent("lib-c.iso").path
    try ImportStaging.stagedCopy(fromPath: source, toPath: destination, keepAlive: nil, itemIndex: 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination))
  }

  func testCloneFastPathStillReportsTheWholeFile() throws {
    ImportStaging.cloneEnabled = true
    let source = try makeFile("d.iso", megabytes: 4)
    let destination = root.appendingPathComponent("lib-d.iso").path
    let (keepAlive, session) = keepAlive(items: [("d.iso", 4 * 1024 * 1024)])
    try ImportStaging.stagedCopy(fromPath: source, toPath: destination, keepAlive: keepAlive, itemIndex: 0)
    XCTAssertEqual(session.fractionCompleted, 1, accuracy: 0.0001)
  }

  func testTrackedMoveOnTheSameVolumeIsARename() throws {
    let source = try makeFile("e.iso", megabytes: 2)
    let destination = root.appendingPathComponent("lib-e.iso").path
    let (keepAlive, session) = keepAlive(items: [("e.iso", 2 * 1024 * 1024)])
    try ImportStaging.stagedMove(fromPath: source, toPath: destination, keepAlive: keepAlive, itemIndex: 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: source))
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination))
    XCTAssertEqual(session.fractionCompleted, 1, accuracy: 0.0001)
  }

  func testStaleSweepRemovesLeftoversButNotACopyInFlight() throws {
    let leftover = root.appendingPathComponent("old.iso" + ImportStaging.stagingSuffix).path
    FileManager.default.createFile(atPath: leftover, contents: Data([1]))
    XCTAssertEqual(ImportStaging.removeStaleStagedImports(inFolder: root.path), 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: leftover))
  }
}
