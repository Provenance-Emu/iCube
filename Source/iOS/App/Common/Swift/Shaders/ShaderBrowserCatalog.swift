// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One preset as the shader browser lists it. `path` is the stored form (`ShaderLibrary.normalizedPath`).
struct ShaderBrowserEntry: Identifiable, Equatable {
  let path: String
  let name: String
  /// The library folder the preset sits in (`crt`, `anti-aliasing`), `ShaderBrowserCatalog.userCategory`
  /// for one the player added, or "" for a preset at the top of the bundled library.
  let category: String

  var id: String { path }
  var looks: Set<ShaderLook> { ShaderLook.looks(path: path, category: category) }
}

/// Broad visual families that narrow the browser, independent of folders. The cases, titles and rules
/// are Provenance's (`PVShaders` `ShaderLook`), so the three apps filter the same library the same way.
enum ShaderLook: String, CaseIterable, Identifiable {
  case crt, lcd, handheld, ntsc, vhs, bezel, pixelArt, smoothing, effects

  var id: String { rawValue }

  var title: String {
    switch self {
    case .crt: return "CRT"
    case .lcd: return "LCD"
    case .handheld: return L("Handheld")
    case .ntsc: return "NTSC / PAL"
    case .vhs: return "VHS"
    case .bezel: return L("Bezels")
    case .pixelArt: return L("Pixel Art")
    case .smoothing: return L("Smoothing")
    case .effects: return L("Effects")
    }
  }

  private static let smoothingCategories: Set<String> = ["interpolation", "anti-aliasing", "blurs", "sharpen", "denoisers", "deblur", "linear"]
  private static let effectCategories: Set<String> = ["misc", "reshade", "film", "cel", "dithering", "warp"]
  private static let pixelArtCategories: Set<String> = ["pixel-art-scaling", "edge-smoothing"]

  static func looks(path: String, category: String) -> Set<ShaderLook> {
    let hay = path.lowercased()
    var looks: Set<ShaderLook> = []
    func has(_ needles: String...) -> Bool { needles.contains { hay.contains($0) } }
    if has("crt", "pvm", "bvm", "scanline", "trinitron", "lottes", "royale", "geom") { looks.insert(.crt) }
    if has("lcd", "dot", "gameboy", "gbc", "gba", "palm") { looks.insert(.lcd) }
    if category == "handheld" || has("handheld", "gameboy", "gbc", "gba", "dmg", "psp", "nds") { looks.insert(.handheld) }
    if has("ntsc", "pal/", "composite", "blargg") { looks.insert(.ntsc) }
    if has("vhs") { looks.insert(.vhs) }
    if has("bezel", "border") { looks.insert(.bezel) }
    if pixelArtCategories.contains(category) || has("xbr", "scalefx", "hqx", "sabr", "pixel") { looks.insert(.pixelArt) }
    if smoothingCategories.contains(category) { looks.insert(.smoothing) }
    if effectCategories.contains(category) { looks.insert(.effects) }
    return looks
  }
}

/// One titled group of the browser.
struct ShaderBrowserSection: Identifiable, Equatable {
  /// `favorites`, `recent` or `category:<folder>`; also the prefix of its cards' focus ids.
  let id: String
  let title: String
  let entries: [ShaderBrowserEntry]
}

/// The shader browser's list: every preset with its category, searchable and grouped. Pure, so the
/// grouping, the search and the category names are unit-tested without a bundle.
struct ShaderBrowserCatalog: Equatable {
  /// Folder of the bundled library inside the app (`Project/Assets/compiled_shaders`).
  static let bundledFolder = "compiled_shaders"
  /// Folder of the player's own presets under the user folder.
  static let userFolder = "Shaders"
  static let userCategory = "user"
  static let favoritesSectionID = "favorites"
  static let recentSectionID = "recent"
  static let categorySectionPrefix = "category:"

  let entries: [ShaderBrowserEntry]

  /// `paths` are stored-form preset paths with their display names, as discovery returns them.
  init(presets: [(path: String, name: String)]) {
    entries = presets.map { ShaderBrowserEntry(path: $0.path, name: $0.name, category: Self.category(forPath: $0.path)) }
  }

  func entry(path: String) -> ShaderBrowserEntry? { entries.first { $0.path == path } }

