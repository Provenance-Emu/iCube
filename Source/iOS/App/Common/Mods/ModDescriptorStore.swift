// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// GameMod descriptors (`.json`): small files that name a base disc and the Riivolution choices to boot it with.
/// Nothing from the disc is copied, so a descriptor in the library costs a few kilobytes.
@objc(DOLModDescriptorStore)
final class ModDescriptorStore: NSObject {
  static let fileExtension = "json"
  /// Folder of saved descriptors, inside the Software folder so the library scan lists each as its own game.
  static let libraryFolderName = "Mods"
  /// Descriptors written for a single play. They sit in the user's cache folder and are swept at launch.
  static let runsFolderName = "ModRuns"
  private static let cacheFolderName = "Cache"
  private static let fallbackName = "Mod"
  private static let maxNameLength = 100
  private static let forbiddenNameCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)

  /// True for a descriptor path. The library lists these as their own tile even though they share the base game's id.
  static func isDescriptor(path: String) -> Bool {
    URL(fileURLWithPath: path).pathExtension.lowercased() == fileExtension
  }

  static func libraryFolder(softwareFolder: String = UserFolderUtil.getSoftwareFolder()) -> URL {
    URL(fileURLWithPath: softwareFolder, isDirectory: true).appendingPathComponent(libraryFolderName, isDirectory: true)
  }

  static func runsFolder(userFolder: String = UserFolderUtil.getUserFolder()) -> URL {
    URL(fileURLWithPath: userFolder, isDirectory: true)
      .appendingPathComponent(cacheFolderName, isDirectory: true)
      .appendingPathComponent(runsFolderName, isDirectory: true)
  }

  /// A fresh descriptor URL for a single play.
  static func newRunURL(userFolder: String = UserFolderUtil.getUserFolder()) -> URL {
    runsFolder(userFolder: userFolder).appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
  }

  /// Deletes every single-play descriptor. Launch only: a booted game still reads its descriptor's packs.
  @objc static func sweepRuns() {
    sweepRuns(userFolder: UserFolderUtil.getUserFolder())
  }

  static func sweepRuns(userFolder: String) {
    try? FileManager.default.removeItem(at: runsFolder(userFolder: userFolder))
  }

  /// A file name made from `title`: no path separators or characters that Files and WebDAV clients reject.
  static func sanitizedFileName(_ title: String) -> String {
    let cleaned = title.unicodeScalars
      .map { forbiddenNameCharacters.contains($0) ? " " : String($0) }
      .joined()
      .split(separator: " ", omittingEmptySubsequences: true)
      .joined(separator: " ")
      .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return cleaned.isEmpty ? fallbackName : String(cleaned.prefix(maxNameLength))
  }

  /// `<folder>/<name>.json`, or `<name> (2).json` and so on if that exists.
  static func uniqueURL(in folder: URL, name: String) -> URL {
    let base = sanitizedFileName(name)
    var candidate = folder.appendingPathComponent(base).appendingPathExtension(fileExtension)
    var counter = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = folder.appendingPathComponent("\(base) (\(counter))").appendingPathExtension(fileExtension)
      counter += 1
    }
    return candidate
  }

  /// `path` as seen from `directory`, so a descriptor survives the app container moving. A path that shares
  /// nothing with `directory` but the root stays absolute. A trailing slash (a folder) is kept.
  static func relativePath(from directory: URL, to path: String) -> String {
    let from = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    let to = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.pathComponents
    var shared = 0
    while shared < min(from.count, to.count), from[shared] == to[shared] { shared += 1 }
    guard shared > 1 else { return path }
    let steps = Array(repeating: "..", count: from.count - shared) + to[shared...]
    let relative = steps.isEmpty ? "." : steps.joined(separator: "/")
    return path.hasSuffix("/") ? relative + "/" : relative
  }

  struct WriteFailure: Error {}

  /// Writes a descriptor booting `baseFile` with each pack's selections. Paths are stored relative to the descriptor.
  static func write(baseFile: String, displayName: String, packs: [RiivolutionPack], to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let written = RiivolutionBridge.writeDescriptor(
      toPath: url.path,
      baseFile: baseFile,
      displayName: displayName,
      packs: packs.map(\.bridgeInfo)
    ) { relativePath(from: directory, to: $0) }
    guard written else { throw WriteFailure() }
  }
}
