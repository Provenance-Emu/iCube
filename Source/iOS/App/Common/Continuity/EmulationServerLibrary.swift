// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation
import PVContinuity

struct EmulationServer: Codable, Equatable, Identifiable, Sendable {
  let origin: URL
  var id: String { "ecs:" + origin.absoluteString }
  var name: String { origin.host.map { host in origin.port.map { "\(host):\($0)" } ?? host } ?? origin.absoluteString }

  init(address: String) throws {
    let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = address.contains("://") ? address : "http://" + address
    guard var parts = URLComponents(string: url), let scheme = parts.scheme?.lowercased(),
          ["http", "https"].contains(scheme), let host = parts.host?.lowercased(), !host.isEmpty,
          parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
          parts.path.isEmpty || parts.path == "/" else {
      throw URLError(.badURL)
    }
    parts.scheme = scheme
    parts.host = host
    parts.path = ""
    if scheme == "http", parts.port == nil { parts.port = 8473 }
    if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) {
      parts.port = nil
    }
    guard let origin = parts.url, parts.port.map({ (1 ... 65535).contains($0) }) ?? true else {
      throw URLError(.badURL)
    }
    self.origin = origin
  }

  func folder(for entry: ContinuityLibraryEntry) throws -> URL {
    let digest = SHA256.hash(data: Data((id + "\n" + entry.key).utf8))
    let name = digest.map { String(format: "%02x", $0) }.joined()
    return try ContinuityPaths.validatedURL(forRelativePath: "Software/EmulationServer/" + name)
  }
}

