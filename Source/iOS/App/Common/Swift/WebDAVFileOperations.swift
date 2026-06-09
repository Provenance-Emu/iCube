// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Client-side WebDAV file operations (MOVE, COPY, DELETE, MKCOL, PUT) aligned with
/// the local `ROMUploadServer` WebDAV surface and macOS Finder expectations.
struct WebDAVFileOperations {
  enum Failure: Error, LocalizedError {
    case unexpectedStatus(Int)
    case preconditionFailed
    case transport(Error)

    var errorDescription: String? {
      switch self {
      case .unexpectedStatus(let code): return "WebDAV request failed with status \(code)"
      case .preconditionFailed: return "Destination already exists"
      case .transport(let error): return error.localizedDescription
      }
    }
  }

  let baseURL: URL
  let username: String?
  let password: String?

  /// MOVE `source` to `destination` (rename when parent directory matches).
  func moveItem(from source: URL, to destination: URL, overwrite: Bool = true) async throws {
    try await transfer(method: "MOVE", source: source, destination: destination, overwrite: overwrite)
  }

  /// COPY `source` to `destination`.
  func copyItem(from source: URL, to destination: URL, overwrite: Bool = true) async throws {
    try await transfer(method: "COPY", source: source, destination: destination, overwrite: overwrite)
  }

  /// DELETE a resource.
  func deleteItem(at url: URL) async throws {
    let (code, _, _) = try await request("DELETE", url: url)
    guard (200...299).contains(code) || code == 404 else {
      throw Failure.unexpectedStatus(code)
    }
  }

  /// MKCOL — create a collection (folder).
  func createCollection(at url: URL) async throws {
    let (code, _, _) = try await request("MKCOL", url: url)
    guard code == 201 || code == 405 else {
      throw Failure.unexpectedStatus(code)
    }
  }

  /// PUT file bytes at `url`.
  func putFile(_ data: Data, at url: URL, overwrite: Bool = true) async throws {
    var headers: [String: String] = [
      "Content-Type": "application/octet-stream",
      "Content-Length": "\(data.count)",
    ]
    if !overwrite { headers["Overwrite"] = "F" }
    let (code, _, _) = try await request("PUT", url: url, headers: headers, body: data)
    guard code == 201 || code == 204 else {
      if code == 412 { throw Failure.preconditionFailed }
      throw Failure.unexpectedStatus(code)
    }
  }

  // MARK: - Internals

  private func transfer(method: String, source: URL, destination: URL, overwrite: Bool) async throws {
    var headers = ["Destination": destinationHeader(for: destination)]
    headers["Overwrite"] = overwrite ? "T" : "F"
    let (code, _, _) = try await request(method, url: source, headers: headers)
    switch code {
    case 201, 204:
      return
    case 412:
      throw Failure.preconditionFailed
    default:
      throw Failure.unexpectedStatus(code)
    }
  }

  /// Absolute `Destination` header value required by WebDAV MOVE/COPY.
  private func destinationHeader(for url: URL) -> String {
    url.absoluteString
  }

  private func request(_ method: String,
                       url: URL,
                       headers: [String: String] = [:],
                       body: Data? = nil) async throws -> (Int, Data, HTTPURLResponse) {
    var req = URLRequest(url: url)
    req.httpMethod = method
    headers.forEach { req.addValue($0.value, forHTTPHeaderField: $0.key) }
    if let body { req.httpBody = body }
    if let username, let password {
      let token = Data("\(username):\(password)".utf8).base64EncodedString()
      req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
    }

    do {
      let (data, resp) = try await URLSession.shared.data(for: req)
      guard let http = resp as? HTTPURLResponse else {
        throw Failure.unexpectedStatus(-1)
      }
      return (http.statusCode, data, http)
    } catch let error as Failure {
      throw error
    } catch {
      throw Failure.transport(error)
    }
  }
}
