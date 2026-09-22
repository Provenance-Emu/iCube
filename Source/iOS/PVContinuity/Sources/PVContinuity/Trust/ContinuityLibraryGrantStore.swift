// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What a host lets one specific peer do with its library.
///
/// `.everything` and `.askPerGame` both browse silently once trusted;
/// Ask-Per-Game's control point is the per-pull approval prompt, not
/// re-consenting to every browse. Re-prompting on browse would train users to
/// dismiss the prompt, which is exactly what makes the per-pull one worthless.
public enum ContinuityLibraryGrant: String, Codable, Sendable, CaseIterable {
    case everything
    case askPerGame
    case denied
}

/// Persistence seam for per-peer library grants.
///
/// Deliberately **separate** from `ContinuityTrustStore`: a denied peer has to
/// be remembered without becoming trusted, and trust-store membership is what
/// authorises game pulls. Folding the two together would mean the act of
/// remembering "no" granted access.
public protocol ContinuityLibraryGrantStore: Sendable {
    func grant(forPeerId id: String) async -> ContinuityLibraryGrant?
    func setGrant(_ grant: ContinuityLibraryGrant, forPeerId id: String) async
    func removeGrant(forPeerId id: String) async
    func removeAll() async
    /// Every remembered decision. Needed so the owner can **see and undo**
    /// them: a "Don't Share" is persisted forever, and with no way to list it a
    /// single mis-tap would kill the feature for that peer with no recovery
    /// short of reinstalling.
    func allGrants() async -> [String: ContinuityLibraryGrant]
}

/// JSON-file grant store, mirroring `FileTrustStore`. Plain storage is fine —
/// the file holds no key material, just peerId → grant strings.
public actor FileLibraryGrantStore: ContinuityLibraryGrantStore {
    private let fileURL: URL
    private var cached: [String: ContinuityLibraryGrant]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func grant(forPeerId id: String) -> ContinuityLibraryGrant? {
        load()[id]
    }

    public func setGrant(_ grant: ContinuityLibraryGrant, forPeerId id: String) {
        var grants = load()
        grants[id] = grant
        save(grants)
    }

    public func removeGrant(forPeerId id: String) {
        var grants = load()
        grants[id] = nil
        save(grants)
    }

    public func removeAll() {
        save([:])
    }

    public func allGrants() -> [String: ContinuityLibraryGrant] {
        load()
    }

    private func load() -> [String: ContinuityLibraryGrant] {
        if let cached { return cached }
        let grants = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: ContinuityLibraryGrant].self, from: $0) } ?? [:]
        cached = grants
        return grants
    }

    private func save(_ grants: [String: ContinuityLibraryGrant]) {
        cached = grants
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(grants).write(to: fileURL, options: .atomic)
        } catch {
            assertionFailure("FileLibraryGrantStore write failed: \(error)")
        }
    }
}
