// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVCloudSync
import PVSyncRules
import XCTest
@testable import iCube

/// Serves a remote snapshot; the first fetch can be held until the test releases it.
private actor PushTestProvider: SyncProvider {
  nonisolated let providerName = "Push Test"
  nonisolated let kind: SyncProviderKind = .iCloud
  private let holdFirstFetch: Bool
  private var remote = RemoteSyncSnapshot()
  private var payloads: [String: Data] = [:]
  private var fetches = 0
  private var heldFetch: CheckedContinuation<RemoteSyncSnapshot, Never>?
  private var fetchWaiter: CheckedContinuation<Void, Never>?
  private(set) var downloads = 0

  init(holdFirstFetch: Bool = false) { self.holdFirstFetch = holdFirstFetch }

  func serve(_ snapshot: RemoteSyncSnapshot, payloads: [String: Data]) {
    remote = snapshot
    self.payloads.merge(payloads) { $1 }
  }

  func waitUntilFetchIsHeld() async {
    if heldFetch != nil { return }
    await withCheckedContinuation { fetchWaiter = $0 }
  }

  func releaseHeldFetch(with snapshot: RemoteSyncSnapshot) {
    heldFetch?.resume(returning: snapshot)
    heldFetch = nil
  }

  func unavailableReason() async -> SyncUnavailableReason? { nil }
  func initialize() async throws {}
  func accountIdentity() async -> String? { "push-test-account" }
  func upload(metadata: SyncableFileMetadata, data: Data) async throws {}
  func download(metadata: SyncableFileMetadata) async throws -> Data {
    downloads += 1
    return payloads[metadata.relativePath] ?? Data()
  }
  func fetchRemoteSnapshot() async throws -> RemoteSyncSnapshot {
    fetches += 1
    if holdFirstFetch && fetches == 1 {
      return await withCheckedContinuation { continuation in
        heldFetch = continuation
        fetchWaiter?.resume()
        fetchWaiter = nil
      }
    }
    return remote
  }
  func writeTombstone(_ tombstone: SyncTombstone) async throws {}
  func purgeExpiredTombstones(olderThan cutoff: Date) async throws {}
  func purgeAllData() async throws {}
}

/// `CloudSyncCoordinator.syncForRemoteChange()` against a fake provider: what a push
/// run actually applies, when it returns, and that a running game is never written to.
@MainActor
final class CloudSyncPushCoordinatorTests: XCTestCase {
  private struct Fixture {
    let root: URL
    let provider: PushTestProvider
    let gate: SyncLocalIOGate
    let coordinator: CloudSyncCoordinator
  }

