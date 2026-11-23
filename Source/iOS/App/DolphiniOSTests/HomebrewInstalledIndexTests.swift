// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class HomebrewInstalledIndexTests: XCTestCase {
  private typealias Data = HomebrewTestData

  private func entry(_ slug: String, version: String = "10") -> HomebrewInstalledIndex.Entry {
    .init(versionSlug: version, version: version, programPath: "\(slug)/apps/\(slug)/\(slug).dol")
  }

  func testRoundTrip() throws {
    let scratch = try HomebrewScratch()
    var index = HomebrewInstalledIndex()
    index.titles["a"] = entry("a")
    try index.save(root: scratch.root)
    XCTAssertTrue(scratch.exists("installed.json"))
    XCTAssertEqual(HomebrewInstalledIndex.load(root: scratch.root), index)
  }

  func testSaveCreatesTheRoot() throws {
    let scratch = try HomebrewScratch()
    let root = scratch.root.appendingPathComponent("Homebrew", isDirectory: true)
    try HomebrewInstalledIndex().save(root: root)
    XCTAssertTrue(scratch.exists("Homebrew/installed.json"))
  }

  func testMissingOrCorruptFileIsEmpty() throws {
    let scratch = try HomebrewScratch()
    XCTAssertEqual(HomebrewInstalledIndex.load(root: scratch.root), HomebrewInstalledIndex())
    try scratch.file("installed.json", "not json")
    XCTAssertEqual(HomebrewInstalledIndex.load(root: scratch.root), HomebrewInstalledIndex())
  }

  func testStateInstalledUpdateAndNotInstalled() throws {
    let scratch = try HomebrewScratch()
    try scratch.file("a/apps/a/a.dol")
    var index = HomebrewInstalledIndex()
    index.titles["a"] = entry("a", version: "10")
    XCTAssertEqual(index.state(of: Data.title("a", latest: Data.version("10")), root: scratch.root), .installed)
    XCTAssertEqual(index.state(of: Data.title("a", latest: Data.version("11")), root: scratch.root), .updateAvailable)
    XCTAssertEqual(index.state(of: Data.title("a", latest: nil), root: scratch.root), .installed)
    XCTAssertEqual(index.state(of: Data.title("b"), root: scratch.root), .notInstalled)
  }

  func testMissingProgramFileCountsAsNotInstalled() throws {
    let scratch = try HomebrewScratch()
    var index = HomebrewInstalledIndex()
    index.titles["a"] = entry("a")
    XCTAssertEqual(index.state(of: Data.title("a"), root: scratch.root), .notInstalled)
    XCTAssertNil(index.programURL(forSlug: "a", root: scratch.root))
  }

  func testProgramURLPointsAtTheFile() throws {
    let scratch = try HomebrewScratch()
    let file = try scratch.file("a/apps/a/a.dol")
    var index = HomebrewInstalledIndex()
    index.titles["a"] = entry("a")
    XCTAssertEqual(index.programURL(forSlug: "a", root: scratch.root)?.resolvingSymlinksInPath().path, file.path)
  }

  func testRemoveOrphansDeletesFolderAndEntry() throws {
    let scratch = try HomebrewScratch()
    try scratch.file("gone/apps/gone/opening.bnr")
    var index = HomebrewInstalledIndex()
    index.titles["gone"] = entry("gone")
    XCTAssertEqual(index.removeOrphans(root: scratch.root), ["gone"])
    XCTAssertNil(index.titles["gone"])
    XCTAssertFalse(scratch.exists("gone"))
  }

  func testRemoveOrphansLeavesInstalledTitlesAndUnknownFolders() throws {
    let scratch = try HomebrewScratch()
    try scratch.file("kept/apps/kept/kept.dol")
    try scratch.file("stranger/apps/stranger/default.dol")
    var index = HomebrewInstalledIndex()
    index.titles["kept"] = entry("kept")
    XCTAssertEqual(index.removeOrphans(root: scratch.root), [])
    XCTAssertNotNil(index.titles["kept"])
    XCTAssertTrue(scratch.exists("kept/apps/kept/kept.dol"))
    XCTAssertTrue(scratch.exists("stranger/apps/stranger/default.dol"))
  }

  func testProgramPathEscapingTheRootIsIgnored() throws {
    let scratch = try HomebrewScratch()
    let root = scratch.root.appendingPathComponent("Homebrew", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try scratch.file("outside.dol")
    try scratch.file("victim/keep.txt")
    var index = HomebrewInstalledIndex()
    index.titles["a"] = .init(versionSlug: "10", version: "10", programPath: "../outside.dol")
    index.titles["../victim"] = .init(versionSlug: "10", version: "10", programPath: "nothing.dol")
    XCTAssertEqual(index.state(of: Data.title("a"), root: root), .notInstalled)
    XCTAssertNil(index.programURL(forSlug: "a", root: root))
    XCTAssertEqual(Set(index.removeOrphans(root: root)), ["a", "../victim"])
    XCTAssertTrue(scratch.exists("outside.dol"))
    XCTAssertTrue(scratch.exists("victim/keep.txt"))
  }

  func testProgramOutsideItsOwnTitleFolderIsIgnored() throws {
    let scratch = try HomebrewScratch()
    try scratch.file("b/apps/b/b.dol")
    var index = HomebrewInstalledIndex()
    index.titles["a"] = .init(versionSlug: "10", version: "10", programPath: "b/apps/b/b.dol")
    XCTAssertNil(index.programURL(forSlug: "a", root: scratch.root))
  }
}
