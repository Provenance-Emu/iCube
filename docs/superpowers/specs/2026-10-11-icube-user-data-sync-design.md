# iCube user-data sync: categories, deletes, stats and future backends

Status: approved design, 2026-10-11. Supersedes the scope section of
`docs/superpowers/plans/2026-09-23-cloudkit-sync-gaps.md`; everything that audit
says about the engine's existing behaviour stays true unless this document says
otherwise.

## 1. Goal

Keep a user's iCube data in step across their devices, with the user never
losing a save and always able to see what is being synced and why. This covers
save states, memory cards, Wii saves, GBA saves, Dolphin and controller INIs,
per-game profiles, touch-overlay layouts, skins, favorites and play statistics.
It optionally covers GameCube firmware, Wii channels and DLC, and the full Wii
NAND. Disc images never sync through this feature.

CloudKit is the only backend built now. The content server
(`Provenance-Emu/emulator-content-server`), a shared iCloud Drive folder across
Provenance, Provenance Lite, iFly and iCube, and nearby device transfer are
designed for as later providers against the same engine, not as parallel
systems.

## 2. What exists

`PVSyncRules` holds the allow-list classifier shared with Continuity.
`PVCloudSync` holds the scanner, planner, timestamp resolver, retry policy,
lifecycle policy and the CloudKit provider. `CloudSyncCoordinator` in the app
target is glue. The CloudKit container `iCloud.com.joemattiello.iCube` is not
provisioned; `CloudKitAvailability.containerIsProvisioned` is false and the
entitlements patch in `docs/cloudkit-entitlements.patch` is unapplied. Every
change below must keep working in that inert state.

Decisions already made that this design keeps:

- The classifier is an allow-list and stays pure. Nothing under `Software/`,
  nothing with a disc-image extension, nothing under caches ever syncs.
- One CloudKit record type in a custom private zone, enumerated with
  `CKFetchRecordZoneChangesOperation`.
- No sync while a game is running; deferred work flushes when it ends.
- App preferences in `UserDefaults` are not mirrored wholesale.

Decisions this design changes:

- Deletions now propagate, through tombstones with safety rails (section 6).
- Firmware, Wii channels and the full NAND become opt-in categories instead of
  hard exclusions (section 4).
- Two files are merged field by field instead of whole-file last-writer-wins
  (section 5).

## 3. Architecture

One planner, many providers.

```
UserDataScanner ─┐
                 ├─> SyncPlanner(local, remote, index, policy) ─> [SyncPlanStep]
SyncProvider ────┘            │
   │                          ▼
   │                  CloudSyncCoordinator executes steps
   │                     upload / download / merge / tombstone / trash
   └── CloudKitSyncProvider (now)
       ContentServerSyncProvider, ICloudDriveSyncProvider, NearbySyncProvider (later)
```

New pieces:

| Piece | Module | Purpose |
| --- | --- | --- |
| `SyncPolicy` | PVSyncRules | The user's toggles: which opt-in categories are on, and whether large categories wait for Wi-Fi. Pure value type. |
| `SyncableFileType` additions and per-category traits | PVSyncRules | New cases; `isOptIn`, `maxFileSizeBytes`, `mergeKind`, `propagatesDeletes`. |
| `SyncIndexStore` | PVCloudSync | Persistent per-path record of what this device last synced. Required to tell "deleted here" from "never had". |
| `SyncTombstone`, `RemoteSyncSnapshot` | PVCloudSync | Remote state now carries tombstones and an opaque cursor. |
| `DocumentMerger` and two mergers | PVCloudSync | Field-level merge for `library_state.json` and `game_profiles.json`. |
| `SyncTrash` | PVCloudSync | Files removed by a remote delete go here for 30 days. |
| `SyncNetworkMonitor` | PVCloudSync | Wi-Fi versus expensive or constrained path, and Low Power Mode. |
| `LibraryStateStore`, `PlayStatsRecorder` | app target | Favorites, last played, launch count and play seconds, written to `Profiles/library_state.json`. |

`SyncProvider` grows three members, all with default implementations so
`InertSyncProvider` and tests stay small:

