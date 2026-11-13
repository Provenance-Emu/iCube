// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import EmulatorContentClient
import Foundation
import PVCloudSync
import PVSyncRules

/// Keeps this device's saves and save states in step with the other devices that use the same Emulation
/// Server destination. `SaveSyncPlanner` decides each file; this applies the decisions.
///
/// What it never does: remove a file on either side, replace a file that changed on both sides without being
/// told which to keep, or touch a file while a game is running. A file it replaces here goes to Recently
/// Deleted first, and the server keeps its own copy of every file a newer one replaces.
actor EmulationServerSaveSyncWorker {
  enum Resolution: Sendable {
    case keepLocal, useServer
  }

  struct Outcome: Equatable, Sendable {
    var uploaded = 0
    var downloaded = 0
    /// Saves that differ on both sides and wait for the user, by path relative to the user folder.
    var conflicts: [String] = []
  }

  enum Failure: Error { case coreBusy, invalidTarget, damagedDownload }

  /// What this device and one destination last agreed on, by path.
  private struct Index: Codable {
    var version = 1
    var checksums: [String: String] = [:]
  }

  private struct Destination: Decodable {
    let id: String
    let libraryId: String
  }

  private static let chunkSize = 512 * 1024
  /// How often one save is sent again when unrelated uploads keep getting in first.
  private static let uploadAttempts = 3

  private let indexDirectory: URL
  private let trash: SyncTrash
  private let gate: SyncLocalIOGate
  private var scanners: [URL: UserDataScanner] = [:]

  init(indexDirectory: URL, trash: SyncTrash, gate: SyncLocalIOGate = .shared) {
    self.indexDirectory = indexDirectory
    self.trash = trash
    self.gate = gate
  }

  /// One pass over every save. `resolving` carries the user's choice for files that were in conflict.
  func sync(root: URL, target: EmulationServerBackupTarget, token: String, transport: any ContentTransport,
            resolving: [String: Resolution] = [:]) async throws -> Outcome {
    guard target.server.origin.scheme == "https" || target.allowsHTTP,
          EmulationServerBackupTarget.isValidItemID(target.itemID) else { throw Failure.invalidTarget }
    let scanner = scanners[root] ?? UserDataScanner(rootDirectory: root)
    scanners[root] = scanner
    let files = try await scan(scanner)
    try Task.checkCancellation()

    let origin = target.server.origin
    let client = ContentSync(baseURL: origin, token: token, transport: transport)
    var request = URLRequest(url: origin.appendingPathComponent("api/v1/items").appendingPathComponent(target.itemID))
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    let (data, response) = try await transport.data(for: request)
    guard response.statusCode == 200 else { throw SyncFailure(status: response.statusCode, message: "Save destination unavailable") }
    let destination = try JSONDecoder().decode(Destination.self, from: data)
    guard destination.id == target.itemID else { throw Failure.invalidTarget }
    var manifest = try await client.manifest(itemId: destination.id)

    let local = Dictionary(files.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
    let indexURL = self.indexURL(for: target)
    var index = loadIndex(at: indexURL)
    defer { saveIndex(index, at: indexURL) }

    // What the server held when the plan was made. Another device may write while this pass runs, so each
    // step first checks that the server's file is still the one it was planned against.
    var live = Self.liveSaves(in: manifest)
    let planned = live.mapValues(\.sha256)
    let steps = SaveSyncPlanner.plan(local: local.mapValues(\.checksum), remote: planned, base: index.checksums)
    var outcome = Outcome()
    for path in steps.keys.sorted() {
      try Task.checkCancellation()
      var step = steps[path]
      if step == .conflict {
        switch resolving[path] {
        case .keepLocal: step = .upload
        case .useServer: step = .download
        case nil: break
        }
      }
      let remote = live[path]
      // Changed on the server since the plan: leave it for the next pass, which sees both sides afresh.
      if step == .upload || step == .download, remote?.sha256 != planned[path] { continue }
      switch step {
      case .settle:
        index.checksums[path] = local[path]?.checksum
      case .upload:
        guard let file = local[path], let kind = EmulationServerBackupWorker.assetKind(file.fileType) else { continue }
        guard let bytes = try await snapshot(file, scanner: scanner, root: root) else { continue }
        var sent = false
        // The server's revision covers the whole destination, so any other upload in between (another save,
        // another device's backup) makes this one arrive late and get parked. That is only a conflict when
        // this file itself changed; otherwise send it again against the new revision.
        for _ in 0 ..< Self.uploadAttempts where !sent && live[path]?.sha256 == planned[path] {
          let upload = try await client.createUpload(libraryId: destination.libraryId)
          try await Self.send(bytes, uploadID: upload.id, client: client)
          try Task.checkCancellation()
          let metadata = UploadComplete(itemId: destination.id, kind: kind, displayName: (path as NSString).lastPathComponent,
                                        relativePath: SaveSyncPaths.remotePath(for: path), baseRevision: manifest.revision)
          let asset = try await client.completeUpload(uploadId: upload.id, metadata: metadata)
          manifest = try await client.manifest(itemId: destination.id)
          live = Self.liveSaves(in: manifest)
          sent = asset.conflictOf == nil
        }
        if sent {
          index.checksums[path] = file.checksum
          outcome.uploaded += 1
        } else {
          // Another device changed this save first, so the server kept theirs live and parked this copy.
          outcome.conflicts.append(path)
        }
      case .download:
        guard let remote, Self.isSave(path) else { continue }
        let (bytes, answer) = try await transport.data(for: client.contentRequest(assetId: remote.id, localBytes: 0, etag: nil))
        guard answer.statusCode == 200 else { throw SyncFailure(status: answer.statusCode, message: "Save download failed") }
        guard Int64(bytes.count) == remote.size, Self.sha256(bytes) == remote.sha256 else { throw Failure.damagedDownload }
        try Task.checkCancellation()
        if try await replace(path, with: bytes, expecting: local[path]?.checksum, scanner: scanner) {
          index.checksums[path] = remote.sha256
          outcome.downloaded += 1
        }
      case .conflict:
        outcome.conflicts.append(path)
      case nil:
        break
      }
    }
    return outcome
  }

  /// The live shared saves in a destination, by local path. Server-kept copies and other folders are left out.
  private static func liveSaves(in manifest: Manifest) -> [String: ManifestFile] {
    var saves: [String: ManifestFile] = [:]
    for file in manifest.files where file.conflictOf == nil && ["battery_save", "save_state"].contains(file.kind) {
      guard let path = SaveSyncPaths.relativePath(fromRemote: file.relativePath), isSave(path), saves[path] == nil else { continue }
      saves[path] = file
    }
    return saves
  }

  /// Only paths this app itself would send are ever written: a server cannot place a file anywhere else.
  private static func isSave(_ path: String) -> Bool {
    guard let type = SyncClassifier.classify(relativePath: path) else { return false }
    return EmulationServerBackupWorker.assetKind(type) != nil && !EmulationServerBackupWorker.isExcluded(path)
  }

  private func scan(_ scanner: UserDataScanner) async throws -> [SyncableFileMetadata] {
    guard gate.beginLocalIO() else { throw Failure.coreBusy }
    defer { gate.endLocalIO() }
    return await scanner.scanLocalFiles().filter { Self.isSave($0.relativePath) }
  }

  /// The file's bytes, or nil when it changed since the scan: the next pass sees the new file.
  private func snapshot(_ file: SyncableFileMetadata, scanner: UserDataScanner, root: URL) async throws -> Data? {
    guard gate.beginLocalIO() else { throw Failure.coreBusy }
    defer { gate.endLocalIO() }
    let url = await scanner.absoluteURL(for: file.relativePath)
    let prefix = root.resolvingSymlinksInPath().path + "/"
    guard url.resolvingSymlinksInPath().path.hasPrefix(prefix),
          let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
          values.isRegularFile == true, values.isSymbolicLink != true,
          let bytes = try? await scanner.readFile(relativePath: file.relativePath),
          Self.sha256(bytes) == file.checksum else { return nil }
    return bytes
  }

  /// Puts the server's file in place. The file here must still be the one the plan saw (or still be absent);
  /// it goes to Recently Deleted first. Returns false when it changed meanwhile and nothing was written.
  private func replace(_ path: String, with bytes: Data, expecting checksum: String?, scanner: UserDataScanner) async throws -> Bool {
    guard gate.beginLocalIO() else { throw Failure.coreBusy }
    defer { gate.endLocalIO() }
    let current = await scanner.fileExists(relativePath: path)
      ? (try? await scanner.readFile(relativePath: path)).map(Self.sha256) ?? "" : nil
    guard current == checksum else { return false }
    if current != nil { _ = try await scanner.moveToTrash(relativePath: path, trash: trash) }
    try await scanner.writeFile(relativePath: path, data: bytes, modificationDate: nil)
    return true
  }

  private static func send(_ bytes: Data, uploadID: String, client: ContentSync) async throws {
    let total = Int64(bytes.count)
    for offset in stride(from: 0, to: bytes.count, by: chunkSize) {
      try Task.checkCancellation()
      let end = min(bytes.count, offset + chunkSize)
      do {
        try await client.uploadChunk(uploadId: uploadID, bytes: bytes.subdata(in: offset ..< end),
                                     offset: Int64(offset), totalBytes: total)
      } catch {
        try Task.checkCancellation()
        guard try await client.receivedOffset(uploadId: uploadID) == Int64(end) else { throw error }
      }
    }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Index

  private func indexURL(for target: EmulationServerBackupTarget) -> URL {
    let name = Self.sha256(Data((target.server.id + "\n" + target.itemID).utf8))
    return indexDirectory.appendingPathComponent(name + ".json")
  }

  /// A missing or unreadable index is an empty one: every file that differs is then a conflict, never a guess.
  private func loadIndex(at url: URL) -> Index {
    (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Index.self, from: $0) } ?? Index()
  }

  private func saveIndex(_ index: Index, at url: URL) {
    try? FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
    try? JSONEncoder().encode(index).write(to: url, options: .atomic)
  }
}
