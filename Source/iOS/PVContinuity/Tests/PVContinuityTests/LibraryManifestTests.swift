// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest
import PVContinuityTesting
@testable import PVContinuity

/// The security boundary for nearby library sharing, asserted rather than
/// documented.
///
/// A handoff payload carries the owner's saves on purpose: it is how a game
/// resumes on their own second device. GameCube saves live in **region-wide**
/// memory-card images and Wii saves in a **shared NAND tree**, so that payload
/// is unavoidably every game's saves for that region or on that NAND — fine
/// for your own device, catastrophic for a stranger who browsed your library
/// and copied one game.
///
/// `testLibraryManifestCarriesNoOwnerSaveData` is the test that makes the split
/// real. If somebody later "simplifies" the two builders back into one, or adds
/// a kind to `libraryUserDataKinds`, this is what stops it.
final class LibraryManifestTests: XCTestCase {

    private let device = SourceDevice(name: "Apple TV", platform: "tvOS", appVersion: "1.0")

    private func game(_ id: String = "GALE01", name: String = "Melee") -> GameIdentity {
        GameIdentity(gameID: id, displayName: name, platform: "gc", discNumber: 0, revision: 0)
    }

    private func descriptor(
        _ kind: ContinuityFileKind, _ path: String, size: Int64 = 1024
    ) -> FileDescriptor {
        FileDescriptor(kind: kind, relativePath: path, sha256: String(repeating: "a", count: 64), size: size)
    }

    private func makeBuilder(
        provider: MockLibraryProvider
    ) -> ContinuityLibraryManifestBuilder {
        ContinuityLibraryManifestBuilder(libraryProvider: provider, sourceDevice: device)
    }

    // MARK: - THE security test

    /// A library manifest must never contain a save state, a memory card, a Wii
    /// NAND file or a per-game INI.
    ///
    /// Asserted over `allDescriptors`, **not** `files`, because
    /// `ContinuityManifest.allDescriptors` appends the `saveState` field and is
    /// what the file route serves from — a manifest with an empty `files` and a
    /// populated `saveState` would leak exactly as effectively.
    func testLibraryManifestCarriesNoOwnerSaveData() async throws {
        let identity = game()
        let provider = MockLibraryProvider()
        await provider.setEntries([
            ContinuityLibraryEntry(game: identity, sizeBytes: 1_400_000_000, hasArtwork: true)
        ])
        await provider.setGameFile(
            descriptor(.gameFile, "Software/melee.rvz", size: 1_400_000_000),
            forKey: identity.stableKey
        )

        let manifest = try require(
            await makeBuilder(provider: provider)
                .manifest(forKey: identity.stableKey, sessionId: "s")
        )

        XCTAssertNil(manifest.saveState, "a library manifest must never mint or carry a save state")
        XCTAssertEqual(manifest.allDescriptors.count, 1, "a library pull is the disc image and nothing else")
        XCTAssertEqual(manifest.allDescriptors.first?.kind, .gameFile)

        let forbidden: Set<ContinuityFileKind> = [
            .saveState, .resumeState, .saveStateMetadata, .saveStateThumbnail,
            .gameCubeMemoryCard, .wiiSave, .config, .gameSettings
        ]
        for leaked in manifest.allDescriptors where forbidden.contains(leaked.kind) {
            XCTFail("library manifest leaked owner data: \(leaked.kind) at \(leaked.relativePath)")
        }
    }

    /// The contrast that proves the two builders really do differ: the same
    /// game, handed off, DOES carry the owner's memory card and per-game INI.
    ///
    /// Without this, `testLibraryManifestCarriesNoOwnerSaveData` could pass
    /// against a file provider that simply had no save data to offer, which
    /// would prove nothing at all.
    func testHandoffManifestDoesCarryOwnerSaveDataForContrast() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fileProvider = MockFileProvider(root: root)
        let card = FileDescriptor(
            kind: .gameCubeMemoryCard,
            relativePath: "GC/USA/MemoryCardA.raw",
            sha256: String(repeating: "b", count: 64),
            size: 16 * 1024 * 1024
        )
        await fileProvider.setEnumeration([card], for: .gameCubeMemoryCard)
        await fileProvider.setEnumeration(
            [descriptor(.gameFile, "Software/melee.rvz")], for: .gameFile
        )

        let handoff = try await ContinuityManifestBuilder(
            fileProvider: fileProvider, sourceDevice: device
        ).build(game: game(), sessionId: "s")

