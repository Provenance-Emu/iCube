// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import EmulatorContentClient
import Foundation
import PVContinuity
import PVRemoteLibrary
import PVSystems

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
    struct SystemCount: Decodable {
      let systemId: String
      let count: Int
    }

    let items: [Item]
    let nextCursor: String?
    /// Game counts for the whole scope, on every browse page.
    let systemCounts: [SystemCount]?
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
      let artworkAvailable: Bool?
      let artworkPath: String?
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

  private struct SourceGroup: Decodable {
    struct File: Decodable {
      let id: String
      let relativePath: String
      let size: Int64
      let availability: String
    }

    let sourceId: String
    let files: [File]
    let error: String?
  }

  /// One file of a game, as the server lists it. Kept in the download journal, so a game can be
  /// finished after a relaunch without browsing the server again.
  struct Download: Codable, Equatable, Sendable {
    let route: String
    let path: String
    let size: Int64
    let digest: String?
  }

  /// What finishing one game needs: the server, the entry and its files.
  struct DownloadPlan: Codable, Sendable {
    let server: EmulationServer
    let entry: ContinuityLibraryEntry
    let downloads: [Download]
  }

  private enum Game {
    case item(Row.Item)
    case source(Row.Source)
  }

  /// The most rows the server returns in one browse page.
  private static let pageSize = 100
  /// The server stores covers up to this size.
  private static let maximumCoverBytes = 8_000_000
  private static let systemIDs = [SystemIdentifier.GameCube.rawValue, SystemIdentifier.Wii.rawValue]

  /// Never send a configured server's bearer token to a redirected URL.
  private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
      completionHandler(nil)
    }
  }

  private let server: EmulationServer
  private let token: String?
  private let transport: any ContinuityTransport
  private let ownedSession: URLSession?
  /// Game files: the shared background downloader, or the transport when one is given.
  private let fetcher: any GameFileFetching
  private var games: [String: Game] = [:]
  /// Server-relative cover path for each entry that has one.
  private var coverPaths: [String: String] = [:]
  /// Covers already checked against the server by this catalog.
  private var checkedCovers = Set<String>()
  /// Where `continueCatalog` resumes.
  private var pendingCursor: CatalogCursor?

  init(server: EmulationServer, token: String?, transport: (any ContinuityTransport)? = nil,
       fetcher: (any GameFileFetching)? = nil) {
    self.server = server
    self.token = token
    if let transport {
      self.transport = transport
      self.fetcher = fetcher ?? TransportGameFileFetcher(transport: transport)
      ownedSession = nil
    } else {
      self.fetcher = fetcher ?? BackgroundGameDownloader.shared
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

  static func isValidToken(_ token: String) -> Bool {
    !token.isEmpty && token.utf8.allSatisfy { (33 ... 126).contains($0) }
  }

  struct CatalogCursor: Sendable {
    fileprivate var libraries: ArraySlice<String>
    fileprivate var cursor: String?
    fileprivate var seenCursors = Set<String>()
    fileprivate let search: String
    /// GameCube and Wii games counted in the libraries read so far.
    fileprivate var counted = 0
  }

  struct CatalogPage: Sendable {
    let entries: [ContinuityLibraryEntry]
    let next: CatalogCursor?
    /// The server's count for this search, once every library has reported.
    let total: Int?
  }

  /// One row from each library is enough: every browse page carries the scope's counts.
  func gameCount() async throws -> Int {
    var total = 0
    for library in try await libraries() {
      try Task.checkCancellation()
      let page: Page<Row> = try await read("browse", query: Self.browseQuery(library: library.id, limit: 1))
      total += Self.playableCount(page.systemCounts)
    }
    return total
  }

  private static func browseQuery(library: String, limit: Int) -> [URLQueryItem] {
    [
      URLQueryItem(name: "libraryId", value: library),
      URLQueryItem(name: "category", value: "games"),
      URLQueryItem(name: "systemIds", value: systemIDs.joined(separator: ",")),
      URLQueryItem(name: "limit", value: String(limit)),
    ]
  }

  private static func playableCount(_ counts: [Page<Row>.SystemCount]?) -> Int {
    (counts ?? []).filter { systemIDs.contains($0.systemId) }.reduce(0) { $0 + max(0, $1.count) }
  }

  func catalog(search: String = "") async throws -> CatalogPage {
    let libraries = try await libraries().map(\.id)
    try Task.checkCancellation()
    games.removeAll()
    coverPaths.removeAll()
    return try await catalogPage(after: CatalogCursor(
      libraries: libraries[...],
      search: search.trimmingCharacters(in: .whitespacesAndNewlines)
    ))
  }

  func catalogPage(after cursor: CatalogCursor) async throws -> CatalogPage {
    var remaining = cursor
    var entries: [ContinuityLibraryEntry] = []
    while let library = remaining.libraries.first, entries.isEmpty {
      try Task.checkCancellation()
      var query = Self.browseQuery(library: library, limit: Self.pageSize)
      if !remaining.search.isEmpty { query.append(URLQueryItem(name: "search", value: remaining.search)) }
      if let cursor = remaining.cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
      let page: Page<Row> = try await read("browse", query: query)
      try Task.checkCancellation()
      if remaining.cursor == nil { remaining.counted += Self.playableCount(page.systemCounts) }
      remaining.cursor = page.nextCursor
      if let cursor = remaining.cursor {
        guard remaining.seenCursors.insert(cursor).inserted else { throw ServerError.invalidContent }
      } else {
        remaining.libraries.removeFirst()
        remaining.seenCursors.removeAll()
      }
      for row in page.items {
        let entry: ContinuityLibraryEntry
        let game: Game
        if row.entityType == "item", let item = row.item, let platform = Self.platform(item.systemIdentifier) {
          let cover = row.previewAsset.flatMap { try? "/api/v1/" + contentRoute("files", id: $0.id) }
          entry = .init(key: "item:" + item.id, game: .init(displayName: item.title, platform: platform),
                        sizeBytes: 0, hasArtwork: cover != nil)
          coverPaths[entry.key] = cover
          game = .item(item)
        } else if row.entityType == "source", let source = row.source,
                  source.availability == "local", source.size > 0,
                  source.groupError == nil, let platform = Self.platform(source.systemId),
                  Self.supportsSource(source) {
          let cover = source.artworkAvailable == true ? source.artworkPath.flatMap(Self.coverPath) : nil
          entry = .init(key: "source:" + source.id, game: .init(displayName: source.title ?? source.name, platform: platform),
                        sizeBytes: (source.groupFileCount ?? 0) > 1 ? 0 : source.size, hasArtwork: cover != nil)
          coverPaths[entry.key] = cover
          game = .source(source)
        } else {
          continue
        }
        games[entry.key] = game
        entries.append(entry)
      }
    }
    // A library whose first page has not been read has not been counted yet.
    let uncounted = remaining.libraries.count - (remaining.cursor == nil ? 0 : 1)
    return CatalogPage(entries: entries, next: remaining.libraries.isEmpty ? nil : remaining,
                       total: uncounted == 0 ? remaining.counted : nil)
  }

  /// The cover, or word that the one the cache holds is current. A cover this catalog has already checked
  /// is not asked about again.
  func artwork(for entry: ContinuityLibraryEntry, etag: String?) async throws -> ArtworkResult {
    guard let path = coverPaths[entry.key] else { return .none }
    var request = try request(path: path)
    if etag != nil, checkedCovers.contains(path) { return .notModified }
    if let etag { request.headers["If-None-Match"] = etag }
    let response = try await transport.request(request)
    checkedCovers.insert(path)
    if response.status == 304, etag != nil { return .notModified }
    guard response.status == 200, !response.body.isEmpty, response.body.count <= Self.maximumCoverBytes else { return .none }
    let newETag = response.headers.first { $0.key.caseInsensitiveCompare("ETag") == .orderedSame }?.value
    return .image(response.body, etag: newETag)
  }

  private func downloads(for game: Game) async throws -> [Download] {
    switch game {
    case .item(let item):
      let manifest: Manifest = try await read("items/" + Self.safeID(item.id) + "/manifest")
      let roms = manifest.files.filter { $0.kind == "rom" }
      guard manifest.version == 1, manifest.itemId == item.id,
            !manifest.files.contains(where: { $0.required && $0.kind != "rom" }) else {
        throw ServerError.invalidContent
      }
      return try roms.compactMap { file in
        guard Self.safeRelativePath(file.relativePath) else { throw ServerError.invalidContent }
        // Dolphin imports the disc images themselves and reads their disc numbers from the headers.
        if Self.isPlaylist(file.relativePath) { return nil }
        guard file.sha256.count == 64,
              file.sha256.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }) else {
          throw ServerError.invalidContent
        }
        return Download(route: try contentRoute("files", id: file.id), path: file.relativePath,
                        size: file.size, digest: file.sha256)
      }
    case .source(let source):
      guard (source.groupFileCount ?? 0) > 1 else {
        return [Download(route: try contentRoute("sources", id: source.id), path: source.name,
                         size: source.size, digest: nil)]
      }
      let group: SourceGroup = try await read("sources/" + Self.safeID(source.id) + "/group")
      guard group.sourceId == source.id, group.error == nil, group.files.count == source.groupFileCount,
            let primary = group.files.first, primary.id == source.id, Self.isPlaylist(primary.relativePath),
            group.files.allSatisfy({ $0.availability == "local" && Self.safeRelativePath($0.relativePath) }) else {
        throw ServerError.invalidContent
      }
      return try group.files.filter { !Self.isPlaylist($0.relativePath) }.map { file in
        Download(route: try contentRoute("sources", id: file.id), path: file.relativePath,
                 size: file.size, digest: nil)
      }
    }
  }

  func downloadJob(for entry: ContinuityLibraryEntry) -> BackgroundDownloadJob {
    BackgroundDownloadJob(kind: .emulationServer, sourceID: server.id, gameKey: entry.key, title: entry.game.displayName)
  }

  /// The game's files: from the catalog when it was browsed, else from the plan a download that is
  /// still in the journal was started with.
  private func plannedDownloads(
    for entry: ContinuityLibraryEntry, job: BackgroundDownloadJob, fetcher: any GameFileFetching
  ) async throws -> [Download] {
    if let game = games[entry.key] { return try await downloads(for: game) }
    if let saved = await fetcher.savedPlan(for: job),
       let plan = try? JSONDecoder().decode(DownloadPlan.self, from: saved),
       plan.server == server, plan.entry.key == entry.key {
      return plan.downloads
    }
    throw ServerError.invalidContent
  }

  /// Every file is asked for before any is waited on, so all of them keep going while iCube is
  /// suspended. Finishing (checks, unpacking, the move into the library) starts once all are in.
  func copy(_ entry: ContinuityLibraryEntry, progress: @escaping @Sendable (PullProgress) -> Void) async throws -> [URL] {
    try await transfer(entry, temporaryFolder: nil, progress: progress)
  }

  func copyTemporarily(
    _ entry: ContinuityLibraryEntry, into folder: URL, progress: @escaping @Sendable (PullProgress) -> Void
  ) async throws -> [URL] {
    try await transfer(entry, temporaryFolder: folder, progress: progress)
  }

  private func transfer(
    _ entry: ContinuityLibraryEntry, temporaryFolder: URL?, progress: @escaping @Sendable (PullProgress) -> Void
  ) async throws -> [URL] {
    // Temporary play uses an in-process transfer so it cannot resume as a library import.
    let transferFetcher: any GameFileFetching = temporaryFolder == nil ? fetcher : TransportGameFileFetcher(transport: transport)
    let job = downloadJob(for: entry)
    let downloads = try await plannedDownloads(for: entry, job: job, fetcher: transferFetcher)
    let count = downloads.count
    let folded = Set(downloads.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() })
    guard (1 ... 512).contains(count), folded.count == count, Set(downloads.map(\.route)).count == count,
          downloads.allSatisfy({ $0.size > 0 && Self.safeRelativePath($0.path) && Self.supports($0.path) }) else {
      throw ServerError.invalidContent
    }
    let totalBytes = try downloads.reduce(Int64(0)) { bytes, file in
      let (total, overflow) = bytes.addingReportingOverflow(file.size)
      guard !overflow else { throw ServerError.invalidContent }
      return total
    }
    // Download and verification both stage files on the app's temporary volume.
    let staging = FileManager.default.temporaryDirectory
    let capacity = (try? staging.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity
    try Self.checkDownloadSpace(bytes: totalBytes, available: capacity.map(Int64.init))
    let requests = try downloads.map { file in
      let route = try request(file.route)
      return GameFileRequest(url: route.url, headers: route.headers, expectedSize: file.size)
    }
    let plan = temporaryFolder == nil ? (try? JSONEncoder().encode(DownloadPlan(server: server, entry: entry, downloads: downloads))) : nil
    let fetched: [URL]
    do {
      fetched = try await transferFetcher.fetch(requests, for: job, plan: plan) { received in
        progress(Self.pullProgress(received: received, downloads: downloads, totalBytes: totalBytes))
      }
    } catch {
      let failure = (error as? BackgroundDownloadError)?.failure
      // A lost connection or a cancel keeps the journal's resume data for the next attempt.
      if temporaryFolder != nil || (failure?.isTerminal ?? true) { await transferFetcher.release(job) }
      if error is CancellationError || failure == .cancelled { throw CancellationError() }
      if failure == .accessDenied { throw ServerError.accessDenied }
      throw error
    }
    do {
      let urls = try await finish(entry, downloads: downloads, fetched: fetched, temporaryFolder: temporaryFolder)
      await transferFetcher.release(job)
      return urls
    } catch {
      await transferFetcher.release(job)
      throw error
    }
  }

  static func checkDownloadSpace(bytes: Int64, available: Int64?) throws {
    let reserve: Int64 = 256 * 1024 * 1024
    guard let available, bytes > max(0, available) - reserve else { return }
    throw ServerError.insufficientSpace(bytes: bytes, available: available)
  }

  private static func pullProgress(received: Int64, downloads: [Download], totalBytes: Int64) -> PullProgress {
    var remaining = max(0, received)
    var index = 0
    while index < downloads.count - 1, remaining >= downloads[index].size {
      remaining -= downloads[index].size
      index += 1
    }
    let file = downloads[index]
    let descriptor = FileDescriptor(kind: .gameFile, relativePath: file.path, sha256: file.digest ?? "", size: file.size)
    return PullProgress(currentFile: descriptor, completedFiles: index, totalFiles: downloads.count,
                        bytesTransferred: min(max(0, received), totalBytes), totalBytes: totalBytes)
  }

  /// Checks and unpacks the fetched files and moves the game into its folder. Needs no network.
  private func finish(
    _ entry: ContinuityLibraryEntry, downloads: [Download], fetched: [URL], temporaryFolder: URL?
  ) async throws -> [URL] {
    let count = downloads.count
    guard fetched.count == count else { throw ServerError.invalidContent }
    let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let ready = staging.appendingPathComponent("ready", isDirectory: true)
    let fm = FileManager.default
    try fm.createDirectory(at: ready, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }
    var paths: [String] = []
    for (index, file) in downloads.enumerated() {
      try Task.checkCancellation()
      let ext = (file.path as NSString).pathExtension.lowercased()
      let work = staging.appendingPathComponent(String(index), isDirectory: true)
      try fm.createDirectory(at: work, withIntermediateDirectories: true)
      let temporary = work.appendingPathComponent("Game." + ext)
      try fm.moveItem(at: fetched[index], to: temporary)
      let received = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
      guard received == file.size else { throw ServerError.invalidContent }
      if let digest = file.digest, try ContinuityHash.sha256Hex(ofFileAt: temporary) != digest {
        throw ServerError.invalidContent
      }
      if ext == "7z" {
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try ZipImportHelper.extractArchive(at: temporary, to: unpacked)
        let candidates = ZipImportHelper.supportedFiles(in: unpacked).sorted { $0.path < $1.path }
        let prefix = unpacked.resolvingSymlinksInPath().path + "/"
        guard !candidates.isEmpty else { throw ServerError.invalidContent }
        for candidate in candidates {
          let resolved = candidate.resolvingSymlinksInPath().path
          guard resolved.hasPrefix(prefix) else { throw ServerError.invalidContent }
          let member = String(resolved.dropFirst(prefix.count))
          let path = count == 1 ? member : file.path + "/" + member
          try stageDisc(candidate, as: path, in: ready)
          paths.append(path)
        }
      } else {
        let path = count == 1 ? temporary.lastPathComponent : file.path
        try stageDisc(temporary, as: path, in: ready)
        paths.append(path)
      }
    }
    let valid = await MainActor.run { [paths] in
      paths.allSatisfy { DiscImageBridge.gameItem(forPath: ready.appendingPathComponent($0).path) != nil }
    }
    guard valid else { throw ServerError.invalidContent }
    try Task.checkCancellation()
    if let temporaryFolder {
      try fm.moveItem(at: ready, to: temporaryFolder)
      return paths.map { temporaryFolder.appendingPathComponent($0) }
    }
    let destination = try server.folder(for: entry)
    guard let relative = ContinuityPaths.relativePath(forAbsolutePath: destination.path) else {
      throw ServerError.invalidContent
    }
    let final = try ContinuityPaths.validatedURL(forRelativePath: relative)
    let urls = try paths.map { try ContinuityPaths.validatedURL(forRelativePath: relative + "/" + $0) }
    if fm.fileExists(atPath: final.path) {
      for (path, url) in zip(paths, urls) {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              try ContinuityHash.sha256Hex(ofFileAt: url) == ContinuityHash.sha256Hex(ofFileAt: ready.appendingPathComponent(path)) else {
          throw CocoaError(.fileWriteFileExists)
        }
      }
    } else {
      try Task.checkCancellation()
      try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.moveItem(at: ready, to: final)
    }
    // Also on a repeat copy, so a game brought in by an older build learns where it came from.
    RemoteGameOrigin(server: server.origin, key: entry.key).write(in: final)
    return urls
  }

  // MARK: - Writing details back

  private struct Revision: Decodable { let revision: Int }

  /// Saves a title, and a cover when one is given, for a game this server listed. The server decides whether
  /// this token may: a read-only token gets `accessDenied`.
  func saveDetails(forKey key: String, title: String?, cover: Data?) async throws {
    do {
      try await writeDetails(forKey: key, title: title, cover: cover)
    } catch ServerError.editConflict {
      // Someone else edited the game in between: read its revision again and try once more.
      try await writeDetails(forKey: key, title: title, cover: cover)
    }
  }

  private func writeDetails(forKey key: String, title: String?, cover: Data?) async throws {
    if key.hasPrefix(Self.sourceKeyPrefix) {
      let route = try "sources/" + Self.safeID(String(key.dropFirst(Self.sourceKeyPrefix.count)))
      var revision = (try await read(route + "/matches/selections") as Revision).revision
      if let title {
        revision = try await write(route + "/details", revision: revision, type: "application/json",
                                   body: JSONEncoder().encode(["title": title]))
      }
      if let cover, let type = Self.imageType(cover) {
        _ = try await write(route + "/details/cover", revision: revision, type: type, body: cover)
      }
    } else if key.hasPrefix(Self.itemKeyPrefix) {
      // An uploaded game's title is its item's; its cover is an uploaded file, which this does not replace.
      guard let title else { return }
      let route = try "items/" + Self.safeID(String(key.dropFirst(Self.itemKeyPrefix.count)))
      let revision = (try await read(route) as Revision).revision
      _ = try await write(route, method: "PATCH", revision: revision, type: "application/json",
                          body: JSONEncoder().encode(["title": title]))
    } else {
      throw ServerError.invalidContent
    }
  }

  /// Sends an edit against the revision it was read at and returns the new revision.
  private func write(_ route: String, method: String = "PUT", revision: Int, type: String, body: Data) async throws -> Int {
    var request = try request(route)
    request.method = method
    request.headers["If-Match"] = "\"rev-\(revision)\""
    request.headers["Content-Type"] = type
    request.body = body
    let response = try await transport.request(request)
    switch response.status {
    case 200: return (try? response.decoded(Revision.self).revision) ?? revision + 1
    case 401, 403: throw ServerError.accessDenied
    case 404, 405: throw ServerError.editUnavailable
    case 409, 412: throw ServerError.editConflict
    default: throw ContinuityError.invalidResponse(status: response.status)
    }
  }

  private static let sourceKeyPrefix = "source:"
  private static let itemKeyPrefix = "item:"

  /// The content type of a PNG or JPEG, the two formats a cover is sent as.
  static func imageType(_ data: Data) -> String? {
    if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    return nil
  }

  private func stageDisc(_ source: URL, as path: String, in folder: URL) throws {
    let fm = FileManager.default
    let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    let destination = folder.appendingPathComponent(path)
    guard Self.safeRelativePath(path), values.isRegularFile == true, values.isSymbolicLink != true,
          !fm.fileExists(atPath: destination.path) else { throw ServerError.invalidContent }
    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.moveItem(at: source, to: destination)
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
    try request(path: "/api/v1/" + route, query: query, authorized: authorized)
  }

  private func request(path: String, query: [URLQueryItem] = [], authorized: Bool = true) throws -> ContinuityRequest {
    var parts = URLComponents(url: server.origin, resolvingAgainstBaseURL: false)
    parts?.path = path
    parts?.queryItems = query.isEmpty ? nil : query
    // The server's query parser treats a literal '+' as a space.
    if let encoded = parts?.percentEncodedQuery {
      parts?.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: "%2B")
    }
    guard let url = parts?.url else { throw URLError(.badURL) }
    if authorized, let token { return .authorized(url: url, token: token) }
    return .init(url: url)
  }

  private func contentRoute(_ collection: String, id: String) throws -> String {
    try collection + "/" + Self.safeID(id) + "/content"
  }

  private static func safeID(_ id: String) throws -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    guard !id.isEmpty, id.unicodeScalars.allSatisfy(allowed.contains) else { throw ServerError.invalidContent }
    return id
  }

  /// A cover path from a browse row, kept only when it stays inside this server's API.
  private static func coverPath(_ path: String) -> String? {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./")
    guard path.hasPrefix("/api/v1/"), path.unicodeScalars.allSatisfy(allowed.contains),
          safeRelativePath(String(path.dropFirst())) else { return nil }
    return path
  }

  private static func platform(_ value: String?) -> String? {
    switch value.flatMap(SystemIdentifier.init(rawValue:)) {
    case .GameCube: return "gc"
    case .Wii: return "wii"
    default: return nil
    }
  }

  private static func supports(_ name: String) -> Bool {
    ["iso", "gcm", "rvz", "wia", "wbfs", "gcz", "ciso", "wad", "7z"].contains((name as NSString).pathExtension.lowercased())
  }

  private static func supportsSource(_ source: Row.Source) -> Bool {
    (source.groupFileCount ?? 0) > 1 ? isPlaylist(source.name) : supports(source.name)
  }

  private static func isPlaylist(_ path: String) -> Bool {
    (path as NSString).pathExtension.lowercased() == "m3u"
  }

  private static func safeRelativePath(_ path: String) -> Bool {
    !path.isEmpty && !path.contains("\\") && !path.contains(":") && !path.contains("\0") &&
      path.split(separator: "/", omittingEmptySubsequences: false)
      .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  enum ServerError: LocalizedError {
    case unsupported, invalidContent, accessDenied, editUnavailable, editConflict
    case insufficientSpace(bytes: Int64, available: Int64)

    var errorDescription: String? {
      switch self {
      case .unsupported: return L("This Emulation Server version is unsupported.")
      case let .insufficientSpace(bytes, available):
        let required = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
        return String(format: L("Not enough free space to download this game (%@ required, %@ available)."), required, free)
      case .invalidContent: return L("The server did not provide valid game files.")
      case .accessDenied: return L("The server denied access. Check your access token and library permissions.")
      case .editUnavailable: return L("The server cannot save edits to this game. It may need an update.")
      case .editConflict: return L("The game changed on the server at the same time. Try again.")
      }
    }
  }
}

