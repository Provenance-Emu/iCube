// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// What `SkinCatalogService.load` produced: the catalog, and whether it is a cached copy standing
/// in for a failed download.
struct SkinCatalogLoad: Sendable {
  var catalog: SkinCatalog
  /// Set when the network fetch failed and a cached catalog was returned instead.
  var networkError: String?

  var isFallback: Bool { networkError != nil }
}

/// Fetches and caches the provenance-emu.com skin catalog (ported from iFly).
///
/// The cache is the server's bytes, verbatim, at `cacheURL`; freshness is the file's modification
/// date, stamped from the injected clock so the TTL holds across launches. Failure order: network
/// (each mirror in turn) → in-memory copy (any age) → disk copy (any age) → throw. An offline
/// player with any previous fetch always gets a catalog.
actor SkinCatalogService {
  static let shared = SkinCatalogService()

  /// Primary first. The GitHub raw URL serves the same file from the repository the site is built from.
  static let defaultCatalogURLs: [URL] = [
    URL(string: "https://provenance-emu.com/skins/catalog.json"),
    URL(string: "https://raw.githubusercontent.com/Provenance-Emu/skins/main/catalog.json")
  ].compactMap { $0 }

  static let defaultTTL: TimeInterval = 24 * 60 * 60
  static let cacheFileName = "skin_store_catalog.json"
  private static let requestTimeout: TimeInterval = 30

  typealias Fetch = @Sendable (URL) async throws -> (Data, URLResponse)

  private let catalogURLs: [URL]
  private let cacheURL: URL
  private let ttl: TimeInterval
  private let now: @Sendable () -> Date
  private let fetch: Fetch

  private var memoryCatalog: SkinCatalog?
  /// When `memoryCatalog`'s bytes were fetched (the cache file's mtime when it came from disk).
  private var memoryFetchedAt: Date?

  init(catalogURLs: [URL] = SkinCatalogService.defaultCatalogURLs,
       cacheURL: URL = SkinCatalogService.defaultCacheURL,
       ttl: TimeInterval = SkinCatalogService.defaultTTL,
       now: @escaping @Sendable () -> Date = { Date() },
       fetch: @escaping Fetch = { url in
         var request = URLRequest(url: url)
         request.cachePolicy = .reloadIgnoringLocalCacheData
         request.timeoutInterval = SkinCatalogService.requestTimeout
         return try await URLSession.shared.data(for: request)
       }) {
    self.catalogURLs = catalogURLs
    self.cacheURL = cacheURL
    self.ttl = ttl
    self.now = now
    self.fetch = fetch
  }

  static var defaultCacheURL: URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    return caches.appendingPathComponent(cacheFileName)
  }

  // MARK: - Public API

  /// The catalog: from cache when fresh, otherwise from the network with a cache fallback.
  func catalog(forceRefresh: Bool = false) async throws -> SkinCatalog {
    try await load(forceRefresh: forceRefresh).catalog
  }

  /// `catalog(forceRefresh:)` plus whether a cached copy stood in for a failed download.
  func load(forceRefresh: Bool = false) async throws -> SkinCatalogLoad {
    if !forceRefresh, let fresh = freshCachedCatalog() {
      return SkinCatalogLoad(catalog: fresh, networkError: nil)
    }
    let networkError: Error
    do {
      return try await SkinCatalogLoad(catalog: fetchFromNetwork(), networkError: nil)
    } catch {
      networkError = error
    }
    if let memoryCatalog {
      NSLog("[SKINSTORE] Catalog fetch failed (%@); using in-memory copy", networkError.localizedDescription)
      return SkinCatalogLoad(catalog: memoryCatalog, networkError: networkError.localizedDescription)
    }
    if let disk = loadDiskCache() {
      NSLog("[SKINSTORE] Catalog fetch failed (%@); using disk cache", networkError.localizedDescription)
      memoryCatalog = disk.catalog
      memoryFetchedAt = disk.modified
      return SkinCatalogLoad(catalog: disk.catalog, networkError: networkError.localizedDescription)
    }
    throw networkError
  }

  /// Whatever is cached, at any age, without touching the network.
  func cachedCatalog() -> SkinCatalog? {
    if let memoryCatalog { return memoryCatalog }
    guard let disk = loadDiskCache() else { return nil }
    memoryCatalog = disk.catalog
    memoryFetchedAt = disk.modified
    return disk.catalog
  }

  func invalidateCache() {
    memoryCatalog = nil
    memoryFetchedAt = nil
    try? FileManager.default.removeItem(at: cacheURL)
  }

  // MARK: - Private

  private func freshCachedCatalog() -> SkinCatalog? {
    if let memoryCatalog, let memoryFetchedAt, now().timeIntervalSince(memoryFetchedAt) < ttl { return memoryCatalog }
    guard let disk = loadDiskCache(), now().timeIntervalSince(disk.modified) < ttl else { return nil }
    memoryCatalog = disk.catalog
    memoryFetchedAt = disk.modified
    return disk.catalog
  }

  private func fetchFromNetwork() async throws -> SkinCatalog {
    var lastError: Error = SkinCatalogError.network("no catalog URL configured")
    for url in catalogURLs {
      do {
        let (data, response) = try await fetch(url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
          throw SkinCatalogError.httpStatus(http.statusCode)
        }
        let catalog = try SkinCatalog.decode(data)
        storeDiskCache(data)
        memoryCatalog = catalog
        memoryFetchedAt = now()
        NSLog("[SKINSTORE] Fetched catalog from %@: %d skins, %d undecodable", url.host ?? url.absoluteString, catalog.skins.count, catalog.droppedEntryCount)
        return catalog
      } catch {
        NSLog("[SKINSTORE] Catalog fetch from %@ failed: %@", url.absoluteString, error.localizedDescription)
        lastError = error
      }
    }
    if lastError is SkinCatalogError { throw lastError }
    throw SkinCatalogError.network(lastError.localizedDescription)
  }

  private func loadDiskCache() -> (catalog: SkinCatalog, modified: Date)? {
    guard let data = try? Data(contentsOf: cacheURL) else { return nil }
    let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path)
    let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
    do {
      return try (SkinCatalog.decode(data), modified)
    } catch {
      NSLog("[SKINSTORE] Discarding unreadable catalog cache: %@", error.localizedDescription)
      try? FileManager.default.removeItem(at: cacheURL)
      return nil
    }
  }

  private func storeDiskCache(_ data: Data) {
    do {
      try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: cacheURL, options: .atomic)
      // Stamp the mtime from the injected clock so the TTL check and the write agree (and tests can drive time).
      try FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: cacheURL.path)
    } catch {
      NSLog("[SKINSTORE] Could not write catalog cache: %@", error.localizedDescription)
    }
  }
}
#endif
