// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import CryptoKit
import EmulatorContentClient
import Foundation
import PVCloudSync
import PVSyncRules

struct EmulationServerBackupTarget: Codable, Equatable {
  let server: EmulationServer
  let itemID: String
  let allowsHTTP: Bool

  static func isValidItemID(_ value: String) -> Bool {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    return (1 ... 128).contains(value.utf8.count) && value.unicodeScalars.allSatisfy(allowed.contains)
  }

  var credentialKey: String { server.id + "/backup" }
}

@MainActor
final class EmulationServerBackups: ObservableObject {
  static let shared = EmulationServerBackups()
  private static let targetsKey = "icube.emulationServerBackups"
  private static let deviceKey = "icube.emulationServerBackupDevice"

  @Published private(set) var targets: [String: EmulationServerBackupTarget]
  @Published private(set) var status: [String: String] = [:]
  private let worker = EmulationServerBackupWorker()
  private var task: Task<Void, Never>?
  private var rerun = false

  private init() {
    let data = UserDefaults.standard.data(forKey: Self.targetsKey)
    targets = data.flatMap { try? JSONDecoder().decode([String: EmulationServerBackupTarget].self, from: $0) } ?? [:]
  }

  func save(_ target: EmulationServerBackupTarget, token: String) throws {
    guard target.server.origin.scheme == "https" || target.allowsHTTP,
          EmulationServerBackupTarget.isValidItemID(target.itemID), EmulationServerLibrary.isValidToken(token) else {
      throw URLError(.badURL)
    }
    guard KeychainService.setPassword(token, for: target.credentialKey) else {
      throw CocoaError(.fileWriteNoPermission)
    }
    targets[target.server.id] = target
    configurationChanged()
  }

  func remove(_ server: EmulationServer) {
    guard let target = targets.removeValue(forKey: server.id) else { return }
    KeychainService.deletePassword(for: target.credentialKey)
    status.removeValue(forKey: server.id)
    configurationChanged()
  }

  private func configurationChanged() {
    UserDefaults.standard.set(try? JSONEncoder().encode(targets), forKey: Self.targetsKey)
    task?.cancel()
    requestBackup()
  }

  func requestBackup() {
    guard !targets.isEmpty else { return }
    guard task == nil else { rerun = true
      return
    }
    guard let root = DolphinPaths.userDirectoryURL() else { return }
    let device = UserDefaults.standard.string(forKey: Self.deviceKey) ?? UUID().uuidString.lowercased()
    UserDefaults.standard.set(device, forKey: Self.deviceKey)
    let destinations = targets.values.sorted { $0.server.id < $1.server.id }
    task = Task {
      defer {
        task = nil
        if rerun {
          rerun = false
          requestBackup()
        }
      }
      for target in destinations {
        guard !Task.isCancelled else { return }
        let id = target.server.id
        guard let token = KeychainService.getPassword(for: target.credentialKey) else {
          status[id] = L("Enter a write access token to back up to this server.")
          continue
        }
        status[id] = L("Backing up…")
        do {
          try await worker.backup(root: root, device: device, target: target, token: token)
          if !Task.isCancelled { status[id] = L("Backup complete.") }
        } catch is CancellationError {
          return
        } catch EmulationServerBackupWorker.Failure.coreBusy {
          status[id] = L("Backup will resume when emulation stops.")
          return
        } catch let failure as SyncFailure {
          if !Task.isCancelled {
            status[id] = String(format: L("Server backup failed (HTTP %d)."), failure.status)
          }
        } catch {
          if !Task.isCancelled { status[id] = L("Server backup failed. It will retry automatically.") }
        }
      }
    }
  }
}

