# R8 library editing audit — 2026-10-20

Source audit plus native production-model/file-operation evidence. No simulator/device operations, Xcode builds, or installed-app acceptance were performed in this audit.

## Present actions and persistence

| Action | iOS/iPadOS | tvOS | Storage/scope |
| --- | --- | --- | --- |
| Favorite/unfavorite | Card context menu, Properties toggle, batch bar | Card context menu, batch bar; Properties read-only | SharedDefaults `favorites_by_gameid`, keyed by gameID; FavoritesChanged imports into Profiles/library_state.json via LibraryStateStore; CloudKit metadata sync. Disc/revision copies share favorite state. |
| Platform assignment / Auto | Batch bar | Batch bar, currently uses SwiftUI Menu; device presentation remains to verify | UserDefaults.standard `library_platform_overrides`, keyed by exact file path; local only. |
| Delete game file | Confirmed context menu and batch actions | Confirmed context menu and batch actions | Local filesystem removal only, followed by rescan. URL-based remote entries are refused/skipped. This handler does not delete save/config/metadata records or invoke peer removal. Automatic mirror reappearance behavior needs separate acceptance. |
| Remove from Cache | Remote card context menu when cached | Same | Remote pre-cache only; original remote ROM remains. Outside this fix's cache implementation scope. |
| Nearby sharing exclusion | Card context menu | Card context menu | Existing Continuity exclusion control, outside this audit's mutation scope. |
| Title / metadata fields / cover artwork / classification tags | No editor | No editor | Current properties show fetched title, game ID, disc/revision, manufacturer, region, title ID, GameTDB ID, apploader date and size. No custom title/art/tag persistence schema exists in these entry points. |

`Write to NFC Tag` on supported iPhones writes a launch URL to physical NFC media; it is not a library classification-tag editor. iOS Properties also exposes per-game emulation settings; those are distinct from title/artwork edits.

Entry points: Common/Swift/GameGridItem.swift, TVSoftwarePropertiesView.swift, LibraryPlatformCategory.swift, TVLibraryView.swift; Common/UI/SoftwareList/TVGameItem.mm. tvOS already renders libraryBottomChrome inside libraryView_tvOS; no missing action-bar fix is needed.

## Confirmed defects fixed

1. Favorites shelf builder repeated game IDs for multi-disc/revision library entries. tvHomeShelves resolves those IDs to the first file, displaying duplicate copies of the same representative card. The builder now retains first-seen distinct nonempty IDs.
2. Deleting repeated identical local paths removed the first and then reported a spurious missing-file error. LocalGameDeleter now removes each input path once, preserving input order.
3. Batch deletion rendered every local filesystem failure as a remote-item refusal. The UI now displays the actual first file-operation error using the existing localized Delete failed message; remote-only refusal retains its existing copy. This view wiring was parsed, not runtime tested.

Tests added to existing LibrarySectionsTests and LocalGameDeleterTests. The committed runner `Source/iOS/App/Project/Scripts/test_library_editing_native.py` creates a SwiftPM harness linking the actual repository production files and XCTest sources directly; no stand-ins replace either production implementation. Reproduce from the repository root: `python3 Source/iOS/App/Project/Scripts/test_library_editing_native.py` (optionally `--work-directory /tmp/icube-library-editing-audit` to retain the package/build cache).

- Red: 12 XCTest tests, two expected failures (duplicate shelf IDs and duplicate deletion path). [Log](2026-10-20-native/library-editing-red.log).
- Green: 12 XCTest tests, zero failures/skips. Includes real temporary-file removal, missing-file failure continuation, and off-main removal checks. [Log](2026-10-20-native/library-editing-green.log).
- Swift frontend syntax parse passed for TVLibraryView.swift, LibrarySections.swift and LocalGameDeleter.swift. No SDK type-check or UI runtime result is implied.

## Remaining release gates

- Custom title/artwork/tag editing is absent. The owner requires working library editing, but the exact field set is being clarified; record that decision and any required persistence/schema before claiming complete editing support. Provenance metadata convergence is not established by current snapshot exports.
- Accept edit/commit/cancel/reopen/rescan/relaunch and cross-device favorite convergence in installed apps. LibraryStateStore startup/reload correctness is owned by the parallel sync audit.
- Verify batch actions and Platform Menu presentation/focus using the Apple TV remote; verify iPhone/iPad touch and controller selection after filter/sort changes and failed deletion.
- Approve explicit local-file/shared-copy/automatic-mirror deletion copy and policy. Existing alert says only that the game will be deleted; it does not describe remote mirrors or local save preservation.
- Verify duplicate/revision/disc identities, missing and remote-only entries, restricted-folder deletion, interrupted edits, cloud races and large libraries. Native tests prove the bounded shelf/removal behaviors only.
