// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import RomMClient

/// RomM's game files on the shared background downloader, its JSON reads on an in-process session.
///
/// The RomM client asks for a game's files one after another and keeps its file list to itself, so
/// a game of several files moves on to its next file only while iCube runs. A file that finished
/// while iCube was away is handed over at once when the game is asked for again.
struct RomMBackgroundTransport: RomMTransport {
  /// The game the current task is downloading. Without one, a download stays in process.
  @TaskLocal static var job: BackgroundDownloadJob?

  private let reads = RomMReadSession()
  private let downloader: any GameFileFetching

  init(downloader: any GameFileFetching = BackgroundGameDownloader.shared) {
    self.downloader = downloader
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await reads.session.data(for: request)
  }

  func download(for request: URLRequest) async throws -> (URL, URLResponse) {
    guard let job = Self.job, let url = request.url else { return try await reads.session.download(for: request) }
    let file = GameFileRequest(url: url, headers: request.allHTTPHeaderFields ?? [:], expectedSize: nil)
    do {
      let files = try await downloader.fetch([file], for: job, plan: nil) { _ in }
      // The downloader only hands over a file that came back 200 or 206.
      guard let arrived = files.first,
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
        throw RomMError.invalidResponse
      }
      return (arrived, response)
    } catch let error as BackgroundDownloadError {
      switch error.failure {
      case .accessDenied: throw RomMError.accessDenied
      case .unavailable: throw RomMError.unavailable
      case .cancelled: throw CancellationError()
      default: throw error
      }
    }
  }
}

/// The same session the RomM client makes for itself: no cookies, no stored credentials, and no
/// redirects, so the Authorization header never reaches another host.
private final class RomMReadSession: Sendable {
  let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCredentialStorage = nil
    configuration.httpShouldSetCookies = false
    session = URLSession(configuration: configuration, delegate: RomMNoRedirects(), delegateQueue: nil)
  }

  deinit { session.invalidateAndCancel() }
}

private final class RomMNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
