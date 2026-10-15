// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One kind of installable content found in an extracted download.
enum ModPackageKind: Equatable {
  /// A Riivolution pack. `root` is the folder that holds the pack's `riivolution/` directory.
  case riivolution(root: URL)
  /// Byte patches (xdelta, bps, ips, ups, ppf) for a disc image.
  case discPatch(patches: [URL], suggestedGameID: String?)
  /// A Dolphin texture pack. `root`'s contents belong in `Load/Textures/<gameID>/`.
  case textures(gameID: String, root: URL)
  /// A Dolphin-format Gecko codes file.
  case gecko(file: URL)
  case unsupported(reason: String)
}

struct ModPackageClassification: Equatable {
  /// Everything installable in the download, most specific first. Never empty: a download with
  /// nothing installable is a single `.unsupported`.
  var kinds: [ModPackageKind]
  /// Program files (`.exe` and the like) that were found and are never run or installed.
  var skippedPrograms: [String]
}

/// Looks at an extracted download and says what it holds. Pure file-system inspection: it
/// writes nothing and runs nothing.
enum ModPackageClassifier {
  static let discImageExtensions: Set<String> = ["iso", "gcm", "rvz", "wbfs", "wia", "gcz", "ciso", "nkit"]
  static let programExtensions: Set<String> = [
    "exe", "msi", "bat", "cmd", "com", "scr", "dll", "ps1", "vbs", "sh", "command", "dmg", "pkg", "apk", "ipa", "jar",
  ]
  static let patchExtensions: Set<String> = ["xdelta", "xdelta3", "vcdiff", "bps", "ips", "ups", "ppf"]
  static let archiveExtensions: Set<String> = ["zip", "7z", "rar", "tar", "gz", "bz2", "xz", "tgz"]
  private static let textureExtensions: Set<String> = ["png", "dds"]
  private static let geckoExtensions: Set<String> = ["ini", "txt"]
  private static let ignoredNames: Set<String> = [".DS_Store", "__MACOSX", "Thumbs.db", "desktop.ini"]
  private static let maxGeckoFileBytes = 2 * 1024 * 1024
  private static let maxRiivolutionDepth = 2
  private static let looseTexturePrefix = "tex1_"

  private struct Item {
    let url: URL
    /// Path components below the extraction root.
    let components: [String]

    var name: String { components.last ?? "" }
    var ext: String { (name as NSString).pathExtension.lowercased() }
    var parent: [String] { Array(components.dropLast()) }
  }

  /// `gameID` is the id of the library game the download is for, when the user started from one:
  /// it names loose textures that carry no game folder and is offered to the disc-patch flow.
  static func classify(extractedRoot: URL, gameID: String? = nil) -> ModPackageClassification {
    let items = collectFiles(under: extractedRoot)
    let programs = items.filter { programExtensions.contains($0.ext) }.map { $0.components.joined(separator: "/") }

    if let image = items.first(where: { discImageExtensions.contains($0.ext) }) {
      let reason = String(format: L("The download contains a disc image (%@). iCube never installs game images from mods."), image.name)
      return ModPackageClassification(kinds: [.unsupported(reason: reason)], skippedPrograms: programs)
    }

    let suggested = gameID.flatMap { $0.isEmpty ? nil : $0.uppercased() }
    var kinds: [ModPackageKind] = []

    let riivolutionRoots = findRiivolutionRoots(items)
    kinds += riivolutionRoots.map { .riivolution(root: rootURL(extractedRoot, $0)) }
    var remaining = items.filter { item in !riivolutionRoots.contains { item.components.starts(with: $0) } }

    let patches = remaining.filter { patchExtensions.contains($0.ext) }
    if !patches.isEmpty {
      kinds.append(.discPatch(patches: patches.map(\.url).sorted { $0.path < $1.path }, suggestedGameID: suggested))
    }

    let (textureKinds, textureItems) = findTextures(remaining, extractedRoot: extractedRoot, fallbackGameID: suggested)
    kinds += textureKinds
    remaining.removeAll { item in textureItems.contains { item.components.starts(with: $0) } }

    kinds += remaining.filter { geckoExtensions.contains($0.ext) && isGeckoFile($0.url) }
      .sorted { $0.url.path < $1.url.path }
      .map { .gecko(file: $0.url) }

    if kinds.isEmpty {
      kinds = [.unsupported(reason: unsupportedReason(items: items, programs: programs))]
    }
    return ModPackageClassification(kinds: kinds, skippedPrograms: programs)
  }

  // MARK: - Riivolution

  /// A Riivolution pack is a `riivolution/*.xml` folder, at the top or a level or two down.
  private static func findRiivolutionRoots(_ items: [Item]) -> [[String]] {
    var roots: [[String]] = []
    for item in items where item.ext == "xml" && item.parent.last?.lowercased() == "riivolution" {
      let root = Array(item.parent.dropLast())
      if root.count <= maxRiivolutionDepth, !roots.contains(root) { roots.append(root) }
    }
    return roots.sorted { $0.joined(separator: "/") < $1.joined(separator: "/") }
  }

