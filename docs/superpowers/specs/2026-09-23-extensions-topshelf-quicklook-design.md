# App extensions: tvOS Top Shelf and Quick Look for iCube, plus Realm-free fixes for Provenance and iFly

Date: 2026-09-23
Status: approved in conversation, implementation plan to follow
Repos touched: iCube (this repo), Provenance (`/Users/jmattiello/Workspace/Provenance/Provenance`), iFly (`/Users/jmattiello/Workspace/Provenance/iFly/iFly`)

## 1. Goal

Give iCube the two OS integrations its sibling apps already have:

* a **tvOS Top Shelf** extension that shows "Continue Playing" and "Favorites" rows on the Apple TV home screen and launches the game on select;
* **Quick Look thumbnail and preview** extensions so the Files app (and Finder once a Mac build exists) shows cover art and metadata for GameCube/Wii disc images.

Along the way fix the two reference implementations:

* **Provenance** ships a Top Shelf that links Realm and opens the live database, and its two Quick Look extensions do the same through `PVQuickLookSupport`. Move all three to the dependency-free snapshot pattern the repo already has for widgets, and embed the orphaned `QuickLookPreview` target.
* **iFly**'s Top Shelf code is correct but the app never refreshes its snapshot on tvOS at foreground or after a CloudKit merge, and ships a diagnostic logging block.

## 2. Findings that drive the design

These were verified by reading the three repos on 2026-09-23. Do not re-derive them.

### 2.1 iFly (the template to copy)

* `Sources/Shared/WidgetSharedData.swift` defines `IFlyWidgetShared` (app group `group.com.joemattiello.ifly`, shared `UserDefaults`, `WidgetMedia/` directory) and the Codable `WidgetSnapshot` / `WidgetGameData`. The file is compiled into the app and every extension.
* `Sources/Core/Widgets/WidgetDataWriter.swift` fetches SwiftData rows, writes the JSON snapshot into the shared suite, and mirrors covers as JPEG at **1280 px long edge** into `WidgetMedia/`. 1280 is load-bearing: tvOS `.poster` at `@2x` is 808×1216 and a 720 px mirror left the art blank (`a7ff0e219`).
* `Extensions/iFlyTopShelf/TopShelfContentProvider.swift` links Foundation + TVServices only, decodes the snapshot, builds two `TVTopShelfItemCollection` sections, uses `setImageURL` with file URLs into the group container, and deep-links `ifly://open?id=...`.
* Tuist quirk: a tvOS-only extension dependency on a multiplatform app is rejected, so the target is declared `[.iPhone, .iPad, .appleTv]` and embedded with `.when([.tvos])` (`Project.swift:435`). The `.when` is load-bearing.
* Blank artwork on some installs is a **signing** problem: a wildcard "Team Provisioning Profile: *" cannot carry App Groups. `Scripts/release.sh` passes `-allowProvisioningUpdates`; ad-hoc builds may not.
* Gaps: `iFlyApp.swift:1181-1183` gates the launch/foreground refresh with `#if !os(tvOS)`. The library itself is not cloud-synced (`ModelConfiguration` uses `cloudKitDatabase: .none`), but save states are mirrored through iCloud Drive by `SyncCoordinator` (`Sources/Core/Sync/Coordinators/SyncCoordinator.swift`), which feeds the "Recent Saves" row, and nothing refreshes the snapshot when a sync pass downloads new files. The "TEMP DIAGNOSTIC" block at `TopShelfContentProvider.swift:24-38, 42-49, 71-78` still ships.

### 2.2 Provenance

