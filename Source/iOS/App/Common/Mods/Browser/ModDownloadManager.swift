// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Downloads mod archives into `<User>/Cache/ModDownloads/<file id>/`.
///
/// A foreground session: the app has no background-session plumbing, and these downloads are
/// something the user watches. A cancelled download keeps its resume data, so asking for the same
/// file again continues where it stopped.
final class ModDownloadManager: NSObject, @unchecked Sendable {
  static let shared = ModDownloadManager()

  private static let staleAge: TimeInterval = 7 * 24 * 60 * 60
  private static let idleTimeout: TimeInterval = 60

  private final class Job {
    let fileID: Int
    let destination: URL
    let expectedBytes: Int64
    let progress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<URL, Error>?
    /// The outcome, when the transfer ended before the caller began waiting for it.
    var earlyResult: Result<URL, Error>?
    var failure: Error?
    var finishedFile: URL?

    init(fileID: Int, destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
      self.fileID = fileID
      self.destination = destination
      self.expectedBytes = expectedBytes
      self.progress = progress
    }
  }

  private let lock = NSLock()
  private var jobs: [Int: Job] = [:]
  private var resumeData: [Int: Data] = [:]
  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = Self.idleTimeout
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }()

  static var downloadsDirectory: URL {
    URL(fileURLWithPath: UserFolderUtil.getUserFolder(), isDirectory: true)
      .appendingPathComponent("Cache", isDirectory: true)
      .appendingPathComponent("ModDownloads", isDirectory: true)
  }

  /// The folder one file's download and extraction live in.
  static func workDirectory(forFileID id: Int) -> URL {
    downloadsDirectory.appendingPathComponent(String(id), isDirectory: true)
  }

  /// Downloads `file`, reporting 0...1, and returns the saved archive's URL. Cancelling the
  /// calling task cancels the transfer and keeps its resume data. The checksum is not checked here.
  func download(_ file: GameBananaFile, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    guard let source = file.downloadURL else { throw ModDownloadError.noDownloadURL }
    let name = file.fileName
    guard !name.isEmpty, name == (name as NSString).lastPathComponent, !name.hasPrefix(".") else {
      throw ModDownloadError.unsafeFileName(name)
    }
    let directory = Self.workDirectory(forFileID: file.id)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: destination)

    let job = Job(fileID: file.id, destination: destination, expectedBytes: file.size, progress: progress)
    let task = startTask(for: job, source: source)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
        let early: Result<URL, Error>? = lock.withLock {
          if job.earlyResult == nil { job.continuation = continuation }
          return job.earlyResult
        }
        if let early {
          continuation.resume(with: early)
        } else {
          task.resume()
        }
      }
    } onCancel: {
      task.cancel(byProducingResumeData: { [weak self] data in
        guard let self, let data else { return }
        self.lock.withLock { self.resumeData[file.id] = data }
      })
    }
  }

  /// Removes work folders nobody has touched for a week: downloads whose install was handed to
  /// another flow stay around until then, since that flow reads them in the background.
  func sweepStaleDownloads(now: Date = Date()) {
    let fm = FileManager.default
    let entries = (try? fm.contentsOfDirectory(at: Self.downloadsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for entry in entries {
      let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
      if now.timeIntervalSince(modified) > Self.staleAge { try? fm.removeItem(at: entry) }
    }
  }

  private func startTask(for job: Job, source: URL) -> URLSessionDownloadTask {
    let saved = lock.withLock { resumeData.removeValue(forKey: job.fileID) }
    let task = saved.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: source)
    lock.withLock { jobs[task.taskIdentifier] = job }
    return task
  }

  private func finish(taskID: Int, error: Error?) {
    guard let job = lock.withLock({ jobs.removeValue(forKey: taskID) }) else { return }
    let result: Result<URL, Error>
    if let failure = job.failure ?? error {
      result = .failure((failure as? URLError)?.code == .cancelled ? CancellationError() : failure)
    } else if let file = job.finishedFile {
      result = .success(file)
    } else {
      result = .failure(URLError(.unknown))
    }
    // Hand the result to the waiting caller, or park it for a caller that has not reached its wait yet.
    let waiting: CheckedContinuation<URL, Error>? = lock.withLock {
      guard let continuation = job.continuation else {
        job.earlyResult = result
        return nil
      }
      job.continuation = nil
      return continuation
    }
    waiting?.resume(with: result)
  }
}

extension ModDownloadManager: URLSessionDownloadDelegate {
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                  totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard let job = lock.withLock({ jobs[downloadTask.taskIdentifier] }) else { return }
    let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : job.expectedBytes
    if total > 0 { job.progress(min(1, Double(totalBytesWritten) / Double(total))) }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard let job = lock.withLock({ jobs[downloadTask.taskIdentifier] }) else { return }
    if let status = (downloadTask.response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
      job.failure = ModDownloadError.status(status)
      return
    }
    // The system deletes `location` as soon as this returns, so the move has to happen here.
    do {
      try? FileManager.default.removeItem(at: job.destination)
      try FileManager.default.moveItem(at: location, to: job.destination)
      job.finishedFile = job.destination
    } catch {
      job.failure = error
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
       let fileID = lock.withLock({ jobs[task.taskIdentifier]?.fileID }) {
      lock.withLock { resumeData[fileID] = data }
    }
    finish(taskID: task.taskIdentifier, error: error)
  }
}
