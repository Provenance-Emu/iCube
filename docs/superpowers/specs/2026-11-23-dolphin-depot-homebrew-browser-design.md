# Homebrew browser (Dolphin Depot): design

Date: 2026-11-23. Status: approved by the owner 2026-11-23.

## Intent

iCube users can only play what they bring. Dolphin Depot (dolphindepot.org) is a
community catalogue of free GameCube homebrew: 72 titles today, each a small zip.
A Homebrew browser inside iCube lets someone find one, read about it, download it
and play it without leaving the app or owning a disc.

## Goals

- Browse the whole Dolphin Depot catalogue inside iCube, split by the catalogue's
  own categories (Games, Emulators, Utilities, Demos, Media), with search.
- A detail page per title: description, author, licence, screenshots, compatible
  hardware, version, size, release date, links.
- One tap downloads a title, puts it in the library with its real name and
  artwork, and offers to play it.
- Show which titles are already installed and which have a newer version.
- Works on iOS, tvOS and Mac Catalyst from the same views.

## Non-goals

- No hide list. Every published title is shown (owner decision, 2026-11-23).
- No GameCube SD card emulation. Titles that read files from an SD card
  (emulators, media players) are listed and boot, but find no files.
- No submitting, liking or rating; no Dolphin Depot account.
- No other homebrew catalogues. The client is specific to Dolphin Depot; a
  second catalogue would be a later refactor.
- No background downloads. The largest package is 166 MB and most are under
  1 MB; a foreground download with resume is enough for a first version.
- No verification of the CDN's `x-signature-ed25519` header (the public key is
  not published in the docs read so far).

## Anti-goals

- A title that lands in the library named `default` with no cover.
- Hammering a volunteer-run API: no polling, no per-row requests.
- Hiding who made a title or its licence.
- A download that leaves a half-unpacked folder the library then lists.

## What Dolphin Depot provides (observed 2026-11-23)

- `https://api.dolphindepot.org` is a PostgREST API, no key, JSON.
  - Categories: `/categories?select=id,name,display_name,sort_order&order=sort_order.asc`
  - Whole catalogue in one request: `/apps?select=slug,name,author,description_short,description_long,banner_path,hero_path,screenshot_paths,downloads_count,likes_count,categories(...),app_versions(...),app_peripherals(peripherals(*)),app_platforms(platforms(*)),app_licenses(spdx,url,notes),app_external_resources(type,label,url,notes,sort_order)`
    with `is_published=eq.true`, `app_versions.is_latest=eq.true`,
    `app_versions.is_published=eq.true`.
  - A version row has `version`, `version_slug`, `size`, `package_type` (`zip`
    for all 71 with a release), `release_date`, `changelog`.
- `https://cdn.dolphindepot.org/<slug>/release/<slug>_<version>_dist.zip` is the
  package; `https://cdn.dolphindepot.org/<path>` serves `banner_path`,
  `hero_path` and `screenshot_paths`. Packages are immutable and carry an `etag`
  and `content-length`.
- A package is laid out like an SD card: the program is usually
  `apps/<name>/default.dol`, with `opening.bnr` beside it and sometimes data.
- Terms: the public API is part of the service; scraping "at a rate that
  materially burdens the Service" is not allowed.

The exact file name pattern, whether the `etag` is the file's MD5, and which
image suits a library cover are to be confirmed by the builder against live
responses before relying on them.

## Approaches

1. **A Homebrew browser of its own (chosen).** New screens modelled on the
   GameBanana mod browser: categories, search, detail page, download. Costs new
   UI on both platforms; gives categories, authorship and licences a home.
2. **A source in the library's filter bar.** One new `RemoteGameCatalog` beside
   Emulation Server and RomM. Much less work, but that grid is flat: no
   categories, no detail page, no author or licence. Rejected because the owner
   wants categories.
3. **Bundle the catalogue in the app.** No network dependency, but stale on the
   day it ships and makes iCube a redistributor. Rejected.