actor EmulationServerBackupWorker {
  enum Failure: Error { case coreBusy, invalidItem, fileChanged }

  private final class DirectRequests: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
      completionHandler(nil)
    }
  }

  private var scanners: [URL: UserDataScanner] = [:]

  func backup(root: URL, device: String, target: EmulationServerBackupTarget, token: String) async throws {
    guard target.server.origin.scheme == "https" || target.allowsHTTP,
          EmulationServerBackupTarget.isValidItemID(target.itemID) else { throw Failure.invalidItem }
    let scanner = scanners[root] ?? UserDataScanner(rootDirectory: root)
    scanners[root] = scanner
    let files = try await scan(scanner)
    try Task.checkCancellation()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 60
    let session = URLSession(configuration: configuration, delegate: DirectRequests(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }

    let origin = target.server.origin
    let transport = BackupTransport(session: session)
    let client = ContentSync(baseURL: origin, token: token, transport: transport)
    let itemURL = origin.appendingPathComponent("api/v1/items").appendingPathComponent(target.itemID)
    var request = URLRequest(url: itemURL)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    let (data, response) = try await transport.data(for: request)
    guard response.statusCode == 200 else { throw SyncFailure(status: response.statusCode, message: "Backup item unavailable") }
    let item = try JSONDecoder().decode(Item.self, from: data)
    guard item.id == target.itemID else { throw Failure.invalidItem }
    var manifest = try await client.manifest(itemId: item.id)

    for file in files {
      try Task.checkCancellation()
      let path = "iCube/" + device + "/" + file.relativePath
      let kind = Self.assetKind(file.fileType)
      guard let kind else { continue }
      let live = manifest.files.first { $0.relativePath == path && $0.kind == kind && $0.conflictOf == nil }
      if live?.sha256 == file.checksum || manifest.files.contains(where: {
        live != nil && $0.conflictOf == live?.id && $0.sha256 == file.checksum
      }) { continue }
      let bytes = try await snapshot(file, scanner: scanner, root: root)
      let upload = try await client.createUpload(libraryId: item.libraryId)
      try await Self.send(bytes, uploadID: upload.id, client: client)
      try Task.checkCancellation()
      let metadata = UploadComplete(itemId: item.id, kind: kind, displayName: (file.relativePath as NSString).lastPathComponent,
                                    relativePath: path, baseRevision: manifest.revision)
      _ = try await client.completeUpload(uploadId: upload.id, metadata: metadata)
      manifest = try await client.manifest(itemId: item.id)
    }
  }

  static func assetKind(_ type: SyncableFileType) -> String? {
    switch type {
    case .gameCubeMemoryCard, .wiiSave, .gbaSave: return "battery_save"
    case .saveState, .resumeState, .saveStateMetadata, .saveStateThumbnail: return "save_state"
    default: return nil
    }
  }

  private func scan(_ scanner: UserDataScanner) async throws -> [SyncableFileMetadata] {
    let gate = SyncLocalIOGate.shared
    guard gate.beginLocalIO() else { throw Failure.coreBusy }
    defer { gate.endLocalIO() }
    return await scanner.scanLocalFiles().filter {
      Self.assetKind($0.fileType) != nil && $0.relativePath.lowercased() != "wii/shared2/sys/sysconf"
    }
  }

  private func snapshot(_ file: SyncableFileMetadata, scanner: UserDataScanner, root: URL) async throws -> Data {
    let gate = SyncLocalIOGate.shared
    guard gate.beginLocalIO() else { throw Failure.coreBusy }
    defer { gate.endLocalIO() }
    let url = await scanner.absoluteURL(for: file.relativePath)
    let prefix = root.resolvingSymlinksInPath().path + "/"
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard url.resolvingSymlinksInPath().path.hasPrefix(prefix), values.isRegularFile == true,
          values.isSymbolicLink != true, let size = values.fileSize, Int64(size) == file.fileSize else {
      throw Failure.fileChanged
    }
    let bytes = try await scanner.readFile(relativePath: file.relativePath)
    guard Int64(bytes.count) == file.fileSize,
          SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == file.checksum else {
      throw Failure.fileChanged
    }
    return bytes
  }

  private static func send(_ bytes: Data, uploadID: String, client: ContentSync) async throws {
    let total = Int64(bytes.count)
    for offset in stride(from: 0, to: bytes.count, by: 512 * 1024) {
      try Task.checkCancellation()
      let end = min(bytes.count, offset + 512 * 1024)
      do {
        try await client.uploadChunk(uploadId: uploadID, bytes: bytes.subdata(in: offset ..< end),
                                     offset: Int64(offset), totalBytes: total)
      } catch {
        try Task.checkCancellation()
        guard try await client.receivedOffset(uploadId: uploadID) == Int64(end) else { throw error }
      }
    }
  }
}

private struct BackupTransport: ContentTransport {
  let session: URLSession

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try Task.checkCancellation()
    let (bytes, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (bytes, response)
  }
}
