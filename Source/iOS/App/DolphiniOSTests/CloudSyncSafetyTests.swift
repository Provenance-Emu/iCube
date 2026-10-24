// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVCloudSync
import enum PVLibraryMetadata.LibraryMetadataDocument
import PVSyncRules
import XCTest
@testable import iCube

private actor SafetySyncProvider: SyncProvider {
  enum Mode { case uploadFailure, downloadFailure, suspended, suspendedSnapshot, success }
  nonisolated let providerName = "Safety Test"
  nonisolated let kind: SyncProviderKind = .iCloud
  let mode: Mode
  private var downloading = false
  private var startWaiter: CheckedContinuation<Void, Never>?
  private var payloadWaiter: CheckedContinuation<Data, Never>?
  private var downloads = 0
  private var payload = Data("remote".utf8)
  private var uploadedPaths: [String] = []
  private var uploadedData: [String: Data] = [:]
  private var remoteSnapshot = RemoteSyncSnapshot()
  private var snapshotWaiter: CheckedContinuation<RemoteSyncSnapshot, Never>?
  private var didSuspendSnapshot = false
  init(_ mode: Mode) { self.mode = mode }
  func unavailableReason() async -> SyncUnavailableReason? { nil }
  func initialize() async throws {}
  func accountIdentity() async -> String? { "safety-account" }
  func upload(metadata: SyncableFileMetadata, data: Data) async throws {
    uploadedPaths.append(metadata.relativePath)
    uploadedData[metadata.relativePath] = data
    if mode == .uploadFailure { throw SyncProviderError.uploadFailed("Expected failure") }
  }
  func download(metadata: SyncableFileMetadata) async throws -> Data {
    downloads += 1
    if mode == .downloadFailure { throw SyncProviderError.downloadFailed("Expected failure") }
    downloading = true
    startWaiter?.resume()
    startWaiter = nil
    if mode == .suspended { return await withCheckedContinuation { payloadWaiter = $0 } }
    return payload
  }
  func waitUntilDownloading() async {
    if downloading { return }
    await withCheckedContinuation { startWaiter = $0 }
  }
  func finishDownload() { payloadWaiter?.resume(returning: payload); payloadWaiter = nil }
  func setPayload(_ data: Data) { payload = data }
  func downloadCount() -> Int { downloads }
  func uploads() -> [String] { uploadedPaths }
  func uploadedBytes(path: String) -> Data? { uploadedData[path] }
  func setSnapshot(_ snapshot: RemoteSyncSnapshot) { remoteSnapshot = snapshot }
  func fetchRemoteSnapshot() async throws -> RemoteSyncSnapshot {
    if mode == .suspendedSnapshot && !didSuspendSnapshot {
      didSuspendSnapshot = true
      downloading = true
      startWaiter?.resume()
      startWaiter = nil
      return await withCheckedContinuation { snapshotWaiter = $0 }
    }
    return remoteSnapshot
  }
  func finishSnapshot(_ metadata: SyncableFileMetadata) {
    snapshotWaiter?.resume(returning: RemoteSyncSnapshot(files: [metadata]))
    snapshotWaiter = nil
  }
  func writeTombstone(_ tombstone: SyncTombstone) async throws {}
  func purgeExpiredTombstones(olderThan cutoff: Date) async throws {}
  func purgeAllData() async throws {}
}

// Pauses the actual scanner write immediately before its atomic replacement.
private final class CommitBarrierFileManager: FileManager, @unchecked Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  private let stateLock = NSLock()
  private var armed = false
  private var pauseLeaf = "Profiles"
  func arm(atLeaf leaf: String = "Profiles") { stateLock.lock(); armed = true; pauseLeaf = leaf; stateLock.unlock() }
  override func fileExists(atPath path: String) -> Bool {
    stateLock.lock()
    let pause = armed && URL(fileURLWithPath: path).lastPathComponent == pauseLeaf
    if pause { armed = false }
    stateLock.unlock()
    if pause { entered.signal(); _ = release.wait(timeout: .now() + 5) }
    return super.fileExists(atPath: path)
  }
}

@MainActor
final class CloudSyncSafetyTests: XCTestCase {
  private struct Fixture {
    let root: URL
    let file: URL
    let conflict: SyncConflict
    let provider: SafetySyncProvider
    let index: SyncIndexStore
    let trash: SyncTrash
    let coordinator: CloudSyncCoordinator
    let gate: SyncLocalIOGate
  }