  // MARK: - Textures

  /// Returns the texture packs, and the path prefixes they cover so later passes skip them.
  private static func findTextures(_ items: [Item], extractedRoot: URL, fallbackGameID: String?)
    -> (kinds: [ModPackageKind], covered: [[String]]) {
    let textures = items.filter { textureExtensions.contains($0.ext) }
    if textures.isEmpty { return ([], []) }

    var markers: [[String]: String] = [:]
    for item in items where item.ext == "txt" {
      let stem = (item.name as NSString).deletingPathExtension
      if isGameID(stem) { markers[item.parent] = stem }
    }
    var directories: Set<[String]> = []
    for texture in textures where !texture.parent.isEmpty {
      for length in 1...texture.parent.count { directories.insert(Array(texture.parent.prefix(length))) }
    }
    var folders: [[String]: String] = [:]
    for directory in directories {
      if let id = gameFolderID(directory, markers: markers) { folders[directory] = id }
    }
    // The outermost game folder wins over one nested in it.
    let roots = folders.keys.filter { candidate in
      !folders.keys.contains { $0.count < candidate.count && candidate.starts(with: $0) }
    }.sorted { $0.joined(separator: "/") < $1.joined(separator: "/") }

    var kinds: [ModPackageKind] = roots.compactMap { root in
      folders[root].map { .textures(gameID: $0, root: rootURL(extractedRoot, root)) }
    }
    var covered = roots

    let loose = textures.filter { texture in
      !roots.contains { texture.components.starts(with: $0) } && texture.name.lowercased().hasPrefix(looseTexturePrefix)
    }
    if !loose.isEmpty {
      if let fallbackGameID {
        let common = commonParent(loose.map(\.parent))
        kinds.append(.textures(gameID: fallbackGameID, root: rootURL(extractedRoot, common)))
        covered.append(common)
      } else {
        kinds.append(.unsupported(reason: L("These textures have no game folder. Open the Mod Browser from the game they are for.")))
      }
    }
    return (kinds, covered)
  }

  /// The game id a folder stands for: its own name under a `Textures` folder (three-character
  /// region-free ids included), a bare six-character game id, or a `<id>.txt` marker file inside
  /// it, which Dolphin also honours.
  private static func gameFolderID(_ directory: [String], markers: [[String]: String]) -> String? {
    guard let name = directory.last else { return nil }
    let underTextures = directory.dropLast().last?.lowercased() == "textures"
    if isGameID(name) || (underTextures && isTitleCode(name)) { return name }
    return markers[directory]
  }

  private static func isTitleCode(_ text: String) -> Bool {
    (text.count == 6 || text.count == 3) && text.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
  }

  /// A full game id always has a digit (`GALE01`), which keeps words such as `README` out.
  private static func isGameID(_ text: String) -> Bool {
    text.count == 6 && isTitleCode(text) && text.contains(where: \.isNumber)
  }

  private static func commonParent(_ parents: [[String]]) -> [String] {
    guard var common = parents.first else { return [] }
    for parent in parents.dropFirst() {
      var shared: [String] = []
      for (a, b) in zip(common, parent) where a == b { shared.append(a) }
      common = shared
    }
    return common
  }

  // MARK: - Gecko

  private static func isGeckoFile(_ url: URL) -> Bool {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= maxGeckoFileBytes,
          let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return false }
    return !GeckoCodeParser.parse(text).isEmpty
  }

  // MARK: - Unsupported

  private static func unsupportedReason(items: [Item], programs: [String]) -> String {
    if let archive = items.first(where: { archiveExtensions.contains($0.ext) }) {
      return String(format: L("The download contains another archive (%@). Extract it with the Files app and import the contents."),
                    archive.name)
    }
    if items.contains(where: { $0.components.contains { $0.lowercased() == "graphicmods" } }) {
      return L("Graphics Mods are not supported yet.")
    }
    if !programs.isEmpty {
      return String(format: L("This mod is a program for another operating system (%@), which iCube never runs."), programs[0])
    }
    return L("Nothing in this download is a texture pack, Gecko code, Riivolution pack or patch that iCube can install.")
  }

  // MARK: - File walking

  private static func rootURL(_ extractedRoot: URL, _ components: [String]) -> URL {
    components.reduce(extractedRoot) { $0.appendingPathComponent($1, isDirectory: true) }
  }

  private static func collectFiles(under root: URL) -> [Item] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else { return [] }
    let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    var items: [Item] = []
    for case let url as URL in enumerator {
      let name = url.lastPathComponent
      if ignoredNames.contains(name) || name.hasPrefix("._") {
        enumerator.skipDescendants()
        continue
      }
      guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
            values.isSymbolicLink != true else { continue }
      let components = Array(url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.dropFirst(rootComponents.count))
      items.append(Item(url: url, components: components))
    }
    return items
  }
}
