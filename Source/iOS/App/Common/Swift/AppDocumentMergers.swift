// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import PVCloudSync
import PVLibraryMetadata
import PVSyncRules

/// Metadata shards use the shared canonical kernel; other documents retain
/// the package's category-specific merger.
enum AppDocumentMergers {
  static func merger(relativePath: String, fileType: SyncableFileType) -> (any DocumentMerger)? {
    if SyncClassifier.isLibraryMetadataShard(relativePath: relativePath) {
      return LibraryMetadataMerger(filename: (relativePath as NSString).lastPathComponent)
    }
    return DocumentMergers.merger(for: fileType)
  }

  private struct LibraryMetadataMerger: DocumentMerger {
    let filename: String

    func merge(local: Data, remote: Data) throws -> Data {
      try LibraryMetadataDocument.merge(local: local, remote: remote, filename: filename)
    }
  }
}
