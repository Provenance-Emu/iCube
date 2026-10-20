// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import PVContinuity

/// Binds the advertised peer selection to the auth challenge before the client
/// signs it. This is an identity-consistency check, not server proof of key
/// possession: the existing LAN HTTP protocol does not sign server responses.
final class PeerBoundContinuityTransport: ContinuityTransport, @unchecked Sendable {
    private let base: any ContinuityTransport
    private let lock = NSLock()
    private var expectedPeerID: String?

    init(base: any ContinuityTransport) { self.base = base }

    func setExpectedPeerID(_ peerID: String?) {
        lock.lock(); defer { lock.unlock() }
        expectedPeerID = peerID
    }

    private func selectedPeerID() -> String? {
        lock.lock(); defer { lock.unlock() }
        return expectedPeerID
    }

    func request(_ request: ContinuityRequest) async throws -> ContinuityResponse {
        let expected = selectedPeerID()
        let response = try await base.request(request)
        try Task.checkCancellation()
        if response.status == 200,
           request.url.path == ContinuityRoutes.libraryAuthStart || request.url.path == ContinuityRoutes.authStart,
           let expected {
            let challenge = try response.decoded(ContinuityPairingMessages.AuthStartResponse.self)
            guard challenge.serverId == expected else { throw ContinuityError.tokenRejected }
        }
        return response
    }

    func download(_ request: ContinuityRequest, to destination: URL, resumeOffset: Int64,
                  progress: (@Sendable (Int64, Int64?) -> Void)?) async throws -> Int64 {
        try await base.download(request, to: destination, resumeOffset: resumeOffset, progress: progress)
    }
}
