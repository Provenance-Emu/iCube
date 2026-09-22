// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Production transport over `URLSession`.
///
/// Downloads stream to disk in chunks: a GameCube/Wii disc image runs to
/// gigabytes and must never be buffered whole, and a partially-written file is
/// deliberately left on disk so the next attempt can resume it with a `Range`
/// request rather than starting over.
///
/// Reaches a plain-`http://` peer on the LAN, which requires
/// `NSAppTransportSecurity → NSAllowsLocalNetworking` in the app's Info.plist.
public struct URLSessionContinuityTransport: ContinuityTransport {
    private let session: URLSession

    /// Small, so an unreachable peer fails fast enough for the browse UI to
    /// stay responsive.
    private static let requestTimeout: TimeInterval = 15
    /// Large, because a single disc image can legitimately take an hour over
    /// congested Wi-Fi.
    private static let resourceTimeout: TimeInterval = 3600
    private static let downloadBufferBytes = 65_536

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Self.requestTimeout
            config.timeoutIntervalForResource = Self.resourceTimeout
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    public func request(_ request: ContinuityRequest) async throws -> ContinuityResponse {
        let urlRequest = makeURLRequest(request)
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw ContinuityError.invalidResponse(status: -1)
            }
            return ContinuityResponse(status: http.statusCode, headers: headerDictionary(http), body: data)
        } catch let error as ContinuityError {
            throw error
        } catch {
            throw ContinuityError.serverUnreachable(detail: (error as? URLError)?.localizedDescription)
        }
    }

    public func download(
        _ request: ContinuityRequest,
        to destination: URL,
        resumeOffset: Int64,
        progress: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws -> Int64 {
        var request = request
        if resumeOffset > 0 {
            request.headers["Range"] = "bytes=\(resumeOffset)-"
        }
        let urlRequest = makeURLRequest(request)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch {
            throw ContinuityError.serverUnreachable(detail: (error as? URLError)?.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ContinuityError.invalidResponse(status: -1)
        }

        var writeOffset = resumeOffset
        switch http.statusCode {
        case 206:
            break
        case 200:
            // The server ignored the Range header and is sending the whole
            // file. Restart from zero rather than appending, which would
            // produce a file that is the right length and wrong content.
            writeOffset = 0
        case 401:
            throw ContinuityError.tokenRejected
        case 404:
            throw ContinuityError.noActiveSession
        default:
            throw ContinuityError.invalidResponse(status: http.statusCode)
        }

        let expectedTotal = http.expectedContentLength > 0
            ? writeOffset + http.expectedContentLength
            : nil

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: destination.path) {
            fileManager.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(writeOffset))
        try handle.seekToEnd()

        var written = writeOffset
        var buffer = Data(capacity: Self.downloadBufferBytes)
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= Self.downloadBufferBytes {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    progress?(written, expectedTotal)
                    try Task.checkCancellation()
                }
            }
        } catch let error as CancellationError {
            // Flush what we have: a cancelled transfer is one the user may
            // resume, and the bytes already across are the whole point of
            // Range resume.
            try? handle.write(contentsOf: buffer)
            throw error
        } catch {
            try? handle.write(contentsOf: buffer)
            throw ContinuityError.serverUnreachable(detail: (error as? URLError)?.localizedDescription)
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        progress?(written, expectedTotal)
        return written
    }

    // MARK: - Helpers

    private func makeURLRequest(_ request: ContinuityRequest) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    private func headerDictionary(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        return headers
    }
}
