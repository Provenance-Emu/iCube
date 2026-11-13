// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import EmulatorContentClient
import Foundation
import PVCloudSync
import XCTest

@testable import iCube

final class EmulationServerSaveSyncTests: XCTestCase {
  private static let card = "GC/USA/MemoryCardA.raw"
  private static let state = "StateSaves/GALE01.s01"

  private var folder: URL!
  private var server: FakeSaveServer!

  override func setUp() {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent("savesync-" + UUID().uuidString, isDirectory: true)
    server = FakeSaveServer()
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: folder)
  }

  private func device(_ name: String, gate: SyncLocalIOGate = SyncLocalIOGate()) -> Device {
    Device(home: folder.appendingPathComponent(name, isDirectory: true), server: server, gate: gate)
  }

  // MARK: - Planner

  func testPlannerNeedsNoClockAndNeverGuessesBetweenTwoChanges() {
    func step(_ local: String?, _ remote: String?, _ base: String?) -> SaveSyncStep? {
      SaveSyncPlanner.step(for: SaveSyncState(local: local, remote: remote, base: base))
    }
    XCTAssertNil(step(nil, nil, nil))
    XCTAssertNil(step("a", "a", "a"), "In step")
    XCTAssertEqual(step("a", "a", nil), .settle, "Same bytes on both sides, met for the first time")
    XCTAssertEqual(step("a", nil, nil), .upload, "New here")
    XCTAssertEqual(step("a", nil, "a"), .upload, "Gone from the server: send it again, never delete it here")
    XCTAssertEqual(step(nil, "a", nil), .download, "New there")
    XCTAssertNil(step(nil, "a", "a"), "Deleted here: stays deleted here and stays on the server")
    XCTAssertEqual(step(nil, "b", "a"), .download, "Deleted here, then changed there")
    XCTAssertEqual(step("b", "a", "a"), .upload, "Changed here only")
    XCTAssertEqual(step("a", "b", "a"), .download, "Changed there only")
    XCTAssertEqual(step("b", "c", "a"), .conflict, "Changed on both")
    XCTAssertEqual(step("a", "b", nil), .conflict, "Never synced and different")

    let plan = SaveSyncPlanner.plan(local: ["same": "a", "mine": "b"], remote: ["same": "a", "theirs": "c"], base: ["same": "a"])
    XCTAssertEqual(plan, ["mine": .upload, "theirs": .download])
  }

  func testOnlyLiveSharedSavesMapToLocalPaths() {
    XCTAssertEqual(SaveSyncPaths.remotePath(for: Self.card), "iCube/shared/GC/USA/MemoryCardA.raw")
    XCTAssertEqual(SaveSyncPaths.relativePath(fromRemote: "iCube/shared/GC/USA/MemoryCardA.raw"), Self.card)
    XCTAssertNil(SaveSyncPaths.relativePath(fromRemote: "iCube/shared/GC/USA/MemoryCardA.raw.conflict-0a1b2c3d"), "A copy the server kept")
    XCTAssertNil(SaveSyncPaths.relativePath(fromRemote: "iCube/5E0C7A1B-device/GC/USA/MemoryCardA.raw"), "A per-device backup")
    XCTAssertNil(SaveSyncPaths.relativePath(fromRemote: "iCube/shared/"))
    XCTAssertEqual(SaveSyncPaths.relativePath(fromRemote: "iCube/shared/StateSaves/a.conflict-notahex1"), "StateSaves/a.conflict-notahex1")
  }

  // MARK: - Two devices

  func testSavesTravelBothWaysAndAReplacedSaveIsKept() async throws {
    let phone = device("phone"), tv = device("tv")
    try phone.write("card v1", to: Self.card)
    try phone.write("state v1", to: Self.state)

    var outcome = try await phone.sync()
    XCTAssertEqual(outcome, .init(uploaded: 2, downloaded: 0, conflicts: []))
    outcome = try await tv.sync()
    XCTAssertEqual(outcome, .init(uploaded: 0, downloaded: 2, conflicts: []))
    XCTAssertEqual(tv.read(Self.card), "card v1")
    XCTAssertEqual(tv.read(Self.state), "state v1")

    let quiet = await server.uploadCount
    outcome = try await phone.sync()
    XCTAssertEqual(outcome, .init())
    outcome = try await tv.sync()
    XCTAssertEqual(outcome, .init())
    let stillQuiet = await server.uploadCount
    XCTAssertEqual(stillQuiet, quiet, "In step means nothing is sent again")

    try tv.write("card v2 from the tv", to: Self.card)
    outcome = try await tv.sync()
    XCTAssertEqual(outcome, .init(uploaded: 1, downloaded: 0, conflicts: []))
    outcome = try await phone.sync()
    XCTAssertEqual(outcome, .init(uploaded: 0, downloaded: 1, conflicts: []))
    XCTAssertEqual(phone.read(Self.card), "card v2 from the tv")
    let trashed = await phone.trashedContents()
    XCTAssertEqual(trashed, ["card v1"], "The save it replaced is in Recently Deleted")
    let kept = await server.contents(at: "iCube/shared/" + Self.card)
    XCTAssertEqual(kept.live, "card v2 from the tv")
    XCTAssertEqual(kept.copies, ["card v1"], "The server kept the save it replaced as well")
  }

  func testASaveChangedOnBothWaitsForTheUserAndEitherChoiceKeepsBoth() async throws {
    let phone = device("phone"), tv = device("tv")
    try phone.write("v1", to: Self.card)
    _ = try await phone.sync()
    _ = try await tv.sync()

    try phone.write("phone progress", to: Self.card)
    try tv.write("tv progress", to: Self.card)
    _ = try await phone.sync()
    var outcome = try await tv.sync()
    XCTAssertEqual(outcome.conflicts.map(\.path), [Self.card])
    XCTAssertEqual([outcome.uploaded, outcome.downloaded], [0, 0])
    XCTAssertEqual(tv.read(Self.card), "tv progress", "Nothing is replaced until the user chooses")
    let untouched = await server.contents(at: "iCube/shared/" + Self.card)
    XCTAssertEqual(untouched.live, "phone progress")
    outcome = try await tv.sync()
    XCTAssertEqual(outcome.conflicts.map(\.path), [Self.card], "It stays a conflict on every pass")

    outcome = try await tv.sync(resolving: Device.answer(outcome.conflicts, .keepLocal))
    XCTAssertEqual(outcome, .init(uploaded: 1, downloaded: 0, conflicts: []))
    let chosen = await server.contents(at: "iCube/shared/" + Self.card)
    XCTAssertEqual(chosen.live, "tv progress")
    XCTAssertEqual(Set(chosen.copies), ["v1", "phone progress"], "The save that was not kept is still on the server")
    outcome = try await phone.sync()
    XCTAssertEqual(outcome, .init(uploaded: 0, downloaded: 1, conflicts: []))
    XCTAssertEqual(phone.read(Self.card), "tv progress")

    // The other choice: take the server's, and this device's goes to Recently Deleted.
    try phone.write("phone again", to: Self.card)
    try tv.write("tv again", to: Self.card)
    _ = try await phone.sync()
    outcome = try await tv.sync()
    outcome = try await tv.sync(resolving: Device.answer(outcome.conflicts, .useServer))
    XCTAssertEqual(outcome, .init(uploaded: 0, downloaded: 1, conflicts: []))
    XCTAssertEqual(tv.read(Self.card), "phone again")
    let trashed = await tv.trashedContents()
    XCTAssertTrue(trashed.contains("tv again"))
  }

  func testTwoDevicesThatNeverSyncedAndDifferAreAConflictNotAGuess() async throws {
    let phone = device("phone"), tv = device("tv")
    try phone.write("phone card", to: Self.card)
    try tv.write("tv card", to: Self.card)
    try tv.write("same state", to: Self.state)
    try phone.write("same state", to: Self.state)
    _ = try await phone.sync()
    let outcome = try await tv.sync()
    XCTAssertEqual(outcome.conflicts.map(\.path), [Self.card])
    XCTAssertEqual([outcome.uploaded, outcome.downloaded], [0, 0])
    XCTAssertEqual(tv.read(Self.card), "tv card")
    let after = try await tv.sync()
    XCTAssertEqual(after.conflicts, outcome.conflicts)
  }

  func testNothingIsEverDeletedOnEitherSide() async throws {
    let phone = device("phone"), tv = device("tv")
    try phone.write("v1", to: Self.state)
    _ = try await phone.sync()
    _ = try await tv.sync()

    try tv.delete(Self.state)
    var outcome = try await tv.sync()
    XCTAssertEqual(outcome, .init(), "A save deleted here is not fetched back")
    XCTAssertNil(tv.read(Self.state))
    let stillThere = await server.contents(at: "iCube/shared/" + Self.state)
    XCTAssertEqual(stillThere.live, "v1", "and is not removed from the server")
    outcome = try await phone.sync()
    XCTAssertEqual(phone.read(Self.state), "v1", "nor from the other device")

    try phone.write("v2", to: Self.state)
    _ = try await phone.sync()
    outcome = try await tv.sync()
    XCTAssertEqual(outcome.downloaded, 1, "A newer save does come back")
    XCTAssertEqual(tv.read(Self.state), "v2")

    // The server lost the file: this device sends it again and keeps its own.
    await server.removeEverything()
    outcome = try await phone.sync()
    XCTAssertEqual(outcome, .init(uploaded: 1, downloaded: 0, conflicts: []))
    XCTAssertEqual(phone.read(Self.state), "v2")
  }

  func testAServerCannotPlaceFilesOutsideTheSaves() async throws {
    let tv = device("tv")
    await server.plant("hostile settings", at: "iCube/shared/Config/Dolphin.ini", kind: "battery_save")
    await server.plant("hostile escape", at: "iCube/shared/../../Documents/escape.raw", kind: "battery_save")
    await server.plant("console settings", at: "iCube/shared/Wii/shared2/sys/SYSCONF", kind: "battery_save")
    await server.plant("a rom", at: "iCube/shared/GC/USA/MemoryCardB.raw", kind: "rom")
    await server.plant("someone's backup", at: "iCube/other-device/GC/USA/MemoryCardA.raw", kind: "battery_save")
    await server.plant("a real save", at: "iCube/shared/" + Self.card, kind: "battery_save")
    let outcome = try await tv.sync()
    XCTAssertEqual(outcome, .init(uploaded: 0, downloaded: 1, conflicts: []))
    XCTAssertEqual(tv.read(Self.card), "a real save")
    XCTAssertEqual(tv.allFiles(), [Self.card])
  }

  func testAWriteFromAnotherDeviceMidPassIsNotCountedAsSynced() async throws {
    let phone = device("phone"), tv = device("tv")
    try phone.write("v1", to: Self.card)
    _ = try await phone.sync()
    _ = try await tv.sync()
    try phone.write("phone progress", to: Self.card)
    try tv.write("tv progress", to: Self.card)

    // The TV's save lands after the phone read the server but before the phone finished sending.
    let saves: FakeSaveServer = server
    await server.onNextUpload { await saves.replaceLive("tv progress", at: "iCube/shared/" + Self.card) }
    var outcome = try await phone.sync()
    XCTAssertEqual(outcome.conflicts.map(\.path), [Self.card])
    XCTAssertEqual([outcome.uploaded, outcome.downloaded], [0, 0])
    XCTAssertEqual(phone.read(Self.card), "phone progress")
    let raced = await server.contents(at: "iCube/shared/" + Self.card)
    XCTAssertEqual(raced.live, "tv progress", "The server parked the late copy instead of replacing the other device's save")
    outcome = try await phone.sync()
    XCTAssertEqual(outcome.conflicts.map(\.path), [Self.card], "and it is still a conflict afterwards")
  }

  func testAnUnrelatedUploadInBetweenIsNotAConflict() async throws {
    let phone = device("phone")
    try phone.write("v1", to: Self.card)
    _ = try await phone.sync()
    try phone.write("v2", to: Self.card)

    // Another device backs up a different file while the phone is sending: the destination's revision moves,
    // but the phone's save did not change on the server.
    let saves: FakeSaveServer = server
    await server.onNextUpload { await saves.replaceLive("someone else", at: "iCube/other-device/" + Self.state) }
    let outcome = try await phone.sync()
    XCTAssertEqual(outcome, .init(uploaded: 1, downloaded: 0, conflicts: []))
    let kept = await server.contents(at: "iCube/shared/" + Self.card)
    XCTAssertEqual(kept.live, "v2")
    let again = try await phone.sync()
    XCTAssertEqual(again, .init())
  }

  func testAnAnswerAppliesOnlyToTheFilesTheUserWasShown() async throws {
    let phone = device("phone"), tv = device("tv")
    try phone.write("v1", to: Self.card)
    _ = try await phone.sync()
    _ = try await tv.sync()
    try phone.write("phone progress", to: Self.card)
    try tv.write("tv progress", to: Self.card)
    _ = try await phone.sync()
    let shown = try await tv.sync().conflicts
    XCTAssertEqual(shown.map(\.path), [Self.card])

    // The game saves again on the TV before the answer is carried out: "use the server's" was not about this file.
    try tv.write("tv progress, later", to: Self.card)
    var outcome = try await tv.sync(resolving: Device.answer(shown, .useServer))
    XCTAssertEqual(tv.read(Self.card), "tv progress, later")
    XCTAssertEqual(outcome.downloaded, 0)
    XCTAssertEqual(outcome.conflicts.map(\.path), [Self.card], "It is asked again, about the files as they are now")
    XCTAssertNotEqual(outcome.conflicts, shown)

    // The same for the other side: the phone saves again before "keep this device's" is carried out.
    let asked = outcome.conflicts
    try phone.write("phone progress, later", to: Self.card)
    _ = try await phone.sync()
    outcome = try await tv.sync(resolving: Device.answer(asked, .keepLocal))
    XCTAssertEqual(outcome.uploaded, 0)
    let live = await server.contents(at: "iCube/shared/" + Self.card).live
    XCTAssertEqual(live, "phone progress, later")

    outcome = try await tv.sync(resolving: Device.answer(outcome.conflicts, .keepLocal))
    XCTAssertEqual(outcome, .init(uploaded: 1, downloaded: 0, conflicts: []))
  }

  func testUnrelatedUploadsThatKeepGettingInFirstAreNotAConflict() async throws {
    let phone = device("phone")
    try phone.write("v1", to: Self.card)
    _ = try await phone.sync()
    try phone.write("v2", to: Self.card)
    let saves: FakeSaveServer = server
    await server.onEveryUpload { await saves.replaceLive(UUID().uuidString, at: "iCube/other-device/" + Self.state) }
    var outcome = try await phone.sync()
    XCTAssertEqual(outcome, .init(), "Not sent yet, and not something to ask the user about")
    await server.onEveryUpload(nil)
    outcome = try await phone.sync()
    XCTAssertEqual(outcome, .init(uploaded: 1, downloaded: 0, conflicts: []))
  }

  func testWiiSavesAreNotSyncedFileByFile() async throws {
    let wii = "Wii/title/00010000/52535045/data/save.bin"
    XCTAssertFalse(EmulationServerSaveSyncWorker.isSave(wii))
    XCTAssertTrue(EmulationServerSaveSyncWorker.isSave(Self.card))
    XCTAssertTrue(EmulationServerSaveSyncWorker.isSave(Self.state))
    let phone = device("phone"), tv = device("tv")
    try phone.write("wii save", to: wii)
    try phone.write("card", to: Self.card)
    var outcome = try await phone.sync()
    XCTAssertEqual(outcome, .init(uploaded: 1, downloaded: 0, conflicts: []))
    await server.plant("someone's wii save", at: "iCube/shared/" + wii, kind: "battery_save")
    outcome = try await tv.sync()
    XCTAssertEqual(tv.allFiles(), [Self.card])
  }

  func testADamagedDownloadChangesNothing() async throws {
    let phone = device("phone"), tv = device("tv")
    try phone.write("v1", to: Self.card)
    _ = try await phone.sync()
    _ = try await tv.sync()
    try phone.write("v2", to: Self.card)
    _ = try await phone.sync()
    await server.corruptDownloads()
    do {
      _ = try await tv.sync()
      XCTFail("A download that does not match its checksum must fail")
    } catch {
      XCTAssertEqual(tv.read(Self.card), "v1")
      let trashed = await tv.trashedContents()
      XCTAssertTrue(trashed.isEmpty)
    }
  }

  func testNothingIsReadOrWrittenWhileAGameRuns() async throws {
    let gate = SyncLocalIOGate()
    let tv = device("tv", gate: gate)
    try tv.write("v1", to: Self.card)
    _ = gate.beginEmulation()
    defer { gate.endEmulation() }
    do {
      _ = try await tv.sync()
      XCTFail("Sync must wait for the game to stop")
    } catch EmulationServerSaveSyncWorker.Failure.coreBusy {
      let requests = await server.requestCount
      XCTAssertEqual(requests, 0)
    }
  }

  func testOlderDestinationsDecodeWithSyncOffAndStatusSaysWhatHappened() throws {
    let saved = #"{"server":{"origin":"https://saves.example"},"itemID":"item1","allowsHTTP":false}"#
    let target = try JSONDecoder().decode(EmulationServerBackupTarget.self, from: Data(saved.utf8))
    XCTAssertFalse(target.syncsSaves)
    var on = target
    on.syncsSaves = true
    let again = try JSONDecoder().decode(EmulationServerBackupTarget.self, from: JSONEncoder().encode(on))
    XCTAssertTrue(again.syncsSaves)
  }
}

