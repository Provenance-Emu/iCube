// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The sending half of the shared drop box (see `EcosystemHandoff`): puts one
/// game's file set where a sibling app will find it.
///
/// Files are copied with `FileManager.copyItem`, which clones on APFS: the app
/// container and the group container sit on one volume, so a multi-gigabyte
/// disc image is staged in milliseconds and takes no extra space.
enum EcosystemHandoffStager {
  enum StageError: Error, Equatable {
    /// Nothing to send.
    case noFiles
  }

  /// One file of the set with the path it gets below `files/`.
  struct Entry: Equatable, Sendable {
    let source: URL
    let relativePath: String
    let role: String
  }

  /// Lays out a game's file set (primary first) for the drop box.
  ///
  /// A file below the primary's directory keeps its path relative to it; a
  /// file from anywhere else goes to the top level under its own name. Two
  /// files that would land on one path: the first wins. Every disc image is
  /// a primary (the receiver lists it); anything else rides along as a
  /// companion. An iCube game is one disc image today, so a set is normally
  /// a single primary.
  static func entries(for files: [URL]) -> [Entry] {
    guard let primary = files.first else { return [] }
    let base = primary.deletingLastPathComponent().standardizedFileURL.path + "/"

    var seen = Set<String>()
    var result: [Entry] = []
    for file in files {
      let path = file.standardizedFileURL.path
      let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : file.lastPathComponent
      guard !relative.isEmpty, seen.insert(relative.lowercased()).inserted else { continue }
      let role = file == primary || ImportableFileTypes.isSoftwareFile(file)
        ? EcosystemHandoffManifest.primaryRole
        : EcosystemHandoffManifest.companionRole
      result.append(Entry(source: file, relativePath: relative, role: role))
    }
    return result
  }

  /// Writes the hand-off and returns its manifest. The directory appears
  /// under its final name only once every file and the manifest are in it.
  static func stage(
    files: [URL],
    to peer: String,
    from sender: String = EcosystemSchemes.ownScheme,
    title: String,
    system: String?,
    md5: String?,
    root: URL,
    id: String = UUID().uuidString,
    now: Date = Date(),
    fileManager: FileManager = .default
  ) throws -> EcosystemHandoffManifest {
    let layout = Self.entries(for: files)
    guard !layout.isEmpty else { throw StageError.noFiles }

    let inbox = EcosystemHandoff.inbox(for: peer, root: root)
    let staging = inbox.appendingPathComponent(".\(id)\(EcosystemHandoff.stagingSuffix)", isDirectory: true)
    let filesDirectory = staging.appendingPathComponent(EcosystemHandoff.filesDirectoryName, isDirectory: true)
    try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)

    do {
      var manifestFiles: [EcosystemHandoffManifest.File] = []
      for entry in layout {
        let destination = filesDirectory.appendingPathComponent(entry.relativePath)
        try fileManager.createDirectory(
          at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try fileManager.copyItem(at: entry.source, to: destination)
        let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?
          .int64Value ?? 0
        manifestFiles.append(.init(path: entry.relativePath, role: entry.role, size: size))
      }
      let manifest = EcosystemHandoffManifest(
        version: EcosystemHandoff.protocolVersion,
        id: id,
        from: sender,
        to: peer.lowercased(),
        created: now,
        kind: EcosystemHandoff.gameKind,
        title: title,
        system: system,
        md5: md5?.lowercased(),
        files: manifestFiles
      )
      try EcosystemHandoffManifest.encoder().encode(manifest)
        .write(to: staging.appendingPathComponent(EcosystemHandoff.manifestName), options: .atomic)
      try fileManager.moveItem(at: staging, to: inbox.appendingPathComponent(id, isDirectory: true))
      return manifest
    } catch {
      try? fileManager.removeItem(at: staging)
      throw error
    }
  }

  /// Removes what this app left behind in every inbox: its own hand-offs that
  /// nobody picked up within `EcosystemHandoff.staleAfter`, and staging
  /// directories of sends that died. A staging directory has no manifest to
  /// name its sender, so one older than `stagingStaleAfter` is removed
  /// whoever started it; complete hand-offs from other apps are not touched.
  @discardableResult
  static func collectGarbage(
    root: URL,
    sender: String = EcosystemSchemes.ownScheme,
    now: Date = Date(),
    fileManager: FileManager = .default
  ) -> Int {
    let handoffRoot = root.appendingPathComponent("Handoff", isDirectory: true)
    guard let inboxes = try? fileManager.contentsOfDirectory(
      at: handoffRoot, includingPropertiesForKeys: nil
    ) else { return 0 }

    var removed = 0
    for inbox in inboxes {
      guard let items = try? fileManager.contentsOfDirectory(
        at: inbox, includingPropertiesForKeys: [.contentModificationDateKey]
      ) else { continue }
      for item in items {
        let name = item.lastPathComponent
        let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? now
        if name.hasPrefix("."), name.hasSuffix(EcosystemHandoff.stagingSuffix) {
          guard now.timeIntervalSince(modified) > EcosystemHandoff.stagingStaleAfter else { continue }
        } else {
          guard let data = try? Data(
                  contentsOf: item.appendingPathComponent(EcosystemHandoff.manifestName)
                ), let manifest = try? EcosystemHandoffManifest.decoder()
            .decode(EcosystemHandoffManifest.self, from: data),
            manifest.from == sender,
            now.timeIntervalSince(manifest.created) > EcosystemHandoff.staleAfter
          else { continue }
        }
        if (try? fileManager.removeItem(at: item)) != nil {
          removed += 1
        }
      }
    }
    return removed
  }
}
