// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Single source of truth for importable disc images, archives, and document-picker UTTypes.
enum ImportableFileTypes {
  /// Disc images accepted by the library scanner and local import pipeline.
  ///
  /// Aligned with `UICommon::FindAllGamePaths` plus iOS-specific additions (`nkit`, `img`).
  static let softwareExtensions: Set<String> = [
    "iso", "gcm", "tgc", "wbfs", "gcz", "ciso", "rvz", "wad", "dol", "elf",
    "nkit", "wia", "img", "bin",
  ]

  /// Archive formats handled by `ZipImportHelper`.
  static let archiveExtensions: Set<String> = [
    "zip", "7z", "gz", "gzip", "tar", "tgz", "xz", "bz2", "tbz", "tbz2",
  ]

  /// Cover-art extensions shown when browsing remote WebDAV libraries.
  static let webDAVCoverExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

  /// All file extensions surfaced while enumerating a remote WebDAV source.
  static var webDAVBrowsableExtensions: Set<String> {
    softwareExtensions.union(archiveExtensions).union(webDAVCoverExtensions)
  }

  /// Archive shape used by the extraction pipeline.
  enum ArchiveKind {
    case zip
    case sevenZip
    case gzip
    case bzip2
    case tar
    case tarGz
    case tarBz2
    case xz
  }

  /// Lowercased path extension for `url`, or empty when absent.
  static func pathExtension(for url: URL) -> String {
    url.pathExtension.lowercased()
  }

  /// Returns true when `url` points at a supported disc image.
  static func isSoftwareFile(_ url: URL) -> Bool {
    softwareExtensions.contains(pathExtension(for: url))
  }

  /// Returns true when `path` has a supported archive extension (including compound names).
  static func isArchiveFile(atPath path: String) -> Bool {
    archiveKind(for: URL(fileURLWithPath: path)) != nil
  }

  /// Returns true when `url` has a supported archive extension (including compound names).
  static func isArchiveFile(_ url: URL) -> Bool {
    archiveKind(for: url) != nil
  }

  /// Classifies supported archives, including compound extensions such as `.tar.gz`.
  static func archiveKind(for url: URL) -> ArchiveKind? {
    let ext = pathExtension(for: url)
    let parentExt = url.deletingPathExtension().pathExtension.lowercased()

    if ext == "gz", parentExt == "tar" { return .tarGz }
    if ext == "bz2", parentExt == "tar" { return .tarBz2 }
    if ext == "tgz" { return .tarGz }
    if ext == "tbz" || ext == "tbz2" { return .tarBz2 }

    switch ext {
    case "zip": return .zip
    case "7z": return .sevenZip
    case "gz", "gzip": return .gzip
    case "bz2": return .bzip2
    case "tar": return .tar
    case "xz": return .xz
    default: return nil
    }
  }

  /// Expands dropped/picked directories and keeps only importable files.
  static func filterImportURLs(_ urls: [URL]) -> [URL] {
    var results: [URL] = []
    let fm = FileManager.default

    for url in urls {
      var isDir: ObjCBool = false
      if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
        if let enumerator = fm.enumerator(at: url,
                                          includingPropertiesForKeys: [.isRegularFileKey],
                                          options: [.skipsHiddenFiles]) {
          for case let fileURL as URL in enumerator where isImportableFile(fileURL) {
            results.append(fileURL)
          }
        }
        continue
      }

      if isImportableFile(url) {
        results.append(url)
      }
    }

    return results
  }

  /// Returns true when `url` is a supported disc image or archive.
  static func isImportableFile(_ url: URL) -> Bool {
    isSoftwareFile(url) || isArchiveFile(url)
  }

  #if canImport(UniformTypeIdentifiers)
  /// Custom exported / imported UTI identifiers declared in Info.plist.
  static let declaredTypeIdentifiers: [String] = [
    "me.oatmealdome.dolphinios.generic-software",
    "me.oatmealdome.dolphinios.gamecube-software",
    "me.oatmealdome.dolphinios.wii-software",
    "public.iso-image",
    "me.oatmealdome.dolphinios.rvz-image",
    "me.oatmealdome.dolphinios.wia-image",
    "me.oatmealdome.dolphinios.nkit-image",
    "me.oatmealdome.dolphinios.dol-executable",
    "me.oatmealdome.dolphinios.elf-executable",
    "me.oatmealdome.dolphinios.7z-archive",
    "me.oatmealdome.dolphinios.zip-archive",
    "me.oatmealdome.dolphinios.gzip-archive",
    "me.oatmealdome.dolphinios.bzip2-archive",
    "me.oatmealdome.dolphinios.tar-archive",
    "me.oatmealdome.dolphinios.xz-archive",
  ]

  /// UTTypes offered by software import document pickers.
  static var documentPickerTypes: [UTType] {
    var seen = Set<String>()
    var types: [UTType] = []

    func append(_ type: UTType?) {
      guard let type, seen.insert(type.identifier).inserted else { return }
      types.append(type)
    }

    for identifier in declaredTypeIdentifiers {
      append(UTType(identifier))
    }

    for ext in softwareExtensions.union(archiveExtensions) {
      append(UTType(filenameExtension: ext))
    }

    append(.archive)
    return types
  }

  /// UTType for `.bin` NAND imports.
  static var binPickerType: UTType {
    UTType(filenameExtension: "bin") ?? .data
  }
  #endif
}

/// Objective-C bridge for `ImportFileManager`, `ZipImportHelper`, and UIKit pickers.
@objc(DOLImportableFileTypes)
final class ImportableFileTypesBridge: NSObject {
  @objc(softwarePathExtensions)
  static func softwarePathExtensions() -> [String] {
    Array(ImportableFileTypes.softwareExtensions).sorted()
  }

  @objc(archivePathExtensions)
  static func archivePathExtensions() -> [String] {
    Array(ImportableFileTypes.archiveExtensions).sorted()
  }

  @objc(isSoftwarePath:)
  static func isSoftwarePath(_ path: String) -> Bool {
    ImportableFileTypes.isSoftwareFile(URL(fileURLWithPath: path))
  }

  @objc(isArchivePath:)
  static func isArchivePath(_ path: String) -> Bool {
    ImportableFileTypes.isArchiveFile(atPath: path)
  }

  @objc(filterImportURLs:)
  static func filterImportURLs(_ urls: [URL]) -> [URL] {
    ImportableFileTypes.filterImportURLs(urls)
  }

  #if canImport(UniformTypeIdentifiers)
  @objc(documentPickerContentTypeIdentifiers)
  static func documentPickerContentTypeIdentifiers() -> [String] {
    ImportableFileTypes.documentPickerTypes.map(\.identifier)
  }
  #endif
}
