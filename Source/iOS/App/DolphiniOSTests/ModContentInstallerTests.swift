// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class ModContentInstallerTests: XCTestCase {
  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ModInstall-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: scratch)
  }

  private func makeFile(_ relative: String, in base: URL, contents: String = "x") throws {
    let url = base.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
  }

  // MARK: - Textures

  func testTexturesCopyIntoTheGameFolderKeepingLayout() throws {
    let pack = scratch.appendingPathComponent("pack")
    try makeFile("tex1_a.png", in: pack)
    try makeFile("sub/tex1_b.dds", in: pack)
    try makeFile(".DS_Store", in: pack)
    try makeFile("__MACOSX/._tex1_a.png", in: pack)
    let textures = scratch.appendingPathComponent("Textures")
    let result = try ModContentInstaller.installTextures(from: pack, gameID: "GALE01", texturesRoot: textures)
    XCTAssertEqual(result.filesCopied, 2)
    XCTAssertEqual(result.destination.lastPathComponent, "GALE01")
    XCTAssertTrue(FileManager.default.fileExists(atPath: textures.appendingPathComponent("GALE01/sub/tex1_b.dds").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: textures.appendingPathComponent("GALE01/.DS_Store").path))
  }

  func testOnlyTexturesAndMarkersAreCopied() throws {
    let pack = scratch.appendingPathComponent("pack")
    try makeFile("tex1_a.png", in: pack)
    try makeFile("GALE01.txt", in: pack)
    try makeFile("all.txt", in: pack)
    try makeFile("Patcher.exe", in: pack)
    try makeFile("patch.xdelta", in: pack)
    try makeFile("readme.txt", in: pack)
    let textures = scratch.appendingPathComponent("Textures")
    let result = try ModContentInstaller.installTextures(from: pack, gameID: "GALE01", texturesRoot: textures)
    XCTAssertEqual(result.filesCopied, 3)
    let copied = try FileManager.default.contentsOfDirectory(atPath: result.destination.path).sorted()
    XCTAssertEqual(copied, ["GALE01.txt", "all.txt", "tex1_a.png"])
  }

  func testReinstallingOverwritesInsteadOfFailing() throws {
    let pack = scratch.appendingPathComponent("pack")
    try makeFile("tex1_a.png", in: pack, contents: "new")
    let textures = scratch.appendingPathComponent("Textures")
    try makeFile("GALE01/tex1_a.png", in: textures, contents: "old")
    _ = try ModContentInstaller.installTextures(from: pack, gameID: "GALE01", texturesRoot: textures)
    let text = try String(contentsOf: textures.appendingPathComponent("GALE01/tex1_a.png"), encoding: .utf8)
    XCTAssertEqual(text, "new")
  }

  func testGameIDCannotEscapeTheTexturesFolder() throws {
    let pack = scratch.appendingPathComponent("pack")
    try makeFile("tex1_a.png", in: pack)
    XCTAssertThrowsError(try ModContentInstaller.installTextures(from: pack, gameID: "../evil", texturesRoot: scratch))
    XCTAssertThrowsError(try ModContentInstaller.installTextures(from: pack, gameID: "", texturesRoot: scratch))
  }

  func testEmptyPackThrows() throws {
    let pack = scratch.appendingPathComponent("empty")
    try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
    XCTAssertThrowsError(try ModContentInstaller.installTextures(from: pack, gameID: "GALE01", texturesRoot: scratch))
  }

  func testSymlinkedFilesAreNotCopied() throws {
    let pack = scratch.appendingPathComponent("pack")
    try makeFile("tex1_a.png", in: pack)
    let secret = scratch.appendingPathComponent("secret.txt")
    try Data("s".utf8).write(to: secret)
    try FileManager.default.createSymbolicLink(at: pack.appendingPathComponent("link.png"), withDestinationURL: secret)
    let textures = scratch.appendingPathComponent("Textures")
    let result = try ModContentInstaller.installTextures(from: pack, gameID: "GALE01", texturesRoot: textures)
    XCTAssertEqual(result.filesCopied, 1)
  }

  // MARK: - Gecko

  private final class FakeStore: GeckoCodeStoring {
    var names: [String]
    var enabled: [String] = []
    var rejecting: Set<String> = []

    init(names: [String] = []) { self.names = names }

    func codeNames(gameID: String, revision: Int) -> [String] { names }

    func add(_ code: GeckoCodeEntry, gameID: String, revision: Int) -> Bool {
      guard !rejecting.contains(code.name) else { return false }
      names.append(code.name)
      return true
    }

    func enable(codeNamed name: String, gameID: String, revision: Int) { enabled.append(name) }
  }

  func testGeckoCodesAreMergedAndEnabled() throws {
    let text = "[Gecko]\n$One [A]\n04000000 00000001\n$Two\n04000000 00000002\n"
    let store = FakeStore()
    let result = try ModContentInstaller.installGecko(text: text, gameID: "GALE01", revision: 0, store: store)
    XCTAssertEqual(result.added, ["One", "Two"])
    XCTAssertEqual(store.enabled, ["One", "Two"])
  }

  func testGeckoCodesAlreadyPresentAreSkipped() throws {
    let text = "[Gecko]\n$One\n04000000 00000001\n$Two\n04000000 00000002\n"
    let store = FakeStore(names: ["One"])
    let result = try ModContentInstaller.installGecko(text: text, gameID: "GALE01", revision: 0, store: store)
    XCTAssertEqual(result.added, ["Two"])
    XCTAssertEqual(result.alreadyPresent, ["One"])
  }

  func testRejectedGeckoCodesAreReported() throws {
    let store = FakeStore()
    store.rejecting = ["Bad"]
    let result = try ModContentInstaller.installGecko(text: "$Bad\n04000000 00000001\n", gameID: "GALE01", revision: 0, store: store)
    XCTAssertEqual(result.rejected, ["Bad"])
    XCTAssertTrue(store.enabled.isEmpty)
  }

  func testGeckoFileWithoutCodesThrows() {
    XCTAssertThrowsError(try ModContentInstaller.installGecko(text: "nothing here", gameID: "GALE01", revision: 0, store: FakeStore()))
  }
}

