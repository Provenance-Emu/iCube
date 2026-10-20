// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Serializes local continuity writes across manual copy, mirror and handoff
/// controllers. A queued cancellation leaves the active transfer untouched.
@MainActor
final class ContinuityTransferGate {
    static let shared = ContinuityTransferGate()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var held = false
    private var waiters: [Waiter] = []

    func withPermit<Value>(_ body: @MainActor () async throws -> Value) async throws -> Value {
        try await acquire()
        defer { release() }
        // Cancellation can race a queued waiter being granted the permit.
        // Install release before checking, so that race cannot strand it.
        try Task.checkCancellation()
        return try await body()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard held else {
            held = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                self.waiters.remove(at: index).continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func release() {
        guard !waiters.isEmpty else {
            held = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }
}
