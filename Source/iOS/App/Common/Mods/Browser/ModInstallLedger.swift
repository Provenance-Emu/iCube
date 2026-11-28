// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What the mod browser remembers about one GameBanana file across launches.
struct ModInstallRecord: Codable, Hashable, Identifiable {
  enum Stage: String, Codable {
    /// A transfer was started and has not been seen to end.
    case downloading
    /// Downloaded and unpacked; nothing installed from it yet.
    case downloaded
    case installed
  }

  var fileID: Int
  var fileName: String
  var fileSize: Int64
  var downloadURL: URL?
  var md5: String?
  var modName: String
  /// The catalogue game (`ModGameTable.Entry.bananaID`) the file was found under.
  var bananaGameID: Int?
  /// The folder in the downloads directory that holds the download, while it is kept.
  var workFolder: String?
  var stage: Stage
  /// One line per thing installed from the file, as shown to the user at the time.
  var installed: [String] = []
  var updatedAt: Date

  var id: Int { fileID }

  /// The file as the browser's screens take it, for reopening it without the catalogue.
  var file: GameBananaFile {
    GameBananaFile(id: fileID, fileName: fileName, size: fileSize, downloadURL: downloadURL, md5: md5)
  }
}

/// The browser's memory, one JSON file. Safe from any thread.
final class ModInstallLedger: @unchecked Sendable {
  static let shared = ModInstallLedger(fileURL: defaultFileURL)

  /// Posted on the main queue after any change.
  static let didChangeNotification = Notification.Name("iCube.modInstallLedgerDidChange")

  /// Beside the downloads folder, not in it: the weekly sweep of stale downloads must not take it.
  static var defaultFileURL: URL {
    ModDownloadManager.downloadsDirectory.deletingLastPathComponent().appendingPathComponent("ModInstalls.json")
  }

  private struct Document: Codable {
    var version = 1
    var records: [ModInstallRecord]
  }

  private let fileURL: URL
  private let now: @Sendable () -> Date
  private let lock = NSLock()
  private var loaded: [Int: ModInstallRecord]?

  init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
    self.fileURL = fileURL
    self.now = now
  }

  /// Every record, most recently touched first.
  var records: [ModInstallRecord] {
    lock.withLock { load().values.sorted { ($0.updatedAt, $0.fileID) > ($1.updatedAt, $1.fileID) } }
  }

  func record(forFileID id: Int) -> ModInstallRecord? {
    lock.withLock { load()[id] }
  }

  /// Stores `record`, stamped with the current time.
  func save(_ record: ModInstallRecord) {
    var record = record
    record.updatedAt = now()
    lock.withLock {
      var all = load()
      all[record.fileID] = record
      store(all)
    }
    announce()
  }

  /// Changes the record of `id` in place. Does nothing when there is none.
  func update(fileID id: Int, _ change: (inout ModInstallRecord) -> Void) {
    guard var record = record(forFileID: id) else { return }
    change(&record)
    save(record)
  }

  func remove(fileID id: Int) {
    lock.withLock {
      var all = load()
      guard all.removeValue(forKey: id) != nil else { return }
      store(all)
    }
    announce()
  }

  private func load() -> [Int: ModInstallRecord] {
    if let loaded { return loaded }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let document = (try? Data(contentsOf: fileURL)).flatMap { try? decoder.decode(Document.self, from: $0) }
    let records = Dictionary((document?.records ?? []).map { ($0.fileID, $0) }, uniquingKeysWith: { first, _ in first })
    loaded = records
    return records
  }

  private func store(_ records: [Int: ModInstallRecord]) {
    loaded = records
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(Document(records: records.values.sorted { $0.fileID < $1.fileID })) else { return }
    try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: fileURL, options: .atomic)
  }

  private func announce() {
    DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChangeNotification, object: self) }
  }
}
