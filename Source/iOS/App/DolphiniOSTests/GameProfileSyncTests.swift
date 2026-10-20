import Foundation
import PVCloudSync
import XCTest
@testable import iCube

final class GameProfileSyncTests: XCTestCase {
  private func fixture() throws -> (URL, GameProfiles) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GameProfileSync-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("game_profiles.json")
    return (file, GameProfiles(fileURL: file))
  }

  func testLocalEditBeforeSyncReloadPreservesRemoteGame() throws {
    let (file, store) = try fixture()
    store.setProfile(GameProfile(irMode: 1), for: "LOCAL")
    var remote = GameProfile(irMode: 2)
    remote.updatedAt = Date().addingTimeInterval(-5)
    try JSONEncoder().encode(["REMOTE": remote]).write(to: file)
    store.setProfile(GameProfile(irMode: 3), for: "LOCAL")
    let saved = try JSONDecoder().decode([String: GameProfile].self, from: Data(contentsOf: file))
    XCTAssertEqual(saved["LOCAL"]?.irMode, 3)
    XCTAssertEqual(saved["REMOTE"]?.irMode, 2)
  }

  func testReloadMergesRecentLocalEditsAndRemoteGames() throws {
    let (file, store) = try fixture()
    store.setProfile(GameProfile(irMode: 1), for: "LOCAL")
    var stale = GameProfile(irMode: 2)
    stale.updatedAt = Date().addingTimeInterval(-10)
    try JSONEncoder().encode(["LOCAL": stale, "REMOTE": stale]).write(to: file)
    store.reloadAfterSync()
    XCTAssertEqual(store.profile(for: "LOCAL")?.irMode, 1)
    XCTAssertEqual(store.profile(for: "REMOTE")?.irMode, 2)
    let saved = try JSONDecoder().decode([String: GameProfile].self, from: Data(contentsOf: file))
    XCTAssertEqual(saved["LOCAL"]?.irMode, 1)
  }

  func testMalformedReloadKeepsPriorMemory() throws {
    let (file, store) = try fixture()
    store.setProfile(GameProfile(irMode: 1), for: "LOCAL")
    try Data("malformed".utf8).write(to: file)
    store.reloadAfterSync()
    XCTAssertEqual(store.profile(for: "LOCAL")?.irMode, 1)
  }

  func testExclusionEditAdoptsCurrentRemoteProfileFields() throws {
    let (file, store) = try fixture()
    var remote = GameProfile(irMode: 2)
    remote.updatedAt = Date()
    try JSONEncoder().encode(["REMOTE": remote]).write(to: file)
    store.setExcludedFromNearbySharing(true, forGameID: "REMOTE")
    XCTAssertTrue(store.isExcludedFromNearbySharing(gameID: "REMOTE"))
    XCTAssertEqual(store.profile(for: "REMOTE")?.irMode, 2)
  }

  func testSavingGraphicsSnapshotDoesNotClearSharingExclusion() throws {
    let (_, store) = try fixture()
    store.setExcludedFromNearbySharing(true, forGameID: "LOCAL")
    store.setProfile(GameProfile(irMode: 3), for: "LOCAL")
    XCTAssertTrue(store.isExcludedFromNearbySharing(gameID: "LOCAL"))
    XCTAssertEqual(store.profile(for: "LOCAL")?.irMode, 3)
    store.setExcludedFromNearbySharing(false, forGameID: "LOCAL")
    XCTAssertFalse(store.isExcludedFromNearbySharing(gameID: "LOCAL"))
  }

  func testPurgedProfilesDirectoryIsRecreated() throws {
    let (file, store) = try fixture()
    store.setProfile(GameProfile(irMode: 1), for: "LOCAL")
    try FileManager.default.removeItem(at: file.deletingLastPathComponent())
    store.setExcludedFromNearbySharing(true, forGameID: "LOCAL")
    let saved = try JSONDecoder().decode([String: GameProfile].self, from: Data(contentsOf: file))
    XCTAssertEqual(saved["LOCAL"]?.irMode, 1)
    XCTAssertEqual(saved["LOCAL"]?.excludedFromNearbySharing, true)
  }

  func testStampedResetSurvivesOldPeerAndPreservesExclusion() throws {
    let (file, store) = try fixture()
    let shader = UserDefaults.standard.object(forKey: "shader_preset_path")
    defer {
      if let shader { UserDefaults.standard.set(shader, forKey: "shader_preset_path") }
      else { UserDefaults.standard.removeObject(forKey: "shader_preset_path") }
    }
    store.setProfile(GameProfile(irMode: 2), for: "LOCAL")
    let oldPeer = try Data(contentsOf: file)
    store.clearProfile(for: "LOCAL")
    XCTAssertFalse(store.hasSavedProfile(for: "LOCAL"))
    let reset = try Data(contentsOf: file)
    let merged = try KeyedTimestampDocumentMerger(timestampKey: "updatedAt").merge(local: reset, remote: oldPeer)
    let result = try JSONDecoder().decode([String: GameProfile].self, from: merged)
    XCTAssertNil(result["LOCAL"]?.irMode)
    try merged.write(to: file)
    store.reloadAfterSync()
    XCTAssertFalse(store.hasSavedProfile(for: "LOCAL"))
    XCTAssertNil(store.profile(for: "LOCAL"))
  }

  func testResetPreservesExclusionAndRemovesRuntimeOverrides() throws {
    let (_, store) = try fixture()
    let shader = UserDefaults.standard.object(forKey: "shader_preset_path")
    defer {
      if let shader { UserDefaults.standard.set(shader, forKey: "shader_preset_path") }
      else { UserDefaults.standard.removeObject(forKey: "shader_preset_path") }
    }
    store.setProfile(GameProfile(irMode: 2, excludedFromNearbySharing: true), for: "LOCAL")
    store.clearProfile(for: "LOCAL")
    XCTAssertTrue(store.isExcludedFromNearbySharing(gameID: "LOCAL"))
    XCTAssertNil(store.profile(for: "LOCAL"))
    XCTAssertFalse(store.hasSavedProfile(for: "LOCAL"))
    store.setProfile(GameProfile(irMode: 3), for: "LOCAL")
    XCTAssertTrue(store.hasSavedProfile(for: "LOCAL"))
    XCTAssertEqual(store.profile(for: "LOCAL")?.irMode, 3)
  }
}
