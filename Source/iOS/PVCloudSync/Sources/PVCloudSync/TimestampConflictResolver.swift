// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Decides which side of a two-sided change wins.
public protocol ConflictResolver: Sendable {
    func resolve(local: SyncableFileMetadata, remote: SyncableFileMetadata) -> ConflictResolution
}

/// Last-writer-wins by modification time, with a simultaneity window.
///
/// Ported from iFly (`TimestampConflictResolver.swift:8-29`). Three rules, in
/// this order:
///
/// 1. **Identical checksum wins immediately** when the two mtimes are within the
///    simultaneity window — the bytes are the same, so there is nothing to
///    transfer and nothing to ask the user about.
/// 2. **Differing checksums inside the window escalate to manual.** Two devices
///    writing the same file within five seconds is not something a timestamp can
///    adjudicate; guessing here is how somebody loses a save.
/// 3. **Otherwise last-writer-wins by mtime.**
///
/// Deliberately synchronous and pure — iFly's version is `async` for no reason
/// other than protocol shape, and that made it awkward to test.
public struct TimestampConflictResolver: ConflictResolver {

    /// Two writes this close together are "simultaneous" and cannot be ordered
    /// by timestamp.
    public let simultaneousThreshold: TimeInterval

    public init(simultaneousThreshold: TimeInterval = 5.0) {
        self.simultaneousThreshold = simultaneousThreshold
    }

    public func resolve(
        local: SyncableFileMetadata,
        remote: SyncableFileMetadata
    ) -> ConflictResolution {
        let timeDifference = abs(local.lastModified.timeIntervalSince(remote.lastModified))

        if timeDifference < simultaneousThreshold {
            // Same bytes: already in sync, no transfer either way.
            if local.checksum == remote.checksum {
                return .useLocal
            }
            // Same instant, different bytes — only a human can call this.
            return .manual(SyncConflict(local: local, remote: remote))
        }

        return local.lastModified > remote.lastModified ? .useLocal : .useRemote
    }
}
