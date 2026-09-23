// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
@testable import PVCloudSync

/// Regression tests for the three bugs documented in `CanonicalRelativePath`'s
/// doc comment. The relative path it returns becomes the CloudKit record name,
/// so a wrong answer here is a silent data-loss bug, not a cosmetic one.
final class CanonicalRelativePathTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanonicalRelativePathTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The core case: a file directly under the root resolves to its bare name.
    func testDirectChild() throws {
        let file = root.appendingPathComponent("Config/Dolphin.ini")
        XCTAssertEqual(
            CanonicalRelativePath.relativePath(of: file, under: root),
            "Config/Dolphin.ini"
        )
    }

    /// Bug 1: mixed path forms. `FileManager` enumeration hands back
    /// `/private/var/…` while a container URL is `/var/…` (on a system where
    /// `/var` is a symlink to `/private/var`, which is true of every Apple
    /// platform this ships on). The naive substring-strip glues the orphaned
    /// prefix onto the result; canonicalizing both sides first must not.
    ///
    /// `/tmp` is a symlink to `/private/tmp` on every Apple platform, which is
    /// exactly the mismatch the doc comment describes — no synthetic symlink
    /// needed. `resolvingSymlinksInPath()` only collapses components that
    /// actually exist on disk, so both the directory and the file underneath
    /// it are created for real rather than only constructing `URL` values.
    func testMixedPrivateVarAndVarFormsResolveToTheSameRelativePath() throws {
        let unique = "PVCloudSyncTests-\(UUID().uuidString)"
        let rawRoot = URL(fileURLWithPath: "/tmp/\(unique)", isDirectory: true)
        let privateRoot = URL(fileURLWithPath: "/private/tmp/\(unique)", isDirectory: true)
        let file = privateRoot.appendingPathComponent("StateSaves/GALE01.s01")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data([0x42]).write(to: file)
        defer { try? FileManager.default.removeItem(at: privateRoot) }

        let viaRawRoot = CanonicalRelativePath.relativePath(of: file, under: rawRoot)
        let viaPrivateRoot = CanonicalRelativePath.relativePath(of: file, under: privateRoot)

        XCTAssertEqual(viaRawRoot, "StateSaves/GALE01.s01")
        XCTAssertEqual(viaPrivateRoot, "StateSaves/GALE01.s01")
        XCTAssertEqual(viaRawRoot, viaPrivateRoot, "the same file must canonicalize identically regardless of which form of the root was used")
    }

    /// Bug 2: `replacingOccurrences` has no notion of a prefix, so if the root's
    /// absolute path recurs verbatim inside the relative portion, a naive
    /// implementation strips both occurrences. `CanonicalRelativePath` must
    /// strip only the leading instance.
    func testRootPathRecurringInsideTheRelativePortionIsOnlyStrippedOnce() throws {
        // Root ends in a component name that also appears further down the tree.
        let nestedRoot = root.appendingPathComponent("User", isDirectory: true)
        let file = nestedRoot.appendingPathComponent("Backups/User/GALE01.s01")

        XCTAssertEqual(
            CanonicalRelativePath.relativePath(of: file, under: nestedRoot),
            "Backups/User/GALE01.s01"
        )
    }

    /// A file outside the root entirely must never produce a mangled or partial
    /// string — only nil.
    func testFileOutsideRootReturnsNil() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("sibling/file.ini")
        XCTAssertNil(CanonicalRelativePath.relativePath(of: outside, under: root))
    }

    /// The root itself is not "a file relative to the root".
    func testFileIsTheRootReturnsNil() throws {
        XCTAssertNil(CanonicalRelativePath.relativePath(of: root, under: root))
    }

    /// A sibling directory whose name merely starts with the root's name must
    /// not be treated as inside it — this is what the trailing separator in the
    /// prefix check exists for (`/a/User` vs `/a/User2/x`).
    func testSiblingWithPrefixedNameIsNotTreatedAsInsideTheRoot() throws {
        let userRoot = root.appendingPathComponent("User", isDirectory: true)
        let siblingFile = root.appendingPathComponent("User2/file.ini")
        XCTAssertNil(CanonicalRelativePath.relativePath(of: siblingFile, under: userRoot))
    }

    /// Nested subdirectories round-trip too, not just one level deep.
    func testDeeplyNestedFile() throws {
        let file = root.appendingPathComponent("Wii/title/00010000/GALE01/data/banner.bin")
        XCTAssertEqual(
            CanonicalRelativePath.relativePath(of: file, under: root),
            "Wii/title/00010000/GALE01/data/banner.bin"
        )
    }
}