* Two Top Shelf targets share bundle id `org.provenance-emu.provenance.topshelf`. `Provenance (AppStore)` embeds **`TopShelfv2`** (links `PVLibrary` + `RealmSwift`, opens `RealmConfiguration.readOnlyConfig`, cannot migrate, blank after any schema bump). `Provenance-UnderDevelopment` and `Provenance-XL` embed the rewritten **`Extensions/TopShelf`** (`ServiceProvider.swift`), which links only `PVLibrarySnapshot`.
* `PVLibrarySnapshot` (`PVAppIntents/Sources/PVLibrarySnapshot/`) is dependency-free: `LibrarySnapshotGame`, `LibrarySnapshotKeys` (`widget.*` UserDefaults keys), `LibrarySnapshotSchema`, `LibrarySnapshotReader`, `LibrarySnapshotAppGroup`. The host writes via `WidgetDataWriter` (`PVAppIntents/Sources/PVAppIntents/Widget/WidgetDataWriter.swift`) fed by `WidgetDataWriter+Realm.swift` in `PVUIBase`, from seven mutation sites, and calls `TVTopShelfContentProvider.topShelfContentDidChange()`.
* `ThumbnailExtension` (iOS + Catalyst, embedded only in `Provenance (AppStore)`) and `QuickLookPreview` (target exists, **embedded nowhere**, still carries dead `PreviewViewController.swift` + storyboard) both link `PVQuickLookSupport`, which depends on `PVLibrary`, `PVHashing`, `RealmSwift`. The Realm use is confined to `ROMGameLookup.swift` (`RealmGamePreviewDataSource`: game by ROM filename, save-state image by path) and `ArtworkResolver.swift` (`PVMediaCache.filePath(forKey:)` fallback plus `PVAppGroupId`). `GameInfo`, `GameMetadataCard`, `SystemIconProvider` are already Realm-free.
* `GameInfo` fields: title, systemName, systemIdentifier, developer, publishDate, genre, gameDescription, playCount, isFavorite, artworkURLKey. Artwork files live at `<group>/{Documents,Caches,Library/Caches,}/PVCache/<md5(artworkURL)>`.
* `Extensions/TopShelfv2/DebugLogger.swift` is dead code. `Extensions/macOS/*` are unbuilt template stubs; out of scope.

### 2.3 iCube

* Single multiplatform app target `iCube` (`Source/iOS/App/Project.swift`, Tuist is the source of truth) plus a hand-maintained fallback `DolphiniOS.xcodeproj` that must be edited in step. Eight shipping bundle ids, all `com.joemattiello.iCube*`. Team `S32Z3HMYVQ`, automatic signing.
* **No App Group anywhere.** Four entitlements files (`DolphiniOS/DolphiniOS.entitlements`, `DolphiniOS/iCube AppStore.entitlements`, `Project/Entitlements/Public.entitlements`, `Project/Entitlements/Private.entitlements`). `docs/cloudkit-entitlements.patch` is the precedent for a capability rollout.
* Library data is only reachable through the Dolphin core: `GameFileCacheManager` wraps `UICommon::GameFileCache` (binary `gamelist.cache`), `TVGameItem` exposes `gameID`, `gametdbID`, `title`, `filePath`, `platform`, `coverImage`, `favorite`. Covers are PNGs at `<UserFolder>/Cache/GameCovers/<gametdbID>.png` inside the app sandbox.
* Favorites: `UserDefaults.standard["favorites_by_gameid"]` (`TVGameItem.mm:214-227`). Added dates: `LibraryAddedDateStore` (`library_added_dates_v1`). **No last-played or play-count tracking exists.**
* Launch chokepoint: `EmulationCoordinator.mm:595 runEmulationWithBootParameter:` posts `DOLEmulationWillStartNotification` at line 624 for both iOS and tvOS paths.
* URL scheme `dolphinios` is registered; `Common/Services/URLRouterService.swift` handles only `dolphinios://dsu/add` and `dsu://`.
* `LiveActivityExtension` is the only extension target and is not embedded (`APP_EMBEDS_APPEX = false`). Useful for scaffolding only.
* No pure-Swift disc parser exists; `PVlibDolphin.xcframework` is 25–27 MB per slice, far too heavy for a Quick Look process.
* `Info-TV.plist` already declares the static `TVTopShelfImage` brand asset. That is unrelated to the dynamic provider and stays.

## 3. Design

### 3.1 iCube: `PVLibrarySnapshot` package (new, `Source/iOS/PVLibrarySnapshot`)

Dependency-free SwiftPM package (Foundation only, platforms iOS 17 / tvOS 17 / macCatalyst 17 / macOS 14 / visionOS 1). Linked by the app and by all three new extensions. Contents:

