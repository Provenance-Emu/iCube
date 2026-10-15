// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The game's user Gecko codes. Abstracted so the merge rules can be tested without the core.
protocol GeckoCodeStoring {
  func codeNames(gameID: String, revision: Int) -> [String]
  func add(_ code: GeckoCodeEntry, gameID: String, revision: Int) -> Bool
  func enable(codeNamed name: String, gameID: String, revision: Int)
}

/// The two kinds of mod content the browser installs by itself.
enum ModContentInstaller {
  struct TextureResult: Equatable {
    let filesCopied: Int
    let destination: URL
  }

  struct GeckoResult: Equatable {
    var added: [String] = []
    var alreadyPresent: [String] = []
    var rejected: [String] = []
  }

  enum InstallError: LocalizedError {
    case emptyTexturePack
    case geckoNeedsLibraryGame
    case noGeckoCodes

    var errorDescription: String? {
      switch self {
      case .emptyTexturePack: return L("The texture pack has no images to install.")
      case .geckoNeedsLibraryGame: return L("Add the game to your library first; Gecko codes are stored per game.")
      case .noGeckoCodes: return L("The file has no Gecko codes in Dolphin's format.")
      }
    }
  }

  private static let junkNames: Set<String> = [".DS_Store", "Thumbs.db", "desktop.ini"]
  private static let textureExtensions: Set<String> = ["png", "dds"]

  // MARK: - Textures

  /// Copies the textures under `root` into `<texturesRoot>/<gameID>/`, keeping the folder layout and
  /// overwriting same-named files (a pack update). Only images and Dolphin's `<id>.txt` / `all.txt`
  /// markers are copied: anything else in the archive (programs, patches, readmes) stays behind.
  /// Links and macOS resource-fork leftovers are skipped.
  static func installTextures(from root: URL, gameID: String, texturesRoot: URL) throws -> TextureResult {
    guard isSafeFolderName(gameID) else { throw CocoaError(.fileWriteInvalidFileName) }
    let fm = FileManager.default
    let destination = texturesRoot.appendingPathComponent(gameID, isDirectory: true)
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let sourceComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
      throw InstallError.emptyTexturePack
    }
    var copied = 0
    for case let url as URL in enumerator {
      let name = url.lastPathComponent
      if junkNames.contains(name) || name.hasPrefix("._") || name == "__MACOSX" {
        enumerator.skipDescendants()
        continue
      }
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            values.isRegularFile == true, values.isSymbolicLink != true, isTextureFile(url) else { continue }
      let relative = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.dropFirst(sourceComponents.count)
      let target = relative.reduce(destination) { $0.appendingPathComponent($1) }
      try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? fm.removeItem(at: target)
      try fm.copyItem(at: url, to: target)
      copied += 1
    }
    guard copied > 0 else { throw InstallError.emptyTexturePack }
    return TextureResult(filesCopied: copied, destination: destination)
  }

  private static func isTextureFile(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    if textureExtensions.contains(ext) { return true }
    let stem = url.deletingPathExtension().lastPathComponent
    return ext == "txt" && (stem == "all" || ((stem.count == 3 || stem.count == 6)
        && stem.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }))
  }

  /// `Load/Textures` in the user directory, from Dolphin's own path table.
  static func bridgedTexturesRoot() -> URL? {
    guard let path = DolphinGetHiresTexturesPathC().map({ String(cString: $0) }), !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  private static func isSafeFolderName(_ name: String) -> Bool {
    !name.isEmpty && !name.contains("/") && !name.contains("\\") && name != "." && name != ".."
  }

  // MARK: - Gecko

  /// Adds the codes in `text` to the game, skipping any whose name the game already has, and turns
  /// the added ones on: installing a code is asking for it.
  static func installGecko(text: String, gameID: String, revision: Int, store: some GeckoCodeStoring) throws -> GeckoResult {
    let codes = GeckoCodeParser.parse(text)
    guard !codes.isEmpty else { throw InstallError.noGeckoCodes }
    var existing = Set(store.codeNames(gameID: gameID, revision: revision))
    var result = GeckoResult()
    for code in codes {
      if existing.contains(code.name) {
        result.alreadyPresent.append(code.name)
      } else if store.add(code, gameID: gameID, revision: revision) {
        existing.insert(code.name)
        store.enable(codeNamed: code.name, gameID: gameID, revision: revision)
        result.added.append(code.name)
      } else {
        result.rejected.append(code.name)
      }
    }
    return result
  }

  /// Reads a codes file as UTF-8, or Latin-1 for the older files that are not.
  static func geckoText(of file: URL) throws -> String {
    let data = try Data(contentsOf: file)
    guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
      throw InstallError.noGeckoCodes
    }
    return text
  }
}

/// The game's Gecko codes as the core stores them.
struct CoreGeckoStore: GeckoCodeStoring {
  func codeNames(gameID: String, revision: Int) -> [String] {
    TVCheatsBridge.geckoCodes(forGameId: gameID, revision: revision).map(\.name)
  }

  func add(_ code: GeckoCodeEntry, gameID: String, revision: Int) -> Bool {
    TVCheatsBridge.addGeckoCode(forGameId: gameID, revision: revision, name: code.name, creator: code.creator,
                                codeText: code.codeText, notesText: code.notesText)
  }

  func enable(codeNamed name: String, gameID: String, revision: Int) {
    let codes = TVCheatsBridge.geckoCodes(forGameId: gameID, revision: revision)
    guard let index = codes.lastIndex(where: { $0.name == name }) else { return }
    TVCheatsBridge.setGeckoCodeEnabled(true, at: index, forGameId: gameID, revision: revision)
  }
}
