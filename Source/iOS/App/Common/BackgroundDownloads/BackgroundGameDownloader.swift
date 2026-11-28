// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import UIKit

extension Notification.Name {
  /// Posted once a launch has matched the journal against the transfers the system still runs.
  static let backgroundGameDownloadsReconciled = Notification.Name("iCube.backgroundGameDownloadsReconciled")
}

/// Game files from remote libraries on one background `URLSession`, so a download keeps going while
/// iCube is suspended and finishes even if iOS ends the app meanwhile.
///
/// Every transfer's `taskDescription` is its journal record's id. A relaunch recreates the session
/// with the same identifier, the system hands back the transfers still running and delivers the
/// ones that ended, and the journal says which game and server each belongs to. A finished file is
/// moved into the journal folder (staged, size-checked, renamed) before the delegate returns,
/// because the system deletes it afterwards; the job that asked for it claims it from there.
///
/// Background transfers carry the headers they were created with. Nothing here refreshes a
/// credential: a transfer whose token stopped working ends as `accessDenied`, and its resume data
/// is dropped because it would replay the same header.
final class BackgroundGameDownloader: NSObject, GameFileFetching, @unchecked Sendable {
  static let identifier = (Bundle.main.bundleIdentifier ?? "org.dolphin-emu.dolphinios") + ".game-downloads"
  static let shared = BackgroundGameDownloader(identifier: identifier, journal: .shared)
  private static let log = ICubeLog.logger("RemoteDownloads")

  private typealias Waiter = CheckedContinuation<URL, any Error>

  private struct Observer {
    let ids: [String]
    let progress: @Sendable (Int64) -> Void
  }

  private let identifier: String
  private let journal: BackgroundDownloadJournal
  private let lock = NSLock()
  private var session: URLSession?
  private var tasks: [String: URLSessionDownloadTask] = [:]
  private var written: [String: Int64] = [:]
  private var waiters: [String: [Waiter]] = [:]
  private var observers: [UUID: Observer] = [:]
  private var isReconciled = false
  private var reconcileWaiters: [CheckedContinuation<Void, Never>] = []
  private var eventsCompletion: (() -> Void)?
  /// The system finished delivering events before the app delegate asked for them.
  private var eventsDelivered = false
  /// Keeps the app running while a job moves its finished files into the library.
  private var finishing: [String: UIBackgroundTaskIdentifier] = [:]

  init(identifier: String, journal: BackgroundDownloadJournal) {
    self.identifier = identifier
    self.journal = journal
  }

  // MARK: - Session