* `LibrarySnapshotAppGroup` — `identifier = "group.com.joemattiello.icube"`, `defaults: UserDefaults?`, `containerURL: URL?`, `mediaDirectory` (`<group>/LibraryMedia/`), `coverURL(gameID:)`. Every accessor is optional and never traps.
* `LibrarySnapshotGame: Codable, Sendable, Identifiable, Hashable` — `id` (6-char game id, or title id hex for WADs), `title`, `filePath`, `platform` (`gamecube | wii | wiiware | triforce | elf | dol`), `gametdbID`, `region` (`String?`), `lastPlayed: Date?`, `isFavorite`, `coverFilename: String?`, computed `launchURL` = `dolphinios://play?id=<id>`.
* `LibrarySnapshot: Codable` — `schemaVersion`, `updatedAt`, `recentlyPlayed: [LibrarySnapshotGame]` (max 12), `favorites` (max 16), `byGameID: [String: LibrarySnapshotGame]` (full index, used by Quick Look).
* `LibrarySnapshotKeys` — `snapshot.v1` UserDefaults key. `LibrarySnapshotSchema.currentVersion = 1`; readers tolerate a missing/older version by returning an empty snapshot.
* `LibrarySnapshotReader` — decodes from the shared suite; returns empty on any failure.
* `DiscHeaderReader` — pure-Swift, reads at most 64 KiB, returns `DiscHeader(gameID, makerCode, discNumber, title, platform)`. Container support in v1:

  | Container | How the header is found |
  |---|---|
  | `.iso`, `.gcm`, `.nkit.iso` | disc header at offset 0 |
  | `.rvz`, `.wia` | magic `RVZ\x01` / `WIA\x01` at 0, disc header copy at 0x58 (header_1 is 0x48 bytes, header_2 begins with four 4-byte fields) |
  | `.wbfs` | magic `WBFS`, `hd_sec_sz_s` at 0x08, first disc header at `1 << hd_sec_sz_s` |
  | `.ciso` | magic `CISO`, block map; if block 0 is present the header is at 0x8000 |
  | `.gcz`, `.tgc`, `.wad`, `.dol`, `.elf` | not parsed in v1; return `nil` and let the caller fall back to the filename-derived placeholder |

  Platform is decided by the Wii magic word `0x5D1C9EA3` at 0x18 versus the GameCube magic `0xC2339F3D` at 0x1C. Title is the 64-byte ASCII field at 0x20, trimmed.

Tests (`swift test`, runs on macOS): fixtures are synthetic 64 KiB headers for each container, plus a truncated file, a zero-byte file, and garbage bytes.

### 3.2 iCube: host-app writers

* `LastPlayedStore` (new, `Common/Swift/`) — `[gameID: TimeInterval]` in the **shared** suite under `last_played_v1`. Observes `DOLEmulationWillStartNotification`; the notification's boot parameter carries the game file, from which `gameID` is read via `TVGameItem`/`GameFilePtrWrapper`. Also exposed for the tvOS library sort in a follow-up (out of scope here).
* Favorites and `LibraryAddedDateStore` move from `UserDefaults.standard` to the shared suite with a one-time migration on first launch (copy, then leave the old key in place for a downgrade). Key names are unchanged.
* `LibrarySnapshotWriter` (new, `Common/Swift/`) — builds `LibrarySnapshot` from `GameFileCacheManager.sharedManager.currentGames`, writes JSON to the shared suite, and mirrors covers as JPEG (quality 0.85, 1280 px long edge, ImageIO downsampling) to `LibraryMedia/cover_<gameID>.jpg`, skipping files that already exist with a newer mtime than the source PNG. Runs on a utility queue, debounced 2 s. Fails closed if the group container is unavailable: logs once, still writes nothing rather than crashing. On tvOS it calls `TVTopShelfContentProvider.topShelfContentDidChange()` after a successful write.
* Trigger sites: app did become active (both platforms), `GameFileCacheManager` rescan complete, `DOLEmulationWillStartNotification`, `FavoritesChanged`, remote library update (`RemoteLibraryUpdated`).
* `URLRouterService` gains `dolphinios://play?id=<gameID>`: looks the id up in `currentGames`, and if found boots through `EmulationCoordinator runEmulationWithBootParameter:` on the main queue after the root view is ready. If the library is not yet scanned it waits for the first scan completion (one-shot observer, 10 s timeout, then shows the existing snackbar with "Game not found").

### 3.3 iCube: Top Shelf extension (`Source/iOS/Extensions/iCubeTopShelf`)

