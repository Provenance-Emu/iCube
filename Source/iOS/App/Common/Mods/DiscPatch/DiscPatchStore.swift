// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The patch files iCube keeps: `<User>/Patches/`. Imports, picked files and uploads end up here so a
/// patch outlives the security scope or temporary folder it arrived in.
enum DiscPatchStore {
  /// Copies `url` into the store and returns the stored file. A file that is already there, or whose
  /// name and size match one that is, is reused; any other clash gets a numbered name.
  static func importPatch(from url: URL, directories: DiscPatchDirectories) throws -> URL {
    let fileManager = FileManager.default
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

    try fileManager.createDirectory(at: directories.patches, withIntermediateDirectories: true)
    if url.deletingLastPathComponent().standardizedFileURL == directories.patches.standardizedFileURL { return url }

    let size = fileSize(at: url)
    let base = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    var destination = directories.patches.appendingPathComponent(url.lastPathComponent)
    var counter = 2
    while fileManager.fileExists(atPath: destination.path) {
      if fileSize(at: destination) == size { return destination }
      destination = directories.patches.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
      counter += 1
    }
    try fileManager.copyItem(at: url, to: destination)
    return destination
  }

  /// Moves a finished upload into the store (the web server wrote it into the library folder).
  static func adoptUpload(at url: URL, directories: DiscPatchDirectories) throws -> URL {
    let stored = try importPatch(from: url, directories: directories)
    if stored != url { try? FileManager.default.removeItem(at: url) }
    return stored
  }

  /// Patch files already on the device, newest first: the store, and the top level of the library
  /// folder where a Files-app drop or a WebDAV upload may have left one. tvOS has no document picker,
  /// so this list is how a patch is chosen there.
  static func availablePatches(directories: DiscPatchDirectories) -> [URL] {
    let fileManager = FileManager.default
    let found = [directories.patches, directories.software].flatMap { folder -> [URL] in
      let contents = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      return contents.filter(DiscPatchPlanner.isPatchFile)
    }
    return found.sorted { modified($0) > modified($1) }
  }

  private static func modified(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
  }

  private static func fileSize(at url: URL) -> UInt64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
  }
}
