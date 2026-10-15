// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

/// "Manage…": what may be deleted, and that the base game never is.
@MainActor
final class ModManageModelTests: XCTestCase {
  private let basePath = "/data/Software/Melee.iso"
  private let copyPath = "/data/Software/Patched/Melee (20XX).iso"
  private let presetPath = "/data/Software/Mods/Melee Training.json"
  private let sdRoot = URL(fileURLWithPath: "/data/User/Load/Riivolution", isDirectory: true)

  private let isModded: ModdedLibrary.Classifier = { $0.contains("/Patched/") || $0.hasSuffix(".json") }

  private final class Removals: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var removed: [String] { lock.lock(); defer { lock.unlock() }; return paths }
    func record(_ more: [String]) { lock.lock(); paths += more; lock.unlock() }
  }

  private func makeModel(removals: Removals, changes: @escaping () -> Void = {}) -> ModManageModel {
    let game = RiivolutionLaunchModel.Game(title: "Melee", gameID: "GALE01", revision: 0, discNumber: 0, filePath: basePath)
    return ModManageModel(
      game: game,
      entries: [
        ModManageModel.Entry(path: copyPath, name: "Melee (20XX)", kind: .patchedCopy),
        ModManageModel.Entry(path: presetPath, name: "Melee Training", kind: .descriptor),
      ],
      sdRoot: sdRoot,
      loadPacks: { _, _ in [] },
      removeFiles: { paths in
        removals.record(paths)
        var outcome = LocalGameDeleter.Outcome()
        outcome.deleted = paths
        return outcome
      },
      isModded: isModded,
      onChanged: changes
    )
  }

  func test_entriesSplitIntoCopiesAndPresets() {
    let model = makeModel(removals: Removals())
    XCTAssertEqual(model.patchedCopies.map(\.name), ["Melee (20XX)"])
    XCTAssertEqual(model.presets.map(\.name), ["Melee Training"])
  }

  func test_theBaseGameCanNeverBeDeleted() async {
    let removals = Removals()
    let model = makeModel(removals: removals)
    XCTAssertFalse(model.canDelete(path: basePath))
    await model.delete(ModManageModel.Entry(path: basePath, name: "Melee", kind: .patchedCopy))
    XCTAssertTrue(removals.removed.isEmpty)
  }

  func test_aPlainFileOutsideTheModFoldersCanNotBeDeleted() async {
    let removals = Removals()
    let model = makeModel(removals: removals)
    let other = "/data/Software/Mario.iso"
    XCTAssertFalse(model.canDelete(path: other))
    await model.delete(ModManageModel.Entry(path: other, name: "Mario", kind: .patchedCopy))
    XCTAssertTrue(removals.removed.isEmpty)
  }

  func test_deletingACopyRemovesItsFileAndTellsTheLibrary() async throws {
    let removals = Removals()
    var changed = 0
    let model = makeModel(removals: removals) { changed += 1 }
    let copy = try XCTUnwrap(model.patchedCopies.first)
    await model.delete(copy)
    XCTAssertEqual(removals.removed, [copyPath])
    XCTAssertTrue(model.patchedCopies.isEmpty)
    XCTAssertEqual(model.presets.count, 1)
    XCTAssertEqual(changed, 1)
  }

  func test_aFailedDeleteKeepsTheEntryAndSaysWhy() async throws {
    let game = RiivolutionLaunchModel.Game(title: "Melee", gameID: "GALE01", revision: 0, discNumber: 0, filePath: basePath)
    var changed = 0
    let model = ModManageModel(
      game: game,
      entries: [ModManageModel.Entry(path: copyPath, name: "Melee (20XX)", kind: .patchedCopy)],
      sdRoot: sdRoot,
      loadPacks: { _, _ in [] },
      removeFiles: { paths in
        var outcome = LocalGameDeleter.Outcome()
        outcome.failures = paths.map { ($0, "Operation not permitted") }
        return outcome
      },
      isModded: isModded,
      onChanged: { changed += 1 }
    )
    await model.delete(try XCTUnwrap(model.patchedCopies.first))
    XCTAssertEqual(model.patchedCopies.count, 1)
    XCTAssertEqual(model.failureMessage, "Operation not permitted")
    XCTAssertEqual(changed, 0)
  }

  func test_aPackIsRemovedByItsXMLAndOnlyInsideTheRiivolutionFolder() async {
    let removals = Removals()
    let model = makeModel(removals: removals)
    let inside = RiivolutionPack(xmlPath: sdRoot.path + "/riivolution/newer.xml", rootPath: sdRoot.path + "/", options: [])
    let outside = RiivolutionPack(xmlPath: "/data/Software/newer.xml", rootPath: "/data/Software/", options: [])
    await model.remove(outside)
    XCTAssertTrue(removals.removed.isEmpty)
    await model.remove(inside)
    XCTAssertEqual(removals.removed, [inside.xmlPath])
  }

  func test_anEntryIsBuiltFromALibraryItem() {
    struct Item: ModdedLibraryEntry {
      let filePath: String
      let gameID = "GALE01"
      let title = "Super Smash Bros. Melee"
    }
    let isModded = self.isModded
    XCTAssertEqual(ModManageModel.Entry(entry: Item(filePath: copyPath), isModded: isModded),
                   ModManageModel.Entry(path: copyPath, name: "Melee (20XX)", kind: .patchedCopy))
    XCTAssertNil(ModManageModel.Entry(entry: Item(filePath: basePath), isModded: isModded))
  }
}
