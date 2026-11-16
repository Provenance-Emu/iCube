// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Which kind of server a background download came from.
enum RemoteServerKind: String, Codable, Sendable {
  case emulationServer, romm, webdav
}

/// The game a set of background downloads belongs to.
struct BackgroundDownloadJob: Codable, Hashable, Sendable {
  var kind: RemoteServerKind
  /// `EmulationServer.id`, `RomMServer.id` or the WebDAV source's id.
  var sourceID: String
  /// The catalog key, or for WebDAV the item URL, that names the game on that source.
  var gameKey: String
  var title: String

  var key: String { sourceID + "\n" + gameKey }
}

/// Why a background download did not give a usable file.
enum BackgroundDownloadFailure: String, Codable, Error, Sendable, Equatable {
  /// 401 or 403: the saved token or password no longer works.
  case accessDenied
  /// 404 or 410: the server no longer has the file.
  case unavailable
  /// The file on disk is not the size the server said it would be.
  case incomplete
  /// Any other HTTP status.
  case server
  /// The transfer ended on another host than the one it was sent to.
  case redirected
  /// The arrived file could not be kept on disk.
  case storage
  /// The connection failed. Resume data, when the server gave it, continues the transfer.
  case network
  case cancelled

  /// Whether a later request may continue this transfer instead of starting it again.
  var keepsResumeData: Bool { self == .network || self == .cancelled }

  /// Whether the job should be thrown away rather than kept for a retry.
  var isTerminal: Bool { !keepsResumeData }
}

/// The error a background fetch throws to its caller.
struct BackgroundDownloadError: LocalizedError, Equatable {
  let failure: BackgroundDownloadFailure

  var errorDescription: String? {
    switch failure {
    case .accessDenied: return L("The server denied access. Check your access token and library permissions.")
    case .unavailable: return L("The server no longer has this game.")
    case .incomplete: return L("The download did not finish. Try again.")
    case .server: return L("The server could not send this game.")
    case .redirected: return L("The server sent the download somewhere else, so it was stopped.")
    case .storage: return L("There is not enough space to keep this game.")
    case .network: return L("The connection to the server was lost. Try again to continue the download.")
    case .cancelled: return L("Cancelled.")
    }
  }
}

/// One file of a job, remembered across launches. Never holds a credential.
struct BackgroundDownloadRecord: Codable, Equatable, Identifiable, Sendable {
  enum State: Codable, Equatable, Sendable {
    case running
    /// The file is in the journal folder, size-checked, waiting for its job to claim it.
    case arrived
    case failed(BackgroundDownloadFailure)
  }

  /// Also the transfer's `taskDescription`, which is how a relaunch finds its record.
  let id: String
  let job: BackgroundDownloadJob
  /// The request URL, without a user or password.
  let url: URL
  let expectedSize: Int64?
  var state: State
  var updatedAt: Date

  /// A URL with any user and password removed, so the journal never stores a credential.
  static func storedURL(_ url: URL) -> URL {
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
          parts.user != nil || parts.password != nil else { return url }
    parts.user = nil
    parts.password = nil
    return parts.url ?? url
  }
}

/// The decisions the downloader makes, kept free of URLSession so they can be tested.
enum BackgroundDownloadPolicy {
  /// How long a finished file nobody claimed, or a failed transfer nobody retried, is kept.
  static let retention: TimeInterval = 7 * 24 * 60 * 60

  /// Judges a file URLSession has just finished writing. Nil means keep it.
  ///
  /// A background request's headers are fixed when it is created, so an expired or revoked
  /// credential shows up here as a "finished" download whose body is the server's 401 page.
  static func judgeFinishedFile(status: Int?, receivedBytes: Int64, expectedBytes: Int64?,
                                requestedURL: URL?, finalURL: URL?) -> BackgroundDownloadFailure? {
    if let requestedURL, let finalURL, !sameOrigin(requestedURL, finalURL) { return .redirected }
    switch status {
    case 200, 206: break
    case 401, 403: return .accessDenied
    case 404, 410: return .unavailable
    default: return .server
    }
    if let expectedBytes, expectedBytes != receivedBytes { return .incomplete }
    return nil
  }

