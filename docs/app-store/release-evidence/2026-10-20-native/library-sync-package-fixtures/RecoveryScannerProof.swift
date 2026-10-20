import Foundation
import PVSyncRules
import PVCloudSync
@main enum RecoveryScannerProof {
  static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecoveryScanner-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let name = String(repeating: "a", count: 64) + ".json"
    let accepted = "Profiles/LibraryMetadata/" + name
    let excluded = ["Profiles/LibraryMetadataRecovery/" + name,
      "Profiles/LibraryMetadataRecovery/nested/" + name,
      "Profiles/librarymetadatarecovery/" + name,
      "Profiles/LibraryMetadata/../LibraryMetadataRecovery/" + name]
    precondition(SyncClassifier.classify(relativePath: accepted) == .gameProfile)
    for path in excluded { precondition(SyncClassifier.classify(relativePath: path) == nil) }
    for path in [accepted] + excluded.prefix(3) {
      let file = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("{}".utf8).write(to: file)
    }
    let files = await UserDataScanner(rootDirectory: root).scanLocalFiles()
    precondition(files.map(\.relativePath) == [accepted])
    print("PVSyncRules 1.0.2: canonical metadata accepted; 4 recovery paths rejected. Actual UserDataScanner: 1 primary shard scanned, 3 recovery files excluded.")
  }
}
