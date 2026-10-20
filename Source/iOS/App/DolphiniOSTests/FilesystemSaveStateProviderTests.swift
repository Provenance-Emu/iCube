import XCTest
@testable import iCube

final class FilesystemSaveStateProviderTests: XCTestCase {
  func test_scanExcludesWorkerRecordingAndUndoArtifactsButKeepsSlot99AndLegacyExports() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let committed = ["GALE01.s01", "GALE01.s99", "GALE01.auto", "GALE01.sav"]
    let artifacts = ["GALE01.s0142.tmp", "GALE01.s0142.tmp.previous", "GALE01.s01.dtm", "lastState.sav", "undo.sav", "GALE01.s00", "notes.txt", "GALE01.s01.json", "GALE01.s01.png"]
    for name in committed + artifacts {
      try Data([0]).write(to: folder.appendingPathComponent(name))
    }
    let groups = await FilesystemSaveStateProvider(root: folder).statesGroupedByGame()
    let observed = Set(groups.values.flatMap { $0 }.map { $0.path.lastPathComponent })
    XCTAssertEqual(observed, Set(committed))
  }
}
