// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Downloads mod archives, and homebrew packages, into `<User>/Cache/ModDownloads/<key>-<session>/`.
///
/// `shared` is a foreground session, for downloads the user watches to the end (homebrew).
/// `background` is a background session for mod files: the transfer keeps going while iCube is
/// suspended and after the system ends it. A transfer names its key and destination in its
/// `taskDescription`, so a relaunched app can either hand the still-running transfer back to
/// whoever asks for that key again, or file a finished download where its owner will look.
/// A cancelled download keeps its resume data, so asking for the same file again continues where
/// it stopped.
final class ModDownloadManager: NSObject, @unchecked Sendable {
  static let shared = ModDownloadManager()
  static let background = ModDownloadManager(
    backgroundIdentifier: (Bundle.main.bundleIdentifier ?? "org.dolphin-emu.dolphinios") + ".mod-downloads")

  /// What a transfer's `taskDescription` holds.
  private struct Label: Codable {
    let key: String
    /// The destination, below `downloadsDirectory`.
    let path: String?
  }

  private static let staleAge: TimeInterval = 7 * 24 * 60 * 60
  private static let idleTimeout: TimeInterval = 60
  private static let progressStep = 0.01

  private final class Job {
    let key: String
    let destination: URL
    let expectedBytes: Int64
    let progress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<HomebrewDownload, Error>?
    /// The outcome, when the transfer ended before the caller began waiting for it.
    var earlyResult: Result<HomebrewDownload, Error>?
    /// Last fraction handed to `progress`; touched only on the session's serial delegate queue.
    var reportedFraction = 0.0
    var failure: Error?
    var finishedFile: URL?
    var etag: String?

    init(key: String, destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
      self.key = key
      self.destination = destination
      self.expectedBytes = expectedBytes
      self.progress = progress
    }
  }

  private static let backgroundResourceTimeout: TimeInterval = 24 * 60 * 60

  private let backgroundIdentifier: String?
  private let lock = NSLock()
  private var jobs: [Int: Job] = [:]
  private var resumeData: [String: Data] = [:]
  /// Transfers the system kept running across a relaunch, by key, until someone asks for the key.
  private var adoptable: [String: URLSessionDownloadTask] = [:]
  private var isReconciled = false
  private var reconcileWaiters: [CheckedContinuation<Void, Never>] = []
  private var eventsCompletion: (() -> Void)?
  private lazy var session: URLSession = {
    let configuration: URLSessionConfiguration
    if let backgroundIdentifier {
      configuration = .background(withIdentifier: backgroundIdentifier)
      configuration.sessionSendsLaunchEvents = true
      configuration.isDiscretionary = false
      configuration.timeoutIntervalForResource = Self.backgroundResourceTimeout
    } else {
      configuration = .default
      configuration.waitsForConnectivity = false
    }
    configuration.timeoutIntervalForRequest = Self.idleTimeout
    return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }()

  init(backgroundIdentifier: String? = nil) {
    self.backgroundIdentifier = backgroundIdentifier
  }

  // MARK: - Background session

