// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class ModInstallModelTests: XCTestCase {
  private func file(name: String, url: String? = "https://gamebanana.com/dl/1") throws -> GameBananaFile {
    let link = url.map { #", "_sDownloadUrl": "\#($0)""# } ?? ""
    let json = #"{"_idRow": 1, "_sFile": "\#(name)", "_nFilesize": 10\#(link)}"#
    return try JSONDecoder().decode(GameBananaFile.self, from: Data(json.utf8))
  }

  func testRarArchivesAreAllowed() throws {
    XCTAssertNil(ModInstallModel.blockedReason(for: try file(name: "pack.RAR")))
  }

  func testFilesWithoutALinkAreBlocked() throws {
    XCTAssertNotNil(ModInstallModel.blockedReason(for: try file(name: "pack.zip", url: nil)))
  }

  func testZipAndBareFilesAreAllowed() throws {
    XCTAssertNil(ModInstallModel.blockedReason(for: try file(name: "pack.zip")))
    XCTAssertNil(ModInstallModel.blockedReason(for: try file(name: "patch.xdelta")))
    XCTAssertNil(ModInstallModel.blockedReason(for: try file(name: "pack.7z")))
  }

  @MainActor
  func testCleaningUpReopenedFilePreservesPatchAlreadyHandedOff() throws {
    let file = try file(name: "patch.xdelta")
    let handler = LiveModInstallHandler(presentPatches: { _, _ in })
    let ledger = ModInstallLedger(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ModModel-\(UUID().uuidString).json"))
    let original = ModInstallModel(file: file, ownedGame: nil, handler: handler, ledger: ledger)
    let reopened = ModInstallModel(file: file, ownedGame: nil, handler: handler, ledger: ledger)
    let fm = FileManager.default
    defer {
      try? fm.removeItem(at: original.workDirectory)
      try? fm.removeItem(at: reopened.workDirectory)
    }
    try fm.createDirectory(at: original.workDirectory, withIntermediateDirectories: true)
    try fm.createDirectory(at: reopened.workDirectory, withIntermediateDirectories: true)
    let patch = original.workDirectory.appendingPathComponent(file.fileName)
    let bytes = Data([0xD6, 0xC3, 0xC4, 0x00])
    try bytes.write(to: patch)
    original.presentDiscPatch([patch], suggestedGameID: nil)
    original.cleanUp()

    reopened.cleanUp()

    XCTAssertFalse(fm.fileExists(atPath: reopened.workDirectory.path))
    XCTAssertEqual(try Data(contentsOf: patch), bytes)
  }

  func testRegionWarningOnlyForTheSameTitleInAnotherRegion() {
    XCTAssertNotNil(ModInstallModel.regionWarning(packID: "GALE01", ownedID: "GALP01"))
    XCTAssertNil(ModInstallModel.regionWarning(packID: "GALE01", ownedID: "GALE01"))
    XCTAssertNil(ModInstallModel.regionWarning(packID: "GALE01", ownedID: nil))
    XCTAssertNil(ModInstallModel.regionWarning(packID: "RMC", ownedID: "RMCP01"))
    XCTAssertNil(ModInstallModel.regionWarning(packID: "readme", ownedID: "RMCP01"))
  }

  // MARK: - Coming back to a file

  private func ledger() -> ModInstallLedger {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ModModel-\(UUID().uuidString).json")
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return ModInstallLedger(fileURL: url)
  }

  private func record(for file: GameBananaFile, stage: ModInstallRecord.Stage, folder: String?, installed: [String] = []) -> ModInstallRecord {
    ModInstallRecord(fileID: file.id, fileName: file.fileName, fileSize: file.size, downloadURL: file.downloadURL, md5: file.md5,
                     modName: "Co-op", bananaGameID: 7120, workFolder: folder, stage: stage, installed: installed, updatedAt: Date())
  }

  @MainActor
  func testAnUnpackedDownloadIsReadyAgainAfterARelaunch() async throws {
    let file = try file(name: "coop.zip")
    let folder = "1-\(UUID().uuidString)"
    let directory = ModDownloadManager.downloadsDirectory.appendingPathComponent(folder, isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: directory.appendingPathComponent("extracted"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }
    try Data([0xD6, 0xC3, 0xC4, 0x00]).write(to: directory.appendingPathComponent("extracted/Console.xdelta"))
    let ledger = ledger()
    ledger.save(record(for: file, stage: .downloaded, folder: folder))

    let model = ModInstallModel(file: file, ownedGame: nil, handler: LiveModInstallHandler(presentPatches: { _, _ in }), ledger: ledger)
    XCTAssertEqual(model.status, .none)
    await model.restoreIfNeeded()

    guard case .ready(let classification) = model.phase, case .discPatch(let patches, _) = classification.kinds[0] else {
      return XCTFail("\(model.phase)")
    }
    XCTAssertEqual(patches.map(\.lastPathComponent), ["Console.xdelta"])
    XCTAssertEqual(model.status, .downloaded)
    XCTAssertTrue(model.isWorthKeeping)
    // Leaving the screen keeps a download nothing was installed from.
    model.cleanUp()
    XCTAssertTrue(fm.fileExists(atPath: directory.path))

    model.discardDownload()
    XCTAssertFalse(fm.fileExists(atPath: directory.path))
    XCTAssertNil(ledger.record(forFileID: file.id))
    XCTAssertEqual(model.phase, .idle)
  }

  @MainActor
  func testWhatWasInstalledIsStillListedAfterTheDownloadIsGone() async throws {
    let file = try file(name: "textures.zip")
    let ledger = ledger()
    ledger.save(record(for: file, stage: .installed, folder: "1-gone-\(UUID().uuidString)", installed: ["Installed 28 textures for SMN."]))

    let model = ModInstallModel(file: file, ownedGame: nil, handler: LiveModInstallHandler(presentPatches: { _, _ in }), ledger: ledger)
    await model.restoreIfNeeded()

    XCTAssertEqual(model.phase, .idle)
    XCTAssertEqual(model.log, ["Installed 28 textures for SMN."])
    XCTAssertEqual(model.status, .installed)
    XCTAssertFalse(model.isWorthKeeping)
    XCTAssertNil(ledger.record(forFileID: file.id)?.workFolder, "the swept download is no longer pointed at")
    XCTAssertEqual(ledger.record(forFileID: file.id)?.stage, .installed)
  }

  @MainActor
  func testADownloadThatDidNotSurviveIsForgotten() async throws {
    let file = try file(name: "pack.zip")
    let ledger = ledger()
    ledger.save(record(for: file, stage: .downloading, folder: "1-lost-\(UUID().uuidString)"))
    // A foreground manager keeps no transfers across launches, so nothing is running for this file.
    let model = ModInstallModel(file: file, ownedGame: nil, handler: LiveModInstallHandler(presentPatches: { _, _ in }),
                                downloader: ModDownloadManager(), ledger: ledger)
    await model.restoreIfNeeded()
    XCTAssertEqual(model.phase, .idle)
    XCTAssertNil(ledger.record(forFileID: file.id))
  }
}
