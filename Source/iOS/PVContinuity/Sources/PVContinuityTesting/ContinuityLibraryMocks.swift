// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
//  Test doubles for nearby library sharing. Split from `ContinuityMocks.swift`
//  so the handoff doubles and the library doubles stay visibly separate — the
//  distinction between the two payloads is the security boundary this feature
//  turns on, and it should be legible in the test scaffolding too.

import Foundation
import PVContinuity

// MARK: - Library provider

/// A library provider a test can make **hostile**: `setGameFile` accepts a
/// descriptor of any kind, so a builder that trusted the provider's label
/// instead of checking it would visibly leak.
public actor MockLibraryProvider: ContinuityLibraryProviding {
    private var entries: [ContinuityLibraryEntry]
    private var excluded: Set<String>
    private var artwork: [String: Data]
    private var gameFiles: [String: FileDescriptor]
    private let root: URL

    public init(
        entries: [ContinuityLibraryEntry] = [],
        root: URL = URL(fileURLWithPath: "/tmp/icube-library-mock")
    ) {
        self.entries = entries
        self.excluded = []
        self.artwork = [:]
        self.gameFiles = [:]
        self.root = root
    }

    public func setEntries(_ entries: [ContinuityLibraryEntry]) {
        self.entries = entries
    }

    public func setExcluded(_ excluded: Set<String>) {
        self.excluded = excluded
    }

    public func setArtwork(_ data: Data?, forKey key: String) {
        artwork[key] = data
    }

    public func setGameFile(_ descriptor: FileDescriptor?, forKey key: String) {
        gameFiles[key] = descriptor
    }

    public func allEntries() async -> [ContinuityLibraryEntry] {
        entries
    }

    public func isExcludedFromSharing(key: String) async -> Bool {
        excluded.contains(key)
    }

    public func artworkPNG(forKey key: String) async -> Data? {
        artwork[key]
    }

    public func gameFileDescriptor(forKey key: String) async -> FileDescriptor? {
        gameFiles[key]
    }

    public func fileURL(for descriptor: FileDescriptor) async throws -> URL {
        root.appendingPathComponent(descriptor.relativePath)
    }
}

// MARK: - Library pull approver

public actor MockLibraryPullApprover: ContinuityLibraryPullApproving {
    private var decision: ContinuityLibraryPullDecision
    /// How many times the owner was actually prompted. The number that proves
    /// `.everything` never prompts and `.askPerGame` prompts **once** per
    /// peer+game rather than once per HTTP request.
    public private(set) var promptCount = 0
    public private(set) var lastPeerName: String?
    public private(set) var lastGameName: String?

    public init(decision: ContinuityLibraryPullDecision) {
        self.decision = decision
    }

    public func setDecision(_ decision: ContinuityLibraryPullDecision) {
        self.decision = decision
    }

    public func approveLibraryPull(
        peerName: String, gameName: String
    ) async -> ContinuityLibraryPullDecision {
        promptCount += 1
        lastPeerName = peerName
        lastGameName = gameName
        return decision
    }
}

// MARK: - In-memory grant store

/// `FileLibraryGrantStore` without the file, so grant-enforcement tests need no
/// scratch directory and no I/O.
public actor MemoryLibraryGrantStore: ContinuityLibraryGrantStore {
    private var grants: [String: ContinuityLibraryGrant]

    public init(grants: [String: ContinuityLibraryGrant] = [:]) {
        self.grants = grants
    }

    public func grant(forPeerId id: String) async -> ContinuityLibraryGrant? {
        grants[id]
    }

    public func setGrant(_ grant: ContinuityLibraryGrant, forPeerId id: String) async {
        grants[id] = grant
    }

    public func removeGrant(forPeerId id: String) async {
        grants[id] = nil
    }

    public func removeAll() async {
        grants.removeAll()
    }

    public func allGrants() async -> [String: ContinuityLibraryGrant] {
        grants
    }
}
