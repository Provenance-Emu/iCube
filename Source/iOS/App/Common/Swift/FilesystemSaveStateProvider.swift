import Foundation
import UIKit

public protocol SaveStateProviding {
  func states(for gameID: String) async -> [SaveStateInfo]
  func statesGroupedByGame() async -> [String: [SaveStateInfo]]
  func thumbnail(for state: SaveStateInfo) async -> UIImage?
  // Actions
  func delete(state: SaveStateInfo) throws
  func rename(state: SaveStateInfo, to title: String) throws
}

public final class FilesystemSaveStateProvider: SaveStateProviding {
  private let root: URL
  private let fm = FileManager.default

  public init(root: URL? = nil) {
    if let root {
      self.root = root
    } else if let bridged = DolphinPaths.stateSavesURL() {
      self.root = bridged
    } else {
      // Last-resort fallback: use temporary directory (will likely yield no states)
      self.root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }
  }

  public func states(for gameID: String) async -> [SaveStateInfo] {
    let grouped = await statesGroupedByGame()
    return grouped[gameID] ?? []
  }

  public func statesGroupedByGame() async -> [String: [SaveStateInfo]] {
    var result: [String: [SaveStateInfo]] = [:]
    let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles])) ?? []

    for url in entries {
      // Skip directories, thumbnail PNGs, and metadata JSON sidecars.
      if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
      let ext = url.pathExtension.lowercased()
      if ext == "png" || ext == "json" { continue }

      // Sidecar metadata (title / savedAt / version), when present.
      let meta = SaveStateMetadataStore.read(forStateFile: url)

      // The dedicated resume auto-state ({GameID}.auto) is surfaced as "Continue".
      let isAuto = (ext == "auto")

      // Parse save state info; the filename is the fallback label.
      let name = url.deletingPathExtension().lastPathComponent
      let gameID = meta?.gameID ?? Self.extractGameID(from: name)
      // Dolphin slot states put the slot in the EXTENSION (GALE01.s01), not the
      // base name — so parse `ext`, falling back to the legacy name patterns.
      let slot = isAuto ? nil : (Self.extractSlot(fromExtension: ext) ?? Self.extractSlot(from: name))
      let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey, .fileSizeKey])
      let created = values?.creationDate
      let modified = meta?.savedAt ?? values?.contentModificationDate
      let size = (values?.fileSize).map { Int64($0) }

      // Thumbnail is a per-slot sibling: GALE01.s01 -> GALE01.s01.png
      let thumbURL = url.appendingPathExtension("png")
      let hasThumb = fm.fileExists(atPath: thumbURL.path)

      // Label fallback when there is no sidecar title (e.g. saves made before
      // metadata existed): "Continue" for the auto-state, "Slot N" for a numbered
      // slot, else the raw filename.
      let fallbackLabel: String
      if isAuto {
        fallbackLabel = "Continue"
      } else if let slot {
        fallbackLabel = "Slot \(slot)"
      } else {
        fallbackLabel = name
      }

      // Real compatibility: a state from a different build's save format reports false.
      let isCompatible = TVEmulationBridge.stateFileIsCompatible(atPath: url.path)

      let info = SaveStateInfo(
        gameID: gameID,
        displayName: meta?.title ?? fallbackLabel,
        slot: slot,
        createdAt: created,
        modifiedAt: modified,
        sizeBytes: size,
        versionHash: meta?.scmRevision,
        isCompatible: isCompatible,
        path: url,
        thumbnailURL: hasThumb ? thumbURL : nil,
        isAuto: isAuto
      )
      result[gameID, default: []].append(info)
    }

    // Sort each group by most recent modified first
    for (key, list) in result {
      result[key] = list.sorted { a, b in
        let ad = a.modifiedAt ?? a.createdAt ?? .distantPast
        let bd = b.modifiedAt ?? b.createdAt ?? .distantPast
        return ad > bd
      }
    }

    return result
  }

  public func thumbnail(for state: SaveStateInfo) async -> UIImage? {
    if let url = state.thumbnailURL, let data = try? Data(contentsOf: url), let img = await UIImage(data: data, scale: UIScreen.main.scale) {
      return img
    }
    return nil
  }

  public func delete(state: SaveStateInfo) throws {
    try fm.removeItem(at: state.path)
    if let thumb = state.thumbnailURL, fm.fileExists(atPath: thumb.path) {
      try? fm.removeItem(at: thumb)
    }
    SaveStateMetadataStore.delete(forStateFile: state.path)
  }

  public func rename(state: SaveStateInfo, to title: String) throws {
    // Update the existing sidecar, or synthesize one for a legacy slot that
    // predates metadata (so any save becomes labelable).
    var meta = SaveStateMetadataStore.read(forStateFile: state.path)
      ?? SaveStateMetadata(
        title: title,
        gameID: state.gameID,
        savedAt: state.modifiedAt ?? state.createdAt ?? Date(),
        scmRevision: state.versionHash
      )
    meta.title = title
    if !SaveStateMetadataStore.write(meta, forStateFile: state.path) {
      throw CocoaError(.fileWriteUnknown)
    }
  }

  // MARK: - Helpers

  private static func extractGameID(from baseName: String) -> String {
    // Heuristic: first 6 characters look like GALE01, RSBE01, etc.
    let trimmed = baseName.trimmingCharacters(in: .whitespaces)
    if trimmed.count >= 6 {
      let prefix = String(trimmed.prefix(6))
      // Basic validation: letters+digits
      if prefix.range(of: "^[A-Z0-9]{6}$", options: .regularExpression) != nil {
        return prefix
      }
    }
    return "UNKNOWN"
  }

  private static func extractSlot(fromExtension ext: String) -> Int? {
    // Dolphin slot states use the extension ".s{NN}" (State.cpp MakeStateFilename).
    guard let r = try? NSRegularExpression(pattern: "^s(\\d+)$", options: [.caseInsensitive]),
          let m = r.firstMatch(in: ext, range: NSRange(location: 0, length: ext.utf16.count)),
          m.numberOfRanges >= 2,
          let range = Range(m.range(at: 1), in: ext) else { return nil }
    return Int(ext[range])
  }

  private static func extractSlot(from baseName: String) -> Int? {
    // Common patterns: "StateSlot1", "Slot-3", "s3" etc. Try a few regexes.
    let patterns = [
      "(?i)slot[-_ ]?(\\d+)",
      "(?i)stateslot[-_ ]?(\\d+)",
      "(?i)\\bs(\\d)\\b"
    ]
    for p in patterns {
      if let r = try? NSRegularExpression(pattern: p),
         let m = r.firstMatch(in: baseName, range: NSRange(location: 0, length: baseName.utf16.count)),
         m.numberOfRanges >= 2,
         let range = Range(m.range(at: 1), in: baseName) {
        return Int(baseName[range])
      }
    }
    return nil
  }
}
