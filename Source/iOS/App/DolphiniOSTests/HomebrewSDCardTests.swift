// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class HomebrewSDCardTests: XCTestCase {
  private var scratch: HomebrewScratch!
  private var root: URL!
  private var work: URL!
  private var packed: [(folder: String, image: String)] = []
  /// The files the fake core was handed to pack, by path from the card's root.
  private var packedFiles: [String] = []
  private var inserted: [String] = []
  private var removals = 0
  /// What the fake core "finds" on the card when asked to unpack it: path to contents.
  private var cardContents: [String: String] = [:]
  private var packSucceeds = true

  override func setUpWithError() throws {
    scratch = try HomebrewScratch()
    root = scratch.root.appendingPathComponent("Software/Homebrew", isDirectory: true)
    work = scratch.root.appendingPathComponent("work", isDirectory: true)
    packed = []
    inserted = []
    removals = 0
    cardContents = [:]
    packSucceeds = true
  }

  private func card() -> HomebrewSDCard {
    HomebrewSDCard(core: .init(
      pack: { [unowned self] folder, image in
        packed.append((folder.lastPathComponent, image.lastPathComponent))
        packedFiles = Self.files(in: folder)
        guard packSucceeds else { return false }
        return FileManager.default.createFile(atPath: image.path, contents: Data("image".utf8))
      },
      unpack: { [unowned self] _, folder in
        for (path, contents) in cardContents {
          _ = try? scratch.file(path, contents, in: folder)
        }
        return true
      },
      insert: { [unowned self] image, programPath in inserted.append(image.lastPathComponent + " " + programPath) },
      remove: { [unowned self] in removals += 1 }), workDirectory: work)
  }

  private static func files(in folder: URL) -> [String] {
    guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    var found: [String] = []
    for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
      found.append(url.pathComponents.suffix(walker.level).joined(separator: "/"))
    }
    return found.sorted()
  }

  /// The program "writes" to its card: the image file changes after it was packed.
  private func touchImage(_ name: String) throws {
    let image = work.appendingPathComponent(name)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: image.path)
  }

  private func program(_ slug: String = "fruity") throws -> String {
    try scratch.file("\(slug)/apps/\(slug)/data/levels.bin", "levels", in: root)
    return try scratch.file("\(slug)/apps/\(slug)/\(slug).dol", "DOL", in: root).path
  }

  // MARK: - Which folder is the card

  func testCardIsTheTitleFolderUnderHomebrew() throws {
    let path = try program()
    XCTAssertEqual(HomebrewSDCard.cardFolder(forProgram: path, homebrewRoot: root)?.lastPathComponent, "fruity")
    let atRoot = try scratch.file("pong/pong.dol", in: root).path
    XCTAssertEqual(HomebrewSDCard.cardFolder(forProgram: atRoot, homebrewRoot: root)?.lastPathComponent, "pong")
  }

  func testProgramsElsewhereHaveNoCard() throws {
    let disc = try scratch.file("Software/game.iso").path
    XCTAssertNil(HomebrewSDCard.cardFolder(forProgram: disc, homebrewRoot: root))
    // Directly in the Homebrew folder there is no title folder to be the card.
    let loose = try scratch.file("loose.dol", in: root).path
    XCTAssertNil(HomebrewSDCard.cardFolder(forProgram: loose, homebrewRoot: root))
    // A sibling whose name only starts the same way.
    let sibling = try scratch.file("Software/HomebrewOld/a/a.dol").path
    XCTAssertNil(HomebrewSDCard.cardFolder(forProgram: sibling, homebrewRoot: root))
  }

  /// The library hands over `/private/var/...` while the root is `/var/...`, or the reverse.
  func testCardFolderIgnoresThePrivatePrefix() throws {
    let path = try program()
    let spelledOut = path.hasPrefix("/private") ? String(path.dropFirst("/private".count)) : "/private" + path
    XCTAssertEqual(HomebrewSDCard.cardFolder(forProgram: spelledOut, homebrewRoot: root)?.lastPathComponent, "fruity")
  }

  // MARK: - A run

  func testHomebrewRunPacksInsertsAndCleansUp() throws {
    let sd = card()
    sd.prepare(programPath: try program(), homebrewRoot: root)
    XCTAssertTrue(sd.hasCard)
    XCTAssertEqual(packed.map(\.folder), ["fruity.card"])
    XCTAssertFalse(scratch.exists("work/fruity.card"))
    XCTAssertTrue(inserted.isEmpty)
    sd.insert(isWii: false)
    XCTAssertEqual(inserted, ["fruity.img /apps/fruity/fruity.dol"])
    sd.finish()
    XCTAssertFalse(sd.hasCard)
    XCTAssertEqual(removals, 1)
    XCTAssertFalse(scratch.exists("work/fruity.img"))
  }

  func testOtherProgramsGetNoCard() throws {
    let sd = card()
    sd.prepare(programPath: try scratch.file("Software/game.iso").path, homebrewRoot: root)
    sd.insert(isWii: false)
    sd.finish()
    sd.prepare(programPath: nil, homebrewRoot: root)
    sd.prepare(programPath: try program(), homebrewRoot: nil)
    XCTAssertFalse(sd.hasCard)
    XCTAssertTrue(packed.isEmpty)
    XCTAssertTrue(inserted.isEmpty)
    XCTAssertEqual(removals, 0)
  }

  func testWiiProgramKeepsSlotB() throws {
    let sd = card()
    sd.prepare(programPath: try program(), homebrewRoot: root)
    sd.insert(isWii: true)
    sd.finish()
    XCTAssertTrue(inserted.isEmpty)
    XCTAssertEqual(removals, 0)
    XCTAssertFalse(scratch.exists("work/fruity.img"))
  }

  func testFailedPackBootsWithoutACard() throws {
    packSucceeds = false
    let sd = card()
    sd.prepare(programPath: try program(), homebrewRoot: root)
    XCTAssertFalse(sd.hasCard)
    sd.insert(isWii: false)
    XCTAssertTrue(inserted.isEmpty)
  }

  /// A boot that was superseded never reaches `finish` before the next `prepare`.
  func testPreparingAgainDropsTheUnusedCard() throws {
    let sd = card()
    sd.prepare(programPath: try program("fruity"), homebrewRoot: root)
    sd.insert(isWii: false)
    sd.prepare(programPath: try program("nicky"), homebrewRoot: root)
    XCTAssertEqual(removals, 1)
    XCTAssertFalse(scratch.exists("work/fruity.img"))
    XCTAssertTrue(scratch.exists("work/nicky.img"))
  }

  // MARK: - What is on the card

  /// FruitY opens `data/levels.bin` from where it stands, which without a loader is the root.
  func testProgramFolderIsAlsoAtTheCardRoot() throws {
    try scratch.file("fruity/apps/fruity/opening.bnr", in: root)
    try scratch.file("fruity/readme.txt", in: root)
    let sd = card()
    sd.prepare(programPath: try program(), homebrewRoot: root)
    XCTAssertEqual(packedFiles, ["apps/fruity/data/levels.bin", "apps/fruity/fruity.dol", "apps/fruity/opening.bnr",
                                 "data/levels.bin", "fruity/data/levels.bin", "fruity/opening.bnr",
                                 "opening.bnr", "readme.txt"])
    // The title's folder itself is as it was.
    XCTAssertFalse(scratch.exists("Software/Homebrew/fruity/data"))
  }

  func testWhatIsAlreadyAtTheRootIsNotReplaced() throws {
    try scratch.file("fruity/data/levels.bin", "the user's own levels", in: root)
    let folder = root.appendingPathComponent("fruity", isDirectory: true)
    let staging = scratch.root.appendingPathComponent("staging", isDirectory: true)
    _ = try program()
    try HomebrewSDCard.stage(folder, programDirectory: ["apps", "fruity"], program: "fruity.dol", at: staging)
    XCTAssertEqual(try String(contentsOf: staging.appendingPathComponent("data/levels.bin"), encoding: .utf8), "the user's own levels")
    XCTAssertEqual(try String(contentsOf: staging.appendingPathComponent("fruity/data/levels.bin"), encoding: .utf8), "levels")
  }

  /// Cube64's package already has `wii64/` at the root; a folder named like the program's is the
  /// package's own and is left alone.
  func testFolderOfTheProgramsNameAtTheRootIsKept() throws {
    try scratch.file("fruity/fruity/notes.txt", "the package's own", in: root)
    let folder = root.appendingPathComponent("fruity", isDirectory: true)
    let staging = scratch.root.appendingPathComponent("staging", isDirectory: true)
    _ = try program()
    try HomebrewSDCard.stage(folder, programDirectory: ["apps", "fruity"], program: "fruity.dol", at: staging)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.appendingPathComponent("fruity").path), ["notes.txt"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("data/levels.bin").path))
  }

  func testProgramAtTheFolderRootIsPackedAsItIs() throws {
    let path = try scratch.file("pong/pong.dol", in: root).path
    try scratch.file("pong/sounds/hit.wav", in: root)
    let sd = card()
    sd.prepare(programPath: path, homebrewRoot: root)
    XCTAssertEqual(packedFiles, ["pong.dol", "sounds/hit.wav"])
  }

  // MARK: - What the program wrote

  func testChangedCardIsCopiedBack() throws {
    let sd = card()
    sd.prepare(programPath: try program(), homebrewRoot: root)
    sd.insert(isWii: false)
    // `data/levels.bin` at the root is the program folder's own file, shown there by the card.
    cardContents = ["apps/fruity/fruity.dol": "DOL", "apps/fruity/data/levels.bin": "levels", "data/levels.bin": "levels",
                    "fruity/data/levels.bin": "levels",
                    "apps/fruity/save.bin": "progress", "config.ini": "volume=3"]
    try touchImage("fruity.img")
    sd.finish()
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("fruity/apps/fruity/save.bin"), encoding: .utf8), "progress")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("fruity/config.ini"), encoding: .utf8), "volume=3")
    XCTAssertFalse(scratch.exists("work/fruity.unpacked"))
    XCTAssertFalse(scratch.exists("Software/Homebrew/fruity/data"))
    XCTAssertFalse(scratch.exists("Software/Homebrew/fruity/fruity"))
  }

  func testUntouchedCardIsNotUnpacked() throws {
    let sd = card()
    sd.prepare(programPath: try program(), homebrewRoot: root)
    sd.insert(isWii: false)
    cardContents = ["stray.txt": "should not appear"]
    sd.finish()
    XCTAssertFalse(scratch.exists("Software/Homebrew/fruity/stray.txt"))
  }

  /// A file the program rewrote through the root goes back to where it came from.
  func testChangedFileFromTheProgramFolderGoesBackThere() throws {
    let cardFolder = scratch.root.appendingPathComponent("card", isDirectory: true)
    let folder = scratch.root.appendingPathComponent("title", isDirectory: true)
    try scratch.file("apps/quest/scores.dat", "old", in: folder)
    try scratch.file("apps/quest/data/levels.bin", "levels", in: folder)
    try scratch.file("apps/quest/scores.dat", "old", in: cardFolder)
    try scratch.file("apps/quest/data/levels.bin", "levels", in: cardFolder)
    try scratch.file("scores.dat", "new", in: cardFolder)
    try scratch.file("data/levels.bin", "levels", in: cardFolder)
    try scratch.file("settings.ini", "fresh", in: cardFolder)
    // The folder again under its own name: one file as it was, one the program rewrote there.
    try scratch.file("quest/scores.dat", "old", in: cardFolder)
    try scratch.file("quest/data/levels.bin", "edited levels", in: cardFolder)

    XCTAssertEqual(HomebrewSDCard.copyChanges(from: cardFolder, into: folder, programDirectory: ["apps", "quest"]),
                   ["apps/quest/data/levels.bin", "apps/quest/scores.dat", "settings.ini"])
    XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("apps/quest/data/levels.bin"), encoding: .utf8), "edited levels")
    XCTAssertFalse(scratch.exists("title/quest"))
    XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("apps/quest/scores.dat"), encoding: .utf8), "new")
    XCTAssertFalse(scratch.exists("title/scores.dat"))
    XCTAssertFalse(scratch.exists("title/data"))
    XCTAssertTrue(scratch.exists("title/settings.ini"))
  }

  /// The other way round: the file changed in its own place and the root still shows the old one.
  func testFileChangedInItsOwnPlaceIsNotUndoneByItsRootCopy() throws {
    let cardFolder = scratch.root.appendingPathComponent("card", isDirectory: true)
    let folder = scratch.root.appendingPathComponent("title", isDirectory: true)
    try scratch.file("apps/quest/scores.dat", "old", in: folder)
    try scratch.file("apps/quest/scores.dat", "new", in: cardFolder)
    try scratch.file("scores.dat", "old", in: cardFolder)

    XCTAssertEqual(HomebrewSDCard.copyChanges(from: cardFolder, into: folder, programDirectory: ["apps", "quest"]),
                   ["apps/quest/scores.dat"])
    XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("apps/quest/scores.dat"), encoding: .utf8), "new")
    XCTAssertFalse(scratch.exists("title/scores.dat"))
  }

  func testCopyChangesReplacesNewAndDifferentFilesOnly() throws {
    let cardFolder = scratch.root.appendingPathComponent("card", isDirectory: true)
    let folder = scratch.root.appendingPathComponent("title", isDirectory: true)
    try scratch.file("same.bin", "same", in: cardFolder)
    try scratch.file("same.bin", "same", in: folder)
    try scratch.file("save/slot1.sav", "new save", in: cardFolder)
    try scratch.file("save/slot1.sav", "old save", in: folder)
    try scratch.file("save/slot2.sav", "second", in: cardFolder)
    try scratch.file("mine/rom.gb", "user file the card no longer has", in: folder)

    XCTAssertEqual(HomebrewSDCard.copyChanges(from: cardFolder, into: folder), ["save/slot1.sav", "save/slot2.sav"])
    XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("save/slot1.sav"), encoding: .utf8), "new save")
    XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("save/slot2.sav"), encoding: .utf8), "second")
    XCTAssertTrue(scratch.exists("title/mine/rom.gb"))
    XCTAssertTrue(scratch.exists("title/same.bin"))
  }
}
