// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Finds the program inside an unpacked Dolphin Depot package. Packages are laid out like an SD
/// card for a real console: usually `apps/<name>/default.dol`, sometimes with data beside it.
enum HomebrewPackageLayout {
  private static let programExtensions: Set<String> = ["dol", "elf"]
  private static let preferredNames = ["default.dol", "boot.dol"]
  private static let macArchiveFolder = "__MACOSX"

  /// The program to start, or nil when the package has none. Only regular files count.
  ///
  /// A package with several is an SD card holding several builds of one title (Cube64 ships
  /// `apps/cube64-Rice`, `apps/cube64-Rice-exp` and two more). The folder named after the title
  /// wins, then the shortest folder name, which is the plain build rather than a variant of it.
  static func program(in root: URL, slug: String? = nil) -> URL? {
    let programs = files(in: root).filter { programExtensions.contains($0.url.pathExtension.lowercased()) }
    if programs.count <= 1 { return programs.first?.url }
    for name in preferredNames {
      let matches = programs.filter {
        $0.path.count == 3 && $0.path[0].lowercased() == "apps" && $0.path[2].lowercased() == name
      }
      if let own = matches.first(where: { $0.path[1].caseInsensitiveCompare(slug ?? "") == .orderedSame }) {
        return own.url
      }
      // `min` keeps the first of equals, and `programs` is in path order.
      if let plainest = matches.min(by: { $0.path[1].count < $1.path[1].count }) { return plainest.url }
    }
    return programs.first?.url
  }

  /// Every regular file of the package, in path order, with its path from the package root.
  private static func files(in root: URL) -> [(path: [String], url: URL)] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
    // Hidden files include the `._name` sidecars a Mac's zip adds; `__MACOSX` holds more of them.
    guard let walker = FileManager.default.enumerator(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else { return [] }
    var found: [(path: [String], url: URL)] = []
    for case let url as URL in walker {
      guard let values = try? url.resourceValues(forKeys: Set(keys)),
            values.isRegularFile == true, values.isSymbolicLink != true else { continue }
      // Counted from the walker's own depth: it may spell the root differently from the caller
      // (`/private/var` for `/var`), and a path cut by the caller's length is then one folder out.
      let path = Array(url.pathComponents.suffix(walker.level))
      if !path.isEmpty, !path.contains(where: { $0.caseInsensitiveCompare(macArchiveFolder) == .orderedSame }) {
        found.append((path, url))
      }
    }
    return found.sorted { $0.path.joined(separator: "/") < $1.path.joined(separator: "/") }
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
