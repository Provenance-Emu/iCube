// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The serving side of nearby library sharing: what this device's library
/// holds, and how to turn one entry into bytes.
///
/// ## Why this is not `ContinuityFileProviding`
///
/// `ContinuityFileProviding` exists to describe a **handoff** payload, and a
/// handoff payload is the user's own save data following them to their own
/// second device. Its `enumerate(kind:identity:)` will happily hand back a
/// region-wide GameCube memory card or a slice of the Wii NAND, because for
/// that use that is correct.
///
/// Nearby library sharing is a different act with a different counterparty: the
/// peer may be a friend's device, and a friend browsing a library should get
/// **the game, not the owner's saves**. That is why this protocol has no
/// `kind:` parameter at all. There is no argument you can pass it that returns
/// a memory card, so no future call site can accidentally ask for one.
///
/// See `ICubeContinuityFileProvider`'s type doc for the concrete reason this
/// distinction is not theoretical: GameCube saves are region-wide images and
/// Wii saves live in a shared NAND, so "this game's saves" is never only this
/// game's saves.
public protocol ContinuityLibraryProviding: Sendable {
    /// Every title in the local library, **before** per-game exclusions are
    /// applied.
    ///
    /// Exclusion is deliberately not this method's job: it is applied once, by
    /// `ContinuityLibraryManifestBuilder`, so the catalog route and the file
    /// route cannot disagree about what is shared. An implementation that
    /// filtered here as well would make the builder's check look redundant,
    /// and the next person would delete one of them.
    func allEntries() async -> [ContinuityLibraryEntry]

    /// Whether the owner has excluded this entry from nearby sharing.
    ///
    /// Consulted **live** on every request rather than baked into
    /// `allEntries()`, so flipping the switch takes effect on a peer's very
    /// next request instead of at next launch.
    func isExcludedFromSharing(key: String) async -> Bool

    /// Cover art as PNG bytes, or nil when this device has none.
    ///
    /// Bytes rather than a `FileDescriptor` because iCube's cover art is
    /// produced in memory by the game-list cache, not stored as a file at a
    /// stable User-directory-relative path — and because artwork is
    /// deliberately *not* a `ContinuityFileKind`. Adding one would mean a
    /// second kind with no `SyncableFileType` counterpart, which is the
    /// invariant `ContinuityFileKind`'s type doc rests on.
    func artworkPNG(forKey key: String) async -> Data?

    /// The disc image for one entry, described for transfer, or nil when the
    /// entry is unknown or its file cannot be offered (it lives outside the
    /// User directory, say — see `ICubeContinuityFileProvider`).
    func gameFileDescriptor(forKey key: String) async -> FileDescriptor?

    /// Absolute URL of a descriptor this device serves.
    func fileURL(for descriptor: FileDescriptor) async throws -> URL
}

/// Host-side hook for the per-pull approval prompt that `.askPerGame` exists
/// for.
///
/// The prompt fires on a **pull**, never on a browse. Re-asking on every browse
/// would train the owner to dismiss the prompt reflexively, which is exactly
/// what makes the one that matters — "a peer wants to copy a game off this
/// device" — worthless. See the doc comment on `ContinuityLibraryGrant`.
///
/// Like `ContinuityPairingApproving`, the server races this against a timeout,
/// so an implementation that can never present must not deadlock; returning
/// late is fine, returning never is handled.
public protocol ContinuityLibraryPullApproving: Sendable {
    /// - Returns: the owner's answer. `nil` is not representable on purpose —
    ///   an unanswered prompt resolves as a decline at the server's timeout.
    func approveLibraryPull(peerName: String, gameName: String) async -> ContinuityLibraryPullDecision
}

/// What the owner chose when a peer asked to copy a game.
public enum ContinuityLibraryPullDecision: Sendable, Equatable {
    /// Allow this pull only. Nothing is persisted, so the next game asks again.
    case allowOnce
    /// Allow this and everything after: persists `.everything` for the peer.
    case allowAlways
    /// Refuse this pull. Nothing is persisted — the peer stays `.askPerGame`
    /// and a later request asks again, which is the right shape for "not right
    /// now".
    case denyOnce
    /// Refuse and persist `.denied`, which is what the review-and-revoke list
    /// in Settings exists to undo.
    case denyAlways
}
