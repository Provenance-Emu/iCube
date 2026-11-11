import PVSyncRules
import XCTest

@testable import iCube

final class EmulationServerBackupTests: XCTestCase {
  func testOnlySaveCategoriesAreUploadedToBackupServers() {
    for type in [SyncableFileType.gameCubeMemoryCard, .wiiSave, .gbaSave] {
      XCTAssertEqual(EmulationServerBackupWorker.assetKind(type), "battery_save")
    }
    for type in [SyncableFileType.saveState, .resumeState, .saveStateMetadata, .saveStateThumbnail] {
      XCTAssertEqual(EmulationServerBackupWorker.assetKind(type), "save_state")
    }
    for type in [SyncableFileType.config, .firmware, .wiiSystem, .wiiChannel, .gameSettings, .libraryState] {
      XCTAssertNil(EmulationServerBackupWorker.assetKind(type))
    }
  }

  func testItemIDsCannotChangeTheRequestPath() {
    XCTAssertTrue(EmulationServerBackupTarget.isValidItemID("item-with_123"))
    for value in ["", "../items", "id?x=1", "id#fragment", "id/child", String(repeating: "x", count: 129)] {
      XCTAssertFalse(EmulationServerBackupTarget.isValidItemID(value))
    }
  }

  func testHostnameDefaultsAndExplicitPorts() throws {
    XCTAssertEqual(try EmulationServer(address: " Studio.local ").origin.absoluteString, "http://studio.local:8473")
    XCTAssertEqual(try EmulationServer(address: "http://studio.local").origin.absoluteString, "http://studio.local:8473")
    XCTAssertEqual(try EmulationServer(address: "studio.local:9000").origin.absoluteString, "http://studio.local:9000")
    XCTAssertEqual(try EmulationServer(address: "https://studio.local").origin.absoluteString, "https://studio.local")
  }
}
