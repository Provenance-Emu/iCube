// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
@testable import iCube

@MainActor
final class BundledControllerSkinsTests: XCTestCase {
  private var root: URL!
  private var defaults: UserDefaults!
  private var suite: String!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    suite = "BundledControllerSkinsTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)!
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
    defaults.removePersistentDomain(forName: suite)
  }

  private func seed(_ library: SkinLibrary) async throws {
    try await BundledControllerSkins.installIfNeededInBackground(library: library, defaults: defaults,
                                                                 bundle: Bundle(for: AppDelegate.self))
  }

  func testShippedArchiveImportsAndHasUsablePhoneLayoutsAndMappedControls() async throws {
    let library = SkinLibrary(rootURL: root)
    try await seed(library)
    let skin = try XCTUnwrap(library.skins.first)
    XCTAssertEqual(skin.id, BundledControllerSkins.identifier)
    XCTAssertEqual(skin.gameType, .gameCube)
    let info = try SkinInfo.load(directory: skin.directory)
    XCTAssertNil(info.representation(device: .ipad, orientation: .portrait))
    for orientation in TouchOverlayOrientation.allCases {
      let rep = try XCTUnwrap(info.representation(device: .iphone, orientation: orientation))
      let canvas = orientation == .portrait ? CGSize(width: 393, height: 852) : CGSize(width: 852, height: 393)
      let layout = SkinLayout.make(rep, canvas: canvas)
      let game = try XCTUnwrap(layout.gameRect)
      XCTAssertGreaterThan(game.width, 0)
      XCTAssertGreaterThan(game.height, 0)
      XCTAssertTrue(CGRect(origin: .zero, size: canvas).contains(game))
      XCTAssertEqual(layout.items.count, rep.items.count)
      XCTAssertEqual(SkinOverlayInput(layout: layout, padKind: .gameCube).sticks.count, 2)
      var buttons = Set<String>()
      for item in rep.items {
        if case .buttons(let names) = item.inputs {
          for name in names {
            buttons.insert(name)
            XCTAssertNotNil(SkinInputMap.action(for: [name], padKind: .gameCube), name)
          }
        }
        for asset in [item.asset?.normal, item.thumbstick?.name].compactMap({ $0 }) {
          XCTAssertTrue(FileManager.default.fileExists(atPath: skin.directory.appendingPathComponent(asset).path), asset)
          XCTAssertNotNil(SkinAssetRenderer.image(named: asset, in: skin.directory,
                                                  size: CGSize(width: 44, height: 44), scale: 2), asset)
        }
      }
      for expected in ["a", "b", "x", "y", "r1", "start", "l2", "r2", "quickSave", "quickLoad"] {
        XCTAssertTrue(buttons.contains(expected), expected)
      }
    }
  }

  func testFreshLibraryGetsAvailabilityWithoutSelectingAnyPad() async throws {
    let library = SkinLibrary(rootURL: root)
    try await seed(library)
    for orientation in TouchOverlayOrientation.allCases {
      for kind in TouchOverlayPadKind.allCases {
        XCTAssertNil(library.selectedSkin(for: kind, orientation: orientation))
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("selection.json").path))
  }

  func testExistingSelectionsAndExplicitNoneSurviveMigration() async throws {
    let library = SkinLibrary(rootURL: root)
    try await seed(library)
    let skin = try XCTUnwrap(library.skins.first)
    library.select(skin, for: .gameCube, orientation: .landscape)
    library.select(skin, for: .gameCube, orientation: .portrait)
    library.select(nil, for: .gameCube, orientation: .portrait)
    let selectionURL = root.appendingPathComponent("selection.json")
    let before = try Data(contentsOf: selectionURL)
    defaults.removeObject(forKey: BundledControllerSkins.seedKey)
    let reloaded = SkinLibrary(rootURL: root)
    try await seed(reloaded)
    XCTAssertEqual(try Data(contentsOf: selectionURL), before)
    XCTAssertNil(reloaded.selectedSkin(for: .gameCube, orientation: .portrait))
    XCTAssertEqual(reloaded.selectedSkin(for: .gameCube, orientation: .landscape)?.id, skin.id)
  }

  func testDeletingBundledSkinDoesNotReinstallOnNextLaunch() async throws {
    let library = SkinLibrary(rootURL: root)
    try await seed(library)
    try library.delete(XCTUnwrap(library.skins.first))
    let reloaded = SkinLibrary(rootURL: root)
    try await seed(reloaded)
    XCTAssertTrue(reloaded.skins.isEmpty)
  }

  func testWrongArchiveDoesNotMarkSuccessfulSeed() throws {
    let archive = root.appendingPathExtension("manicskin")
    defer { try? FileManager.default.removeItem(at: archive) }
    try Data("wrong bytes".utf8).write(to: archive)
    let library = SkinLibrary(rootURL: root)
    XCTAssertThrowsError(try BundledControllerSkins.install(archive: archive, library: library, defaults: defaults))
    XCTAssertFalse(defaults.bool(forKey: BundledControllerSkins.seedKey))
    XCTAssertTrue(library.skins.isEmpty)
  }
}
#endif
