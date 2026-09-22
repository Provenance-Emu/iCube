// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  WebRoute.swift
//  PVWebServer
//
//  A general route registry for `ROMUploadServer`, mirroring iFly's
//  `NativeWebServer.addAsyncHandler(forMethod:path:)`.
//
//  Why this exists (WS-4 prerequisite)
//  -----------------------------------
//  Before this, every route the server answered was hardcoded in the private
//  `routeRequest` / `routeHTTP` / `routeWebDAV` switch. The only extension seam
//  was `addCustomHandler`, which is synchronous, can only answer `200`, and can
//  only return a JSON dictionary or one in-memory `Data` blob. Continuity needs
//  all three things it cannot do: `async` handlers (approval prompts, actor
//  hops), real status codes and headers (`401`, `206` + `Content-Range`), and
//  file bodies streamed from disk at a byte offset — a handed-off disc image is
//  gigabytes and must never be buffered whole.
//
//  ⚠️  TRANSPORT SECURITY — READ BEFORE ADDING A ROUTE  ⚠️
//
//  This server speaks **plain HTTP over the local network**. There is no TLS.
//  Anything a route serves — save states, memory cards, Wii saves, disc images —
//  crosses the LAN in the clear and is readable by anything else on that
//  network.
//
//  This is a deliberate, accepted tradeoff, not an oversight. Continuity's
//  pairing handshake (`PVContinuity`: 6-digit code + HMAC-SHA256 proof over both
//  devices' Curve25519 public keys) **authenticates the peer**; it adds **no
//  confidentiality whatsoever**. A route's bearer token stops an unauthorised
//  device from *asking* for bytes; it does not stop a passive observer from
//  *reading* the bytes that are already in flight.
//
//  Consequences you are signing up for when you register a route here:
//    * The tradeoff must be stated in the user-facing UI (pairing + settings),
//      not left for a user to discover. It is, today, in the continuity screens.
//    * `NSAppTransportSecurity → NSAllowsLocalNetworking` is required.
//    * Never serve anything through here that would be catastrophic to leak on
//      a hostile Wi-Fi network. Credentials, tokens belonging to other services,
//      and account identifiers do not belong on this transport.

import Foundation

// MARK: - Request

/// A request as seen by an async route handler, decoupled from the server's
/// internal `HTTPRequest` so handlers (and their tests) need no server at all.
public struct WebRouteRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lower-cased by the parser; use `header(_:)` rather than
    /// subscripting so a caller spelling `"Authorization"` still matches.
    public var headers: [String: String]
    public var body: Data?

    public init(
        method: String,
        path: String,
        query: [String: String] = [:],
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Case-insensitive header lookup. HTTP header names are case-insensitive
    /// and hosts differ in what casing they preserve.
    public func header(_ name: String) -> String? {
        if let exact = headers[name] { return exact }
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }
}

// MARK: - Response

public struct WebRouteResponse: Sendable {
    /// Bodies are either in memory (JSON, small payloads) or a reference to a
    /// file the server streams from disk. Game files run to gigabytes and must
    /// never be loaded into memory.
    public enum Body: Sendable {
        case empty
        case data(Data)
        /// `length == nil` means "to the end of the file".
        case file(url: URL, offset: Int64, length: Int64?)
    }

    public var status: Int
    public var contentType: String
    public var headers: [String: String]
    public var body: Body

    public init(
        status: Int,
        contentType: String = "application/json",
        headers: [String: String] = [:],
        body: Body = .empty
    ) {
        self.status = status
        self.contentType = contentType
        self.headers = headers
        self.body = body
    }

    public static func json(_ data: Data, status: Int = 200) -> WebRouteResponse {
        WebRouteResponse(status: status, contentType: "application/json", body: .data(data))
    }

    /// A JSON `{"error": "..."}` body. Used for every non-2xx answer so a
    /// client can always parse the failure the same way.
    public static func error(status: Int, message: String) -> WebRouteResponse {
        let payload = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data()
        return WebRouteResponse(status: status, contentType: "application/json", body: .data(payload))
    }

    /// Reason phrase for the status line. Only the codes this server actually
    /// emits are spelled out; anything else gets a generic phrase, which is
    /// legal — clients parse the numeric code, not the text.
    public static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 410: return "Gone"
        case 413: return "Request Entity Too Large"
        case 416: return "Range Not Satisfiable"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return status < 400 ? "OK" : "Error"
        }
    }
}

// MARK: - Registration seam

public typealias WebRouteHandler = @Sendable (WebRouteRequest) async -> WebRouteResponse

/// What a feature needs in order to hang routes off the app's web server.
/// `PVWebServer` conforms; tests substitute a collecting stub.
public protocol WebRouteRegistering: Sendable {
    func addAsyncHandler(forMethod method: String, path: String, handler: @escaping WebRouteHandler)
}

// MARK: - Route table

/// The matching half of the registry, split out so it is pure and testable
/// without a live listener.
///
/// Matching rules, deliberately minimal:
///   * Method is compared case-insensitively after upper-casing.
///   * Path is compared **exactly**, after stripping a trailing slash from both
///     sides (so `/api/x` and `/api/x/` are one route) and after query removal
///     (the server splits the query off before we see it).
///   * First registration wins. Re-registering the same method+path is a no-op
///     rather than a silent replacement — a double `activate()` must not swap a
///     live handler out from under an in-flight request.
///
/// No wildcards or path parameters: every continuity route addresses its
/// subject through the query string, and a pattern language nobody needs is a
/// path-traversal surface nobody audits.
struct WebRouteTable: Sendable {
    private struct Entry {
        let method: String
        let path: String
        let handler: WebRouteHandler
    }

    private var entries: [Entry] = []

    init() {}

    /// Returns `true` if the route was added, `false` if an identical
    /// method+path was already registered (first registration wins).
    @discardableResult
    mutating func register(method: String, path: String, handler: @escaping WebRouteHandler) -> Bool {
        let normalizedMethod = method.uppercased()
        let normalizedPath = Self.normalize(path: path)
        guard !entries.contains(where: { $0.method == normalizedMethod && $0.path == normalizedPath }) else {
            return false
        }
        entries.append(Entry(method: normalizedMethod, path: normalizedPath, handler: handler))
        return true
    }

    func handler(forMethod method: String, path: String) -> WebRouteHandler? {
        let normalizedMethod = method.uppercased()
        let normalizedPath = Self.normalize(path: path)
        return entries.first { $0.method == normalizedMethod && $0.path == normalizedPath }?.handler
    }

    /// True when any method is registered at this path. Lets the server answer
    /// `405`-shaped cases as a registry miss rather than leaking the path into
    /// the WebDAV handler.
    func hasPath(_ path: String) -> Bool {
        let normalizedPath = Self.normalize(path: path)
        return entries.contains { $0.path == normalizedPath }
    }

    var count: Int { entries.count }

    /// Lower-cases nothing (paths are case-sensitive by RFC) but collapses a
    /// single trailing slash and guarantees a leading one.
    static func normalize(path: String) -> String {
        var normalized = path
        if !normalized.hasPrefix("/") { normalized = "/" + normalized }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
