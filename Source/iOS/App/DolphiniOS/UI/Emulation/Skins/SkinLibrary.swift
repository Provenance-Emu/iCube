// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation
import Zip

/// A skin that has been imported and unpacked into the library.
struct InstalledSkin: Identifiable, Equatable {
  /// The skin's `info.json` identifier, which is also the name of its folder in the library.
  let id: String
  let name: String
  let gameType: SkinGameType
  let directory: URL
}

enum SkinImportError: Error, Equatable {
  /// The file is not a zip archive, or could not be unpacked.
  case unreadableArchive
  /// No `info.json` at the archive root or one folder deep.
  case missingInfo
  /// The skin targets a system iCube does not run. Carries the raw `gameTypeIdentifier`.
  case unsupportedGameType(String)
  /// `info.json` is valid but declares no layout this app can use.
  case noUsableLayout
  /// The skin's identifier cannot be used as a folder name.
  case invalidIdentifier

  /// A short sentence for the player; any other error falls back to its own description.
  static func describe(_ error: Error) -> String {
    switch error as? SkinImportError {
    case .unreadableArchive: return L("the file is not a skin archive")
    case .missingInfo: return L("the skin has no readable info.json")
    case .unsupportedGameType(let identifier): return String(format: L("unsupported game type %@"), identifier)
    case .noUsableLayout: return L("the skin has no usable layout")
    case .invalidIdentifier: return L("the skin's identifier is not valid")
    case nil: return error.localizedDescription
    }
  }
}

/// The skins the player has imported, and which one they picked per pad kind and orientation.
/// Skins live in `<root>/<identifier>/`; the picks live in `<root>/selection.json`.
@MainActor
final class SkinLibrary: ObservableObject {
  static let shared = SkinLibrary(rootURL: defaultRootURL())

  /// File extensions of the archives the system hands to the app (Delta and Manic share the zip layout).
  static let archiveExtensions: Set<String> = ["deltaskin", "manicskin"]

  private static let rootFolderName = "Skins"
  private static let selectionFileName = "selection.json"
  private static let infoFileName = "info.json"
  private static let stagingArchiveName = "archive.zip"
  private static let stagingExtractFolderName = "extracted"
  private static let gameTypeKey = "gameTypeIdentifier"

  @Published private(set) var skins: [InstalledSkin] = []

  private let rootURL: URL
  /// `"<padKind>.<orientation>"` (see `TouchOverlayLayoutStore.key`) to the chosen skin's identifier.
  private var selection: [String: String] = [:]

  init(rootURL: URL) {
    self.rootURL = rootURL
    skins = Self.scan(rootURL)
    selection = Self.loadSelection(from: rootURL.appendingPathComponent(Self.selectionFileName))
  }

  private static func defaultRootURL() -> URL {
    URL(fileURLWithPath: UserFolderUtil.getUserFolder()).appendingPathComponent(rootFolderName, isDirectory: true)
  }

  static func isSkinArchive(_ url: URL) -> Bool {
    url.isFileURL && archiveExtensions.contains(url.pathExtension.lowercased())
  }

  // MARK: - Import and delete

  /// Unpacks, validates and installs the skin in `archive`, replacing any installed skin with the same identifier.
  /// Nothing is left on disk when this throws.
  @discardableResult
  func importSkin(from archive: URL) throws -> InstalledSkin {
    let fileManager = FileManager.default
    let staging = fileManager.temporaryDirectory.appendingPathComponent("SkinImport-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: staging) }

    let extracted = staging.appendingPathComponent(Self.stagingExtractFolderName, isDirectory: true)
    do {
      try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
      // Zip only opens `.zip` / `.cbz`, and skins arrive as `.deltaskin` / `.manicskin`, so unpack a renamed copy.
      let zipCopy = staging.appendingPathComponent(Self.stagingArchiveName)
      try fileManager.copyItem(at: archive, to: zipCopy)
      try Zip.unzipFile(zipCopy, destination: extracted, overwrite: true, password: nil)
    } catch {
      throw SkinImportError.unreadableArchive
    }

    let skinFolder = try Self.skinFolder(in: extracted)
    let info = try Self.loadInfo(from: skinFolder)
    guard Self.isUsableFolderName(info.identifier) else { throw SkinImportError.invalidIdentifier }

    let destination = rootURL.appendingPathComponent(info.identifier, isDirectory: true)
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: skinFolder)
    } else {
      try fileManager.moveItem(at: skinFolder, to: destination)
    }

