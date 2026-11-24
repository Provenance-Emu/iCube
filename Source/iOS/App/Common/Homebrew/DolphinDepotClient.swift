// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Builds the request URLs. Separate from the client so they can be tested without one.
enum DolphinDepotEndpoint {
  static let api = URL(string: "https://api.dolphindepot.org")!
  static let cdn = URL(string: "https://cdn.dolphindepot.org")!

  private static let select = [
    "slug", "name", "author", "description_short", "description_long", "source_url", "banner_path", "hero_path",
    "screenshot_paths", "downloads_count", "likes_count", "updated_at",
    "categories(name,display_name,sort_order)",
    "app_versions(version,version_slug,size,release_date,changelog,app_version_assets(file_name,file_size))",
    "app_peripherals(peripherals(*))",
    "app_platforms(platforms(*))",
    "app_licenses(spdx,url,notes)",
    "app_external_resources(type,label,url,notes,sort_order)",
  ].joined(separator: ",")

  /// Every published title with its newest published version, in one request.
  static var catalogue: URL {
    var components = URLComponents(url: api.appendingPathComponent("apps"), resolvingAgainstBaseURL: false)!
    // Written out by hand: PostgREST reads `(`, `)`, `,` and `*` literally, and none of these values
    // needs escaping.
    components.percentEncodedQuery = [
      "select=" + select,
      "is_published=eq.true",
      "app_versions.is_latest=eq.true",
      "app_versions.is_published=eq.true",
      "order=name.asc",
    ].joined(separator: "&")
    return components.url!
  }

  /// The catalogue stores `<slug>/<file>`; the CDN serves it at `<slug>/image/<file>`.
  static func image(path: String) -> URL? {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2, parts.allSatisfy(HomebrewName.isSafe) else { return nil }
    return cdn.appendingPathComponent(parts[0]).appendingPathComponent("image").appendingPathComponent(parts[1])
  }

  static func package(slug: String, fileName: String) -> URL? {
    guard HomebrewName.isSafe(slug), HomebrewName.isSafe(fileName) else { return nil }
    return cdn.appendingPathComponent(slug).appendingPathComponent("release").appendingPathComponent(fileName)
  }
}

protocol DolphinDepotTransport: Sendable {
  func data(from url: URL, userAgent: String) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionDolphinDepotTransport: DolphinDepotTransport {
  private static let requestTimeout: TimeInterval = 30

  func data(from url: URL, userAgent: String) async throws -> (Data, HTTPURLResponse) {
    var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (data, http)
  }
}

enum DolphinDepotError: LocalizedError, Equatable {
  case status(Int)
  case emptyCatalogue

  var errorDescription: String? {
    switch self {
    case .status(let code): return String(format: L("Dolphin Depot answered with HTTP %d."), code)
    case .emptyCatalogue: return L("Dolphin Depot sent an empty list.")
    }
  }
}

/// Read-only client for Dolphin Depot's public API. The whole catalogue is one request, kept in
/// memory for ten minutes and on disk for the next launch and for when the site cannot be reached,
/// so browsing costs a volunteer-run service almost nothing.
actor DolphinDepotClient {
  static let shared = DolphinDepotClient()

  struct Loaded: Sendable {
    let catalogue: HomebrewCatalogue
    /// True when this is an earlier answer, shown because the site could not be reached just now.
    let isSaved: Bool
  }

  private static let cacheLifetime: TimeInterval = 10 * 60

  static var defaultCacheFile: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Homebrew", isDirectory: true)
      .appendingPathComponent("catalogue.json")
  }

  private let transport: any DolphinDepotTransport
  private let userAgent: String
  private let cacheFile: URL
  private let now: @Sendable () -> Date
  private var memory: (fetched: Date, catalogue: HomebrewCatalogue)?
  private var inFlight: Task<HomebrewCatalogue, Error>?

  init(transport: any DolphinDepotTransport = URLSessionDolphinDepotTransport(),
       userAgent: String = GameBananaClient.defaultUserAgent,
       cacheFile: URL = DolphinDepotClient.defaultCacheFile,
       now: @escaping @Sendable () -> Date = { Date() }) {
    self.transport = transport
    self.userAgent = userAgent
    self.cacheFile = cacheFile
    self.now = now
  }

  /// The catalogue: from memory inside the cache window, else from the site, else the last answer
  /// that worked. Throws only when there is nothing at all to show.
  func catalogue(forceRefresh: Bool = false) async throws -> Loaded {
    if !forceRefresh, let memory, now().timeIntervalSince(memory.fetched) < Self.cacheLifetime {
      return Loaded(catalogue: memory.catalogue, isSaved: false)
    }
    do {
      let fresh = try await fetch()
      memory = (now(), fresh)
      return Loaded(catalogue: fresh, isSaved: false)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if let earlier = memory?.catalogue ?? saved() { return Loaded(catalogue: earlier, isSaved: true) }
      throw error
    }
  }

  /// The copy on disk, for a first paint before the network answers.
  func saved() -> HomebrewCatalogue? {
    guard let data = try? Data(contentsOf: cacheFile), let catalogue = try? HomebrewCatalogue.decode(data),
          !catalogue.titles.isEmpty else { return nil }
    return catalogue
  }

  /// One other file from the service (a cover image). 2xx only.
  func data(from url: URL) async throws -> Data {
    let (data, response) = try await transport.data(from: url, userAgent: userAgent)
    guard (200 ..< 300).contains(response.statusCode) else { throw DolphinDepotError.status(response.statusCode) }
    return data
  }

  /// Callers that ask while a request is out share it.
  private func fetch() async throws -> HomebrewCatalogue {
    if let inFlight { return try await inFlight.value }
    let transport = transport
    let userAgent = userAgent
    let cacheFile = cacheFile
    let task = Task<HomebrewCatalogue, Error> {
      let (data, response) = try await transport.data(from: DolphinDepotEndpoint.catalogue, userAgent: userAgent)
      guard (200 ..< 300).contains(response.statusCode) else { throw DolphinDepotError.status(response.statusCode) }
      let catalogue = try HomebrewCatalogue.decode(data)
      // An error object fails to decode and an empty list is never the real catalogue: neither may
      // replace a copy that works.
      guard !catalogue.titles.isEmpty else { throw DolphinDepotError.emptyCatalogue }
      try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? data.write(to: cacheFile, options: .atomic)
      return catalogue
    }
    inFlight = task
    defer { inFlight = nil }
    return try await task.value
  }
}