        XCTAssertTrue(
            handoff.allDescriptors.contains { $0.kind == .gameCubeMemoryCard },
            "handoff is SUPPOSED to carry the memory card — if this fails the contrast test is vacuous"
        )
    }

    /// `libraryUserDataKinds` is the named, empty counterpart to
    /// `handoffUserDataKinds`. Emptiness is the invariant, not an accident.
    func testLibraryUserDataKindsIsEmptyAndHandoffIsNot() {
        XCTAssertTrue(
            ContinuityLibraryManifestBuilder.libraryUserDataKinds.isEmpty,
            "a browsing peer gets the game, not the owner's saves — see the type doc before changing this"
        )
        XCTAssertFalse(ContinuityManifestBuilder.handoffUserDataKinds.isEmpty)
    }

    /// A provider that mislabels owner data as the game file is a bug, and the
    /// safe reading of a bug is "serve nothing".
    func testMislabelledDescriptorIsRefused() async throws {
        let identity = game()
        let provider = MockLibraryProvider()
        await provider.setEntries([
            ContinuityLibraryEntry(game: identity, sizeBytes: 100, hasArtwork: false)
        ])
        await provider.setGameFile(
            descriptor(.gameCubeMemoryCard, "GC/USA/MemoryCardA.raw"),
            forKey: identity.stableKey
        )

        // The builder asserts in debug builds; this test documents the release
        // behaviour, which is a nil manifest rather than a served memory card.
        #if !DEBUG
        let manifest = await makeBuilder(provider: provider)
            .manifest(forKey: identity.stableKey, sessionId: "s")
        XCTAssertNil(manifest)
        #endif
    }

    // MARK: - Per-game exclusion

    func testExcludedGameIsAbsentFromTheServedCatalog() async throws {
        let shared = game("GALE01", name: "Melee")
        let hidden = game("RMCE01", name: "Mario Kart Wii")
        let provider = MockLibraryProvider()
        await provider.setEntries([
            ContinuityLibraryEntry(game: shared, sizeBytes: 1, hasArtwork: false),
            ContinuityLibraryEntry(game: hidden, sizeBytes: 1, hasArtwork: false)
        ])
        await provider.setExcluded([hidden.stableKey])

        let catalog = await makeBuilder(provider: provider).catalog()

        XCTAssertEqual(catalog.entries.map(\.key), [shared.stableKey])
        XCTAssertNil(catalog.entry(forKey: hidden.stableKey))
    }

    /// The half that the acceptance criterion actually turns on: an excluded
    /// game must 404 when requested **directly by key**, not merely be absent
    /// from the list. A peer that kept a key from before the exclusion, or that
    /// guessed one, gets nothing.
    func testExcludedGameHasNoManifestEvenWhenRequestedDirectly() async throws {
        let hidden = game("RMCE01", name: "Mario Kart Wii")
        let provider = MockLibraryProvider()
        await provider.setEntries([
            ContinuityLibraryEntry(game: hidden, sizeBytes: 1, hasArtwork: false)
        ])
        await provider.setGameFile(
            descriptor(.gameFile, "Software/mkwii.rvz"), forKey: hidden.stableKey
        )

        // Shared first: the manifest exists.
        var manifest = await makeBuilder(provider: provider)
            .manifest(forKey: hidden.stableKey, sessionId: "s")
        XCTAssertNotNil(manifest)

        // Then excluded: the same direct request yields nothing.
        await provider.setExcluded([hidden.stableKey])
        manifest = await makeBuilder(provider: provider)
            .manifest(forKey: hidden.stableKey, sessionId: "s")
        XCTAssertNil(manifest, "an excluded game must 404 when requested by key, not just vanish from the list")
    }

    /// Exclusion is consulted live, so an unknown key and an excluded key are
    /// the same answer — telling a peer a game exists but is withheld leaks
    /// the fact the owner has it.
    func testUnknownKeyAndExcludedKeyAreIndistinguishable() async throws {
        let hidden = game("RMCE01")
        let provider = MockLibraryProvider()
        await provider.setEntries([
            ContinuityLibraryEntry(game: hidden, sizeBytes: 1, hasArtwork: false)
        ])
        await provider.setGameFile(
            descriptor(.gameFile, "Software/mkwii.rvz"), forKey: hidden.stableKey
        )
        await provider.setExcluded([hidden.stableKey])

        let builder = makeBuilder(provider: provider)
        let excluded = await builder.manifest(forKey: hidden.stableKey, sessionId: "s")
        let unknown = await builder.manifest(forKey: "id:NOPE00|d0|r0", sessionId: "s")
        XCTAssertNil(excluded)
        XCTAssertNil(unknown)
    }

    // MARK: - Catalog wire format

    func testCatalogRoundTrips() throws {
        let catalog = ContinuityLibraryCatalog(
            sourceDevice: device,
            entries: [ContinuityLibraryEntry(game: game(), sizeBytes: 42, hasArtwork: true)]
        )
        let decoded = try ContinuityLibraryCatalog.decode(from: try catalog.encoded())
        XCTAssertEqual(decoded, catalog)
    }

    func testCatalogRejectsUnsupportedVersion() throws {
        var catalog = ContinuityLibraryCatalog(sourceDevice: device, entries: [])
        catalog.version = 99
        let data = try catalog.encoded()
        XCTAssertThrowsError(try ContinuityLibraryCatalog.decode(from: data)) { error in
            guard case ContinuityError.manifestVersionUnsupported(let found) = error else {
                return XCTFail("expected manifestVersionUnsupported, got \(error)")
            }
            XCTAssertEqual(found, 99)
        }
    }

    /// The catalog says what a title is and what it costs, and nothing about
    /// how the owner has played it. Asserted on the encoded bytes so a field
    /// added later has to survive a reviewer reading this test.
    func testCatalogCarriesNoPlayHistory() throws {
        let catalog = ContinuityLibraryCatalog(
            sourceDevice: device,
            entries: [ContinuityLibraryEntry(game: game(), sizeBytes: 42, hasArtwork: true)]
        )
        let json = String(decoding: try catalog.encoded(), as: UTF8.self).lowercased()
        for leaked in ["lastplayed", "playtime", "savestate", "savecount", "progress"] {
            XCTAssertFalse(json.contains(leaked), "catalog leaked \(leaked)")
        }
    }
}
