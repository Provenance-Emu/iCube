// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import iCube

final class ModGameFilePackBuilderTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("ModPackBuilder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: root)
  }

  private func group(_ name: String, _ files: [String], _ mapping: ModGameFilePack.Mapping = .byName) -> ModGameFilePack.Group {
    let directory = name.isEmpty ? root! : root.appendingPathComponent(name, isDirectory: true)
    return ModGameFilePack.Group(name: name, directory: directory, files: files, mapping: mapping)
  }

  private func plan(_ groups: [ModGameFilePack.Group], modName: String = "Wario & Waluigi", titleCode: String? = "SMN")
    throws -> ModGameFilePackBuilder.Plan {
    try ModGameFilePackBuilder.plan(pack: ModGameFilePack(groups: groups), modName: modName, packID: "gamebanana-383315",
                                    titleCode: titleCode)
  }

  /// What Dolphin's parser will see: element names with their attributes, in document order.
  private func elements(of xml: String) throws -> [(name: String, attributes: [String: String])] {
    final class Collector: NSObject, XMLParserDelegate {
      var found: [(name: String, attributes: [String: String])] = []
      func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                  qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        found.append((elementName, attributeDict))
      }
    }
    let collector = Collector()
    let parser = XMLParser(data: Data(xml.utf8))
    parser.delegate = collector
    XCTAssertTrue(parser.parse(), "\(String(describing: parser.parserError))\n\(xml)")
    return collector.found
  }

  func testEachFolderBecomesAnOptionThatIsOnByDefault() throws {
    let plan = try plan([group("", ["Kinopio.arc", "K_rcha.arc"]), group("Cinematic Model", ["KBB.arc"])])
    XCTAssertEqual(plan.options.map(\.name), ["Wario & Waluigi", "Cinematic Model"])
    XCTAssertEqual(plan.options.map(\.isOnByDefault), [true, true])
    XCTAssertEqual(plan.xmlRelativePath, "riivolution/gamebanana-383315.xml")
    XCTAssertEqual(plan.copies.map(\.destination), [
      "icube-mods/gamebanana-383315/0/Kinopio.arc",
      "icube-mods/gamebanana-383315/0/K_rcha.arc",
      "icube-mods/gamebanana-383315/1/KBB.arc",
    ])
  }

  func testTheXMLIsForTheTitleAndReplacesFilesByName() throws {
    let xml = try plan([group("", ["Kinopio.arc"]), group("Cinematic Model", ["KBB.arc"])]).xml
    let elements = try elements(of: xml)
    XCTAssertEqual(elements.first { $0.name == "wiidisc" }?.attributes, ["version": "1"])
    XCTAssertEqual(elements.first { $0.name == "id" }?.attributes, ["game": "SMN"])
    XCTAssertEqual(elements.first { $0.name == "section" }?.attributes["name"], "Wario & Waluigi")
    let options = elements.filter { $0.name == "option" }
    XCTAssertEqual(options.map { $0.attributes["name"] }, ["Wario & Waluigi", "Cinematic Model"])
    XCTAssertEqual(options.map { $0.attributes["default"] }, ["1", "1"])
    let folders = elements.filter { $0.name == "folder" }
    // No `disc` attribute: Dolphin then matches each file to the disc file of the same name.
    XCTAssertEqual(folders.map(\.attributes), [
      ["external": "/icube-mods/gamebanana-383315/0"],
      ["external": "/icube-mods/gamebanana-383315/1"],
    ])
    // Every choice points at a patch that exists.
    let patchIDs = elements.filter { $0.name == "patch" }.compactMap { $0.attributes["id"] }
    XCTAssertEqual(Set(patchIDs).count, 2)
    XCTAssertEqual(patchIDs.count, 4)
  }

  func testAFolderThatReplacesTheSameFilesStartsSwitchedOff() throws {
    let plan = try plan([
      group("Sonic Over Mario", ["Mario.arc"]),
      group("Alternate Animations (Optional)", ["P_rcha.arc"]),
      group("Sonic Over Mario (Blue)", ["mario.ARC"]),
    ])
    XCTAssertEqual(plan.options.map(\.isOnByDefault), [true, true, false])
  }

  func testADiscTreeIsPatchedAtItsPaths() throws {
    let plan = try plan([group("Linkle/files", ["res/Object/Link.arc"], .discTree)])
    let folder = try XCTUnwrap(try elements(of: plan.xml).first { $0.name == "folder" })
    XCTAssertEqual(folder.attributes, ["disc": "/", "external": "/icube-mods/gamebanana-383315/0", "recursive": "true", "create": "true"])
    XCTAssertEqual(plan.copies.map(\.destination), ["icube-mods/gamebanana-383315/0/res/Object/Link.arc"])
  }

  func testAProgramReplacesMainDolAndOnlyTheFirstIsOn() throws {
    let plan = try plan([group("", ["widescreen_USA.dol"], .mainExecutable), group("PAL", ["widescreen_PAL.dol"], .mainExecutable)])
    let files = try elements(of: plan.xml).filter { $0.name == "file" }
    XCTAssertEqual(files.map { $0.attributes["disc"] }, ["main.dol", "main.dol"])
    XCTAssertEqual(files.first?.attributes["external"], "/icube-mods/gamebanana-383315/0/widescreen_USA.dol")
    XCTAssertEqual(plan.options.map(\.isOnByDefault), [true, false])
  }

  func testNamesAreEscapedAndKeptApart() throws {
    let plan = try plan([group("A <b> \"c\"", ["a.arc"]), group("A <b> \"c\"", ["b.arc"])], modName: "Tom & Jerry")
    let options = try elements(of: plan.xml).filter { $0.name == "option" }
    XCTAssertEqual(options.map { $0.attributes["name"] }, ["A <b> \"c\"", "A <b> \"c\" (2)"])
  }

  func testWithoutAGameThereIsNoPack() {
    XCTAssertThrowsError(try plan([group("", ["a.arc"])], titleCode: nil)) {
      XCTAssertEqual($0 as? ModGameFilePackBuilder.BuildError, .unknownGame)
    }
    XCTAssertThrowsError(try plan([group("", ["a.arc"])], titleCode: "../")) {
      XCTAssertEqual($0 as? ModGameFilePackBuilder.BuildError, .unknownGame)
    }
    XCTAssertThrowsError(try plan([])) {
      XCTAssertEqual($0 as? ModGameFilePackBuilder.BuildError, .nothingToInstall)
    }
  }

  func testAFullGameIDIsReducedToItsTitleCode() throws {
    let xml = try plan([group("", ["a.arc"])], titleCode: "smne01").xml
    XCTAssertEqual(try elements(of: xml).first { $0.name == "id" }?.attributes, ["game": "SMN"])
  }

  func testStagingWritesAPackTheInstallerRecognises() throws {
    let source = root.appendingPathComponent("download", isDirectory: true)
    try FileManager.default.createDirectory(at: source.appendingPathComponent("Middle Flag"), withIntermediateDirectories: true)
    try Data("flag".utf8).write(to: source.appendingPathComponent("Middle Flag/middle_flag.arc"))
    let pack = ModGameFilePack(groups: [
      .init(name: "Middle Flag", directory: source.appendingPathComponent("Middle Flag"), files: ["middle_flag.arc"], mapping: .byName),
    ])
    let plan = try ModGameFilePackBuilder.plan(pack: pack, modName: "Flags", packID: "gamebanana-1", titleCode: "SMN")
    let stage = root.appendingPathComponent("stage", isDirectory: true)
    try ModGameFilePackBuilder.stage(plan, in: stage)

    XCTAssertEqual(try String(contentsOf: stage.appendingPathComponent("riivolution/gamebanana-1.xml"), encoding: .utf8), plan.xml)
    XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent("icube-mods/gamebanana-1/0/middle_flag.arc")), Data("flag".utf8))
    // The download is copied, not moved: the user may install again or pick other items from it.
    XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("Middle Flag/middle_flag.arc").path))
  }
}