  private func fixture(holdFirstFetch: Bool = false) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSyncPush-\(UUID())")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Config"), withIntermediateDirectories: true)
    let provider = PushTestProvider(holdFirstFetch: holdFirstFetch)
    let gate = SyncLocalIOGate()
    let coordinator = CloudSyncCoordinator(network: StaticNetworkState.unconstrained, enabled: true,
      scanner: UserDataScanner(rootDirectory: root), provider: provider,
      index: SyncIndexStore(fileURL: root.appendingPathComponent("index.json")),
      trash: SyncTrash(rootURL: root.appendingPathComponent("Trash")), localIOGate: gate)
    let enabledKey = "icube.cloudSync.enabled"
    let savedEnabled = UserDefaults.standard.object(forKey: enabledKey)
    addTeardownBlock {
      await coordinator.handle(.enabledChanged(false))
      if let savedEnabled { UserDefaults.standard.set(savedEnabled, forKey: enabledKey) }
      else { UserDefaults.standard.removeObject(forKey: enabledKey) }
      try? FileManager.default.removeItem(at: root)
    }
    return Fixture(root: root, provider: provider, gate: gate, coordinator: coordinator)
  }

  private func remoteFile(_ path: String, _ bytes: Data) -> SyncableFileMetadata {
    SyncableFileMetadata(relativePath: path, lastModified: Date(timeIntervalSince1970: 1_700_000_000),
      fileSize: Int64(bytes.count), checksum: SyncChecksum.sha256Hex(bytes), fileType: .config)
  }

  private func contents(_ f: Fixture, _ path: String) -> Data? {
    try? Data(contentsOf: f.root.appendingPathComponent(path))
  }

  func testPushRunDownloadsAndCountsTheAppliedFile() async throws {
    let f = try fixture()
    let bytes = Data("[Core]\nCPUThread = True\n".utf8)
    await f.provider.serve(RemoteSyncSnapshot(files: [remoteFile("Config/Dolphin.ini", bytes)]),
                           payloads: ["Config/Dolphin.ini": bytes])
    let before = f.coordinator.remoteChangeCounters

    await f.coordinator.syncForRemoteChange()

    XCTAssertFalse(f.coordinator.isSyncing, "Returns only once the run is over")
    XCTAssertEqual(contents(f, "Config/Dolphin.ini"), bytes)
    XCTAssertEqual(f.coordinator.remoteChangeCounters.appliedFromRemote, before.appliedFromRemote + 1)
    XCTAssertEqual(CloudSyncPushResult.resolve(before: before, after: f.coordinator.remoteChangeCounters,
                                               finished: true, unavailable: f.coordinator.unavailableReason != nil),
                   .newData)
  }

  func testQuietPushRunIsNoData() async throws {
    let f = try fixture()
    let before = f.coordinator.remoteChangeCounters
    await f.coordinator.syncForRemoteChange()
    XCTAssertEqual(CloudSyncPushResult.resolve(before: before, after: f.coordinator.remoteChangeCounters,
                                               finished: true, unavailable: f.coordinator.unavailableReason != nil),
                   .noData)
  }

  func testPushDuringARunWaitsForTheFollowUpRun() async throws {
    let f = try fixture(holdFirstFetch: true)
    let first = Data("first".utf8)
    let second = Data("second".utf8)
    let firstFile = remoteFile("Config/GFX.ini", first)
    let secondFile = remoteFile("Config/Dolphin.ini", second)
    // The held (first) fetch sees only the first file; any later fetch sees both.
    await f.provider.serve(RemoteSyncSnapshot(files: [firstFile, secondFile]),
                           payloads: ["Config/GFX.ini": first, "Config/Dolphin.ini": second])

    await f.coordinator.syncNow()
    await f.provider.waitUntilFetchIsHeld()
    let push = Task { await f.coordinator.syncForRemoteChange() }
    // The push has handed its trigger to the policy once its event is logged.
    while !f.coordinator.recentEvents.contains(where: { $0.message.hasPrefix("iCloud reported a change") }) {
      await Task.yield()
    }
    await f.provider.releaseHeldFetch(with: RemoteSyncSnapshot(files: [firstFile]))
    await push.value

    XCTAssertFalse(f.coordinator.isSyncing)
    XCTAssertEqual(contents(f, "Config/GFX.ini"), first)
    XCTAssertEqual(contents(f, "Config/Dolphin.ini"), second, "The follow-up run finished before the push returned")
    XCTAssertEqual(f.coordinator.remoteChangeCounters.appliedFromRemote, 2)
  }

  func testPushDuringAGameWritesNothingUntilTheCoreDrains() async throws {
    let f = try fixture()
    let bytes = Data("remote".utf8)
    await f.provider.serve(RemoteSyncSnapshot(files: [remoteFile("Config/Dolphin.ini", bytes)]),
                           payloads: ["Config/Dolphin.ini": bytes])
    let generation = f.gate.beginEmulation()
    await f.coordinator.handleEmulationWillStart(generation: generation)
    XCTAssertTrue(f.coordinator.pushState.isEmulating)

    await f.coordinator.syncForRemoteChange()

    XCTAssertNil(contents(f, "Config/Dolphin.ini"))
    let downloadsDuringGame = await f.provider.downloads
    XCTAssertEqual(downloadsDuringGame, 0)
    XCTAssertEqual(f.coordinator.remoteChangeCounters, CloudSyncRemoteChangeCounters())

    XCTAssertTrue(f.gate.finishCoreDrain(generation: generation))
    await f.coordinator.handleCoreDidDrain(generation: generation)
    await f.coordinator.waitForCurrentSyncCompletion()

    XCTAssertEqual(contents(f, "Config/Dolphin.ini"), bytes, "The deferred trigger runs after the drain")
    XCTAssertEqual(f.coordinator.remoteChangeCounters.appliedFromRemote, 1)
  }
}
