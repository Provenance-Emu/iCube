// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Picks out the files the system asked the app to open (Open With, AirDrop, a drop on the Mac
/// Dock icon) that the import pipeline accepts. Links and unknown files are left for the URL router.
enum OpenedFileRouter {
  static func importableFiles(in urls: [URL]) -> [URL] {
    urls.filter { $0.isFileURL && (ImportableFileTypes.isImportableFile($0) || DiscPatchPlanner.isPatchFile($0)) }
  }
}