/// Read-only client for the server's published /api/v1 browse and content routes.
actor EmulationServerLibrary {
  private struct Page<Item: Decodable>: Decodable {
    let items: [Item]
    let nextCursor: String?
  }

  private struct Capabilities: Decodable {
    struct Version: Decodable { let major: Int }
    let `protocol`: Version
  }

  private struct Library: Decodable { let id: String }

  private struct Row: Decodable {
    struct Item: Decodable {
      let id: String
      let title: String
      let systemIdentifier: String
    }

    struct Source: Decodable {
      let id: String
      let name: String
      let title: String?
      let systemId: String?
      let size: Int64
      let availability: String
      let groupFileCount: Int?
      let groupError: String?
    }

    struct Asset: Decodable { let id: String }
    let entityType: String
    let item: Item?
    let source: Source?
    let previewAsset: Asset?
  }

  private struct Manifest: Decodable {
    struct File: Decodable {
      let id: String
      let kind: String
      let relativePath: String
      let size: Int64
      let sha256: String
      let required: Bool
    }

    let version: Int
    let itemId: String
    let files: [File]
  }

  private enum Game {
    case item(Row.Item, artworkID: String?)
    case source(Row.Source)
  }

  /// Never send a configured server's bearer token to a redirected URL.
  private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
      completionHandler(nil)
    }
  }

  private let server: EmulationServer
  private let token: String
  private let transport: any ContinuityTransport
  private let ownedSession: URLSession?
  private var games: [String: Game] = [:]

  init(server: EmulationServer, token: String, transport: (any ContinuityTransport)? = nil) {
    self.server = server
    self.token = token
    if let transport {
      self.transport = transport
      ownedSession = nil
    } else {
      let config = URLSessionConfiguration.ephemeral
      config.timeoutIntervalForRequest = 30
      let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
      self.transport = URLSessionContinuityTransport(session: session)
      ownedSession = session
    }
  }

  deinit { ownedSession?.invalidateAndCancel() }

  private func libraries() async throws -> [Library] {
    let capabilities: Capabilities = try await read("capabilities", authorized: false)
    guard capabilities.protocol.major == 1 else { throw ServerError.unsupported }
    return try await pages("browse-libraries")
  }

  func checkAccess() async throws {
    _ = try await libraries()
  }

  func catalog() async throws -> [ContinuityLibraryEntry] {
    let libraries = try await libraries()
    var entries: [ContinuityLibraryEntry] = []
    var nextGames: [String: Game] = [:]
    for library in libraries {
      let query = [URLQueryItem(name: "libraryId", value: library.id), URLQueryItem(name: "category", value: "games")]
      let rows: [Row] = try await pages("browse", query: query)
      for row in rows {
        let entry: ContinuityLibraryEntry
        let game: Game
        if row.entityType == "item", let item = row.item, let platform = Self.platform(item.systemIdentifier) {
          let artwork = row.previewAsset?.id
          entry = .init(key: "item:" + item.id, game: .init(displayName: item.title, platform: platform),
                        sizeBytes: 0, hasArtwork: artwork != nil)
          game = .item(item, artworkID: artwork)
        } else if row.entityType == "source", let source = row.source,
                  source.availability == "online", source.size > 0,
                  (source.groupFileCount ?? 0) <= 1, source.groupError == nil,
                  let platform = Self.platform(source.systemId), Self.supports(source.name) {
          entry = .init(key: "source:" + source.id, game: .init(displayName: source.title ?? source.name, platform: platform),
                        sizeBytes: source.size, hasArtwork: false)
          game = .source(source)
        } else {
          continue
        }
        if nextGames.updateValue(game, forKey: entry.key) == nil { entries.append(entry) }
      }
    }
    games = nextGames
    return entries.sorted { $0.game.displayName.localizedStandardCompare($1.game.displayName) == .orderedAscending }
  }

  func artwork(for entry: ContinuityLibraryEntry) async -> Data? {
    guard case .item(_, let id?) = games[entry.key],
          let response = try? await transport.request(request(try contentRoute("files", id: id))),
          response.status == 200, response.body.count <= 5_000_000 else { return nil }
    return response.body
  }

  func copy(_ entry: ContinuityLibraryEntry, progress: @escaping @Sendable (PullProgress) -> Void) async throws -> URL {
    guard let game = games[entry.key] else { throw ServerError.invalidContent }
    let route: String
    let name: String
    let size: Int64
    let digest: String?
    switch game {
    case .item(let item, _):
      let manifest: Manifest = try await read("items/" + Self.safeID(item.id) + "/manifest")
      let roms = manifest.files.filter { $0.kind == "rom" }
      guard manifest.version == 1, manifest.itemId == item.id, roms.count == 1, let file = roms.first,
            file.sha256.count == 64, file.sha256.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }),
            !manifest.files.contains(where: { $0.required && $0.kind != "rom" }) else {
        throw ServerError.invalidContent
      }
      route = try contentRoute("files", id: file.id)
      name = (file.relativePath as NSString).lastPathComponent
      size = file.size
      digest = file.sha256
    case .source(let source):
      route = try contentRoute("sources", id: source.id)
      name = source.name
      size = source.size
      digest = nil
    }
    guard size > 0, Self.supports(name) else { throw ServerError.invalidContent }

    let ext = (name as NSString).pathExtension.lowercased()
    let destination = try server.folder(for: entry).appendingPathComponent("Game." + ext)
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let temporary = staging.appendingPathComponent(destination.lastPathComponent)
    let fm = FileManager.default
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }

    let descriptor = FileDescriptor(kind: .gameFile, relativePath: destination.lastPathComponent, sha256: digest ?? "", size: size)
    let received = try await transport.download(request(route), to: temporary, resumeOffset: 0) { bytes, _ in
      progress(.init(currentFile: descriptor, completedFiles: 0, totalFiles: 1, bytesTransferred: bytes, totalBytes: size))
    }
    try Task.checkCancellation()
    guard received == size else { throw ServerError.invalidContent }
    if let digest, try ContinuityHash.sha256Hex(ofFileAt: temporary) != digest {
      throw ServerError.invalidContent
    }
    let valid = await MainActor.run { DiscImageBridge.gameItem(forPath: temporary.path) != nil }
    guard valid else { throw ServerError.invalidContent }
    try Task.checkCancellation()
    guard let relative = ContinuityPaths.relativePath(forAbsolutePath: destination.path) else {
      throw ServerError.invalidContent
    }
    let final = try ContinuityPaths.validatedURL(forRelativePath: relative)
    try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: temporary, to: final)
    return final
  }

  private func pages<Item: Decodable>(_ route: String, query: [URLQueryItem] = []) async throws -> [Item] {
    var entries: [Item] = []
    var cursors = Set<String>()
    var cursor: String?
    repeat {
      try Task.checkCancellation()
      let paging = cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []
      let page: Page<Item> = try await read(route, query: query + paging)
      entries.append(contentsOf: page.items)
      cursor = page.nextCursor
      if let cursor, !cursors.insert(cursor).inserted { throw ServerError.invalidContent }
    } while cursor != nil
    return entries
  }

  private func read<T: Decodable>(_ route: String, query: [URLQueryItem] = [], authorized: Bool = true) async throws -> T {
    let response = try await transport.request(request(route, query: query, authorized: authorized))
    if response.status == 401 || response.status == 403 { throw ServerError.accessDenied }
    guard response.status == 200 else { throw ContinuityError.invalidResponse(status: response.status) }
    return try response.decoded(T.self)
  }

  private func request(_ route: String, query: [URLQueryItem] = [], authorized: Bool = true) throws -> ContinuityRequest {
    var parts = URLComponents(url: server.origin, resolvingAgainstBaseURL: false)
    parts?.path = "/api/v1/" + route
    parts?.queryItems = query.isEmpty ? nil : query
    // The server's query parser treats a literal '+' as a space.
    if let encoded = parts?.percentEncodedQuery {
      parts?.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
    }
    guard let url = parts?.url else { throw URLError(.badURL) }
    return authorized ? .authorized(url: url, token: token) : .init(url: url)
  }

  private func contentRoute(_ collection: String, id: String) throws -> String {
    try collection + "/" + Self.safeID(id) + "/content"
  }

  private static func safeID(_ id: String) throws -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    guard !id.isEmpty, id.unicodeScalars.allSatisfy(allowed.contains) else { throw ServerError.invalidContent }
    return id
  }

  private static func platform(_ value: String?) -> String? {
    switch value {
    case "com.provenance.gamecube": return "gc"
    case "com.provenance.wii": return "wii"
    default: return nil
    }
  }

  private static func supports(_ name: String) -> Bool {
    ["iso", "gcm", "rvz", "wia", "wbfs", "gcz", "ciso", "wad"].contains((name as NSString).pathExtension.lowercased())
  }

  enum ServerError: LocalizedError {
    case unsupported, invalidContent, accessDenied

    var errorDescription: String? {
      switch self {
      case .unsupported: return L("This Emulation Server version is unsupported.")
      case .invalidContent: return L("The server did not provide a valid single-file game.")
      case .accessDenied: return L("The server denied access. Check your access token and library permissions.")
      }
    }
  }
}
