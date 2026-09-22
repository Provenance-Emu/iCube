// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

public struct ContinuityRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }

    /// A request carrying the session bearer token.
    public static func authorized(url: URL, method: String = "GET", token: String) -> ContinuityRequest {
        ContinuityRequest(url: url, method: method, headers: ["Authorization": "Bearer \(token)"])
    }

    /// A JSON POST. Used by every pairing/auth round trip.
    public static func json<T: Encodable>(url: URL, payload: T) throws -> ContinuityRequest {
        ContinuityRequest(
            url: url,
            method: "POST",
            headers: ["Content-Type": "application/json"],
            body: try JSONEncoder().encode(payload)
        )
    }
}

public struct ContinuityResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: body)
    }
}

/// HTTP client abstraction.
///
/// Production uses `URLSessionContinuityTransport`; tests use
/// `PVContinuityTesting.MockTransport`, which can script responses and inject a
/// mid-download failure — the case the fallback ladder exists for and the one
/// hardest to provoke against a real server.
public protocol ContinuityTransport: Sendable {
    func request(_ request: ContinuityRequest) async throws -> ContinuityResponse

    /// Streams a download to `destination`, appending from `resumeOffset`
    /// (sent as an HTTP `Range` header when > 0). Returns the total bytes on
    /// disk when complete. `progress` reports `(bytesOnDisk, expectedTotal?)`.
    func download(
        _ request: ContinuityRequest,
        to destination: URL,
        resumeOffset: Int64,
        progress: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws -> Int64
}
