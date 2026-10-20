// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import PVContinuity

/// App policy around the shared transport. Only the library file route may
/// wait for owner approval before its first byte; ordinary browsing stays fast.
struct ICubeContinuityTransport: ContinuityTransport {
    private let base: any ContinuityTransport
    private let approval: any ContinuityTransport

    init(
        base: any ContinuityTransport = URLSessionContinuityTransport(),
        approval: (any ContinuityTransport)? = nil
    ) {
        self.base = base
        if let approval {
            self.approval = approval
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = ContinuityLibraryServer.approvalTimeout + 15
            configuration.timeoutIntervalForResource = 3600
            configuration.waitsForConnectivity = false
            self.approval = URLSessionContinuityTransport(session: URLSession(configuration: configuration))
        }
    }

    func request(_ request: ContinuityRequest) async throws -> ContinuityResponse {
        try Task.checkCancellation()
        let response = try await transport(for: request).request(request)
        try Task.checkCancellation()
        return response
    }

    func download(
        _ request: ContinuityRequest,
        to destination: URL,
        resumeOffset: Int64,
        progress: (@Sendable (Int64, Int64?) -> Void)?
    ) async throws -> Int64 {
        try Task.checkCancellation()
        let bytes = try await transport(for: request).download(
            request, to: destination, resumeOffset: resumeOffset, progress: progress
        )
        // The shared puller verifies and moves immediately after this returns.
        // Keep a cancelled final chunk in .part even if the delegate succeeds.
        try Task.checkCancellation()
        return bytes
    }

    private func transport(for request: ContinuityRequest) -> any ContinuityTransport {
        request.url.path == ContinuityRoutes.libraryFile ? approval : base
    }
}
