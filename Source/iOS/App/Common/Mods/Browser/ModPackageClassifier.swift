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
  /// Replacement game files with no Riivolution XML of their own. iCube writes the XML.
  case gameFiles(ModGameFilePack)
  case unsupported(reason: String)
}

/// Loose replacement files for a game disc, grouped the way they become Riivolution options.
struct ModGameFilePack: Equatable {
  enum Mapping: Equatable {
    /// Each file replaces the disc file of the same name, wherever that is on the disc.
    case byName
    /// `directory` mirrors the disc's file tree (an extracted disc's `files` folder).
    case discTree
    /// One `.dol` that replaces the game's main program.
    case mainExecutable
  }

  struct Group: Equatable {
    /// The folder's path inside the download; empty for files at the top.
    var name: String
    var directory: URL
    /// Paths below `directory`: plain names except for `.discTree`.
    var files: [String]
    var mapping: Mapping
  }

  var groups: [Group]

  var fileCount: Int { groups.reduce(0) { $0 + $1.files.count } }

  /// The pack without the files that replace nothing: a file matched by name needs a disc file
  /// of that name. `discFileNames` are lower-cased. Returns the names left out as well.
  func keeping(discFileNames: Set<String>) -> (pack: ModGameFilePack, leftOut: [String]) {
    var kept: [Group] = []
    var leftOut: [String] = []
    for var group in groups {
      if group.mapping == .byName {
        leftOut += group.files.filter { !discFileNames.contains($0.lowercased()) }
        group.files.removeAll { !discFileNames.contains($0.lowercased()) }
      }
      if !group.files.isEmpty { kept.append(group) }
    }
    return (ModGameFilePack(groups: kept), leftOut)
  }
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
  /// Formats a GameCube or Wii game keeps on its disc. A file with one of these and no Riivolution
  /// XML is taken for a replacement of the disc file of the same name.
  static let gameFileExtensions: Set<String> = [
    "arc", "szs", "carc", "rarc", "u8", "szp", "cmp", "lz", "bin", "dat", "usd", "rel", "str", "rso", "sel",
    "brres", "brsar", "brstm", "brwsd", "brbnk", "brseq", "breff", "breft", "brlyt", "brlan", "brctr", "brfnt", "brfna",
    "tpl", "bti", "bmd", "bdl", "bck", "bca", "btk", "btp", "brk", "bpk", "bmg", "blo", "bls", "bcsv", "jmp",
    "thp", "ast", "adp", "hps", "dsp", "aw", "baa", "bsft", "bstn", "bms", "aaf", "afc", "h4m", "mth", "sfd",
    "pac", "pcs", "kmp", "kcl", "krm", "col", "ymp", "ral", "prm", "mot", "sawnd",
  ]
  /// Disc files that are themselves archives. A folder named like one (`MRAM.arc/…`) holds files
  /// for inside that archive, which only a PC tool can put there.
  private static let containerExtensions: Set<String> = ["arc", "szs", "carc", "rarc", "u8"]
  private static let saveExtensions: Set<String> = ["gci", "gcs", "sav"]
  /// A Wii save as exported by the console or Dolphin, and the files inside an unpacked one.
  private static let saveFileNames: Set<String> = ["data.bin", "banner.bin", "gamedata.bin"]
  private static let noteExtensions: Set<String> = ["txt", "md", "rtf", "pdf", "url", "html", "htm", "nfo", "doc", "docx", ""]
  private static let executableExtension = "dol"
  private static let discTreeFolderName = "files"
  private static let maxDiscTreeDepth = 2
  private static let maxListedExtensions = 4
  private static let textureExtensions: Set<String> = ["png", "dds"]
  private static let geckoExtensions: Set<String> = ["ini", "txt"]
  private static let ignoredNames: Set<String> = [".DS_Store", "__MACOSX", "Thumbs.db", "desktop.ini"]
  private static let maxGeckoFileBytes = 2 * 1024 * 1024
  private static let maxRiivolutionDepth = 2
  private static let riivolutionFolderName = "riivolution"
  private static let riivolutionProbeBytes = 4096
  private static let looseTexturePrefix = "tex1_"
  private static let texturesFolderName = "textures"

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

