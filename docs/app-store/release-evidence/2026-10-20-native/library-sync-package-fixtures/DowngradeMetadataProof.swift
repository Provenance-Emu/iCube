import Foundation
import CloudKit
import PVSyncRules
@testable import PVCloudSync
@main enum DowngradeMetadataProof {
  static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DowngradeMetadata-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let path = "Profiles/LibraryMetadata/" + String(repeating: "a", count: 64) + ".json"
    let file = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: file)
    precondition(SyncClassifier.classify(relativePath: path) == nil)
    precondition(!SyncableFileType.gameProfile.propagatesDeletes)
    let local = await UserDataScanner(rootDirectory: root).scanLocalFiles()
    precondition(local.isEmpty)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let indexURL = root.appendingPathComponent("index.json")
    let upgradedIndex = SyncIndexStore(fileURL: indexURL)
    _ = await upgradedIndex.bind(toAccountIdentity: "same-account")
    await upgradedIndex.record(path: path, checksum: "same-bytes", lastModified: date)
    try await upgradedIndex.save()
    let downgradedIndex = SyncIndexStore(fileURL: indexURL)
    _ = await downgradedIndex.bind(toAccountIdentity: "same-account")
    let remembered = await downgradedIndex.snapshot()
    precondition(remembered[path]?.isLive == true)
    let record = CKRecord(recordType: "TestUserFile", recordID: CKRecord.ID(recordName: path))
    record[CloudSyncConstants.Field.fileName] = path as CKRecordValue
    record[CloudSyncConstants.Field.fileType] = SyncableFileType.gameProfile.rawValue as CKRecordValue
    record[CloudSyncConstants.Field.fileSize] = Int64(2) as CKRecordValue
    record[CloudSyncConstants.Field.lastModified] = date as CKRecordValue
    record[CloudSyncConstants.Field.checksum] = "same-bytes" as CKRecordValue
    precondition(CloudKitSyncProvider.remoteRecord(from: record) == nil)
    let plan = SyncPlanner().plan(local: local, remote: RemoteSyncSnapshot(), index: remembered, policy: .default)
    precondition(plan.isEmpty)
    let remote = SyncableFileMetadata(relativePath: path, lastModified: date, fileSize: 2,
      checksum: "same-bytes", fileType: .gameProfile)
    let bypass = SyncPlanner().plan(local: local, remote: RemoteSyncSnapshot(files: [remote]), index: remembered, policy: .default)
    guard bypass.count == 1, case .download = bypass[0] else { fatalError("Merged document unexpectedly inferred deletion") }
    print("PVSyncRules 1.0.1 / PVCloudSync 82ff294: retained same-account live index row=1; local scanner shard rows=0; actual CloudKit decoder drops shard=true; normal planner steps=0; injected gameProfile remote-only step=download; inferred tombstones=0.")
  }
}