    let installed = InstalledSkin(id: info.identifier, name: info.name, gameType: info.gameType, directory: destination)
    skins = Self.scan(rootURL)
    return installed
  }

  func delete(_ skin: InstalledSkin) throws {
    try FileManager.default.removeItem(at: skin.directory)
    skins = Self.scan(rootURL)
    let cleaned = selection.filter { $0.value != skin.id }
    if cleaned.count != selection.count {
      selection = cleaned
      saveSelection()
    }
  }

  // MARK: - Selection

  func selectedSkin(for padKind: TouchOverlayPadKind, orientation: TouchOverlayOrientation) -> InstalledSkin? {
    guard let id = selection[TouchOverlayLayoutStore.key(padKind, orientation)] else { return nil }
    return skins.first { $0.id == id }
  }

  /// Picks `skin` for a pad kind and orientation, or clears the pick with `nil`.
  /// A skin whose game type cannot serve the pad kind is ignored.
  func select(_ skin: InstalledSkin?, for padKind: TouchOverlayPadKind, orientation: TouchOverlayOrientation) {
    let key = TouchOverlayLayoutStore.key(padKind, orientation)
    if let skin {
      guard skin.gameType.padKinds.contains(padKind) else { return }
      selection[key] = skin.id
    } else {
      selection[key] = nil
    }
    saveSelection()
  }

  // MARK: - Helpers

  /// The folder holding `info.json`: the archive root, or the single folder beside any `__MACOSX` litter.
  private static func skinFolder(in extracted: URL) throws -> URL {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: extracted.appendingPathComponent(infoFileName).path) { return extracted }
    let children = (try? fileManager.contentsOfDirectory(at: extracted, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
    for child in children {
      let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      if isDirectory, fileManager.fileExists(atPath: child.appendingPathComponent(infoFileName).path) { return child }
    }
    throw SkinImportError.missingInfo
  }

  private static func loadInfo(from folder: URL) throws -> SkinInfo {
    do {
      return try SkinInfo.load(directory: folder)
    } catch SkinInfoError.noUsableRepresentation {
      throw SkinImportError.noUsableLayout
    } catch {
      if let identifier = rawGameTypeIdentifier(in: folder), SkinGameType(identifier: identifier) == nil {
        throw SkinImportError.unsupportedGameType(identifier)
      }
      throw SkinImportError.missingInfo
    }
  }

  private static func rawGameTypeIdentifier(in folder: URL) -> String? {
    guard let raw = try? Data(contentsOf: folder.appendingPathComponent(infoFileName)),
          let data = try? SkinInfo.stripComments(raw),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return json[gameTypeKey] as? String
  }

  /// An identifier becomes a folder name, so it must not be able to climb out of the library or hide.
  private static func isUsableFolderName(_ name: String) -> Bool {
    !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && name != selectionFileName
  }

  private static func scan(_ root: URL) -> [InstalledSkin] {
    let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    return folders.compactMap { folder in
      guard let info = try? SkinInfo.load(directory: folder) else { return nil }
      return InstalledSkin(id: folder.lastPathComponent, name: info.name, gameType: info.gameType, directory: folder)
    }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private static func loadSelection(from url: URL) -> [String: String] {
    guard let data = try? Data(contentsOf: url) else { return [:] }
    return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
  }

  private func saveSelection() {
    try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(selection) else { return }
    try? data.write(to: rootURL.appendingPathComponent(Self.selectionFileName), options: .atomic)
  }
}
#endif
