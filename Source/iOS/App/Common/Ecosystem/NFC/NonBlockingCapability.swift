// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import os

/// A device capability read once on a background queue and cached. Readers never wait:
/// until the read returns, `value` is false. For system checks that can stall, such as
/// `NFCNDEFReaderSession.readingAvailable`, which SwiftUI bodies must not call directly.
final class NonBlockingCapability: Sendable {
    private enum State {
        case unread
        case reading
        case known(Bool)
    }

    private let read: @Sendable () -> Bool
    private let state = OSAllocatedUnfairLock(initialState: State.unread)

    init(read: @escaping @Sendable () -> Bool) {
        self.read = read
    }

    /// The cached answer, or false while it is unknown (which also starts the read).
    var value: Bool {
        let current = state.withLock { $0 }
        if case .known(let answer) = current { return answer }
        resolve()
        return false
    }

    /// Starts the background read unless it has already started.
    func resolve() {
        let shouldRead = state.withLock { current -> Bool in
            guard case .unread = current else { return false }
            current = .reading
            return true
        }
        guard shouldRead else { return }
        DispatchQueue.global(qos: .utility).async { [read, state] in
            let answer = read()
            state.withLock { $0 = .known(answer) }
        }
    }
}
