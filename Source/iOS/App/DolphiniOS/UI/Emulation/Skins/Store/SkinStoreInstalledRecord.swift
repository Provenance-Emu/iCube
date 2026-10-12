// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// Which catalog entries the store has installed: `[catalog id: installed skin identifier]`, in a
/// JSON file beside the library's `selection.json`. Keyed by catalog id so a skin the player later
/// deletes can be noticed (`SkinStoreInstaller.reconcileInstalled`) instead of showing "Installed"
/// forever.
struct SkinStoreInstalledRecord {
  let fileURL: URL

  init(fileURL: URL = SkinLibrary.defaultRootURL().appendingPathComponent(SkinLibrary.storeRecordFileName)) {
    self.fileURL = fileURL
  }

  func load() -> [String: String] {
    guard let data = try? Data(contentsOf: fileURL) else { return [:] }
    return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
  }

  func markInstalled(catalogId: String, skinIdentifier: String) {
    var current = load()
    current[catalogId] = skinIdentifier
    save(current)
  }

  func remove(catalogIds: Set<String>) {
    guard !catalogIds.isEmpty else { return }
    var current = load()
    for id in catalogIds { current[id] = nil }
    save(current)
  }

  private func save(_ record: [String: String]) {
    try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(record) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
#endif
