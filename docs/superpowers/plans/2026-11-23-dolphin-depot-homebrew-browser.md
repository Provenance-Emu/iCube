# Homebrew Browser (Dolphin Depot) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A "Get Homebrew…" browser in iCube that lists Dolphin Depot's catalogue by category, downloads a title, and puts it in the library under its real name and artwork.

**Architecture:** A read-only `DolphinDepotClient` actor loads the whole catalogue in one request and keeps a disk copy. Pure functions do search, sort, package layout and the installed index. `HomebrewInstallModel` drives download, verify, unpack and install through two small protocols (a downloader and a library registrar) so it is testable without the network or the emulator core. SwiftUI screens mirror the GameBanana mod browser.

**Tech Stack:** Swift, SwiftUI, XCTest (`@testable import iCube`), URLSession, existing `ModDownloadManager`, `ZipImportHelper`, `LibraryMetadataService`.

**Spec:** `docs/superpowers/specs/2026-11-23-dolphin-depot-homebrew-browser-design.md`

## Global Constraints

- All paths below are relative to `Source/iOS/App/` unless they start with `docs/`.
- New product code lives in `Common/Homebrew/`; tests in `DolphiniOSTests/`; fixtures in `DolphiniOSTests/Fixtures/Homebrew/`. Tuist globs `Common/**/*.swift`; check how `Project.swift` picks up test fixtures (`Fixtures/GameBanana` is the model) and add the new folder the same way.
- Every file starts with the two-line header the neighbours use (`// Copyright 2026 iCube Project` / `// SPDX-License-Identifier: GPL-2.0-or-later`). Two-space indent, as in `Common/Mods/Browser/`.
- User-visible strings go through `L("…")` and are added to both `Common/UI/Localization/en.lproj/Core.strings` and `ja.lproj/Core.strings` (identity entries in both, as existing keys do).
- `ICubeDesign` tokens only (`.icubeText(.detail)`, `ICubeDesign.color(.textSecondary)`, `ICubeDesign.Radius`). No new hard-coded fonts, radii or colours.
- tvOS: every row is one focus target. No `Menu`, `Picker` or `Link`. Use `ModChoiceList` for choices.
- No Dolphin Depot artwork or packages in the repo. Fixtures are hand-written JSON in the API's shape; test zips are built in the test from in-memory bytes.
- `ModDownloadManager` changes are additive: `download(_ file: GameBananaFile, …)` keeps its signature and behaviour, and `ModInstallModelTests` must pass unchanged.
- Requests carry only `User-Agent: iCube/<version>` and `Accept: application/json`. Nothing about the user or device.
- Commits: conventional subjects, no `Co-Authored-By` or other attribution trailers. This checkout is shared with other sessions: work in a worktree of branch `feature/homebrew-browser`, and run `git checkout -- build/xcframework` before committing if a local build touched it.
- Run one test class with `make test TEST_ARGS="-only-testing:iCubeTests/<Class>"` from `Source/iOS/App` (read the `test` target in the `Makefile` there first for `DEST`).

## Facts checked against the live service (2026-11-23)

- One request returns all 72 titles (194 KB):
  `https://api.dolphindepot.org/apps?select=slug,name,author,description_short,description_long,source_url,banner_path,hero_path,screenshot_paths,downloads_count,likes_count,updated_at,categories(name,display_name,sort_order),app_versions(version,version_slug,size,release_date,changelog,app_version_assets(file_name,file_size)),app_peripherals(peripherals(*)),app_platforms(platforms(*)),app_licenses(spdx,url,notes),app_external_resources(type,label,url,notes,sort_order)&is_published=eq.true&app_versions.is_latest=eq.true&app_versions.is_published=eq.true&order=name.asc`
- `categories` and `app_licenses` are single objects (or null), not arrays. `app_versions` is an array of 0 or 1 (one title, `gbi`, has none). `app_version_assets` has exactly one entry for the other 71, and its `file_size` equals the version's `size`.
- Package URL: `https://cdn.dolphindepot.org/<slug>/release/<app_version_assets[0].file_name>`. Use the catalogue's file name; do not build it from the version.
- The package response's `ETag` is the file's MD5 in quotes (checked on three packages).
- Image URL: a path such as `classicube/banner.png` is served at `https://cdn.dolphindepot.org/classicube/image/banner.png`: insert `image/` after the first path component. `banner` is 96x32 (a GameCube banner), `hero` is 640x160 and only 12 titles have one, screenshots are 640x480 and 69 titles have at least one.
- Dates look like `2026-11-20T08:45:09.843+00:00` (ISO 8601 with fractional seconds).
- Peripheral and platform rows have `name` and `display_name`.
- Packages seen: `apps/<slug>/default.dol` with an optional `opening.bnr`.

