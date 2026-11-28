// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import XCTest

@testable import iCube

/// "There is not enough space to keep this game" with gigabytes free: the message was given for
/// every failure to keep a finished file, no space was ever measured, and on tvOS the folder the
/// file is kept in could not be made at all.
final class RemoteDownloadSpaceTests: XCTestCase {
  private typealias Space = RemoteDownloadSpace

  private let gigabyte: Int64 = 1024 * 1024 * 1024
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteDownloadSpaceTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: - The reported failure

  /// What happened on Apple TV: the journal folder sat where the app may not write, the download
  /// finished, the move into the folder failed, and the user was told the device was full.
  func testAFolderThatCannotBeMadeIsNotReportedAsAFullDisk() throws {
    let blocker = root.appendingPathComponent("not-a-folder")
    try Data("x".utf8).write(to: blocker)
    let journal = BackgroundDownloadJournal(folder: blocker.appendingPathComponent("BackgroundDownloads", isDirectory: true))
    let downloaded = root.appendingPathComponent("CFNetworkDownload.tmp")
    try Data(repeating: 7, count: 4096).write(to: downloaded)

    var moveError: (any Error)?
    do {
      try ImportStaging.stagedMove(fromPath: downloaded.path, toPath: journal.arrivedFile(id: "r1").path)
    } catch {
      moveError = error
    }
    let failure = BackgroundDownloadPolicy.judgeStoreError(try XCTUnwrap(moveError))

    XCTAssertEqual(failure, .storage)
    let message = try XCTUnwrap(BackgroundDownloadError(failure: failure).errorDescription)
    XCTAssertFalse(message.localizedCaseInsensitiveContains("space"), "Nothing here measured space: \(message)")
    XCTAssertThrowsError(try journal.prepareFolder(), "The same folder is refused before a download starts")
  }