The owner picked 1 on 2026-11-23.

## Design

All new code lives in `Source/iOS/App/Common/Homebrew/`.

### Catalogue client

- `actor DolphinDepotClient`, shaped like `GameBananaClient`: a
  `DolphinDepotTransport` protocol as the test seam, a `DolphinDepotEndpoint`
  enum that builds URLs so query strings are testable without a client, a 30 s
  timeout, a generic `iCube/<version>` user agent.
- One request loads the whole catalogue (72 rows). It is kept in memory for
  10 minutes and also written to Caches so the browser opens instantly and
  still lists titles offline; pull to refresh (iOS) or a Refresh row (tvOS)
  forces a reload.
- Models (`HomebrewTitle`, `HomebrewCategory`, `HomebrewVersion`,
  `HomebrewLicence`, `HomebrewLink`) decode leniently: an unknown category or a
  missing optional field must not drop the whole catalogue. A title with no
  published version is listed without a Download button.
- Images go through the existing `RemoteCoverCache`.

### Screens

`HomebrewBrowserRoot` is a `NavigationStack` in a sheet, presented like the mod
browser (`.claimsController()`, plain `List` rows and `NavigationLink`, no
`Menu` or `Picker`, so it works on tvOS).

```
Homebrew                                  [Search]
-------------------------------------------------
Games (32)                               See all >
  [img] ClassiCube     AndrewPH          Installed
  [img] Neverball      ...               711 KB
Emulators (13)                           See all >
  ...
Utilities (20) / Demos (1) / Media (6)
-------------------------------------------------
Catalogue from Dolphin Depot
```

- Root: one section per category in the catalogue's `sort_order`, a few titles
  each (most downloaded first) and a "See all" row; searching replaces the
  sections with one flat result list over name, author and short description.
- Category list: every title in the category, sorted by name, with a sort
  choice (name, most downloaded, recently updated) as a `ModChoiceList`-style
  row.
- Detail: hero image and screenshots, name, author, long description, licence
  (SPDX id, link), compatible hardware, version, size, release date, external
  links (plain text plus "open on another device" on tvOS, as the mod browser
  does), and one primary button whose label follows the state: Download,
  progress with Cancel, Play, or Update.
- Emulators and Media titles carry one line under the button: they look for
  files on an SD card, which iCube does not provide yet. (Proposed by the
  designer, not requested by the owner.)

### Entry point

