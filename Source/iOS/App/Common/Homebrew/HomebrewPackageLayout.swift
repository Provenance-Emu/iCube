// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Finds the program inside an unpacked Dolphin Depot package. Packages are laid out like an SD
/// card for a real console: usually `apps/<name>/default.dol`, sometimes with data beside it.
enum HomebrewPackageLayout {
  private static let programExtensions: Set<String> = ["dol", "elf"]
  private static let preferredNames = ["default.dol", "boot.dol"]

  /// The program to start, or nil when the package has none. Only regular files count.
  static func program(in root: URL) -> URL? {
    let base = root.resolvingSymlinksInPath()
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
    guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: keys) else { return nil }
    var programs: [(path: [String], url: URL)] = []
    for case let url as URL in walker {
      guard programExtensions.contains(url.pathExtension.lowercased()),
            let values = try? url.resourceValues(forKeys: Set(keys)),
            values.isRegularFile == true, values.isSymbolicLink != true else { continue }
      let path = Array(url.pathComponents.dropFirst(base.pathComponents.count))
      if !path.isEmpty { programs.append((path, url)) }
    }
    programs.sort { $0.path.joined(separator: "/") < $1.path.joined(separator: "/") }
    if programs.count <= 1 { return programs.first?.url }
    for name in preferredNames {
      if let match = programs.first(where: {
        $0.path.count == 3 && $0.path[0].lowercased() == "apps" && $0.path[2].lowercased() == name
      }) {
        return match.url
      }
    }
    return programs.first?.url
  }

  /// Renames the program to `<slug>.<extension>` where it is and returns the new URL.
  ///
  /// The emulator names a `.dol` or `.elf` after its file: `default.dol` is game `ID-default`, and
  /// that ID keys per-game settings and save states. Nearly every package calls its program
  /// `default.dol`, so without this they would all share one set.
  static func rename(_ program: URL, slug: String) throws -> URL {
    guard HomebrewName.isSafe(slug) else { throw CocoaError(.fileWriteInvalidFileName) }
    let destination = program.deletingLastPathComponent()
      .appendingPathComponent(slug + "." + program.pathExtension.lowercased())
    guard destination.lastPathComponent != program.lastPathComponent else { return program }
    let fm = FileManager.default
    // A case-only rename on a case-insensitive volume finds "itself" at the destination.
    if fm.fileExists(atPath: destination.path), destination.lastPathComponent.lowercased() != program.lastPathComponent.lowercased() {
      try fm.removeItem(at: destination)
    }
    try fm.moveItem(at: program, to: destination)
    return destination
  }
}
