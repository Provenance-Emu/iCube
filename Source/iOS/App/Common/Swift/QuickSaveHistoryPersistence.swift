// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// The caller owns serialization. Production invokes saves and Keep on SaveStateService's queue.
/// Dependencies make file failures and session transitions testable without starting a core.
struct QuickSaveHistoryPersistence {
  struct Result: Sendable {
    var snapshot: SaveStateCompletedSnapshot?
    var cleanupFailed = false
    var cancelled = false
  }
  let root: URL
  var writeSnapshot: (URL) -> SaveStateCompletedSnapshot?
  var isCurrentSession: () -> Bool
  var writeMetadata: (SaveStateMetadata, URL) -> Bool = { SaveStateMetadataStore.write($0, forStateFile: $1) }
  var removeFile: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
  private let fm = FileManager.default

  func save(gameID: String, sessionIdentifier: UInt64, gameTitle: String? = nil) -> Result {
    guard isCurrentSession() else { return Result(cancelled: true) }
    // A UUID in the basename makes the file immutable; .s01 reuses sync's numbered-state category.
    let url = root.appendingPathComponent("\(gameID).quick-\(UUID().uuidString).s01")
    guard isValidHistoryURL(url, gameID: gameID), !fm.fileExists(atPath: url.path) else { return Result() }
    guard let snapshot = writeSnapshot(url) else {
      _ = removeBundle(at: url)
      return Result(cancelled: !isCurrentSession())
    }
    guard snapshot.gameID == gameID, snapshot.sessionIdentifier == sessionIdentifier,
          URL(fileURLWithPath: snapshot.filePath).standardizedFileURL.resolvingSymlinksInPath().path == url.standardizedFileURL.resolvingSymlinksInPath().path,
          fm.fileExists(atPath: url.path), isCurrentSession() else {
      _ = removeBundle(at: url)
      return Result(cancelled: true)
    }
    let metadata = SaveStateMetadata(title: "Quick Save", gameID: gameID, gameTitle: gameTitle,
      savedAt: snapshot.savedAt, playTimeSeconds: Double(snapshot.playTimeSeconds),
      isAuto: false, isQuickSave: true, isKept: false)
    guard writeMetadata(metadata, url) else {
      _ = removeBundle(at: url)
      return Result()
    }
    // A fully committed save remains useful after its session ends. Do not rotate older saves
    // or report success into the replacement game's UI when the session changed during metadata I/O.
    guard isCurrentSession() else { return Result(cancelled: true) }
    let states = historyStates(gameID: gameID)
    var failed = false
    for candidate in QuickSaveHistoryPolicy.pruningCandidates(states: states.filter { $0.path.standardizedFileURL.path != url.standardizedFileURL.path }, limit: 9) {
      guard isCurrentSession() else { return Result(cancelled: true) }
      // Re-read the identifying metadata immediately before deletion, so a Keep is protected.
      guard candidate.standardizedFileURL.path != url.standardizedFileURL.path, let meta = validatedMetadata(at: candidate, gameID: gameID), meta.isKept != true else { continue }
      if !removeBundle(at: candidate) { failed = true }
    }
    return Result(snapshot: snapshot, cleanupFailed: failed)
  }

  func setKept(_ kept: Bool, at url: URL, gameID: String) -> Bool {
    guard isCurrentSession(), var metadata = validatedMetadata(at: url, gameID: gameID) else { return false }
    metadata.isKept = kept
    return writeMetadata(metadata, url)
  }

  func isValidHistoryURL(_ url: URL, gameID: String) -> Bool {
    guard url.isFileURL, !url.pathComponents.contains(".."),
          QuickSaveHistoryPolicy.historyGameID(for: url) == gameID,
          url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == root.standardizedFileURL.resolvingSymlinksInPath(),
          (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return false }
    return true
  }

  private func validatedMetadata(at url: URL, gameID: String) -> SaveStateMetadata? {
    guard isValidHistoryURL(url, gameID: gameID), fm.fileExists(atPath: url.path),
          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
          let metadata = SaveStateMetadataStore.read(forStateFile: url),
          metadata.gameID == gameID, metadata.isQuickSave == true, !metadata.isAuto else { return nil }
    return metadata
  }

  private func historyStates(gameID: String) -> [SaveStateInfo] {
    let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return entries.compactMap { url in
      guard let metadata = validatedMetadata(at: url, gameID: gameID) else { return nil }
      return SaveStateInfo(gameID: gameID, displayName: metadata.title, slot: nil,
        createdAt: nil, modifiedAt: metadata.savedAt, sizeBytes: nil, versionHash: nil,
        isCompatible: true, path: url, thumbnailURL: nil, isAuto: false,
        playTimeSeconds: metadata.playTimeSeconds, isQuickSave: true, isKept: metadata.isKept == true)
    }
  }

  private func removeBundle(at url: URL) -> Bool {
    // Keep identifying sidecars when removing the state itself fails, allowing a later save to retry.
    do { if fm.fileExists(atPath: url.path) { try removeFile(url) } } catch { return false }
    var success = true
    for sidecar in [url.appendingPathExtension("json"), url.appendingPathExtension("png")] {
      do { if fm.fileExists(atPath: sidecar.path) { try removeFile(sidecar) } } catch { success = false }
    }
    return success
  }
}
