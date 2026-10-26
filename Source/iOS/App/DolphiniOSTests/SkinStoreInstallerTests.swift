// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Combine
import SkinCatalogKit
import SkinKitManager
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

  private func installed(id: String = "x") -> SkinStoreInstaller.InstallResult {
    .installed(identifier: id)
  }

  /// The store's installer with a scripted download and install step, wired like the app's (policy, wording).
  private func makeInstaller(downloader: any SkinStoreDownloading, record: SkinStoreInstalledRecord? = nil,
                             installStep: @escaping SkinStoreInstaller.InstallStep) -> SkinStoreInstaller {
    SkinStoreInstaller(policy: .iCube, downloader: downloader, record: record ?? self.record(), appName: "iCube",
                       notInstallableMessage: SkinStoreMessages.notInstallable, describeError: SkinStoreMessages.describe,
                       installStep: installStep)
  }

  private func entry(id: String = SkinCatalogFixture.gameCubePocketID, systems: [String] = ["gamecube"],
                     url: String = "https://deltastyles.com/files/skins/760/gamecubepocket.manicskin") throws -> SkinCatalogEntry {
    try SkinCatalogEntry(id: id, name: "GameCube Pocket", systems: systems, downloadURL: XCTUnwrap(URL(string: url)))
  }

  func testSuccessfulInstallRecordsTheCatalogId() async throws {
    var seen: [(file: String, section: SkinStoreSection, fileExists: Bool)] = []
    let installer = makeInstaller(downloader: FakeDownloader(), record: record(), installStep: { file, section in
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
    let first = makeInstaller(downloader: FakeDownloader(), record: record(), installStep: { _, _ in self.installed() })
    let skin = try entry()
    await first.install(skin)
    let second = makeInstaller(downloader: FakeDownloader(), record: record(), installStep: { _, _ in
      XCTFail("must not install")
      return self.installed()
    })
    XCTAssertEqual(second.state(for: skin), .installed)
  }

  func testDownloadFailureSurfacesMessage() async throws {
    let installer = makeInstaller(downloader: FakeDownloader(error: URLSessionSkinStoreDownloader.HTTPStatusError(statusCode: 404)),
                                  record: record(), installStep: { _, _ in
      XCTFail("install must not run after a failed download")
      return self.installed()
    })
    let skin = try entry()
    await installer.install(skin)
    XCTAssertEqual(installer.state(for: skin), .failed(message: SkinStoreMessages.describe(URLSessionSkinStoreDownloader.HTTPStatusError(statusCode: 404))))
    XCTAssertFalse(installer.installedIds.contains(skin.id))
  }

  /// A dead link that answers HTML with 200 reaches the library as a non-archive.
  func testInstallStepFailureSurfacesMessage() async throws {
    let installer = makeInstaller(downloader: FakeDownloader(), record: record(),
                                  installStep: { _, _ in throw SkinImportError.unreadableArchive })
    let skin = try entry()
    await installer.install(skin)
    XCTAssertEqual(installer.state(for: skin), .failed(message: SkinImportError.describe(SkinImportError.unreadableArchive)))
    XCTAssertEqual(record().load(), [:])
  }

  func testStatesPassThroughDownloadingAndInstalling() async throws {
    var observed: [SkinStoreInstallState] = []
    let installer = makeInstaller(downloader: FakeDownloader(), record: record(), installStep: { _, _ in self.installed() })
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
    let installer = makeInstaller(downloader: FakeDownloader(error: CancellationError()), record: record(),
                                  installStep: { _, _ in self.installed() })
    let skin = try entry()
    await installer.install(skin)
    XCTAssertEqual(installer.state(for: skin), .idle)
  }

  func testTemporaryDownloadFolderIsRemoved() async throws {
    var downloadedTo: URL?
    let installer = makeInstaller(downloader: FakeDownloader(), record: record(), installStep: { file, _ in
      downloadedTo = file
      return self.installed()
    })
    await installer.install(try entry())
    let folder = try XCTUnwrap(downloadedTo).deletingLastPathComponent()
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
  }

  func testHiddenEntryFailsWithoutDownloading() async throws {
    let installer = makeInstaller(downloader: FakeDownloader(error: URLError(.badURL)), record: record(),
                                  installStep: { _, _ in self.installed() })
    let zip = try entry(id: SkinCatalogFixture.n64ZipID, systems: ["n64"], url: "https://deltastyles.com/files/skins/758/x.zip")
    await installer.install(zip)
    guard case .failed = installer.state(for: zip) else { return XCTFail("a .zip entry must not install") }
  }

  func testReconcileForgetsDeletedSkins() async throws {
    let record = record()
    record.markInstalled(catalogId: "kept", skinIdentifier: "skin.kept")
    record.markInstalled(catalogId: "deleted", skinIdentifier: "skin.deleted")
    let installer = makeInstaller(downloader: FakeDownloader(), record: record, installStep: { _, _ in self.installed() })
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
    let installer = makeInstaller(downloader: FakeDownloader(source: archive), record: record(),
                                  installStep: SkinStoreInstaller.libraryInstallStep(library, policy: .iCube))
    let n64 = try entry(id: SkinCatalogFixture.n64PackID, systems: ["n64"], url: "https://deltastyles.com/files/skins/551/x.deltaskin")

    await installer.install(n64)

    XCTAssertEqual(installer.state(for: n64), .installed)
    XCTAssertEqual(library.skins.map(\.id), ["com.joemattiello.icube.testcube-gamecube"])
    XCTAssertEqual(library.skins.first?.gameType, .gameCube)
    XCTAssertEqual(record().load(), [SkinCatalogFixture.n64PackID: "com.joemattiello.icube.testcube-gamecube"])
  }

  /// A player who installed from the store before the move: `store.json` in the old format and the skin's folder in
  /// the library. The new installer must read the record as it is, show the entry installed, and keep it through a
  /// reconcile against the library's skins.
  func testExistingStoreRecordStillMarksTheEntryInstalled() throws {
    let root = scratch.appendingPathComponent("Skins", isDirectory: true)
    let folder = root.appendingPathComponent("com.joemattiello.icube.testcube", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestCube", withExtension: "deltaskin", subdirectory: "Skins")),
                                     to: folder)
    // Written by the previous release's `SkinStoreInstalledRecord`: a flat JSON object, beside `selection.json`.
    let oldRecord = #"{"\#(SkinCatalogFixture.gameCubePocketID)":"com.joemattiello.icube.testcube"}"#
    try Data(oldRecord.utf8).write(to: root.appendingPathComponent(SkinLibrary.storeRecordFileName))

    let library = SkinLibrary(rootURL: root)
    let installer = SkinStoreInstaller.iCube(library: library, record: .iCube(rootURL: root))
    let skin = try entry()

    XCTAssertEqual(installer.state(for: skin), .installed)
    installer.reconcileInstalled(with: Set(library.skins.map(\.id)))
    XCTAssertEqual(installer.state(for: skin), .installed, "the skin is in the library, so the record stays")
    XCTAssertEqual(SkinStoreInstalledRecord.iCubeFileName, SkinLibrary.storeRecordFileName, "SkinKit's record file is iCube's")

    try library.delete(XCTUnwrap(library.skins.first))
    installer.reconcileInstalled(with: Set(library.skins.map(\.id)))
    XCTAssertEqual(installer.state(for: skin), .idle, "a deleted skin is offered again")
  }

  func testNotInstallableAndCatalogMessagesUseICubeWording() {
    XCTAssertEqual(SkinStoreMessages.notInstallable("Foo"), "Foo isn't a skin iCube can install.")
    XCTAssertEqual(SkinStoreMessages.describe(SkinCatalogError.httpStatus(503)), "The skin catalog server answered with HTTP 503.")
    XCTAssertEqual(SkinStoreMessages.describe(SkinImportError.missingInfo), SkinImportError.describe(SkinImportError.missingInfo))
  }
}
#endif
