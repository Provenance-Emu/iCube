// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest
@testable import iCube

final class DefaultISOBridgeTests: XCTestCase {
  private let localKey = "icube.defaultISO.localSelection"
  private let configKey = "Dolphin.Core.DefaultISO"
  private var folder: URL!
  private var savedBase: [String: String] = [:]
  private var savedLocal: Any?

  override func setUpWithError() throws {
    savedBase = DOLConfigBridge.baseLayerSnapshot()
    savedLocal = UserDefaults.standard.object(forKey: localKey)
    DOLConfigBridge.clearMainDefaultISO()
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("DefaultISOTests-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDown() {
    DOLConfigBridge.clearMainDefaultISO()
    DOLConfigBridge.restoreBaseLayerSnapshot(savedBase)
    if let savedLocal { UserDefaults.standard.set(savedLocal, forKey: localKey) }
    else { UserDefaults.standard.removeObject(forKey: localKey) }
    DOLConfigBridge.flushSettingsToDisk()
    try? FileManager.default.removeItem(at: folder)
  }

  /// Synthetic disc header, no copyrighted game bytes. DiscIO uses these magic words to
  /// recognize mountable image containers; this tests bridge routing, not real-game emulation.
  private func disc(_ name: String = "base.iso", wii: Bool = false) throws -> URL {
    let path = folder.appendingPathComponent(name)
    var bytes = Data(repeating: 0, count: 0x8000)
    bytes.replaceSubrange(0..<6, with: Data("TEST01".utf8))
    bytes.replaceSubrange((wii ? 0x18 : 0x1c)..<(wii ? 0x1c : 0x20),
                          with: wii ? [0x5d, 0x1c, 0x9e, 0xa3] : [0xc2, 0x33, 0x9f, 0x3d])
    try bytes.write(to: path)
    return path
  }

  private func injectLegacy(_ path: String) {
    var snapshot = DOLConfigBridge.baseLayerSnapshot()
    snapshot[configKey] = path
    DOLConfigBridge.restoreBaseLayerSnapshot(snapshot)
  }

  private func assertNoSyncedPath(file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(DOLConfigBridge.baseLayerSnapshot().keys.contains { $0.lowercased() == configKey.lowercased() }, file: file, line: line)
  }

  func test_selectionPersistsLocally_andUsesOnlyCurrentRunConfig() throws {
    let image = try disc()
    XCTAssertTrue(DOLConfigBridge.setMainDefaultISO(image.path))
    XCTAssertEqual(DOLConfigBridge.defaultISOSelectionPath(), image.path)
    XCTAssertEqual(DOLConfigBridge.mainDefaultISO(), image.path)
    XCTAssertTrue(DOLConfigBridge.defaultISOSelectionIsAvailable())
    let stored = try XCTUnwrap(UserDefaults.standard.dictionary(forKey: localKey))
    let relative = try XCTUnwrap(stored["relativePath"] as? String)
    XCTAssertFalse(relative.hasPrefix("/"))
    XCTAssertNil(stored["absolutePath"])
    assertNoSyncedPath()
    DOLConfigBridge.flushSettingsToDisk()
    XCTAssertFalse(try XCTUnwrap(DOLConfigBridge.savedBaseConfigSnapshot()).keys.contains { $0.lowercased() == configKey.lowercased() })
    // The bridge has no cached selection: reading/revalidating reconstructs it from preferences.
    XCTAssertTrue(DOLConfigBridge.prepareDefaultISOForBoot())
    XCTAssertEqual(DOLConfigBridge.mainDefaultISO(), image.path)
  }

  func test_relativeSelectionRebasesAgainstCurrentSandbox_andRejectsTraversal() throws {
    let image = try disc()
    let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
    let relative = String(image.path.dropFirst(home.count + 1))
    UserDefaults.standard.set(["relativePath": relative], forKey: localKey)
    XCTAssertEqual(DOLConfigBridge.defaultISOSelectionPath(), image.path)
    XCTAssertTrue(DOLConfigBridge.prepareDefaultISOForBoot())
    UserDefaults.standard.set(["relativePath": "../foreign/base.iso"], forKey: localKey)
    XCTAssertEqual(DOLConfigBridge.defaultISOSelectionPath(), "")
  }

  func test_unusableChoicesAreRejected_withoutReplacingSelection() throws {
    let image = try disc()
    XCTAssertTrue(DOLConfigBridge.setMainDefaultISO(image.path))
    for name in ["junk.iso", "launcher.dol", "launcher.elf", "channel.wad"] {
      let junk = folder.appendingPathComponent(name)
      try Data("not a disc".utf8).write(to: junk)
      XCTAssertFalse(DOLConfigBridge.setMainDefaultISO(junk.path), name)
      XCTAssertEqual(DOLConfigBridge.defaultISOSelectionPath(), image.path)
    }
    for path in [folder.path, folder.appendingPathComponent("missing.iso").path, "https://example.com/base.iso"] {
      XCTAssertFalse(DOLConfigBridge.setMainDefaultISO(path))
    }
    XCTAssertEqual(DOLConfigBridge.mainDefaultISO(), image.path)
  }

  func test_wiiDiscIsAccepted() throws {
    let image = try disc("wii.iso", wii: true)
    XCTAssertTrue(DOLConfigBridge.setMainDefaultISO(image.path))
    XCTAssertEqual(DOLConfigBridge.mainDefaultISO(), image.path)
  }

  func test_renamedOrDeletedSelectionRemainsVisible_butCannotReachCore() throws {
    let image = try disc()
    XCTAssertTrue(DOLConfigBridge.setMainDefaultISO(image.path))
    let renamed = folder.appendingPathComponent("renamed.iso")
    try FileManager.default.moveItem(at: image, to: renamed)
    XCTAssertEqual(DOLConfigBridge.defaultISOSelectionPath(), image.path)
    XCTAssertFalse(DOLConfigBridge.defaultISOSelectionIsAvailable())
    XCTAssertFalse(DOLConfigBridge.prepareDefaultISOForBoot())
    XCTAssertEqual(DOLConfigBridge.mainDefaultISO(), "")
    XCTAssertTrue(DOLConfigBridge.setMainDefaultISO(renamed.path))
    try FileManager.default.removeItem(at: renamed)
    XCTAssertFalse(DOLConfigBridge.prepareDefaultISOForBoot())
    XCTAssertEqual(DOLConfigBridge.defaultISOSelectionPath(), renamed.path)
    XCTAssertEqual(DOLConfigBridge.mainDefaultISO(), "")
    assertNoSyncedPath()
  }

  func test_clearRemovesSelection_andDoesNotBlockBoot() throws {
    XCTAssertTrue(DOLConfigBridge.setMainDefaultISO(try disc().path))
    DOLConfigBridge.clearMainDefaultISO()
    XCTAssertEqual(DOLConfigBridge.defaultISOSelectionPath(), "")
    XCTAssertEqual(DOLConfigBridge.mainDefaultISO(), "")
    XCTAssertTrue(DOLConfigBridge.prepareDefaultISOForBoot())
    XCTAssertNotNil(UserDefaults.standard.dictionary(forKey: localKey), "Clearing must retain the one-time migration marker")
    assertNoSyncedPath()
  }

  func test_legacyMigrationAcceptsCurrentSandboxOnce_andIgnoresLaterImports() throws {
    let original = try disc()
    UserDefaults.standard.removeObject(forKey: localKey)
    injectLegacy(original.path)
    DOLConfigBridge.migrateLegacyDefaultISO()
    XCTAssertEqual(DOLConfigBridge.defaultISOSelectionPath(), original.path)
    assertNoSyncedPath()
    let imported = try disc("another.iso")
    injectLegacy(imported.path)
    DOLConfigBridge.migrateLegacyDefaultISO()
    XCTAssertEqual(DOLConfigBridge.defaultISOSelectionPath(), original.path)
    assertNoSyncedPath()
    DOLConfigBridge.clearMainDefaultISO()
    injectLegacy(imported.path)
    DOLConfigBridge.migrateLegacyDefaultISO()
    XCTAssertEqual(DOLConfigBridge.defaultISOSelectionPath(), "")
    assertNoSyncedPath()
  }

  func test_foreignLegacySandboxIsNeverAdopted() {
    UserDefaults.standard.removeObject(forKey: localKey)
    injectLegacy("/var/mobile/Containers/Data/Application/FOREIGN/Documents/base.iso")
    DOLConfigBridge.migrateLegacyDefaultISO()
    XCTAssertEqual(DOLConfigBridge.defaultISOSelectionPath(), "")
    XCTAssertTrue(DOLConfigBridge.prepareDefaultISOForBoot())
    XCTAssertEqual(DOLConfigBridge.mainDefaultISO(), "")
    assertNoSyncedPath()
  }

  func test_libraryActionOnlyOffersExistingLocalDisc() throws {
    let image = try disc()
    let item = try XCTUnwrap(DiscImageBridge.gameItem(forPath: image.path))
    XCTAssertTrue(DefaultISOLibraryAction.isOffered(for: item))
    try FileManager.default.removeItem(at: image)
    XCTAssertFalse(DefaultISOLibraryAction.isOffered(for: item))
  }

  func test_validDiscChangeWithoutRunningCoreIsRejectedWithoutChangingSelection() throws {
    let image = try disc()
    XCTAssertFalse(TVEmulationBridge.isRunning(), "This bridge regression must not boot a core")
    XCTAssertTrue(DOLConfigBridge.setMainDefaultISO(image.path))
    XCTAssertEqual(TVEmulationBridge.changeDisc(atPath: image.path), .noRunningGame)
    XCTAssertEqual(DOLConfigBridge.defaultISOSelectionPath(), image.path)
    XCTAssertEqual(DOLConfigBridge.mainDefaultISO(), image.path)
  }

  func test_managementExplainsUnavailableSelection_andClearIsAnExplicitAction() {
    var clears = 0
    let missing = DefaultISOSettingsModelBuilder.make(
      state: DefaultISOSelectionState(path: "/local/missing.iso", available: false),
      pathView: AnyView(EmptyView()), clear: { clears += 1 }, done: {})
    XCTAssertEqual(missing.item(id: "default-iso-status")?.title, DefaultISOSelectionState.unavailableMessage)
    XCTAssertEqual(missing.item(id: "default-iso-path")?.description, "/local/missing.iso")
    XCTAssertTrue(missing.item(id: "clear-default-iso")?.isEnabled == true)
    XCTAssertTrue(missing.item(id: "clear-default-iso")?.activateInPlace() == true)
    XCTAssertEqual(clears, 1)
    let empty = DefaultISOSettingsModelBuilder.make(state: DefaultISOSelectionState(), pathView: AnyView(EmptyView()), clear: { clears += 1 }, done: {})
    XCTAssertEqual(empty.item(id: "default-iso-status")?.title, "No Default ISO selected")
    XCTAssertNil(empty.item(id: "default-iso-path"))
    XCTAssertFalse(empty.item(id: "clear-default-iso")?.isEnabled == true)
    _ = empty.item(id: "clear-default-iso")?.activateInPlace()
    XCTAssertEqual(clears, 1)
  }
}
