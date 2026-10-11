# iCube user-data sync: implementation plan

Spec: `docs/superpowers/specs/2026-10-11-icube-user-data-sync-design.md`.
Branch: `claude/icube-cloudkit-sync-986468`. Each phase builds, its package
tests pass, and it is committed on its own before the next begins.

## Phase 1: PVSyncRules categories and policy

Files: `SyncableFileType.swift`, `SyncClassifier.swift`, new `SyncPolicy.swift`,
`SyncClassifierTests.swift`, new `SyncPolicyTests.swift`.

- Add cases `gbaSave`, `gameProfile`, `touchOverlayLayout`, `libraryState`,
  `skin`, `firmware`, `wiiChannel`, `wiiSystem`. Extend `pullPriority` (new
  cases sort after the existing eight) and `isRequiredToResume` (false).
- Add traits: `isOptIn`, `maxFileSizeBytes`, `mergeKind` (`.wholeFile` or
  `.document`), `propagatesDeletes`, `isLarge` (for the Wi-Fi rule),
  `displayNameKey`.
- Rewrite `classify` for the new paths. Keep the hard exclusions first; add
  `wii/tmp` and `wii/import` to them. IPL is no longer a hard exclusion; it
  classifies to `firmware`. Wii title and ticket paths map by title-type high
  word.
- `SyncClassifier.syncableType(relativePath:sizeBytes:)` applies the
  per-category cap. Keep `maxFileSizeBytes` as the default cap for callers that
  pass no category.
- `SyncPolicy`: `firmwareEnabled`, `wiiChannelsEnabled`, `fullWiiNANDEnabled`,
  `largeFilesOverWiFiOnly`; `allows(_:)`, `effectiveWiiChannels` (true when
  NAND is on), `Codable`, `Equatable`, `Sendable`, `static let default`.
- Tests: one per new path family; every exclusion still nil; the no-ROM test
  gains `Software/`, `Wii/title/00010001/.../content/00000000.app` must be
  `wiiChannel` and never a ROM; cap per category; policy implications.

## Phase 2: PVContinuity failable kind

Files: `ContinuityFileKind.swift`, `ICubeContinuityFileProvider.swift`,
`ModelTests.swift` (or a new test file).

- `init?(_ syncableType:)` returns nil for every case beyond the eight.
- The guard chain in `ICubeContinuityFileProvider.walk` already binds the
  descriptor; add the kind binding to it.
- Tests: eight map, new cases nil.

## Phase 3: PVCloudSync engine

New files: `SyncTombstone.swift`, `RemoteSyncSnapshot.swift`,
`SyncIndexStore.swift`, `SyncTrash.swift`, `DocumentMerger.swift`,
`LibraryStateDocument.swift`, `KeyedTimestampDocumentMerger.swift`,
`SyncNetworkMonitor.swift`, `SyncProviderKind.swift`.
Changed: `SyncModels.swift`, `SyncPlanner.swift`, `SyncProvider.swift`,
`CloudKitSyncProvider.swift`, `CloudSyncConstants.swift`, `UserDataScanner.swift`.

- `SyncTombstone { relativePath, checksum, deletedAt, deviceIdentifier }`.
- `RemoteSyncSnapshot { files, tombstones, cursor: String? }`.
- `SyncIndexStore` actor: `[String: SyncIndexEntry]` with `checksum`,
  `lastModified`, `syncedAt`, `deletedAt?`; `accountIdentity: String?`;
  JSON at a caller-supplied URL; `load`, `save`, `reset`, `record`,
  `markDeleted`, `entry(for:)`.
- `SyncTrash` actor: `move(fileAt:relativePath:)`, `entries()`,
  `restore(_:into:)`, `purge(olderThan:)`; root supplied by caller.
- `DocumentMerger` protocol `merge(local: Data, remote: Data) throws -> Data`
  plus `DocumentMergerRegistry.merger(for: SyncableFileType)`.
