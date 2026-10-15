// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

/// Riivolution soft patching: descriptors written with relative paths, pack detection and install, and the launch
/// sheet's rules. The core's parser is not involved; the files these tests write are checked as plain JSON.
@MainActor
final class RiivolutionModsTests: XCTestCase {
  private var root: URL!
  private var sdRoot: URL { root.appendingPathComponent("Load/Riivolution", isDirectory: true) }
  private var software: URL { root.appendingPathComponent("Software", isDirectory: true) }

  private static let packXML = """
  <wiidisc version="1">
    <id game="SMN"/>
    <options>
      <section name="Newer">
        <option name="Newer SMBW" id="newer"><choice name="Enabled"><patch id="a"/></choice></option>
        <option name="Music"><choice name="On"><patch id="b"/></choice><choice name="Off"/></option>
      </section>
    </options>
    <patch id="a"/>
  </wiidisc>
  """

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("RiivolutionModsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: software, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: - Helpers

  private func put(_ text: String, at relative: String, in base: URL) throws {
    let url = base.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  private func extracted(_ name: String = "extracted") -> URL {
    root.appendingPathComponent(name, isDirectory: true)
  }

  private func entries(of folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
  }

  private func pack(selected: Int) -> RiivolutionPack {
    RiivolutionPack(
      xmlPath: sdRoot.appendingPathComponent("riivolution/newer.xml").path,
      rootPath: sdRoot.path + "/",
      options: [
        RiivolutionOption(sectionName: "Newer", optionID: "newer", name: "Newer SMBW", choices: ["Enabled"], selectedChoice: selected),
        RiivolutionOption(sectionName: "Newer", optionID: "", name: "Music", choices: ["On", "Off"], selectedChoice: 0),
      ]
    )
  }

  private func json(at url: URL) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }

  // MARK: - Relative paths

  func testRelativePathClimbsToASiblingFolder() {
    let mods = software.appendingPathComponent("Mods", isDirectory: true)
    XCTAssertEqual(ModDescriptorStore.relativePath(from: mods, to: software.appendingPathComponent("Game.iso").path), "../Game.iso")
    XCTAssertEqual(ModDescriptorStore.relativePath(from: mods, to: sdRoot.path + "/"), "../../Load/Riivolution/")
  }

  func testRelativePathInsideTheDirectoryHasNoClimb() {
    XCTAssertEqual(ModDescriptorStore.relativePath(from: software, to: software.appendingPathComponent("Game.iso").path), "Game.iso")
  }

  func testRelativePathTreatsPrivateVarAndVarAlike() throws {
    // /var is a symbolic link to /private/var on the Mac that hosts the simulator.
    let spelledPrivate = URL(fileURLWithPath: "/private/var/tmp/RiivolutionModsTests-\(UUID().uuidString)", isDirectory: true)
    let mods = spelledPrivate.appendingPathComponent("Software/Mods", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: spelledPrivate.appendingPathComponent("Load/Riivolution"), withIntermediateDirectories: true)
    } catch {
      throw XCTSkip("Cannot create a folder under /private/var/tmp: \(error)")
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: spelledPrivate) }
    let target = spelledPrivate.path.replacingOccurrences(of: "/private", with: "") + "/Load/Riivolution/"