- A "Get Homebrew…" button in the library's Import menu section, which iOS and
  the tvOS toolbar sheet share. (Designer's call; a tvOS rail row can follow.)
- `HomebrewBrowser.isEnabled` is a constant kill switch like
  `ModBrowser.isEnabled`. Shown in every build, App Store included, as the mod
  browser is. (Designer's call: flip it if review objects.)

### Download and install

`HomebrewInstallModel` is a state machine like `ModInstallModel`: idle,
downloading(progress), verifying, installing, installed, failed(reason).

1. Check free space (`ModDownloadPolicy`'s check) and confirm a large download
   over mobile data with the existing threshold.
2. Download the zip to a staging folder in Caches with resume data. Reuse
   `ModDownloadManager` by giving it a small protocol for "something
   downloadable" (URL, size, id) rather than copying it.
3. Verify the byte count against the catalogue's `size`; verify MD5 against the
   `etag` only if the builder confirms the etag is an MD5.
4. Unpack with `ZipImportHelper.extractArchive` (already zip-slip safe) into
   staging.
5. Pick the program with a pure function, `HomebrewPackageLayout.program(in:)`:
   the only `.dol`/`.elf` if there is one; else `apps/*/default.dol`, then
   `apps/*/boot.dol`; else fail with "this package has no program iCube can
   start". It must pass `DiscImageBridge.gameItem(forPath:)`.
6. Move the whole unpacked folder to `Software/Homebrew/<slug>/` through
   `ContinuityPaths.validatedURL`. An update unpacks beside the old folder and
   swaps only after step 5 passes, so a failed update keeps the old version.
7. Register with `TVLibraryBridge.updateLibrary(withRemotePaths:fetchMetadata:)`.
8. Set the library title and cover from the catalogue through
   `LibraryMetadataService` (`resolveIdentity`, `store().commit`, `didChange`),
   with the cover passed through `prepareCover`. A title or cover the user has
   since edited is not overwritten on update.
9. Record `slug -> version, program path` in
   `Software/Homebrew/installed.json`. The browser reads it to show Installed
   and Update; an entry whose program file is gone counts as not installed.

Deleting the game from the library is the uninstall; no separate remove button.

### Decisions added after the builder check (designer's calls)

- **Identity.** A `.dol` has no game ID; the library identifies it by content
  hash (`LibraryMetadataService.resolveIdentity`), so two titles never collide.
  An update has new bytes and so a new identity: the installer reads the old
  identity's title and cover before the swap and writes them to the new one.
  That carries a user's edits forward with no "who set it" flag; when the old
  entry has no metadata, the catalogue's title and cover are written. The
  builder must check what per-game settings and save states key on for a
  `.dol` and say so in the plan if an update orphans them.
- **Registration is by explicit path** (`updateLibrary(withRemotePaths:)`), so
  folder depth does not matter.
- **Nothing writes inside the install folder**: without an SD card the program
  has nowhere to save, so an update replaces the folder whole.
- **Orphans.** When the browser opens it removes any `Software/Homebrew/<slug>/`
  folder whose recorded program file is gone, and its index entry.
- **Several programs in one package:** one library entry, the first match of
  the rule in path order. The index holds one program path per slug.
- **Update available** means the catalogue's `version_slug` differs from the
  installed one. No ordering.
- **`ModDownloadManager` changes are additive only**; the mod browser's
  behaviour and tests must not change.
- **No licence filtering.** Every published title is listed and its licence
  shown.
- **tvOS discoverability** beyond the shared Import section is not needed for
  the first version.

### Errors

- Catalogue unreachable: show the cached catalogue with a quiet "showing saved
  list" line, or an empty state with Retry when there is none.
- Download failure keeps resume data; Cancel discards it.
- Size mismatch, bad zip, no program: failed state with a plain sentence and
  staging removed. Nothing is registered with the library.

## Constraints

- Strings through `L("…")`, added to both `en.lproj/Core.strings` and
  `ja.lproj/Core.strings`; `check_localized_keys.py --check`,
  `check_design_tokens.py --check` and `check_button_types.py` must pass.
- `ICubeDesign` tokens only; no new hard-coded fonts, radii or colours.
- tvOS: every row one focus target; no `Menu`, `Picker`, `Link`.
- New source files must be picked up by `Project.swift` (Tuist globs).
- No user data is sent to Dolphin Depot beyond the requests themselves.
- No Dolphin Depot artwork or packages are committed or used as fixtures;
  fixtures are hand-written JSON in the API's shape.

## Tests (XCTest, `DolphiniOSTests/`)

- Decoding: full catalogue fixture, missing optionals, unknown category, title
  with no version.
- `DolphinDepotEndpoint`: URLs and query strings; package and image URLs.
- Client: cache window, forced refresh, disk fallback when the transport fails.
- `HomebrewPackageLayout`: single program, `default.dol` under `apps/`, several
  programs, none.
- Installed index: round trip, missing program file, update detection.
- `HomebrewInstallModel`: happy path and each failure with a fake downloader.
- Search and sort: pure functions over the model.

## Left to the builder

- The package file name rule and etag meaning (check live responses).
- Which image (`banner` or `hero`) crops best as a library cover.
- How many titles each root section shows on iPhone, iPad and tvOS.
- Whether `ModDownloadManager` is generalised in place or wrapped.

## Device checks owed after the build

- Download and boot one game on an iPhone and on an Apple TV.
- tvOS focus through root, category, detail and back.
- An update of an installed title.