```swift
func fetchRemoteSnapshot() async throws -> RemoteSyncSnapshot   // files + tombstones + cursor
func writeTombstone(_ tombstone: SyncTombstone) async throws
func purgeExpiredTombstones(olderThan: Date) async throws
```

`fetchRemoteMetadata()` remains and is implemented on top of
`fetchRemoteSnapshot()` for callers that only want live files.

## 4. Categories

Paths are relative to Dolphin's `User/` directory, which on iOS is the app's
Documents folder and on tvOS is Library/Caches. Matching is case-insensitive.

### Always on when sync is on

| Case | Paths | Notes |
| --- | --- | --- |
| `saveState` | `StateSaves/*.s00`..`.s99` | unchanged |
| `resumeState` | `StateSaves/*.auto` | unchanged |
| `saveStateMetadata` | `StateSaves/*.json` | unchanged |
| `saveStateThumbnail` | `StateSaves/*.png` | unchanged |
| `gameCubeMemoryCard` | `GC/**/*.raw`, `GC/**/*.gci` | unchanged |
| `wiiSave` | `Wii/title/*/*/data/**`, `Wii/shared2/sys/SYSCONF` | unchanged |
| `gbaSave` | `GBA/Saves/**` | new; Dolphin's integrated GBA saves |
| `config` | `Config/*.ini` | unchanged; includes `GCPadNew.ini`, `WiimoteNew.ini`, `Hotkeys.ini`, so controller INIs are already covered |
| `gameSettings` | `GameSettings/*.ini` | unchanged; also carries cheats |
| `gameProfile` | `Profiles/game_profiles.json` | new; merged per game |
| `touchOverlayLayout` | `Profiles/touch_overlay_layout*.json` | new; whole file |
| `libraryState` | `Profiles/library_state.json` | new; merged per field |
| `skin` | `Skins/selection.json`, `Skins/*/**` | new; 32 MB per file |

### Opt-in, default off

| Case | Toggle | Paths | Cap |
| --- | --- | --- | --- |
| `firmware` | GameCube Firmware | `GC/IPL.bin`, `GC/*/IPL.bin` | 4 MB |
| `wiiChannel` | Wii Channels & DLC | `Wii/title/{00010001,00010004,00010005,00010008}/*/**` except `data/`, matching `Wii/ticket/...`, `Wii/shared1/**` | 256 MB |
| `wiiSystem` | Full Wii NAND | everything else under `Wii/` except `tmp/` and `import/` | 256 MB |

Turning on Full Wii NAND implies Wii Channels & DLC; the settings view shows the
channels toggle as on and disabled while NAND is on. The three toggles have
footers that say what the category contains, roughly how large it is, and that
the data goes only to the user's own private iCloud database.

Continuity carries only the first eight categories, unchanged.
`ContinuityFileKind.init(_:)` becomes failable and returns nil for every new
case, so a new category can never ride a nearby transfer by accident.

### What never syncs

`Software/`, `Cache/`, `Dump/`, `Logs/`, `Load/`, `Shaders/`, `Maps/`,
`Backup/`, `ResourcePacks/`, `ScreenShots/`, `Wii/tmp/`, `Wii/import/`, any
file with a disc-image or archive extension (`.iso .gcm .gcz .wbfs .rvz .ciso
.wia .wad .dol .elf .nkit .m3u .img .dff .zip .7z .rar`), `.DS_Store`,
`dolphin.log`, and anything the classifier does not positively match. The
existing tests that assert no ROM is ever classified stay and gain cases for the
new directories.

### Policy

`SyncPolicy` is read by the scanner (skip opt-in categories that are off so
their bytes are never hashed), by the planner (a remote file in an off category
is ignored, never downloaded), and by the coordinator (large categories wait for
an unconstrained network when the Wi-Fi-only switch is on). The classifier
itself does not consult policy; the provider's record-to-metadata mapping keeps
re-classifying by path and never by policy, so a record from a device with
different toggles still lands in the right category here.

## 5. Mergeable documents

Two files hold per-game records that different devices edit independently.
Whole-file last-writer-wins would discard one device's edits whenever both
changed, so these take a `mergeKind` of `.document` and never produce a user
conflict.