## Decisions this plan adds to the spec

- **The program is renamed on install.** Dolphin gives a `.dol` or `.elf` the game ID `ID-<file name without extension>`, so every `default.dol` would share one set of per-game settings and save states. The installer renames the chosen program to `<slug>.<ext>` inside its folder. The game ID becomes `ID-<slug>`: unique per title and unchanged by updates, so settings and save states survive an update.
- **Library cover:** first screenshot, else hero, else banner, else none.
- **Browser images** use `AsyncImage`, as the mod browser does. `RemoteCoverCache` is a store, not a fetcher, and is not used.
- **Categories come from the titles** (`categories(name,display_name,sort_order)` embedded in each row); there is no second request, so a category with no titles is not shown.
- **Play** dismisses the browser, then calls `DiscPatchFlow.launch(path:)`.
- **tvOS presentation** is `.fullScreenCover`, because tvOS 26 draws a `.sheet` as a small card (see the Sources sheet in `TVLibraryView.swift`).
- **Root sections show 4 titles** on every platform.

## Review Focus

1. A catalogue row with a `slug` or asset `file_name` that is not a plain name (`../x`, empty, leading dot, a slash): the title is listed without a Download button and nothing is written outside `Software/Homebrew/<slug>/`. (Task 1, Task 4)
2. The catalogue answers HTTP 200 with a PostgREST error object or an empty array: the saved list stays on disk and on screen. (Task 2)
3. A package whose only program is at the zip's root, or in a folder not called `apps`: it still installs. (Task 4)
4. The user deletes an installed title from the library, then opens the browser: the title shows Download again and its leftover folder is removed. (Task 4, Task 6)
5. An update fails after download (bad zip, no program): the old version still boots and still shows Installed. (Task 6)

---

### Task 1: Catalogue models and decoding

**Files:**
- Create: `Common/Homebrew/HomebrewModels.swift`
- Create: `DolphiniOSTests/Fixtures/Homebrew/catalogue.json` (hand-written, 4 rows: a full row; a row with `app_versions: []`; a row with `categories: null` and every optional missing; a row with `slug: "../evil"`)
- Test: `DolphiniOSTests/HomebrewDecodingTests.swift`

**Interfaces:**
- Produces:

```swift
struct HomebrewCategory: Hashable, Identifiable, Sendable {
  let name: String; let displayName: String; let sortOrder: Int
  var id: String { name }
}
struct HomebrewVersion: Hashable, Sendable {
  let version: String; let versionSlug: String; let size: Int64
  let fileName: String; let releaseDate: Date?; let changelog: String?
}
struct HomebrewLicence: Hashable, Sendable { let spdx: String?; let url: URL?; let notes: String? }
struct HomebrewLink: Hashable, Sendable { let label: String; let url: URL }
struct HomebrewTitle: Hashable, Identifiable, Sendable {
  let slug: String; let name: String; let author: String
  let summary: String; let details: String          // description_short / description_long
  let category: HomebrewCategory?
  let bannerPath: String?; let heroPath: String?; let screenshotPaths: [String]
  let downloads: Int; let likes: Int; let updatedAt: Date?
  let latest: HomebrewVersion?                       // nil = listed without Download
  let licence: HomebrewLicence?; let links: [HomebrewLink]
  let hardware: [String]; let platforms: [String]    // display names
  var id: String { slug }
  var coverPath: String? { get }                     // first screenshot, else hero, else banner
  var needsSDCard: Bool { get }                      // category name is "emulators" or "media"
}
struct HomebrewCatalogue: Sendable {
  let titles: [HomebrewTitle]
  var categories: [HomebrewCategory] { get }         // distinct, by sortOrder then name
  static func decode(_ data: Data) throws -> HomebrewCatalogue
}
enum HomebrewName { static func isSafe(_ name: String) -> Bool }
```

- [ ] **Step 1: Write the failing tests** in `HomebrewDecodingTests`:
  - `testDecodesFullRow`: name, author, `category?.name == "games"`, `latest?.fileName`, `latest?.size`, `latest?.versionSlug`, `releaseDate` non-nil for `2026-11-20T08:45:09.843+00:00`, `licence?.spdx`, `hardware == ["Controller", "SD Gecko"]`, one link.
  - `testRowWithoutVersionIsListedWithoutDownload`: `latest == nil`, title still present.
  - `testMissingOptionalsDoNotDropTheRow`: `category == nil`, `screenshotPaths == []`, `licence == nil`, `details == ""`.
  - `testUnsafeSlugIsDropped`: no title with slug `../evil`; the other three decode.
  - `testUnsafeFileNameMeansNoDownload`: a row whose asset `file_name` is `a/b.zip` decodes with `latest == nil` (build the JSON inline).
  - `testCoverPathPrefersScreenshotThenHeroThenBanner` and `testNeedsSDCardForEmulatorsAndMedia`.
  - `testCategoriesAreDistinctAndOrdered`.
  - `testHomebrewNameSafety`: safe `classicube`, `240p-test-suite`, `a_1.20_dist.zip`; unsafe `""`, `.hidden`, `a/b`, `..`, `a\\b`, a name containing NUL.
