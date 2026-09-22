// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One transferable file.
///
/// ## Coordinate space — read this before adding a call site
///
/// `relativePath` is **relative to iCube's User directory** — the same root
/// `PVSyncRules.SyncClassifier` classifies against, and the same root
/// `File::GetUserPath(D_USER_IDX)` returns in the core. Examples:
/// `StateSaves/GALE01.s01`, `GC/USA/MemoryCardA.raw`, `Software/game.rvz`.
///
/// This is deliberately **not** "relative to the documents directory". On iOS
/// the User directory lives under Documents; on **tvOS it lives under Caches**
/// (see `PVWebServer.uploadRootDirectory`, and `UserFolderUtil`). Anchoring on
/// Documents would compile everywhere and silently resolve to the wrong place
/// on tvOS — which is the platform where Bonjour is the *only* discovery path,
/// so it is also the platform this feature is least likely to be smoke-tested
/// on before shipping.
///
/// The path is recreated verbatim on the receiving device. Save states bind to
/// games by filename stem, and per-game settings/memory cards bind by directory
/// layout, so the layout has to survive the trip intact.
public struct FileDescriptor: Codable, Hashable, Sendable {
    public var kind: ContinuityFileKind
    /// User-directory-relative path. See the type doc.
    public var relativePath: String
    /// Lowercase hex SHA-256 of the file's full contents.
    public var sha256: String
    public var size: Int64
    public var modifiedAt: Date?
    /// Whether the pull can be considered successful without this file.
    public var required: Bool

    public init(
        kind: ContinuityFileKind,
        relativePath: String,
        sha256: String,
        size: Int64,
        modifiedAt: Date? = nil,
        required: Bool = true
    ) {
        self.kind = kind
        self.relativePath = relativePath
        self.sha256 = sha256
        self.size = size
        self.modifiedAt = modifiedAt
        self.required = required
    }
}

/// Where a handoff came from, shown to the receiving user so "continue on this
/// device" names a device rather than an anonymous peer.
public struct SourceDevice: Codable, Hashable, Sendable {
    public var name: String
    /// `iOS`, `tvOS`, `macOS`.
    public var platform: String
    public var appVersion: String

    public init(name: String, platform: String, appVersion: String) {
        self.name = name
        self.platform = platform
        self.appVersion = appVersion
    }
}
