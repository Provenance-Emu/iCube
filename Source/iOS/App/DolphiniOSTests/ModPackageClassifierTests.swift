// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class ModPackageClassifierTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("ModClassifier-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: root)
  }

  @discardableResult
  private func write(_ path: String, _ contents: String = "x") throws -> URL {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    return url
  }

  private func classify(gameID: String? = nil) -> ModPackageClassification {
    ModPackageClassifier.classify(extractedRoot: root, gameID: gameID)
  }

  private func path(_ url: URL) -> String {
    let base = root.standardizedFileURL.resolvingSymlinksInPath().path
    return url.standardizedFileURL.resolvingSymlinksInPath().path.replacingOccurrences(of: base, with: "")
  }

  func testRiivolutionPackAtTheTop() throws {
    try write("riivolution/Newer.xml")
    try write("Newer/Stage/a.arc")
    let kinds = classify().kinds
    XCTAssertEqual(kinds.count, 1)
    guard case .riivolution(let packRoot) = kinds[0] else { return XCTFail("\(kinds)") }
    XCTAssertEqual(path(packRoot), "")
  }

  func testRiivolutionPackOneFolderDown() throws {
    try write("MyPack/Riivolution/pack.xml")
    guard case .riivolution(let packRoot) = classify().kinds[0] else { return XCTFail() }
    XCTAssertEqual(path(packRoot), "/MyPack")
  }

  func testFilesInsideARiivolutionPackAreNotClassifiedAgain() throws {
    try write("riivolution/pack.xml")
    try write("pack/patch.ips")
    try write("pack/Textures/GALE01/tex1_64x64_a_b_9.png")
    try write("pack/codes.ini", "[Gecko]\n$A\n04000000 00000000\n")
    XCTAssertEqual(classify().kinds.count, 1)
  }

  func testPatchesBecomeADiscPatchWithTheSuggestedGame() throws {
    try write("Melee 64/patch.xdelta")
    try write("Melee 64/xdeltaUI/xdeltaUI.exe")
    try write("readme.txt", "hello")
    let result = classify(gameID: "galp01")
    XCTAssertEqual(result.kinds.count, 1)
    guard case .discPatch(let patches, let suggested) = result.kinds[0] else { return XCTFail("\(result.kinds)") }
    XCTAssertEqual(patches.map(\.lastPathComponent), ["patch.xdelta"])
    XCTAssertEqual(suggested, "GALP01")
    XCTAssertEqual(result.skippedPrograms, ["Melee 64/xdeltaUI/xdeltaUI.exe"])
  }

  func testEveryPatchFormatIsRecognised() throws {
    for name in ["a.xdelta", "b.vcdiff", "c.bps", "d.IPS", "e.ups", "f.ppf"] { try write(name) }
    guard case .discPatch(let patches, let suggested) = classify().kinds[0] else { return XCTFail() }
    XCTAssertEqual(patches.count, 6)
    XCTAssertNil(suggested)
  }

  func testTexturePackUnderLoadTextures() throws {
    try write("Load/Textures/RMCP01/tex1_64x64_aa_bb_9.png")
    try write("Load/Textures/RMCP01/sub/tex1_32x32_cc_dd_9.dds")
    let kinds = classify().kinds
    XCTAssertEqual(kinds.count, 1)
    guard case .textures(let id, let packRoot) = kinds[0] else { return XCTFail("\(kinds)") }
    XCTAssertEqual(id, "RMCP01")
    XCTAssertEqual(path(packRoot), "/Load/Textures/RMCP01")
  }

  func testThreeCharacterRegionFreeFolderUnderTextures() throws {
    try write("Textures/RMC/tex1_64x64_aa_bb_9.png")
    guard case .textures(let id, _) = classify().kinds[0] else { return XCTFail() }
    XCTAssertEqual(id, "RMC")
  }

  func testBareGameIDFolder() throws {
    try write("pack/GALE01/tex1_64x64_aa_bb_9.png")
    guard case .textures(let id, let packRoot) = classify().kinds[0] else { return XCTFail() }
    XCTAssertEqual(id, "GALE01")
    XCTAssertEqual(path(packRoot), "/pack/GALE01")
  }

  func testTwoGamesInOnePack() throws {
    try write("Textures/GALE01/tex1_a.png")
    try write("Textures/GALP01/tex1_a.png")
    let ids = classify().kinds.compactMap { kind -> String? in
      if case .textures(let id, _) = kind { return id }
      return nil
    }
    XCTAssertEqual(ids, ["GALE01", "GALP01"])
  }

  func testGameIDMarkerFileNamesTheFolder() throws {
    try write("HD Pack/GALE01.txt")
    try write("HD Pack/tex1_64x64_aa_bb_9.png")
    guard case .textures(let id, let packRoot) = classify().kinds[0] else { return XCTFail() }
    XCTAssertEqual(id, "GALE01")
    XCTAssertEqual(path(packRoot), "/HD Pack")
  }

  func testLooseTexturesUseTheBrowsedGame() throws {
    try write("pack/tex1_64x64_aa_bb_9.png")
    try write("pack/more/tex1_32x32_cc_dd_9.png")
    guard case .textures(let id, let packRoot) = classify(gameID: "GALE01").kinds[0] else { return XCTFail() }
    XCTAssertEqual(id, "GALE01")
    XCTAssertEqual(path(packRoot), "/pack")
  }

  func testLooseTexturesWithoutAGameAreUnsupported() throws {
    try write("pack/tex1_64x64_aa_bb_9.png")
    guard case .unsupported = classify().kinds[0] else { return XCTFail() }
  }

  func testPlainImagesAreNotTextures() throws {
    try write("Preview/screenshot.png")
    guard case .unsupported = classify().kinds[0] else { return XCTFail() }
  }

  func testReadmeFolderIsNotAGameID() throws {
    try write("README/notes.png")
    guard case .unsupported = classify().kinds[0] else { return XCTFail() }
  }

  func testGeckoIniAndTxtAreRecognised() throws {
    try write("codes/GALE01.ini", "[Gecko]\n$Infinite Shield [Me]\n04000000 00000001\n")
    try write("codes/extra.txt", "$Other\n04000000 00000002\n")
    try write("codes/notes.txt", "just a readme")
    let files = classify().kinds.compactMap { kind -> String? in
      if case .gecko(let file) = kind { return file.lastPathComponent }
      return nil
    }
    XCTAssertEqual(files, ["GALE01.ini", "extra.txt"])
  }

  func testIniWithoutGeckoIsIgnored() throws {
    try write("settings.ini", "[Core]\nCPUCore = 1\n")
    guard case .unsupported = classify().kinds[0] else { return XCTFail() }
  }

  func testArchiveWithSeveralKindsReturnsAllOfThem() throws {
    try write("patch.xdelta")
    try write("Textures/GALE01/tex1_a.png")
    try write("codes.ini", "[Gecko]\n$A\n04000000 00000000\n")
    try write("pack/riivolution/p.xml")
    let kinds = classify().kinds
    XCTAssertEqual(kinds.count, 4)
    XCTAssertTrue(kinds.contains { if case .riivolution = $0 { return true } else { return false } })
    XCTAssertTrue(kinds.contains { if case .discPatch = $0 { return true } else { return false } })
    XCTAssertTrue(kinds.contains { if case .textures = $0 { return true } else { return false } })
    XCTAssertTrue(kinds.contains { if case .gecko = $0 { return true } else { return false } })
  }

  func testDiscImagesRefuseTheWholeArchive() throws {
    for name in ["iso", "gcm", "rvz", "wbfs", "wia", "gcz", "ciso", "nkit"] {
      try? FileManager.default.removeItem(at: root)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try write("patch.xdelta")
      try write("game.\(name)")
      let kinds = classify().kinds
      XCTAssertEqual(kinds.count, 1, name)
      guard case .unsupported(let reason) = kinds[0] else { return XCTFail(name) }
      XCTAssertTrue(reason.contains("game.\(name)"))
    }
  }

  func testProgramsAloneAreUnsupportedAndListed() throws {
    try write("Patcher.exe")
    try write("install.sh")
    let result = classify()
    guard case .unsupported = result.kinds[0] else { return XCTFail() }
    XCTAssertEqual(Set(result.skippedPrograms), ["Patcher.exe", "install.sh"])
  }

  func testNestedArchiveHasAClearReason() throws {
    try write("inner.zip")
    guard case .unsupported(let reason) = classify().kinds[0] else { return XCTFail() }
    XCTAssertTrue(reason.contains("inner.zip"))
  }

  func testMacOSLeftoversAreIgnored() throws {
    try write("__MACOSX/._patch.xdelta")
    try write(".DS_Store")
    try write("._junk.ini", "[Gecko]\n$A\n04000000 00000000\n")
    guard case .unsupported = classify().kinds[0] else { return XCTFail() }
  }

  func testEmptyFolderIsUnsupported() {
    XCTAssertEqual(classify().kinds.count, 1)
    guard case .unsupported = classify().kinds[0] else { return XCTFail() }
  }

  func testSymlinksAreNotFollowed() throws {
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("ModClassifierOutside-\(UUID().uuidString)")
    try Data("x".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("evil.xdelta"), withDestinationURL: outside)
    guard case .unsupported = classify().kinds[0] else { return XCTFail() }
  }

  // MARK: - Game files

  private func gameFiles(_ kinds: [ModPackageKind]) -> ModGameFilePack? {
    for case .gameFiles(let pack) in kinds { return pack }
    return nil
  }

  /// The layout of GameBanana's "Wario & Waluigi over Yellow/Blue Toad": disc archives and a note, no XML.
  func testLooseDiscFilesBecomeOneGroupPerFolder() throws {
    try write("Cinematic Model/KBB.arc")
    try write("Cinematic Model/KYB.arc")
    try write("Middle Flag/middle_flag.arc")
    try write("Credits.txt", "Thanks")
    try write("K_rcha.arc")
    try write("Kinopio.arc")
    let kinds = classify(gameID: "SMNE01").kinds
    XCTAssertEqual(kinds.count, 1)
    let pack = try XCTUnwrap(gameFiles(kinds))
    XCTAssertEqual(pack.groups.map(\.name), ["", "Cinematic Model", "Middle Flag"])
    XCTAssertEqual(pack.groups.map(\.files), [["K_rcha.arc", "Kinopio.arc"], ["KBB.arc", "KYB.arc"], ["middle_flag.arc"]])
    XCTAssertEqual(pack.groups.map(\.mapping), [.byName, .byName, .byName])
    XCTAssertEqual(path(pack.groups[1].directory), "/Cinematic Model")
    XCTAssertEqual(pack.fileCount, 5)
  }

  func testAFilesFolderMirrorsTheDisc() throws {
    try write("Linkle_v2-1/files/res/Object/Link.arc")
    let pack = try XCTUnwrap(gameFiles(classify().kinds))
    XCTAssertEqual(pack.groups.count, 1)
    XCTAssertEqual(pack.groups[0].mapping, .discTree)
    XCTAssertEqual(pack.groups[0].name, "Linkle_v2-1")
    XCTAssertEqual(pack.groups[0].files, ["res/Object/Link.arc"])
    XCTAssertEqual(path(pack.groups[0].directory), "/Linkle_v2-1/files")
  }

  /// Mario Kart: Double Dash!! patcher mods put files for inside `MRAM.arc` in a folder of that name.
  func testFilesForInsideADiscArchiveAreRefusedWithTheArchiveNamed() throws {
    try write("files/MRAM.arc/mram/driver/mario/driver.bmd")
    try write("files/race2d.arc/mram_race2d/timg/teresa.bti")
    try write("modinfo.ini", "name = x")
    let kinds = classify().kinds
    XCTAssertNil(gameFiles(kinds))
    guard case .unsupported(let reason) = kinds[0] else { return XCTFail("\(kinds)") }
    XCTAssertTrue(reason.contains("MRAM.arc"), reason)
  }

  func testALooseProgramReplacesTheMainExecutable() throws {
    try write("widescreen_USA.dol")
    let pack = try XCTUnwrap(gameFiles(classify().kinds))
    XCTAssertEqual(pack.groups.map(\.mapping), [.mainExecutable])
    XCTAssertEqual(pack.groups[0].files, ["widescreen_USA.dol"])
  }

  func testSaveFilesAreNamedAsSavesNotGameFiles() throws {
    try write("Unpacked/banner.bin")
    try write("Unpacked/rksys.dat")
    guard case .unsupported(let reason) = classify().kinds[0] else { return XCTFail("expected a refusal") }
    XCTAssertTrue(reason.contains("banner.bin"), reason)
    try FileManager.default.removeItem(at: root.appendingPathComponent("Unpacked"))
    try write("01-GM4E-MarioKart Double Dash!!.gci")
    XCTAssertEqual(classify().kinds.count, 1)
    guard case .unsupported(let gciReason) = classify().kinds[0] else { return XCTFail("expected a refusal") }
    XCTAssertTrue(gciReason.contains(".gci"), gciReason)
  }

  func testGameFilesSitBesideTexturesAndCodes() throws {
    try write("Object/mario.arc")
    try write("Textures/SMNE01/tex1_64x64_aa_bb_9.png")
    try write("codes.ini", "[Gecko]\n$A\n04000000 00000000\n")
    let kinds = classify().kinds
    XCTAssertEqual(kinds.count, 3)
    XCTAssertEqual(gameFiles(kinds)?.groups.map(\.files), [["mario.arc"]])
  }

  func testImagesNotesAndSourceFilesAreNotGameFiles() throws {
    try write("Maya/SM64_MKDD.mb")
    try write("Model/SM64_MKDD.dae")
    try write("Model/textures/mario_all.png")
    guard case .unsupported(let reason) = classify().kinds[0] else { return XCTFail("expected a refusal") }
    XCTAssertTrue(reason.contains(".mb") && reason.contains(".dae") && reason.contains(".png"), reason)
  }

  func testADownloadThatIsOnlyANoteSaysSo() throws {
    try write("OPEN ME.txt", "Download at example.org")
    guard case .unsupported(let reason) = classify().kinds[0] else { return XCTFail("expected a refusal") }
    XCTAssertTrue(reason.contains("OPEN ME.txt"), reason)
  }

  /// "XBOX, Switch & PlayStation UI for NSMBWii" ships `SMNP01/Load/Textures/SMN/…`.
  func testTheFolderUnderTexturesWinsOverAGameIDFolderAboveIt() throws {
    try write("SMNP01/Load/Textures/SMN/tex1_256x256_7b53229a3b86fede_5.png")
    let kinds = classify().kinds
    XCTAssertEqual(kinds.count, 1)
    guard case .textures(let id, let packRoot) = kinds[0] else { return XCTFail("\(kinds)") }
    XCTAssertEqual(id, "SMN")
    XCTAssertEqual(path(packRoot), "/SMNP01/Load/Textures/SMN")
  }

  func testKeepingOnlyWhatTheDiscHasDropsEmptyGroups() throws {
    try write("Sans (Shoes)/FitNess00.pac")
    try write("Sans (Shoes)/FitNessXX(Shoes).pcs")
    try write("Raw data/advsv0.bin")
    try write("files/sound/extra.brstm")
    let pack = try XCTUnwrap(gameFiles(classify().kinds))
    let (kept, leftOut) = pack.keeping(discFileNames: ["fitness00.pac", "common.pac"])
    // A `files` tree is placed at its own paths, so it needs no namesake on the disc.
    XCTAssertEqual(kept.groups.map(\.name), ["", "Sans (Shoes)"])
    XCTAssertEqual(kept.groups.map(\.files), [["sound/extra.brstm"], ["FitNess00.pac"]])
    XCTAssertEqual(leftOut.sorted(), ["FitNessXX(Shoes).pcs", "advsv0.bin"])
    XCTAssertTrue(pack.keeping(discFileNames: []).pack.groups.allSatisfy { $0.mapping == .discTree })
  }

  // MARK: - Riivolution XML beside its folder

  /// "SMG: No Gravity Edition" ships `Pack.xml` next to the `Pack/` folder, with no `riivolution/`.
  func testARiivolutionXMLOutsideItsFolderIsStillAPack() throws {
    try write("No Gravity v1.0/SMG1 No Gravity.xml", #"<wiidisc version="1" root=""><id game="RMG" /></wiidisc>"#)
    try write("No Gravity v1.0/SMG1 No Gravity/StageData/a.arc")
    let kinds = classify().kinds
    XCTAssertEqual(kinds.count, 1)
    guard case .riivolution(let packRoot) = kinds[0] else { return XCTFail("\(kinds)") }
    XCTAssertEqual(path(packRoot), "/No Gravity v1.0")

    try ModPackageClassifier.gatherLooseRiivolutionXMLs(in: packRoot)
    XCTAssertTrue(FileManager.default.fileExists(atPath: packRoot.appendingPathComponent("riivolution/SMG1 No Gravity.xml").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: packRoot.appendingPathComponent("SMG1 No Gravity.xml").path))
    // A second call, or a pack that was laid out properly, changes nothing.
    try ModPackageClassifier.gatherLooseRiivolutionXMLs(in: packRoot)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: packRoot.appendingPathComponent("riivolution").path), ["SMG1 No Gravity.xml"])
  }

  func testAnXMLThatIsNotRiivolutionIsNotAPack() throws {
    try write("layout.xml", "<layout><pane /></layout>")
    try write("Object/mario.arc")
    let kinds = classify().kinds
    XCTAssertEqual(kinds.count, 1)
    XCTAssertNotNil(gameFiles(kinds))
  }
}