- [ ] **Step 2: Run** `make test TEST_ARGS="-only-testing:iCubeTests/HomebrewDecodingTests"`. Expected: build fails, types not defined.
- [ ] **Step 3: Implement `HomebrewModels.swift`.** Decode each array element through a wrapper that swallows a row's error (`struct Lossy<T: Decodable>: Decodable { let value: T? }`), so one bad row never fails the catalogue. A row needs only a safe `slug` and a non-empty `name`; everything else defaults. `latest` is the first version that has an asset with a safe file name ending in `.zip`. Dates: `ISO8601DateFormatter` with `.withFractionalSeconds`, falling back to without. `HomebrewName.isSafe`: non-empty, equals its own `lastPathComponent`, no leading `.`, no `/`, `\`, NUL, not `..`.
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(homebrew): catalogue models for Dolphin Depot`.

### Task 2: Endpoint and client

**Files:**
- Create: `Common/Homebrew/DolphinDepotClient.swift`
- Create: `Common/Homebrew/HomebrewBrowser.swift`
- Test: `DolphiniOSTests/DolphinDepotClientTests.swift`

**Interfaces:**
- Consumes: `HomebrewCatalogue.decode(_:)`, `HomebrewTitle`, `HomebrewVersion` (Task 1).
- Produces:

```swift
enum HomebrewBrowser {
  static let isEnabled = true
  static let attribution = "Catalogue from Dolphin Depot. iCube does not host or modify these programs."
  static let rootSectionCount = 4
}
enum DolphinDepotEndpoint {
  static let api = URL(string: "https://api.dolphindepot.org")!
  static let cdn = URL(string: "https://cdn.dolphindepot.org")!
  static var catalogue: URL { get }                                   // the URL in "Facts checked"
  static func image(path: String) -> URL?                             // "a/b.png" -> cdn/a/image/b.png; nil unless exactly two safe components
  static func package(slug: String, fileName: String) -> URL?         // nil unless both are HomebrewName.isSafe
}
protocol DolphinDepotTransport: Sendable {
  func data(from url: URL, userAgent: String) async throws -> (Data, HTTPURLResponse)
}
struct URLSessionDolphinDepotTransport: DolphinDepotTransport   // 30 s timeout, Accept: application/json
enum DolphinDepotError: LocalizedError { case status(Int); case emptyCatalogue }
actor DolphinDepotClient {
  static let shared: DolphinDepotClient
  struct Loaded: Sendable { let catalogue: HomebrewCatalogue; let isSaved: Bool }  // isSaved: from disk because the network failed
  init(transport: any DolphinDepotTransport = URLSessionDolphinDepotTransport(),
       userAgent: String = GameBananaClient.defaultUserAgent,
       cacheFile: URL = DolphinDepotClient.defaultCacheFile,   // Caches/Homebrew/catalogue.json
       now: @escaping @Sendable () -> Date = { Date() })
  func catalogue(forceRefresh: Bool = false) async throws -> Loaded
  func saved() -> HomebrewCatalogue?                           // disk copy, for an instant first paint
  func data(from url: URL) async throws -> Data                // cover fetch for the installer; 2xx only
}
```

- [ ] **Step 1: Write the failing tests** with a fake transport that counts calls and returns queued results, and a temp `cacheFile`:
  - `testCatalogueURLIsOneRequestWithPublishedFilters`: host `api.dolphindepot.org`, path `/apps`, query contains `is_published=eq.true`, `app_versions.is_latest=eq.true`, `app_versions.is_published=eq.true`, and `select` contains `app_version_assets(file_name,file_size)` and `categories(name,display_name,sort_order)`.
  - `testImageURLInsertsImageFolder`: `image(path: "classicube/banner.png")` is `https://cdn.dolphindepot.org/classicube/image/banner.png`; `image(path: "../x.png")`, `image(path: "a/b/c.png")`, `image(path: "banner.png")` are nil.
  - `testPackageURL`: `package(slug: "classicube", fileName: "classicube_2026-11-20-ab02ba3b_dist.zip")` is `https://cdn.dolphindepot.org/classicube/release/classicube_2026-11-20-ab02ba3b_dist.zip`; nil for `fileName: "../a.zip"`.
  - `testSecondCallWithinTenMinutesUsesMemory`: two calls, one transport call.
  - `testCallAfterTenMinutesRefetches` (advance the injected clock by 601 s) and `testForceRefreshRefetches`.
  - `testTransportFailureFallsBackToDiskCopy`: load once, new client on the same `cacheFile` whose transport throws: `isSaved == true`, same titles.
  - `testTransportFailureWithNoDiskCopyThrows`.
  - `testHTTP500FallsBackAndDoesNotOverwriteDiskCopy`.
  - `testErrorObjectOrEmptyArrayDoesNotOverwriteDiskCopy`: a 200 with `{"code":"PGRST200","message":"x"}` and a 200 with `[]` both leave the disk copy and return it with `isSaved == true`.
