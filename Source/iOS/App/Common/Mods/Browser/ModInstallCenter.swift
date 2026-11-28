// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Combine
import Foundation

/// Keeps a mod file's install model alive while no screen shows it, so a download keeps going and
/// shows its progress again when the user comes back: after navigating away, and after closing
/// the browser. What outlasts the launch is in `ModInstallLedger`.
@MainActor
final class ModInstallCenter: ObservableObject {
  static let shared = ModInstallCenter()

  /// The browser's memory of downloads, newest first, for the "Your Downloads" list.
  @Published private(set) var records: [ModInstallRecord] = []

  private let ledger: ModInstallLedger
  private var models: [Int: ModInstallModel] = [:]
  private var subscriptions: [Int: AnyCancellable] = [:]
  /// How many screens show each file. A model is only cleaned up and dropped at zero.
  private var viewers: [Int: Int] = [:]
  private var ledgerObserver: NSObjectProtocol?

  init(ledger: ModInstallLedger = .shared) {
    self.ledger = ledger
    records = ledger.records
    ledgerObserver = NotificationCenter.default.addObserver(
      forName: ModInstallLedger.didChangeNotification, object: ledger, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.reload() }
    }
  }

  /// The model for `file`: the live one if a download or an install of it is under way, else a new
  /// one that first restores what the ledger remembers.
  func model(for file: GameBananaFile, modName: String, entry: ModGameTable.Entry?, ownedGame: ModLibraryGame?,
             handler: any ModInstallHandling, restores: Bool = true) -> ModInstallModel {
    if let model = models[file.id] { return model }
    let model = ModInstallModel(file: file, modName: modName, bananaGameID: entry?.bananaID,
                                titleCode: entry?.gameIDs.first.map { String($0.prefix(3)) },
                                ownedGame: ownedGame, handler: handler, ledger: ledger)
    models[file.id] = model
    // A row elsewhere shows this file's status, so its changes are the centre's changes.
    subscriptions[file.id] = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    if restores { Task { await model.restoreIfNeeded() } }
    return model
  }

  /// Reconnects every download the ledger still lists as under way, so "Your Downloads" shows its
  /// progress and it gets unpacked when it ends, without the user opening each file. Called when
  /// the browser opens. A transfer that did not survive is dropped from the list.
  func resumeInterruptedDownloads(ownedGame: (ModGameTable.Entry) -> ModLibraryGame?, handler: any ModInstallHandling) {
    for record in ledger.records where record.stage == .downloading && models[record.fileID] == nil {
      let entry = record.bananaGameID.flatMap { ModGameTable.bundled.entry(forBananaID: $0) }
      let model = self.model(for: record.file, modName: record.modName, entry: entry,
                             ownedGame: entry.flatMap(ownedGame), handler: handler, restores: false)
      Task {
        await model.restoreIfNeeded()
        self.dropIfUnused(model)
      }
    }
  }

  /// Where `fileID` stands, from its live model if there is one, else from the ledger.
  func status(forFileID fileID: Int) -> ModInstallModel.Status {
    if let model = models[fileID], model.status != .none { return model.status }
    guard let record = records.first(where: { $0.fileID == fileID }) else { return .none }
    switch record.stage {
    case .downloading: return .preparing
    case .downloaded: return .downloaded
    case .installed: return .installed
    }
  }

  /// A screen began showing `model`.
  func attach(_ model: ModInstallModel) {
    viewers[model.file.id, default: 0] += 1
  }

  /// A screen stopped showing `model`. Once no screen shows it, it is dropped unless it still has
  /// work or a kept download.
  func release(_ model: ModInstallModel) {
    let remaining = max(0, (viewers[model.file.id] ?? 0) - 1)
    viewers[model.file.id] = remaining == 0 ? nil : remaining
    dropIfUnused(model)
  }

  private func dropIfUnused(_ model: ModInstallModel) {
    guard viewers[model.file.id] == nil else { return }
    model.cleanUp()
    guard !model.isWorthKeeping, models[model.file.id] === model else { return }
    models[model.file.id] = nil
    subscriptions[model.file.id] = nil
  }

  /// Forgets a file altogether: its download is deleted and it leaves "Your Downloads".
  /// What it installed stays installed.
  func forget(fileID: Int) {
    var keepsFolder = false
    if let model = models[fileID] {
      guard !model.isInstalling else { return }
      // The disc-patch flow may still be reading the unpacked files: leave them for the weekly sweep.
      keepsFolder = model.holdsFilesForAnotherFlow
      // A running transfer deletes its own folder when the cancellation lands.
      model.cancel()
      model.discardDownload()
      models[fileID] = nil
      subscriptions[fileID] = nil
      viewers[fileID] = nil
    }
    if !keepsFolder, let folder = ledger.record(forFileID: fileID)?.workFolder {
      try? FileManager.default.removeItem(at: ModDownloadManager.downloadsDirectory.appendingPathComponent(folder, isDirectory: true))
    }
    ledger.remove(fileID: fileID)
  }

  private func reload() {
    records = ledger.records
  }
}
