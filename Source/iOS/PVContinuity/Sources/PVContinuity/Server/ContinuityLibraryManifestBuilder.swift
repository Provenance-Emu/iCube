// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Builds the catalog and the per-entry manifests a host serves to **browsing
/// peers**, as opposed to the handoff manifests `ContinuityManifestBuilder`
/// builds for a user's own second device.
///
/// ## Why this is a separate type — read before adding a file to it
///
/// A handoff manifest carries the user's save data on purpose: it is how a game
/// resumes at the same point on the device in their other hand. Because
/// GameCube saves live in **region-wide** memory-card images and Wii saves live
/// in a **shared NAND tree**, "this game's saves" is unavoidably *every* game's
/// saves for that region or on that NAND. That is the right trade for a handoff
/// and it is spelled out on `ICubeContinuityFileProvider`.
///
/// A library pull is a different act with a different counterparty. The peer
/// browsing may be a friend's device, or a device the owner paired once and
/// forgot. **A browsing peer pulling a game gets the game — nothing of the
/// owner's.** So this builder does not reuse
/// `ContinuityManifestBuilder.handoffUserDataKinds`; it has its own set,
/// `libraryUserDataKinds`, which is empty and is meant to stay empty.
///
/// If you are here to add a kind to that array, the question to answer first is
/// not "is this file small?" but "would the owner expect a stranger who copied
/// one game to receive it?". For every user-data category iCube has, the answer
/// is no:
///
///   * memory cards and Wii saves — region- and NAND-wide, as above;
///   * save states — the owner's progress, plus a screenshot of their screen;
///   * per-game INIs — iCube stores **cheats** in the same file
///     (`SyncableFileType.gameSettings`), and they are the owner's, not the
///     title's;
///   * config — device-specific, and pushing it at a peer is hostile even when
///     it leaks nothing.
///
/// `ContinuityLibraryManifestTests.testLibraryManifestCarriesNoOwnerSaveData`
/// asserts this against a provider that offers one descriptor of *every* kind,
/// and checks `allDescriptors` (which includes the `saveState` field) rather
/// than `files`. It will fail the moment this changes, which is the point.
public struct ContinuityLibraryManifestBuilder: Sendable {

    /// User-data categories a **library pull** carries: none.
    ///
    /// Stated as an array rather than simply omitted so that the contrast with
    /// `ContinuityManifestBuilder.handoffUserDataKinds` is visible at both
    /// sites, and so the security test has something concrete to assert
    /// against. See the type doc before changing it.
    public static let libraryUserDataKinds: [ContinuityFileKind] = []

    private let libraryProvider: any ContinuityLibraryProviding
    private let sourceDevice: SourceDevice

    public init(libraryProvider: any ContinuityLibraryProviding, sourceDevice: SourceDevice) {
        self.libraryProvider = libraryProvider
        self.sourceDevice = sourceDevice
    }

    /// The shared game list, with excluded titles removed rather than flagged.
    ///
    /// Filtering here — server-side, in the thing that builds what goes on the
    /// wire — rather than in the browsing UI is the whole point of the
    /// acceptance criterion: an excluded game must never be *served*, not
    /// merely never *drawn*. A peer with a hand-written HTTP client sees
    /// exactly what the app's own browser sees.
    public func catalog() async -> ContinuityLibraryCatalog {
        var entries: [ContinuityLibraryEntry] = []
        for entry in await libraryProvider.allEntries()
        where await !libraryProvider.isExcludedFromSharing(key: entry.key) {
            entries.append(entry)
        }
        return ContinuityLibraryCatalog(sourceDevice: sourceDevice, entries: entries)
    }

    /// The manifest for one catalog entry, or nil when the entry is unknown,
    /// excluded, or has no offerable disc image.
    ///
    /// The exclusion check runs **here**, not only in `catalog()`, so a peer
    /// that kept a key from before the owner excluded the game — or guessed one
    /// — gets the same nil, and the route turns it into a 404.
    ///
    /// A nil return deliberately does not distinguish "excluded" from
    /// "unknown". Telling a peer that a game exists but is withheld leaks the
    /// fact that the owner has it, which is precisely what excluding it was
    /// meant to stop.
    public func manifest(forKey key: String, sessionId: String) async -> ContinuityManifest? {
        guard await !libraryProvider.isExcludedFromSharing(key: key) else { return nil }
        let entries = await libraryProvider.allEntries()
        guard let entry = entries.first(where: { $0.key == key }) else { return nil }
        guard let gameFile = await libraryProvider.gameFileDescriptor(forKey: key) else { return nil }
        guard gameFile.kind == .gameFile else {
            // A provider handing back something labelled otherwise is a bug,
            // and the safe reading of a bug here is "serve nothing".
            assertionFailure("library provider returned a non-gameFile descriptor for \(key)")
            return nil
        }

        // `saveState: nil` and a `files` array holding exactly the disc image.
        // Both halves matter: the save state travels in its own field and is
        // part of `ContinuityManifest.allDescriptors`, which is what the file
        // route serves from — a manifest with an empty `files` and a populated
        // `saveState` would leak just as effectively.
        return ContinuityManifest(
            sessionId: sessionId,
            mintedAt: Date(),
            sourceDevice: sourceDevice,
            game: entry.game,
            saveState: nil,
            files: [gameFile]
        )
    }
}
