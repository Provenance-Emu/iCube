// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import XCTest

@testable import iCube

final class BackgroundDownloadPolicyTests: XCTestCase {
  private typealias Policy = BackgroundDownloadPolicy

  private let job = BackgroundDownloadJob(kind: .emulationServer, sourceID: "ecs:http://server.local:8473",
                                          gameKey: "item:1", title: "Game")
  private let fileURL = URL(string: "http://server.local:8473/api/v1/files/a/content")!
  private let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func record(_ state: BackgroundDownloadRecord.State, id: String = "r1", size: Int64? = 100,
                      age: TimeInterval = 0) -> BackgroundDownloadRecord {
    BackgroundDownloadRecord(id: id, job: job, url: fileURL, expectedSize: size, state: state,
                             updatedAt: now.addingTimeInterval(-age))
  }

  // MARK: - Finished files

  func testFinishedFileIsKeptOnlyWhenStatusAndSizeMatch() {
    XCTAssertNil(Policy.judgeFinishedFile(status: 200, receivedBytes: 100, expectedBytes: 100,
                                          requestedURL: fileURL, finalURL: fileURL))
    XCTAssertNil(Policy.judgeFinishedFile(status: 206, receivedBytes: 100, expectedBytes: 100,
                                          requestedURL: fileURL, finalURL: fileURL), "A resumed transfer ends in 206")
    XCTAssertNil(Policy.judgeFinishedFile(status: 200, receivedBytes: 7, expectedBytes: nil,
                                          requestedURL: fileURL, finalURL: nil), "No size to check against")
    XCTAssertEqual(Policy.judgeFinishedFile(status: 200, receivedBytes: 99, expectedBytes: 100,
                                            requestedURL: fileURL, finalURL: fileURL), .incomplete)
  }

  func testExpiredCredentialArrivesAsAFinishedErrorPage() {
    for status in [401, 403] {
      XCTAssertEqual(Policy.judgeFinishedFile(status: status, receivedBytes: 40, expectedBytes: 100,
                                              requestedURL: fileURL, finalURL: fileURL), .accessDenied)
    }
    XCTAssertEqual(Policy.judgeFinishedFile(status: 404, receivedBytes: 9, expectedBytes: 100,
                                            requestedURL: fileURL, finalURL: fileURL), .unavailable)
    XCTAssertEqual(Policy.judgeFinishedFile(status: 500, receivedBytes: 100, expectedBytes: 100,
                                            requestedURL: fileURL, finalURL: fileURL), .server)
    XCTAssertEqual(Policy.judgeFinishedFile(status: nil, receivedBytes: 100, expectedBytes: 100,
                                            requestedURL: fileURL, finalURL: fileURL), .server)
  }

  func testTransferThatEndedOnAnotherOriginIsRejected() {
    let elsewhere = URL(string: "http://cdn.example/disc.iso")!
    XCTAssertEqual(Policy.judgeFinishedFile(status: 200, receivedBytes: 100, expectedBytes: 100,
                                            requestedURL: fileURL, finalURL: elsewhere), .redirected)
    let otherPort = URL(string: "http://server.local:9000/api/v1/files/a/content")!
    XCTAssertEqual(Policy.judgeFinishedFile(status: 200, receivedBytes: 100, expectedBytes: 100,
                                            requestedURL: fileURL, finalURL: otherPort), .redirected)
    XCTAssertTrue(Policy.sameOrigin(URL(string: "https://Romm.Example/a")!, URL(string: "https://romm.example:443/b")!))
    XCTAssertFalse(Policy.sameOrigin(URL(string: "https://romm.example/a")!, URL(string: "http://romm.example/a")!))
  }

  func testErrorsSayWhetherTheTransferCanContinue() {
    XCTAssertEqual(Policy.judgeError(URLError(.cancelled)), .cancelled)
    XCTAssertEqual(Policy.judgeError(CancellationError()), .cancelled)
    XCTAssertEqual(Policy.judgeError(URLError(.networkConnectionLost)), .network)
    XCTAssertEqual(Policy.judgeError(URLError(.timedOut)), .network)
    XCTAssertEqual(Policy.judgeError(URLError(.cannotWriteToFile)), .storage)
    XCTAssertEqual(Policy.judgeError(URLError(.userAuthenticationRequired)), .accessDenied)

    XCTAssertTrue(BackgroundDownloadFailure.network.keepsResumeData)
    XCTAssertTrue(BackgroundDownloadFailure.cancelled.keepsResumeData)
    for failure in [BackgroundDownloadFailure.accessDenied, .unavailable, .incomplete, .server, .redirected, .storage] {
      XCTAssertFalse(failure.keepsResumeData, "\(failure) would replay a request that cannot work")
      XCTAssertTrue(failure.isTerminal)
    }
  }

