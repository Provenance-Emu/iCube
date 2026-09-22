// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

// MARK: - File provision

/// Whether the receiving device already has a manifest entry.
public enum LocalFileStatus: Sendable, Equatable {
    /// Not on disk — must be pulled.
    case missing
    /// On disk with a matching checksum — skip it.
    case presentMatching
    /// On disk but different content (a newer local save, a different dump).
    /// The pull plan treats this as needing transfer; the app owns the
    /// overwrite policy.
    case presentDiffering
}

/// Bridges the kit to iCube's file layout. The app adapter knows about the
/// User directory, `StateSaves/`, the GameCube memory-card folders, the Wii
/// NAND save subtree and the `Software/` ROM directory.
///
/// Every path crossing this protocol is **User-directory-relative** — see the
/// coordinate-space note on `FileDescriptor`.
public protocol ContinuityFileProviding: Sendable {
    /// Every file of `kind` belonging to `identity`. Serving side.
    func enumerate(kind: ContinuityFileKind, identity: GameIdentity) async throws -> [FileDescriptor]
    /// Absolute URL for a descriptor this device serves. Serving side.
    func fileURL(for descriptor: FileDescriptor) async throws -> URL
    /// Whether this device already has the descriptor's file. Receiving side.
    func localStatus(of descriptor: FileDescriptor) async -> LocalFileStatus
    /// Absolute URL a pulled descriptor must land at — the same relative path
    /// as on the source device, under this device's User directory. Creating
    /// intermediate directories is the implementation's job.
    func destinationURL(for descriptor: FileDescriptor) async throws -> URL
}

// MARK: - Save-state minting

/// Produces a fresh save state for the running game on demand.
///
/// Minting is lazy: the receiving device's call to the mint route triggers it,
/// so the state is seconds old when it is pulled. The alternative — a periodic
/// autosave kept warm in case somebody hands off — costs every user a
/// background write they almost never use.
///
/// The implementation pauses the emulator, saves, and reports the **core's**
/// filename stem. See the stem rule on `SaveStateDescriptor`.
public protocol SaveStateMinting: Sendable {
    func mintHandoffState(identity: GameIdentity) async throws -> SaveStateDescriptor
}

// MARK: - Library resolution

/// A game already present on the receiving device.
public struct LocalGameMatch: Sendable, Equatable {
    public var strength: IdentityMatchStrength
    /// User-directory-relative path of the local game file.
    public var gameRelativePath: String
    /// Whether any local save state exists for this game — the
    /// `bootWithLatestLocalState` rung of the fallback ladder depends on it.
    public var hasLocalSaveState: Bool

    public init(strength: IdentityMatchStrength, gameRelativePath: String, hasLocalSaveState: Bool) {
        self.strength = strength
        self.gameRelativePath = gameRelativePath
        self.hasLocalSaveState = hasLocalSaveState
    }
}

/// Resolves a remote identity against the local library using
/// `GameIdentity.match(against:)`.
public protocol LibraryQuerying: Sendable {
    func resolveLocalGame(_ identity: GameIdentity) async -> LocalGameMatch?
}

// MARK: - Approval hooks

/// Host-side hook that shows the pairing prompt (peer name + 6-digit code) and
/// resolves with the user's answer. The server races it against the pairing
/// lifetime, so an implementation that can never present must not deadlock —
/// returning late is fine, returning never is handled.
public protocol ContinuityPairingApproving: Sendable {
    func approvePairing(peerName: String, code: String) async -> Bool
}

// MARK: - Advertising

/// Broadcasts an active handoff session so other devices can find it.
///
/// The app supplies platform implementations: `NSUserActivity` (Handoff, on
/// iOS/iPadOS/macOS) and a Bonjour TXT record. **tvOS has no system Handoff**,
/// so Bonjour is its only discovery path — which is why the Bonjour
/// advertiser is not an iOS-conditional extra.
public protocol ContinuityAdvertising: Sendable {
    func publish(_ advertisement: ContinuityAdvertisement) async
    func withdraw() async
}