  func testAFullDiskIsReportedAsOne() {
    let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    XCTAssertEqual(BackgroundDownloadPolicy.judgeStoreError(CocoaError(.fileWriteOutOfSpace)), .outOfSpace)
    XCTAssertEqual(BackgroundDownloadPolicy.judgeStoreError(posix), .outOfSpace)
    let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: posix])
    XCTAssertEqual(BackgroundDownloadPolicy.judgeStoreError(wrapped), .outOfSpace)
    XCTAssertEqual(BackgroundDownloadPolicy.judgeStoreError(CocoaError(.fileWriteNoPermission)), .storage)
    XCTAssertEqual(BackgroundDownloadPolicy.judgeError(URLError(.cannotMoveFile)), .storage)
  }

  // MARK: - Where finished files are kept

  func testTheJournalLivesInCachesWhereNothingElseIsWritable() {
    let manager = FileManager.default
    let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    XCTAssertEqual(BackgroundDownloadJournal.defaultFolder(cachesOnly: true).deletingLastPathComponent().path, caches.path)
    XCTAssertEqual(BackgroundDownloadJournal.defaultFolder(cachesOnly: false).deletingLastPathComponent().path, support.path)
    #if os(tvOS)
    XCTAssertTrue(BackgroundDownloadJournal.platformWritesOnlyCaches)
    #else
    XCTAssertFalse(BackgroundDownloadJournal.platformWritesOnlyCaches)
    #endif
    XCTAssertNoThrow(try BackgroundDownloadJournal.shared.prepareFolder())
  }

  func testArrivedBytesCountOnlyFilesThatAreHere() throws {
    let journal = BackgroundDownloadJournal(folder: root.appendingPathComponent("journal", isDirectory: true))
    let job = BackgroundDownloadJob(kind: .emulationServer, sourceID: "ecs:http://server.local:8473", gameKey: "item:1", title: "Game")
    let url = URL(string: "http://server.local:8473/api/v1/files/a/content")!
    journal.save(BackgroundDownloadRecord(id: "here", job: job, url: url, expectedSize: 300, state: .arrived, updatedAt: Date()))
    journal.save(BackgroundDownloadRecord(id: "coming", job: job, url: url.appendingPathComponent("b"), expectedSize: 500,
                                          state: .running, updatedAt: Date()))
    try Data(repeating: 1, count: 300).write(to: journal.arrivedFile(id: "here"))
    XCTAssertEqual(journal.arrivedBytes(forJob: job.key), 300)
  }

  // MARK: - The decision

  func testAGameFitsWhenThereIsRoomForItAndTheMargin() {
    let disc = [Space.File(bytes: 4 * gigabyte, isArchive: false)]
    XCTAssertNil(Space.shortfall(files: disc, storedBytes: 0, availableBytes: 40 * gigabyte))
    XCTAssertNil(Space.shortfall(files: disc, storedBytes: 0, availableBytes: 4 * gigabyte + Space.margin))
    XCTAssertEqual(Space.shortfall(files: disc, storedBytes: 0, availableBytes: 4 * gigabyte),
                   Space.Shortfall(needed: 4 * gigabyte + Space.margin, available: 4 * gigabyte))
  }

  func testFreeSpaceThatCannotBeMeasuredNeverRefusesAGame() {
    XCTAssertNil(Space.shortfall(files: [Space.File(bytes: 8 * gigabyte, isArchive: false)], storedBytes: 0, availableBytes: nil))
  }

  /// A relaunch finishing a game whose files already arrived: they are on disk, so what is free
  /// has already paid for them.
  func testBytesAlreadyOnDiskAreNotCountedAgain() {
    let discs = [Space.File(bytes: 4 * gigabyte, isArchive: false), Space.File(bytes: 4 * gigabyte, isArchive: false)]
    XCTAssertNil(Space.shortfall(files: discs, storedBytes: 8 * gigabyte, availableBytes: gigabyte))
    XCTAssertEqual(Space.neededBytes(files: discs, storedBytes: 4 * gigabyte), 4 * gigabyte + Space.margin)
    XCTAssertEqual(Space.neededBytes(files: discs, storedBytes: 100 * gigabyte), Space.margin, "Never negative")
  }

  func testAnArchiveNeedsRoomForWhatItUnpacksTo() {
    let archive = [Space.File(bytes: gigabyte, isArchive: true)]
    XCTAssertEqual(Space.neededBytes(files: archive, storedBytes: 0), 2 * gigabyte + Space.margin)
    XCTAssertEqual(Space.neededBytes(files: archive, storedBytes: gigabyte), gigabyte + Space.margin,
                   "An arrived archive still has to be unpacked")
  }

  func testSizesAreBytesAndHugeOnesDoNotOverflow() {
    let huge = [Space.File(bytes: .max, isArchive: true)]
    XCTAssertEqual(Space.neededBytes(files: huge, storedBytes: 0), .max)
    XCTAssertEqual(Space.neededBytes(files: [Space.File(bytes: 1_459_978_240, isArchive: false)], storedBytes: 0),
                   1_459_978_240 + Space.margin, "A GameCube disc is 1.36 GiB, not 1.36 MiB or TiB")
  }

  func testTheMessageStatesWhatIsNeededAndWhatIsFree() throws {
    let shortfall = Space.Shortfall(needed: 5 * gigabyte, available: 2 * gigabyte)
    let message = try XCTUnwrap(shortfall.errorDescription)
    XCTAssertTrue(message.contains(ByteCountFormatter.string(fromByteCount: 5 * gigabyte, countStyle: .file)), message)
    XCTAssertTrue(message.contains(ByteCountFormatter.string(fromByteCount: 2 * gigabyte, countStyle: .file)), message)
    XCTAssertEqual(shortfall.localizedDescription, message)
  }

  // MARK: - Measuring

  /// "Important usage" reporting zero, or far less than is free, must not refuse a download.
  func testTheLargerOfTheTwoSystemFiguresIsTrusted() {
    XCTAssertEqual(Space.trustedAvailableBytes(importantUsage: 0, plain: 50 * gigabyte), 50 * gigabyte)
    XCTAssertEqual(Space.trustedAvailableBytes(importantUsage: 60 * gigabyte, plain: 50 * gigabyte), 60 * gigabyte)
    XCTAssertEqual(Space.trustedAvailableBytes(importantUsage: nil, plain: 50 * gigabyte), 50 * gigabyte)
    XCTAssertEqual(Space.trustedAvailableBytes(importantUsage: 3, plain: nil), 3)
    XCTAssertNil(Space.trustedAvailableBytes(importantUsage: nil, plain: nil))
  }

  func testTheDeviceReportsFreeSpaceWhereGamesAreKept() throws {
    XCTAssertGreaterThan(try XCTUnwrap(Space.availableBytesForGames()), 0)
  }
}
