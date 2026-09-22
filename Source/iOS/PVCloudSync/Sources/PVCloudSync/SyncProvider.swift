// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Why sync is not running. Surfaced verbatim in the settings pane: "off" with
/// no explanation is the failure mode this exists to prevent.
public enum SyncUnavailableReason: Sendable, Equatable {
    /// The CloudKit container has not been provisioned in the developer account
    /// and the entitlements do not request it. This is the state iCube ships in
    /// until that work is done — see `CloudSyncConstants`.
    case containerNotProvisioned
    /// `CKContainer(identifier:)` would trap on this build (simulator, or an
    /// ad-hoc re-signed build whose iCloud entitlement was stripped).
    case entitlementMissing
    case notSignedIn
    case accountRestricted
    case accountTemporarilyUnavailable
    case networkUnavailable
    case unknown(String)

    /// User-facing text. Kept here rather than in the view so the app target and
    /// any future headless caller say the same thing.
    public var localizedDescription: String {
        switch self {
        case .containerNotProvisioned:
            return "iCloud sync is not available in this build yet."
        case .entitlementMissing:
            return "This build is not signed for iCloud, so sync is off."
        case .notSignedIn:
            return "Sign in to iCloud in Settings to enable sync."
        case .accountRestricted:
            return "iCloud is restricted on this device."
        case .accountTemporarilyUnavailable:
            return "iCloud is temporarily unavailable. Sync will resume by itself."
        case .networkUnavailable:
            return "No network connection. Changes will sync when you are back online."
        case .unknown(let detail):
            return detail
        }
    }
}

/// Errors a provider can raise.
public enum SyncProviderError: LocalizedError, Equatable {
    case unavailable(SyncUnavailableReason)
    case fileNotFound
    case invalidData
    case uploadFailed(String)
    case downloadFailed(String)
    case quotaExceeded

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason.localizedDescription
        case .fileNotFound: return "File not found in iCloud."
        case .invalidData: return "The cloud copy of this file was unreadable."
        case .uploadFailed(let detail): return "Upload failed: \(detail)"
        case .downloadFailed(let detail): return "Download failed: \(detail)"
        case .quotaExceeded: return "iCloud storage is full. Free up space to keep syncing."
        }
    }
}

/// A sync backend. CloudKit is the only real implementation; `InertSyncProvider`
/// stands in whenever CloudKit cannot be used, so the coordinator never has to
/// branch on availability.
public protocol SyncProvider: Actor {
    /// For logging and the settings pane.
    nonisolated var providerName: String { get }

    /// `nil` when the provider is ready, otherwise why it is not.
    func unavailableReason() async -> SyncUnavailableReason?

    /// Prepare the backend (account check, zone creation). Throws
    /// `SyncProviderError.unavailable` when it cannot.
    func initialize() async throws

    func upload(metadata: SyncableFileMetadata, data: Data) async throws
    func download(metadata: SyncableFileMetadata) async throws -> Data

    /// Every record currently in the zone.
    func fetchRemoteMetadata() async throws -> [SyncableFileMetadata]

    /// Remove every remote record. Local files are never touched.
    func purgeAllData() async throws
}

/// The provider used when CloudKit is unusable: unprovisioned container, missing
/// entitlement, simulator.
///
/// iFly degrades by swapping in its iCloud-Drive provider; iCube has nothing to
/// swap to, so "off" has to be a first-class provider rather than an optional
/// that every call site checks. It reports its reason, answers an empty remote,
/// and refuses writes — so the coordinator runs its whole normal path, finds
/// nothing to do, and the settings pane shows why.
public actor InertSyncProvider: SyncProvider {
    public nonisolated let providerName = "Unavailable"
    private let reason: SyncUnavailableReason

    public init(reason: SyncUnavailableReason) {
        self.reason = reason
    }

    public func unavailableReason() async -> SyncUnavailableReason? { reason }

    public func initialize() async throws {
        throw SyncProviderError.unavailable(reason)
    }

    public func upload(metadata: SyncableFileMetadata, data: Data) async throws {
        throw SyncProviderError.unavailable(reason)
    }

    public func download(metadata: SyncableFileMetadata) async throws -> Data {
        throw SyncProviderError.unavailable(reason)
    }

    /// Empty, not an error: an empty remote is a legitimate state and the
    /// additive merge never deletes on the strength of it.
    public func fetchRemoteMetadata() async throws -> [SyncableFileMetadata] { [] }

    public func purgeAllData() async throws {}
}
