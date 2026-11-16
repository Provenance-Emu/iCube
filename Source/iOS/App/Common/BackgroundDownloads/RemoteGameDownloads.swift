// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import os
import PVContinuity
import UIKit

/// One copy per server game at a time, whoever asks for it: the library screen, or a launch carrying
/// on with a download the journal still holds. A second caller for the same game joins the copy
/// already running and gets its progress, instead of starting the files again.
@MainActor
final class RemoteGameDownloads: ObservableObject {
  static let shared = RemoteGameDownloads()
  private static let log = ICubeLog.logger("RemoteDownloads")

  struct Active: Equatable {
    let entry: ContinuityLibraryEntry
    let sourceID: String
    var progress: PullProgress?
  }

  /// Copies in flight, by job key, for a screen that wants to show them.
  @Published private(set) var active: [String: Active] = [:]

  private var running: [String: Task<[URL], any Error>] = [:]
  private var listeners: [String: [UUID: @MainActor (PullProgress) -> Void]] = [:]
  private var observers: [NSObjectProtocol] = []

  private static func key(sourceID: String, entry: ContinuityLibraryEntry) -> String { sourceID + "\n" + entry.key }

  /// Whether a copy of this game is running now.
  func isCopying(_ entry: ContinuityLibraryEntry, sourceID: String) -> Bool {
    running[Self.key(sourceID: sourceID, entry: entry)] != nil
  }

  /// Copies a game, or joins the copy of it already running. Takes the transfer permit, so it never
  /// runs beside another library or nearby transfer.
  func copy(_ entry: ContinuityLibraryEntry, from catalog: any RemoteGameCatalog,
            progress: @escaping @MainActor (PullProgress) -> Void) async throws -> [URL] {
    let key = Self.key(sourceID: catalog.downloadSourceID, entry: entry)
    let token = UUID()
    listeners[key, default: [:]][token] = progress
    defer { listeners[key]?[token] = nil }
    if let task = running[key] { return try await task.value }
    return try await ContinuityTransferGate.shared.withPermit {
      // Another caller may have started this game while this one waited for the permit.
      if let task = self.running[key] { return try await task.value }
      let task = Task { @MainActor () throws -> [URL] in
        try await catalog.copy(entry) { update in
          Task { @MainActor in RemoteGameDownloads.shared.report(update, for: key) }
        }
      }
      self.running[key] = task
      self.active[key] = Active(entry: entry, sourceID: catalog.downloadSourceID, progress: nil)
      defer {
        self.running[key] = nil
        self.active[key] = nil
      }
      return try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
    }
  }

  private func report(_ progress: PullProgress, for key: String) {
    guard running[key] != nil else { return }
    active[key]?.progress = progress
    listeners[key]?.values.forEach { $0(progress) }
  }

  // MARK: - After a relaunch

  /// Watches for the moments a launch can carry on with saved downloads: once the downloader has
  /// matched its journal against the system's transfers, and whenever iCube comes to the front.
  func start() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    for name in [Notification.Name.backgroundGameDownloadsReconciled, UIApplication.didBecomeActiveNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { RemoteGameDownloads.shared.resumeSavedDownloads() }
      })
    }
  }

  /// Finishes Emulation Server games whose files were still coming, or had arrived, when iCube was
  /// suspended or ended. Waits for the front: unpacking and hashing a disc is not work for the few
  /// seconds a background wake gets. A cancelled or failed download waits for the user instead.
  ///
  /// RomM and WebDAV jobs are not carried on here: their file lists live in their own clients, so
  /// their arrived files wait in the journal and are handed over when the game is asked for again.
  func resumeSavedDownloads() {
    guard UIApplication.shared.applicationState == .active else { return }
    let downloader = BackgroundGameDownloader.shared
    Task { @MainActor in
      let configured = NearbyLibrariesModel.savedServers()
      for job in await downloader.resumableJobs() where job.kind == .emulationServer && running[job.key] == nil {
        guard let plan = EmulationServerLibrary.savedPlan(await downloader.savedPlan(for: job)),
              configured.contains(plan.server) else {
          // The server was removed, or the plan cannot be read: nothing can finish this job.
          await downloader.release(job)
          continue
        }
        let library = EmulationServerLibrary(server: plan.server, token: KeychainService.getPassword(for: plan.server.id))
        Task { @MainActor in
          do {
            let urls = try await self.copy(plan.entry, from: library) { _ in }
            TVLibraryBridge.updateLibrary(withRemotePaths: urls.map(\.path), fetchMetadata: true)
            Self.log.info("Finished \(job.title, privacy: .public) from an earlier launch")
          } catch {
            Self.log.error("Could not finish \(job.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
          }
        }
      }
    }
  }
}