- [ ] **Step 2: Run** `-only-testing:iCubeTests/DolphinDepotClientTests`. Expected: build fails.
- [ ] **Step 3: Implement.** Memory cache lifetime 600 s. The disk copy is the raw response body, written atomically only after it decodes to at least one title. Build the catalogue URL with `URLComponents.percentEncodedQuery`, percent-encoding values as `GameBananaEndpoint.percentEncode` does but keeping `(`, `)`, `,`, `*`, `.` literal (PostgREST needs them).
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(homebrew): Dolphin Depot client with a saved catalogue`.

### Task 3: Search, sort and sections

**Files:**
- Create: `Common/Homebrew/HomebrewCatalogueQuery.swift`
- Test: `DolphiniOSTests/HomebrewCatalogueQueryTests.swift`

**Interfaces:**
- Consumes: `HomebrewTitle`, `HomebrewCategory`, `HomebrewCatalogue` (Task 1).
- Produces:

```swift
enum HomebrewSort: String, CaseIterable, Identifiable {
  case name, mostDownloaded, recentlyUpdated
  var id: String { rawValue }
  var title: String { get }      // L("Name"), L("Most Downloaded"), L("Recently Updated")
}
enum HomebrewCatalogueQuery {
  struct Section: Identifiable { let category: HomebrewCategory; let count: Int; let preview: [HomebrewTitle]; var id: String { category.id } }
  static func sections(_ catalogue: HomebrewCatalogue, previewCount: Int) -> [Section]
  static func titles(in category: HomebrewCategory, of catalogue: HomebrewCatalogue, sort: HomebrewSort) -> [HomebrewTitle]
  static func search(_ query: String, in catalogue: HomebrewCatalogue) -> [HomebrewTitle]
}
```

- [ ] **Step 1: Write the failing tests** over titles built in the test:
  - `testSectionsFollowSortOrderAndPreviewMostDownloaded`: categories in `sortOrder`, `count` is the full count, `preview` is the top `previewCount` by `downloads`, ties by name.
  - `testTitlesWithoutCategoryAreInNoSection` and `testSearchStillFindsThem`.
  - `testSortByName` (case- and diacritic-insensitive), `testSortByMostDownloaded`, `testSortByRecentlyUpdated` (nil dates last).
  - `testSearchMatchesNameAuthorAndSummary`: case-insensitive, diacritic-insensitive, every whitespace-separated word must match somewhere; results by name.
  - `testBlankSearchReturnsNothing`.
- [ ] **Step 2: Run** `-only-testing:iCubeTests/HomebrewCatalogueQueryTests`. Expected: build fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the tests.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(homebrew): search, sort and category sections`.

### Task 4: Package layout and the installed index

**Files:**
- Create: `Common/Homebrew/HomebrewPackageLayout.swift`
- Create: `Common/Homebrew/HomebrewInstalledIndex.swift`
- Test: `DolphiniOSTests/HomebrewPackageLayoutTests.swift`, `DolphiniOSTests/HomebrewInstalledIndexTests.swift`

**Interfaces:**
- Consumes: `HomebrewName.isSafe`, `HomebrewTitle` (Task 1).
- Produces:

```swift
enum HomebrewPackageLayout {
  /// The program to start, or nil. Regular files only; symlinks are ignored.
  static func program(in root: URL) -> URL?
  /// Renames `program` to `<slug>.<its extension>` in place and returns the new URL.
  static func rename(_ program: URL, slug: String) throws -> URL
}
struct HomebrewInstalledIndex: Codable, Equatable {
  struct Entry: Codable, Equatable { var versionSlug: String; var version: String; var programPath: String }  // programPath is relative to the Homebrew root
  enum State: Equatable { case notInstalled, installed, updateAvailable }
  var titles: [String: Entry] = [:]
  static func load(root: URL) -> HomebrewInstalledIndex          // unreadable or missing = empty
  func save(root: URL) throws                                    // atomic, `installed.json`
  func state(of title: HomebrewTitle, root: URL) -> State        // program file missing = .notInstalled
  func programURL(forSlug slug: String, root: URL) -> URL?       // nil when the file is gone
  /// Drops entries whose program is gone and deletes their `<slug>/` folders. Returns the removed slugs.
  mutating func removeOrphans(root: URL) -> [String]
}
```