`Profiles/library_state.json`, version 1:

```json
{
  "version": 1,
  "games": {
    "GALE01": {
      "favorite": { "value": true, "updatedAt": "2026-10-11T18:00:00Z" },
      "lastPlayed": "2026-10-11T17:55:00Z",
      "launches": { "<deviceID>": 12 },
      "playSeconds": { "<deviceID>": 54000 }
    }
  }
}
```

Merge rules: `favorite` is a last-writer-wins register on `updatedAt`;
`lastPlayed` is the maximum; `launches` and `playSeconds` are per-device
counters merged by taking the maximum per device and summing across devices for
display. The merge is commutative, associative and idempotent, and is tested as
such.

`Profiles/game_profiles.json` keeps its current shape, a dictionary keyed by
GameID. `GameProfile` gains an optional `updatedAt` stamped on every save.
Merge is per key: the entry with the newer `updatedAt` wins, a missing stamp
counts as oldest, and a key present on one side only is kept. The merger works
on JSON dictionaries and knows nothing about `GameProfile`, so it lives in
`PVCloudSync` and is tested there.

Plan step `.merge(local, remote)`: the coordinator reads both payloads, merges,
writes the result locally if it differs from local, and uploads if it differs
from remote. The uploaded record's `lastModified` is the write time, and the
local file is back-dated to match so the next scan sees it as synced.

Favorites and last-played currently live in the app-group `UserDefaults`, which
TopShelf and the snapshot writer read. `LibraryStateStore` becomes the owner of
`library_state.json` and keeps those keys mirrored: it imports them on first
run, re-imports whenever `FavoritesChanged` fires (the Objective-C favorites
writer stays untouched), and writes them back after a merge lands so every
existing reader keeps working. `PlayStatsRecorder` adds a launch on
`DOLEmulationWillStartNotification` and the session's seconds on
`DOLEmulationDidEndNotification`, using the same path-to-GameID lookup
`LibrarySnapshotService` already uses for last-played.

## 6. Deletes

A delete on one device propagates as a tombstone. The remote record keeps its
name, drops its asset, and gains `deleted = 1`, `deletedAt`, and the checksum of
the content that was deleted.

To emit a tombstone the engine must know it once had the file, which is what
`SyncIndexStore` records: per path, the checksum and modification date last
seen in sync, plus the time. It is JSON under the app's Application Support
directory on iOS and Library/Caches on tvOS, keyed by provider kind. If the
index is missing (fresh install, tvOS purge) the engine behaves additively for
that run and rebuilds the index; it never emits a tombstone it cannot justify.

Planner rules, evaluated per path:

| Local | Remote | Index | Step |
| --- | --- | --- | --- |
| present | absent | absent | upload (new here) |
| present | absent | present | the remote record vanished without a tombstone, which only a purge, an expired tombstone or a zone reset produces: upload again |
| present | tombstone | any | if local mtime is newer than `deletedAt` + tolerance: upload (undelete). Else if local checksum equals the tombstone's: move local to trash, mark index deleted. Else: conflict "deleted on another device, changed here". |
| absent | live file | present | the file was deleted here since last sync. If remote checksum equals the index checksum: write tombstone. Else the other device changed it after we deleted: download it and log "restored because it changed elsewhere". |
| absent | live file | absent | download (new elsewhere) |
| absent | tombstone | any | mark index deleted, nothing else |
| present | live file | any | existing checksum, tolerance and timestamp rules |

Documents with `mergeKind == .document` never tombstone.

Trash: a local file removed by a tombstone is moved to
`<app support>/iCubeSync/Trash/<ISO stamp>/<relative path>`. Entries older than
30 days are purged at the start of a sync run. Settings gains a Recently
Deleted screen listing trash entries with a Restore action. A restore writes the
file back with the current time as its modification date, so the next run
treats it as an undelete and uploads it.

Tombstones older than 90 days are removed from the remote by whichever device
syncs next. A device offline longer than that simply re-uploads the file, which
is the resurrection the old behaviour had, now limited to a rare case.

## 7. Being a good citizen

- No sync while emulating; abort in-flight work when a game starts; flush when
  it ends. Unchanged.