  /// Creates the session and collects the transfers the system kept for it. Call at launch, so
  /// downloads that finished while the app was gone are filed before anyone looks for them.
  /// Does nothing for a foreground manager; safe to call again.
  func activate() {
    guard backgroundIdentifier != nil else { return }
    let isFirst = lock.withLock { () -> Bool in
      defer { didActivate = true }
      return !didActivate
    }
    guard isFirst else { return }
    session.getAllTasks { [self] all in
      let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
        for case let task as URLSessionDownloadTask in all where task.state == .running || task.state == .suspended {
          guard jobs[task.taskIdentifier] == nil, let label = Self.label(of: task) else { continue }
          adoptable[label.key] = task
        }
        isReconciled = true
        defer { reconcileWaiters = [] }
        return reconcileWaiters
      }
      waiters.forEach { $0.resume() }
    }
  }

  private var didActivate = false

  /// The app delegate's `handleEventsForBackgroundURLSession`. Returns false for another session.
  @discardableResult
  func handleEvents(forSession identifier: String, completion: @escaping () -> Void) -> Bool {
    guard let backgroundIdentifier, identifier == backgroundIdentifier else { return false }
    lock.withLock { eventsCompletion = completion }
    activate()
    return true
  }

  /// Whether a transfer for `key` is under way: one this launch started, or one the system kept.
  func isDownloading(key: String) async -> Bool {
    await reconciled()
    return lock.withLock { adoptable[key] != nil || jobs.values.contains { $0.key == key } }
  }

  private func reconciled() async {
    guard backgroundIdentifier != nil else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let ready = lock.withLock { () -> Bool in
        if !isReconciled { reconcileWaiters.append(continuation) }
        return isReconciled
      }
      if ready { continuation.resume() } else { activate() }
    }
  }

  private static func label(of task: URLSessionTask) -> Label? {
    task.taskDescription.flatMap { try? JSONDecoder().decode(Label.self, from: Data($0.utf8)) }
  }

  /// `destination` as a path below the downloads folder, or nil when it lies elsewhere.
  private static func relativePath(of destination: URL) -> String? {
    let root = downloadsDirectory.standardizedFileURL.path + "/"
    let path = destination.standardizedFileURL.path
    return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : nil
  }

  /// Where a transfer nobody is waiting for said its file goes, if that is inside the downloads folder.
  private static func orphanDestination(for label: Label) -> URL? {
    guard let path = label.path, !path.isEmpty, !path.split(separator: "/").contains(".."), !path.hasPrefix("/") else { return nil }
    return downloadsDirectory.appendingPathComponent(path)
  }

  static var downloadsDirectory: URL {
    URL(fileURLWithPath: UserFolderUtil.getUserFolder(), isDirectory: true)
      .appendingPathComponent("Cache", isDirectory: true)
      .appendingPathComponent("ModDownloads", isDirectory: true)
  }

  /// A private staging folder for one install session, even when the same file is reopened.
  static func makeWorkDirectory(forFileID id: Int) -> URL {
    makeWorkDirectory(forKey: String(id))
  }

  /// The same, for a download named by a key rather than a GameBanana file ID.
  static func makeWorkDirectory(forKey key: String) -> URL {
    downloadsDirectory.appendingPathComponent("\(key)-\(UUID().uuidString)", isDirectory: true)
  }

  /// Downloads `file`, reporting 0...1, and returns the saved archive's URL. Cancelling the
  /// calling task cancels the transfer and keeps its resume data. The checksum is not checked here.
  func download(_ file: GameBananaFile, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
    guard let source = file.downloadURL else { throw ModDownloadError.noDownloadURL }
    return try await download(key: String(file.id), from: source, fileName: file.fileName, expectedBytes: file.size,
                              into: directory, progress: progress).file
  }

  /// Downloads `source` to `directory/fileName`, reporting 0...1, and returns the saved file with
  /// the server's ETag. `key` names the transfer: a cancelled one keeps its resume data under it.
  func download(key: String, from source: URL, fileName name: String, expectedBytes: Int64, into directory: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> HomebrewDownload {
    guard !name.isEmpty, name == (name as NSString).lastPathComponent, !name.hasPrefix(".") else {
      throw ModDownloadError.unsafeFileName(name)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: destination)

    await reconciled()
    let job = Job(key: key, destination: destination, expectedBytes: expectedBytes, progress: progress)
    let task = startTask(for: job, source: source)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HomebrewDownload, Error>) in
        let early: Result<HomebrewDownload, Error>? = lock.withLock {
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
        self.lock.withLock { self.resumeData[key] = data }
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

  /// A transfer for the job: the one the system kept running for its key, else a new one.
  private func startTask(for job: Job, source: URL) -> URLSessionDownloadTask {
    let (kept, saved) = lock.withLock { (adoptable.removeValue(forKey: job.key), resumeData.removeValue(forKey: job.key)) }
    if let kept, kept.state == .running || kept.state == .suspended {
      lock.withLock { jobs[kept.taskIdentifier] = job }
      return kept
    }
    let task = saved.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: source)
    let label = Label(key: job.key, path: Self.relativePath(of: job.destination))
    task.taskDescription = (try? JSONEncoder().encode(label)).flatMap { String(data: $0, encoding: .utf8) }
    lock.withLock { jobs[task.taskIdentifier] = job }
    return task
  }

  private func finish(task: URLSessionTask, error: Error?) {
    let taskID = task.taskIdentifier
    guard let job = lock.withLock({ jobs.removeValue(forKey: taskID) }) else {
      if let key = Self.label(of: task)?.key {
        lock.withLock { if adoptable[key]?.taskIdentifier == taskID { adoptable[key] = nil } }
      }
      return
    }
    let result: Result<HomebrewDownload, Error>
    if let failure = job.failure ?? error {
      result = .failure((failure as? URLError)?.code == .cancelled ? CancellationError() : failure)
    } else if let file = job.finishedFile {
      result = .success(HomebrewDownload(file: file, etag: job.etag))
    } else {
      result = .failure(URLError(.unknown))
    }
    // Hand the result to the waiting caller, or park it for a caller that has not reached its wait yet.
    let waiting: CheckedContinuation<HomebrewDownload, Error>? = lock.withLock {
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
    guard total > 0 else { return }
    let fraction = min(1, Double(totalBytesWritten) / Double(total))
    // A big file reports thousands of times; the UI only needs whole percents.
    if fraction - job.reportedFraction >= Self.progressStep || fraction == 1 {
      job.reportedFraction = fraction
      job.progress(fraction)
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
    guard let job = lock.withLock({ jobs[downloadTask.taskIdentifier] }) else {
      // Nobody is waiting: the app was relaunched for this transfer. File the download where its
      // owner will look for it when the user comes back.
      if status.map({ (200..<300).contains($0) }) ?? true, let label = Self.label(of: downloadTask),
         let destination = Self.orphanDestination(for: label) {
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: location, to: destination)
      }
      return
    }
    if let status, !(200..<300).contains(status) {
      job.failure = ModDownloadError.status(status)
      return
    }
    // The system deletes `location` as soon as this returns, so the move has to happen here.
    do {
      try? FileManager.default.removeItem(at: job.destination)
      try FileManager.default.moveItem(at: location, to: job.destination)
      job.finishedFile = job.destination
      job.etag = (downloadTask.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
    } catch {
      job.failure = error
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
       let key = lock.withLock({ jobs[task.taskIdentifier]?.key }) {
      lock.withLock { resumeData[key] = data }
    }
    finish(task: task, error: error)
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    let completion = lock.withLock { () -> (() -> Void)? in
      defer { eventsCompletion = nil }
      return eventsCompletion
    }
    if let completion { DispatchQueue.main.async(execute: completion) }
  }
}