  // MARK: - Asking again

  func testAskingAgainAdoptsJoinsResumesOrStarts() {
    XCTAssertEqual(Policy.step(for: nil, hasLiveTask: false, arrivedFileExists: false, resumeDataExists: false), .start)
    XCTAssertEqual(Policy.step(for: record(.arrived), hasLiveTask: false, arrivedFileExists: true, resumeDataExists: false), .adopt)
    XCTAssertEqual(Policy.step(for: record(.arrived), hasLiveTask: false, arrivedFileExists: false, resumeDataExists: false),
                   .start, "A claimed or lost file is fetched again")
    XCTAssertEqual(Policy.step(for: record(.running), hasLiveTask: true, arrivedFileExists: false, resumeDataExists: false), .attach)
    XCTAssertEqual(Policy.step(for: record(.running), hasLiveTask: false, arrivedFileExists: false, resumeDataExists: true), .resume)
    XCTAssertEqual(Policy.step(for: record(.running), hasLiveTask: false, arrivedFileExists: false, resumeDataExists: false), .start)
    XCTAssertEqual(Policy.step(for: record(.failed(.network)), hasLiveTask: false, arrivedFileExists: false,
                               resumeDataExists: true), .resume)
    XCTAssertEqual(Policy.step(for: record(.failed(.cancelled)), hasLiveTask: false, arrivedFileExists: false,
                               resumeDataExists: true), .resume)
    XCTAssertEqual(Policy.step(for: record(.failed(.accessDenied)), hasLiveTask: false, arrivedFileExists: false,
                               resumeDataExists: true), .start, "Resume data would send the old credential again")
  }

  // MARK: - Relaunch

  func testRelaunchRepairsRecordsAgainstTheSystemsTransfers() {
    XCTAssertEqual(Policy.repair(record(.running), hasLiveTask: true, arrivedFileExists: false, now: now), .keep)
    XCTAssertEqual(Policy.repair(record(.running, age: 30 * 24 * 3600), hasLiveTask: true, arrivedFileExists: false, now: now),
                   .keep, "A transfer the system still runs is never thrown away")
    XCTAssertEqual(Policy.repair(record(.running), hasLiveTask: false, arrivedFileExists: false, now: now), .interrupted)
    XCTAssertEqual(Policy.repair(record(.arrived), hasLiveTask: false, arrivedFileExists: true, now: now), .keep)
    XCTAssertEqual(Policy.repair(record(.arrived), hasLiveTask: false, arrivedFileExists: false, now: now), .discard)
    XCTAssertEqual(Policy.repair(record(.failed(.network)), hasLiveTask: false, arrivedFileExists: false, now: now), .keep)
    XCTAssertEqual(Policy.repair(record(.arrived, age: Policy.retention + 1), hasLiveTask: false, arrivedFileExists: true, now: now),
                   .discard, "A file nobody claimed for a week is deleted")
    XCTAssertEqual(Policy.repair(record(.failed(.cancelled), age: Policy.retention + 1), hasLiveTask: false,
                                 arrivedFileExists: false, now: now), .discard)
  }

  func testOnlyJobsStillOnTheirWayResumeByThemselves() {
    XCTAssertFalse(Policy.resumesByItself([]))
    XCTAssertTrue(Policy.resumesByItself([record(.running, id: "a"), record(.arrived, id: "b")]))
    XCTAssertTrue(Policy.resumesByItself([record(.arrived, id: "a")]))
    XCTAssertFalse(Policy.resumesByItself([record(.arrived, id: "a"), record(.failed(.cancelled), id: "b")]),
                   "A cancel waits for the user")
    XCTAssertFalse(Policy.resumesByItself([record(.failed(.network), id: "a")]))
  }

  func testOrphanedFilesAreThoseNoRecordOwns() {
    let names = ["journal.json", "r1.download", "r1.resume", "gone.download", "gone.resume", "r2.download.importing"]
    XCTAssertEqual(Policy.orphanedFiles(names, records: [record(.arrived, id: "r1"), record(.running, id: "r2")]),
                   ["gone.download", "gone.resume"])
  }

  func testJobProgressCountsArrivedFilesInFull() {
    let records = ["a": record(.arrived, id: "a", size: 100), "b": record(.running, id: "b", size: 50)]
    XCTAssertEqual(Policy.receivedBytes(ids: ["a", "b"], records: records, written: ["a": 10, "b": 20]), 120)
    XCTAssertEqual(Policy.receivedBytes(ids: ["b", "c"], records: records, written: ["b": -1]), 0)
  }