extension EmulationServerLibrary: RemoteGameCatalog {
  func openCatalog(search: String) async throws -> RemoteCatalogPage {
    pendingCursor = nil
    return remember(try await catalog(search: search))
  }

  func continueCatalog() async throws -> RemoteCatalogPage {
    guard let cursor = pendingCursor else { return RemoteCatalogPage(entries: [], hasMore: false, total: nil) }
    return remember(try await catalogPage(after: cursor))
  }

  private func remember(_ page: CatalogPage) -> RemoteCatalogPage {
    pendingCursor = page.next
    return RemoteCatalogPage(entries: page.entries, hasMore: page.next != nil, total: page.total)
  }

  nonisolated func isAccessDenied(_ error: any Error) -> Bool {
    if case ServerError.accessDenied = error { return true }
    return false
  }

  nonisolated var downloadSourceID: String { server.id }

  nonisolated var sourceKind: LibrarySourceInfo.Kind { .contentServer }
}

extension EmulationServerLibrary {
  /// The server and entry a journal job was started with, if the job is an Emulation Server game.
  static func savedPlan(_ data: Data?) -> DownloadPlan? {
    data.flatMap { try? JSONDecoder().decode(DownloadPlan.self, from: $0) }
  }
}

/// Temporary server games live outside every library scan root.
enum TemporaryServerGame {
  private static let prefix = "iCube-Server-"

  static func makeFolder() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
  }

  static func remove(containing path: String) {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    guard file.path.hasPrefix(root.path + "/"),
          let folder = file.path.dropFirst(root.path.count + 1).split(separator: "/").first,
          isSessionFolder(String(folder))
    else { return }
    try? FileManager.default.removeItem(at: root.appendingPathComponent(String(folder), isDirectory: true))
  }

  /// Run before any transfers start. No temporary game is active across app launches.
  static func removeAbandoned(in root: URL = FileManager.default.temporaryDirectory) {
    let manager = FileManager.default
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
    guard let folders = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) else { return }
    for folder in folders where isSessionFolder(folder.lastPathComponent) {
      guard let values = try? folder.resourceValues(forKeys: keys),
            values.isDirectory == true, values.isSymbolicLink != true else { continue }
      try? manager.removeItem(at: folder)
    }
  }

  private static func isSessionFolder(_ name: String) -> Bool {
    name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
  }
}
