// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Where the top bar's screenshot button writes: `<User>/ScreenShots/<GameID>/<GameID>_<timestamp>.png`,
/// the same folder and base naming the core's own `Core::SaveScreenShot` uses (Core.cpp
/// GenerateScreenshotName), so the files show up next to any others in the user folder. The timestamp
/// carries milliseconds, and a name that is somehow taken gets a counter, so a second shot can never be
/// mistaken for (or overwrite) the first one's file.
enum QuickScreenshot {
  static let folderName = "ScreenShots"
  static let timestampFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
  /// How long to wait for the core's asynchronous frame dump to land before reporting a failure.
  static let captureTimeout: TimeInterval = 2.0
  private static let pollInterval: TimeInterval = 0.1
  private static let firstCollisionCounter = 2

  static func fileName(gameID: String, date: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = timestampFormat
    return "\(gameID)_\(formatter.string(from: date)).png"
  }

  /// Creates the per-game folder and returns the destination for a screenshot taken `date`.
  static func destination(gameID: String, date: Date, userDirectory: URL) -> URL? {
    let folder = userDirectory
      .appendingPathComponent(folderName, isDirectory: true)
      .appendingPathComponent(gameID, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      return nil
    }
    return uniqueURL(for: fileName(gameID: gameID, date: date), in: folder)
  }

  /// `name`, or `name` with `-2`, `-3`, ... before the extension when a file of that name already exists.
  static func uniqueURL(for fileName: String, in folder: URL) -> URL {
    let candidate = folder.appendingPathComponent(fileName)
    guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
    let stem = candidate.deletingPathExtension().lastPathComponent
    let ext = candidate.pathExtension
    var counter = firstCollisionCounter
    while true {
      let next = folder.appendingPathComponent("\(stem)-\(counter)").appendingPathExtension(ext)
      if !FileManager.default.fileExists(atPath: next.path) { return next }
      counter += 1
    }
  }

  enum Outcome: Equatable {
    case saved
    /// The core writes a frame only while presenting, so a paused game produces no file.
    case pausedNoFrame
    case failed
  }

  /// Requests a capture and waits (off the main thread's critical path) until the file is complete.
  @MainActor
  static func capture() async -> Outcome {
    guard !TVEmulationBridge.isPaused() else { return .pausedNoFrame }
    guard let gameID = SaveStateService.currentGameID,
          let userDirectory = DolphinPaths.userDirectoryURL(),
          let url = destination(gameID: gameID, date: Date(), userDirectory: userDirectory) else { return .failed }
    TVEmulationBridge.captureScreenshot(toPath: url.path)
    return await waitForCompleteFile(at: url) ? .saved : .failed
  }

  /// The PNG is encoded on a later frame, so a file is "complete" once it is non-empty and stopped growing.
  private static func waitForCompleteFile(at url: URL) async -> Bool {
    let deadline = Date().addingTimeInterval(captureTimeout)
    var lastSize: UInt64 = 0
    while Date() < deadline {
      try? await Task.sleep(nanoseconds: TopBarTiming.nanoseconds(pollInterval))
      let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
      if size > 0, size == lastSize { return true }
      lastSize = size
    }
    return false
  }
}
