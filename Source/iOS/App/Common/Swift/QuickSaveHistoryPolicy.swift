import Foundation

public enum QuickSaveMode: String {
  case history
  case slots
}

public enum QuickLoadTarget: Equatable {
  case manual(URL)
  case automatic(URL)
  case incompatible(URL)
  case unavailable
}

/// Selection and retention decisions only. Callers commit a new state and its metadata
/// successfully before applying pruning candidates; scanning never deletes files.
public enum QuickSaveHistoryPolicy {
  public static func loadTarget(states: [SaveStateInfo], modded: Bool) -> QuickLoadTarget {
    // A mod's explicit selected classic slot is resolved by its caller. Implicit
    // selection cannot establish whether any vanilla/manual state belongs to a mod.
    guard !modded else { return .unavailable }
    if let manual = states.filter({ !$0.isAuto }).sorted(by: newestFirst).first {
      return manual.isCompatible ? .manual(manual.path) : .incompatible(manual.path)
    }
    if let automatic = states.filter(\.isAuto).sorted(by: newestFirst).first {
      return automatic.isCompatible ? .automatic(automatic.path) : .incompatible(automatic.path)
    }
    return .unavailable
  }

  /// `isQuickSave` is set by the provider only after validating identifying metadata.
  /// Recheck the filename here so foreign/classic/automatic files cannot rotate even
  /// when a caller constructs an inconsistent SaveStateInfo.
  public static func pruningCandidates(states: [SaveStateInfo], limit: Int = 10) -> [URL] {
    let eligible = states.filter {
      $0.isQuickSave && !$0.isKept && !$0.isAuto && $0.slot == nil &&
        historyGameID(for: $0.path) == $0.gameID
    }
    return Dictionary(grouping: eligible, by: \.gameID).values.flatMap {
      $0.sorted(by: newestFirst).dropFirst(max(0, limit))
    }.sorted(by: newestFirst).map(\.path)
  }

  /// Recognize preferred sync-compatible `.s01` history and legacy `.sav` history.
  /// Other numbered extensions remain classic saves, even with a history-like name.
  static func historyGameID(for url: URL) -> String? {
    let name = url.lastPathComponent
    guard name.hasSuffix(".s01") || name.hasSuffix(".sav"),
          let separator = name.range(of: ".quick-", options: .backwards) else { return nil }
    let gameID = String(name[..<separator.lowerBound])
    let identifier = String(name[separator.upperBound...].dropLast(4))
    // The core uses executable basenames for homebrew IDs and shorter WAD IDs.
    // Preserve those names, including dots/Unicode, while requiring a safe single
    // path component. The last marker separates IDs that themselves contain it.
    guard !gameID.isEmpty, gameID != ".", gameID != "..",
          !gameID.contains("/"), !gameID.contains("\\"),
          gameID.rangeOfCharacter(from: .controlCharacters) == nil,
          identifier.count == 36, UUID(uuidString: identifier) != nil else { return nil }
    return gameID
  }

  static func newestFirst(_ lhs: SaveStateInfo, _ rhs: SaveStateInfo) -> Bool {
    let lhsDate = lhs.modifiedAt ?? lhs.createdAt ?? .distantPast
    let rhsDate = rhs.modifiedAt ?? rhs.createdAt ?? .distantPast
    if lhsDate != rhsDate { return lhsDate > rhsDate }
    return lhs.path.path < rhs.path.path
  }
}
