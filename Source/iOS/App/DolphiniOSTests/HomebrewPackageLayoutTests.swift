// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

/// A scratch folder that removes itself.
final class HomebrewScratch {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("homebrew-tests-\(UUID().uuidString)", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  @discardableResult
  func file(_ path: String, _ contents: String = "x", in base: URL? = nil) throws -> URL {
    let url = (base ?? root).appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    return url
  }

  func exists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
  }
}

final class HomebrewPackageLayoutTests: XCTestCase {
  private func relative(_ url: URL?, to scratch: HomebrewScratch) -> String? {
    guard let url else { return nil }
    return String(url.resolvingSymlinksInPath().path.dropFirst(scratch.root.path.count + 1))
  }

  func testSingleProgramAnywhere() throws {
    let rootOnly = try HomebrewScratch()
    try rootOnly.file("game.dol")
    try rootOnly.file("readme.txt")
    XCTAssertEqual(relative(HomebrewPackageLayout.program(in: rootOnly.root), to: rootOnly), "game.dol")

    let nested = try HomebrewScratch()
    try nested.file("tools/x/boot.elf")
    XCTAssertEqual(relative(HomebrewPackageLayout.program(in: nested.root), to: nested), "tools/x/boot.elf")
  }

  func testDefaultDolUnderAppsWins() throws {
    let scratch = try HomebrewScratch()
    try scratch.file("apps/a/default.dol")
    try scratch.file("apps/a/extra.dol")
    try scratch.file("aaa.dol")
    XCTAssertEqual(relative(HomebrewPackageLayout.program(in: scratch.root), to: scratch), "apps/a/default.dol")
  }

  func testBootDolWhenNoDefault() throws {
    let scratch = try HomebrewScratch()
    try scratch.file("apps/a/boot.dol")
    try scratch.file("apps/a/another.dol")
    XCTAssertEqual(relative(HomebrewPackageLayout.program(in: scratch.root), to: scratch), "apps/a/boot.dol")
  }

  func testSeveralAppsPicksFirstInPathOrder() throws {
    let scratch = try HomebrewScratch()
    try scratch.file("apps/b/default.dol")
    try scratch.file("apps/a/default.dol")
    XCTAssertEqual(relative(HomebrewPackageLayout.program(in: scratch.root), to: scratch), "apps/a/default.dol")
  }

  func testSeveralProgramsOutsideAppsPicksFirstInPathOrder() throws {
    let scratch = try HomebrewScratch()
    try scratch.file("z/two.dol")
    try scratch.file("m/one.elf")
    XCTAssertEqual(relative(HomebrewPackageLayout.program(in: scratch.root), to: scratch), "m/one.elf")
  }

  func testDefaultDolDeeperThanOneFolderIsNotTheAppsRule() throws {
    let scratch = try HomebrewScratch()
    try scratch.file("apps/a/data/default.dol")
    try scratch.file("apps/a/boot.dol")
    XCTAssertEqual(relative(HomebrewPackageLayout.program(in: scratch.root), to: scratch), "apps/a/boot.dol")
  }

  func testNoProgramIsNil() throws {
    let scratch = try HomebrewScratch()
    try scratch.file("readme.txt")
    try scratch.file("apps/a/opening.bnr")
    XCTAssertNil(HomebrewPackageLayout.program(in: scratch.root))
    XCTAssertNil(HomebrewPackageLayout.program(in: scratch.root.appendingPathComponent("missing")))
  }

  func testExtensionCaseIsIgnored() throws {
    let scratch = try HomebrewScratch()
    try scratch.file("APPS/Game/DEFAULT.DOL")
    try scratch.file("APPS/Game/other.Dol")
    XCTAssertEqual(relative(HomebrewPackageLayout.program(in: scratch.root), to: scratch), "APPS/Game/DEFAULT.DOL")
  }

  func testSymlinkIsIgnored() throws {
    let scratch = try HomebrewScratch()
    let outside = try HomebrewScratch()
    let target = try outside.file("real.dol")
    try FileManager.default.createSymbolicLink(at: scratch.root.appendingPathComponent("link.dol"), withDestinationURL: target)
    XCTAssertNil(HomebrewPackageLayout.program(in: scratch.root))
  }

  func testDirectoryNamedLikeAProgramIsIgnored() throws {
    let scratch = try HomebrewScratch()
    try scratch.file("fake.dol/readme.txt")
    XCTAssertNil(HomebrewPackageLayout.program(in: scratch.root))
  }

  func testMacArchiveLeftoversAreIgnored() throws {
    let scratch = try HomebrewScratch()
    try scratch.file("__MACOSX/._game.dol")
    try scratch.file("__MACOSX/apps/a/._default.dol")
    try scratch.file("._game.dol")
    try scratch.file(".hidden/other.dol")
    try scratch.file("game.dol")
    XCTAssertEqual(relative(HomebrewPackageLayout.program(in: scratch.root), to: scratch), "game.dol")

    let onlyLeftovers = try HomebrewScratch()
    try onlyLeftovers.file("__MACOSX/._game.dol")
    XCTAssertNil(HomebrewPackageLayout.program(in: onlyLeftovers.root))
  }

  func testRenameUsesSlugAndKeepsExtension() throws {
    let scratch = try HomebrewScratch()
    let program = try scratch.file("apps/a/default.dol", "new")
    try scratch.file("apps/a/classicube.dol", "stale")
    let renamed = try HomebrewPackageLayout.rename(program, slug: "classicube")
    XCTAssertEqual(relative(renamed, to: scratch), "apps/a/classicube.dol")
    XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "new")
    XCTAssertFalse(scratch.exists("apps/a/default.dol"))

    let elf = try scratch.file("boot.ELF")
    XCTAssertEqual(relative(try HomebrewPackageLayout.rename(elf, slug: "classicube"), to: scratch), "classicube.elf")
  }

  func testRenameIsANoOpWhenAlreadyNamed() throws {
    let scratch = try HomebrewScratch()
    let program = try scratch.file("apps/a/classicube.dol", "keep")
    let renamed = try HomebrewPackageLayout.rename(program, slug: "classicube")
    XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "keep")
  }

  func testRenameRefusesAnUnsafeSlug() throws {
    let scratch = try HomebrewScratch()
    let program = try scratch.file("default.dol")
    XCTAssertThrowsError(try HomebrewPackageLayout.rename(program, slug: "../up"))
    XCTAssertTrue(scratch.exists("default.dol"))
  }
}