  /// Creates the session, which also collects whatever the system kept for it. Call at launch;
  /// safe to call again.
  func activate() {
    let created: URLSession? = lock.withLock {
      guard session == nil else { return nil }
      let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
      configuration.sessionSendsLaunchEvents = true
      configuration.isDiscretionary = false
      configuration.httpShouldSetCookies = false
      configuration.httpCookieAcceptPolicy = .never
      configuration.urlCredentialStorage = nil
      configuration.urlCache = nil
      let queue = OperationQueue()
      queue.name = "iCube.game-downloads"
      queue.maxConcurrentOperationCount = 1
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
      self.session = session
      return session
    }
    created?.getAllTasks { [self] all in
      let unknown: [URLSessionTask] = lock.withLock {
        var unknown: [URLSessionTask] = []
        for task in all where task.state == .running || task.state == .suspended {
          if let id = task.taskDescription, let download = task as? URLSessionDownloadTask,
             journal.record(id: id) != nil {
            tasks[id] = download
          } else {
            unknown.append(task)
          }
        }
        journal.reconcile(liveTaskIDs: Set(tasks.keys))
        isReconciled = true
        return unknown
      }
      unknown.forEach { $0.cancel() }
      let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
        defer { reconcileWaiters.removeAll() }
        return reconcileWaiters
      }
      ready.forEach { $0.resume() }
      NotificationCenter.default.post(name: .backgroundGameDownloadsReconciled, object: self)
    }
  }

  /// The app delegate's `handleEventsForBackgroundURLSession`. Returns false for another session.
  @discardableResult
  func handleEvents(forSession identifier: String, completion: @escaping () -> Void) -> Bool {
    guard identifier == self.identifier else { return false }
    let delivered = lock.withLock {
      defer { eventsDelivered = false }
      if !eventsDelivered { eventsCompletion = completion }
      return eventsDelivered
    }
    activate()
    if delivered { DispatchQueue.main.async { completion() } }
    return true
  }

  private func reconciled() async {
    activate()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let ready = lock.withLock {
        if !isReconciled { reconcileWaiters.append(continuation) }
        return isReconciled
      }
      if ready { continuation.resume() }
    }
  }

  // MARK: - Jobs

  /// The jobs the journal holds that a launch may carry on with by itself.
  func resumableJobs() async -> [BackgroundDownloadJob] {
    await reconciled()
    return journal.jobs.filter { BackgroundDownloadPolicy.resumesByItself(journal.records(forJob: $0.key)) }
  }

  func savedPlan(for job: BackgroundDownloadJob) async -> Data? {
    await reconciled()
    return journal.plan(forJob: job.key)
  }

  func fetch(_ files: [GameFileRequest], for job: BackgroundDownloadJob, plan: Data?,
             progress: @escaping @Sendable (Int64) -> Void) async throws -> [URL] {
    await reconciled()
    do {
      try journal.prepareFolder()
    } catch {
      // Nothing that arrives could be kept: say so now, not after the whole game has come down.
      Self.log.error("No folder for downloads: \(error.localizedDescription, privacy: .public)")
      throw BackgroundDownloadError(failure: BackgroundDownloadPolicy.judgeStoreError(error))
    }
    if let plan { journal.setPlan(plan, forJob: job.key) }
    let ids = files.map { start($0, for: job) }
    let token = UUID()
    lock.withLock { observers[token] = Observer(ids: ids, progress: progress) }
    defer { _ = lock.withLock { observers.removeValue(forKey: token) } }
    report(ids)
    return try await withTaskCancellationHandler {
      var urls: [URL] = []
      for id in ids {
        // A cancel keeps its resume data, so it is reported as the downloader's own failure.
        if Task.isCancelled { throw BackgroundDownloadError(failure: .cancelled) }
        urls.append(try await wait(for: id))
      }
      return urls
    } onCancel: {
      self.cancel(ids)
    }
  }

  func storedBytes(for job: BackgroundDownloadJob) async -> Int64 {
    await reconciled()
    let records = journal.records(forJob: job.key)
    // A transfer the system kept running across a relaunch has reported nothing to this process
    // yet, so the task's own count is asked as well.
    let transferred: [String: Int64] = lock.withLock {
      var bytes: [String: Int64] = [:]
      for record in records {
        guard let task = tasks[record.id] else { continue }
        bytes[record.id] = max(written[record.id] ?? 0, task.countOfBytesReceived)
      }
      return bytes
    }
    return BackgroundDownloadPolicy.storedBytes(
      records: records, arrived: journal.arrivedSizes(forJob: job.key), transferred: transferred,
      resumable: journal.resumableBytes(forJob: job.key))
  }

  func release(_ job: BackgroundDownloadJob) async {
    let records = journal.records(forJob: job.key)
    let ids = Set(records.map(\.id))
    let (stopped, abandoned, assertion) = lock.withLock {
      let stopped = ids.compactMap { tasks.removeValue(forKey: $0) }
      let abandoned = ids.flatMap { waiters.removeValue(forKey: $0) ?? [] }
      ids.forEach { written.removeValue(forKey: $0) }
      return (stopped, abandoned, finishing.removeValue(forKey: job.key))
    }
    stopped.forEach { $0.cancel() }
    abandoned.forEach { $0.resume(throwing: BackgroundDownloadError(failure: .cancelled)) }
    journal.remove(ids: ids)
    if let assertion { await MainActor.run { UIApplication.shared.endBackgroundTask(assertion) } }
  }

  /// Starts, continues or joins the transfer for one file and returns its record's id.
  private func start(_ file: GameFileRequest, for job: BackgroundDownloadJob) -> String {
    let manager = FileManager.default
    return lock.withLock {
      var record = journal.record(job: job, url: file.url)
      if let stale = record, stale.expectedSize != file.expectedSize {
        // The server's file changed size since this record was made: what arrived is not it.
        tasks.removeValue(forKey: stale.id)?.cancel()
        journal.remove(ids: [stale.id])
        record = nil
      }
      let id = record?.id ?? UUID().uuidString
      let step = BackgroundDownloadPolicy.step(
        for: record, hasLiveTask: tasks[id] != nil,
        arrivedFileExists: manager.fileExists(atPath: journal.arrivedFile(id: id).path),
        resumeDataExists: manager.fileExists(atPath: journal.resumeDataFile(id: id).path))
      if step == .adopt || step == .attach { return id }
      guard let session else { return id }
      let task: URLSessionDownloadTask
      if step == .resume, let data = journal.resumeData(id: id) {
        // Resume data is good for one attempt; a failure that keeps going writes new data.
        journal.setResumeData(nil, id: id)
        task = session.downloadTask(withResumeData: data)
      } else {
        var request = URLRequest(url: file.url, cachePolicy: .reloadIgnoringLocalCacheData)
        file.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        task = session.downloadTask(with: request)
        written[id] = 0
      }
      task.taskDescription = id
      if let size = file.expectedSize { task.countOfBytesClientExpectsToReceive = size }
      journal.save(BackgroundDownloadRecord(id: id, job: job, url: BackgroundDownloadRecord.storedURL(file.url),
                                            expectedSize: file.expectedSize, state: .running, updatedAt: Date()))
      tasks[id] = task
      task.resume()
      return id
    }
  }

  private func wait(for id: String) async throws -> URL {
    try await withCheckedThrowingContinuation { (continuation: Waiter) in
      let outcome: Result<URL, any Error>? = lock.withLock {
        guard let record = journal.record(id: id) else {
          return .failure(BackgroundDownloadError(failure: .cancelled))
        }
        switch record.state {
        case .arrived:
          let file = journal.arrivedFile(id: id)
          if FileManager.default.fileExists(atPath: file.path) { return .success(file) }
          return .failure(BackgroundDownloadError(failure: .incomplete))
        case .failed(let failure) where tasks[id] == nil:
          return .failure(BackgroundDownloadError(failure: failure))
        default:
          waiters[id, default: []].append(continuation)
          return nil
        }
      }
      if let outcome { continuation.resume(with: outcome) }
    }
  }

  private func cancel(_ ids: [String]) {
    let running = lock.withLock { ids.compactMap { id in tasks[id].map { (id, $0) } } }
    for (id, task) in running {
      task.cancel(byProducingResumeData: { [journal] data in
        if let data, journal.record(id: id) != nil { journal.setResumeData(data, id: id) }
      })
    }
  }

  private func report(_ changed: [String]) {
    let changed = Set(changed)
    let updates: [(Observer, Int64)] = lock.withLock {
      let interested = observers.values.filter { !changed.isDisjoint(with: $0.ids) }
      guard !interested.isEmpty else { return [] }
      let records = Dictionary(journal.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      return interested.map {
        ($0, BackgroundDownloadPolicy.receivedBytes(ids: $0.ids, records: records, written: written))
      }
    }
    for (observer, bytes) in updates { observer.progress(bytes) }
  }

  /// Holds the app up after a job's files are all in, until the job releases them.
  private func beginFinishing(_ job: BackgroundDownloadJob) {
    Task { @MainActor in
      let started = lock.withLock { finishing[job.key] == nil }
      guard started else { return }
      var assertion = UIBackgroundTaskIdentifier.invalid
      assertion = UIApplication.shared.beginBackgroundTask(withName: "iCube.game-download") { [weak self] in
        guard let self else { return }
        let ending = self.lock.withLock { self.finishing.removeValue(forKey: job.key) }
        if let ending { UIApplication.shared.endBackgroundTask(ending) }
      }
      guard assertion != .invalid else { return }
      let duplicate = lock.withLock { () -> Bool in
        guard finishing[job.key] == nil else { return true }
        finishing[job.key] = assertion
        return false
      }
      if duplicate { UIApplication.shared.endBackgroundTask(assertion) }
    }
  }
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundGameDownloader: URLSessionDownloadDelegate {
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                  totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard let id = downloadTask.taskDescription else { return }
    lock.withLock { written[id] = totalBytesWritten }
    report([id])
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64,
                  expectedTotalBytes: Int64) {
    guard let id = downloadTask.taskDescription else { return }
    lock.withLock { written[id] = fileOffset }
    report([id])
  }

  /// The file at `location` is deleted when this returns, so it is judged and moved here.
  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    guard let id = downloadTask.taskDescription, let record = journal.record(id: id) else { return }
    let size = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    let response = downloadTask.response as? HTTPURLResponse
    if let failure = BackgroundDownloadPolicy.judgeFinishedFile(
      status: response?.statusCode, receivedBytes: size, expectedBytes: record.expectedSize,
      requestedURL: downloadTask.originalRequest?.url, finalURL: response?.url ?? downloadTask.currentRequest?.url) {
      journal.setResumeData(nil, id: id)
      journal.update(id: id, state: .failed(failure))
      return
    }
    let destination = journal.arrivedFile(id: id)
    do {
      try? FileManager.default.removeItem(at: destination)
      try ImportStaging.stagedMove(fromPath: location.path, toPath: destination.path)
      journal.setResumeData(nil, id: id)
      journal.update(id: id, state: .arrived)
    } catch {
      Self.log.error("Could not keep a finished download: \(error.localizedDescription, privacy: .public)")
      journal.update(id: id, state: .failed(BackgroundDownloadPolicy.judgeStoreError(error)))
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    guard let id = task.taskDescription else { return }
    let result: Result<URL, any Error>
    if let error {
      let failure = BackgroundDownloadPolicy.judgeError(error)
      if journal.record(id: id) == nil {
        // Released while it was stopping: nothing is kept for it.
      } else if failure.keepsResumeData {
        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
          journal.setResumeData(data, id: id)
        }
      } else {
        journal.setResumeData(nil, id: id)
      }
      if journal.record(id: id)?.state != .arrived { journal.update(id: id, state: .failed(failure)) }
      result = .failure(BackgroundDownloadError(failure: failure))
    } else {
      switch journal.record(id: id)?.state {
      case .arrived: result = .success(journal.arrivedFile(id: id))
      case .failed(let failure): result = .failure(BackgroundDownloadError(failure: failure))
      case .running:
        journal.update(id: id, state: .failed(.incomplete))
        result = .failure(BackgroundDownloadError(failure: .incomplete))
      case nil: result = .failure(BackgroundDownloadError(failure: .cancelled))
      }
    }
    let resumed = lock.withLock { () -> [Waiter] in
      if tasks[id] === task { tasks.removeValue(forKey: id) }
      return waiters.removeValue(forKey: id) ?? []
    }
    resumed.forEach { $0.resume(with: result) }
    report([id])
    if case .success = result, let job = journal.record(id: id)?.job, !resumed.isEmpty,
       journal.records(forJob: job.key).allSatisfy({ $0.state == .arrived }) {
      beginFinishing(job)
    }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    let completion = lock.withLock { () -> (() -> Void)? in
      defer { eventsCompletion = nil }
      // The session is made at launch, so the system can finish delivering before the app
      // delegate hands over its completion handler; `handleEvents` then calls it at once.
      eventsDelivered = eventsCompletion == nil
      return eventsCompletion
    }
    DispatchQueue.main.async { completion?() }
  }

  /// Apple documents that tasks in a background session follow redirects without asking, so this is
  /// not expected to run; `judgeFinishedFile` rejects a transfer that ended on another origin instead.
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}
