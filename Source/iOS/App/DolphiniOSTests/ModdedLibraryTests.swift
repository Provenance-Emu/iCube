// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

/// The library rules for patched copies and saved mods: what the grid shows, what a base game lists under
/// "Patches & Mods", the badge count, and how a modded tile is named.
final class ModdedLibraryTests: XCTestCase {
  private struct Entry: ModdedLibraryEntry, Equatable {
    let filePath: String
    let gameID: String
    let title: String
  }

  private static let patchedFolder = "/data/Software/Patched/"
  private static let modsFolder = "/data/Software/Mods/"

  private let melee = Entry(filePath: "/data/Software/Melee.iso", gameID: "GALE01", title: "Super Smash Bros. Melee")
  private let meleePatched = Entry(filePath: patchedFolder + "Melee (20XX).iso", gameID: "GALE01", title: "Super Smash Bros. Melee")
  private let meleePreset = Entry(filePath: modsFolder + "Melee Training.json", gameID: "GALE01", title: "Melee Training")
  private let mario = Entry(filePath: "/data/Software/Mario.rvz", gameID: "GMSE01", title: "Super Mario Sunshine")
  private let marioPatched = Entry(filePath: patchedFolder + "Sunshine (Hack).rvz", gameID: "GMSE01", title: "Super Mario Sunshine")

  private var library: [Entry] { [melee, meleePatched, meleePreset, mario, marioPatched] }

  /// A stand-in for `ModdedBoot`: the two folders above, plus any `.json`.
  private let isModded: ModdedLibrary.Classifier = {
    $0.hasPrefix(ModdedLibraryTests.patchedFolder) || $0.hasPrefix(ModdedLibraryTests.modsFolder) || $0.hasSuffix(".json")
  }

  // MARK: - The grid

  func test_withTheSettingOnEveryTileIsShown() {
    XCTAssertEqual(ModdedLibrary.visible(library, showPatchedSeparately: true, isModded: isModded), library)
  }

  func test_withTheSettingOffOnlyBaseGamesAreShown() {
    XCTAssertEqual(ModdedLibrary.visible(library, showPatchedSeparately: false, isModded: isModded), [melee, mario])
  }

  func test_hidingKeepsTheLibraryOrder() {
    let shuffled = [marioPatched, mario, meleePreset, melee]
    XCTAssertEqual(ModdedLibrary.visible(shuffled, showPatchedSeparately: false, isModded: isModded), [mario, melee])
  }

  // MARK: - The badge and the menu

  func test_variantsAreGroupedUnderTheirBaseGamesID() {
    let grouped = ModdedLibrary.variantsByGameID(in: library, isModded: isModded)
    XCTAssertEqual(grouped["GALE01"], [meleePatched, meleePreset])
    XCTAssertEqual(grouped["GMSE01"], [marioPatched])
    XCTAssertEqual(grouped.count, 2)
  }

  func test_aGameWithNothingModdedHasNoCount() {
    let wario = Entry(filePath: "/data/Software/Wario.iso", gameID: "G4WE01", title: "Wario World")
    let grouped = ModdedLibrary.variantsByGameID(in: library + [wario], isModded: isModded)
    XCTAssertNil(grouped["G4WE01"])
    XCTAssertEqual(grouped["GALE01"]?.count, 2)
  }

  func test_entriesWithoutAGameIDAreNotCounted() {
    let orphan = Entry(filePath: Self.patchedFolder + "Unknown.iso", gameID: "", title: "Unknown")
    XCTAssertTrue(ModdedLibrary.variantsByGameID(in: [orphan], isModded: isModded).isEmpty)
  }

  func test_theBaseGameIsTheUnmoddedEntry() {
    XCTAssertEqual(ModdedLibrary.baseGame(withGameID: "GALE01", in: [meleePatched, melee], isModded: isModded), melee)
    XCTAssertNil(ModdedLibrary.baseGame(withGameID: "GALE01", in: [meleePatched, meleePreset], isModded: isModded))
  }

  // MARK: - Tile naming

  func test_aBaseGameHasNoModMark() {
    XCTAssertNil(ModdedLibrary.tileInfo(path: melee.filePath, title: melee.title, isModded: isModded))
  }

  func test_aPatchedCopyIsNamedAfterItsFile() {
    let info = ModdedLibrary.tileInfo(path: meleePatched.filePath, title: meleePatched.title, isModded: isModded)
    XCTAssertEqual(info, ModdedTileInfo(kind: .patchedCopy, displayName: "Melee (20XX)"))
    XCTAssertEqual(info?.caption, "Patched")
  }

  func test_aSavedModKeepsItsOwnDisplayName() {
    let info = ModdedLibrary.tileInfo(path: meleePreset.filePath, title: "Melee: Training Mode", isModded: isModded)
    XCTAssertEqual(info, ModdedTileInfo(kind: .descriptor, displayName: "Melee: Training Mode"))
    XCTAssertEqual(info?.caption, "Mod")
  }

  // MARK: - The setting

  func test_theSettingIsOnUntilTheUserTurnsItOff() throws {
    let suite = "ModdedLibraryTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertTrue(ModdedLibrary.showsPatchedSeparately(defaults: defaults))
    defaults.set(false, forKey: ConfigInterfaceDefaultsKey.showPatchedSeparately)
    XCTAssertFalse(ModdedLibrary.showsPatchedSeparately(defaults: defaults))
    defaults.set(true, forKey: ConfigInterfaceDefaultsKey.showPatchedSeparately)
    XCTAssertTrue(ModdedLibrary.showsPatchedSeparately(defaults: defaults))
  }
}
