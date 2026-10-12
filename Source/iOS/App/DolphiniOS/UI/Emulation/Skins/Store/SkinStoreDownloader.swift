// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// Fetches a skin file to a local path. Abstracted so the installer's state machine can be tested
/// without the network.
protocol SkinStoreDownloading: Sendable {
  /// Downloads `url` to `destination` (overwriting it), reporting progress in 0...1. Throws on
  /// transport failure, a non-2xx status, or cancellation.
  func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Downloads a skin with `URLSessionDownloadTask`, reporting progress. Delegate-based rather than
/// `URLSession.download(from:delegate:)`: the async variant delivers no `didWriteData`, so no progress.
struct URLSessionSkinStoreDownloader: SkinStoreDownloading {
  /// A non-2xx answer. deltastyles.com serves an HTML page for a dead link, which would otherwise
  /// reach the library as a "not a skin archive".
  struct HTTPStatusError: LocalizedError {
    var statusCode: Int

    var errorDescription: String? { String(format: L("The skin's host answered with HTTP %d."), statusCode) }
  }

  private static let defaultTimeout: TimeInterval = 60

  var timeout: TimeInterval = URLSessionSkinStoreDownloader.defaultTimeout

  func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
    let delegate = SkinStoreDownloadDelegate(destination: destination, progress: progress)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    // The session retains its delegate until invalidated; invalidate once the continuation has resumed.
    defer { session.finishTasksAndInvalidate() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        delegate.start(session.downloadTask(with: url), continuation: continuation)
      }
    } onCancel: {
      delegate.cancel()
    }
  }
}
#endif