* `TopShelfContentProvider: TVTopShelfContentProvider`, whole file `#if os(tvOS)`. Sections: "Continue Playing" from `recentlyPlayed`, "Favorites" from `favorites`. Item image via `setImageURL(coverURL, for: .screenScale1x)` and `.screenScale2x`, `.poster` shape. `displayAction` and `playAction` both use `launchURL`. Empty snapshot returns `nil` content so tvOS falls back to the static brand image.
* Tuist target `iCubeTopShelf`: `destinations: [.iPhone, .iPad, .appleTv]`, `product: .appExtension`, bundle id `$(PRODUCT_BUNDLE_IDENTIFIER_BASE).topshelf` derived per configuration from the eight app ids, deployment `iOS 17 / tvOS 17`, `NSExtensionPointIdentifier = com.apple.tv-top-shelf`, principal class `$(PRODUCT_MODULE_NAME).TopShelfContentProvider`, dependency `PVLibrarySnapshot`, entitlement file with the app group. Embedded from the app with `.when([.tvos])`.
* Same target added to `DolphiniOS.xcodeproj` by hand with `C0C0CAFE`-prefixed UUIDs.

### 3.4 iCube: Quick Look extensions (`Source/iOS/Extensions/iCubeThumbnail`, `iCubeQuickLookPreview`)

