# Skin store (provenance-emu.com/skins) — design

**Status:** approved in conversation by the owner on 2026-10-11 (including the N64 shelf).
**Scope:** iOS only. tvOS has no on-screen controls and gets nothing here.

## 1. What exists, what this adds

iCube already imports, parses, draws and plays Delta (`.deltaskin`) and Manic (`.manicskin`)
controller skins for GameCube and Wii (`feature/controller-skins`, merged; code under
`Source/iOS/App/DolphiniOS/UI/Emulation/Skins/`, picker at
`Common/UI/Settings/SwiftUI/SkinPickerView.swift`). Real skins and the Swift-drawn overlay already
share one host (`HostedOverlayRoot`), one hit tester and one input writer, so this design does not
touch rendering or input semantics.

This adds the missing piece: an in-app **store** that browses the Provenance skin catalog and
installs skins with one tap, modelled on iFly's store (`iFly/Sources/Core/Skins/Store/`,
2026-10-07) and built on top of `SkinLibrary.importSkin`.

### Decisions
1. **Keep iCube's renderer.** Provenance's `DeltaSkinView`/`DeltaSkinInputHandler` stack is
   ~12k lines coupled to Realm, PVEmulatorCore and PVSettings. The "one format for generated and
   real skins" idea (a generated skin conforming to the skin protocol) was tried in both iFly
   (`DefaultDeltaSkin.swift`, now unreferenced) and Provenance (deleted in `e6a8771d84`); both moved
   to the shape iCube has. Nothing is ported from the renderer side.
2. **Three shelves:** GameCube, Wii, and "Made for Nintendo 64" (buttons remapped onto the
   GameCube pad). The catalog holds one `gamecube` skin and no `wii` skins today (2026-10-11,
   1358 entries); the N64 shelf (57 entries) is what makes the store worth opening.
3. **Install reuses `SkinLibrary.importSkin`.** No second importer, no sidecar files. A retarget
   is a rewrite of the extracted `info.json` before validation.
4. **Installing does not select.** The picker underneath updates live; the player picks per pad
   kind and orientation as today.

## 2. Catalog facts (live feed, 2026-10-11)

- URL: `https://provenance-emu.com/skins/catalog.json`; mirror
  `https://raw.githubusercontent.com/Provenance-Emu/skins/main/catalog.json`. One flat file,
  about 1 MB, schema `version: 2`.
- Root: `version`, `lastUpdated` (ISO 8601), `totalSkins`, `skins[]`.
- Entry: `id` (16 hex), `name`, `author`, `systems[]` (short codes, mixed case: `gamecube`,
  `wii`, `n64`, `threeDS`...), `gameTypeIdentifier` (mostly null; Manic style
  `public.aoshuang.game.ngc` when set), `downloadURL`, `thumbnailURL` (null for 120 entries),
  `screenshotURLs`, `tags`, `deviceSupport` (always empty), `downloadCount`, `rating`,
  `lastUpdated` (ISO 8601 **or** bare `2025-09-23`), `fileSize` (always null), `source` (host
  such as `deltastyles.com`, or `owner/repo`), `description`, `submittedBy`, `submittedAt`,
  `groupId`, `groupOrder`.
- Downloads: 1157 `.deltaskin`, 145 `.manicskin`, 45 `.zip`, 11 extensionless (Google Drive)
  and 2 shop links. Hosts: `deltastyles.com` (1110), GitHub raw/releases (236), others.
  Nothing is re-hosted: iCube downloads from `downloadURL` and credits author and host.
- Thumbnails: GitHub releases/raw PNGs; some return `application/octet-stream`, which
  `AsyncImage` decodes fine.
- Placeholder codes to ignore: `unofficial`, `unsupported`, `unknown`.

## 3. Backend

All new files live in `Source/iOS/App/DolphiniOS/UI/Emulation/Skins/Store/` and are wrapped in
`#if os(iOS)`. They are picked up by the existing `DolphiniOS/**` Tuist glob; run
`tuist generate --no-open` after adding them.

### 3.1 Catalog model (port of iFly, verbatim where possible)
- `SkinCatalog` (`Decodable`): `version?`, `lastUpdated?`, `totalSkins?`, `skins`,
  `droppedEntryCount`. `skins` decodes lossily: an entry that fails is counted and skipped.
- `SkinCatalogEntry` (`Decodable, Hashable, Identifiable, Sendable`): `id`, `name`,
  `downloadURL` required; every other field `try?`. `url(from:)` percent-encodes raw spaces and
  stray `\u{00C2}\u{00A0}` seen in real feed URLs. `normalizedSystems` lowercases.
  `gameTypeSuffix`: the last dot component of `gameTypeIdentifier`, lowercased, or nil.