    XCTAssertEqual(ModDescriptorStore.relativePath(from: mods, to: target), "../../Load/Riivolution/")
  }

  func testRelativePathStaysAbsoluteWhenNothingIsShared() {
    XCTAssertEqual(ModDescriptorStore.relativePath(from: URL(fileURLWithPath: "/a/b"), to: "/c/d.iso"), "/c/d.iso")
  }

  // MARK: - Descriptor

  func testDescriptorIsWrittenWithRelativePathsThatResolveBack() throws {
    let mods = ModDescriptorStore.libraryFolder(softwareFolder: software.path)
    let url = mods.appendingPathComponent("Newer.json")
    let base = software.appendingPathComponent("Game.iso").path

    try ModDescriptorStore.write(baseFile: base, displayName: "Game — Newer", packs: [pack(selected: 1)], to: url)

    let descriptor = try json(at: url)
    XCTAssertEqual(descriptor["type"] as? String, "dolphin-game-mod-descriptor")
    XCTAssertEqual(descriptor["display-name"] as? String, "Game — Newer")
    XCTAssertEqual(descriptor["base-file"] as? String, "../Game.iso")
    let patch = try XCTUnwrap(((descriptor["riivolution"] as? [String: Any])?["patches"] as? [[String: Any]])?.first)
    XCTAssertEqual(patch["xml"] as? String, "../../Load/Riivolution/riivolution/newer.xml")
    XCTAssertEqual(patch["root"] as? String, "../../Load/Riivolution/")

    // The core resolves each stored path against the descriptor's folder.
    let resolved = URL(fileURLWithPath: try XCTUnwrap(patch["xml"] as? String), relativeTo: mods).standardizedFileURL
    XCTAssertEqual(resolved.resolvingSymlinksInPath().path, sdRoot.appendingPathComponent("riivolution/newer.xml").resolvingSymlinksInPath().path)
  }

  func testDescriptorStoresEveryOptionByIDOrName() throws {
    let url = software.appendingPathComponent("Mods/Newer.json")
    try ModDescriptorStore.write(baseFile: software.appendingPathComponent("Game.iso").path, displayName: "x", packs: [pack(selected: 1)], to: url)

    let patch = try XCTUnwrap(((try json(at: url)["riivolution"] as? [String: Any])?["patches"] as? [[String: Any]])?.first)
    let options = try XCTUnwrap(patch["options"] as? [[String: Any]])
    XCTAssertEqual(options.count, 2)
    XCTAssertEqual(options[0]["option-id"] as? String, "newer")
    XCTAssertNil(options[0]["option-name"])
    XCTAssertEqual(options[0]["choice"] as? Int, 1)
    XCTAssertEqual(options[1]["option-name"] as? String, "Music")
    XCTAssertNil(options[1]["option-id"])
    XCTAssertEqual(options[1]["section-name"] as? String, "Newer")
  }

  func testDescriptorLeavesOutPacksWithNothingSelected() throws {
    let url = software.appendingPathComponent("Mods/Plain.json")
    try ModDescriptorStore.write(baseFile: software.appendingPathComponent("Game.iso").path, displayName: "x", packs: [pack(selected: 0)].filter(\.hasSelection), to: url)
    XCTAssertNil(try json(at: url)["riivolution"])
  }

  func testDescriptorNamesAreSafeAndUnique() throws {
    XCTAssertEqual(ModDescriptorStore.sanitizedFileName("Mario: Kart/Wii?"), "Mario Kart Wii")
    XCTAssertEqual(ModDescriptorStore.sanitizedFileName("  ...  "), "Mod")
    let mods = ModDescriptorStore.libraryFolder(softwareFolder: software.path)
    try put("{}", at: "Game.json", in: mods)
    XCTAssertEqual(ModDescriptorStore.uniqueURL(in: mods, name: "Game").lastPathComponent, "Game (2).json")
  }

  func testRunDescriptorsAreSweptWithTheirFolder() throws {
    let run = ModDescriptorStore.newRunURL(userFolder: root.path)
    try put("{}", at: "Cache/ModRuns/\(run.lastPathComponent)", in: root)
    XCTAssertTrue(FileManager.default.fileExists(atPath: run.path))
    ModDescriptorStore.sweepRuns(userFolder: root.path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: run.path))
    XCTAssertTrue(ModDescriptorStore.isDescriptor(path: run.path))
    XCTAssertFalse(ModDescriptorStore.isDescriptor(path: "/x/Game.iso"))
  }

  // MARK: - Pack detection

  func testPackIsFoundAtTheRootOfAnArchive() throws {
    try put(Self.packXML, at: "riivolution/newer.xml", in: extracted())
    XCTAssertEqual(RiivolutionPackInstaller.packRoots(in: extracted()).map(\.lastPathComponent), ["extracted"])
  }

  func testPackIsFoundOneFolderDown() throws {
    try put(Self.packXML, at: "Newer SMBW/riivolution/newer.xml", in: extracted())
    XCTAssertEqual(RiivolutionPackInstaller.packRoots(in: extracted()).map(\.lastPathComponent), ["Newer SMBW"])
  }

  func testPackFolderNameIsMatchedWithoutRegardToCase() throws {
    try put(Self.packXML, at: "Riivolution/newer.XML", in: extracted())
    XCTAssertEqual(RiivolutionPackInstaller.packRoots(in: extracted()).count, 1)
  }

  func testTwoFoldersDownAndXMLlessFoldersAreNotPacks() throws {
    try put(Self.packXML, at: "a/b/riivolution/newer.xml", in: extracted())
    try put("data", at: "riivolution/readme.txt", in: extracted("empty"))
    try put(Self.packXML, at: "__MACOSX/riivolution/newer.xml", in: extracted("mac"))
    XCTAssertTrue(RiivolutionPackInstaller.packRoots(in: extracted()).isEmpty)
    XCTAssertTrue(RiivolutionPackInstaller.packRoots(in: extracted("empty")).isEmpty)
    XCTAssertTrue(RiivolutionPackInstaller.packRoots(in: extracted("mac")).isEmpty)
  }

  // MARK: - Install

  func testInstallMergesIntoTheSDRootAndOverwritesSamePaths() throws {
    try put("old", at: "NewerSMBW/Hud.arc", in: sdRoot)
    try put("kept", at: "NewerSMBW/Extra.arc", in: sdRoot)
    try put(Self.packXML, at: "Newer/Riivolution/newer.xml", in: extracted())
    try put("new", at: "Newer/NewerSMBW/Hud.arc", in: extracted())
    try put("junk", at: "Newer/.DS_Store", in: extracted())
    try put("junk", at: "__MACOSX/Newer/._newer.xml", in: extracted())

    let summary = try RiivolutionPackInstaller.install(extractedFolder: extracted(), name: "Newer SMBW", into: sdRoot)

    XCTAssertEqual(summary, RiivolutionPackInstaller.Summary(packName: "Newer SMBW", optionCount: 2))
    XCTAssertEqual(try String(contentsOf: sdRoot.appendingPathComponent("NewerSMBW/Hud.arc"), encoding: .utf8), "new")
    XCTAssertEqual(try String(contentsOf: sdRoot.appendingPathComponent("NewerSMBW/Extra.arc"), encoding: .utf8), "kept")
    // The XML folder is renamed to lowercase; the directory listing, not fileExists, shows the real case.
    XCTAssertEqual(entries(of: sdRoot), ["NewerSMBW", "riivolution"])
    XCTAssertEqual(entries(of: sdRoot.appendingPathComponent("riivolution")), ["newer.xml"])
  }

  func testInstallRejectsASymbolicLinkAndMovesNothing() throws {
    try put(Self.packXML, at: "riivolution/newer.xml", in: extracted())
    try FileManager.default.createSymbolicLink(at: extracted().appendingPathComponent("link"), withDestinationURL: URL(fileURLWithPath: "/etc"))

    XCTAssertThrowsError(try RiivolutionPackInstaller.install(extractedFolder: extracted(), name: "x", into: sdRoot)) {
      XCTAssertEqual($0 as? ZipEntryScannerError, .unsafeEntry("link"))
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: sdRoot.path))
  }

  func testInstallThrowsWhenThereIsNoPack() throws {
    try put("x", at: "game.iso", in: extracted())
    XCTAssertThrowsError(try RiivolutionPackInstaller.install(extractedFolder: extracted(), name: "x", into: sdRoot))
  }

  func testSummaryMessageHandlesOneOption() {
    XCTAssertTrue(RiivolutionPackInstaller.Summary(packName: "P", optionCount: 1).message.contains("(1 option)"))
    XCTAssertTrue(RiivolutionPackInstaller.Summary(packName: "P", optionCount: 3).message.contains("(3 options)"))
  }

  // MARK: - Archive import

  private func archive(_ entries: [TestZipBuilder.Entry], as name: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try TestZipBuilder.build(entries).write(to: url)
    return url
  }

  func testAZippedPackInstallsInsteadOfEnteringTheLibrary() throws {
    let zip = try archive([
      .init(name: "Newer SMBW/"), .init(name: "Newer SMBW/riivolution/"),
      .init(name: "Newer SMBW/riivolution/newer.xml", contents: Data(Self.packXML.utf8)),
      .init(name: "Newer SMBW/NewerSMBW/Hud.arc", contents: Data("hud".utf8)),
    ], as: "Newer SMBW v1.3.zip")

    let result = ZipImportHelper.importArchive(atPath: zip.path, toFolder: software.path, riivolutionRoot: sdRoot)

    XCTAssertNil(result.errorMessage)
    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(result.importedCount, 0)
    XCTAssertEqual(result.installedPackMessage, RiivolutionPackInstaller.Summary(packName: "Newer SMBW v1.3", optionCount: 2).message)
    XCTAssertEqual(entries(of: sdRoot), ["NewerSMBW", "riivolution"])
    XCTAssertEqual(entries(of: software), [])
  }

  func testAnArchiveWithAPackAndADiscInstallsTheOneAndImportsTheOther() throws {
    let zip = try archive([
      .init(name: "riivolution/newer.xml", contents: Data(Self.packXML.utf8)),
      .init(name: "NewerSMBW/Hud.arc", contents: Data("hud".utf8)),
      .init(name: "NewerSMBW/Hud.bin", contents: Data("pack asset".utf8)),
      .init(name: "Game.iso", contents: Data("disc".utf8)),
    ], as: "Bundle.zip")

    let result = ZipImportHelper.importArchive(atPath: zip.path, toFolder: software.path, riivolutionRoot: sdRoot)

    XCTAssertNil(result.errorMessage)
    XCTAssertTrue(result.isSafeToDiscardArchive)
    XCTAssertEqual(result.importedCount, 1)
    XCTAssertNotNil(result.installedPackMessage)
    XCTAssertEqual(entries(of: software), ["Game.iso"])
    XCTAssertEqual(entries(of: sdRoot), ["NewerSMBW", "riivolution"])
    XCTAssertEqual(entries(of: sdRoot.appendingPathComponent("NewerSMBW")), ["Hud.arc", "Hud.bin"])
  }

  func testADiscBesideAWrappedPackIsImported() throws {
    let zip = try archive([
      .init(name: "Pack/riivolution/newer.xml", contents: Data(Self.packXML.utf8)),
      .init(name: "Games/Game.iso", contents: Data("disc".utf8)),
    ], as: "Bundle.zip")

    let result = ZipImportHelper.importArchive(atPath: zip.path, toFolder: software.path, riivolutionRoot: sdRoot)

    XCTAssertEqual(result.importedCount, 1)
    XCTAssertNotNil(result.installedPackMessage)
    XCTAssertEqual(entries(of: software), ["Game.iso"])
  }

  func testAPackWithADiscAlreadyInTheLibraryIsNotAnError() throws {
    try put("disc", at: "Game.iso", in: software)
    let zip = try archive([
      .init(name: "riivolution/newer.xml", contents: Data(Self.packXML.utf8)),
      .init(name: "Game.iso", contents: Data("disc".utf8)),
    ], as: "Bundle.zip")

    let result = ZipImportHelper.importArchive(atPath: zip.path, toFolder: software.path, riivolutionRoot: sdRoot)

    XCTAssertNil(result.errorMessage)
    XCTAssertEqual(result.skippedExistingCount, 1)
    XCTAssertNotNil(result.installedPackMessage)
  }

  func testAPackWhoseDiscCannotBeImportedReportsTheFailure() throws {
    let zip = try archive([
      .init(name: "riivolution/newer.xml", contents: Data(Self.packXML.utf8)),
      .init(name: "Game.iso", contents: Data("disc".utf8)),
    ], as: "Bundle.zip")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: software.path)
    addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.software.path) }

    let result = ZipImportHelper.importArchive(atPath: zip.path, toFolder: software.path, riivolutionRoot: sdRoot)

    XCTAssertNotNil(result.installedPackMessage)
    XCTAssertNotNil(result.errorMessage)
    XCTAssertTrue(result.hadFailures)
    XCTAssertFalse(result.isSafeToDiscardArchive)
  }

  func testAnArchiveWithAPackAndADiscIsRemovedOnlyAfterBothImport() throws {
    let zip = try archive([
      .init(name: "riivolution/newer.xml", contents: Data(Self.packXML.utf8)),
      .init(name: "Game.iso", contents: Data("disc".utf8)),
    ], as: "Bundle.zip")
    let inLibrary = software.appendingPathComponent("Bundle.zip")
    try FileManager.default.moveItem(at: zip, to: inLibrary)

    let result = ZipImportHelper.processArchiveInPlace(atPath: inLibrary.path, libraryFolder: software.path, riivolutionRoot: sdRoot)

    XCTAssertEqual(result?.importedCount, 1)
    XCTAssertEqual(entries(of: software), ["Game.iso"])
  }

  func testAnArchiveWhoseDiscFailsToImportIsKept() throws {
    let zip = try archive([
      .init(name: "riivolution/newer.xml", contents: Data(Self.packXML.utf8)),
      .init(name: "Game.iso", contents: Data("disc".utf8)),
    ], as: "Bundle.zip")
    let inLibrary = software.appendingPathComponent("Bundle.zip")
    try FileManager.default.moveItem(at: zip, to: inLibrary)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: software.path)
    addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: self.software.path) }

    let result = ZipImportHelper.processArchiveInPlace(atPath: inLibrary.path, libraryFolder: software.path, riivolutionRoot: sdRoot)

    XCTAssertNotNil(result?.installedPackMessage)
    XCTAssertEqual(result?.hadFailures, true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: inLibrary.path), "the only copy of the disc was deleted")
  }

  func testAPackArchiveWithAnEscapingPathIsRejectedAndInstallsNothing() throws {
    let escape = "riiv-escape-\(UUID().uuidString).txt"
    let escaped = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(escape)
    addTeardownBlock { try? FileManager.default.removeItem(at: escaped) }
    let zip = try archive([
      .init(name: "riivolution/newer.xml", contents: Data(Self.packXML.utf8)),
      .init(name: "../\(escape)", contents: Data("x".utf8)),
    ], as: "hostile.zip")

    let result = ZipImportHelper.importArchive(atPath: zip.path, toFolder: software.path, riivolutionRoot: sdRoot)

    XCTAssertEqual(result.errorMessage, ZipImportHelper.unsafeArchiveMessage)
    XCTAssertFalse(result.succeeded)
    XCTAssertFalse(FileManager.default.fileExists(atPath: escaped.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sdRoot.path))
  }

  func testAPackUploadedToTheLibraryIsConsumedNotRejected() throws {
    let zip = try archive([.init(name: "riivolution/newer.xml", contents: Data(Self.packXML.utf8))], as: "Pack.zip")
    try FileManager.default.moveItem(at: zip, to: software.appendingPathComponent("Pack.zip"))
    let rejected = ZipImportHelper.rejectedImportsFolder(forLibraryFolder: software.path)

    let batch = ZipImportHelper.processOrphanedArchives(inFolder: software.path, riivolutionRoot: sdRoot)

    XCTAssertEqual(batch.failedArchives, 0)
    XCTAssertEqual(batch.installedPackMessages.count, 1)
    XCTAssertEqual(entries(of: software), [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: rejected))
    XCTAssertEqual(ZipImportHelper.snackbarText(for: batch), batch.installedPackMessages.first)
    XCTAssertEqual(entries(of: sdRoot), ["riivolution"])
  }

  // MARK: - Models and launch sheet

  func testSectionsGroupAdjacentOptions() {
    var multi = pack(selected: 0)
    multi.options.append(RiivolutionOption(sectionName: "Extras", optionID: "", name: "Cheats", choices: ["On"], selectedChoice: 0))
    XCTAssertEqual(multi.sections, [RiivolutionSection(name: "Newer", optionIndices: [0, 1]), RiivolutionSection(name: "Extras", optionIndices: [2])])
    XCTAssertEqual(multi.title, "newer")
  }

  func testOnlyLocalDiscGamesOfferMods() {
    XCTAssertTrue(RiivolutionEligibility.isEligible(filePath: "/x/Game.iso", platform: DiscIOPlatform.gameCubeDisc.rawValue))
    XCTAssertTrue(RiivolutionEligibility.isEligible(filePath: "/x/Game.rvz", platform: DiscIOPlatform.wiiDisc.rawValue))
    XCTAssertFalse(RiivolutionEligibility.isEligible(filePath: "/x/Game.wad", platform: DiscIOPlatform.wiiWAD.rawValue))
    XCTAssertFalse(RiivolutionEligibility.isEligible(filePath: "/x/Game.dol", platform: DiscIOPlatform.elfOrDOL.rawValue))
    XCTAssertFalse(RiivolutionEligibility.isEligible(filePath: "webdav://nas/Game.iso", platform: DiscIOPlatform.wiiDisc.rawValue))
    XCTAssertFalse(RiivolutionEligibility.isEligible(filePath: "/x/Mods/Game.json", platform: DiscIOPlatform.wiiDisc.rawValue))
  }

  private func model(packs: [RiivolutionPack], saved: @escaping ([RiivolutionPack], String) -> Bool = { _, _ in true }) -> RiivolutionLaunchModel {
    let game = RiivolutionLaunchModel.Game(title: "NSMBW", gameID: "SMNE01", revision: 0, discNumber: 0, filePath: software.appendingPathComponent("NSMBW.iso").path)
    return RiivolutionLaunchModel(
      game: game, sdRoot: sdRoot, softwareFolder: software.path, userFolder: root.path,
      loadPacks: { _, _ in packs }, saveSelections: saved
    )
  }

  func testPlayNeedsAChoiceAndSavesSelectionsBeforeWritingARunDescriptor() async throws {
    var savedForGame: String?
    let subject = model(packs: [pack(selected: 0)]) { _, gameID in savedForGame = gameID; return true }
    await subject.load()
    XCTAssertFalse(subject.canLaunch)
    XCTAssertNil(subject.writeRunDescriptor())

    subject.select(choice: 1, option: 0, inPack: 0)
    XCTAssertTrue(subject.canLaunch)
    let url = try XCTUnwrap(subject.writeRunDescriptor())

    XCTAssertEqual(savedForGame, "SMNE01")
    XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, ModDescriptorStore.runsFolderName)
    XCTAssertEqual(try json(at: url)["base-file"] as? String, "../../Software/NSMBW.iso")
  }

  func testSelectIgnoresChoicesOutOfRange() async {
    let subject = model(packs: [pack(selected: 0)])
    await subject.load()
    subject.select(choice: 5, option: 0, inPack: 0)
    subject.select(choice: 1, option: 9, inPack: 0)
    subject.select(choice: 1, option: 0, inPack: 3)
    XCTAssertFalse(subject.canLaunch)
  }

  func testAddToLibraryWritesANamedDescriptorInTheModsFolder() async throws {
    let subject = model(packs: [pack(selected: 1)])
    await subject.load()
    XCTAssertEqual(subject.libraryName, "NSMBW — newer")

    let first = try XCTUnwrap(subject.writeLibraryDescriptor())
    let second = try XCTUnwrap(subject.writeLibraryDescriptor())
    subject.customLibraryName = "  My Newer  "
    let third = try XCTUnwrap(subject.writeLibraryDescriptor())

    XCTAssertEqual([first, second, third].map(\.lastPathComponent), ["NSMBW — newer.json", "NSMBW — newer (2).json", "My Newer.json"])
    XCTAssertEqual(first.deletingLastPathComponent().path, ModDescriptorStore.libraryFolder(softwareFolder: software.path).path)
    XCTAssertEqual(try json(at: third)["display-name"] as? String, "My Newer")
    XCTAssertEqual(try json(at: first)["base-file"] as? String, "../NSMBW.iso")
  }
}