- [ ] **Step 1: Write the failing layout tests** over temp folders:
  - `testSingleProgramAnywhere`: `game.dol` at the root; `tools/x/boot.elf` alone.
  - `testDefaultDolUnderAppsWins`: `apps/a/default.dol` plus `apps/a/extra.dol` picks `default.dol`.
  - `testBootDolWhenNoDefault`.
  - `testSeveralAppsPicksFirstInPathOrder`: `apps/b/default.dol` and `apps/a/default.dol` picks `apps/a`.
  - `testSeveralProgramsOutsideAppsPicksFirstInPathOrder`.
  - `testNoProgramIsNil` (only `readme.txt` and `opening.bnr`), `testExtensionCaseIsIgnored` (`DEFAULT.DOL`), `testSymlinkIsIgnored`.
  - `testRenameUsesSlugAndKeepsExtension`: `apps/a/default.dol` becomes `apps/a/classicube.dol`; an existing file of that name is replaced.
- [ ] **Step 2: Write the failing index tests:**
  - `testRoundTrip`; `testMissingOrCorruptFileIsEmpty`.
  - `testStateInstalledUpdateAndNotInstalled`: same `versionSlug` is `.installed`, a different one is `.updateAvailable`, no entry is `.notInstalled`, a title with `latest == nil` and an entry is `.installed`.
  - `testMissingProgramFileCountsAsNotInstalled`.
  - `testRemoveOrphansDeletesFolderAndEntry` and `testRemoveOrphansLeavesInstalledTitlesAndUnknownFolders` (a folder with no entry is left alone: another install may be writing it).
  - `testProgramPathEscapingTheRootIsIgnored`: an entry with `programPath: "../../x.dol"` is `.notInstalled` and `removeOrphans` deletes nothing outside `root`.
- [ ] **Step 3: Run** both classes. Expected: build fails.
- [ ] **Step 4: Implement.** `program(in:)`: collect regular `.dol`/`.elf` files sorted by relative path; one file: that file; else the first `apps/*/default.dol`, else the first `apps/*/boot.dol`, else the first file. `removeOrphans` only touches `root/<slug>` where `slug` is `HomebrewName.isSafe`.
- [ ] **Step 5: Run the tests.** Expected: PASS.
- [ ] **Step 6: Commit** `feat(homebrew): package layout rule and installed index`.

### Task 5: A downloader the installer can share

**Files:**
- Modify: `Common/Mods/Browser/ModDownloadManager.swift`
- Create: `Common/Homebrew/HomebrewDownloading.swift`
- Test: `DolphiniOSTests/ModInstallModelTests.swift` (unchanged, must still pass)

**Interfaces:**
- Produces:

```swift
struct HomebrewDownload: Sendable { let file: URL; let etag: String? }
protocol HomebrewDownloading: Sendable {
  func download(key: String, from source: URL, fileName: String, expectedBytes: Int64, into directory: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> HomebrewDownload
}
extension ModDownloadManager: HomebrewDownloading {}
extension ModDownloadManager { static func makeWorkDirectory(forKey key: String) -> URL }
```

- [ ] **Step 1: Generalise `ModDownloadManager`.** Key jobs and resume data by `String` instead of `Int`. Move the body of `download(_ file: GameBananaFile, …)` into the new `download(key:from:fileName:expectedBytes:into:progress:)`, which also records the response's `ETag` header on the job in `didFinishDownloadingTo`. The `GameBananaFile` method keeps its checks (`noDownloadURL`, `unsafeFileName`) and calls the new one with key `String(file.id)`, returning `.file`. `makeWorkDirectory(forFileID:)` stays and calls `makeWorkDirectory(forKey:)`.
- [ ] **Step 2: Run** `-only-testing:iCubeTests/ModInstallModelTests -only-testing:iCubeTests/LiveModInstallHandlerTests`. Expected: PASS, no test edited.
- [ ] **Step 3: Commit** `refactor(mods): let the download manager fetch any keyed file`.

### Task 6: Install model

**Files:**
- Create: `Common/Homebrew/HomebrewInstallModel.swift`
- Create: `Common/Homebrew/HomebrewLibraryRegistrar.swift`
- Test: `DolphiniOSTests/HomebrewInstallModelTests.swift`

