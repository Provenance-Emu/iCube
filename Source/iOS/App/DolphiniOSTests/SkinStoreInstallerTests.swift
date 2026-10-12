// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Combine
import XCTest
import Zip
@testable import iCube

/// The installer's state machine with the network stubbed, plus one pass through a real `SkinLibrary`.
@MainActor
final class SkinStoreInstallerTests: XCTestCase {
  /// Writes `source` (or a placeholder) to the destination, reports scripted progress, optionally fails.
  private struct FakeDownloader: SkinStoreDownloading {
    var error: Error?
    var source: URL?
    var progressSteps: [Double] = [0.25, 0.5, 1]

    func download(from _: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
      for step in progressSteps { progress(step) }
      if let error { throw error }
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      if let source {
        try FileManager.default.copyItem(at: source, to: destination)
      } else {
        try Data("skin".utf8).write(to: destination)
      }
    }
  }

  private var scratch: URL!
  private var recordURL: URL { scratch.appendingPathComponent("store.json") }

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SkinStoreInstallerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  private func record() -> SkinStoreInstalledRecord { SkinStoreInstalledRecord(fileURL: recordURL) }

  private func installed(id: String = "x", name: String = "Skin", gameType: SkinGameType = .gameCube) -> InstalledSkin {
    InstalledSkin(id: id, name: name, gameType: gameType, directory: scratch.appendingPathComponent(id))
  }

  private func entry(id: String = SkinCatalogFixture.gameCubePocketID, systems: [String] = ["gamecube"],
                     url: String = "https://deltastyles.com/files/skins/760/gamecubepocket.manicskin") throws -> SkinCatalogEntry {
    try SkinCatalogEntry(id: id, name: "GameCube Pocket", systems: systems, downloadURL: XCTUnwrap(URL(string: url)))
  }

  func testSuccessfulInstallRecordsTheCatalogId() async throws {
    var seen: [(file: String, section: SkinStoreSection, fileExists: Bool)] = []
    let installer = SkinStoreInstaller(downloader: FakeDownloader(), record: record(), installStep: { file, section in
      seen.append((file.lastPathComponent, section, FileManager.default.fileExists(atPath: file.path)))
      return self.installed(id: "com.starvingartist.gamecubepocket")
    })
    let skin = try entry()
    XCTAssertEqual(installer.state(for: skin), .idle)

    await installer.install(skin)

    XCTAssertEqual(installer.state(for: skin), .installed)
    XCTAssertEqual(seen.count, 1)
    XCTAssertEqual(seen.first?.file, "\(SkinCatalogFixture.gameCubePocketID).manicskin", "named <entry id>.<ext>")
    XCTAssertEqual(seen.first?.section, .gameCube)
    XCTAssertEqual(seen.first?.fileExists, true)
    XCTAssertEqual(record().load(), [SkinCatalogFixture.gameCubePocketID: "com.starvingartist.gamecubepocket"])
  }

  func testInstalledStateSurvivesANewInstaller() async throws {
    let first = SkinStoreInstaller(downloader: FakeDownloader(), record: record(), installStep: { _, _ in self.installed() })
    let skin = try entry()
    await first.install(skin)
    let second = SkinStoreInstaller(downloader: FakeDownloader(), record: record(), installStep: { _, _ in
      XCTFail("must not install")
      return self.installed()
    })
    XCTAssertEqual(second.state(for: skin), .installed)
  }

  func testDownloadFailureSurfacesMessage() async throws {
    let installer = SkinStoreInstaller(downloader: FakeDownloader(error: URLSessionSkinStoreDownloader.HTTPStatusError(statusCode: 404)),
                                       record: record(), installStep: { _, _ in
      XCTFail("install must not run after a failed download")
      return self.installed()
    })
    let skin = try entry()
    await installer.install(skin)
    XCTAssertEqual(installer.state(for: skin), .failed(message: URLSessionSkinStoreDownloader.HTTPStatusError(statusCode: 404).localizedDescription))
    XCTAssertFalse(installer.installedIds.contains(skin.id))
  }

  /// A dead link that answers HTML with 200 reaches the library as a non-archive.
  func testInstallStepFailureSurfacesMessage() async throws {
    let installer = SkinStoreInstaller(downloader: FakeDownloader(), record: record(),
                                       installStep: { _, _ in throw SkinImportError.unreadableArchive })
    let skin = try entry()
    await installer.install(skin)
    XCTAssertEqual(installer.state(for: skin), .failed(message: SkinImportError.describe(SkinImportError.unreadableArchive)))
    XCTAssertEqual(record().load(), [:])
  }