- `SkinCatalogDates.parse`: full ISO 8601, fractional seconds, bare date; else nil.
- `SkinCatalogError`: `.httpStatus(Int)`, `.network(String)`, `.decoding(String)`.
- `SkinCatalogLoad`: `catalog` plus `networkError: String?` (set when a cached copy stood in).

### 3.2 `SkinCatalogService` (actor, port of iFly)
- Mirrors tried in order; `URLRequest` with `.reloadIgnoringLocalCacheData`, 30 s timeout.
- Cache: the server's bytes verbatim at `<Caches>/skin_store_catalog.json`; freshness is the
  file's mtime, TTL 24 h, stamped from an injected clock so it holds across launches.
- `load(forceRefresh:)`: fresh cache → network → in-memory copy → disk copy (any age) → throw.
- `cachedCatalog()` paints the screen before the network answers. `invalidateCache()`.
- Injectable `catalogURLs`, `cacheURL`, `ttl`, `now`, `fetch` for tests.

### 3.3 `SkinStorePolicy` (pure)
- `SkinStoreSection`: `.gameCube`, `.wii`, `.nintendo64`; `ordered` in that order.
- `section(for:)`: nil when the download extension is not `deltaskin`/`manicskin`
  (`SkinLibrary.archiveExtensions`). Otherwise codes = lowercased `systems` minus placeholders,
  plus the game-type suffix mapped through `SkinGameType` (`ngc`/`gc`/`gamecube` → `gamecube`,
  `wii` → `wii`, `n64` → `n64`). Precedence: `gamecube` > `wii` > `n64`; anything else nil.
- `sections(for:)`: visible entries grouped, ordered, empty shelves omitted, feed order kept.
- `retarget(for:)`: `.nintendo64` → `.gameCube`; the others nil (install as-is).
- `downloadFileName(for:)`: `<entry id>.<ext>`, id sanitised of path characters.

### 3.4 Retarget in `SkinLibrary`
- `importSkin(from:retargetingTo: SkinGameType? = nil)`. After extraction and locating the
  skin folder, when a target is given: read `info.json`, strip comments, parse as a JSON object,
  set `gameTypeIdentifier` to the target's Manic identifier (`public.aoshuang.game.ngc`), set
  `identifier` to `<identifier>-gamecube`, write back pretty-printed, then continue with the
  normal validation and install. An N64 skin imported as-is still throws
  `unsupportedGameType`; only the store asks for a retarget.
- `SkinGameType.manicIdentifier` (`ngc` / `wii`) and `SkinGameType.retargetSuffix` live in
  `SkinGameType.swift`.
- N64 input names on the GameCube pad, added to `SkinInputMap.gameCubeControls`:
  `cUp`/`cDown`/`cLeft`/`cRight` (plus the `c-up` and `c▲▼◀▶` spellings Provenance accepts) →
  `.axisButton` on the C-stick half-axes 16/17/18/19. `l`, `r`, `z`, `start`, `a`, `b`, the
  d-pad and `leftThumbstick` already map. Unknown names stay ignored.

### 3.5 `SkinStoreInstaller` (`@MainActor ObservableObject`, port of iFly)
- `@Published states: [catalogId: SkinStoreInstallState]`, `@Published installedIds`.
- `SkinStoreInstallState`: `.idle`, `.downloading(progress)`, `.installing`, `.installed`,
  `.failed(message)`.
- `startInstall(entry)` runs one `Task` per id; `cancelInstall(entry)` cancels it and the entry
  returns to idle. `install(entry)`: section + file name from the policy (else `.failed`),
  download to `<tmp>/SkinStore-<uuid>/<id>.<ext>` with progress, then the install step, then
  record and `.installed`. Cancellation (`CancellationError` or `URLError.cancelled`) → `.idle`.
- `SkinStoreDownloading` protocol; `URLSessionSkinStoreDownloader` uses a download task with a
  delegate for progress, rejects non-2xx (`HTTPStatusError`), moves the file in
  `didFinishDownloadingTo`.
- Install step (injectable; default): `SkinLibrary.shared.importSkin(from: file,
  retargetingTo: policy.retarget(for: section))`. The library already scans the archive for
  unsafe entries, unzips, validates `info.json` (so an unreadable skin fails the install here,
  no "prove it loads" pass needed), replaces atomically and announces the change.
