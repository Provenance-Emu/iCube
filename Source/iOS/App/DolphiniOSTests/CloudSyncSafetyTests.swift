// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVCloudSync
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
  private var uploadedPaths: [String] = []
  private var remoteSnapshot = RemoteSyncSnapshot()
  private var snapshotWaiter: CheckedContinuation<RemoteSyncSnapshot, Never>?
  private var didSuspendSnapshot = false
  init(_ mode: Mode) { self.mode = mode }
  func unavailableReason() async -> SyncUnavailableReason? { nil }
  func initialize() async throws {}
  func accountIdentity() async -> String? { "safety-account" }
  func upload(metadata: SyncableFileMetadata, data: Data) async throws {
    uploadedPaths.append(metadata.relativePath)
    if mode == .uploadFailure { throw SyncProviderError.uploadFailed("Expected failure") }
  }
  func download(metadata: SyncableFileMetadata) async throws -> Data {
    downloads += 1
    if mode == .downloadFailure { throw SyncProviderError.downloadFailed("Expected failure") }
    downloading = true
    startWaiter?.resume()
    startWaiter = nil
    if mode == .suspended { return await withCheckedContinuation { payloadWaiter = $0 } }
    return Data("remote".utf8)
  }
  func waitUntilDownloading() async {
    if downloading { return }
    await withCheckedContinuation { startWaiter = $0 }
  }
  func finishDownload() { payloadWaiter?.resume(returning: Data("remote".utf8)); payloadWaiter = nil }
  func downloadCount() -> Int { downloads }
  func uploads() -> [String] { uploadedPaths }
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
