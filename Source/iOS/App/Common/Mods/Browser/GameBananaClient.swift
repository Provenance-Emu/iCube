// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum GameBananaSort: String, CaseIterable, Identifiable {
  case newest = "Generic_Newest"
  case mostLiked = "Generic_MostLiked"
  case mostDownloaded = "Generic_MostDownloaded"
  case recentlyUpdated = "Generic_LatestUpdated"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .newest: return L("Newest")
    case .mostLiked: return L("Most Liked")
    case .mostDownloaded: return L("Most Downloaded")
    case .recentlyUpdated: return L("Recently Updated")
    }
  }
}

/// Builds the request URLs. Separate from the client so the query strings can be tested.
enum GameBananaEndpoint {
  static let base = URL(string: "https://gamebanana.com/apiv11")!

  /// GameBanana's list endpoints take a fixed 15 per page whatever `_nPerpage` says on search.
  static let listPageSize = 15

  static func nameMatch(_ name: String) -> URL {
    url("Util/Game/NameMatch", [("_sName", name)])
  }

  static func modIndex(gameID: Int, categoryID: Int?, sort: GameBananaSort, page: Int) -> URL {
    var items: [(String, String)] = [
      ("_nPerpage", String(listPageSize)),
      ("_nPage", String(page)),
      ("_aFilters[Generic_Game]", String(gameID)),
      ("_sSort", sort.rawValue),
    ]
    if let categoryID { items.append(("_aFilters[Generic_Category]", String(categoryID))) }
    return url("Mod/Index", items)
  }

  static func search(gameID: Int, query: String, page: Int) -> URL {
    url("Util/Search/Results", [
      ("_sModelName", "Mod"),
      ("_sSearchString", query),
      ("_idGameRow", String(gameID)),
      ("_nPage", String(page)),
    ])
  }

  static func categories(gameID: Int) -> URL {
    // Without an explicit sort the endpoint rejects the request ("most_items" is not recognized).
    url("Mod/Categories", [("_idGameRow", String(gameID)), ("_sSort", "a_to_z")])
  }

  static func profile(modID: Int) -> URL {
    url("Mod/\(modID)/ProfilePage", [])
  }

  private static func url(_ path: String, _ items: [(String, String)]) -> URL {
    var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    if !items.isEmpty {
      components.percentEncodedQuery = items
        .map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }
        .joined(separator: "&")
    }
    return components.url!
  }

  /// Strict encoding: the filter keys contain `[` and `]`, and a search term may contain `&`.
  private static func percentEncode(_ text: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
  }
}

protocol GameBananaTransport: Sendable {
  func data(from url: URL, userAgent: String) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionGameBananaTransport: GameBananaTransport {
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

enum GameBananaClientError: LocalizedError {
  case status(Int)

  var errorDescription: String? {
    switch self {
    case .status(let code): return String(format: L("GameBanana answered with HTTP %d."), code)
    }
  }
}

/// Read-only client for the public GameBanana API. Requests run one at a time (an actor alone
/// would not do that, since it re-enters at every `await`) and answers are cached briefly, so
/// paging back and forth costs the site nothing.
actor GameBananaClient {
  static let shared = GameBananaClient()

  private static let cacheLifetime: TimeInterval = 120

  private let transport: any GameBananaTransport
  private let userAgent: String
  private let now: @Sendable () -> Date
  private var cache: [URL: (fetched: Date, data: Data)] = [:]
  private var lastRequest: Task<Void, Never>?

  init(transport: any GameBananaTransport = URLSessionGameBananaTransport(),
       userAgent: String = GameBananaClient.defaultUserAgent,
       now: @escaping @Sendable () -> Date = { Date() }) {
    self.transport = transport
    self.userAgent = userAgent
    self.now = now
  }

  static var defaultUserAgent: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    return "iCube/\(version)"
  }

  func games(matching name: String) async throws -> [GameBananaGame] {
    try await decode(GameBananaPage<GameBananaGame>.self, from: GameBananaEndpoint.nameMatch(name)).records
  }

  func mods(gameID: Int, categoryID: Int? = nil, sort: GameBananaSort = .mostLiked, page: Int = 1) async throws
    -> GameBananaPage<GameBananaModSummary> {
    try await decode(GameBananaPage<GameBananaModSummary>.self,
                     from: GameBananaEndpoint.modIndex(gameID: gameID, categoryID: categoryID, sort: sort, page: page))
  }

  func searchMods(gameID: Int, query: String, page: Int = 1) async throws -> GameBananaPage<GameBananaModSummary> {
    try await decode(GameBananaPage<GameBananaModSummary>.self,
                     from: GameBananaEndpoint.search(gameID: gameID, query: query, page: page))
  }

  func categories(gameID: Int) async throws -> [GameBananaCategory] {
    try await decode([GameBananaCategory].self, from: GameBananaEndpoint.categories(gameID: gameID))
  }

  func modDetail(id: Int) async throws -> GameBananaModDetail {
    try await decode(GameBananaModDetail.self, from: GameBananaEndpoint.profile(modID: id))
  }

  private func decode<Value: Decodable>(_ type: Value.Type, from url: URL) async throws -> Value {
    try JSONDecoder().decode(Value.self, from: try await body(of: url))
  }

  private func body(of url: URL) async throws -> Data {
    if let hit = cache[url], now().timeIntervalSince(hit.fetched) < Self.cacheLifetime { return hit.data }
    let previous = lastRequest
    let transport = transport
    let userAgent = userAgent
    let request = Task<Data, Error> {
      await previous?.value
      try Task.checkCancellation()
      let (data, response) = try await transport.data(from: url, userAgent: userAgent)
      guard (200..<300).contains(response.statusCode) else { throw GameBananaClientError.status(response.statusCode) }
      // A rejected query is an HTTP 200 whose body is `{"_sErrorCode": ...}`; lenient page decoding
      // would otherwise turn it into an empty list.
      if let apiError = try? JSONDecoder().decode(GameBananaAPIError.self, from: data) { throw apiError }
      return data
    }
    lastRequest = Task { _ = try? await request.value }
    let data = try await withTaskCancellationHandler { try await request.value } onCancel: { request.cancel() }
    cache[url] = (now(), data)
    return data
  }
}