  /// Judges a transfer that ended with an error.
  static func judgeError(_ error: any Error) -> BackgroundDownloadFailure {
    if error is CancellationError { return .cancelled }
    if let error = error as? URLError {
      switch error.code {
      case .cancelled: return .cancelled
      case .userAuthenticationRequired, .userCancelledAuthentication: return .accessDenied
      case .fileDoesNotExist: return .unavailable
      case .cannotCreateFile, .cannotWriteToFile, .cannotMoveFile: return .storage
      default: return .network
      }
    }
    return .network
  }

  static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.scheme?.lowercased() == rhs.scheme?.lowercased() &&
      lhs.host?.lowercased() == rhs.host?.lowercased() &&
      effectivePort(lhs) == effectivePort(rhs)
  }

  private static func effectivePort(_ url: URL) -> Int? {
    if let port = url.port { return port }
    switch url.scheme?.lowercased() {
    case "https": return 443
    case "http": return 80
    default: return nil
    }
  }

  /// What to do when a job asks for a file the journal may already know.
  enum Step: Equatable {
    /// The file already arrived: hand it over.
    case adopt
    /// A transfer is running for it: wait for that one.
    case attach
    /// Continue from the saved resume data.
    case resume
    /// Send a new request.
    case start
  }

  static func step(for record: BackgroundDownloadRecord?, hasLiveTask: Bool, arrivedFileExists: Bool,
                   resumeDataExists: Bool) -> Step {
    guard let record else { return .start }
    switch record.state {
    case .arrived:
      return arrivedFileExists ? .adopt : .start
    case .running:
      if hasLiveTask { return .attach }
      return resumeDataExists ? .resume : .start
    case .failed(let failure):
      return resumeDataExists && failure.keepsResumeData ? .resume : .start
    }
  }

  /// What a launch does with a record once it knows which transfers the system still runs.
  enum Repair: Equatable {
    case keep
    /// The transfer is gone: keep the record as failed, so a retry can continue or restart it.
    case interrupted
    case discard
  }

  static func repair(_ record: BackgroundDownloadRecord, hasLiveTask: Bool, arrivedFileExists: Bool,
                     now: Date) -> Repair {
    if hasLiveTask { return .keep }
    if now.timeIntervalSince(record.updatedAt) > retention { return .discard }
    switch record.state {
    case .running:
      // The system may still deliver this transfer's completion after the launch; a failed
      // record accepts a late file, so nothing is lost by not discarding it here.
      return .interrupted
    case .arrived:
      return arrivedFileExists ? .keep : .discard
    case .failed:
      return .keep
    }
  }

  /// Whether a launch should carry on with a job by itself. A job the user cancelled, or one that
  /// failed, waits until the user asks for the game again.
  static func resumesByItself(_ records: [BackgroundDownloadRecord]) -> Bool {
    !records.isEmpty && records.allSatisfy { $0.state == .running || $0.state == .arrived }
  }

  /// Files in the journal folder that no record owns.
  static func orphanedFiles(_ names: [String], records: [BackgroundDownloadRecord]) -> [String] {
    let owned = Set(records.map(\.id))
    return names.filter { name in
      guard name != BackgroundDownloadJournal.fileName else { return false }
      let id = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
      return !owned.contains(id)
    }
  }

  /// Bytes received for a set of files: a finished file counts in full.
  static func receivedBytes(ids: [String], records: [String: BackgroundDownloadRecord],
                            written: [String: Int64]) -> Int64 {
    ids.reduce(Int64(0)) { total, id in
      let bytes: Int64
      if records[id]?.state == .arrived {
        bytes = records[id]?.expectedSize ?? written[id] ?? 0
      } else {
        bytes = written[id] ?? 0
      }
      return total + max(0, bytes)
    }
  }
}

/// The downloader's records on disk, with each record's file and resume data beside them.
/// Safe to call from any thread.
final class BackgroundDownloadJournal: @unchecked Sendable {
  static let fileName = "journal.json"

  static let shared: BackgroundDownloadJournal = {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return BackgroundDownloadJournal(folder: support.appendingPathComponent("BackgroundDownloads", isDirectory: true))
  }()

  private struct Contents: Codable {
    var records: [BackgroundDownloadRecord] = []
    /// Whatever a job's server kind needs to finish it after a relaunch, by job key.
    var plans: [String: Data] = [:]
  }

  let folder: URL
  private let lock = NSLock()
  private var contents: Contents

