// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One file the engine removed because of a remote delete.
public struct SyncTrashEntry: Identifiable, Equatable, Sendable {
    /// `"<epoch ms>/<relative path>"`, unique per deletion.
    public let id: String
    /// Path relative to the `User/` directory the file came from.
    public let relativePath: String
    public let deletedAt: Date
    public let fileSize: Int64
    /// Where the bytes sit now.
    public let url: URL
}

/// Where a locally removed file goes instead of being unlinked.
///
/// Every delete the engine performs on this device passes through here, and
/// nothing is unlinked outright. A user who sees a save vanish because another
/// device deleted it has 30 days to get it back from Settings.
///
/// Layout: `<root>/<epoch ms>/<relative path>`. The folder name carries the
/// deletion time so no sidecar is needed, and the relative path is preserved so
/// a restore is a move back to the same place.
public actor SyncTrash {

    public let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    // MARK: - Moving in

    /// Move a file into the trash. The source must be inside the User tree the
    /// relative path describes; the caller passes both because the trash does
    /// not know where `User/` is.
    @discardableResult
    public func move(fileAt source: URL, relativePath: String, now: Date = Date()) throws -> SyncTrashEntry {
        let stamp = Self.stamp(for: now)
        let destination = rootURL
            .appendingPathComponent(stamp, isDirectory: true)
            .appendingPathComponent(relativePath)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Two deletes of the same path inside one millisecond would collide;
        // keep the earlier one rather than failing the sync.
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
        let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        return SyncTrashEntry(
            id: "\(stamp)/\(relativePath)",
            relativePath: relativePath,
            deletedAt: Self.date(fromStamp: stamp) ?? now,
            fileSize: size,
            url: destination
        )
    }

    // MARK: - Listing

    /// Every trashed file, newest first.
    public func entries() -> [SyncTrashEntry] {
        guard let stamps = try? fileManager.contentsOfDirectory(atPath: rootURL.path) else { return [] }
        var result: [SyncTrashEntry] = []
        for stamp in stamps {
            guard let deletedAt = Self.date(fromStamp: stamp) else { continue }
            let folder = rootURL.appendingPathComponent(stamp, isDirectory: true)
            result += entries(inStampFolder: folder, stamp: stamp, deletedAt: deletedAt)
        }
        return result.sorted { $0.deletedAt > $1.deletedAt }
    }

    /// Regular files under one stamp folder.
    private func entries(inStampFolder folder: URL, stamp: String, deletedAt: Date) -> [SyncTrashEntry] {
        var result: [SyncTrashEntry] = []
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard let relative = CanonicalRelativePath.relativePath(of: url, under: folder) else { continue }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            // Rebuild the URL from our own root rather than using the
            // enumerator's, which may come back symlink-resolved
            // (`/private/var` vs `/var`) and then not compare equal to the
            // URL `move` handed out.
            result.append(SyncTrashEntry(
                id: "\(stamp)/\(relative)",
                relativePath: relative,
                deletedAt: deletedAt,
                fileSize: size,
                url: folder.appendingPathComponent(relative)
            ))
        }
        return result
    }

    // MARK: - Restoring and purging

    /// Put a trashed file back under `userRoot`, replacing whatever is there.
    /// The restored file gets the current time as its modification date so the
    /// next sync reads it as an undelete and uploads it.
    public func restore(_ entry: SyncTrashEntry, into userRoot: URL, now: Date = Date()) throws {
        let destination = userRoot.appendingPathComponent(entry.relativePath)
        guard CanonicalRelativePath.relativePath(of: destination, under: userRoot) != nil else {
            throw SyncProviderError.invalidData
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: entry.url, to: destination)
        try? fileManager.setAttributes([.modificationDate: now], ofItemAtPath: destination.path)
        pruneEmptyFolders(under: entry.url.deletingLastPathComponent())
    }

    /// Remove one entry for good.
    public func delete(_ entry: SyncTrashEntry) throws {
        try fileManager.removeItem(at: entry.url)
        pruneEmptyFolders(under: entry.url.deletingLastPathComponent())
    }

    /// Remove every entry deleted before `cutoff`. Returns how many went.
    @discardableResult
    public func purge(olderThan cutoff: Date) -> Int {
        guard let stamps = try? fileManager.contentsOfDirectory(atPath: rootURL.path) else { return 0 }
        var removed = 0
        for stamp in stamps {
            guard let deletedAt = Self.date(fromStamp: stamp), deletedAt < cutoff else { continue }
            let folder = rootURL.appendingPathComponent(stamp, isDirectory: true)
            let count = entries(inStampFolder: folder, stamp: stamp, deletedAt: deletedAt).count
            if (try? fileManager.removeItem(at: folder)) != nil {
                removed += count
            }
        }
        return removed
    }

    /// Total bytes held.
    public func totalSize() -> Int64 {
        entries().reduce(0) { $0 + $1.fileSize }
    }

    // MARK: - Stamps

    private static func stamp(for date: Date) -> String {
        String(Int64((date.timeIntervalSince1970 * 1000).rounded()))
    }

    private static func date(fromStamp stamp: String) -> Date? {
        guard let millis = Int64(stamp) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }

    /// Walk up from `folder` to the trash root removing empty directories, so a
    /// restored or deleted entry does not leave a trail of empty stamp folders.
    private func pruneEmptyFolders(under folder: URL) {
        var current = folder.standardizedFileURL
        let root = rootURL.standardizedFileURL
        while current.path.hasPrefix(root.path), current.path != root.path {
            guard let contents = try? fileManager.contentsOfDirectory(atPath: current.path), contents.isEmpty else { return }
            try? fileManager.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }
}
