// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

/// Where the mod browser's two hand-offs go: a Riivolution pack to the pack installer, patch files to the
/// disc-patching sheet. Also what the browser offers once a pack is in.
@MainActor
final class LiveModInstallHandlerTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveModInstallHandlerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  private func writePack(named name: String) throws -> URL {
    let pack = root.appendingPathComponent("extracted/\(name)", isDirectory: true)
    let xmlFolder = pack.appendingPathComponent("riivolution", isDirectory: true)
    try FileManager.default.createDirectory(at: xmlFolder, withIntermediateDirectories: true)
    let xml = #"<wiidisc version="1"><options><section name="S"><option name="One"><choice name="On"/></option></section></options></wiidisc>"#
    try Data(xml.utf8).write(to: xmlFolder.appendingPathComponent("pack.xml"))
    return pack
  }

  func test_aPackGoesToTheInstallerAndTheSummaryComesBack() async throws {
    let sd = root.appendingPathComponent("Load/Riivolution", isDirectory: true)
    let handler = LiveModInstallHandler(packRoot: { sd }, presentPatches: { _, _ in })
    let message = try await handler.installRiivolutionPack(at: try writePack(named: "Newer"), named: "Newer SMBW")
    XCTAssertEqual(message, "Installed Riivolution pack Newer SMBW (1 option)")
    XCTAssertTrue(FileManager.default.fileExists(atPath: sd.appendingPathComponent("riivolution/pack.xml").path))
  }

  func test_aFolderWithoutAPackIsAnError() async {
    let sd = root.appendingPathComponent("sd")
    let handler = LiveModInstallHandler(packRoot: { sd }, presentPatches: { _, _ in })
    let empty = root.appendingPathComponent("empty", isDirectory: true)
    try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    do {
      _ = try await handler.installRiivolutionPack(at: empty, named: "Nothing")
      XCTFail("expected the install to fail")
    } catch {
      XCTAssertFalse(error.localizedDescription.isEmpty)
    }
  }

  func test_patchesGoToTheDiscPatchSheetWithTheSuggestedGame() async {
    let presented = expectation(description: "presented")
    var received: ([URL], String?)?
    let unused = root!
    let handler = LiveModInstallHandler(packRoot: { unused }, presentPatches: { patches, gameID in
      received = (patches, gameID)
      presented.fulfill()
    })
    let patch = root.appendingPathComponent("hack.xdelta")
    handler.presentDiscPatch([patch], suggestedGameID: "GALE01")
    await fulfillment(of: [presented], timeout: 2)
    XCTAssertEqual(received?.0, [patch])
    XCTAssertEqual(received?.1, "GALE01")
  }
}

/// A handler that records what the install model asks of it.
private struct RecordingHandler: ModInstallHandling {
  func installRiivolutionPack(at root: URL, named name: String) async throws -> String {
    "Installed \(name)"
  }

  func presentDiscPatch(_ patches: [URL], suggestedGameID: String?) {}
}

@MainActor
final class ModInstallModelPackOfferTests: XCTestCase {
  private func file() throws -> GameBananaFile {
    let json = #"{"_idRow": 1, "_sFile": "pack.zip", "_nFilesize": 10, "_sDownloadUrl": "https://gamebanana.com/dl/1"}"#
    return try JSONDecoder().decode(GameBananaFile.self, from: Data(json.utf8))
  }

  private func install(ownedGame: ModLibraryGame?) async throws -> ModInstallModel {
    let model = ModInstallModel(file: try file(), ownedGame: ownedGame, handler: RecordingHandler())
    model.installRiivolutionPack(root: URL(fileURLWithPath: "/tmp/pack"), named: "Newer")
    while model.isInstalling { await Task.yield() }
    return model
  }

  func test_aPackInstalledForALibraryGameOffersPlayWithMods() async throws {
    let model = try await install(ownedGame: ModLibraryGame(gameID: "SMNE01", title: "New Super Mario Bros. Wii", revision: 0))
    XCTAssertEqual(model.log, ["Installed Newer"])
    XCTAssertTrue(model.offerPlayWithMods)
  }

  func test_aPackInstalledWithoutAGameOffersNothing() async throws {
    let model = try await install(ownedGame: nil)
    XCTAssertEqual(model.log, ["Installed Newer"])
    XCTAssertFalse(model.offerPlayWithMods)
  }

  func test_playWithModsClosesTheBrowserThenAsksTheLibrary() async throws {
    let game = ModLibraryGame(gameID: "SMNE01", title: "New Super Mario Bros. Wii", revision: 0)
    let model = try await install(ownedGame: game)
    let presenter = ModBrowserPresenter.shared
    presenter.open(game: game)
    XCTAssertNotNil(presenter.request)

    var asked: [String] = []
    let observer = NotificationCenter.default.addObserver(forName: .DOLShowModsForGame, object: nil, queue: nil) { note in
      if let id = note.userInfo?[ModBrowserPresenter.gameIDKey] as? String { asked.append(id) }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    model.playWithMods()
    XCTAssertNil(presenter.request)
    XCTAssertTrue(asked.isEmpty, "the library cannot present a sheet while the browser still covers it")
    presenter.browserDidDismiss()
    XCTAssertEqual(asked, ["SMNE01"])
    presenter.browserDidDismiss()
    XCTAssertEqual(asked, ["SMNE01"], "one request, one answer")
  }
}
