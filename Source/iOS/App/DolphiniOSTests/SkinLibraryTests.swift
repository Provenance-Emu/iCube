// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Combine
import UniformTypeIdentifiers
import XCTest
import Zip
@testable import iCube

@MainActor
final class SkinLibraryTests: XCTestCase {
  private static let fixtureIdentifier = "com.joemattiello.icube.testcube"
  private static let fixtureGameType = "public.aoshuang.game.ngc"
  private static let wiiGameType = "public.aoshuang.game.wii"

  private var scratch: URL!
  private var root: URL!

  private var fixture: URL {
    Bundle(for: Self.self).url(forResource: "TestCube", withExtension: "deltaskin", subdirectory: "Skins")!
  }

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SkinLibraryTests-\(UUID().uuidString)")
    root = scratch.appendingPathComponent("Skins")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  /// Zips a copy of the fixture whose info.json has the given game type and identifier.
  private func makeArchive(gameType: String = fixtureGameType, identifier: String = fixtureIdentifier,
                           nested: Bool = false, includeInfo: Bool = true) throws -> URL {
    let folder = scratch.appendingPathComponent("src-\(UUID().uuidString)/Packed", isDirectory: true)
    try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture, to: folder)
    if includeInfo {
      let infoURL = folder.appendingPathComponent("info.json")
      let json = try String(contentsOf: infoURL, encoding: .utf8)
        .replacingOccurrences(of: Self.fixtureGameType, with: gameType)
        .replacingOccurrences(of: Self.fixtureIdentifier, with: identifier)
      try json.write(to: infoURL, atomically: true, encoding: .utf8)
    } else {
      try FileManager.default.removeItem(at: folder.appendingPathComponent("info.json"))
    }
    let archive = scratch.appendingPathComponent("\(UUID().uuidString).deltaskin")
    let members = nested ? [folder] : try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    try Zip.zipFiles(paths: members, zipFilePath: archive, password: nil, progress: nil)
    return archive
  }

  /// What the library has left on disk; a root that was never created counts as empty.
  private func installedFolderNames() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
  }

  func testImportStoresSkinUnderItsIdentifier() throws {
    let library = SkinLibrary(rootURL: root)
    let skin = try library.importSkin(from: makeArchive())
    XCTAssertEqual(library.skins.count, 1)
    XCTAssertEqual(skin.id, Self.fixtureIdentifier)
    XCTAssertEqual(skin.name, "Test Cube")
    XCTAssertEqual(skin.gameType, .gameCube)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(Self.fixtureIdentifier)/info.json").path))
    XCTAssertEqual(skin.directory.standardizedFileURL, root.appendingPathComponent(Self.fixtureIdentifier).standardizedFileURL)
  }

  func testImportAcceptsInfoOneFolderDeep() throws {
    let library = SkinLibrary(rootURL: root)
    _ = try library.importSkin(from: makeArchive(nested: true))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(Self.fixtureIdentifier)/info.json").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(Self.fixtureIdentifier)/bg.png").path))
  }

  func testImportingSameIdentifierReplaces() throws {
    let library = SkinLibrary(rootURL: root)
    _ = try library.importSkin(from: makeArchive())
    _ = try library.importSkin(from: makeArchive())
    XCTAssertEqual(library.skins.count, 1)
    XCTAssertEqual(SkinLibrary(rootURL: root).skins.count, 1, "a fresh library lists what is on disk")
  }

  func testUnsupportedGameTypeThrowsAndLeavesNothing() throws {
    let library = SkinLibrary(rootURL: root)
    let archive = try makeArchive(gameType: "com.rileytestut.delta.game.n64")
    XCTAssertThrowsError(try library.importSkin(from: archive)) {
      XCTAssertEqual($0 as? SkinImportError, .unsupportedGameType("com.rileytestut.delta.game.n64"))
    }
    XCTAssertTrue(library.skins.isEmpty)
    XCTAssertEqual(installedFolderNames(), [])
  }

  func testArchiveWithoutInfoThrowsMissingInfo() throws {
    let library = SkinLibrary(rootURL: root)
    let archive = try makeArchive(includeInfo: false)
    XCTAssertThrowsError(try library.importSkin(from: archive)) {
      XCTAssertEqual($0 as? SkinImportError, .missingInfo)
    }
    XCTAssertEqual(installedFolderNames(), [])
  }

  func testNonArchiveThrowsUnreadable() throws {
    let library = SkinLibrary(rootURL: root)
    let bogus = scratch.appendingPathComponent("bogus.deltaskin")
    try Data("not a zip".utf8).write(to: bogus)
    XCTAssertThrowsError(try library.importSkin(from: bogus)) {
      XCTAssertEqual($0 as? SkinImportError, .unreadableArchive)
    }
  }

  func testPathTraversalIdentifierIsRefused() throws {
    let library = SkinLibrary(rootURL: root)
    let archive = try makeArchive(identifier: "../escape")
    XCTAssertThrowsError(try library.importSkin(from: archive)) {
      XCTAssertEqual($0 as? SkinImportError, .invalidIdentifier)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("escape").path))
  }

  func testZipSlipArchiveIsRefusedBeforeAnythingIsWritten() throws {
    let library = SkinLibrary(rootURL: root)
    // The unzip destination is two folders below the temporary directory, so this would land beside them.
    let escapeName = "SkinLibraryTests-escape-\(UUID().uuidString).txt"
    let escaped = FileManager.default.temporaryDirectory.appendingPathComponent(escapeName)
    defer { try? FileManager.default.removeItem(at: escaped) }
    let hostile = scratch.appendingPathComponent("hostile.deltaskin")
    try TestZipBuilder.build([
      .init(name: "../../\(escapeName)", contents: Data("owned".utf8)),
      .init(name: "info.json", contents: Data("{}".utf8))
    ]).write(to: hostile)
    XCTAssertThrowsError(try library.importSkin(from: hostile)) {
      XCTAssertEqual($0 as? SkinImportError, .unsafeArchive)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
    XCTAssertTrue(library.skins.isEmpty)
    XCTAssertEqual(installedFolderNames(), [])
  }

  func testReservedSelectionFileNameIsRefusedInAnyCase() throws {
    let library = SkinLibrary(rootURL: root)
    let archive = try makeArchive(identifier: "Selection.JSON")
    XCTAssertThrowsError(try library.importSkin(from: archive)) {
      XCTAssertEqual($0 as? SkinImportError, .invalidIdentifier)
    }
  }

  func testSelectionRoundTripsThroughFreshLibrary() throws {
    let library = SkinLibrary(rootURL: root)
    let skin = try library.importSkin(from: makeArchive())
    XCTAssertNil(library.selectedSkin(for: .gameCube, orientation: .portrait))
    library.select(skin, for: .gameCube, orientation: .portrait)
    XCTAssertEqual(library.selectedSkin(for: .gameCube, orientation: .portrait)?.id, skin.id)
    XCTAssertNil(library.selectedSkin(for: .gameCube, orientation: .landscape), "selection is per orientation")

    let reloaded = SkinLibrary(rootURL: root)
    XCTAssertEqual(reloaded.selectedSkin(for: .gameCube, orientation: .portrait)?.id, skin.id)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("selection.json").path))
    let stored = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("selection.json")))
    XCTAssertEqual(stored[TouchOverlayLayoutStore.key(.gameCube, .portrait)], skin.id)
  }

  func testSelectingNilClearsTheChoice() throws {
    let library = SkinLibrary(rootURL: root)
    let skin = try library.importSkin(from: makeArchive())
    library.select(skin, for: .gameCube, orientation: .portrait)
    library.select(nil, for: .gameCube, orientation: .portrait)
    XCTAssertNil(SkinLibrary(rootURL: root).selectedSkin(for: .gameCube, orientation: .portrait))
  }

  func testWiiSkinCannotBeSelectedForGameCube() throws {
    let library = SkinLibrary(rootURL: root)
    let wii = try library.importSkin(from: makeArchive(gameType: Self.wiiGameType, identifier: "com.joemattiello.icube.testwii"))
    XCTAssertEqual(wii.gameType, .wii)
    library.select(wii, for: .gameCube, orientation: .portrait)
    XCTAssertNil(library.selectedSkin(for: .gameCube, orientation: .portrait))
    library.select(wii, for: .wiiClassic, orientation: .landscape)
    XCTAssertEqual(library.selectedSkin(for: .wiiClassic, orientation: .landscape)?.id, wii.id)
  }

  func testDeleteRemovesFilesAndSelection() throws {
    let library = SkinLibrary(rootURL: root)
    let skin = try library.importSkin(from: makeArchive())
    library.select(skin, for: .gameCube, orientation: .portrait)
    try library.delete(skin)
    XCTAssertTrue(library.skins.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: skin.directory.path))
    XCTAssertNil(SkinLibrary(rootURL: root).selectedSkin(for: .gameCube, orientation: .portrait))
  }

  func testReimportKeepsExistingSelection() throws {
    let library = SkinLibrary(rootURL: root)
    let skin = try library.importSkin(from: makeArchive())
    library.select(skin, for: .gameCube, orientation: .portrait)
    _ = try library.importSkin(from: makeArchive())
    XCTAssertEqual(library.selectedSkin(for: .gameCube, orientation: .portrait)?.id, skin.id)
  }

  func testSelectionChangesPublishAndAnnounceThemselves() throws {
    let library = SkinLibrary(rootURL: root)
    let skin = try library.importSkin(from: makeArchive())
    var published = 0
    var announced = 0
    let sink = library.objectWillChange.sink { published += 1 }
    let observer = NotificationCenter.default.addObserver(forName: SkinLibrary.didChangeNotification, object: library, queue: nil) { _ in announced += 1 }
    defer {
      sink.cancel()
      NotificationCenter.default.removeObserver(observer)
    }
    library.select(skin, for: .gameCube, orientation: .portrait)
    XCTAssertEqual(published, 1)
    XCTAssertEqual(announced, 1)
    try library.delete(skin)
    XCTAssertGreaterThanOrEqual(announced, 2, "deleting the active skin tells a running game to rebuild its pads")
  }

  func testRepickingTheSameSkinDoesNotAnnounceAgain() throws {
    let library = SkinLibrary(rootURL: root)
    let skin = try library.importSkin(from: makeArchive())
    library.select(skin, for: .gameCube, orientation: .portrait)
    var announced = 0
    var published = 0
    let sink = library.objectWillChange.sink { published += 1 }
    let observer = NotificationCenter.default.addObserver(forName: SkinLibrary.didChangeNotification, object: library, queue: nil) { _ in announced += 1 }
    defer {
      sink.cancel()
      NotificationCenter.default.removeObserver(observer)
    }
    library.select(skin, for: .gameCube, orientation: .portrait)
    library.select(nil, for: .gameCube, orientation: .landscape)
    XCTAssertEqual(announced, 0)
    XCTAssertEqual(published, 0)
    library.select(nil, for: .gameCube, orientation: .portrait)
    XCTAssertEqual(announced, 1, "clearing a real pick still announces")
  }

  func testImporterAcceptsWhateverTypeTheExtensionsResolveTo() {
    for ext in ["deltaskin", "manicskin"] {
      let resolved = UTType(filenameExtension: ext)
      XCTAssertNotNil(resolved)
      XCTAssertTrue(resolved.map(SkinLibrary.archiveContentTypes.contains) ?? false, "\(ext) must be pickable even if another app owns its type")
    }
    XCTAssertTrue(SkinLibrary.archiveContentTypes.contains(.zip))
  }

  func testImportableArchivesAreSkinArchivesAndPlainZips() {
    XCTAssertTrue(SkinLibrary.isImportableArchive(URL(fileURLWithPath: "/tmp/a.deltaskin")))
    XCTAssertTrue(SkinLibrary.isImportableArchive(URL(fileURLWithPath: "/tmp/a.MANICSKIN")))
    XCTAssertTrue(SkinLibrary.isImportableArchive(URL(fileURLWithPath: "/tmp/a.zip")))
    XCTAssertFalse(SkinLibrary.isImportableArchive(URL(fileURLWithPath: "/tmp/a.png")))
    XCTAssertFalse(SkinLibrary.isImportableArchive(URL(string: "https://example.com/a.zip")!))
  }
}
#endif
