// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Lists the most recent save states as (game, date) pairs for the widget's Continue list.
///
/// Lighter than `FilesystemSaveStateProvider`: it reads no state file and checks no compatibility,
/// only the folder listing and the sidecars of the newest `scanLimit` files, because it runs on
/// every snapshot write.
enum SaveStateContinuesScanner {
  /// Newest files looked at. One game's quick-save history can hold many, so this is well above
  /// `ContinuesList.maxEntries`.
  static let scanLimit = 200

  static func scan(root: URL, limit: Int = scanLimit, fileManager: FileManager = .default) -> [ContinueEntry] {
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
    let urls = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
    let files: [(url: URL, modified: Date)] = urls.compactMap { url in
      guard FilesystemSaveStateProvider.isCommittedStateFileName(url.lastPathComponent),
            let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory != true,
            let modified = values.contentModificationDate else { return nil }
      return (url, modified)
    }
    return files.sorted { $0.modified > $1.modified }.prefix(limit).map { file in
      let metadata = SaveStateMetadataStore.read(forStateFile: file.url)
      return ContinueEntry(gameID: metadata?.gameID ?? gameID(fromFileName: file.url),
                           savedAt: metadata?.savedAt ?? file.modified)
    }
  }

  /// A save with no sidecar: `GALE01.s01`, `GALE01.auto`, or a quick save `GALE01.quick-<uuid>.s01`.
  private static func gameID(fromFileName url: URL) -> String {
    QuickSaveHistoryPolicy.historyGameID(for: url) ?? url.deletingPathExtension().lastPathComponent
  }
}