final class GeckoCodeParserTests: XCTestCase {
  func testParsesNamesCreatorsNotesAndLines() {
    let text = """
    [Gecko]
    $Infinite Shield [Dev]
    *Keeps the shield full
    *second note
    0415D3A0 3C008000
    c2000000 00000002 ignored trailing
    $Plain
    04000000 00000001
    [Gecko_Enabled]
    $Plain
    """
    let codes = GeckoCodeParser.parse(text)
    XCTAssertEqual(codes.count, 2)
    XCTAssertEqual(codes[0].name, "Infinite Shield")
    XCTAssertEqual(codes[0].creator, "Dev")
    XCTAssertEqual(codes[0].notes, ["Keeps the shield full", "second note"])
    XCTAssertEqual(codes[0].lines, ["0415D3A0 3C008000", "C2000000 00000002"])
    XCTAssertFalse(codes[0].isEnabled)
    XCTAssertEqual(codes[1].creator, "")
    XCTAssertTrue(codes[1].isEnabled)
  }

  func testOtherSectionsAreIgnored() {
    let text = "[Core]\n$NotACode\n04000000 00000001\n[Gecko]\n$Real\n04000000 00000002\n[ActionReplay]\n$AR\n04000000 00000003\n"
    XCTAssertEqual(GeckoCodeParser.parse(text).map(\.name), ["Real"])
  }

  func testBareListWithoutSectionHeaders() {
    XCTAssertEqual(GeckoCodeParser.parse("$A\n04000000 00000001\n").map(\.name), ["A"])
  }

