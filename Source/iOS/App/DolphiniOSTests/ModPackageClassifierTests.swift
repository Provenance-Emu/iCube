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
}