  func testStatesPassThroughDownloadingAndInstalling() async throws {
    var observed: [SkinStoreInstallState] = []
    let installer = SkinStoreInstaller(downloader: FakeDownloader(), record: record(), installStep: { _, _ in self.installed() })
    let skin = try entry()
    let cancellable = installer.$states.sink { states in
      if let state = states[skin.id] { observed.append(state) }
    }
    defer { cancellable.cancel() }

    await installer.install(skin)

    XCTAssertEqual(observed.first, .downloading(progress: 0))
    XCTAssertTrue(observed.contains(.installing))
    XCTAssertEqual(observed.last, .installed)
  }

  func testCancellationReturnsToIdle() async throws {
    let installer = SkinStoreInstaller(downloader: FakeDownloader(error: CancellationError()), record: record(),
                                       installStep: { _, _ in self.installed() })
    let skin = try entry()
    await installer.install(skin)
    XCTAssertEqual(installer.state(for: skin), .idle)
  }

  func testTemporaryDownloadFolderIsRemoved() async throws {
    var downloadedTo: URL?
    let installer = SkinStoreInstaller(downloader: FakeDownloader(), record: record(), installStep: { file, _ in
      downloadedTo = file
      return self.installed()
    })
    await installer.install(try entry())
    let folder = try XCTUnwrap(downloadedTo).deletingLastPathComponent()
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
  }

  func testHiddenEntryFailsWithoutDownloading() async throws {
    let installer = SkinStoreInstaller(downloader: FakeDownloader(error: URLError(.badURL)), record: record(),
                                       installStep: { _, _ in self.installed() })
    let zip = try entry(id: SkinCatalogFixture.n64ZipID, systems: ["n64"], url: "https://deltastyles.com/files/skins/758/x.zip")
    await installer.install(zip)
    guard case .failed = installer.state(for: zip) else { return XCTFail("a .zip entry must not install") }
  }

  func testReconcileForgetsDeletedSkins() async throws {
    let record = record()
    record.markInstalled(catalogId: "kept", skinIdentifier: "skin.kept")
    record.markInstalled(catalogId: "deleted", skinIdentifier: "skin.deleted")
    let installer = SkinStoreInstaller(downloader: FakeDownloader(), record: record, installStep: { _, _ in self.installed() })
    XCTAssertEqual(installer.installedIds, ["kept", "deleted"])

    installer.reconcileInstalled(with: ["skin.kept", "something.else"])

    XCTAssertEqual(installer.installedIds, ["kept"])
    XCTAssertEqual(record.load(), ["kept": "skin.kept"])
  }

  /// The default install step, end to end: a real archive through a real library, with the N64 shelf's retarget.
  func testLibraryInstallStepInstallsAndRetargets() async throws {
    let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestCube", withExtension: "deltaskin", subdirectory: "Skins"))
    let packed = scratch.appendingPathComponent("Packed", isDirectory: true)
    try FileManager.default.copyItem(at: fixture, to: packed)
    let infoURL = packed.appendingPathComponent("info.json")
    let json = try String(contentsOf: infoURL, encoding: .utf8)
      .replacingOccurrences(of: "public.aoshuang.game.ngc", with: "com.rileytestut.delta.game.n64")
    try json.write(to: infoURL, atomically: true, encoding: .utf8)
    let archive = scratch.appendingPathComponent("n64.deltaskin")
    try Zip.zipFiles(paths: FileManager.default.contentsOfDirectory(at: packed, includingPropertiesForKeys: nil),
                     zipFilePath: archive, password: nil, progress: nil)

    let library = SkinLibrary(rootURL: scratch.appendingPathComponent("Skins"))
    let installer = SkinStoreInstaller(downloader: FakeDownloader(source: archive), record: record(),
                                       installStep: SkinStoreInstaller.libraryInstallStep(library))
    let n64 = try entry(id: SkinCatalogFixture.n64PackID, systems: ["n64"], url: "https://deltastyles.com/files/skins/551/x.deltaskin")

    await installer.install(n64)

    XCTAssertEqual(installer.state(for: n64), .installed)
    XCTAssertEqual(library.skins.map(\.id), ["com.joemattiello.icube.testcube-gamecube"])
    XCTAssertEqual(library.skins.first?.gameType, .gameCube)
    XCTAssertEqual(record().load(), [SkinCatalogFixture.n64PackID: "com.joemattiello.icube.testcube-gamecube"])
  }
}
#endif
