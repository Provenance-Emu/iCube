// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import CryptoKit
import Foundation
import PVContinuity
import PVWebServer

actor NearbySaveServer {
  private struct Grant {
    let peerID: String
    let gameKey: String
    let expires: Date
    let directory: URL
    let files: [String: URL]
  }

  private let manager: ContinuityManager
  private var grants: [String: Grant] = [:]
  private var replayGuard = NearbySaveReplayGuard()
  private var awaitingApproval = false
  private var generation: UInt64 = 0

  init(manager: ContinuityManager) { self.manager = manager }

  func activate(on registrar: any WebRouteRegistering) {
    registrar.addAsyncHandler(forMethod: "POST", path: NearbySaveWire.catalogPath) { [self] in await catalog($0) }
    registrar.addAsyncHandler(forMethod: "GET", path: NearbySaveWire.filePath) { [self] in await file($0) }
  }

  func forgetPeer(_ id: String) {
    generation &+= 1
    for (token, grant) in grants where grant.peerID == id {
      try? FileManager.default.removeItem(at: grant.directory)
      grants[token] = nil
    }
  }

  func forgetAllPeers() {
    generation &+= 1
    for grant in grants.values { try? FileManager.default.removeItem(at: grant.directory) }
    grants.removeAll()
  }

  private func allowed(peerID: String, gameKey: String) async -> Bool {
    guard await manager.sharesLibrary,
          await manager.trustStore.peer(withId: peerID) != nil,
          await manager.grantStore.grant(forPeerId: peerID) != .denied,
          !(await ICubeLibraryProvider().isExcludedFromSharing(key: gameKey)) else { return false }
    return true
  }

  private func prune() {
    let now = Date()
    for (token, grant) in grants where grant.expires <= now {
      try? FileManager.default.removeItem(at: grant.directory)
      grants[token] = nil
    }
    replayGuard.prune(now: now)
  }

  private func catalog(_ http: WebRouteRequest) async -> WebRouteResponse {
    prune()
    guard let body = http.body, body.count < 16384,
          let signed = try? JSONDecoder().decode(NearbySaveWire.SignedRequest.self, from: body),
          let unverified = try? JSONDecoder().decode(NearbySaveWire.Request.self, from: signed.payload),
          let peer = await manager.trustStore.peer(withId: unverified.peerID),
          let request = NearbySaveWire.verify(signed, publicKey: peer.publicKey,
                                              serverID: await manager.identity.id, now: Date()),
          await allowed(peerID: peer.id, gameKey: request.gameKey) else {
      return .error(status: 403, message: "Save sharing is not authorized.")
    }
    guard !awaitingApproval, grants.count < 16 else {
      return .error(status: 429, message: "Try again later.")
    }
    guard replayGuard.accept(request.nonce, now: Date()) else {
      return .error(status: 403, message: "Request replayed or rate limited.")
    }
    awaitingApproval = true
    defer { awaitingApproval = false }
    guard let entry = await ICubeLibraryProvider().allEntries().first(where: { $0.key == request.gameKey }),
          let gameID = entry.game.gameID else {
      return .error(status: 404, message: "Game not found.")
    }
    let admission = generation
    let approved = await withTaskGroup(of: Bool.self) { group in
      group.addTask { [manager] in
        await manager.awaitLibraryPullApproval(peerName: peer.name,
                                               gameName: entry.game.displayName, saveStates: true) == .allowOnce
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(120))
        return false
      }
      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }
    guard approved, admission == generation, await allowed(peerID: peer.id, gameKey: entry.key) else {
      return .error(status: 403, message: "Save sharing was declined or expired.")
    }
    guard SyncLocalIOGate.shared.beginLocalIO() else {
      return .error(status: 409, message: "Stop the game before sharing saves.")
    }
    defer { SyncLocalIOGate.shared.endLocalIO() }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nearby-states-" + UUID().uuidString)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let states = await FilesystemSaveStateProvider().states(for: gameID)
      guard states.count <= NearbySaveWire.maxStates else { throw CocoaError(.fileReadTooLarge) }
      var files: [String: URL] = [:]
      var descriptors: [NearbySaveWire.State] = []
      var total: Int64 = 0
      let root = DolphinPaths.stateSavesURL()?.resolvingSymlinksInPath().standardizedFileURL
      for state in states {
        try Task.checkCancellation()
        let source = state.path.resolvingSymlinksInPath().standardizedFileURL
        guard source.deletingLastPathComponent() == root else { throw CocoaError(.fileReadNoPermission) }
        let id = UUID().uuidString
        let snapshot = directory.appendingPathComponent(id)
        let size = (try source.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size > 0, Int64(size) <= NearbySaveWire.maxBytes - total else { throw CocoaError(.fileReadTooLarge) }
        total += Int64(size)
        try FileManager.default.copyItem(at: source, to: snapshot)
        let hash = try ContinuityHash.sha256Hex(ofFileAt: snapshot)
        files[id] = snapshot
        descriptors.append(.init(id: id, title: state.displayName,
                                 savedAt: state.modifiedAt ?? state.createdAt ?? .distantPast,
                                 size: Int64(size), sha256: hash))
      }
      guard admission == generation, await allowed(peerID: peer.id, gameKey: entry.key) else { throw CocoaError(.fileReadNoPermission) }
      let token = UUID().uuidString + UUID().uuidString
      grants[token] = Grant(peerID: peer.id, gameKey: entry.key, expires: Date().addingTimeInterval(600),
                            directory: directory, files: files)
      // Expiry cleanup does not depend on another request arriving.
      Task { [weak self] in
        try? await Task.sleep(for: .seconds(601))
        await self?.prune()
      }
      return .json(try JSONEncoder().encode(NearbySaveWire.Catalog(gameKey: entry.key, token: token, states: descriptors)))
    } catch {
      try? FileManager.default.removeItem(at: directory)
      return .error(status: 409, message: "The saves could not be snapshotted. Try again with the game stopped.")
    }
  }

  private func file(_ request: WebRouteRequest) async -> WebRouteResponse {
    prune()
    guard let authorization = request.header("Authorization"), authorization.hasPrefix("Bearer "),
          let grant = grants[String(authorization.dropFirst(7))],
          let id = request.query["id"], let url = grant.files[id],
          await allowed(peerID: grant.peerID, gameKey: grant.gameKey) else {
      return .error(status: 403, message: "Save grant expired or revoked.")
    }
    return WebRouteResponse(status: 200, contentType: "application/octet-stream", body: .file(url: url, offset: 0, length: nil))
  }
}