    let geckoFiles = remaining.filter { geckoExtensions.contains($0.ext) && isGeckoFile($0.url) }
      .sorted { $0.url.path < $1.url.path }
    kinds += geckoFiles.map { .gecko(file: $0.url) }
    remaining.removeAll { item in geckoFiles.contains { $0.components == item.components } }

    kinds += findGameFiles(remaining, extractedRoot: extractedRoot)

    if kinds.isEmpty {
      kinds = [.unsupported(reason: unsupportedReason(items: items, programs: programs))]
    }
    return ModPackageClassification(kinds: kinds, skippedPrograms: programs)
  }

  // MARK: - Riivolution

  /// A Riivolution pack is a `riivolution/*.xml` folder, at the top or a level or two down. Some
  /// authors leave the XML beside the pack's folder instead; `gatherLooseRiivolutionXMLs` files
  /// those where Dolphin looks before the pack is installed.
  private static func findRiivolutionRoots(_ items: [Item]) -> [[String]] {
    var roots: [[String]] = []
    for item in items where item.ext == "xml" && item.parent.last?.lowercased() == riivolutionFolderName {
      let root = Array(item.parent.dropLast())
      if root.count <= maxRiivolutionDepth, !roots.contains(root) { roots.append(root) }
    }
    for item in items where item.ext == "xml" && item.parent.count <= maxRiivolutionDepth && isRiivolutionXML(item.url) {
      let coveredByAPack = roots.contains { item.components.starts(with: $0) }
      if !coveredByAPack, !roots.contains(item.parent) { roots.append(item.parent) }
    }
    return roots.sorted { $0.joined(separator: "/") < $1.joined(separator: "/") }
  }

  private static func isRiivolutionXML(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    let head = (try? handle.read(upToCount: riivolutionProbeBytes)) ?? Data()
    // Latin-1 reads any bytes, so an XML in an odd encoding is still searched.
    return (String(data: head, encoding: .isoLatin1) ?? "").lowercased().contains("<wiidisc")
  }

  /// Moves Riivolution XMLs that sit directly in `root` into `root/riivolution/`, the one place
  /// Dolphin and the pack installer look. Does nothing when `root` already has that folder.
  static func gatherLooseRiivolutionXMLs(in root: URL) throws {
    let fm = FileManager.default
    let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    if entries.contains(where: { $0.lastPathComponent.lowercased() == riivolutionFolderName }) { return }
    let xmls = entries.filter { url in
      url.pathExtension.lowercased() == "xml" && !url.lastPathComponent.hasPrefix("._")
        && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true && isRiivolutionXML(url)
    }
    guard !xmls.isEmpty else { return }
    let folder = root.appendingPathComponent(riivolutionFolderName, isDirectory: true)
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    for xml in xmls { try fm.moveItem(at: xml, to: folder.appendingPathComponent(xml.lastPathComponent)) }
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
    // A folder right under `Textures` is the pack, whatever the folders above it are called
    // (`SMNP01/Load/Textures/SMN/`). Otherwise the outermost game folder wins over one nested in it.
    let anchored = folders.keys.filter { $0.dropLast().last?.lowercased() == texturesFolderName }
    let candidates = folders.keys.filter { candidate in
      !anchored.contains { $0.count > candidate.count && $0.starts(with: candidate) }
    }
    let roots = candidates.filter { candidate in
      !candidates.contains { $0.count < candidate.count && candidate.starts(with: $0) }
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
    let underTextures = directory.dropLast().last?.lowercased() == texturesFolderName
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

  // MARK: - Game files

  /// Loose disc files, a `files` tree and replacement programs, plus the reasons for what looks
  /// like game data and still cannot be installed (saves, files for inside a disc archive).
  private static func findGameFiles(_ items: [Item], extractedRoot: URL) -> [ModPackageKind] {
    var kinds: [ModPackageKind] = []
    var remaining = items

    func container(of item: Item) -> String? {
      item.parent.first { containerExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }
    let nested = remaining.filter { container(of: $0) != nil }
    if !nested.isEmpty {
      let containers = Set(nested.compactMap(container(of:))).sorted().prefix(maxListedExtensions).joined(separator: ", ")
      kinds.append(.unsupported(reason: String(
        format: L("%d files here go inside the game's own archives (%@). That needs a PC tool to rebuild them; iCube can only replace whole disc files."),
        nested.count, containers)))
      remaining.removeAll { container(of: $0) != nil }
    }

    var groups: [ModGameFilePack.Group] = []
    var treeRoots: [[String]] = []
    for item in remaining {
      guard let index = item.parent.firstIndex(where: { $0.lowercased() == discTreeFolderName }), index <= maxDiscTreeDepth else { continue }
      let root = Array(item.components.prefix(index + 1))
      if !treeRoots.contains(root) { treeRoots.append(root) }
    }
    for root in treeRoots.sorted(by: { $0.joined(separator: "/") < $1.joined(separator: "/") }) {
      let files = remaining.filter { $0.components.starts(with: root) }
        .map { $0.components.dropFirst(root.count).joined(separator: "/") }.sorted()
      if !files.isEmpty {
        groups.append(.init(name: root.dropLast().joined(separator: "/"), directory: rootURL(extractedRoot, root), files: files, mapping: .discTree))
      }
      remaining.removeAll { $0.components.starts(with: root) }
    }

    // Checked after the disc trees are taken out: a game's own tree may hold a `data.bin`.
    if let save = remaining.first(where: { saveExtensions.contains($0.ext) || saveFileNames.contains($0.name.lowercased()) }) {
      kinds.append(.unsupported(reason: String(
        format: L("This is a save file (%@), not a mod. iCube cannot import saves from the Mod Browser yet."), save.name)))
      remaining = []
    }

    let loose = Dictionary(grouping: remaining.filter { gameFileExtensions.contains($0.ext) }, by: \.parent)
    for parent in loose.keys.sorted(by: { $0.joined(separator: "/") < $1.joined(separator: "/") }) {
      groups.append(.init(name: parent.joined(separator: "/"), directory: rootURL(extractedRoot, parent),
                          files: (loose[parent] ?? []).map(\.name).sorted(), mapping: .byName))
    }
    for program in remaining.filter({ $0.ext == executableExtension }).sorted(by: { $0.url.path < $1.url.path }) {
      groups.append(.init(name: program.parent.joined(separator: "/"), directory: rootURL(extractedRoot, program.parent),
                          files: [program.name], mapping: .mainExecutable))
    }
    if !groups.isEmpty { kinds.insert(.gameFiles(ModGameFilePack(groups: groups)), at: 0) }
    return kinds
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
    if !items.isEmpty, items.allSatisfy({ noteExtensions.contains($0.ext) }) {
      return String(format: L("This download only holds a note (%@). The mod itself is hosted somewhere else: see its page on GameBanana."),
                    items[0].name)
    }
    if items.isEmpty { return L("The download is empty.") }
    // Say what is there, so "can't install" is never a dead end.
    let counts = Dictionary(grouping: items, by: { $0.ext.isEmpty ? L("no extension") : "." + $0.ext }).mapValues(\.count)
    let listed = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(maxListedExtensions)
      .map { "\($0.value) × \($0.key)" }.joined(separator: ", ")
    return String(format: L("Nothing here is a texture pack, Gecko code, Riivolution pack, patch or game file that iCube can install. The download holds: %@."),
                  listed)
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