- `LibraryStateDocument` Codable with the schema in the spec and a static
  `merge`. `KeyedTimestampDocumentMerger(timestampKey: "updatedAt")` for
  `game_profiles.json`.
- `SyncPlanStep` gains `.merge(local:remote:)`, `.writeTombstone(SyncTombstone)`,
  `.trashLocal(SyncableFileMetadata, tombstone:)`, `.markDeleted(path)`,
  `.restoreFromRemote(SyncableFileMetadata, reason:)` (download with a log
  message). `SyncConflict` gains `kind: .bothChanged | .deletedRemotelyChangedLocally`.
- `SyncPlanner.plan(local:remote:index:policy:)` implements the table in the
  spec. The old `plan(local:remote:)` stays as a wrapper with an empty index and
  default policy so existing tests keep passing until updated.
- `SyncProvider` gains `fetchRemoteSnapshot`, `writeTombstone`,
  `purgeExpiredTombstones`, `accountIdentity()`; protocol extension defaults.
- `CloudKitSyncProvider`: tombstone fields `deleted`, `deletedAt`;
  `metadata(from:)` splits into live file and tombstone mapping;
  `writeTombstone` saves the record with the asset removed; expired tombstones
  deleted in batches; `accountIdentity` from `container.userRecordID()`.
- `UserDataScanner.scanLocalFiles(policy:)` skips off categories;
  `moveToTrash` hook via injected `SyncTrash`.
- `SyncNetworkMonitor`: `NWPathMonitor` wrapper with `isConstrainedOrExpensive`
  and `ProcessInfo.isLowPowerModeEnabled`; protocol so tests inject.
- Tests: planner table rows, undelete, merge laws, index round trip, trash
  move/restore/purge, mapping of tombstone records (pure function on a
  dictionary, no CloudKit), policy gating in scanner.

## Phase 4: App target

Files: `CloudSyncCoordinator.swift`, `CloudSyncSettingsView.swift`,
`SyncConflictResolutionView.swift`, `SyncStatusIndicator.swift`, new
`SyncRecentlyDeletedView.swift`, new `LibraryStateStore.swift`, new
`PlayStatsRecorder.swift`, `GameProfiles.swift`, `LastPlayedStore.swift`,
`LibrarySnapshotService.swift`, `ServiceManager.swift`.

- Coordinator: persist `SyncPolicy` in `UserDefaults` under
  `icube.cloudSync.policy`; create index and trash under Application Support
  (iOS) or Caches (tvOS); execute new steps; publish `progress`; observe
  `CKAccountChanged` and compare account identity; gate large categories on the
  network monitor; skip timer in Low Power Mode; after a `libraryState` or
  `gameProfile` merge lands, post `CloudSyncDocumentDidChangeNotification` with
  the category.
- Settings view sections per spec section 8, with the new category display
  names.
- Recently Deleted view: list, Restore, Delete Permanently.
- `GameProfile.updatedAt: Date?` set in `setProfile` and
  `setExcludedFromNearbySharing`.
- `LibraryStateStore`: owns `Profiles/library_state.json`; imports favorites
  and last-played from `SharedDefaults` on first run and on `FavoritesChanged`;
  writes them back after a sync merge; `recordLaunch`, `addPlaySeconds`,
  `playSeconds(for:)`, `launchCount(for:)`.
- `PlayStatsRecorder` service: observes emulation start and end, resolves the
  GameID the way `LibrarySnapshotService` does, writes through the store.
- `LastPlayedStore.record` also writes through `LibraryStateStore`.

## Phase 5: Verification

- `swift test` in PVSyncRules, PVCloudSync, PVContinuity.
- `tuist generate` then `xcodebuild` for iOS and tvOS with
  `CODE_SIGNING_ALLOWED=NO`.
- Update `docs/superpowers/plans/2026-09-23-cloudkit-sync-gaps.md` with a
  pointer to the new spec.
