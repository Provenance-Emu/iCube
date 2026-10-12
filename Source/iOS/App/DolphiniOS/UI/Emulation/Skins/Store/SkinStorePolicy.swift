// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// The shelves the skin store shows, in display order. GameCube and Wii skins install as-is; N64
/// layouts are rewritten to the GameCube pad on install.
enum SkinStoreSection: String, CaseIterable, Sendable, Identifiable {
  case gameCube
  case wii
  case nintendo64

  var id: String { rawValue }

  /// Display order. `allCases` happens to match, but the store reads this so a reordering of the
  /// enum cannot silently reshuffle the UI.
  static let ordered: [SkinStoreSection] = [.gameCube, .wii, .nintendo64]

  /// The game type a skin from this shelf is rewritten to on install, or nil to install as-is.
  var retarget: SkinGameType? {
    switch self {
    case .gameCube, .wii: return nil
    case .nintendo64: return .gameCube
    }
  }
}

/// Decides which catalog entries the store shows, where, and how each downloads. Pure: the feed is
/// about 1,400 entries and this runs over all of them.
enum SkinStorePolicy {
  static let gameCubeCode = "gamecube"
  static let wiiCode = "wii"
  static let nintendo64Code = "n64"

  /// Leftover codes from before the feed's systems were cleaned up. They say nothing about the
  /// layout, so they never place an entry.
  static let placeholderSystemCodes: Set<String> = ["unofficial", "unsupported", "unknown"]

  /// Archives `SkinLibrary` imports by extension. `.zip` (often a folder of skins) and extensionless
  /// links (not identifiable before download) are hidden.
  static var installableExtensions: Set<String> { SkinLibrary.archiveExtensions }

  private static let unsafeFileNameCharacters = CharacterSet(charactersIn: "/:\\\n\r\t")
  private static let fallbackFileStem = "skin"

  /// The lowercased skin extension of `url`'s last path component, or nil when it is not importable.
  static func installableExtension(for url: URL) -> String? {
    let ext = url.pathExtension.lowercased()
    return installableExtensions.contains(ext) ? ext : nil
  }

  /// The system codes an entry claims: its `systems` minus placeholders, plus the code its game type
  /// identifier implies (the one `gamecube` entry has `systems` *and* `public.aoshuang.game.ngc`;
  /// an entry could carry only the latter).
  static func systemCodes(for entry: SkinCatalogEntry) -> Set<String> {
    var codes = Set(entry.normalizedSystems).subtracting(placeholderSystemCodes)
    if let suffix = entry.gameTypeSuffix {
      switch SkinGameType(identifier: suffix) {
      case .gameCube?: codes.insert(gameCubeCode)
      case .wii?: codes.insert(wiiCode)
      case nil: if suffix == nintendo64Code { codes.insert(nintendo64Code) }
      }
    }
    return codes
  }

  /// The shelf for `entry`, or nil when the store hides it. When an entry lists several systems
  /// the strongest claim wins: GameCube, then Wii, then N64.
  static func section(for entry: SkinCatalogEntry) -> SkinStoreSection? {
    guard installableExtension(for: entry.downloadURL) != nil else { return nil }
    let codes = systemCodes(for: entry)
    if codes.contains(gameCubeCode) { return .gameCube }
    if codes.contains(wiiCode) { return .wii }
    if codes.contains(nintendo64Code) { return .nintendo64 }
    return nil
  }

  /// Visible entries grouped by shelf, shelves in display order, empty shelves omitted. Entries keep
  /// feed order within a shelf.
  static func sections(for entries: [SkinCatalogEntry]) -> [(section: SkinStoreSection, entries: [SkinCatalogEntry])] {
    var grouped: [SkinStoreSection: [SkinCatalogEntry]] = [:]
    for entry in entries {
      guard let section = section(for: entry) else { continue }
      grouped[section, default: []].append(entry)
    }
    return SkinStoreSection.ordered.compactMap { section in
      guard let list = grouped[section], !list.isEmpty else { return nil }
      return (section, list)
    }
  }

  /// Local file name for a download: `<entry id>.<deltaskin|manicskin>`. The library keys off the
  /// extension, and many feed URLs end in a name that is unsafe or ambiguous as a path component.
  static func downloadFileName(for entry: SkinCatalogEntry) -> String? {
    guard let ext = installableExtension(for: entry.downloadURL) else { return nil }
    let stem = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: unsafeFileNameCharacters).filter { !$0.isEmpty }.joined(separator: "-")
    return "\(stem.isEmpty ? fallbackFileStem : stem).\(ext)"
  }
}
#endif