/// Saves arrive as new manual imports with generated filenames; existing slots,
/// autosaves, thumbnails and memory cards are never overwritten.
struct NearbySaveClient {
  let identity: ContinuityPeerIdentity
  let transport: any ContinuityTransport

  init(identity: ContinuityPeerIdentity) {
    self.identity = identity
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 135
    config.timeoutIntervalForResource = 900
    transport = URLSessionContinuityTransport(session: URLSession(configuration: config))
  }

  func catalog(from advertisement: ContinuityAdvertisement, entry: ContinuityLibraryEntry) async throws -> NearbySaveWire.Catalog {
    guard let base = advertisement.urlCandidates.first, let serverID = advertisement.peerId else { throw URLError(.badURL) }
    let payload = try JSONEncoder().encode(NearbySaveWire.Request(peerID: identity.id, serverID: serverID,
                                                                  gameKey: entry.key, nonce: UUID().uuidString, issuedAt: Date()))
    let signed = NearbySaveWire.SignedRequest(payload: payload, signature: try identity.signingKey.signature(for: NearbySaveWire.signingData(payload)))
    let response = try await transport.request(.json(url: base.appendingPathComponent(NearbySaveWire.catalogPath), payload: signed))
    guard response.status == 200 else {
      if response.status == 404 { throw SaveTransferError.unsupported }
      throw SaveTransferError.declined
    }
    let catalog = try response.decoded(NearbySaveWire.Catalog.self)
    guard catalog.gameKey == entry.key, catalog.states.count <= NearbySaveWire.maxStates,
          Set(catalog.states.map(\.id)).count == catalog.states.count else { throw SaveTransferError.invalid }
    var total: Int64 = 0
    for state in catalog.states {
      guard state.size > 0, state.size <= NearbySaveWire.maxBytes - total,
            state.sha256.count == 64, state.sha256.allSatisfy(\.isHexDigit) else { throw SaveTransferError.invalid }
      total += state.size
    }
    return catalog
  }