- `SkinStoreInstalledRecord`: `[catalogId: skinIdentifier]` in `<UserFolder>/Skins/store.json`,
  beside `selection.json`, atomic writes. `reconcile(with: installedSkinIds)` drops records whose
  skin is gone, so the store offers it again after a delete in the picker.
- `state(for:)`: a transient state wins; else `.installed` when recorded; else `.idle`.
- Logging: `NSLog` with a `[SKINSTORE]` prefix, as the rest of the touch layer does.

## 4. UI

`Common/UI/Settings/SwiftUI/SkinStoreView.swift` (+ `SkinStoreViewModel.swift`), `#if os(iOS)`,
SwiftUI, design tokens from `ICubeDesign` (`icubeText` roles, `Spacing`, `Radius`,
`ICubeDesign.color`) so `check_design_tokens.py --check` stays green.

- **Entry point:** a "Browse Catalog…" toolbar button beside "Import…" in `SkinPickerView`,
  presenting `SkinStoreView` in a sheet inside a `NavigationStack` with a Done button.
- **Layout:** `ScrollView` → intro line → offline banner (when a cached copy stands in) →
  one shelf per section: header (`section` role) with count, note (`detail` role; N64 explains the
  remap), `LazyVGrid` of cards (adaptive 160–240 pt) → credit footer. Pull-to-refresh and a
  refresh toolbar button.
- **Card:** thumbnail (`AsyncImage`, placeholder: gamepad glyph + system name), system badge
  (`tag` role capsule), name (`body`), "by author" and source host (`detail`), then the action
  view: Install pill; download progress with a cancel button; "Installing"; "Installed"; or the
  failure message with Retry.
- **States:** loading spinner on first load with nothing cached; failed view with "Try Again"
  when nothing is cached; empty shelf set shows a message and a `Link` to
  `https://provenance-emu.com/skins/submit.html`.
- **Not built:** detail page, search, sort, ratings, screenshots, delete (delete stays in the
  picker), tvOS.
- `SkinStoreViewModel`: `loadIfNeeded()` paints the cache then loads; `refresh()` forces the
  network; `reconcileInstalled()` on appear using `SkinLibrary.shared.skins`.
- Every string goes through `L("…")` with identity entries added to `en` and `ja`
  `Core.strings`.

## 5. Tests (`iCubeTests`, `#if os(iOS)`)

- `SkinCatalogDecodingTests`: a verbatim fixture slice of the live feed (`SkinCatalogFixture`,
  a raw-string Swift constant: the GameCube Pocket entry, several `n64`, a `.zip`, a Google Drive
  link, an `unofficial`, a `threeDS`, a date-only `lastUpdated`, null fields, `groupId`), plus a
  hand-written bad-entry catalog: count first, then fields.
- `SkinCatalogServiceTests`: injected fetch and clock; first fetch writes the cache; TTL serves
  memory; fresh disk cache across instances; expiry refetches; force refresh; offline falls
  back to a stale cache; HTTP error falls back or throws; second mirror tried; `cachedCatalog`
  never fetches.
- `SkinStorePolicyTests`: sections from the fixture and from synthetic entries (precedence,
  placeholder codes, game-type suffix, case-insensitive extension, hidden `.zip` and
  extensionless), ordering, retarget routing, file names.
- `SkinStoreInstallerTests`: fake downloader and a temp `SkinLibrary`; success records the id and
  the file is named `<id>.<ext>`; installed state survives a new installer; download failure and
  install failure surface messages; the state sequence; cancellation; a `.zip` entry fails without
  downloading; reconcile forgets deleted skins; the default install step installs the TestCube
  fixture archive through a real `SkinLibrary`.
- `SkinLibraryTests`: retarget rewrites game type and identifier and the skin installs as
  GameCube; the same archive without a retarget throws `unsupportedGameType`.
- `SkinInputMapTests`: the C-button names map to the C-stick half-axes on GameCube only.

## 6. Risks

- **Catalog hosts are third parties.** A dead `deltastyles.com` link answers HTML with 200 in
  some cases; the library then fails with `unreadableArchive`, which the card shows with Retry.
- **Store nearly empty for GameCube/Wii.** Expected; the empty state links to the submit page.
  The N64 shelf carries the store until the catalog grows.
- **N64 skins keep N64 art and labels.** The shelf note says so.
- **Localization:** ja gets identity entries, as every DolphiniOS-only string does.

## 7. Build order

1. Catalog models, service, policy, retarget and C-button mapping, with tests.
2. Installer, downloader, record, with tests.
3. View model, view, picker entry point, strings, token-lint and localization checks.
4. Owner device pass: install one skin per shelf, pick it, play.
