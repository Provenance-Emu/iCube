// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import PVLibrarySnapshot

/// Pure random-pick logic for `PlayRandomGameIntent`, separated out so it's testable with a
/// seeded `RandomNumberGenerator` (production callers pass `SystemRandomNumberGenerator()`).
enum RandomGameSelector {
    /// Sorts candidates by id first so a seeded generator picks reproducibly in tests — a
    /// `Dictionary`'s iteration order is not stable across runs.
    static func pick(from snapshot: LibrarySnapshot, using generator: inout some RandomNumberGenerator) -> LibrarySnapshotGame? {
        snapshot.byGameID.values
            .sorted { $0.id < $1.id }
            .randomElement(using: &generator)
    }
}