* Both iOS + iPad + Mac Catalyst, embedded `.when([.ios, .catalyst])`. Not tvOS (no Quick Look there).
* `QLSupportedContentTypes`: the existing UTIs `me.oatmealdome.dolphinios.generic-software`, `.gamecube-software`, `.wii-software`, `.rvz-image`, `.wia-image`, `.nkit-image`, `public.iso-image`. Archives are excluded (a zip's contents are unknown without extraction).
* Shared lookup, in `PVLibrarySnapshot`: `LibraryLookup.game(for url: URL) -> ResolvedGame` does, in order: (1) read the disc header with `DiscHeaderReader`; (2) if that yields a game id, look it up in `snapshot.byGameID` for title, platform, favorite and cover; (3) if the header could not be read, match `snapshot.byGameID` values by `filePath` last path component (handles `.gcz`, `.tgc`, `.wad`); (4) otherwise return a filename-derived title with `platform = .unknown`. iCloud placeholder names (`.Name.ext.icloud`) are normalised the way Provenance's `ROMGameLookup.realFilename(from:)` does.
* `ThumbnailProvider` — if a cover exists, `QLThumbnailReply(imageFileURL:)`. Otherwise draws a placeholder in the reply context: platform-tinted gradient (GameCube purple, Wii white/blue, unknown grey), the platform glyph, and the game id or filename. Never returns an error for a readable file.
* `PreviewProvider` — data-based preview (`QLIsDataBasedPreview = true`) returning an HTML card at 600×800 with base64 cover, title, platform, game id, region, maker code, disc number, file size, last played and favorite. Mirrors Provenance's `GameMetadataCard` layout but is written fresh in Swift string templates inside the extension (no shared package with Provenance).
* Memory: the thumbnail extension reads at most 64 KiB from the disc plus one JPEG under 1 MB. No core, no network.

### 3.5 iCube: entitlements and signing

* Add `com.apple.security.application-groups = [group.com.joemattiello.icube]` to all four entitlements files and to the three new extension entitlements.
* Ship `docs/app-group-entitlements.md` with the portal checklist: create the group, enable App Groups on all eight app ids and the 3×8 extension ids (or rely on automatic signing with `-allowProvisioningUpdates`, which registers them on first build), then regenerate profiles. Note the wildcard-profile trap from iFly.
* CI (`.github/workflows/build.yml`, `release.yml`) re-signs with `Public.entitlements` / `Private.entitlements`; those now carry the group so the `.appex` bundles keep working after re-sign. The re-sign step must also sign the embedded `PlugIns/*.appex` (verify `CreateIpa.sh` recurses).

### 3.6 Provenance: Realm-free extensions

* **Top Shelf:** in `project.pbxproj`, point `Provenance (AppStore)`'s target dependency and "Embed Foundation Extensions" entry at the `TopShelf` target (`BE9FDCB61C210B9E0046DF0E`) instead of `TopShelfv2` (`B39B10AA2DAF3D16004EEF79`). Delete the `TopShelfv2` target, its build files, its group, and `Extensions/TopShelfv2/`. Fix the stale sentence in `docs/superpowers/specs/2026-08-07-macos-visionos-strategy-design.md:127-129` that calls `TopShelf` the dead one.
* **Snapshot additions in `PVLibrarySnapshot`:** a new file-based index for Quick Look, because thousands of games do not belong in UserDefaults. `LibraryIndexFile` writes `<group>/LibraryIndex/games-by-filename.json` (`[filename: LibraryIndexGame]`, where `LibraryIndexGame` carries every `GameInfo` field plus `artworkKeyHash` = md5 of `artworkURL` precomputed by the host) and `savestates-by-filename.json` (`[filename: relativeImagePath]`). Written atomically (temp file + rename). Reader side: `LibraryIndexReader.game(forROMFilename:)`, `saveStateImagePath(forFilename:)`, memoised per process.
* **Host writer:** `WidgetDataWriter+Realm.swift` gains `writeLibraryIndex()` that projects all `PVGame` and `PVSaveState` rows; it runs on the existing seven trigger sites but debounced to at most once per 30 s for the full index (the small `widget.*` lists keep their current cadence). Import completion (`PVGameLibraryUpdatesController`) bypasses the debounce.
* **`PVQuickLookSupport` goes Realm-free:** `Package.swift` drops `PVLibrary`, `PVHashing`, `RealmSwift` and depends on `PVAppIntents`'s `PVLibrarySnapshot` product only. `RealmGamePreviewDataSource` is replaced by `SnapshotGamePreviewDataSource` reading `LibraryIndexReader`. `ArtworkResolver` keeps the four group-container candidate paths, takes the precomputed hash, and drops the `PVMediaCache` fallback. `PVAppGroupId` is replaced by `LibrarySnapshotAppGroup.identifier`. Existing `ROMGameLookupTests` are updated to the new data source with a temp-directory index.
* **Targets:** `ThumbnailExtension` and `QuickLookPreview` lose `PVLibrary`/`RealmSwift` framework links. `QuickLookPreview` drops `PreviewViewController.swift` and `MainInterface.storyboard`, and is added to `Provenance (AppStore)`'s target dependencies and "Embed Foundation Extensions" phase with `platformFilters = (ios, maccatalyst)`. The stale "(#3310)" comment in `PreviewProvider.swift` goes.

### 3.7 iFly fixes

* Remove the `#if !os(tvOS)` guard at `iFlyApp.swift:1181-1183` so cold launch and foreground refresh the snapshot on tvOS too.
* Call `WidgetDataWriter.refresh()` at the end of `SyncCoordinator.performSync()` (line 387) when at least one file was downloaded, so a save state made on iPhone shows up in the Apple TV's "Recent Saves" row without a local play.
* Delete the "TEMP DIAGNOSTIC" blocks in `TopShelfContentProvider.swift`, keeping one `Logger` line per section built. Tick the `release-qa-checklist.md:50` item only after Joe verifies on a properly signed build. That is a manual step.

## 4. Testing and gates

* `swift test` for iCube `PVLibrarySnapshot` (header reader, snapshot round-trip, lookup fallbacks) and for Provenance `PVAppIntents` (index writer/reader) and `PVQuickLookSupport` (updated data source tests).
* iCube local device build with `-configuration "Debug (Non-Jailbroken)"` per existing notes, then: Files app shows a cover for an RVZ and a placeholder for a GCZ; tvOS Top Shelf shows a played game after one launch and launches it on select. tvOS simulator is acceptable for layout, the Apple TV is the gate for artwork because of the signing trap.
* Provenance: `Provenance (AppStore)` tvOS build produces exactly one `.appex` under `PlugIns/` named for `TopShelf`; iOS build embeds both Quick Look extensions; `otool -L` on each `.appex` shows no Realm.
* iFly: tvOS build, background the app, foreground it, confirm the snapshot `updatedAt` advanced.

## 5. Out of scope

* A "recently played" sort in iCube's library view (the store lands; the UI row is a follow-up).
* Recent save states row on iCube Top Shelf.
* GCZ/TGC/WAD header parsing.
* Provenance's Quick Look UTI list, `SystemIconProvider`, `GameMetadataCard` content, and the `Extensions/macOS` stubs.
* A native macOS or Catalyst product for iCube. The Quick Look targets are declared for Catalyst so Finder support arrives with the first Mac build, but nothing here ships one.

## 6. Order of work

1. iCube `PVLibrarySnapshot` package with tests.
2. iCube app group entitlements, shared-suite migration, `LastPlayedStore`, `LibrarySnapshotWriter`, `play` deep link.
3. iCube Top Shelf target (Tuist + fallback project), device gate.
4. iCube Quick Look targets, device gate.
5. Provenance index writer, `PVQuickLookSupport` Realm removal, target rewiring, `TopShelfv2` deletion.
6. iFly refresh fixes and log cleanup.

Each step is its own commit set. Steps 5 and 6 are independent of 1–4 and can run in parallel worktrees.
