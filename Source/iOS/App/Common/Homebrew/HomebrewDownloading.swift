// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// A fetched package and the server's ETag for it, if it sent one.
struct HomebrewDownload: Sendable {
  let file: URL
  let etag: String?
}

/// What the homebrew installer needs from a downloader. `ModDownloadManager` is the real one; tests
/// hand back a prepared file.
protocol HomebrewDownloading: Sendable {
  /// Downloads `source` to `directory/fileName`, reporting 0...1. `key` names the transfer so a
  /// cancelled one can resume. Cancelling the calling task cancels the transfer.
  func download(key: String, from source: URL, fileName: String, expectedBytes: Int64, into directory: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> HomebrewDownload
}

extension ModDownloadManager: HomebrewDownloading {}
