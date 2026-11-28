// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class ModInstallLedgerTests: XCTestCase {
  private var fileURL: URL!
  private var clock: Clock!

  private final class Clock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
  }

  override func setUp() {
    fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ModLedger-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("ModInstalls.json")
    clock = Clock()
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
  }

  private func ledger() -> ModInstallLedger {
    let clock = clock!
    return ModInstallLedger(fileURL: fileURL, now: { clock.date })
  }

  private func record(_ id: Int, stage: ModInstallRecord.Stage = .downloaded, folder: String? = "1-abc") -> ModInstallRecord {
    ModInstallRecord(fileID: id, fileName: "mod\(id).zip", fileSize: 42, downloadURL: URL(string: "https://gamebanana.com/dl/\(id)"),
                     md5: "abc", modName: "Mod \(id)", bananaGameID: 6247, workFolder: folder, stage: stage, installed: [],
                     updatedAt: .distantPast)
  }

  func testARecordSurvivesANewLedgerOnTheSameFile() {
    ledger().save(record(383_315, stage: .installed))
    let reloaded = ledger().record(forFileID: 383_315)
    XCTAssertEqual(reloaded?.stage, .installed)
    XCTAssertEqual(reloaded?.modName, "Mod 383315")
    XCTAssertEqual(reloaded?.workFolder, "1-abc")
    XCTAssertEqual(reloaded?.updatedAt, clock.date)
  }

  func testTheRememberedFileCanBeDownloadedAgain() {
    let file = record(7).file
    XCTAssertEqual(file.id, 7)
    XCTAssertEqual(file.fileName, "mod7.zip")
    XCTAssertEqual(file.size, 42)
    XCTAssertEqual(file.downloadURL?.absoluteString, "https://gamebanana.com/dl/7")
    XCTAssertEqual(file.md5, "abc")
  }

  func testRecordsAreListedNewestFirst() {
    let ledger = ledger()
    ledger.save(record(1))
    clock.date += 60
    ledger.save(record(2))
    clock.date += 60
    ledger.update(fileID: 1) { $0.installed.append("Installed 3 textures.") }
    XCTAssertEqual(ledger.records.map(\.fileID), [1, 2])
    XCTAssertEqual(ledger.record(forFileID: 1)?.installed, ["Installed 3 textures."])
  }

  func testUpdatingAnUnknownFileAddsNothing() {
    let ledger = ledger()
    ledger.update(fileID: 9) { $0.stage = .installed }
    XCTAssertTrue(ledger.records.isEmpty)
  }

  func testRemovingForgetsTheFileOnDiskToo() {
    let first = ledger()
    first.save(record(1))
    first.save(record(2))
    first.remove(fileID: 1)
    XCTAssertEqual(ledger().records.map(\.fileID), [2])
  }

  func testADamagedFileStartsEmptyAndIsReplaced() throws {
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: fileURL)
    let ledger = ledger()
    XCTAssertTrue(ledger.records.isEmpty)
    ledger.save(record(5))
    XCTAssertEqual(self.ledger().records.map(\.fileID), [5])
  }

  func testChangesAreAnnounced() {
    let ledger = ledger()
    let announced = expectation(forNotification: ModInstallLedger.didChangeNotification, object: ledger)
    ledger.save(record(1))
    wait(for: [announced], timeout: 2)
  }
}
