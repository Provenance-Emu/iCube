// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Which homebrew titles are installed and at which version: `installed.json` in the Homebrew
/// folder. The program file is the truth; an entry whose file is gone counts as not installed.
struct HomebrewInstalledIndex: Codable, Equatable {
  struct Entry: Codable, Equatable {
    var versionSlug: String
    var version: String
    /// Relative to the Homebrew folder, and always inside `<slug>/`.
    var programPath: String
  }

  enum State: Equatable {
    case notInstalled
    case installed
    case updateAvailable
  }

  static let fileName = "installed.json"

  var titles: [String: Entry] = [:]

  static func load(root: URL) -> HomebrewInstalledIndex {
    guard let data = try? Data(contentsOf: root.appendingPathComponent(fileName)),
          let index = try? JSONDecoder().decode(HomebrewInstalledIndex.self, from: data) else { return .init() }
    return index
  }

  func save(root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self).write(to: root.appendingPathComponent(Self.fileName), options: .atomic)
  }

  func state(of title: HomebrewTitle, root: URL) -> State {
    guard let entry = titles[title.slug], programURL(forSlug: title.slug, root: root) != nil else { return .notInstalled }
    guard let latest = title.latest else { return .installed }
    return latest.versionSlug == entry.versionSlug ? .installed : .updateAvailable
  }

  /// The installed program, or nil when it is gone or the entry points outside its own folder.
  func programURL(forSlug slug: String, root: URL) -> URL? {
    guard let entry = titles[slug], HomebrewName.isSafe(slug) else { return nil }
    let parts = entry.programPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2, parts[0] == slug, parts.allSatisfy(HomebrewName.isSafe) else { return nil }
    let url = parts.reduce(root) { $0.appendingPathComponent($1) }
    let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return nil }
    return url
  }

  /// Forgets titles whose program is gone (the user deleted the game from the library) and removes
  /// what is left of their folders. Returns the forgotten slugs. A folder with no entry is left
  /// alone, and so is every title in `keeping`: an install may be half way through replacing it.
  mutating func removeOrphans(root: URL, keeping: Set<String> = []) -> [String] {
    let orphans = titles.keys.filter { !keeping.contains($0) && programURL(forSlug: $0, root: root) == nil }.sorted()
    for slug in orphans {
      titles[slug] = nil
      if HomebrewName.isSafe(slug) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(slug, isDirectory: true))
      }
    }
    return orphans
  }
}