**Interfaces:**
- Consumes: `HomebrewTitle`, `HomebrewVersion` (Task 1); `DolphinDepotEndpoint.package/image`, `DolphinDepotClient.data(from:)` (Task 2); `HomebrewPackageLayout`, `HomebrewInstalledIndex` (Task 4); `HomebrewDownloading`, `HomebrewDownload` (Task 5); existing `ModDownloadPolicy.verdict(fileSize:availableBytes:)`, `.availableBytes(at:)`, `.md5(of:)`, `ZipImportHelper.extractArchive(at:to:)`, `ContinuityPaths.validatedURL(forRelativePath:)`.
- Produces:

```swift
protocol HomebrewLibraryRegistering: Sendable {
  /// True when the emulator can start this file.
  func canBoot(_ program: URL) -> Bool
  /// The custom title and cover the library holds for this file, if any.
  func metadata(of program: URL) async -> (title: String?, cover: Data?)
  /// Adds the file to the library and sets its title and cover.
  func register(_ program: URL, title: String, cover: Data?) async throws
}
struct LiveHomebrewLibraryRegistrar: HomebrewLibraryRegistering

enum HomebrewPaths {
  static let relativeRoot = "Software/Homebrew"
  static func root() throws -> URL                       // ContinuityPaths.validatedURL(forRelativePath: relativeRoot)
}

@MainActor final class HomebrewInstallModel: ObservableObject {
  enum Phase: Equatable { case idle, downloading(Double), verifying, installing, installed, failed(String) }
  let title: HomebrewTitle
  @Published private(set) var phase: Phase
  @Published private(set) var state: HomebrewInstalledIndex.State
  @Published var largeDownloadBytes: Int64?
  init(title: HomebrewTitle, root: URL, downloader: any HomebrewDownloading = ModDownloadManager.shared,
       registrar: any HomebrewLibraryRegistering = LiveHomebrewLibraryRegistrar(),
       cover: @escaping @Sendable (URL) async -> Data? = { try? await DolphinDepotClient.shared.data(from: $0) },
       availableBytes: @escaping @Sendable () -> Int64? = { … })
  func requestStart()        // free-space and size check, then start()
  func start()
  func cancel()              // keeps resume data, back to idle
  var programURL: URL? { get }   // the installed program, for Play
}
enum HomebrewInstallError: LocalizedError, Equatable {
  case noPackage, sizeMismatch, checksumMismatch, noProgram, cannotBoot
}
```

- [ ] **Step 1: Write the failing tests** with a fake downloader (it writes a zip the test builds: reuse the zip-building helper in `ArchiveImportSafetyTests.swift` if there is one, else write stored-method zip bytes by hand in a small test helper), a fake registrar recording calls, and a temp root:
  - `testHappyPathInstallsRegistersAndRecords`: phases end at `.installed`; `root/<slug>/apps/<x>/<slug>.dol` exists; registrar got that URL with the catalogue name and the cover bytes; index entry has the catalogue's `versionSlug`; `state == .installed`; the staging folder is gone.
  - `testSizeMismatchFailsAndRegistersNothing`: downloaded bytes differ from `latest.size`: `.failed`, no folder under `root`, registrar never called.
  - `testChecksumMismatchFails` (etag is 32 hex characters and wrong) and `testNonMD5EtagIsIgnored` (`W/"abc"` and a multipart-style `"…-2"` both install).
  - `testBadZipFails`, `testPackageWithoutProgramFails` (message is `L("This package has no program iCube can start.")`), `testProgramTheCoreRejectsFails` (`canBoot` false).
  - `testNotEnoughSpaceFailsBeforeDownloading`: downloader never called.
  - `testUpdateKeepsUserTitleAndCover`: registrar's `metadata(of:)` returns `("My Name", coverA)` for the old program: `register` receives `"My Name"` and `coverA`, the folder holds only the new version, the index has the new `versionSlug`.
  - `testFailedUpdateKeepsOldVersion`: install v1, then a v2 whose zip has no program: `.failed`, the v1 program file still exists, the index still says v1, `state == .updateAvailable`.
  - `testCancelReturnsToIdleAndLeavesNothing`.
  - `testCoverFetchFailureStillInstalls`: `cover` returns nil: `.installed`, registrar called with `cover: nil`.
  - `testDeletedProgramShowsDownloadAgain`: install, delete the program file, new model: `state == .notInstalled`.