  init(folder: URL) {
    self.folder = folder
    let manager = FileManager.default
    try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
    var excluded = URLResourceValues()
    excluded.isExcludedFromBackup = true
    var marked = folder
    try? marked.setResourceValues(excluded)
    let file = folder.appendingPathComponent(Self.fileName)
    contents = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Contents.self, from: $0) } ?? Contents()
  }

  var records: [BackgroundDownloadRecord] { lock.withLock { contents.records } }

  func record(id: String) -> BackgroundDownloadRecord? {
    lock.withLock { contents.records.first { $0.id == id } }
  }

  func record(job: BackgroundDownloadJob, url: URL) -> BackgroundDownloadRecord? {
    let stored = BackgroundDownloadRecord.storedURL(url)
    return lock.withLock { contents.records.first { $0.job.key == job.key && $0.url == stored } }
  }

  func records(forJob key: String) -> [BackgroundDownloadRecord] {
    lock.withLock { contents.records.filter { $0.job.key == key } }
  }

  /// Every job the journal holds, in the order it first saw them.
  var jobs: [BackgroundDownloadJob] {
    lock.withLock {
      var seen = Set<String>()
      return contents.records.map(\.job).filter { seen.insert($0.key).inserted }
    }
  }

  func save(_ record: BackgroundDownloadRecord) {
    lock.withLock {
      if let index = contents.records.firstIndex(where: { $0.id == record.id }) {
        contents.records[index] = record
      } else {
        contents.records.append(record)
      }
      write()
    }
  }

  /// Changes a record's state, if the record is still there, and returns it.
  @discardableResult
  func update(id: String, state: BackgroundDownloadRecord.State, now: Date = Date()) -> BackgroundDownloadRecord? {
    lock.withLock {
      guard let index = contents.records.firstIndex(where: { $0.id == id }) else { return nil }
      contents.records[index].state = state
      contents.records[index].updatedAt = now
      write()
      return contents.records[index]
    }
  }

  /// Removes records and their files.
  func remove(ids: Set<String>) {
    guard !ids.isEmpty else { return }
    lock.withLock {
      contents.records.removeAll { ids.contains($0.id) }
      let live = Set(contents.records.map(\.job.key))
      contents.plans = contents.plans.filter { live.contains($0.key) }
      write()
    }
    for id in ids {
      try? FileManager.default.removeItem(at: arrivedFile(id: id))
      try? FileManager.default.removeItem(at: resumeDataFile(id: id))
    }
  }

  func plan(forJob key: String) -> Data? { lock.withLock { contents.plans[key] } }

  func setPlan(_ plan: Data?, forJob key: String) {
    lock.withLock {
      contents.plans[key] = plan
      write()
    }
  }

  func arrivedFile(id: String) -> URL { folder.appendingPathComponent(id + ".download") }
  func resumeDataFile(id: String) -> URL { folder.appendingPathComponent(id + ".resume") }

  func resumeData(id: String) -> Data? { try? Data(contentsOf: resumeDataFile(id: id)) }

  func setResumeData(_ data: Data?, id: String) {
    let file = resumeDataFile(id: id)
    if let data, !data.isEmpty {
      try? data.write(to: file, options: .atomic)
    } else {
      try? FileManager.default.removeItem(at: file)
    }
  }

  /// Applies `repair` to every record and deletes files no record owns.
  func reconcile(liveTaskIDs: Set<String>, now: Date = Date()) {
    let manager = FileManager.default
    var discarded = Set<String>()
    lock.withLock {
      for index in contents.records.indices {
        let record = contents.records[index]
        let repair = BackgroundDownloadPolicy.repair(
          record, hasLiveTask: liveTaskIDs.contains(record.id),
          arrivedFileExists: manager.fileExists(atPath: arrivedFile(id: record.id).path), now: now)
        switch repair {
        case .keep: break
        case .interrupted: contents.records[index].state = .failed(.network)
        case .discard: discarded.insert(record.id)
        }
      }
      write()
    }
    remove(ids: discarded)
    let names = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in BackgroundDownloadPolicy.orphanedFiles(names, records: records) {
      try? manager.removeItem(at: folder.appendingPathComponent(name))
    }
  }

  /// Called with the lock held.
  private func write() {
    guard let data = try? JSONEncoder().encode(contents) else { return }
    try? data.write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
  }
}
