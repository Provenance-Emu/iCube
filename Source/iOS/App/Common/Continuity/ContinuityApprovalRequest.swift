// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// One owner decision. Cancellation and a late UI answer race through the same
/// main-actor gate, so exactly one result resumes the waiting server task.
@MainActor
final class ContinuityApprovalRequest<Decision: Sendable> {
    let id = UUID()

    private let cancellationValue: Decision
    private let onFinish: @MainActor (UUID) -> Void
    private var continuation: CheckedContinuation<Decision, Never>?
    private var result: Decision?

    init(cancellationValue: Decision, onFinish: @escaping @MainActor (UUID) -> Void) {
        self.cancellationValue = cancellationValue
        self.onFinish = onFinish
    }

    func wait() async -> Decision {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                    if Task.isCancelled { resolve(cancellationValue) }
                }
            }
        } onCancel: {
            Task { @MainActor in self.resolve(self.cancellationValue) }
        }
    }

    func resolve(_ decision: Decision) {
        guard result == nil else { return }
        result = decision
        let waiting = continuation
        continuation = nil
        onFinish(id)
        waiting?.resume(returning: decision)
    }
}
