// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The receiving half of the shared drop box (see `EcosystemHandoff`): finds
/// the hand-offs a sibling app left for this one and moves their files into the
/// library folder. File work only; `EcosystemHandoffImporter` drives it and
/// tells the library to rescan.
enum EcosystemHandoffInbox {
  /// One complete hand-off waiting in this app's inbox.
  struct Pending: Equatable, Sendable {
    let directory: URL
    let manifest: EcosystemHandoffManifest
  }

  /// What `place` did with one hand-off.
  struct Placement: Equatable, Sendable {
    /// Files now in the library folder because of this hand-off.
    var placed: [URL] = []
    /// Files that were already there under the same path (left as they were).
    var alreadyPresent: [URL] = []
    /// Manifest paths that were refused and will never be taken: unsafe,
    /// missing, not a regular file, or a type iCube does not import.
    var rejected: [String] = []
    /// Manifest paths whose move into the library failed (no space, a folder
    /// that could not be written). The hand-off is kept so they are tried
    /// again.
    var failed: [String] = []
    /// Library-folder URLs of the manifest's primary files, placed or
    /// already present.
    var primaries: [URL] = []
  }

  /// Moves one file into the library. The default is the importer's own
  /// staged move (`ImportStaging`): a rename on one volume, a size-checked
  /// copy through an `.importing` sibling across volumes.
  typealias Mover = (_ source: URL, _ destination: URL) throws -> Void

  static let stagedMove: Mover = { source, destination in
    try ImportStaging.stagedMove(fromPath: source.path, toPath: destination.path)
  }

  /// Hand-offs addressed to `own` that this build understands, oldest first.
  /// Staging directories, other versions and other kinds are left where they
  /// are for their sender to clean up.
  static func pending(
    root: URL,
    own: String = EcosystemSchemes.ownScheme,
    fileManager: FileManager = .default
  ) -> [Pending] {
    let inbox = EcosystemHandoff.inbox(for: own, root: root)
    guard let items = try? fileManager.contentsOfDirectory(
      at: inbox, includingPropertiesForKeys: [.isDirectoryKey]
    ) else { return [] }

    var result: [Pending] = []
    for item in items where !item.lastPathComponent.hasPrefix(".") {
      guard let data = try? Data(contentsOf: item.appendingPathComponent(EcosystemHandoff.manifestName)),
            let manifest = try? EcosystemHandoffManifest.decoder()
              .decode(EcosystemHandoffManifest.self, from: data),
            manifest.version >= 1, manifest.version <= EcosystemHandoff.protocolVersion,
            manifest.kind == EcosystemHandoff.gameKind,
            manifest.to.lowercased() == own.lowercased()
      else { continue }
      result.append(Pending(directory: item, manifest: manifest))
    }
    return result.sorted { $0.manifest.created < $1.manifest.created }
  }

  /// Moves a hand-off's files into `libraryDirectory`, keeping their relative
  /// layout (the library scan is recursive), then deletes the hand-off.
  ///
  /// - A file already in the library under the same path with the same bytes
  ///   is left alone: the same game sent twice is not an error.
  /// - A different file under the same path (two dumps both named `game.iso`)
  ///   is kept beside it under a free name, `game (2).iso`.
  /// - When a move fails the hand-off is not deleted, so the next pass tries
  ///   again. Files an earlier pass already moved count as present.
  static func place(
    _ pending: Pending,
    into libraryDirectory: URL,
    allowedExtensions: Set<String>,
    fileManager: FileManager = .default,
    move: Mover = stagedMove
  ) -> Placement {
    let filesDirectory = pending.directory
      .appendingPathComponent(EcosystemHandoff.filesDirectoryName, isDirectory: true)
    var placement = Placement()

    for file in pending.manifest.files {
      let ext = (file.path as NSString).pathExtension.lowercased()
      guard isSafeRelativePath(file.path), allowedExtensions.contains(ext) else {
        placement.rejected.append(file.path)
        continue
      }
      let source = filesDirectory.appendingPathComponent(file.path)
      var destination = libraryDirectory.appendingPathComponent(file.path)
      let isPrimary = file.role == EcosystemHandoffManifest.primaryRole
      let destinationExists = fileManager.fileExists(atPath: destination.path)

      // Does not follow a link in the last component, so a symbolic link counts as there.
      guard (try? fileManager.attributesOfItem(atPath: source.path)) != nil else {
        if destinationExists {
          // Moved in by an earlier pass over a hand-off that was kept for a retry.
          placement.alreadyPresent.append(destination)
          if isPrimary { placement.primaries.append(destination) }
        } else {
          placement.rejected.append(file.path)
        }
        continue
      }
      // A symbolic link in the drop box could name a file outside it.
      guard isRegularFile(source) else {
        placement.rejected.append(file.path)
        continue
      }
      if destinationExists {
        if hasSameContents(source, destination, fileManager: fileManager) {
          placement.alreadyPresent.append(destination)
          if isPrimary { placement.primaries.append(destination) }
          continue
        }
        destination = freeName(beside: destination, fileManager: fileManager)
      }
      do {
        try fileManager.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try move(source, destination)
        placement.placed.append(destination)
        if isPrimary { placement.primaries.append(destination) }
      } catch {
        NSLog("[Ecosystem] couldn't move '%@' into the library: %@", file.path, error.localizedDescription)
        placement.failed.append(file.path)
      }
    }

    if placement.failed.isEmpty {
      try? fileManager.removeItem(at: pending.directory)
    }
    return placement
  }

  /// A manifest path may only name something below `files/`: relative, no
  /// empty, `.`, `..` or dot-prefixed components, no backslashes.
  static func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
      return false
    }
    return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
      !component.isEmpty && component != "." && component != ".." && !component.hasPrefix(".")
    }
  }

  private static func isRegularFile(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
  }

  /// Byte for byte the same file? Sizes first: every full GameCube image is
  /// the same size, so equal sizes alone say nothing, and the full comparison
  /// only runs when a name collides.
  private static func hasSameContents(_ first: URL, _ second: URL, fileManager: FileManager) -> Bool {
    func size(_ url: URL) -> Int64? {
      (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
    guard let firstSize = size(first), firstSize == size(second) else { return false }
    return fileManager.contentsEqual(atPath: first.path, andPath: second.path)
  }

  /// `game.iso` → `game (2).iso`, or the first number after that which is free.
  private static func freeName(beside url: URL, fileManager: FileManager) -> URL {
    let directory = url.deletingLastPathComponent()
    let stem = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    var number = 2
    while true {
      let candidate = directory.appendingPathComponent("\(stem) (\(number))").appendingPathExtension(ext)
      if !fileManager.fileExists(atPath: candidate.path) { return candidate }
      number += 1
    }
  }
}