// MARK: - Fixtures

/// One device: its own user folder, its own record of what it last synced, its own Recently Deleted.
private struct Device {
  let root: URL
  let trash: SyncTrash
  let worker: EmulationServerSaveSyncWorker
  let server: FakeSaveServer

  init(home: URL, server: FakeSaveServer, gate: SyncLocalIOGate) {
    root = home.appendingPathComponent("User", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    trash = SyncTrash(rootURL: home.appendingPathComponent("Trash", isDirectory: true))
    worker = EmulationServerSaveSyncWorker(indexDirectory: home.appendingPathComponent("Index", isDirectory: true),
                                           trash: trash, gate: gate)
    self.server = server
  }

  static func answer(_ conflicts: [EmulationServerSaveSyncWorker.Conflict],
                     _ resolution: EmulationServerSaveSyncWorker.Resolution) -> [String: EmulationServerSaveSyncWorker.Choice] {
    Dictionary(conflicts.map { ($0.path, .init(conflict: $0, resolution: resolution)) }, uniquingKeysWith: { first, _ in first })
  }

  func sync(resolving: [String: EmulationServerSaveSyncWorker.Choice] = [:]) async throws -> EmulationServerSaveSyncWorker.Outcome {
    let target = EmulationServerBackupTarget(server: try EmulationServer(address: "https://saves.example"),
                                             itemID: FakeSaveServer.itemID, allowsHTTP: false, syncsSaves: true)
    return try await worker.sync(root: root, target: target, token: "writer", transport: server, resolving: resolving)
  }

  func write(_ text: String, to path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
  }

  func read(_ path: String) -> String? {
    (try? Data(contentsOf: root.appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
  }

  func delete(_ path: String) throws {
    try FileManager.default.removeItem(at: root.appendingPathComponent(path))
  }

  func allFiles() -> [String] {
    let prefix = root.resolvingSymlinksInPath().path + "/"
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?
      .compactMap { $0 as? URL }
      .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } ?? []
    return files.map { String($0.resolvingSymlinksInPath().path.dropFirst(prefix.count)) }.sorted()
  }

  func trashedContents() async -> [String] {
    await trash.entries().compactMap { try? Data(contentsOf: $0.url) }.map { String(decoding: $0, as: UTF8.self) }.sorted()
  }
}

/// The server's save rules, as its code has them: one revision per destination, bumped by every completed
/// upload; an upload at the current revision becomes live and the file it replaces is kept as a copy; an
/// upload at a stale revision is parked as a copy when a live file exists; nothing is ever removed.
private actor FakeSaveServer: ContentTransport {
  static let itemID = "item1"

  private struct Stored {
    let id: String
    var path: String
    let kind: String
    let bytes: Data
    var conflictOf: String?
  }

  private var revision = 0
  private var files: [Stored] = []
  private var uploads: [String: Data] = [:]
  private var interleave: (@Sendable () async -> Void)?
  private var interleaveAlways: (@Sendable () async -> Void)?
  private var corrupt = false
  private(set) var uploadCount = 0
  private(set) var requestCount = 0

  func onNextUpload(_ work: @escaping @Sendable () async -> Void) { interleave = work }
  func onEveryUpload(_ work: (@Sendable () async -> Void)?) { interleaveAlways = work }
  func corruptDownloads() { corrupt = true }
  func removeEverything() { files.removeAll() }

  func plant(_ text: String, at path: String, kind: String) {
    files.append(Stored(id: Self.newID(), path: path, kind: kind, bytes: Data(text.utf8), conflictOf: nil))
    revision += 1
  }

  /// Another device completing an upload at the current revision.
  func replaceLive(_ text: String, at path: String) {
    place(Data(text.utf8), at: path, kind: "battery_save", baseRevision: revision)
  }

  func contents(at path: String) -> (live: String?, copies: [String]) {
    let text = { (file: Stored) in String(decoding: file.bytes, as: UTF8.self) }
    return (files.first { $0.path == path }.map(text),
            files.filter { $0.path.hasPrefix(path + ".conflict-") }.map(text))
  }

  private static func newID() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
  }

  @discardableResult
  private func place(_ bytes: Data, at path: String, kind: String, baseRevision: Int) -> Stored {
    let id = Self.newID()
    let current = baseRevision == revision
    revision += 1
    var stored = Stored(id: id, path: path, kind: kind, bytes: bytes, conflictOf: nil)
    if let live = files.firstIndex(where: { $0.path == path }) {
      if current {
        files[live].conflictOf = id
        files[live].path = path + ".conflict-" + files[live].id.prefix(8)
      } else {
        stored.conflictOf = files[live].id
        stored.path = path + ".conflict-" + id.prefix(8)
      }
    }
    files.append(stored)
    return stored
  }

  private func asset(_ file: Stored) -> [String: Any] {
    ["id": file.id, "itemId": Self.itemID, "kind": file.kind, "displayName": (file.path as NSString).lastPathComponent,
     "relativePath": file.path, "sha256": SHA256.hash(data: file.bytes).map { String(format: "%02x", $0) }.joined(),
     "size": file.bytes.count, "md5": NSNull(), "crc": NSNull(), "shareable": true, "revision": 1,
     "createdAt": "2026-11-12T00:00:00Z", "updatedAt": "2026-11-12T00:00:00Z", "conflictOf": file.conflictOf ?? NSNull(),
     "required": false, "contentPath": "/api/v1/files/\(file.id)/content"]
  }

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requestCount += 1
    guard let url = request.url, request.value(forHTTPHeaderField: "Authorization") == "Bearer writer" else {
      throw URLError(.userAuthenticationRequired)
    }
    let parts = url.path.split(separator: "/").map(String.init)
    let method = request.httpMethod ?? "GET"
    func answer(_ status: Int, _ body: Any) throws -> (Data, HTTPURLResponse) {
      let data: Data
      if let raw = body as? Data {
        data = raw
      } else {
        data = try JSONSerialization.data(withJSONObject: body)
      }
      guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else {
        throw URLError(.badServerResponse)
      }
      return (data, response)
    }
    switch (method, parts.dropFirst(2).first, parts.count) {
    case ("GET", "items", 4):
      return try answer(200, ["id": Self.itemID, "libraryId": "lib1"])
    case ("GET", "items", 5):
      let listed = files.sorted { $0.path < $1.path }.map(asset)
      return try answer(200, ["version": 1, "itemId": Self.itemID, "revision": revision, "files": listed])
    case ("POST", "uploads", 3):
      let id = Self.newID()
      uploads[id] = Data()
      if let work = interleave {
        interleave = nil
        await work()
      }
      await interleaveAlways?()
      return try answer(201, ["id": id, "received": 0, "state": "open"])
    case ("PUT", "uploads", 5):
      uploads[parts[3], default: Data()].append(request.httpBody ?? Data())
      return try answer(200, ["id": parts[3], "received": uploads[parts[3]]?.count ?? 0, "state": "open"])
    case ("POST", "uploads", 5):
      guard let body = request.httpBody, let draft = try JSONSerialization.jsonObject(with: body) as? [String: Any],
            let path = draft["relativePath"] as? String, let kind = draft["kind"] as? String,
            let base = draft["baseRevision"] as? Int, let bytes = uploads.removeValue(forKey: parts[3]) else {
        return try answer(400, ["title": "Invalid body"])
      }
      uploadCount += 1
      return try answer(201, asset(place(bytes, at: path, kind: kind, baseRevision: base)))
    case ("GET", "files", 5):
      guard let file = files.first(where: { $0.id == parts[3] }) else { return try answer(404, ["title": "Not found"]) }
      return try answer(200, corrupt ? Data(file.bytes.reversed()) : file.bytes)
    default:
      return try answer(404, ["title": "Not found"])
    }
  }
}
