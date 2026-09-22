// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVSyncRules

/// Where one file stands relative to the cloud copy.
public enum SyncStatus: String, Codable, Sendable, CaseIterable {
    /// Present here, not yet known to the cloud.
    case local
    case synced
    case uploading
    case downloading
    /// Both sides changed and the resolver could not decide.
    case conflict
    case error

    public var systemImageName: String {
        switch self {
        case .local: return "iphone"
        case .synced: return "checkmark.icloud.fill"
        case .uploading: return "icloud.and.arrow.up"
        case .downloading: return "icloud.and.arrow.down"
        case .conflict: return "exclamationmark.icloud.fill"
        case .error: return "xmark.icloud.fill"
        }
    }
}

/// Everything the sync engine knows about one file, on either side.
///
/// `relativePath` is the identity key: it is the CloudKit record name, so how it
/// is derived is load-bearing. Always produce it through `CanonicalRelativePath`
/// — see that type for the three separate bugs the naive version caused.
public struct SyncableFileMetadata: Identifiable, Codable, Hashable, Sendable {
    public var id: String { relativePath }

    /// Path relative to iCube's `User/` directory, `/`-separated, no leading slash.
    public var relativePath: String
    public var lastModified: Date
    public var fileSize: Int64
    /// SHA-256 of the contents, lowercase hex.
    public var checksum: String
    public var fileType: SyncableFileType
    public var syncStatus: SyncStatus
    public var lastSyncDate: Date?
    /// CloudKit record name once the file has been seen remotely.
    public var cloudKitRecordID: String?
    /// Device that last wrote the remote copy. Display only.
    public var lastModifiedDeviceID: String?
    public var syncAttempts: Int
    public var lastError: String?

    public init(
        relativePath: String,
        lastModified: Date,
        fileSize: Int64,
        checksum: String,
        fileType: SyncableFileType,
        syncStatus: SyncStatus = .local,
        lastSyncDate: Date? = nil,
        cloudKitRecordID: String? = nil,
        lastModifiedDeviceID: String? = nil,
        syncAttempts: Int = 0,
        lastError: String? = nil
    ) {
        self.relativePath = relativePath
        self.lastModified = lastModified
        self.fileSize = fileSize
        self.checksum = checksum
        self.fileType = fileType
        self.syncStatus = syncStatus
        self.lastSyncDate = lastSyncDate
        self.cloudKitRecordID = cloudKitRecordID
        self.lastModifiedDeviceID = lastModifiedDeviceID
        self.syncAttempts = syncAttempts
        self.lastError = lastError
    }
}

/// A file that changed on both sides and could not be resolved automatically.
public struct SyncConflict: Identifiable, Sendable, Equatable {
    public struct FileVersion: Sendable, Equatable {
        public let modifiedDate: Date
        public let size: Int64
        public let checksum: String

        public init(modifiedDate: Date, size: Int64, checksum: String) {
            self.modifiedDate = modifiedDate
            self.size = size
            self.checksum = checksum
        }
    }

    public let id: UUID
    public let metadata: SyncableFileMetadata
    public let localVersion: FileVersion
    public let remoteVersion: FileVersion
    public let detectedDate: Date

    public init(
        id: UUID = UUID(),
        metadata: SyncableFileMetadata,
        localVersion: FileVersion,
        remoteVersion: FileVersion,
        detectedDate: Date = Date()
    ) {
        self.id = id
        self.metadata = metadata
        self.localVersion = localVersion
        self.remoteVersion = remoteVersion
        self.detectedDate = detectedDate
    }

    /// Conflict for a local/remote metadata pair, filling both versions from them.
    public init(local: SyncableFileMetadata, remote: SyncableFileMetadata) {
        self.init(
            metadata: local,
            localVersion: FileVersion(
                modifiedDate: local.lastModified,
                size: local.fileSize,
                checksum: local.checksum
            ),
            remoteVersion: FileVersion(
                modifiedDate: remote.lastModified,
                size: remote.fileSize,
                checksum: remote.checksum
            )
        )
    }
}

/// How a conflict is to be settled.
public enum ConflictResolution: Sendable, Equatable {
    case useLocal
    case useRemote
    case keepBoth
    case manual(SyncConflict)
}

/// Counts for the settings pane, broken out per category so the user can see
/// *what* is syncing rather than just a total.
public struct SyncStatistics: Sendable, Equatable {
    public var totalFiles: Int = 0
    public var syncedFiles: Int = 0
    public var pendingFiles: Int = 0
    public var conflictFiles: Int = 0
    public var errorFiles: Int = 0
    public var totalSize: Int64 = 0
    public var lastSyncDate: Date?

    /// Per-category file counts. Keyed by category so adding a
    /// `SyncableFileType` case never means editing this struct.
    public var countsByType: [SyncableFileType: Int] = [:]
    /// Per-category byte totals.
    public var bytesByType: [SyncableFileType: Int64] = [:]

    public init() {}

    public var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    /// Recompute every field from a metadata snapshot plus the live conflict list.
    public static func summarize(
        _ files: some Collection<SyncableFileMetadata>,
        conflictCount: Int,
        lastSyncDate: Date?
    ) -> SyncStatistics {
        var stats = SyncStatistics()
        stats.totalFiles = files.count
        stats.lastSyncDate = lastSyncDate
        stats.conflictFiles = conflictCount
        for file in files {
            switch file.syncStatus {
            case .synced: stats.syncedFiles += 1
            case .uploading, .downloading, .local: stats.pendingFiles += 1
            case .error: stats.errorFiles += 1
            case .conflict: break
            }
            stats.totalSize += file.fileSize
            stats.countsByType[file.fileType, default: 0] += 1
            stats.bytesByType[file.fileType, default: 0] += file.fileSize
        }
        return stats
    }
}

/// One line in the sync log surfaced by the settings pane.
public struct SyncEvent: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable {
        case upload
        case download
        case conflict
        case error
        case success
        case info
    }

    public let id: UUID
    public let timestamp: Date
    public let kind: Kind
    public let file: String?
    public let message: String

    public init(kind: Kind, file: String? = nil, message: String, timestamp: Date = Date()) {
        self.id = UUID()
        self.timestamp = timestamp
        self.kind = kind
        self.file = file
        self.message = message
    }
}