  func testStoredURLNeverKeepsACredential() {
    let url = URL(string: "https://user:secret@dav.example/Games/Disc.iso")!
    XCTAssertEqual(BackgroundDownloadRecord.storedURL(url).absoluteString, "https://dav.example/Games/Disc.iso")
    XCTAssertEqual(BackgroundDownloadRecord.storedURL(fileURL), fileURL)
  }
}

final class BackgroundDownloadJournalTests: XCTestCase {
  private var folder: URL!
  private let job = BackgroundDownloadJob(kind: .webdav, sourceID: "dav1", gameKey: "https://dav.example/a.iso", title: "A")

  override func setUp() {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("journal-" + UUID().uuidString, isDirectory: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: folder)
  }

  private func record(_ id: String, _ state: BackgroundDownloadRecord.State, url: String = "https://dav.example/a.iso",
                      updatedAt: Date = Date()) -> BackgroundDownloadRecord {
    BackgroundDownloadRecord(id: id, job: job, url: URL(string: url)!, expectedSize: 4, state: state, updatedAt: updatedAt)
  }

  func testRecordsAndPlansSurviveARelaunch() throws {
    let journal = BackgroundDownloadJournal(folder: folder)
    journal.save(record("r1", .running))
    journal.setPlan(Data("plan".utf8), forJob: job.key)
    journal.update(id: "r1", state: .failed(.network))

    let reopened = BackgroundDownloadJournal(folder: folder)
    XCTAssertEqual(reopened.records.map(\.id), ["r1"])
    XCTAssertEqual(reopened.record(id: "r1")?.state, .failed(.network))
    XCTAssertEqual(reopened.plan(forJob: job.key), Data("plan".utf8))
    XCTAssertEqual(reopened.jobs, [job])
    XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
  }

  func testLookupByURLIgnoresCredentials() {
    let journal = BackgroundDownloadJournal(folder: folder)
    journal.save(record("r1", .running))
    XCTAssertEqual(journal.record(job: job, url: URL(string: "https://user:pw@dav.example/a.iso")!)?.id, "r1")
    let other = BackgroundDownloadJob(kind: .webdav, sourceID: "dav2", gameKey: job.gameKey, title: "A")
    XCTAssertNil(journal.record(job: other, url: URL(string: "https://dav.example/a.iso")!), "Records belong to one source")
  }

  func testRemovingAJobsRecordsDeletesItsFilesAndPlan() throws {
    let journal = BackgroundDownloadJournal(folder: folder)
    journal.save(record("r1", .arrived))
    journal.setPlan(Data("plan".utf8), forJob: job.key)
    try Data("disc".utf8).write(to: journal.arrivedFile(id: "r1"))
    journal.setResumeData(Data("resume".utf8), id: "r1")

    journal.remove(ids: ["r1"])
    XCTAssertTrue(journal.records.isEmpty)
    XCTAssertNil(journal.plan(forJob: job.key))
    XCTAssertFalse(FileManager.default.fileExists(atPath: journal.arrivedFile(id: "r1").path))
    XCTAssertNil(journal.resumeData(id: "r1"))
  }

  func testReconcileKeepsLiveAndArrivedWorkAndSweepsTheRest() throws {
    let journal = BackgroundDownloadJournal(folder: folder)
    let old = Date().addingTimeInterval(-BackgroundDownloadPolicy.retention - 60)
    journal.save(record("live", .running, url: "https://dav.example/1.iso"))
    journal.save(record("dead", .running, url: "https://dav.example/2.iso"))
    journal.save(record("done", .arrived, url: "https://dav.example/3.iso"))
    journal.save(record("lost", .arrived, url: "https://dav.example/4.iso"))
    journal.save(record("stale", .failed(.cancelled), url: "https://dav.example/5.iso", updatedAt: old))
    try Data("disc".utf8).write(to: journal.arrivedFile(id: "done"))
    try Data("left over".utf8).write(to: folder.appendingPathComponent("someone-else.download"))

    journal.reconcile(liveTaskIDs: ["live"])
    XCTAssertEqual(Set(journal.records.map(\.id)), ["live", "dead", "done"])
    XCTAssertEqual(journal.record(id: "live")?.state, .running)
    XCTAssertEqual(journal.record(id: "dead")?.state, .failed(.network), "Kept, so a retry can start it again")
    XCTAssertTrue(FileManager.default.fileExists(atPath: journal.arrivedFile(id: "done").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("someone-else.download").path))
  }
}
