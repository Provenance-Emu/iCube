// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Persists when each local ROM path was added to the library. File mtimes often
/// reflect the original disc image timestamp, not the import time.
enum LibraryAddedDateStore {
  private static let defaultsKey = "library_added_dates_v1"

  /// Records or refreshes the import timestamp for a local filesystem path.
  static func record(path: String, date: Date = Date()) {
    let key = normalize(path)
    guard !key.isEmpty else { return }
    var map = load()
    map[key] = date.timeIntervalSince1970
    save(map)
  }

  /// Lookup for sort/display; tries normalized path and bare path variants.
  static func addedDate(forPath path: String) -> Date? {
    let map = load()
    let key = normalize(path)
    if let t = map[key] { return Date(timeIntervalSince1970: t) }
    if path.hasPrefix("/"), let t = map[path] { return Date(timeIntervalSince1970: t) }
    if let url = URL(string: path), url.isFileURL {
      let p = url.path
      if let t = map[p] { return Date(timeIntervalSince1970: t) }
    }
    return nil
  }

  /// File creation in the sandbox (import time on iOS) when no explicit record exists.
  /// Never uses modification date — ROM copies preserve the source mtime from the PC.
  static func filesystemAddedDate(forPath path: String) -> Date? {
    let url = URL(fileURLWithPath: path)
    if let values = try? url.resourceValues(forKeys: [.creationDateKey]) {
      return values.creationDate
    }
    if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
      return attrs[.creationDate] as? Date
    }
    return nil
  }

  /// Best available "date added" for sorting.
  static func resolvedAddedDate(forPath path: String) -> Date? {
    if let stored = addedDate(forPath: path) { return stored }
    return filesystemAddedDate(forPath: path)
  }

  /// After an import burst, stamp software files that landed recently but lack a stored date.
  static func recordRecentImportsInSoftwareFolder(within seconds: TimeInterval = 300) {
    let folder = UserFolderUtil.getSoftwareFolder()
    let root = URL(fileURLWithPath: folder, isDirectory: true)
    let fm = FileManager.default
    guard fm.fileExists(atPath: folder) else { return }
    let cutoff = Date().addingTimeInterval(-seconds)
    let importTime = Date()

    guard let enumerator = fm.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return }

    for case let url as URL in enumerator {
      let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false
      guard isRegular, ImportableFileTypes.isSoftwareFile(url) else { continue }
      let path = url.path
      if addedDate(forPath: path) != nil { continue }
      let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
      guard let created, created >= cutoff else { continue }
      record(path: path, date: importTime)
    }
  }

  private static func normalize(_ path: String) -> String {
    if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
      return url.path
    }
    return (path as NSString).standardizingPath
  }

  private static func load() -> [String: TimeInterval] {
    UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: TimeInterval] ?? [:]
  }

  private static func save(_ map: [String: TimeInterval]) {
    UserDefaults.standard.set(map, forKey: defaultsKey)
  }
}

#if os(iOS)
@objcMembers
final class LibraryAddedDateStoreBridge: NSObject {
  static func recordPath(_ path: String) {
    LibraryAddedDateStore.record(path: path)
  }
}
#endif