- Opt-in categories do not transfer over an expensive or constrained path when
  "Large files over Wi-Fi only" is on. Default on. Always-on categories
  transfer regardless; they are small.
- Periodic timer syncs are skipped in Low Power Mode. Manual, foreground and
  game-end triggers still run.
- Progress: the coordinator publishes completed and total step counts, and the
  status indicator shows them while syncing.
- Account change: on `CKAccountChanged`, or when the stored user record ID
  differs from the live one, the index is reset and the next run behaves as a
  first sync. Two accounts never share an index.
- First enable with existing remote data: the first run downloads before it
  uploads so the device fills in rather than overwrites, which the planner's
  ordering already gives us. The activity log says how many files came down.
- Quota exceeded, not signed in, restricted, offline: existing reasons, shown
  verbatim in the status footer.
- Every delete the engine performs locally goes through the trash. Nothing is
  unlinked outright.

## 8. Settings surface

`CloudSyncSettingsView` sections, in order:

1. Status: toggle, status row with progress while syncing, last synced, Sync
   Now, footer with the unavailable reason or last error.
2. Needs Your Decision: conflicts, including delete-versus-change conflicts.
3. What Syncs: a static list of the always-on categories, then the three
   opt-in toggles with footers, then "Large files over Wi-Fi only".
4. Synced Contents: per-category counts and sizes, including the new
   categories.
5. Recently Deleted: link to the trash screen with a count.
6. Recent Activity: unchanged.
7. Maintenance: Clear iCloud Data, unchanged.

Copy stays plain: say what a toggle moves, where it goes, and roughly how big it
is. The footer that lists what never uploads keeps "Games are never uploaded"
first.

## 9. Future providers

The seam is `SyncProvider` plus `SyncProviderKind`, an enum with `iCloud`,
`contentServer`, `iCloudDrive` and `nearby`. Only `iCloud` is constructed now.
Each later provider maps onto the engine as follows, so no planner change is
expected:

| Engine concept | Content server | Shared iCloud Drive folder | Nearby |
| --- | --- | --- | --- |
| record name | asset path under the library item | file path under the shared container | continuity descriptor path |
| checksum | SHA-256 blob identity | computed on read | manifest checksum |
| device identifier | device token | per-install UUID in a sidecar | peer identity |
| tombstone | server tombstone in the change feed | `.tombstone` sidecar or folder manifest | not carried |
| conflict | `conflictOf` copy beside the live asset | `NSFileVersion` conflict versions | manual |
| cursor | `GET /api/v1/changes` cursor | `NSMetadataQuery` update | none |

Two constraints are recorded so they are not rediscovered: tvOS has no iCloud
Drive, so the shared folder can never be the only backend; and the iCloud Drive
container the Provenance agent is planning (`iCloud.org.provenance-emu.provenance`)
is a ubiquity container, which iCube would have to add to its entitlements
alongside, not instead of, the CloudKit container.

The content server's own sync workstream resolves save conflicts by keeping
both as separate assets. When that provider is written, `.conflict` maps to
"download the conflict copy beside the live one and surface both", which the
Keep Both action already does locally.

## 10. Testing

Package tests, all runnable with `swift test` on macOS:

- PVSyncRules: every new path pattern classifies to the right case; every
  excluded directory and extension still returns nil; `SyncPolicy` gating;
  per-category size caps; the no-ROM invariant with the new directories.
- PVCloudSync: planner tombstone table above, row by row; undelete; delete
  versus change conflict; document merge commutativity, associativity and
  idempotence for both documents; index round trip and reset; trash move,
  restore and 30-day purge; network gating; provider record mapping for
  tombstones.
- PVContinuity: failable kind init returns nil for new cases; existing eight
  still map.

App target: iOS and tvOS build. Device-pair convergence remains a manual test
that needs the provisioned container.

## 11. Out of scope

Provisioning the container and applying the entitlements patch (maintainer
action, checklist unchanged). Disc image sync of any kind. Writing the content
server, iCloud Drive or nearby providers. Showing play time in the library UI
beyond exposing it from `LibraryStateStore`. Syncing `UserDefaults` beyond the
fields carried in `library_state.json`.
