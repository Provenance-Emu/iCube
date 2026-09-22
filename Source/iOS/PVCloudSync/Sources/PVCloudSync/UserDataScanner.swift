// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CryptoKit
import Foundation
import PVSyncRules

/// Walks iCube's `User/` directory and produces metadata for every file the
/// classifier allows off the device, plus the local read/write half of the sync.
///
/// The include/exclude decision is **not** made here — it is made by
/// `PVSyncRules.SyncClassifier`, which WS-4's continuity manifest also consults,
/// so the two features can never disagree about what may leave the device.
///
/// Two things this does that iFly's scanner does not:
///
/// - **Prunes at directory level.** iFly classifies every walked file, which
///   under `User/Load/` (texture packs, gigabytes) or `User/Cache/` means
///   enumerating tens of thousands of entries to reject all of them.
///   `SyncClassifier.shouldDescend` skips those subtrees whole.
/// - **Caches checksums by (size, mtime).** Hashing means reading the file, and
///   a 16 MB memory card re-read on every foreground transition is real battery
///   for no information. An entry is reused only when size *and* mtime both
///   match, so an edit always re-hashes.
public actor UserDataScanner {

    /// Absolute URL of iCube's `User/` directory. Every relative path in the
    /// sync engine is relative to this.
    public let rootDirectory: URL

    private let fileManager: FileManager
    private var checksumCache: [String: CachedChecksum] = [:]

    private struct CachedChecksum {
        let size: Int64
        let modified: Date
        let checksum: String
    }

    public init(rootDirectory: URL, fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
    }

    // MARK: - Scanning

    /// Metadata for every syncable file under the root.
    ///
    /// Never throws for a missing root: a fresh install may not have created
    /// `User/` yet, and an empty result is the correct answer.
    public func scanLocalFiles() -> [SyncableFileMetadata] {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return [] }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [SyncableFileMetadata] = []
        var seenPaths: Set<String> = []

        for case let url as URL in enumerator {
            guard let relativePath = CanonicalRelativePath.relativePath(of: url, under: rootDirectory) else {
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))

            if values?.isDirectory == true {
                if !SyncClassifier.shouldDescend(intoDirectoryRelativePath: relativePath) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }

            let size = Int64(values?.fileSize ?? 0)
            // Empty files carry no information and an empty CKAsset is a
            // needless round trip.
            guard size > 0 else { continue }

            guard let fileType = SyncClassifier.syncableType(relativePath: relativePath, sizeBytes: size) else {
                continue
            }

            let modified = values?.contentModificationDate ?? Date()
            guard let checksum = checksum(for: url, relativePath: relativePath, size: size, modified: modified) else {
                continue
            }

            // Defensive: the canonicaliser cannot produce duplicates, but the
            // record name is an identity key and a silent collision would be
            // ugly to debug.
            guard seenPaths.insert(relativePath).inserted else { continue }

            results.append(SyncableFileMetadata(
                relativePath: relativePath,
                lastModified: modified,
                fileSize: size,
                checksum: checksum,
                fileType: fileType,
                syncStatus: .local
            ))
        }

        return results
    }

    /// SHA-256 of the file, reusing the cached value when neither size nor mtime
    /// has changed.
    private func checksum(for url: URL, relativePath: String, size: Int64, modified: Date) -> String? {
        if let cached = checksumCache[relativePath],
           cached.size == size,
           cached.modified == modified {
            return cached.checksum
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let digest = SHA256.hash(data: data)
        let checksum = digest.map { String(format: "%02x", $0) }.joined()
        checksumCache[relativePath] = CachedChecksum(size: size, modified: modified, checksum: checksum)
        return checksum
    }

    // MARK: - Local file I/O

    public func absoluteURL(for relativePath: String) -> URL {
        rootDirectory.appendingPathComponent(relativePath)
    }

    public func readFile(relativePath: String) throws -> Data {
        try Data(contentsOf: absoluteURL(for: relativePath))
    }

    public func modificationDate(relativePath: String) -> Date? {
        let attributes = try? fileManager.attributesOfItem(atPath: absoluteURL(for: relativePath).path)
        return attributes?[.modificationDate] as? Date
    }

    /// Write a downloaded payload into the local tree, creating intermediate
    /// directories. Atomic, so a crash mid-write cannot truncate an existing save.
    ///
    /// `modificationDate` is **required on the download path**. The reconcile
    /// compares local and remote mtimes, and the remote record carries the
    /// original source mtime. A fresh download landing with mtime = now would
    /// always read back "newer" than the remote, triggering an immediate
    /// re-upload — endless ping-pong between devices. Back-dating the file to the
    /// source mtime closes the round trip, and is harmless because Dolphin keys
    /// saves by content, not timestamp.
    public func writeFile(relativePath: String, data: Data, modificationDate: Date?) throws {
        // Belt and braces: never write a path the classifier would not let out
        // of the device in the first place. A malicious or corrupt remote record
        // name must not be able to place a file anywhere it likes.
        guard SyncClassifier.classify(relativePath: relativePath) != nil else {
            throw SyncProviderError.invalidData
        }
        let url = absoluteURL(for: relativePath)
        // Reject any path that escapes the root (`../`), which the classifier's
        // component rules make unlikely but do not forbid outright.
        guard CanonicalRelativePath.relativePath(of: url, under: rootDirectory) != nil else {
            throw SyncProviderError.invalidData
        }

        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
        if let modificationDate {
            try? fileManager.setAttributes([.modificationDate: modificationDate], ofItemAtPath: url.path)
        }
        // The bytes changed, so the cached digest is stale.
        checksumCache[relativePath] = nil
    }

    /// Drop the checksum cache — used when sync is turned off and back on.
    public func resetCache() {
        checksumCache.removeAll()
    }
}