  /// The top folder under the bundled library, or `userCategory` for anything outside it.
  static func category(forPath path: String) -> String {
    let parts = path.split(separator: "/").map(String.init)
    guard let library = parts.lastIndex(of: bundledFolder) else { return userCategory }
    let inside = parts[(library + 1)...]
    return inside.count > 1 ? inside[inside.startIndex] : ""
  }

  static func categoryTitle(_ category: String) -> String {
    switch category {
    case userCategory: return L("My Shaders")
    case "": return L("Basic")
    case "crt": return "CRT"
    case "ntsc": return "NTSC"
    case "pal": return "PAL"
    case "vhs": return "VHS"
    case "gpu": return "GPU"
    case "hdr": return "HDR"
    case "subframe-bfi": return "Subframe BFI"
    case "nes_raw_palette": return "NES Raw Palette"
    case "stereoscopic-3d": return "Stereoscopic 3D"
    default:
      return category.split(whereSeparator: { $0 == "-" || $0 == "_" })
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
    }
  }

  /// Categories in display order: the player's own, the basics, then the library folders by title.
  var categories: [String] {
    let present = Set(entries.map(\.category))
    let pinned = [Self.userCategory, ""].filter(present.contains)
    let rest = present.subtracting(pinned).sorted {
      Self.categoryTitle($0).localizedCaseInsensitiveCompare(Self.categoryTitle($1)) == .orderedAscending
    }
    return pinned + rest
  }

  /// Looks at least one preset has, in the enum's order: a chip that could never match is not offered.
  var availableLooks: [ShaderLook] {
    let present = entries.reduce(into: Set<ShaderLook>()) { $0.formUnion($1.looks) }
    return ShaderLook.allCases.filter(present.contains)
  }

  /// Entries matching every word of `query` (in the name, the category title or the path; case and
  /// diacritics ignored) and every look in `looks`.
  func search(_ query: String, looks: Set<ShaderLook> = []) -> [ShaderBrowserEntry] {
    let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
    return entries.filter { entry in
      guard looks.isSubset(of: entry.looks) else { return false }
      let hay = "\(entry.name) \(Self.categoryTitle(entry.category)) \(entry.path)"
      return terms.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
  }

  static func isFiltering(query: String, looks: Set<ShaderLook>) -> Bool {
    !looks.isEmpty || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// The browser's groups. Unfiltered: Favorites, Recently Used (most recent first, favorites left
  /// out), then every category. While a search or a look chip is active: only the categories that
  /// have a match, with the matches.
  func sections(query: String, looks: Set<ShaderLook>, favorites: Set<String>, recents: [String]) -> [ShaderBrowserSection] {
    let filtering = Self.isFiltering(query: query, looks: looks)
    let pool = filtering ? search(query, looks: looks) : entries
    let grouped = Dictionary(grouping: pool, by: \.category)
    let byCategory = categories.compactMap { category -> ShaderBrowserSection? in
      guard let found = grouped[category], !found.isEmpty else { return nil }
      return ShaderBrowserSection(id: Self.categorySectionPrefix + category, title: Self.categoryTitle(category), entries: found)
    }
    guard !filtering else { return byCategory }
    var result: [ShaderBrowserSection] = []
    let favoriteEntries = entries.filter { favorites.contains($0.path) }
    if !favoriteEntries.isEmpty {
      result.append(ShaderBrowserSection(id: Self.favoritesSectionID, title: L("Favorites"), entries: favoriteEntries))
    }
    let recentEntries = recents.filter { !favorites.contains($0) }.compactMap(entry(path:))
    if !recentEntries.isEmpty {
      result.append(ShaderBrowserSection(id: Self.recentSectionID, title: L("Recently Used"), entries: recentEntries))
    }
    return result + byCategory
  }
}

/// Which frame the browser's previews are rendered from.
enum ShaderPreviewFrame {
  /// The pause frame is this game's when it was captured for the session now running. Its age does not
  /// matter: a game paused for ten minutes still shows that frame. A frame from another session (the
  /// temp file outlives a game) is not this game's picture.
  static func isCurrent(captureSession: UInt64?, runningSession: UInt64, fileExists: Bool) -> Bool {
    guard fileExists, let captureSession else { return false }
    return captureSession == runningSession
  }
}