  func testCodesWithoutValidLinesAreDropped() {
    XCTAssertTrue(GeckoCodeParser.parse("[Gecko]\n$Empty\nnot a line\n").isEmpty)
  }

  func testWindowsLineEndings() {
    XCTAssertEqual(GeckoCodeParser.parse("[Gecko]\r\n$A\r\n04000000 00000001\r\n").first?.lines, ["04000000 00000001"])
  }
}

final class HTMLPlainTextTests: XCTestCase {
  func testStripsTagsAndKeepsParagraphBreaks() {
    let html = #"<span class="x"><i>Hello</i> world<br><br><a href="https://e.com">link</a></span><p>Next</p>"#
    XCTAssertEqual(HTMLPlainText.text(from: html), "Hello world\n\nlink\nNext")
  }

  func testDecodesEntities() {
    XCTAssertEqual(HTMLPlainText.text(from: "Tom &amp; Jerry &lt;3 &#39;x&#x27; &quot;y&quot; a&nbsp;b"), "Tom & Jerry <3 'x' \"y\" a b")
  }

  func testDropsScriptAndStyleBodies() {
    XCTAssertEqual(HTMLPlainText.text(from: "a<script>alert(1)</script>b<style>p{}</style>c"), "abc")
  }

  func testUnknownEntitiesAndStrayAmpersandsSurvive() {
    XCTAssertEqual(HTMLPlainText.text(from: "R&D &bogus; end"), "R&D &bogus; end")
  }

  func testListItemsGetTheirOwnLines() {
    XCTAssertEqual(HTMLPlainText.text(from: "<ul><li>one</li><li>two</li></ul>"), "one\ntwo")
  }

  func testImagesAreDropped() {
    XCTAssertEqual(HTMLPlainText.text(from: #"before<img src="https://tracker/x.png">after"#), "beforeafter")
  }
}

final class ModDownloadPolicyTests: XCTestCase {
  func testSmallDownloadWithRoomIsAllowed() {
    XCTAssertEqual(ModDownloadPolicy.verdict(fileSize: 10_000_000, availableBytes: 10_000_000_000), .allowed)
  }

  func testLargeDownloadAsksForConfirmation() {
    let size: Int64 = 600 * 1024 * 1024
    XCTAssertEqual(ModDownloadPolicy.verdict(fileSize: size, availableBytes: 100_000_000_000), .confirmLargeDownload(bytes: size))
  }

  func testNotEnoughSpaceReportsTheNeed() {
    XCTAssertEqual(ModDownloadPolicy.verdict(fileSize: 1_000, availableBytes: 2_999), .insufficientSpace(needed: 3_000, available: 2_999))
  }

  func testUnknownFreeSpaceDoesNotBlock() {
    XCTAssertEqual(ModDownloadPolicy.verdict(fileSize: 1_000, availableBytes: nil), .allowed)
  }

  func testMD5MatchesAKnownDigest() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("md5-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("The quick brown fox jumps over the lazy dog".utf8).write(to: url)
    XCTAssertEqual(try ModDownloadPolicy.md5(of: url), "9e107d9d372bb6826bd81d3542a419d6")
    XCTAssertNoThrow(try ModDownloadPolicy.verifyChecksum(of: url, expected: "9E107D9D372BB6826BD81D3542A419D6"))
    XCTAssertNoThrow(try ModDownloadPolicy.verifyChecksum(of: url, expected: nil))
  }

  func testMD5OfMultipleChunks() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("md5big-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(repeating: 0x61, count: (1 << 20) * 2 + 5).write(to: url)
    XCTAssertEqual(try ModDownloadPolicy.md5(of: url).count, 32)
  }

  func testChecksumMismatchThrows() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("md5bad-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data("abc".utf8).write(to: url)
    XCTAssertThrowsError(try ModDownloadPolicy.verifyChecksum(of: url, expected: "00000000000000000000000000000000")) { error in
      guard case ModDownloadError.checksumMismatch = error else { return XCTFail("\(error)") }
    }
  }
}