- [ ] **Step 2: Run** `-only-testing:iCubeTests/HomebrewInstallModelTests`. Expected: build fails.
- [ ] **Step 3: Implement `HomebrewInstallModel`.** Order of work in `run()`:
  1. Package URL from `DolphinDepotEndpoint.package`; none: `.noPackage`.
  2. Download into `ModDownloadManager.makeWorkDirectory(forKey: "homebrew-" + slug)` with key `"homebrew-\(slug)-\(versionSlug)"`.
  3. `.verifying`: file size equals `latest.size`, else `.sizeMismatch`. If the etag, stripped of quotes, is exactly 32 hex characters, compare with `ModDownloadPolicy.md5(of:)`, else skip.
  4. `.installing`: extract into `<work>/extracted`; `HomebrewPackageLayout.program(in:)` or `.noProgram`; `rename(_:slug:)`; `registrar.canBoot` or `.cannotBoot`.
  5. Read the old program's metadata (`index.programURL(forSlug:)`, then `registrar.metadata(of:)`) before touching the old folder.
  6. Swap: move `root/<slug>` aside to `root/.<slug>.old` if it exists, move `extracted` to `root/<slug>`, delete the old one. If the second move throws, move the old folder back.
  7. `registrar.register(newProgram, title: old.title ?? title.name, cover: old.cover ?? fetched cover)`. Fetch the cover (`title.coverPath` through `DolphinDepotEndpoint.image`) only when the old entry has none.
  8. Write the index entry; `phase = .installed`; refresh `state`.
  Any error after step 2 removes the work folder; cancellation returns to `.idle`. File work runs in `Task.detached(priority: .userInitiated)`.
- [ ] **Step 4: Implement `LiveHomebrewLibraryRegistrar`.** `canBoot`: `DiscImageBridge.gameItem(forPath:) != nil`. `register`: `TVLibraryBridge.updateLibrary(withRemotePaths: [path], fetchMetadata: true)`, then `DiscImageBridge.gameItem(forPath:)`, `LibraryMetadataService.resolveIdentity(for:)`, `LibraryMetadataService.store().commit(Draft(title:coverData:), baseline: Draft(), for:)` off the main actor, then `LibraryMetadataService.didChange()`. Pass the cover through `LibraryMetadataService.prepareCover` (256 KB limit); if that throws, commit the title alone. `metadata(of:)`: `identity(for:)` or `resolveIdentity(for:)`, then `store().draft(for:)`.
- [ ] **Step 5: Run the tests.** Expected: PASS.
- [ ] **Step 6: Commit** `feat(homebrew): download and install a title into the library`.

### Task 7: Screens and the menu entry

**Files:**
- Create: `Common/Homebrew/HomebrewBrowserPresenter.swift` (presenter + `homebrewBrowserSheet()` modifier)
- Create: `Common/Homebrew/HomebrewBrowserViews.swift` (root, category list, row, model)
- Create: `Common/Homebrew/HomebrewDetailView.swift`
- Modify: `Common/Swift/TVLibraryView.swift` (`libraryImportMenuSection` near line 2365; sheet host near line 2814)
- Modify: `Common/UI/Localization/en.lproj/Core.strings`, `Common/UI/Localization/ja.lproj/Core.strings`
- Test: `DolphiniOSTests/HomebrewBrowserModelTests.swift`

**Interfaces:**
- Consumes: everything above; existing `ModChoiceList`, `ModChoice`, `TVStorageNoteSection`, `claimsController()`, `DiscPatchFlow.launch(path:)`, `ModInstallModel.formatted(_:)`.
- Produces:

```swift
@MainActor final class HomebrewBrowserPresenter: ObservableObject {
  static let shared: HomebrewBrowserPresenter
  @Published var isPresented: Bool
  func open()                          // no-op unless HomebrewBrowser.isEnabled
  func closeAndPlay(_ program: URL)    // dismisses, then DiscPatchFlow.launch(path:) once the cover is gone
  func browserDidDismiss()
}
extension View { func homebrewBrowserSheet() -> some View }   // .sheet on iOS/Catalyst, .fullScreenCover on tvOS, .claimsController()
enum HomebrewBrowserRoute: Hashable { case category(HomebrewCategory), title(HomebrewTitle) }
@MainActor final class HomebrewBrowserModel: ObservableObject {
  @Published private(set) var catalogue: HomebrewCatalogue?
  @Published private(set) var isLoading: Bool
  @Published private(set) var isShowingSavedList: Bool
  @Published private(set) var errorMessage: String?       // only when there is nothing to show
  @Published private(set) var index: HomebrewInstalledIndex
  @Published var searchText: String
  init(client: DolphinDepotClient = .shared, root: URL?)
  func load() async          // saved copy first, then the network; sweeps orphans once
  func refresh() async       // forceRefresh
  func reloadIndex()         // after an install finishes
}
```

