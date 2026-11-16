// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVContinuity

/// One file a job asks for.
struct GameFileRequest: Sendable, Equatable {
  var url: URL
  /// Sent as they are. A background transfer keeps these for its whole life, retries included.
  var headers: [String: String]
  var expectedSize: Int64?
}

/// Fetches a game's files from a server. The files it returns belong to the caller, who moves them
/// away and then calls `release`.
protocol GameFileFetching: Sendable {
  /// What the job was started with, saved so the job can be finished after a relaunch.
  func savedPlan(for job: BackgroundDownloadJob) async -> Data?
  /// Asks for every file at once, so all of them keep going while the app is suspended, and returns
  /// them in the order asked. `progress` gets the bytes received for the whole job.
  func fetch(_ files: [GameFileRequest], for job: BackgroundDownloadJob, plan: Data?,
             progress: @escaping @Sendable (Int64) -> Void) async throws -> [URL]
  /// Forgets the job: running transfers stop, and its files and resume data are deleted.
  /// A caller that wants a failed job continued later does not call this.
  func release(_ job: BackgroundDownloadJob) async
}

/// Fetches through a `ContinuityTransport`, one file after another, in this process. This is what a
/// caller that brings its own transport (tests) gets; nothing survives a suspend.
actor TransportGameFileFetcher: GameFileFetching {
  private let transport: any ContinuityTransport
  private var folders: [String: URL] = [:]

  init(transport: any ContinuityTransport) {
    self.transport = transport
  }

  func savedPlan(for job: BackgroundDownloadJob) -> Data? { nil }

  func fetch(_ files: [GameFileRequest], for job: BackgroundDownloadJob, plan: Data?,
             progress: @escaping @Sendable (Int64) -> Void) async throws -> [URL] {
    release(job)
    let manager = FileManager.default
    let folder = manager.temporaryDirectory.appendingPathComponent("fetch-" + UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    folders[job.key] = folder
    var urls: [URL] = []
    var received: Int64 = 0
    for (index, file) in files.enumerated() {
      try Task.checkCancellation()
      let destination = folder.appendingPathComponent(String(index) + ".download")
      let before = received
      received += try await transport.download(ContinuityRequest(url: file.url, headers: file.headers),
                                               to: destination, resumeOffset: 0) { bytes, _ in
        progress(before + max(0, bytes))
      }
      try Task.checkCancellation()
      urls.append(destination)
    }
    return urls
  }

  func release(_ job: BackgroundDownloadJob) {
    if let folder = folders.removeValue(forKey: job.key) { try? FileManager.default.removeItem(at: folder) }
  }
}
