// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVContinuity
import PVLibrarySnapshot

/// One incoming `dolphinios://requestGame` ask, awaiting the user's decision.
struct EcosystemShareRequest: Identifiable {
    let id = UUID()
    let game: LibrarySnapshotGame
    let callbackScheme: String
}

/// Handles `dolphinios://requestGame` (a peer app wants a game's file set):
/// surfaces a confirm prompt, and on approval opens a non-advertised
/// continuity session for the game and answers the peer with a FetchPayload
/// callback — the peer then downloads over HTTP with the session's bearer
/// token.
///
/// File transfer to another app is deliberately user-confirmed every time,
/// even between Joe's own apps — the requesting URL is attacker-forgeable.
@MainActor
final class EcosystemShareCenter: ObservableObject {
    static let shared = EcosystemShareCenter()

    @Published var request: EcosystemShareRequest?

    /// Non-nil when an OUTGOING share couldn't be delivered (the continuity
    /// session failed to start, or the peer's callback URL wouldn't open).
    /// Surfaced as an alert by `EcosystemShareApprovalModifier` so a "Send to
    /// Provenance" tap always produces visible feedback instead of silently
    /// doing nothing.
    @Published var shareError: String?

    private init() {}

    /// How long the share session stays up for the peer's download. A
    /// continue-session (handoff) started meanwhile replaces it — the
    /// sessionId guard in `endEcosystemShareIfCurrent` keeps this timer from
    /// killing THAT one.
    static let shareSessionLifetime: TimeInterval = 30 * 60

    /// Entry point from `EcosystemBridge.perform`.
    func handleRequest(gameID: String, callbackScheme: String) {
        guard let game = EcosystemBridge.game(forID: gameID) else { return }
        // One ask at a time; a second requester is dropped (it can retry).
        guard request == nil else { return }
        request = EcosystemShareRequest(game: game, callbackScheme: callbackScheme)
    }

    func deny() {
        request = nil
    }

    /// Friendly peer name for user-facing messages ("provenance" → "Provenance").
    static func peerName(_ scheme: String) -> String {
        scheme.lowercased() == EcosystemSchemes.provenanceScheme ? "Provenance" : "\(scheme)://"
    }

    func approve() {
        guard let request else { return }
        self.request = nil
        beginShare(game: request.game, callbackScheme: request.callbackScheme)
    }

    /// User-initiated push ("Send to Provenance" in the game context menu) —
    /// the same machinery as an approved incoming request, just started from
    /// this side. The receiver is stateless (Provenance's
    /// `EcosystemFetchParser` accepts any `<scheme>://dolphinios?fetch=`
    /// callback), so no prior handshake is needed. No confirm prompt either:
    /// the user's tap IS the consent.
    func send(gameID: String, toScheme scheme: String = EcosystemSchemes.provenanceScheme) {
        guard let game = EcosystemBridge.game(forID: gameID) else {
            shareError = "That game isn\u{2019}t in the library snapshot yet. Try again in a moment."
            return
        }
        beginShare(game: game, callbackScheme: scheme)
    }

    private func beginShare(game: LibrarySnapshotGame, callbackScheme: String) {
        Task {
            guard let (session, candidates) = await ContinuityManager.shared.beginEcosystemShare(gameID: game.id) else {
                shareError = "Couldn\u{2019}t start the share session for \u{201C}\(game.title)\u{201D}. Please try again."
                return
            }
            scheduleSessionEnd(sessionId: session.sessionId)
            let payload = EcosystemBridge.FetchPayload(
                name: game.title,
                md5: EcosystemBridge.transferId(gameID: game.id, filename: game.filename),
                bases: candidates.map(\.absoluteString),
                manifestPath: ContinuityRoutes.manifest,
                filePath: ContinuityRoutes.file,
                fileQueryKey: ContinuityRoutes.filePathQueryKey,
                token: session.token
            )
            guard let data = try? JSONEncoder().encode(payload) else { return }
            EcosystemBridge.openCallback(
                scheme: callbackScheme,
                query: "fetch",
                value: EcosystemBridge.base64url(data)
            ) { success in
                guard !success else { return }
                Task { @MainActor in
                    EcosystemShareCenter.shared.shareError =
                        "Couldn\u{2019}t open \(EcosystemShareCenter.peerName(callbackScheme)). Make sure it\u{2019}s installed and up to date, then try again."
                }
            }
        }
    }

    /// Ends the share session after its lifetime, unless a newer session
    /// (another share, or a real handoff) already replaced it.
    private func scheduleSessionEnd(sessionId: String) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.shareSessionLifetime * 1_000_000_000))
            await ContinuityManager.shared.endEcosystemShareIfCurrent(sessionId: sessionId)
        }
    }
}
