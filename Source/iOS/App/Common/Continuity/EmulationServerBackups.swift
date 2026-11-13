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
  /// Also bring other devices' saves here (`EmulationServerSaveSyncWorker`), not only send this device's.
  var syncsSaves = false

  init(server: EmulationServer, itemID: String, allowsHTTP: Bool, syncsSaves: Bool = false) {
    self.server = server
    self.itemID = itemID
    self.allowsHTTP = allowsHTTP
    self.syncsSaves = syncsSaves
  }

  private enum CodingKeys: String, CodingKey { case server, itemID, allowsHTTP, syncsSaves }

  /// Destinations saved before save sync existed have no `syncsSaves`.
  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    server = try values.decode(EmulationServer.self, forKey: .server)
    itemID = try values.decode(String.self, forKey: .itemID)
    allowsHTTP = try values.decode(Bool.self, forKey: .allowsHTTP)
    syncsSaves = try values.decodeIfPresent(Bool.self, forKey: .syncsSaves) ?? false
  }

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

  @Published private(set) var targets: [String: EmulationServerBackupTarget]
  @Published private(set) var status: [String: String] = [:]
  /// Saves that changed on this device and on the server, by server: the user picks which to keep.
  @Published private(set) var conflicts: [String: [String]] = [:]
  private let worker = EmulationServerBackupWorker()
  private let syncWorker: EmulationServerSaveSyncWorker = {
    let support = CloudSyncCoordinator.supportDirectory()
    // The same trash the iCloud sync uses, so a replaced save shows in Recently Deleted.
    return EmulationServerSaveSyncWorker(indexDirectory: support.appendingPathComponent("EmulationServer", isDirectory: true),
                                         trash: SyncTrash(rootURL: support.appendingPathComponent("Trash", isDirectory: true)))
  }()
  /// The user's choices for conflicts, applied by the next pass.
  private var resolutions: [String: [String: EmulationServerSaveSyncWorker.Resolution]] = [:]
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
    var saved = target
    // Choosing another destination on the same server keeps the choice to sync.
    saved.syncsSaves = target.syncsSaves || targets[target.server.id]?.syncsSaves == true
    targets[target.server.id] = saved
    configurationChanged()
  }

  func setSyncsSaves(_ enabled: Bool, for server: EmulationServer) {
    guard var target = targets[server.id], target.syncsSaves != enabled else { return }
    target.syncsSaves = enabled
    targets[server.id] = target
    if !enabled {
      conflicts.removeValue(forKey: server.id)
      resolutions.removeValue(forKey: server.id)
    }
    configurationChanged()
  }

  /// Settles conflicts the way the user chose; the next pass carries it out.
  func resolve(_ paths: [String], on server: EmulationServer, _ resolution: EmulationServerSaveSyncWorker.Resolution) {
    for path in paths { resolutions[server.id, default: [:]][path] = resolution }
    task?.cancel()
    requestBackup()
  }

  func remove(_ server: EmulationServer) {
    guard let target = targets.removeValue(forKey: server.id) else { return }
    KeychainService.deletePassword(for: target.credentialKey)
    status.removeValue(forKey: server.id)
    conflicts.removeValue(forKey: server.id)
    resolutions.removeValue(forKey: server.id)
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
    let device = SyncDeviceIdentity.deviceIdentifier()
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
          guard !Task.isCancelled else { return }
          guard target.syncsSaves else {
            status[id] = L("Backup complete.")
            continue
          }
          status[id] = L("Syncing saves…")
          let outcome = try await syncSaves(root: root, target: target, token: token)
          guard !Task.isCancelled else { return }
          conflicts[id] = outcome.conflicts
          status[id] = Self.describe(outcome)
        } catch is CancellationError {
          return
        } catch EmulationServerBackupWorker.Failure.coreBusy, EmulationServerSaveSyncWorker.Failure.coreBusy {
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

extension EmulationServerBackups {
  fileprivate func syncSaves(root: URL, target: EmulationServerBackupTarget, token: String) async throws -> EmulationServerSaveSyncWorker.Outcome {
    let id = target.server.id
    let choices = resolutions[id] ?? [:]
    let session = URLSession(configuration: EmulationServerBackupWorker.sessionConfiguration(),
                             delegate: BackupDirectRequests(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let outcome = try await syncWorker.sync(root: root, target: target, token: token,
                                            transport: BackupTransport(session: session), resolving: choices)
    // A choice is spent once its pass ran; one that could not be carried out shows as a conflict again.
    for path in choices.keys { resolutions[id]?.removeValue(forKey: path) }
    return outcome
  }

  static func describe(_ outcome: EmulationServerSaveSyncWorker.Outcome) -> String {
    if !outcome.conflicts.isEmpty {
      return outcome.conflicts.count == 1
        ? L("1 save differs on this device and the server. Choose which to keep.")
        : String(format: L("%d saves differ on this device and the server. Choose which to keep."), outcome.conflicts.count)
    }
    if outcome.downloaded == 0, outcome.uploaded == 0 { return L("Saves are in step.") }
    return String(format: L("Saves are in step. Sent %1$d, received %2$d."), outcome.uploaded, outcome.downloaded)
  }
}

actor EmulationServerBackupWorker {
  enum Failure: Error { case coreBusy, invalidItem, fileChanged }

  /// The console's own settings file is the one save-typed file that must not travel between devices.
  static func isExcluded(_ relativePath: String) -> Bool {
    relativePath.lowercased() == "wii/shared2/sys/sysconf"
  }

  static func sessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 60
    return configuration
  }

  private var scanners: [URL: UserDataScanner] = [:]

  func backup(root: URL, device: String, target: EmulationServerBackupTarget, token: String) async throws {
    guard target.server.origin.scheme == "https" || target.allowsHTTP,
          EmulationServerBackupTarget.isValidItemID(target.itemID),
          EmulationServerBackupTarget.isValidItemID(device) else { throw Failure.invalidItem }
    let scanner = scanners[root] ?? UserDataScanner(rootDirectory: root)
    scanners[root] = scanner
    let files = try await scan(scanner)
    try Task.checkCancellation()
    let session = URLSession(configuration: Self.sessionConfiguration(), delegate: BackupDirectRequests(), delegateQueue: nil)
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
      Self.assetKind($0.fileType) != nil && !Self.isExcluded($0.relativePath)
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

final class BackupDirectRequests: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

enum EmulationServerBackupSetup {
  static func libraries(server: EmulationServer, token: String) async throws -> LibraryList {
    try await send(server: server, token: token, path: "browse-libraries")
  }

  static func items(server: EmulationServer, token: String, libraryID: String, cursor: String? = nil) async throws -> ItemList {
    var query = [URLQueryItem(name: "libraryId", value: libraryID), URLQueryItem(name: "limit", value: "100")]
    if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
    return try await send(server: server, token: token, path: "items", query: query)
  }

  static func createItem(server: EmulationServer, token: String, libraryID: String, key: String) async throws -> Item {
    let draft = ItemDraft(libraryId: libraryID, systemIdentifier: "com.provenance.gamecube", title: "iCube Backups")
    return try await send(server: server, token: token, path: "items", body: JSONEncoder().encode(draft), key: key)
  }

  private static func send<T: Decodable>(server: EmulationServer, token: String, path: String,
                                         query: [URLQueryItem] = [], body: Data? = nil, key: String? = nil) async throws -> T {
    var parts = URLComponents(url: server.origin.appendingPathComponent("api/v1/" + path), resolvingAgainstBaseURL: false)
    parts?.queryItems = query.isEmpty ? nil : query
    guard let url = parts?.url else { throw URLError(.badURL) }
    var request = URLRequest(url: url)
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    if let body {
      request.httpMethod = "POST"
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 20
    let session = URLSession(configuration: configuration, delegate: BackupDirectRequests(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await BackupTransport(session: session).data(for: request)
    guard (200 ... 299).contains(response.statusCode) else {
      throw SyncFailure(status: response.statusCode, message: "Backup destination unavailable")
    }
    return try JSONDecoder().decode(T.self, from: data)
  }
}

struct BackupTransport: ContentTransport {
  let session: URLSession

  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    try Task.checkCancellation()
    let (bytes, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (bytes, response)
  }
}
