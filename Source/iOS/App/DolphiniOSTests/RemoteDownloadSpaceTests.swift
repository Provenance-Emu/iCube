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

  // MARK: - What is already on disk

  private let job = BackgroundDownloadJob(kind: .emulationServer, sourceID: "ecs:http://server.local:8473", gameKey: "item:1", title: "Game")

  private func record(_ id: String, _ state: BackgroundDownloadRecord.State, size: Int64?) -> BackgroundDownloadRecord {
    BackgroundDownloadRecord(id: id, job: job, url: URL(string: "http://server.local:8473/api/v1/files/\(id)/content")!,
                             expectedSize: size, state: state, updatedAt: Date())
  }

  /// A 4 GiB game with 3 GiB already down and 2 GiB free: 1 GiB is still to come, so it fits.
  /// Counting only finished files asked for all 4 GiB again and refused it.
  func testAPartialDownloadIsNotCountedAgainstTheSpaceItUses() {
    let disc = [Space.File(bytes: 4 * gigabyte, isArchive: false)]
    let running = [record("r", .running, size: 4 * gigabyte)]
    let stopped = [record("r", .failed(.network), size: 4 * gigabyte)]

    let live = BackgroundDownloadPolicy.storedBytes(records: running, arrived: [:], transferred: ["r": 3 * gigabyte], resumable: [:])
    let resumable = BackgroundDownloadPolicy.storedBytes(records: stopped, arrived: [:], transferred: [:], resumable: ["r": 3 * gigabyte])
    for stored in [live, resumable] {
      XCTAssertEqual(stored, 3 * gigabyte)
      let needed = Space.neededBytes(files: disc, storedBytes: stored)
      XCTAssertEqual(needed, gigabyte)
      XCTAssertNoThrow(try Library.checkDownloadSpace(bytes: needed, available: 2 * gigabyte))
    }
    XCTAssertThrowsError(try Library.checkDownloadSpace(bytes: Space.neededBytes(files: disc, storedBytes: 0), available: 2 * gigabyte),
                         "The same game from nothing does not fit")
  }

  func testStoredBytesAddUpEveryStateAndNeverExceedAFile() {
    let records = [record("here", .arrived, size: 300), record("coming", .running, size: 500),
                   record("stopped", .failed(.cancelled), size: 400), record("lost", .failed(.server), size: 900),
                   record("unsized", .running, size: nil)]
    let stored = BackgroundDownloadPolicy.storedBytes(
      records: records, arrived: ["here": 300, "coming": 999],
      transferred: ["coming": 120, "stopped": 10, "unsized": 7], resumable: ["stopped": 250, "coming": 80, "here": 999])
    XCTAssertEqual(stored, 300 + 120 + 250 + 0 + 7)
    XCTAssertEqual(BackgroundDownloadPolicy.storedBytes(records: [record("r", .running, size: 100)], arrived: [:],
                                                        transferred: ["r": 5000], resumable: [:]), 100)
  }

  func testResumeDataSaysHowMuchIsOnDisk() throws {
    let contents: [String: Any] = ["NSURLSessionResumeBytesReceived": NSNumber(value: 3 * gigabyte), "NSURLSessionResumeInfoVersion": 2]
    let plain = try PropertyListSerialization.data(fromPropertyList: contents, format: .binary, options: 0)
    XCTAssertEqual(BackgroundDownloadPolicy.resumeDataBytes(plain), 3 * gigabyte)
    let archived = try NSKeyedArchiver.archivedData(withRootObject: contents as NSDictionary, requiringSecureCoding: false)
    XCTAssertEqual(BackgroundDownloadPolicy.resumeDataBytes(archived), 3 * gigabyte)
    XCTAssertNil(BackgroundDownloadPolicy.resumeDataBytes(Data("not a plist".utf8)))
    XCTAssertNil(BackgroundDownloadPolicy.resumeDataBytes(try PropertyListSerialization.data(fromPropertyList: ["x": 1], format: .xml, options: 0)))
  }

  func testTheJournalReportsArrivedFilesAndResumeData() throws {
    let journal = BackgroundDownloadJournal(folder: root.appendingPathComponent("journal", isDirectory: true))
    journal.save(record("here", .arrived, size: 300))
    journal.save(record("stopped", .failed(.network), size: 500))
    journal.save(record("fresh", .running, size: 500))
    try Data(repeating: 1, count: 300).write(to: journal.arrivedFile(id: "here"))
    let resume: [String: Any] = ["NSURLSessionResumeBytesReceived": 200]
    journal.setResumeData(try PropertyListSerialization.data(fromPropertyList: resume, format: .xml, options: 0), id: "stopped")

    XCTAssertEqual(journal.arrivedSizes(forJob: job.key), ["here": 300])
    XCTAssertEqual(journal.resumableBytes(forJob: job.key), ["stopped": 200])
    XCTAssertEqual(BackgroundDownloadPolicy.storedBytes(
      records: journal.records(forJob: job.key), arrived: journal.arrivedSizes(forJob: job.key), transferred: [:],
      resumable: journal.resumableBytes(forJob: job.key)), 500)
  }

  // MARK: - The decision

  private typealias Library = EmulationServerLibrary
  /// What `checkDownloadSpace` keeps free beyond the game.
  private let reserve: Int64 = 256 * 1024 * 1024

  func testAGameFitsWhenThereIsRoomForItAndTheReserve() {
    let needed = Space.neededBytes(files: [Space.File(bytes: 4 * gigabyte, isArchive: false)], storedBytes: 0)
    XCTAssertEqual(needed, 4 * gigabyte)
    XCTAssertNoThrow(try Library.checkDownloadSpace(bytes: needed, available: 40 * gigabyte))
    XCTAssertNoThrow(try Library.checkDownloadSpace(bytes: needed, available: 4 * gigabyte + reserve))
    XCTAssertThrowsError(try Library.checkDownloadSpace(bytes: needed, available: 4 * gigabyte))
  }

  func testFreeSpaceThatCannotBeMeasuredNeverRefusesAGame() {
    XCTAssertNoThrow(try Library.checkDownloadSpace(bytes: 8 * gigabyte, available: nil))
  }

  /// A relaunch finishing a game whose files already arrived: they are on disk, so what is free
  /// has already paid for them.
  func testBytesAlreadyOnDiskAreNotCountedAgain() {
    let discs = [Space.File(bytes: 4 * gigabyte, isArchive: false), Space.File(bytes: 4 * gigabyte, isArchive: false)]
    XCTAssertEqual(Space.neededBytes(files: discs, storedBytes: 8 * gigabyte), 0)
    XCTAssertNoThrow(try Library.checkDownloadSpace(bytes: 0, available: gigabyte))
    XCTAssertEqual(Space.neededBytes(files: discs, storedBytes: 4 * gigabyte), 4 * gigabyte)
    XCTAssertEqual(Space.neededBytes(files: discs, storedBytes: 100 * gigabyte), 0, "Never negative")
  }

  func testAnArchiveNeedsRoomForWhatItUnpacksTo() {
    let archive = [Space.File(bytes: gigabyte, isArchive: true)]
    XCTAssertEqual(Space.neededBytes(files: archive, storedBytes: 0), 2 * gigabyte)
    XCTAssertEqual(Space.neededBytes(files: archive, storedBytes: gigabyte), gigabyte, "An arrived archive still has to be unpacked")
  }

  func testSizesAreBytesAndHugeOnesDoNotOverflow() {
    XCTAssertEqual(Space.neededBytes(files: [Space.File(bytes: .max, isArchive: true)], storedBytes: 0), .max)
    XCTAssertEqual(Space.neededBytes(files: [Space.File(bytes: 1_459_978_240, isArchive: false)], storedBytes: 0),
                   1_459_978_240, "A GameCube disc is 1.36 GiB, not 1.36 MiB or TiB")
  }

  func testTheMessageStatesWhatIsNeededAndWhatIsFree() throws {
    let error = Library.ServerError.insufficientSpace(bytes: 5 * gigabyte, available: 2 * gigabyte)
    let message = try XCTUnwrap(error.errorDescription)
    XCTAssertTrue(message.contains(ByteCountFormatter.string(fromByteCount: 5 * gigabyte, countStyle: .file)), message)
    XCTAssertTrue(message.contains(ByteCountFormatter.string(fromByteCount: 2 * gigabyte, countStyle: .file)), message)
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
