// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Installs Riivolution packs into the virtual SD card (`Load/Riivolution/`), the layout Dolphin reads on desktop.
///
/// A pack is any folder holding `riivolution/*.xml`, with the files the XMLs refer to beside it. Most packs are
/// zipped either with that folder at the top or inside one wrapper folder; both install the same way.
enum RiivolutionPackInstaller {
  struct Summary: Equatable {
    let packName: String
    let optionCount: Int

    /// "Installed Riivolution pack Newer SMBW (12 options)".
    var message: String {
      let format = optionCount == 1 ? L("Installed Riivolution pack %@ (%d option)") : L("Installed Riivolution pack %@ (%d options)")
      return String(format: format, packName, optionCount)
    }
  }

  private static let xmlExtension = "xml"
  private static let optionElement = "option"

  /// The folders of `folder` that hold a pack: `folder` itself, or else its immediate subfolders.
  static func packRoots(in folder: URL) -> [URL] {
    if hasPack(folder) { return [folder] }
    let subfolders = (try? FileManager.default.contentsOfDirectory(
      at: folder,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    return subfolders
      .filter { isDirectory($0) && !ZipImportHelper.shouldSkipArchiveRelativePath($0.lastPathComponent + "/") && hasPack($0) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// Moves the packs found in `extractedFolder` into `root`, replacing files that already exist (a pack update).
  /// Every path is checked before the first file moves, so a rejected pack installs nothing.
  static func install(extractedFolder: URL, name: String, into root: URL = RiivolutionLocation.installRoot()) throws -> Summary {
    let packRoots = packRoots(in: extractedFolder)
    var moves: [(source: URL, destination: URL)] = []
    for packRoot in packRoots {
      moves += try plannedMoves(from: packRoot, into: root)
    }
    guard !moves.isEmpty else { throw CocoaError(.fileNoSuchFile) }

    let fileManager = FileManager.default
    for move in moves {
      try fileManager.createDirectory(at: move.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      if fileManager.fileExists(atPath: move.destination.path) {
        try fileManager.removeItem(at: move.destination)
      }
      try fileManager.moveItem(at: move.source, to: move.destination)
    }
    let xmlFolder = root.appendingPathComponent(RiivolutionLocation.xmlFolderName, isDirectory: true)
    let installedXMLs = moves.map(\.destination).filter { $0.deletingLastPathComponent().path == xmlFolder.path && isXML($0) }
    return Summary(packName: name, optionCount: installedXMLs.reduce(0) { $0 + countOptions(inXMLAt: $1) })
  }

  // MARK: - Planning

  private static func plannedMoves(from packRoot: URL, into root: URL) throws -> [(source: URL, destination: URL)] {
    guard let files = FileManager.default.enumerator(
      at: packRoot,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
    ) else { return [] }

    let rootPath = root.standardizedFileURL.path + "/"
    var moves: [(source: URL, destination: URL)] = []
    for case let file as URL in files {
      let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      let relative = relativePath(of: file, in: packRoot)
      if values.isSymbolicLink == true { throw ZipEntryScannerError.unsafeEntry(relative) }
      guard values.isRegularFile == true else { continue }
      if ZipImportHelper.shouldSkipArchiveRelativePath(relative) || file.lastPathComponent.hasPrefix("._") { continue }

      try ZipImportHelper.validateItemPaths([relative])
      let destination = root.appendingPathComponent(normalizedPath(relative))
      guard destination.standardizedFileURL.path.hasPrefix(rootPath) else { throw ZipEntryScannerError.unsafeEntry(relative) }
      moves.append((file, destination))
    }
    return moves
  }

  /// Dolphin looks for the XML folder in lowercase, and the case of the archive's folder is the pack author's choice.
  private static func normalizedPath(_ relative: String) -> String {
    var components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    if let first = components.first, first.lowercased() == RiivolutionLocation.xmlFolderName {
      components[0] = RiivolutionLocation.xmlFolderName
    }
    return components.joined(separator: "/")
  }

  private static func relativePath(of file: URL, in folder: URL) -> String {
    let folderPath = folder.standardizedFileURL.path + "/"
    let path = file.standardizedFileURL.path
    return path.hasPrefix(folderPath) ? String(path.dropFirst(folderPath.count)) : file.lastPathComponent
  }

  // MARK: - Detection

  private static func hasPack(_ folder: URL) -> Bool {
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    guard let xmlFolderName = entries.first(where: { $0.lowercased() == RiivolutionLocation.xmlFolderName }) else { return false }
    let xmlFolder = folder.appendingPathComponent(xmlFolderName, isDirectory: true)
    guard isDirectory(xmlFolder) else { return false }
    let xmls = (try? FileManager.default.contentsOfDirectory(atPath: xmlFolder.path)) ?? []
    return xmls.contains { isXML(URL(fileURLWithPath: $0)) && !$0.hasPrefix("._") }
  }

  private static func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
  }

  private static func isXML(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == xmlExtension
  }

  // MARK: - Option count

  private static func countOptions(inXMLAt url: URL) -> Int {
    guard let parser = XMLParser(contentsOf: url) else { return 0 }
    let counter = OptionCounter()
    parser.delegate = counter
    parser.parse()
    return counter.count
  }

  private final class OptionCounter: NSObject, XMLParserDelegate {
    private(set) var count = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
      if elementName == RiivolutionPackInstaller.optionElement { count += 1 }
    }
  }
}
