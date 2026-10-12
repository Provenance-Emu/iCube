// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// Bridges `URLSessionSkinStoreDownloader`'s delegate callbacks to one continuation. All mutable
/// state sits behind `lock`: URLSession calls in on its own serial delegate queue, and `cancel()` can
/// arrive from any thread.
final class SkinStoreDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let destination: URL
  private let progress: @Sendable (Double) -> Void

  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?
  private var task: URLSessionDownloadTask?
  private var cancelled = false
  /// Set in `didFinishDownloadingTo` when the file cannot be kept.
  private var finishError: Error?

  init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
    self.destination = destination
    self.progress = progress
  }

  func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<Void, Error>) {
    let alreadyCancelled = lock.withLock {
      self.continuation = continuation
      self.task = task
      return cancelled
    }
    task.resume()
    // didCompleteWithError(.cancelled) resumes the continuation.
    if alreadyCancelled { task.cancel() }
  }

  func cancel() {
    let task = lock.withLock {
      cancelled = true
      return self.task
    }
    task?.cancel()
  }

  func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64,
                  totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard totalBytesExpectedToWrite > 0 else { return }
    progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
  }

  func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    // `location` is deleted when this method returns, so the move happens here, synchronously.
    let error: Error?
    if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      error = URLSessionSkinStoreDownloader.HTTPStatusError(statusCode: http.statusCode)
    } else {
      do {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: location, to: destination)
        error = nil
      } catch let moveError {
        error = moveError
      }
    }
    lock.withLock { finishError = error }
  }

  func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
    let (continuation, finishError, cancelled) = lock.withLock {
      let pending = self.continuation
      self.continuation = nil
      return (pending, self.finishError, self.cancelled)
    }
    guard let continuation else { return }
    if cancelled {
      continuation.resume(throwing: CancellationError())
    } else if let failure = error ?? finishError {
      continuation.resume(throwing: failure)
    } else {
      progress(1)
      continuation.resume()
    }
  }
}
#endif