- [ ] **Step 1: Write the failing model tests** (fake transport, temp root):
  - `testLoadShowsSavedCopyThenFreshOne`.
  - `testLoadWithNoNetworkAndNoCopySetsErrorMessage`.
  - `testLoadWithNoNetworkButACopyFlagsSavedList`: `isShowingSavedList == true`, `errorMessage == nil`.
  - `testLoadSweepsOrphans`: an index entry whose program is gone is removed and its folder deleted.
  - `testRefreshForcesARequest`.
- [ ] **Step 2: Run** `-only-testing:iCubeTests/HomebrewBrowserModelTests`. Expected: build fails.
- [ ] **Step 3: Implement the presenter, modifier and model.** Run the tests. Expected: PASS.
- [ ] **Step 4: Implement the screens.**
  - `HomebrewBrowserRoot`: `NavigationStack` with title `L("Homebrew")`, a Done button, `.searchable`. With blank search: one `Section` per `HomebrewCatalogueQuery.sections(_, previewCount: HomebrewBrowser.rootSectionCount)`, header `"<display name> (<count>)"`, rows, then a `NavigationLink` row `L("See All")`. With search text: one flat list from `search`, or `L("No homebrew found.")`. Below: a `L("Refresh")` button row on tvOS and `.refreshable` elsewhere; `L("Showing the saved list.")` when `isShowingSavedList`; the attribution line; `TVStorageNoteSection()`. Empty state with `L("Try Again")` when `errorMessage` is set.
  - Row: 64 pt `AsyncImage` of `coverPath` (placeholder as `ModSummaryRow`), name, author, and a trailing detail: `L("Installed")`, `L("Update")`, or the formatted size.
  - Category screen: the sort row (`ModChoiceList`, default `.name`) and every title of the category.
  - `HomebrewDetailView` (owns a `@StateObject HomebrewInstallModel`): hero or first screenshot, name, author, the primary button, the SD-card line when `needsSDCard` (`L("This program looks for files on an SD card, which iCube does not provide yet.")`), description, a horizontal screenshot strip (iOS) or the first screenshot only (tvOS), then rows for Licence, Works With (hardware), Version, Size, Released, and links. On tvOS a link row is plain text with `L("Open this address on another device.")`; elsewhere it opens with `openURL`. Primary button by state: `L("Download")`, a progress row with `L("Cancel")`, `L("Play")` plus `L("Update")` when one is available, and the failure sentence with `L("Try Again")`. A title with `latest == nil` shows `L("No download is available for this title yet.")`. The large-download confirmation is an `.alert` bound to `largeDownloadBytes`. After `.installed`, call `browser.reloadIndex()`.
- [ ] **Step 5: Wire the entry point.** In `libraryImportMenuSection`, after the mods button:

```swift
if HomebrewBrowser.isEnabled {
  Button(action: { libraryMenuAction { HomebrewBrowserPresenter.shared.open() } }) {
    Label(L("Get Homebrew…"), systemImage: "arrow.down.app")
  }
}
```

  and add `.homebrewBrowserSheet()` next to `.modBrowserSheet(libraryGames:)`.
- [ ] **Step 6: Add every new `L("…")` key to both `Core.strings` files.**
- [ ] **Step 7: Run the checks** from `Source/iOS/App`: `python3 Project/Scripts/check_localized_keys.py --check`, `python3 Project/Scripts/check_design_tokens.py --check`, `python3 Project/Scripts/check_button_types.py`. Expected: all exit 0.
- [ ] **Step 8: Commit** `feat(homebrew): browser screens and the Get Homebrew menu entry`.

### Task 8: Whole-feature verification

**Files:** none new.

- [ ] **Step 1: Run the full suite:** `make test` from `Source/iOS/App`. Expected: every test passes, including all mod browser tests.
- [ ] **Step 2: Build for tvOS** (the scheme and destination the `Makefile` or `tests.yml` uses for tvOS). Expected: compiles.
- [ ] **Step 3: Simulator check on iOS.** Open the library menu, Get Homebrew…, open Games, open one small title, Download, Play. Confirm the library shows the catalogue's name and a cover, not `default`. Delete it from the library, reopen the browser, confirm it shows Download. Record what was and was not checked.
- [ ] **Step 4: Check whether the library scans `Software/` recursively** (read `GameFileCacheManager`'s scan paths). If it does, a package with several programs shows each as its own entry after a rescan; write the finding into the spec's "Decisions" section rather than changing code.
- [ ] **Step 5: Update the spec** with what the builder confirmed (file name from the catalogue, etag is MD5, cover choice, rename rule), and commit `docs: record what the homebrew build confirmed`.

Owed on devices afterwards (not part of this plan): download and boot one game on an iPhone and an Apple TV; tvOS focus through root, category, detail and back; an update of an installed title.