  private func fixture(_ mode: SafetySyncProvider.Mode, path: String = "StateSaves/TEST01.s01") throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSyncSafety-\(UUID())")
    let file = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let original = Data("original".utf8)
    try original.write(to: file)
    let localDate = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: localDate], ofItemAtPath: file.path)
    let local = SyncableFileMetadata(relativePath: path, lastModified: localDate,
                                    fileSize: Int64(original.count), checksum: SyncChecksum.sha256Hex(original), fileType: path.lowercased().hasPrefix("config/") ? .config : .saveState)
    var remote = local
    remote.lastModified = localDate.addingTimeInterval(-2) // The user's explicit remote choice may be older.
    remote.fileSize = 6
    remote.checksum = SyncChecksum.sha256Hex(Data("remote".utf8))
    let conflict = SyncConflict(local: local, remote: remote)
    let provider = SafetySyncProvider(mode)
    let index = SyncIndexStore(fileURL: root.appendingPathComponent("index.json"))
    let trash = SyncTrash(rootURL: root.appendingPathComponent("Trash"))
    let gate = SyncLocalIOGate()
    let coordinator = CloudSyncCoordinator(network: StaticNetworkState.unconstrained, enabled: true,
      scanner: UserDataScanner(rootDirectory: root), provider: provider, index: index,
      trash: trash, localIOGate: gate, pendingConflicts: [conflict])
    let enabledKey = "icube.cloudSync.enabled"
    let savedEnabled = UserDefaults.standard.object(forKey: enabledKey)
    addTeardownBlock {
      // Exercise the real shutdown policy: cancel timers/tasks/observers before removing files.
      await coordinator.handle(.enabledChanged(false))
      if let savedEnabled { UserDefaults.standard.set(savedEnabled, forKey: enabledKey) }
      else { UserDefaults.standard.removeObject(forKey: enabledKey) }
      try? FileManager.default.removeItem(at: root)
    }
    return Fixture(root: root, file: file, conflict: conflict, provider: provider, index: index, trash: trash, coordinator: coordinator, gate: gate)
  }

  private func metadataShard(_ mode: SafetySyncProvider.Mode) throws -> (Fixture, LibraryMetadataStore.Identity, String) {
    let identity = LibraryMetadataStore.Identity.game(gameID: "TEST01", discNumber: 0, revision: 0)!
    let path = "Profiles/LibraryMetadata/" + identity.fileName
    return (try fixture(mode, path: path), identity, path)
  }

  private func shardBytes(identity: LibraryMetadataStore.Identity, field: String, value: Any, stamp: Double = 100) throws -> Data {
    try JSONSerialization.data(withJSONObject: [identity.rawValue + ":" + field: ["updatedAt": stamp, "value": value]], options: [.sortedKeys])
  }

  private func shardMetadata(path: String, bytes: Data, type: SyncableFileType = .gameProfile) -> SyncableFileMetadata {
    SyncableFileMetadata(relativePath: path, lastModified: Date(), fileSize: Int64(bytes.count),
      checksum: SyncChecksum.sha256Hex(bytes), fileType: type)
  }

  func testInitialScannerLeaseDrainsBeforeCoreBootCanOpenFiles() async throws {
    let f = try fixture(.success)
    let barrier = CommitBarrierFileManager()
    let coordinator = CloudSyncCoordinator(network: StaticNetworkState.unconstrained, enabled: true,
      scanner: UserDataScanner(rootDirectory: f.root, fileManager: barrier), provider: f.provider,
      index: f.index, trash: f.trash, localIOGate: f.gate)
    addTeardownBlock { await coordinator.handle(.enabledChanged(false)) }
    barrier.arm(atLeaf: f.root.lastPathComponent)
    await coordinator.syncNow()
    let entered = await Task.detached { barrier.entered.wait(timeout: .now() + 3) }.value
    XCTAssertEqual(entered, .success)
    let generation = f.gate.beginEmulation()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { f.gate.waitForLocalIO(); drained.signal() }
    XCTAssertEqual(drained.wait(timeout: .now() + 0.05), .timedOut)
    barrier.release.signal()
    let didDrain = await Task.detached { drained.wait(timeout: .now() + 3) }.value
    XCTAssertEqual(didDrain, .success)
    await coordinator.waitForCurrentSyncCompletion()
    let uploads = await f.provider.uploads()
    XCTAssertTrue(uploads.isEmpty)
    XCTAssertTrue(f.gate.finishCoreDrain(generation: generation))
  }

  func testLibraryEditStoreWriterWaitsForSyncCommitAndKeepsIndependentRemoteTags() async throws {
    let (f, identity, path) = try metadataShard(.suspended)
    try FileManager.default.removeItem(at: f.file)
    let store = try LibraryMetadataStore(directoryURL: f.file.deletingLastPathComponent(), withFileAccess: { operation in
      try LibraryStateStore.withFileAccess(operation)
    })
    let baseline = LibraryMetadataStore.Draft(title: "Original")
    _ = try store.commit(baseline, baseline: .init(), for: identity)
    let remote = try shardBytes(identity: identity, field: "tags", value: ["Remote Tag"])
    await f.provider.setPayload(remote)
    await f.provider.setSnapshot(RemoteSyncSnapshot(files: [shardMetadata(path: path, bytes: remote)]))
    let barrier = CommitBarrierFileManager()
    let coordinator = CloudSyncCoordinator(network: StaticNetworkState.unconstrained, enabled: true,
      scanner: UserDataScanner(rootDirectory: f.root, fileManager: barrier), provider: f.provider,
      index: f.index, trash: f.trash, localIOGate: f.gate)
    addTeardownBlock { await coordinator.handle(.enabledChanged(false)) }
    await coordinator.syncNow()
    await f.provider.waitUntilDownloading()
    barrier.arm(atLeaf: "LibraryMetadata")
    await f.provider.finishDownload()
    let entered = await Task.detached { barrier.entered.wait(timeout: .now() + 3) }.value
    XCTAssertEqual(entered, .success)
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      defer { finished.signal() }
      do { _ = try store.commit(.init(title: "Edited"), baseline: baseline, for: identity) }
      catch { XCTFail("Unexpected metadata commit error: \(error)") }
    }
    XCTAssertEqual(finished.wait(timeout: .now() + 0.05), .timedOut)
    barrier.release.signal()
    await coordinator.waitForCurrentSyncCompletion()
    XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
    try store.reload()
    let draft = try store.draft(for: identity)
    XCTAssertEqual(draft.title, "Edited")
    XCTAssertEqual(draft.tags, ["Remote Tag"])
  }

  func testLibraryEditShardUploadsThroughExistingDocumentProvider() async throws {
    let (f, identity, path) = try metadataShard(.success)
    let bytes = try shardBytes(identity: identity, field: "title", value: "Custom Title")
    try bytes.write(to: f.file)
    await f.coordinator.syncNow()
    await f.coordinator.waitForCurrentSyncCompletion()
    let uploaded = await f.provider.uploadedBytes(path: path)
    XCTAssertEqual(uploaded, bytes)
  }

  func testLibraryEditShardDownloadNotifiesItsRelativePath() async throws {
    let (f, identity, path) = try metadataShard(.success)
    try FileManager.default.removeItem(at: f.file)
    let bytes = try shardBytes(identity: identity, field: "title", value: "Custom Title")
    await f.provider.setPayload(bytes)
    await f.provider.setSnapshot(RemoteSyncSnapshot(files: [shardMetadata(path: path, bytes: bytes)]))
    let notification = expectation(forNotification: CloudSyncCoordinator.documentDidChangeNotification,
      object: f.coordinator) { note in note.userInfo?[CloudSyncCoordinator.relativePathKey] as? String == path }
    await f.coordinator.syncNow()
    await f.coordinator.waitForCurrentSyncCompletion()
    await fulfillment(of: [notification], timeout: 1)
    XCTAssertEqual(try Data(contentsOf: f.file), bytes)
  }

  func testFirstDownloadMergesLibraryEditsCreatedWhileNetworkSuspends() async throws {
    let (f, identity, path) = try metadataShard(.suspended)
    try FileManager.default.removeItem(at: f.file)
    let remote = try shardBytes(identity: identity, field: "title", value: "Remote Title")
    await f.provider.setPayload(remote)
    await f.provider.setSnapshot(RemoteSyncSnapshot(files: [shardMetadata(path: path, bytes: remote)]))
    await f.coordinator.syncNow()
    await f.provider.waitUntilDownloading()
    let created = try shardBytes(identity: identity, field: "tags", value: ["Local Tag"])
    try created.write(to: f.file)
    await f.provider.finishDownload()
    await f.coordinator.waitForCurrentSyncCompletion()
    let committed = try Data(contentsOf: f.file)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: committed) as? [String: [String: Any]])
    XCTAssertEqual(object[identity.rawValue + ":title"]?["value"] as? String, "Remote Title")
    XCTAssertEqual(object[identity.rawValue + ":tags"]?["value"] as? [String], ["Local Tag"])
    let index = await f.index.snapshot()
    XCTAssertEqual(index[path]?.checksum, SyncChecksum.sha256Hex(committed))
  }

  func testLibraryEditMergeRetainsIndependentFieldsAndClearTombstones() async throws {
    let (f, identity, path) = try metadataShard(.success)
    let local = try shardBytes(identity: identity, field: "title", value: "Local Title")
    let remote = try JSONSerialization.data(withJSONObject: [
      identity.rawValue + ":tags": ["updatedAt": 200, "value": ["Racing"]],
      identity.rawValue + ":cover": ["updatedAt": 200, "value": NSNull()]
    ], options: [.sortedKeys])
    try local.write(to: f.file)
    await f.provider.setPayload(remote)
    await f.provider.setSnapshot(RemoteSyncSnapshot(files: [shardMetadata(path: path, bytes: remote)]))
    await f.coordinator.syncNow()
    await f.coordinator.waitForCurrentSyncCompletion()
    let merged = try Data(contentsOf: f.file)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: [String: Any]])
    XCTAssertEqual(object[identity.rawValue + ":title"]?["value"] as? String, "Local Title")
    XCTAssertEqual(object[identity.rawValue + ":tags"]?["value"] as? [String], ["Racing"])
    XCTAssertTrue(object[identity.rawValue + ":cover"]?["value"] is NSNull)
    let uploaded = await f.provider.uploadedBytes(path: path)
    XCTAssertEqual(uploaded, merged)
  }

  func testLibraryEditScannerMergeUsesCanonicalOpaquePrimitiveTies() async throws {
    let (f, identity, path) = try metadataShard(.success)
    let local = Data(#"{"future":2}"#.utf8)
    let remote = Data(#"{"future":9}"#.utf8)
    try local.write(to: f.file)
    await f.provider.setPayload(remote)
    await f.provider.setSnapshot(RemoteSyncSnapshot(files: [shardMetadata(path: path, bytes: remote)]))
    await f.coordinator.syncNow()
    await f.coordinator.waitForCurrentSyncCompletion()
    let expected = try LibraryMetadataDocument.merge(local: local, remote: remote, filename: identity.fileName)
    XCTAssertEqual(try Data(contentsOf: f.file), expected)
    // The tie keeps the greater canonical bytes, the remote 9, so the merge equals the
    // remote copy and the coordinator has nothing to upload.
    XCTAssertEqual(expected, remote)
    let uploaded = await f.provider.uploadedBytes(path: path)
    XCTAssertNil(uploaded)
  }

  func testFirstDownloadUsesCanonicalMergerForNewLocalOpaquePrimitives() async throws {
    let (f, identity, path) = try metadataShard(.suspended)
    try FileManager.default.removeItem(at: f.file)
    let local = Data(#"{"future":2}"#.utf8)
    let remote = Data(#"{"future":9}"#.utf8)
    await f.provider.setPayload(remote)
    await f.provider.setSnapshot(RemoteSyncSnapshot(files: [shardMetadata(path: path, bytes: remote)]))
    await f.coordinator.syncNow()
    await f.provider.waitUntilDownloading()
    try local.write(to: f.file)
    await f.provider.finishDownload()
    await f.coordinator.waitForCurrentSyncCompletion()
    let expected = try LibraryMetadataDocument.merge(local: local, remote: remote, filename: identity.fileName)
    XCTAssertEqual(try Data(contentsOf: f.file), expected)
    let index = await f.index.snapshot()
    XCTAssertEqual(index[path]?.checksum, SyncChecksum.sha256Hex(expected))
  }

  func testMalformedOrWrongIdentityLibraryEditDownloadCannotReplaceGoodLocal() async throws {
    for remoteIdentity in [false, true] {
      let (f, identity, path) = try metadataShard(.success)
      let local = try shardBytes(identity: identity, field: "title", value: "Good")
      try local.write(to: f.file)
      let remote = remoteIdentity
        ? try shardBytes(identity: .game(gameID: "OTHER1", discNumber: 0, revision: 0)!, field: "title", value: "Wrong Identity")
        : Data("broken".utf8)
      await f.provider.setPayload(remote)
      await f.provider.setSnapshot(RemoteSyncSnapshot(files: [shardMetadata(path: path, bytes: remote)]))
      await f.coordinator.syncNow()
      await f.coordinator.waitForCurrentSyncCompletion()
      XCTAssertEqual(try Data(contentsOf: f.file), local)
      let uploaded = await f.provider.uploads()
      XCTAssertTrue(uploaded.isEmpty)
    }
  }

  func testLibraryEditFirstDownloadRejectsMalformedOversizeAndForgedCategory() async throws {
    for mode in ["malformed", "oversize", "category", "checksum"] {
      let (f, identity, path) = try metadataShard(.success)
      try FileManager.default.removeItem(at: f.file)
      let bytes = mode == "malformed" ? Data("broken".utf8) : try shardBytes(identity: identity, field: "title", value: "Good")
      var metadata = shardMetadata(path: path, bytes: bytes, type: mode == "category" ? .saveState : .gameProfile)
      if mode == "oversize" { metadata.fileSize = 1_048_577 }
      if mode == "checksum" { metadata.checksum = "mismatch" }
      await f.provider.setPayload(bytes)
      await f.provider.setSnapshot(RemoteSyncSnapshot(files: [metadata]))
      await f.coordinator.syncNow()
      await f.coordinator.waitForCurrentSyncCompletion()
      XCTAssertFalse(FileManager.default.fileExists(atPath: f.file.path), mode)
    }
  }

  func testProfileWriterWaitsForSyncCommitAndPreservesBothGames() async throws {
    let f = try fixture(.suspended, path: "Profiles/game_profiles.json")
    try JSONEncoder().encode([String: GameProfile]()).write(to: f.file)
    let store = GameProfiles(fileURL: f.file)
    store.setProfile(GameProfile(irMode: 1), for: "LOCAL")
    var remote = GameProfile(irMode: 2)
    remote.updatedAt = Date()
    let bytes = try JSONEncoder().encode(["REMOTE": remote])
    await f.provider.setPayload(bytes)
    await f.provider.setSnapshot(RemoteSyncSnapshot(files: [SyncableFileMetadata(
      relativePath: "Profiles/game_profiles.json", lastModified: Date(), fileSize: Int64(bytes.count),
      checksum: SyncChecksum.sha256Hex(bytes), fileType: .gameProfile)]))
    let barrier = CommitBarrierFileManager()
    let coordinator = CloudSyncCoordinator(network: StaticNetworkState.unconstrained, enabled: true,
      scanner: UserDataScanner(rootDirectory: f.root, fileManager: barrier), provider: f.provider,
      index: f.index, trash: f.trash, localIOGate: f.gate)
    addTeardownBlock { await coordinator.handle(.enabledChanged(false)) }
    await coordinator.syncNow()
    await f.provider.waitUntilDownloading()
    barrier.arm()
    await f.provider.finishDownload()
    let entered = await Task.detached { barrier.entered.wait(timeout: .now() + 3) }.value
    XCTAssertEqual(entered, .success)
    let writerStarted = DispatchSemaphore(value: 0)
    let writerFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      writerStarted.signal()
      store.setProfile(GameProfile(irMode: 3), for: "LOCAL")
      writerFinished.signal()
    }
    XCTAssertEqual(writerStarted.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(writerFinished.wait(timeout: .now() + 0.05), .timedOut,
      "Local store writes must wait for the scanner document commit")
    barrier.release.signal()
    await coordinator.waitForCurrentSyncCompletion()
    XCTAssertEqual(writerFinished.wait(timeout: .now() + 1), .success)
    store.reloadAfterSync()
    XCTAssertEqual(store.profile(for: "LOCAL")?.irMode, 3)
    XCTAssertEqual(store.profile(for: "REMOTE")?.irMode, 2)
  }

  func testLibraryMergePreservesEditMadeWhileRemoteDownloadSuspends() async throws {
    let f = try fixture(.suspended, path: "Profiles/library_state.json")
    let original = LibraryStateDocument(games: ["TEST01": .init(launches: ["local": 1])])
    try original.encoded().write(to: f.file)
    let remote = LibraryStateDocument(games: ["REMOTE": .init(launches: ["remote": 2])])
    let remoteBytes = try remote.encoded()
    await f.provider.setPayload(remoteBytes)
    let metadata = SyncableFileMetadata(relativePath: "Profiles/library_state.json", lastModified: Date(),
      fileSize: Int64(remoteBytes.count), checksum: SyncChecksum.sha256Hex(remoteBytes), fileType: .libraryState)
    await f.provider.setSnapshot(RemoteSyncSnapshot(files: [metadata]))
    await f.coordinator.syncNow()
    await f.provider.waitUntilDownloading()
    var edited = original
    edited.games["TEST01"]?.launches["local"] = 3
    try edited.encoded().write(to: f.file, options: .atomic)
    await f.provider.finishDownload()
    await f.coordinator.waitForCurrentSyncCompletion()
    let result = try LibraryStateDocument.decode(Data(contentsOf: f.file))
    XCTAssertEqual(result.games["TEST01"]?.totalLaunches, 3)
    XCTAssertEqual(result.games["REMOTE"]?.totalLaunches, 2)
  }

  func testMalformedNewerRemoteDocumentCannotReplaceValidLocalDocument() async throws {
    let f = try fixture(.success, path: "Profiles/library_state.json")
    let bytes = try LibraryStateDocument(games: ["TEST01": .init(launches: ["local": 3])]).encoded()
    try bytes.write(to: f.file)
    let malformed = Data("malformed".utf8)
    await f.provider.setPayload(malformed)
    let metadata = SyncableFileMetadata(relativePath: "Profiles/library_state.json", lastModified: Date().addingTimeInterval(300),
      fileSize: Int64(malformed.count), checksum: SyncChecksum.sha256Hex(malformed), fileType: .libraryState)
    await f.provider.setSnapshot(RemoteSyncSnapshot(files: [metadata]))
    await f.coordinator.syncNow()
    await f.coordinator.waitForCurrentSyncCompletion()
    XCTAssertEqual(try Data(contentsOf: f.file), bytes)
    let uploads = await f.provider.uploads()
    XCTAssertTrue(uploads.isEmpty, "Neither copy may be destroyed on an undecodable merge")
    XCTAssertTrue(f.coordinator.recentEvents.contains { $0.message.contains("merge") || $0.message.contains("Merge") })
  }

  func testMergedDocumentNotifiesOwnerEvenWhenUploadFails() async throws {
    let f = try fixture(.uploadFailure, path: "Profiles/library_state.json")
    try LibraryStateDocument(games: ["LOCAL": .init(launches: ["local": 1])]).encoded().write(to: f.file)
    let remote = try LibraryStateDocument(games: ["REMOTE": .init(launches: ["remote": 1])]).encoded()
    await f.provider.setPayload(remote)
    let metadata = SyncableFileMetadata(relativePath: "Profiles/library_state.json", lastModified: Date(),
      fileSize: Int64(remote.count), checksum: SyncChecksum.sha256Hex(remote), fileType: .libraryState)
    await f.provider.setSnapshot(RemoteSyncSnapshot(files: [metadata]))
    let notification = expectation(forNotification: CloudSyncCoordinator.documentDidChangeNotification,
      object: f.coordinator) { note in
        note.userInfo?[CloudSyncCoordinator.fileTypeKey] as? String == SyncableFileType.libraryState.rawValue
      }
    await f.coordinator.syncNow()
    await f.coordinator.waitForCurrentSyncCompletion()
    await fulfillment(of: [notification], timeout: 1)
    let saved = try LibraryStateDocument.decode(Data(contentsOf: f.file))
    XCTAssertEqual(Set(saved.games.keys), ["LOCAL", "REMOTE"])
  }

  func testPurgeableStoragePlanningRestoresMissingFileWithSurvivingIndex() async throws {
    let f = try fixture(.success)
    let metadata = f.conflict.metadata
    await f.index.record(path: metadata.relativePath, checksum: metadata.checksum, lastModified: metadata.lastModified)
    let snapshot = await f.index.snapshot()
    let purgeSafe = CloudSyncCoordinator.planningIndex(snapshot, purgeableStorage: true)
    let steps = SyncPlanner().plan(local: [], remote: RemoteSyncSnapshot(files: [metadata]), index: purgeSafe, policy: .default)
    XCTAssertEqual(steps, [.download(metadata)])
    XCTAssertEqual(CloudSyncCoordinator.planningIndex(snapshot, purgeableStorage: false), snapshot)
  }

  private let privateConfigPaths = ["Config/RetroAchievements.ini", "Config/DSUClient.ini"]

  func testPrivateConfigsNeverUploadButOrdinaryConfigsStillSync() async throws {
    for path in privateConfigPaths + ["Config/Dolphin.ini", "Config/GFX.ini"] {
      let f = try fixture(.success, path: path)
      await f.coordinator.syncNow()
      await f.coordinator.waitForCurrentSyncCompletion()
      let uploads = await f.provider.uploads()
      XCTAssertEqual(uploads.contains(path), !privateConfigPaths.contains(path), path)
    }
  }

  func testPrivateRemoteConfigsNeverDownloadButOrdinaryConfigsStillSync() async throws {
    for path in privateConfigPaths + ["Config/Dolphin.ini", "Config/GFX.ini"] {
      let f = try fixture(.success, path: path)
      try FileManager.default.removeItem(at: f.file)
      await f.provider.setSnapshot(RemoteSyncSnapshot(files: [f.conflict.metadata]))
      await f.coordinator.syncNow()
      await f.coordinator.waitForCurrentSyncCompletion()
      let downloads = await f.provider.downloadCount()
      XCTAssertEqual(downloads, privateConfigPaths.contains(path) ? 0 : 1, path)
      XCTAssertEqual(FileManager.default.fileExists(atPath: f.file.path), !privateConfigPaths.contains(path), path)
    }
  }

  func testPrivateRemoteTombstonesCannotRemoveLocalCredentials() async throws {
    for path in privateConfigPaths {
      let f = try fixture(.success, path: path)
      let metadata = f.conflict.metadata
      await f.index.record(path: path, checksum: metadata.checksum, lastModified: metadata.lastModified)
      await f.provider.setSnapshot(RemoteSyncSnapshot(tombstones: [SyncTombstone(relativePath: path,
        checksum: metadata.checksum, deletedAt: Date())]))
      await f.coordinator.syncNow()
      await f.coordinator.waitForCurrentSyncCompletion()
      XCTAssertTrue(FileManager.default.fileExists(atPath: f.file.path), path)
      XCTAssertTrue(f.coordinator.pendingConflicts.isEmpty, path)
    }
  }

  func testPrivateConfigEligibilityNormalizesCaseAndRelativeComponents() {
    for path in ["./Config/RETROACHIEVEMENTS.INI", "Config\\DSUClient.ini", "Config/Sub/../dsuclient.ini", "/Config//RetroAchievements.ini"] {
      XCTAssertFalse(CloudSyncCoordinator.isEligibleForCloudSync(relativePath: path), path)
    }
    for path in ["Config/Dolphin.ini", "Config/GFX.ini", "GameSettings/RetroAchievements.ini"] {
      XCTAssertTrue(CloudSyncCoordinator.isEligibleForCloudSync(relativePath: path), path)
    }
  }

  func testStalePrivateConfigConflictsCannotUploadOrDownload() async throws {
    for path in privateConfigPaths {
      for resolution in [ConflictResolution.useLocal, .useRemote, .keepBoth] {
        let f = try fixture(.success, path: path)
        await f.coordinator.resolve(f.conflict, as: resolution)
        let uploads = await f.provider.uploads()
        let downloads = await f.provider.downloadCount()
        XCTAssertTrue(uploads.isEmpty, path)
        XCTAssertEqual(downloads, 0, path)
        XCTAssertEqual(try Data(contentsOf: f.file), Data("original".utf8), path)
      }
    }
  }

  func testRecentlyDeletedRestoresWhileDisabledAndDurablyForgetsTombstone() async throws {
    let f = try fixture(.downloadFailure)
    let path = f.conflict.metadata.relativePath
    let entry = try await f.trash.move(fileAt: f.file, relativePath: path)
    await f.index.markDeleted(path: path)
    try await f.index.save()
    f.coordinator.isEnabled = false
    await f.coordinator.handle(.enabledChanged(false))
    await f.coordinator.restoreFromTrash(entry)
    XCTAssertTrue(FileManager.default.fileExists(atPath: f.file.path))
    let reopened = SyncIndexStore(fileURL: f.root.appendingPathComponent("index.json"))
    let remaining = await reopened.entry(for: path)
    XCTAssertNil(remaining)
  }

  func testFailedUploadsAndDownloadsRetainConflicts() async throws {
    for mode in [SafetySyncProvider.Mode.uploadFailure, .downloadFailure] {
      let f = try fixture(mode)
        let result = await f.coordinator.resolve(f.conflict, as: mode == .uploadFailure ? .useLocal : .useRemote)
      XCTAssertTrue(result.message?.contains("Expected failure") == true)
      XCTAssertEqual(f.coordinator.pendingConflicts.map(\.id), [f.conflict.id])
      XCTAssertEqual(try Data(contentsOf: f.file), Data("original".utf8))
      let snapshot = await f.index.snapshot()
      XCTAssertNil(snapshot[f.conflict.metadata.relativePath])
    }
  }

  func testResolutionDuringEmulationDoesNotDownloadOrOverwrite() async throws {
    let f = try fixture(.success)
    await f.coordinator.handle(.emulationWillStart)
    let reason = try XCTUnwrap(f.coordinator.conflictResolutionUnavailableReason)
    let result = await f.coordinator.resolve(f.conflict, as: .useRemote)
    XCTAssertEqual(result.message, reason)
    let downloads = await f.provider.downloadCount()
    XCTAssertEqual(downloads, 0)
    XCTAssertEqual(try Data(contentsOf: f.file), Data("original".utf8))
    XCTAssertEqual(f.coordinator.pendingConflicts.map(\.id), [f.conflict.id])
  }

  func testDownloadFinishingAfterEmulationStartsDoesNotOverwriteOrResolve() async throws {
    let f = try fixture(.suspended)
    let operation = Task { await f.coordinator.resolve(f.conflict, as: .useRemote) }
    await f.provider.waitUntilDownloading()
    XCTAssertTrue(f.coordinator.isResolvingConflict)
    XCTAssertNotNil(f.coordinator.conflictResolutionUnavailableReason)
    await f.coordinator.handle(.emulationWillStart)
    await f.provider.finishDownload()
    _ = await operation.value
    XCTAssertEqual(try Data(contentsOf: f.file), Data("original".utf8))
    XCTAssertEqual(f.coordinator.pendingConflicts.map(\.id), [f.conflict.id])
    let snapshot = await f.index.snapshot()
    XCTAssertNil(snapshot[f.conflict.metadata.relativePath])
  }

  func testCancelledDownloadRetainsConflictAndOriginalFile() async throws {
    let f = try fixture(.suspended)
    let operation = Task { await f.coordinator.resolve(f.conflict, as: .useRemote) }
    await f.provider.waitUntilDownloading()
    operation.cancel()
    await f.provider.finishDownload()
    _ = await operation.value
    XCTAssertEqual(try Data(contentsOf: f.file), Data("original".utf8))
    XCTAssertEqual(f.coordinator.pendingConflicts.map(\.id), [f.conflict.id])
  }

  func testDisablingSyncDuringDownloadRetainsConflictAndOriginalFile() async throws {
    let f = try fixture(.suspended)
    let operation = Task { await f.coordinator.resolve(f.conflict, as: .useRemote) }
    await f.provider.waitUntilDownloading()
    f.coordinator.isEnabled = false
    await f.provider.finishDownload()
    _ = await operation.value
    XCTAssertEqual(try Data(contentsOf: f.file), Data("original".utf8))
    XCTAssertEqual(f.coordinator.pendingConflicts.map(\.id), [f.conflict.id])
  }

  func testDisablingAndImmediatelyReenablingSyncInvalidatesOldDownload() async throws {
    let f = try fixture(.suspended)
    let operation = Task { await f.coordinator.resolve(f.conflict, as: .useRemote) }
    await f.provider.waitUntilDownloading()
    f.coordinator.isEnabled = false
    f.coordinator.isEnabled = true
    await f.provider.finishDownload()
    _ = await operation.value
    XCTAssertEqual(try Data(contentsOf: f.file), Data("original".utf8))
    XCTAssertEqual(f.coordinator.pendingConflicts.map(\.id), [f.conflict.id])
  }

  func testEarlyUIDidEndDoesNotAdmitFileWritesDuringCoreTeardown() async throws {
    let f = try fixture(.success)
    await f.coordinator.handle(.emulationWillStart)
    await f.coordinator.handle(.emulationDidEnd) // UI dismissal, core still owns its User files.
    let admitted = f.gate.beginLocalIO()
    if admitted {
      try Data("too early".utf8).write(to: f.file)
      f.gate.endLocalIO()
    }
    XCTAssertFalse(admitted)
    XCTAssertEqual(try Data(contentsOf: f.file), Data("original".utf8))
  }

  func testFastBootAndDrainInvalidatesDownloadBeforeQueuedPolicyDelivery() async throws {
    let f = try fixture(.suspended)
    let operation = Task { await f.coordinator.resolve(f.conflict, as: .useRemote) }
    await f.provider.waitUntilDownloading()
    // The synchronous gate sees a complete boot cycle before any queued MainActor event.
    f.gate.beginEmulation()
    f.gate.endEmulation()
    await f.provider.finishDownload()
    _ = await operation.value
    XCTAssertEqual(try Data(contentsOf: f.file), Data("original".utf8))
    XCTAssertEqual(f.coordinator.pendingConflicts.map(\.id), [f.conflict.id])
  }

  func testDelayedLifecycleDeliveryCannotRecloseDrainedBootOrOpenNewBoot() async throws {
    let f = try fixture(.success)
    let old = f.gate.beginEmulation()
    XCTAssertTrue(f.gate.finishCoreDrain(generation: old))
    await f.coordinator.handleEmulationWillStart(generation: old)
    XCTAssertFalse(f.coordinator.isEmulating)
    XCTAssertFalse(f.gate.isEmulating)
    let current = f.gate.beginEmulation()
    await f.coordinator.handleEmulationWillStart(generation: current)
    await f.coordinator.handleCoreDidDrain(generation: old)
    XCTAssertTrue(f.coordinator.isEmulating)
    XCTAssertFalse(f.gate.beginLocalIO())
  }

  func testExplicitRemoteChoiceUsesRemoteBytesAndVersionMetadata() async throws {
    let f = try fixture(.success)
    await f.coordinator.resolve(f.conflict, as: .useRemote)
    XCTAssertEqual(try Data(contentsOf: f.file), Data("remote".utf8))
    XCTAssertTrue(f.coordinator.pendingConflicts.isEmpty)
    let snapshot = await f.index.snapshot()
    XCTAssertEqual(snapshot[f.conflict.metadata.relativePath]?.checksum, f.conflict.remoteVersion.checksum)
    XCTAssertEqual(snapshot[f.conflict.metadata.relativePath]?.lastModified, f.conflict.remoteVersion.modifiedDate)
  }

  func testFailedTrashMoveRetainsDeleteConflict() async throws {
    let f = try fixture(.success)
    try FileManager.default.removeItem(at: f.file)
    let deletion = SyncConflict(id: f.conflict.id, kind: .deletedRemotelyChangedLocally,
      metadata: f.conflict.metadata, localVersion: f.conflict.localVersion,
      remoteVersion: f.conflict.remoteVersion)
    await f.coordinator.resolve(deletion, as: .useRemote)
    XCTAssertEqual(f.coordinator.pendingConflicts.map(\.id), [f.conflict.id])
  }

  func testSnapshotFromPreviousAccountCannotStartTransfersInNewAccount() async throws {
    let f = try fixture(.suspendedSnapshot)
    await f.coordinator.syncNow()
    await f.provider.waitUntilDownloading()
    let completion = Task { await f.coordinator.waitForCurrentSyncCompletion() }
    await f.coordinator.handleAccountChange()
    var remote = f.conflict.metadata
    remote.lastModified = remote.lastModified.addingTimeInterval(60)
    remote.checksum = SyncChecksum.sha256Hex(Data("remote".utf8))
    remote.fileSize = 6
    await f.provider.finishSnapshot(remote)
    await completion.value
    XCTAssertEqual(try Data(contentsOf: f.file), Data("original".utf8))
    let downloads = await f.provider.downloadCount()
    XCTAssertEqual(downloads, 0, "An old account's snapshot must not adopt the new transfer generation")
  }

  func testAccountChangeClearsOldAccountChoicesEvenWhileEmulating() async throws {
    let f = try fixture(.success)
    await f.coordinator.handle(.emulationWillStart)
    await f.coordinator.handleAccountChange()
    XCTAssertTrue(f.coordinator.pendingConflicts.isEmpty,
                  "The new account must never resolve the previous account's remote version")
  }

  func testRescanRefreshesRemoteVersionForAnExistingConflictPath() throws {
    let f = try fixture(.success)
    let newer = SyncConflict.FileVersion(modifiedDate: f.conflict.remoteVersion.modifiedDate.addingTimeInterval(10),
      size: 20, checksum: "newer-remote-checksum")
    let refreshed = SyncConflict(metadata: f.conflict.metadata,
      localVersion: f.conflict.localVersion, remoteVersion: newer)
    f.coordinator.recordConflict(refreshed)
    XCTAssertEqual(f.coordinator.pendingConflicts.count, 1)
    XCTAssertEqual(f.coordinator.pendingConflicts.first?.remoteVersion, newer)
  }

  func testKeepBothDoesNotResolveWhenRemoteDownloadFails() async throws {
    let f = try fixture(.downloadFailure)
    await f.coordinator.resolve(f.conflict, as: .keepBoth)
    XCTAssertEqual(try Data(contentsOf: f.file), Data("original".utf8))
    XCTAssertEqual(f.coordinator.pendingConflicts.map(\.id), [f.conflict.id])
  }
}