  func copy(_ states: [NearbySaveWire.State], catalog: NearbySaveWire.Catalog,
            from advertisement: ContinuityAdvertisement, entry: ContinuityLibraryEntry,
            progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> [SaveStateInfo] {
    guard let base = advertisement.urlCandidates.first, let gameID = entry.game.gameID,
          let root = DolphinPaths.stateSavesURL(), catalog.gameKey == entry.key,
          states.allSatisfy({ catalog.states.contains($0) }) else { throw SaveTransferError.invalid }
    let total = states.reduce(Int64(0)) { $0 + $1.size }
    var completed: Int64 = 0
    var imported: [URL] = []
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    // Download everything before publishing any of the selected states.
    var staged: [(NearbySaveWire.State, URL)] = []
    for state in states {
      try Task.checkCancellation()
      var components = URLComponents(url: base.appendingPathComponent(NearbySaveWire.filePath), resolvingAgainstBaseURL: false)!
      components.queryItems = [URLQueryItem(name: "id", value: state.id)]
      let temporary = staging.appendingPathComponent(UUID().uuidString)
      let previous = completed
      _ = try await transport.download(.authorized(url: components.url!, token: catalog.token),
                                       to: temporary, resumeOffset: 0) { bytes, _ in progress(previous + bytes, total) }
      try Task.checkCancellation()
      let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
      guard size.map(Int64.init) == state.size,
            try ContinuityHash.sha256Hex(ofFileAt: temporary) == state.sha256 else { throw SaveTransferError.invalid }
      staged.append((state, temporary))
      completed += state.size
    }
    guard SyncLocalIOGate.shared.beginLocalIO() else { throw SaveTransferError.running }
    defer { SyncLocalIOGate.shared.endLocalIO() }
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      for (state, temporary) in staged {
        try Task.checkCancellation()
        // No remote title, path, or game ID is used as a path component.
        let destination = root.appendingPathComponent("Nearby-\(UUID().uuidString).sav")
        try FileManager.default.moveItem(at: temporary, to: destination)
        imported.append(destination)
        guard SaveStateMetadataStore.write(.init(title: state.title, gameID: gameID,
                                                 gameTitle: entry.game.displayName, savedAt: state.savedAt), forStateFile: destination) else {
          throw CocoaError(.fileWriteUnknown)
        }
      }
    } catch {
      for url in imported {
        try? FileManager.default.removeItem(at: url)
        SaveStateMetadataStore.delete(forStateFile: url)
      }
      throw error
    }
    let paths = Set(imported)
    return await FilesystemSaveStateProvider().states(for: gameID).filter { paths.contains($0.path) }
  }
}

enum SaveTransferError: LocalizedError {
  case unsupported, declined, invalid, running
  var errorDescription: String? {
    switch self {
    case .unsupported: return L("This device doesn't support copying save states. You can still copy the game.")
    case .declined: return L("Save sharing was declined or expired. Try again on the other device.")
    case .invalid: return L("The save transfer could not be verified. Nothing was replaced.")
    case .running: return L("Stop the game before importing save states.")
    }
  }
}
