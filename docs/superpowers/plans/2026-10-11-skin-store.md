# Skin Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An in-app store that browses the Provenance skin catalog (`provenance-emu.com/skins/catalog.json`) and installs GameCube, Wii and remapped Nintendo 64 skins into iCube's existing skin library with one tap.

**Architecture:** A port of iFly's store backend (catalog models, a caching catalog service actor, a pure shelf policy, a download-then-install installer) layered on iCube's existing `SkinLibrary.importSkin`, which gains an optional retarget that rewrites an N64 skin's `info.json` to GameCube. A SwiftUI shelf-and-card store view, presented from the existing skin picker. Rendering and input are untouched.

**Tech Stack:** Swift 5, SwiftUI, `URLSession` download tasks, `marmelroy/Zip` (already a dependency, used through `SkinLibrary`), XCTest in `iCubeTests`, Tuist-generated project.

**Spec:** `docs/superpowers/specs/2026-10-11-skin-store-design.md`

## Global Constraints

- iOS only: every new file is wrapped in `#if os(iOS)` … `#endif`. tvOS must still compile.
- Paths below are relative to `Source/iOS/App`. Backend files go in `DolphiniOS/UI/Emulation/Skins/Store/`; UI files in `Common/UI/Settings/SwiftUI/`; tests in `DolphiniOSTests/`.
- After adding any file: `cd Source/iOS/App && PATH=/opt/homebrew/bin:$PATH tuist generate --no-open`, or new tests silently don't run.
- Tests: `cd Source/iOS/App && make test TEST_ARGS="-only-testing:iCubeTests/<Class>"` (iPhone 17 Pro simulator; the first build in a fresh checkout also builds the core simulator slice, ~30 min).
- Every user-visible string goes through `L("…")` and gets an identity entry (`"key" = "key";`) in **both** `Common/UI/Localization/en.lproj/Core.strings` and `ja.lproj/Core.strings`. Check with `python3 Project/Scripts/check_localized_keys.py --check`.
- Files under `Common/` must not add hard-coded fonts, radii, line widths or colours: no `.font(.system(size:`, `.font(.<textStyle>`, numeric `cornerRadius:`/`lineWidth:`, `Color(red:`, `Color.green` etc. Use `.icubeText(.body/.detail/.tag/.section)`, `ICubeDesign.color(.accent/.textSecondary/.destructive/.rowSurface/.hairline)`, `ICubeDesign.Radius.*.rawValue`, `ICubeDesign.Spacing.*.rawValue`, `ICubeDesign.symbolFont(.tile)`. Check with `python3 Project/Scripts/check_design_tokens.py --check`.
- Logging is `NSLog` with a `[SKINSTORE]` prefix, like the rest of the touch layer.
- Skins download from the catalog entry's `downloadURL` only; nothing is re-hosted.
- Before every commit: `git checkout -- build/xcframework` (local builds rewrite the tracked slices); stage only your own files. Commit messages use conventional prefixes and carry no AI/LLM trailers (repo rule in `docs/HANDOFF.md`).
- Raw `TCButtonType` ids only through `TouchOverlayDefaults.ButtonID`.

## Review Focus

1. A `downloadURL` that answers HTTP 200 with an HTML page (dead `deltastyles.com` link): the card must show "the file is not a skin archive" with Retry, and nothing must be left in the library. Pinned in Task 5 (`testInstallStepFailureSurfacesMessage`) and Task 3 (`SkinLibrary` already throws `unreadableArchive` on a non-zip; `testNonArchiveThrowsUnreadable` exists).
2. An N64 skin whose `identifier` collides with an as-is GameCube import: the retarget suffix must keep them apart. Pinned in Task 3 (`testRetargetKeepsAnAsIsImportSeparate`).
3. Cancelling mid-download must return the card to Install and leave no temp file. Pinned in Task 5 (`testCancellationReturnsToIdle`, `testTemporaryDownloadFolderIsRemoved`).
4. Deleting a store-installed skin in the picker must make the store offer it again. Pinned in Task 5 (`testReconcileForgetsDeletedSkins`) and Task 6 (`reconcileInstalled()` on appear).
5. A catalog entry whose `systems` is empty but whose `gameTypeIdentifier` ends in `.ngc`: must land on the GameCube shelf. Pinned in Task 4 (`testGameTypeSuffixPlacesAnEntryWithoutSystems`).

---

### Task 1: Catalog models and the feed fixture

**Files:**
- Create: `DolphiniOS/UI/Emulation/Skins/Store/SkinCatalog.swift`
- Create: `DolphiniOS/UI/Emulation/Skins/Store/SkinCatalogEntry.swift`
- Create: `DolphiniOSTests/SkinCatalogFixture.swift`
- Test: `DolphiniOSTests/SkinCatalogDecodingTests.swift`

**Interfaces:**
- Produces: `struct SkinCatalog: Decodable { version: Int?; lastUpdated: Date?; totalSkins: Int?; skins: [SkinCatalogEntry]; droppedEntryCount: Int }`, `static func SkinCatalog.decode(_ data: Data) throws -> SkinCatalog`.
- Produces: `struct SkinCatalogEntry: Decodable, Hashable, Identifiable, Sendable` with `id`, `name`, `downloadURL: URL`, `author?`, `systems: [String]`, `gameTypeIdentifier?`, `thumbnailURL?`, `screenshotURLs`, `tags`, `downloadCount?`, `lastUpdated?`, `source?`, `description?`, `groupId?`, `groupOrder?`; computed `normalizedSystems: [String]`, `gameTypeSuffix: String?`, `sourceHost: String?`; memberwise `init(id:name:systems:downloadURL:…)` with defaults; `static func url(from raw: String) -> URL?`.
- Produces: `enum SkinCatalogDates { static func parse(_ string: String?) -> Date? }`, `enum SkinCatalogError: LocalizedError { httpStatus(Int), network(String), decoding(String) }`.

- [ ] **Step 1: Write the fixture** — `DolphiniOSTests/SkinCatalogFixture.swift`. Ten entries are verbatim from the live feed (2026-10-11); the last two are hand-written and prefixed `test-` (there are no `wii` entries and no date-only `lastUpdated` among GameCube/N64 entries to copy).

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// A slice of the live skin catalog (https://provenance-emu.com/skins/catalog.json, fetched
/// 2026-10-11): the one `gamecube` entry, four `n64` (one `.zip`, one with a raw space in its URL,
/// one in a pack with `groupId`, one with a Delta `gameTypeIdentifier`), a `gba` `.zip`, a Google
/// Drive link, an `unofficial`, a `threeDS`, a `gba` with a raw space. The two `test-` entries are
/// hand-written: a `wii` skin and a mixed-case `GameCube` with a date-only `lastUpdated`, which the
/// feed has for other systems but not for these.
///
/// A raw string so the feed's JSON escapes reach the decoder untouched.
enum SkinCatalogFixture {
  static let entryCount = 12
  static let gameCubePocketID = "ea60f2003d82ac9e"
  static let n64ZipID = "91f17a221e5c6a87"
  static let n64PackID = "15dd242edd355b11"
  static let n64SpaceURLID = "598c913900e17758"
  static let n64DeltaTypeID = "abe5e9e4ee7b0195"
  static let gbaZipID = "f3c67e2b3c9c1bc2"
  static let googleDriveID = "2a71bf5fa167d694"
  static let unofficialID = "e62e868cf559da9f"
  static let threeDSID = "f68e4aabb347bd7c"
  static let gbaSpaceURLID = "8e3871abb5910097"
  static let wiiID = "test-wii-remote"
  static let mixedCaseGameCubeID = "test-gamecube-dated"

  static var data: Data { Data(json.utf8) }

  static let json = #"""
  {
    "version": 2,
    "lastUpdated": "2026-10-04T05:11:24Z",
    "totalSkins": 1358,
    "skins": [
      {
        "author": "starvingartist",
        "gameTypeIdentifier": "public.aoshuang.game.ngc",
        "version": null,
        "thumbnailURL": null,
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": null,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": null,
        "groupId": null,
        "groupOrder": null,
        "name": "GameCube Pocket",
        "downloadURL": "https://deltastyles.com/files/skins/760/gamecubepocket.manicskin",
        "systems": ["gamecube"],
        "source": "deltastyles.com",
        "id": "ea60f2003d82ac9e"
      },
      {
        "author": "bossmiller",
        "gameTypeIdentifier": null,
        "version": null,
        "thumbnailURL": null,
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": null,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": null,
        "groupId": null,
        "groupOrder": null,
        "name": "Dpad with Joystick controls",
        "downloadURL": "https://deltastyles.com/files/skins/758/Dpad_Sub_for_Joystick_DPAD_ANALOG_MAPPING_FIXED_v2%202.zip",
        "systems": ["n64"],
        "source": "deltastyles.com",
        "id": "91f17a221e5c6a87"
      },
      {
        "author": "R3BEL",
        "gameTypeIdentifier": null,
        "version": null,
        "thumbnailURL": "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/15dd242edd355b11.png",
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": 2443,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": null,
        "groupId": "deltastyles:551",
        "groupOrder": 1,
        "name": "[CRT GAMEPAD] [N64] [NO OVERSCAN]",
        "downloadURL": "https://deltastyles.com/files/skins/551/%5BCRT%20GAMEPAD%5D%20%5BN64%5D%20%5BNO%20OVERSCAN%5D.deltaskin",
        "systems": ["n64"],
        "source": "deltastyles.com",
        "id": "15dd242edd355b11"
      },
      {
        "author": "allgoodnobad",
        "gameTypeIdentifier": null,
        "version": null,
        "thumbnailURL": "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/598c913900e17758.png",
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": 1652,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": null,
        "name": "8BitDo Micro Compatible N64 Skin",
        "downloadURL": "https://deltastyles.com/files/skins/459/8BitDo Micro SNES & N64 Skin.deltaskin",
        "systems": ["n64"],
        "source": "deltastyles.com",
        "id": "598c913900e17758"
      },
      {
        "author": "Classicallybrok3n",
        "gameTypeIdentifier": null,
        "version": null,
        "thumbnailURL": "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/f3c67e2b3c9c1bc2.png",
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": 406,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": null,
        "name": "GAMEBOY ADVANCE MICRO",
        "downloadURL": "https://deltastyles.com/files/skins/490/gba_micro_working.zip",
        "systems": ["gba"],
        "source": "deltastyles.com",
        "id": "f3c67e2b3c9c1bc2"
      },
      {
        "author": "rythmic",
        "gameTypeIdentifier": null,
        "version": null,
        "thumbnailURL": "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/2a71bf5fa167d694.png",
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": 683,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": null,
        "name": "Anime Icons: Luffy (One Piece)",
        "downloadURL": "https://drive.google.com/uc?export=download&id=1aiL5IBu_QHunenBsIC4-v3oorH1zb72l",
        "systems": ["gba"],
        "source": "deltastyles.com",
        "id": "2a71bf5fa167d694"
      },
      {
        "author": "masonkoleh",
        "gameTypeIdentifier": null,
        "version": null,
        "thumbnailURL": "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/e62e868cf559da9f.png",
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": 736,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": "2026-03-15T00:05:34Z",
        "id": "e62e868cf559da9f",
        "downloadURL": "https://raw.githubusercontent.com/masonkoleh/deltaskins/HEAD/gba/skins/ahegaoGBA.deltaskin",
        "source": "masonkoleh/deltaskins",
        "name": "ahegaoGBA",
        "systems": ["unofficial"]
      },
      {
        "author": "JanZa",
        "gameTypeIdentifier": null,
        "version": null,
        "thumbnailURL": "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/f68e4aabb347bd7c.png",
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": 2518,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": null,
        "name": "3DS Controller",
        "downloadURL": "https://deltastyles.com/files/skins/538/3dscontroller.manicskin",
        "systems": ["threeDS"],
        "source": "deltastyles.com",
        "id": "f68e4aabb347bd7c"
      },
      {
        "author": "328yt",
        "gameTypeIdentifier": null,
        "version": null,
        "thumbnailURL": "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/8e3871abb5910097.png",
        "screenshotURLs": [],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": 2774,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": null,
        "name": "328 Black GBA for iPad",
        "downloadURL": "https://deltastyles.com/files/skins/328 Black GBA.deltaskin",
        "systems": ["gba"],
        "source": "deltastyles.com",
        "id": "8e3871abb5910097"
      },
      {
        "author": "masonkoleh",
        "gameTypeIdentifier": "com.rileytestut.delta.game.n64",
        "version": null,
        "thumbnailURL": "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/abe5e9e4ee7b0195.png",
        "screenshotURLs": [
          "https://github.com/Provenance-Emu/skins/releases/download/thumbnails/abe5e9e4ee7b0195-landscape.png"
        ],
        "tags": [],
        "deviceSupport": [],
        "downloadCount": 3922,
        "rating": null,
        "lastUpdated": null,
        "fileSize": null,
        "submittedBy": null,
        "submittedAt": "2026-03-15T00:05:35Z",
        "id": "abe5e9e4ee7b0195",
        "downloadURL": "https://raw.githubusercontent.com/masonkoleh/deltaskins/HEAD/gba/skins/bleu.deltaskin",
        "source": "masonkoleh/deltaskins",
        "name": "Bleu N64",
        "systems": ["n64"]
      },
      {
        "id": "test-wii-remote",
        "name": "Test Wii Remote",
        "author": "iCube tests",
        "systems": ["wii"],
        "downloadURL": "https://example.com/skins/test-wii-remote.manicskin",
        "thumbnailURL": null,
        "source": "example.com",
        "tags": ["portrait"]
      },
      {
        "id": "test-gamecube-dated",
        "name": "Test GameCube Dated",
        "author": "iCube tests",
        "systems": ["GameCube"],
        "downloadURL": "https://example.com/skins/test-gamecube-dated.deltaskin",
        "thumbnailURL": null,
        "source": "owner/repo",
        "lastUpdated": "2025-09-23"
      }
    ]
  }
  """#
}
#endif
```

- [ ] **Step 2: Write the failing tests** — `DolphiniOSTests/SkinCatalogDecodingTests.swift`:

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
@testable import iCube

/// Decoding against a slice of the live feed. The count assertion comes first everywhere: the
/// decoder is lossy by design, so a test that only checks "the .zip entry is hidden" would also
/// pass if that entry had silently failed to decode.
final class SkinCatalogDecodingTests: XCTestCase {
  private func decodeFixture() throws -> SkinCatalog {
    try SkinCatalog.decode(SkinCatalogFixture.data)
  }

  private func entry(_ id: String, in catalog: SkinCatalog) throws -> SkinCatalogEntry {
    try XCTUnwrap(catalog.skins.first { $0.id == id }, "missing \(id)")
  }

  func testEveryFixtureEntryDecodes() throws {
    let catalog = try decodeFixture()
    XCTAssertEqual(catalog.skins.count, SkinCatalogFixture.entryCount)
    XCTAssertEqual(catalog.droppedEntryCount, 0)
  }

  func testRootFields() throws {
    let catalog = try decodeFixture()
    XCTAssertEqual(catalog.version, 2)
    XCTAssertEqual(catalog.totalSkins, 1358)
    let root = try XCTUnwrap(catalog.lastUpdated)
    XCTAssertEqual(root.timeIntervalSince1970, 1_791_090_684, accuracy: 1) // 2026-10-04T05:11:24Z
  }

  func testDateOnlyLastUpdatedParses() throws {
    let catalog = try decodeFixture()
    let dated = try entry(SkinCatalogFixture.mixedCaseGameCubeID, in: catalog)
    let date = try XCTUnwrap(dated.lastUpdated)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    XCTAssertEqual([parts.year, parts.month, parts.day], [2025, 9, 23])
  }

  func testNullFieldsDecodeAsNil() throws {
    let catalog = try decodeFixture()
    let pocket = try entry(SkinCatalogFixture.gameCubePocketID, in: catalog)
    XCTAssertEqual(pocket.name, "GameCube Pocket")
    XCTAssertEqual(pocket.author, "starvingartist")
    XCTAssertNil(pocket.thumbnailURL)
    XCTAssertNil(pocket.downloadCount)
    XCTAssertNil(pocket.lastUpdated)
    XCTAssertNil(pocket.groupId)
    XCTAssertEqual(pocket.gameTypeIdentifier, "public.aoshuang.game.ngc")
    XCTAssertEqual(pocket.gameTypeSuffix, "ngc")
  }

  func testGroupFields() throws {
    let catalog = try decodeFixture()
    let pack = try entry(SkinCatalogFixture.n64PackID, in: catalog)
    XCTAssertEqual(pack.groupId, "deltastyles:551")
    XCTAssertEqual(pack.groupOrder, 1)
  }

  /// Two feed URLs carry raw spaces; they must decode rather than drop the entry.
  func testURLWithRawSpacesDecodes() throws {
    let catalog = try decodeFixture()
    let n64 = try entry(SkinCatalogFixture.n64SpaceURLID, in: catalog)
    XCTAssertEqual(n64.downloadURL.host, "deltastyles.com")
    XCTAssertEqual(n64.downloadURL.pathExtension.lowercased(), "deltaskin")
    let gba = try entry(SkinCatalogFixture.gbaSpaceURLID, in: catalog)
    XCTAssertEqual(gba.downloadURL.lastPathComponent, "328%20Black%20GBA.deltaskin")
  }

  func testSystemsAreNormalisedForComparison() throws {
    let catalog = try decodeFixture()
    let threeDS = try entry(SkinCatalogFixture.threeDSID, in: catalog)
    XCTAssertEqual(threeDS.systems, ["threeDS"])
    XCTAssertEqual(threeDS.normalizedSystems, ["threeds"])
    let mixed = try entry(SkinCatalogFixture.mixedCaseGameCubeID, in: catalog)
    XCTAssertEqual(mixed.normalizedSystems, ["gamecube"])
  }

  func testSourceHost() throws {
    let catalog = try decodeFixture()
    XCTAssertEqual(try entry(SkinCatalogFixture.gameCubePocketID, in: catalog).sourceHost, "deltastyles.com")
    // `owner/repo` is not a host: fall back to the download URL's host.
    XCTAssertEqual(try entry(SkinCatalogFixture.unofficialID, in: catalog).sourceHost, "raw.githubusercontent.com")
    XCTAssertEqual(try entry(SkinCatalogFixture.mixedCaseGameCubeID, in: catalog).sourceHost, "example.com")
  }

  /// One malformed entry must not cost the rest of the catalog.
  func testBadEntryIsDroppedNotFatal() throws {
    let json = #"""
    {
      "version": 2,
      "lastUpdated": "not a date",
      "skins": [
        { "id": "good", "name": "Good", "systems": ["gamecube"],
          "downloadURL": "https://example.com/good.manicskin", "rating": "five stars" },
        { "id": "no-url", "name": "No URL", "systems": ["gamecube"] },
        { "id": 42, "name": "Numeric id", "systems": ["gamecube"],
          "downloadURL": "https://example.com/x.manicskin" },
        { "id": "no-systems", "name": "No systems",
          "downloadURL": "https://example.com/y.deltaskin", "lastUpdated": "2025-13-45" }
      ]
    }
    """#
    let catalog = try SkinCatalog.decode(Data(json.utf8))
    XCTAssertEqual(catalog.skins.map(\.id), ["good", "no-systems"])
    XCTAssertEqual(catalog.droppedEntryCount, 2)
    XCTAssertNil(catalog.lastUpdated)
    XCTAssertNil(catalog.skins[0].rating, "a mistyped optional drops the field, not the entry")
    XCTAssertEqual(catalog.skins[1].systems, [])
    XCTAssertNil(catalog.skins[1].lastUpdated)
    XCTAssertNil(catalog.skins[1].gameTypeSuffix)
  }

  func testNonCatalogJSONThrows() {
    XCTAssertThrowsError(try SkinCatalog.decode(Data("[1, 2, 3]".utf8)))
    XCTAssertThrowsError(try SkinCatalog.decode(Data("<html>".utf8)))
  }
}
#endif
```

- [ ] **Step 3: Run to verify it fails** — `make test TEST_ARGS="-only-testing:iCubeTests/SkinCatalogDecodingTests"` after `tuist generate --no-open`. Expected: compile error, `cannot find 'SkinCatalog' in scope`.

- [ ] **Step 4: Implement** `Store/SkinCatalog.swift`:

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// The provenance-emu.com skin catalog (`/skins/catalog.json`, schema version 2).
///
/// Decodes the feed as it really is: nearly every field is nullable, and one malformed entry must
/// never cost the player the other 1,357. `skins` therefore decodes lossily: an entry that fails
/// is counted in `droppedEntryCount` and skipped. Decodable only: the service caches the server's
/// bytes verbatim, so there is no second, re-encoded schema to keep in step with the feed.
struct SkinCatalog: Decodable, Sendable {
  var version: Int?
  var lastUpdated: Date?
  var totalSkins: Int?
  var skins: [SkinCatalogEntry]
  /// Entries present in the feed that could not be decoded.
  var droppedEntryCount: Int

  init(version: Int? = nil, lastUpdated: Date? = nil, totalSkins: Int? = nil, skins: [SkinCatalogEntry], droppedEntryCount: Int = 0) {
    self.version = version
    self.lastUpdated = lastUpdated
    self.totalSkins = totalSkins
    self.skins = skins
    self.droppedEntryCount = droppedEntryCount
  }

  private enum CodingKeys: String, CodingKey {
    case version, lastUpdated, totalSkins, skins
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try? container.decodeIfPresent(Int.self, forKey: .version)
    lastUpdated = SkinCatalogDates.parse(try? container.decodeIfPresent(String.self, forKey: .lastUpdated))
    totalSkins = try? container.decodeIfPresent(Int.self, forKey: .totalSkins)
    let lossy = try container.decodeIfPresent([LossyEntry].self, forKey: .skins) ?? []
    skins = lossy.compactMap(\.entry)
    droppedEntryCount = lossy.count - skins.count
  }

  /// Decodes feed bytes. Shared by the network and disk paths so both apply the same lossy rules.
  static func decode(_ data: Data) throws -> SkinCatalog {
    do {
      return try JSONDecoder().decode(SkinCatalog.self, from: data)
    } catch {
      throw SkinCatalogError.decoding(error.localizedDescription)
    }
  }

  /// Swallows one entry's decode failure so the array as a whole survives.
  private struct LossyEntry: Decodable {
    let entry: SkinCatalogEntry?

    init(from decoder: Decoder) throws {
      entry = try? SkinCatalogEntry(from: decoder)
    }
  }
}

/// Date parsing for the feed, which mixes full ISO 8601 (`2026-10-04T05:11:24Z`) at the root and
/// in `submittedAt` with bare dates (`2025-09-23`) in per-skin `lastUpdated`. Anything unparseable
/// becomes nil instead of failing the entry.
enum SkinCatalogDates {
  static func parse(_ string: String?) -> Date? {
    guard let raw = string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    if let full = try? Date.ISO8601FormatStyle().parse(raw) { return full }
    if let fractional = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(raw) { return fractional }
    return try? Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day().parse(raw)
  }
}

/// Why the catalog could not be produced (the network and every cache failed).
enum SkinCatalogError: LocalizedError {
  case httpStatus(Int)
  case network(String)
  case decoding(String)

  var errorDescription: String? {
    switch self {
    case .httpStatus(let code): return String(format: L("The skin catalog server answered with HTTP %d."), code)
    case .network(let message): return String(format: L("The skin catalog could not be downloaded: %@"), message)
    case .decoding(let message): return String(format: L("The skin catalog could not be read: %@"), message)
    }
  }
}
#endif
```

and `Store/SkinCatalogEntry.swift`:

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// One skin in the provenance-emu.com catalog.
///
/// Only `id`, `name` and `downloadURL` are required: without them there is nothing to show or
/// fetch. Every other field is decoded with `try?`, so a type drift in, say, `rating` drops that
/// field rather than the skin.
struct SkinCatalogEntry: Decodable, Sendable, Hashable, Identifiable {
  var id: String
  var name: String
  var author: String?
  /// Short system codes as the feed writes them (`gamecube`, `n64`, `threeDS`). Mixed case in the
  /// wild; compare through `normalizedSystems`.
  var systems: [String]
  var gameTypeIdentifier: String?
  var version: String?
  /// Where the skin is fetched from. Mostly third-party hosts; iCube downloads from here and never
  /// re-hosts.
  var downloadURL: URL
  var thumbnailURL: URL?
  var screenshotURLs: [URL]
  var tags: [String]
  var deviceSupport: [String]
  var downloadCount: Int?
  var rating: Double?
  var lastUpdated: Date?
  var fileSize: Int?
  /// Host attribution (`deltastyles.com`), or sometimes a GitHub `owner/repo`.
  var source: String?
  var description: String?
  var submittedBy: String?
  var submittedAt: Date?
  /// Packs (several skins from one upload) share a `groupId` and order by `groupOrder`.
  var groupId: String?
  var groupOrder: Int?

  /// `systems`, lowercased.
  var normalizedSystems: [String] { systems.map { $0.lowercased() } }

  /// The last dot component of `gameTypeIdentifier`, lowercased (`ngc` for
  /// `public.aoshuang.game.ngc`), or nil when the feed has none.
  var gameTypeSuffix: String? {
    guard let identifier = gameTypeIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty,
          let suffix = identifier.split(separator: ".").last else { return nil }
    return suffix.lowercased()
  }

  /// Where the skin is hosted, for the credit line. The feed's `source` is usually a host but
  /// sometimes an `owner/repo`; anything that is not a bare host falls back to the download URL's host.
  var sourceHost: String? {
    if let source = source?.trimmingCharacters(in: .whitespacesAndNewlines), Self.looksLikeHost(source) {
      return source.lowercased()
    }
    guard let host = downloadURL.host?.lowercased() else { return nil }
    return host.hasPrefix(Self.wwwPrefix) ? String(host.dropFirst(Self.wwwPrefix.count)) : host
  }

  private static let wwwPrefix = "www."

  init(id: String, name: String, author: String? = nil, systems: [String], gameTypeIdentifier: String? = nil,
       version: String? = nil, downloadURL: URL, thumbnailURL: URL? = nil, screenshotURLs: [URL] = [],
       tags: [String] = [], deviceSupport: [String] = [], downloadCount: Int? = nil, rating: Double? = nil,
       lastUpdated: Date? = nil, fileSize: Int? = nil, source: String? = nil, description: String? = nil,
       submittedBy: String? = nil, submittedAt: Date? = nil, groupId: String? = nil, groupOrder: Int? = nil) {
    self.id = id
    self.name = name
    self.author = author
    self.systems = systems
    self.gameTypeIdentifier = gameTypeIdentifier
    self.version = version
    self.downloadURL = downloadURL
    self.thumbnailURL = thumbnailURL
    self.screenshotURLs = screenshotURLs
    self.tags = tags
    self.deviceSupport = deviceSupport
    self.downloadCount = downloadCount
    self.rating = rating
    self.lastUpdated = lastUpdated
    self.fileSize = fileSize
    self.source = source
    self.description = description
    self.submittedBy = submittedBy
    self.submittedAt = submittedAt
    self.groupId = groupId
    self.groupOrder = groupOrder
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, author, systems, gameTypeIdentifier, version, downloadURL
    case thumbnailURL, screenshotURLs, tags, deviceSupport, downloadCount, rating
    case lastUpdated, fileSize, source, description, submittedBy, submittedAt
    case groupId, groupOrder
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    let rawDownload = try container.decode(String.self, forKey: .downloadURL)
    guard let download = Self.url(from: rawDownload) else {
      throw DecodingError.dataCorruptedError(forKey: .downloadURL, in: container, debugDescription: "Unusable downloadURL '\(rawDownload)'")
    }
    downloadURL = download

    func string(_ key: CodingKeys) -> String? { try? container.decodeIfPresent(String.self, forKey: key) }
    func strings(_ key: CodingKeys) -> [String] { (try? container.decodeIfPresent([String].self, forKey: key)) ?? [] }

    author = string(.author)
    systems = strings(.systems)
    gameTypeIdentifier = string(.gameTypeIdentifier)
    version = string(.version)
    thumbnailURL = string(.thumbnailURL).flatMap(Self.url(from:))
    screenshotURLs = strings(.screenshotURLs).compactMap(Self.url(from:))
    tags = strings(.tags)
    deviceSupport = strings(.deviceSupport)
    downloadCount = try? container.decodeIfPresent(Int.self, forKey: .downloadCount)
    rating = try? container.decodeIfPresent(Double.self, forKey: .rating)
    lastUpdated = SkinCatalogDates.parse(string(.lastUpdated))
    fileSize = try? container.decodeIfPresent(Int.self, forKey: .fileSize)
    source = string(.source)
    description = string(.description)
    submittedBy = string(.submittedBy)
    submittedAt = SkinCatalogDates.parse(string(.submittedAt))
    groupId = string(.groupId)
    groupOrder = try? container.decodeIfPresent(Int.self, forKey: .groupOrder)
  }

  /// Feed URLs are not always valid URL strings (raw spaces, a stray `\u{00C2}\u{00A0}`).
  /// Percent-encode as a fallback rather than dropping the entry.
  static func url(from raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let url = URL(string: trimmed), url.scheme != nil { return url }
    guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else { return nil }
    return URL(string: encoded)
  }

  private static func looksLikeHost(_ value: String) -> Bool {
    !value.isEmpty && value.contains(".") && !value.contains("/") && !value.contains(" ")
  }
}
#endif
```

- [ ] **Step 5: Run to verify it passes** — same command. Expected: all `SkinCatalogDecodingTests` PASS.
- [ ] **Step 6: Commit** — `git add Source/iOS/App/DolphiniOS/UI/Emulation/Skins/Store/SkinCatalog.swift Source/iOS/App/DolphiniOS/UI/Emulation/Skins/Store/SkinCatalogEntry.swift Source/iOS/App/DolphiniOSTests/SkinCatalogFixture.swift Source/iOS/App/DolphiniOSTests/SkinCatalogDecodingTests.swift && git commit -m "feat(skins): decode the provenance-emu.com skin catalog"`. (Strings `L(...)` used here are catalogued in Task 6.)

---

### Task 2: Catalog service with a 24-hour verbatim cache

**Files:**
- Create: `DolphiniOS/UI/Emulation/Skins/Store/SkinCatalogService.swift`
- Test: `DolphiniOSTests/SkinCatalogServiceTests.swift`

**Interfaces:**
- Consumes: `SkinCatalog.decode`, `SkinCatalogError`.
- Produces: `actor SkinCatalogService` with `static let shared`, `static let defaultCatalogURLs: [URL]`, `static let defaultTTL`, `static let cacheFileName = "skin_store_catalog.json"`, `init(catalogURLs:cacheURL:ttl:now:fetch:)`, `func load(forceRefresh: Bool = false) async throws -> SkinCatalogLoad`, `func catalog(forceRefresh:) async throws -> SkinCatalog`, `func cachedCatalog() -> SkinCatalog?`, `func invalidateCache()`; `struct SkinCatalogLoad { catalog; networkError: String?; isFallback }`.

- [ ] **Step 1: Write the failing tests** — `DolphiniOSTests/SkinCatalogServiceTests.swift`:

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
@testable import iCube

/// Cache and TTL behaviour with an injected fetch and clock; no network.
final class SkinCatalogServiceTests: XCTestCase {
  private final class FakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var _fetches = 0
    private var _status = 200
    private var _offline = false

    var fetches: Int { lock.withLock { _fetches } }
    func set(status: Int) { lock.withLock { _status = status } }
    func set(offline: Bool) { lock.withLock { _offline = offline } }

    func respond(_ url: URL) throws -> (Data, URLResponse) {
      let (status, offline) = lock.withLock {
        _fetches += 1
        return (_status, _offline)
      }
      if offline { throw URLError(.notConnectedToInternet) }
      let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
      return (SkinCatalogFixture.data, response ?? URLResponse())
    }
  }

  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { _now } }
    func advance(_ seconds: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(seconds) } }
  }

  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SkinCatalogServiceTests-\(UUID().uuidString)", isDirectory: true)
  private let server = FakeServer()
  private let clock = Clock()
  private var cacheURL: URL { directory.appendingPathComponent(SkinCatalogService.cacheFileName) }

  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func makeService() -> SkinCatalogService {
    let server = server
    let clock = clock
    return SkinCatalogService(catalogURLs: [URL(fileURLWithPath: "/catalog.json")], cacheURL: cacheURL,
                              ttl: 24 * 60 * 60, now: { clock.now }, fetch: { url in try server.respond(url) })
  }

  func testFirstFetchHitsNetworkAndWritesCache() async throws {
    let catalog = try await makeService().catalog()
    XCTAssertEqual(catalog.skins.count, SkinCatalogFixture.entryCount)
    XCTAssertEqual(server.fetches, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
  }

  func testWithinTTLServesMemoryWithoutFetching() async throws {
    let service = makeService()
    _ = try await service.catalog()
    clock.advance(60 * 60)
    _ = try await service.catalog()
    XCTAssertEqual(server.fetches, 1)
  }

  /// A fresh launch (new service instance) must honour the disk cache's age, not refetch every time.
  func testFreshDiskCacheIsUsedAcrossInstances() async throws {
    _ = try await makeService().catalog()
    clock.advance(23 * 60 * 60)
    let catalog = try await makeService().catalog()
    XCTAssertEqual(catalog.skins.count, SkinCatalogFixture.entryCount)
    XCTAssertEqual(server.fetches, 1)
  }

  func testExpiredCacheRefetches() async throws {
    let service = makeService()
    _ = try await service.catalog()
    clock.advance(25 * 60 * 60)
    _ = try await service.catalog()
    XCTAssertEqual(server.fetches, 2)
  }

  func testForceRefreshAlwaysFetches() async throws {
    let service = makeService()
    _ = try await service.catalog()
    _ = try await service.catalog(forceRefresh: true)
    XCTAssertEqual(server.fetches, 2)
  }

  func testOfflineFallsBackToStaleDiskCacheAndSaysSo() async throws {
    _ = try await makeService().catalog()
    clock.advance(30 * 24 * 60 * 60)
    server.set(offline: true)
    let load = try await makeService().load()
    XCTAssertEqual(load.catalog.skins.count, SkinCatalogFixture.entryCount)
    XCTAssertTrue(load.isFallback)
    XCTAssertNotNil(load.networkError)
  }

  func testHTTPErrorFallsBackToCacheOrThrows() async throws {
    server.set(status: 503)
    do {
      _ = try await makeService().catalog()
      XCTFail("expected a throw with no cache")
    } catch let error as SkinCatalogError {
      guard case .httpStatus(503) = error else { return XCTFail("unexpected \(error)") }
    }
    server.set(status: 200)
    let service = makeService()
    _ = try await service.catalog()
    server.set(status: 500)
    let fallback = try await service.catalog(forceRefresh: true)
    XCTAssertEqual(fallback.skins.count, SkinCatalogFixture.entryCount)
  }

  func testSecondURLIsTriedWhenFirstFails() async throws {
    let failing = URL(fileURLWithPath: "/down.json")
    let working = URL(fileURLWithPath: "/catalog.json")
    let server = server
    let service = SkinCatalogService(catalogURLs: [failing, working], cacheURL: cacheURL, fetch: { url in
      if url == failing { throw URLError(.cannotFindHost) }
      return try server.respond(url)
    })
    let catalog = try await service.catalog()
    XCTAssertEqual(catalog.skins.count, SkinCatalogFixture.entryCount)
  }

  func testCachedCatalogNeverTouchesNetwork() async throws {
    let empty = await makeService().cachedCatalog()
    XCTAssertNil(empty)
    _ = try await makeService().catalog()
    let cached = await makeService().cachedCatalog()
    XCTAssertEqual(cached?.skins.count, SkinCatalogFixture.entryCount)
    XCTAssertEqual(server.fetches, 1)
  }

  func testCorruptDiskCacheIsDiscarded() async throws {
    try Data("<html>".utf8).write(to: cacheURL)
    let catalog = try await makeService().catalog()
    XCTAssertEqual(catalog.skins.count, SkinCatalogFixture.entryCount)
    XCTAssertEqual(server.fetches, 1)
  }
}
#endif
```

- [ ] **Step 2: Run to verify it fails** — `make test TEST_ARGS="-only-testing:iCubeTests/SkinCatalogServiceTests"`. Expected: `cannot find 'SkinCatalogService' in scope`.

- [ ] **Step 3: Implement** `Store/SkinCatalogService.swift`:

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// What `SkinCatalogService.load` produced: the catalog, and whether it is a cached copy standing
/// in for a failed download.
struct SkinCatalogLoad: Sendable {
  var catalog: SkinCatalog
  /// Set when the network fetch failed and a cached catalog was returned instead.
  var networkError: String?

  var isFallback: Bool { networkError != nil }
}

/// Fetches and caches the provenance-emu.com skin catalog (ported from iFly).
///
/// The cache is the server's bytes, verbatim, at `cacheURL`; freshness is the file's modification
/// date, stamped from the injected clock so the TTL holds across launches. Failure order: network
/// (each mirror in turn) → in-memory copy (any age) → disk copy (any age) → throw. An offline
/// player with any previous fetch always gets a catalog.
actor SkinCatalogService {
  static let shared = SkinCatalogService()

  /// Primary first. The GitHub raw URL serves the same file from the repository the site is built from.
  static let defaultCatalogURLs: [URL] = [
    URL(string: "https://provenance-emu.com/skins/catalog.json"),
    URL(string: "https://raw.githubusercontent.com/Provenance-Emu/skins/main/catalog.json")
  ].compactMap { $0 }

  static let defaultTTL: TimeInterval = 24 * 60 * 60
  static let cacheFileName = "skin_store_catalog.json"
  private static let requestTimeout: TimeInterval = 30

  typealias Fetch = @Sendable (URL) async throws -> (Data, URLResponse)

  private let catalogURLs: [URL]
  private let cacheURL: URL
  private let ttl: TimeInterval
  private let now: @Sendable () -> Date
  private let fetch: Fetch

  private var memoryCatalog: SkinCatalog?
  /// When `memoryCatalog`'s bytes were fetched (the cache file's mtime when it came from disk).
  private var memoryFetchedAt: Date?

  init(catalogURLs: [URL] = SkinCatalogService.defaultCatalogURLs,
       cacheURL: URL = SkinCatalogService.defaultCacheURL,
       ttl: TimeInterval = SkinCatalogService.defaultTTL,
       now: @escaping @Sendable () -> Date = { Date() },
       fetch: @escaping Fetch = { url in
         var request = URLRequest(url: url)
         request.cachePolicy = .reloadIgnoringLocalCacheData
         request.timeoutInterval = SkinCatalogService.requestTimeout
         return try await URLSession.shared.data(for: request)
       }) {
    self.catalogURLs = catalogURLs
    self.cacheURL = cacheURL
    self.ttl = ttl
    self.now = now
    self.fetch = fetch
  }

  static var defaultCacheURL: URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
    return caches.appendingPathComponent(cacheFileName)
  }

  // MARK: - Public API

  /// The catalog: from cache when fresh, otherwise from the network with a cache fallback.
  func catalog(forceRefresh: Bool = false) async throws -> SkinCatalog {
    try await load(forceRefresh: forceRefresh).catalog
  }

  /// `catalog(forceRefresh:)` plus whether a cached copy stood in for a failed download.
  func load(forceRefresh: Bool = false) async throws -> SkinCatalogLoad {
    if !forceRefresh, let fresh = freshCachedCatalog() {
      return SkinCatalogLoad(catalog: fresh, networkError: nil)
    }
    let networkError: Error
    do {
      return try await SkinCatalogLoad(catalog: fetchFromNetwork(), networkError: nil)
    } catch {
      networkError = error
    }
    if let memoryCatalog {
      NSLog("[SKINSTORE] Catalog fetch failed (%@); using in-memory copy", networkError.localizedDescription)
      return SkinCatalogLoad(catalog: memoryCatalog, networkError: networkError.localizedDescription)
    }
    if let disk = loadDiskCache() {
      NSLog("[SKINSTORE] Catalog fetch failed (%@); using disk cache", networkError.localizedDescription)
      memoryCatalog = disk.catalog
      memoryFetchedAt = disk.modified
      return SkinCatalogLoad(catalog: disk.catalog, networkError: networkError.localizedDescription)
    }
    throw networkError
  }

  /// Whatever is cached, at any age, without touching the network.
  func cachedCatalog() -> SkinCatalog? {
    if let memoryCatalog { return memoryCatalog }
    guard let disk = loadDiskCache() else { return nil }
    memoryCatalog = disk.catalog
    memoryFetchedAt = disk.modified
    return disk.catalog
  }

  func invalidateCache() {
    memoryCatalog = nil
    memoryFetchedAt = nil
    try? FileManager.default.removeItem(at: cacheURL)
  }

  // MARK: - Private

  private func freshCachedCatalog() -> SkinCatalog? {
    if let memoryCatalog, let memoryFetchedAt, now().timeIntervalSince(memoryFetchedAt) < ttl { return memoryCatalog }
    guard let disk = loadDiskCache(), now().timeIntervalSince(disk.modified) < ttl else { return nil }
    memoryCatalog = disk.catalog
    memoryFetchedAt = disk.modified
    return disk.catalog
  }

  private func fetchFromNetwork() async throws -> SkinCatalog {
    var lastError: Error = SkinCatalogError.network("no catalog URL configured")
    for url in catalogURLs {
      do {
        let (data, response) = try await fetch(url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
          throw SkinCatalogError.httpStatus(http.statusCode)
        }
        let catalog = try SkinCatalog.decode(data)
        storeDiskCache(data)
        memoryCatalog = catalog
        memoryFetchedAt = now()
        NSLog("[SKINSTORE] Fetched catalog from %@: %d skins, %d undecodable", url.host ?? url.absoluteString, catalog.skins.count, catalog.droppedEntryCount)
        return catalog
      } catch {
        NSLog("[SKINSTORE] Catalog fetch from %@ failed: %@", url.absoluteString, error.localizedDescription)
        lastError = error
      }
    }
    if lastError is SkinCatalogError { throw lastError }
    throw SkinCatalogError.network(lastError.localizedDescription)
  }

  private func loadDiskCache() -> (catalog: SkinCatalog, modified: Date)? {
    guard let data = try? Data(contentsOf: cacheURL) else { return nil }
    let attributes = try? FileManager.default.attributesOfItem(atPath: cacheURL.path)
    let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
    do {
      return try (SkinCatalog.decode(data), modified)
    } catch {
      NSLog("[SKINSTORE] Discarding unreadable catalog cache: %@", error.localizedDescription)
      try? FileManager.default.removeItem(at: cacheURL)
      return nil
    }
  }

  private func storeDiskCache(_ data: Data) {
    do {
      try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: cacheURL, options: .atomic)
      // Stamp the mtime from the injected clock so the TTL check and the write agree (and tests can drive time).
      try FileManager.default.setAttributes([.modificationDate: now()], ofItemAtPath: cacheURL.path)
    } catch {
      NSLog("[SKINSTORE] Could not write catalog cache: %@", error.localizedDescription)
    }
  }
}
#endif
```

- [ ] **Step 4: Run to verify it passes** — Expected: all `SkinCatalogServiceTests` PASS.
- [ ] **Step 5: Commit** — `git add Source/iOS/App/DolphiniOS/UI/Emulation/Skins/Store/SkinCatalogService.swift Source/iOS/App/DolphiniOSTests/SkinCatalogServiceTests.swift && git commit -m "feat(skins): fetch and cache the skin catalog"`.

---

### Task 3: Retarget N64 skins onto the GameCube pad

**Files:**
- Modify: `DolphiniOS/UI/Emulation/Skins/SkinGameType.swift`
- Modify: `DolphiniOS/UI/Emulation/Skins/SkinInputMap.swift`
- Modify: `DolphiniOS/UI/Emulation/Skins/SkinLibrary.swift`
- Test: `DolphiniOSTests/SkinInputMapTests.swift`, `DolphiniOSTests/SkinLibraryTests.swift`

**Interfaces:**
- Produces: `SkinGameType.manicIdentifier: String` (`public.aoshuang.game.ngc` / `.wii`), `SkinGameType.retargetSuffix: String` (`-gamecube` / `-wii`).
- Produces: `SkinLibrary.importSkin(from archive: URL, retargetingTo target: SkinGameType? = nil) throws -> InstalledSkin`; `static func defaultRootURL() -> URL` (now internal); `static let storeRecordFileName = "store.json"`.
- Produces: `SkinInputName.cUp/.cDown/.cLeft/.cRight` and their spellings; `SkinInputMap.action(for: ["cUp"], padKind: .gameCube) == .control(.axisButton(id: 16))` etc.

- [ ] **Step 1: Write the failing tests** — append to `SkinInputMapTests`:

```swift
  /// N64 skins installed from the store keep their C-button items; on the GameCube pad those press
  /// the C-stick half-axes. Provenance accepts the same spellings.
  func testN64CButtonsDriveTheCStickOnGameCubeOnly() {
    XCTAssertEqual(SkinInputMap.action(for: ["cUp"], padKind: .gameCube), .control(.axisButton(id: 16)))
    XCTAssertEqual(SkinInputMap.action(for: ["cDown"], padKind: .gameCube), .control(.axisButton(id: 17)))
    XCTAssertEqual(SkinInputMap.action(for: ["cLeft"], padKind: .gameCube), .control(.axisButton(id: 18)))
    XCTAssertEqual(SkinInputMap.action(for: ["cRight"], padKind: .gameCube), .control(.axisButton(id: 19)))
    XCTAssertEqual(SkinInputMap.action(for: ["c-up"], padKind: .gameCube), .control(.axisButton(id: 16)))
    XCTAssertEqual(SkinInputMap.action(for: ["c▼"], padKind: .gameCube), .control(.axisButton(id: 17)))
    XCTAssertEqual(SkinInputMap.action(for: ["CUP"], padKind: .gameCube), .control(.axisButton(id: 16)), "case-insensitive")
    XCTAssertNil(SkinInputMap.action(for: ["cUp"], padKind: .wiiRemote))
    XCTAssertNil(SkinInputMap.action(for: ["cUp"], padKind: .wiiClassic))
  }

  func testManicIdentifiersAndRetargetSuffixes() {
    XCTAssertEqual(SkinGameType.gameCube.manicIdentifier, "public.aoshuang.game.ngc")
    XCTAssertEqual(SkinGameType.wii.manicIdentifier, "public.aoshuang.game.wii")
    XCTAssertEqual(SkinGameType(identifier: SkinGameType.gameCube.manicIdentifier), .gameCube)
    XCTAssertEqual(SkinGameType.gameCube.retargetSuffix, "-gamecube")
  }
```

and append to `SkinLibraryTests` (inside the class; `makeArchive(gameType:)` already exists there):

```swift
  func testRetargetInstallsAnN64SkinAsGameCube() throws {
    let library = SkinLibrary(rootURL: root)
    let archive = try makeArchive(gameType: "com.rileytestut.delta.game.n64")
    let skin = try library.importSkin(from: archive, retargetingTo: .gameCube)
    XCTAssertEqual(skin.gameType, .gameCube)
    XCTAssertEqual(skin.id, "\(Self.fixtureIdentifier)-gamecube")
    XCTAssertEqual(skin.name, "Test Cube")
    let info = try SkinInfo.load(directory: skin.directory)
    XCTAssertEqual(info.identifier, "\(Self.fixtureIdentifier)-gamecube")
    XCTAssertEqual(info.gameType, .gameCube)
    XCTAssertTrue(FileManager.default.fileExists(atPath: skin.directory.appendingPathComponent("bg.png").path), "assets travel with the rewrite")
    XCTAssertEqual(SkinLibrary(rootURL: root).skins.map(\.id), [skin.id], "a fresh scan reads the rewritten info.json")
  }

  func testRetargetKeepsAnAsIsImportSeparate() throws {
    let library = SkinLibrary(rootURL: root)
    _ = try library.importSkin(from: makeArchive())
    _ = try library.importSkin(from: makeArchive(gameType: "com.rileytestut.delta.game.n64"), retargetingTo: .gameCube)
    XCTAssertEqual(library.skins.map(\.id).sorted(), [Self.fixtureIdentifier, "\(Self.fixtureIdentifier)-gamecube"])
  }

  func testRetargetToTheSkinsOwnTypeIsANoOp() throws {
    let library = SkinLibrary(rootURL: root)
    let skin = try library.importSkin(from: makeArchive(), retargetingTo: .gameCube)
    XCTAssertEqual(skin.id, Self.fixtureIdentifier, "already GameCube: no suffix, no rewrite")
  }

  func testWithoutRetargetAnN64SkinStillThrows() throws {
    let library = SkinLibrary(rootURL: root)
    XCTAssertThrowsError(try library.importSkin(from: makeArchive(gameType: "com.rileytestut.delta.game.n64"))) {
      XCTAssertEqual($0 as? SkinImportError, .unsupportedGameType("com.rileytestut.delta.game.n64"))
    }
    XCTAssertEqual(installedFolderNames(), [])
  }
```

- [ ] **Step 2: Run to verify they fail** — `make test TEST_ARGS="-only-testing:iCubeTests/SkinInputMapTests -only-testing:iCubeTests/SkinLibraryTests"`. Expected: compile errors (`manicIdentifier`, extra argument `retargetingTo`).

- [ ] **Step 3: Implement.** In `SkinGameType.swift`, add inside the enum:

```swift
  private static let manicPrefix = "public.aoshuang.game."

  /// The Manic EMU identifier for this game type, used when a skin is rewritten to it.
  var manicIdentifier: String {
    switch self {
    case .gameCube: return Self.manicPrefix + "ngc"
    case .wii: return Self.manicPrefix + "wii"
    }
  }

  /// Appended to a skin's identifier when it is rewritten to this type, so the rewritten copy never
  /// replaces an as-is import of the same skin.
  var retargetSuffix: String {
    switch self {
    case .gameCube: return "-gamecube"
    case .wii: return "-wii"
    }
  }
```

In `SkinInputMap.swift`, add to `SkinInputName` (after `rightThumbstick`):

```swift
  /// N64 C buttons, as Delta skins spell them (`cUp`), Provenance's hyphenated and arrow forms too.
  static let cUp = "cUp", cDown = "cDown", cLeft = "cLeft", cRight = "cRight"
  static let cUpHyphen = "c-up", cDownHyphen = "c-down", cLeftHyphen = "c-left", cRightHyphen = "c-right"
  static let cUpArrow = "c▲", cDownArrow = "c▼", cLeftArrow = "c◀", cRightArrow = "c▶"
```

and extend `gameCubeControls` (the C-stick half-axes are `gcCStick + 1 … + 4` in Up/Down/Left/Right order, the same layout `TouchOverlayInput.stickWrites` uses):

```swift
    SkinInputName.cUp: .axisButton(id: ID.gcCStick + 1),
    SkinInputName.cDown: .axisButton(id: ID.gcCStick + 2),
    SkinInputName.cLeft: .axisButton(id: ID.gcCStick + 3),
    SkinInputName.cRight: .axisButton(id: ID.gcCStick + 4),
    SkinInputName.cUpHyphen: .axisButton(id: ID.gcCStick + 1),
    SkinInputName.cDownHyphen: .axisButton(id: ID.gcCStick + 2),
    SkinInputName.cLeftHyphen: .axisButton(id: ID.gcCStick + 3),
    SkinInputName.cRightHyphen: .axisButton(id: ID.gcCStick + 4),
    SkinInputName.cUpArrow: .axisButton(id: ID.gcCStick + 1),
    SkinInputName.cDownArrow: .axisButton(id: ID.gcCStick + 2),
    SkinInputName.cLeftArrow: .axisButton(id: ID.gcCStick + 3),
    SkinInputName.cRightArrow: .axisButton(id: ID.gcCStick + 4)
```

In `SkinLibrary.swift`: make `defaultRootURL()` `static func` (drop `private`); add `static let storeRecordFileName = "store.json"`; add `storeRecordFileName` to the names `isUsableFolderName` refuses; change the import signature and insert the retarget between locating the folder and loading the info:

```swift
  /// Unpacks, validates and installs the skin in `archive`, replacing any installed skin with the same identifier.
  /// With `target`, a skin made for another system is rewritten to it first (`info.json` gets the target's game type
  /// and a suffixed identifier); a skin already of that type is installed as-is. Nothing is left on disk when this throws.
  @discardableResult
  func importSkin(from archive: URL, retargetingTo target: SkinGameType? = nil) throws -> InstalledSkin {
    …
    let skinFolder = try Self.skinFolder(in: extracted)
    if let target { try Self.retarget(folder: skinFolder, to: target) }
    let info = try Self.loadInfo(from: skinFolder)
    …
  }

  private static let identifierKey = "identifier"

  /// Rewrites `info.json` so the skin declares `target`: the Manic game type, and the identifier with the target's
  /// suffix. Comments are stripped and the JSON re-serialised; assets are untouched. No-op when the skin already
  /// declares `target`.
  private static func retarget(folder: URL, to target: SkinGameType) throws {
    let infoURL = folder.appendingPathComponent(infoFileName)
    guard let raw = try? Data(contentsOf: infoURL),
          let data = try? SkinInfo.stripComments(raw),
          var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let identifier = json[identifierKey] as? String else { throw SkinImportError.missingInfo }
    if let current = json[gameTypeKey] as? String, SkinGameType(identifier: current) == target { return }
    json[gameTypeKey] = target.manicIdentifier
    json[identifierKey] = identifier + target.retargetSuffix
    let rewritten = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try rewritten.write(to: infoURL, options: .atomic)
  }
```

- [ ] **Step 4: Run to verify they pass** — same command. Expected: PASS, including the pre-existing `SkinLibraryTests` and `SkinInputMapTests`.
- [ ] **Step 5: Commit** — `git add Source/iOS/App/DolphiniOS/UI/Emulation/Skins/SkinGameType.swift Source/iOS/App/DolphiniOS/UI/Emulation/Skins/SkinInputMap.swift Source/iOS/App/DolphiniOS/UI/Emulation/Skins/SkinLibrary.swift Source/iOS/App/DolphiniOSTests/SkinInputMapTests.swift Source/iOS/App/DolphiniOSTests/SkinLibraryTests.swift && git commit -m "feat(skins): rewrite N64 skins to GameCube and map their C buttons"`.

---

### Task 4: Store shelves (pure policy)

**Files:**
- Create: `DolphiniOS/UI/Emulation/Skins/Store/SkinStorePolicy.swift`
- Test: `DolphiniOSTests/SkinStorePolicyTests.swift`

**Interfaces:**
- Consumes: `SkinCatalogEntry`, `SkinGameType`, `SkinLibrary.archiveExtensions`.
- Produces: `enum SkinStoreSection: String, CaseIterable, Identifiable, Sendable { gameCube, wii, nintendo64; static let ordered; var retarget: SkinGameType? }`, `enum SkinStorePolicy { static func section(for:) -> SkinStoreSection?; static func sections(for:) -> [(section: SkinStoreSection, entries: [SkinCatalogEntry])]; static func installableExtension(for: URL) -> String?; static func downloadFileName(for:) -> String? }`.

- [ ] **Step 1: Write the failing tests** — `DolphiniOSTests/SkinStorePolicyTests.swift`:

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
@testable import iCube

final class SkinStorePolicyTests: XCTestCase {
  private var catalog: SkinCatalog!

  override func setUpWithError() throws {
    catalog = try SkinCatalog.decode(SkinCatalogFixture.data)
    // Guard against the lossy decoder making every "is hidden" test vacuous.
    XCTAssertEqual(catalog.skins.count, SkinCatalogFixture.entryCount)
  }

  private func section(_ id: String) throws -> SkinStoreSection? {
    let entry = try XCTUnwrap(catalog.skins.first { $0.id == id }, "missing \(id)")
    return SkinStorePolicy.section(for: entry)
  }

  private func entry(id: String = "x", systems: [String], gameType: String? = nil, url: String) throws -> SkinCatalogEntry {
    try SkinCatalogEntry(id: id, name: id, systems: systems, gameTypeIdentifier: gameType, downloadURL: XCTUnwrap(URL(string: url)))
  }

  // MARK: - Sections from the feed

  func testGameCubeAndWiiEntriesLandOnTheirShelves() throws {
    XCTAssertEqual(try section(SkinCatalogFixture.gameCubePocketID), .gameCube)
    XCTAssertEqual(try section(SkinCatalogFixture.mixedCaseGameCubeID), .gameCube, "codes compare lowercased")
    XCTAssertEqual(try section(SkinCatalogFixture.wiiID), .wii)
  }

  func testN64SkinsLandOnTheN64Shelf() throws {
    XCTAssertEqual(try section(SkinCatalogFixture.n64PackID), .nintendo64)
    XCTAssertEqual(try section(SkinCatalogFixture.n64SpaceURLID), .nintendo64)
    XCTAssertEqual(try section(SkinCatalogFixture.n64DeltaTypeID), .nintendo64)
  }

  func testZipsAndExtensionlessLinksAreHidden() throws {
    XCTAssertNil(try section(SkinCatalogFixture.n64ZipID), "an N64 .zip")
    XCTAssertNil(try section(SkinCatalogFixture.gbaZipID))
    XCTAssertNil(try section(SkinCatalogFixture.googleDriveID))
    XCTAssertNil(try SkinStorePolicy.section(for: entry(systems: ["gamecube"], url: "https://example.com/skin")))
  }

  func testOtherSystemsAreHidden() throws {
    XCTAssertNil(try section(SkinCatalogFixture.threeDSID))
    XCTAssertNil(try section(SkinCatalogFixture.gbaSpaceURLID))
    XCTAssertNil(try section(SkinCatalogFixture.unofficialID))
  }

  func testFixtureSectionCounts() {
    let grouped = SkinStorePolicy.sections(for: catalog.skins)
    XCTAssertEqual(grouped.map(\.section), [.gameCube, .wii, .nintendo64])
    XCTAssertEqual(grouped.map(\.entries.count), [2, 1, 3])
    XCTAssertEqual(grouped[0].entries.map(\.id), [SkinCatalogFixture.gameCubePocketID, SkinCatalogFixture.mixedCaseGameCubeID], "feed order kept")
  }

  // MARK: - Rules

  func testGameTypeSuffixPlacesAnEntryWithoutSystems() throws {
    XCTAssertEqual(try SkinStorePolicy.section(for: entry(systems: [], gameType: "public.aoshuang.game.ngc", url: "https://e.com/a.manicskin")), .gameCube)
    XCTAssertEqual(try SkinStorePolicy.section(for: entry(systems: [], gameType: "com.rileytestut.delta.game.wii", url: "https://e.com/a.deltaskin")), .wii)
    XCTAssertEqual(try SkinStorePolicy.section(for: entry(systems: [], gameType: "com.rileytestut.delta.game.n64", url: "https://e.com/a.deltaskin")), .nintendo64)
    XCTAssertNil(try SkinStorePolicy.section(for: entry(systems: [], gameType: "com.rileytestut.delta.game.gba", url: "https://e.com/a.deltaskin")))
  }

  func testExtensionMatchIsCaseInsensitive() throws {
    XCTAssertEqual(try SkinStorePolicy.section(for: entry(systems: ["GameCube"], url: "https://example.com/A.DeltaSkin")), .gameCube)
    XCTAssertEqual(try SkinStorePolicy.section(for: entry(systems: ["WII"], url: "https://example.com/a.MANICSKIN")), .wii)
  }

  func testPlaceholderCodeDoesNotHideARealSystem() throws {
    XCTAssertEqual(try SkinStorePolicy.section(for: entry(systems: ["unknown", "n64"], url: "https://e.com/a.manicskin")), .nintendo64)
  }

  func testGameCubeBeatsWiiBeatsN64() throws {
    XCTAssertEqual(try SkinStorePolicy.section(for: entry(systems: ["n64", "wii", "gamecube"], url: "https://e.com/a.deltaskin")), .gameCube)
    XCTAssertEqual(try SkinStorePolicy.section(for: entry(systems: ["n64", "wii"], url: "https://e.com/a.deltaskin")), .wii)
  }

  func testOrderedSectionsAndEmptySectionsOmitted() throws {
    let entries = try [
      entry(id: "n", systems: ["n64"], url: "https://e.com/n.deltaskin"),
      entry(id: "g", systems: ["gamecube"], url: "https://e.com/g.manicskin")
    ]
    let grouped = SkinStorePolicy.sections(for: entries)
    XCTAssertEqual(grouped.map(\.section), [.gameCube, .nintendo64])
    XCTAssertEqual(SkinStoreSection.ordered, [.gameCube, .wii, .nintendo64])
  }

  func testRetargetOnlyForTheN64Shelf() {
    XCTAssertNil(SkinStoreSection.gameCube.retarget)
    XCTAssertNil(SkinStoreSection.wii.retarget)
    XCTAssertEqual(SkinStoreSection.nintendo64.retarget, .gameCube)
  }

  func testDownloadFileNameUsesEntryIdAndURLExtension() throws {
    let pocket = try XCTUnwrap(catalog.skins.first { $0.id == SkinCatalogFixture.gameCubePocketID })
    XCTAssertEqual(SkinStorePolicy.downloadFileName(for: pocket), "ea60f2003d82ac9e.manicskin")
    XCTAssertEqual(try SkinStorePolicy.downloadFileName(for: entry(id: "a/b:c", systems: [], url: "https://e.com/x.ManicSkin")), "a-b-c.manicskin")
    XCTAssertNil(try SkinStorePolicy.downloadFileName(for: entry(systems: [], url: "https://e.com/x.zip")))
  }
}
#endif
```

- [ ] **Step 2: Run to verify it fails** — `make test TEST_ARGS="-only-testing:iCubeTests/SkinStorePolicyTests"`. Expected: `cannot find 'SkinStorePolicy'`.

- [ ] **Step 3: Implement** `Store/SkinStorePolicy.swift`:

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// The shelves the skin store shows, in display order. GameCube and Wii skins install as-is; N64
/// layouts are rewritten to the GameCube pad on install.
enum SkinStoreSection: String, CaseIterable, Sendable, Identifiable {
  case gameCube
  case wii
  case nintendo64

  var id: String { rawValue }

  /// Display order. `allCases` happens to match, but the store reads this so a reordering of the
  /// enum cannot silently reshuffle the UI.
  static let ordered: [SkinStoreSection] = [.gameCube, .wii, .nintendo64]

  /// The game type a skin from this shelf is rewritten to on install, or nil to install as-is.
  var retarget: SkinGameType? {
    switch self {
    case .gameCube, .wii: return nil
    case .nintendo64: return .gameCube
    }
  }
}

/// Decides which catalog entries the store shows, where, and how each downloads. Pure: the feed is
/// about 1,400 entries and this runs over all of them.
enum SkinStorePolicy {
  static let gameCubeCode = "gamecube"
  static let wiiCode = "wii"
  static let nintendo64Code = "n64"

  /// Leftover codes from before the feed's systems were cleaned up. They say nothing about the
  /// layout, so they never place an entry.
  static let placeholderSystemCodes: Set<String> = ["unofficial", "unsupported", "unknown"]

  /// Archives `SkinLibrary` imports by extension. `.zip` (often a folder of skins) and extensionless
  /// links (not identifiable before download) are hidden.
  static var installableExtensions: Set<String> { SkinLibrary.archiveExtensions }

  private static let unsafeFileNameCharacters = CharacterSet(charactersIn: "/:\\\n\r\t")
  private static let fallbackFileStem = "skin"

  /// The lowercased skin extension of `url`'s last path component, or nil when it is not importable.
  static func installableExtension(for url: URL) -> String? {
    let ext = url.pathExtension.lowercased()
    return installableExtensions.contains(ext) ? ext : nil
  }

  /// The system codes an entry claims: its `systems` minus placeholders, plus the code its game type
  /// identifier implies (the one `gamecube` entry has `systems` *and* `public.aoshuang.game.ngc`;
  /// an entry could carry only the latter).
  static func systemCodes(for entry: SkinCatalogEntry) -> Set<String> {
    var codes = Set(entry.normalizedSystems).subtracting(placeholderSystemCodes)
    if let suffix = entry.gameTypeSuffix {
      switch SkinGameType(identifier: suffix) {
      case .gameCube?: codes.insert(gameCubeCode)
      case .wii?: codes.insert(wiiCode)
      case nil: if suffix == nintendo64Code { codes.insert(nintendo64Code) }
      }
    }
    return codes
  }

  /// The shelf for `entry`, or nil when the store hides it. When an entry lists several systems
  /// the strongest claim wins: GameCube, then Wii, then N64.
  static func section(for entry: SkinCatalogEntry) -> SkinStoreSection? {
    guard installableExtension(for: entry.downloadURL) != nil else { return nil }
    let codes = systemCodes(for: entry)
    if codes.contains(gameCubeCode) { return .gameCube }
    if codes.contains(wiiCode) { return .wii }
    if codes.contains(nintendo64Code) { return .nintendo64 }
    return nil
  }

  /// Visible entries grouped by shelf, shelves in display order, empty shelves omitted. Entries keep
  /// feed order within a shelf.
  static func sections(for entries: [SkinCatalogEntry]) -> [(section: SkinStoreSection, entries: [SkinCatalogEntry])] {
    var grouped: [SkinStoreSection: [SkinCatalogEntry]] = [:]
    for entry in entries {
      guard let section = section(for: entry) else { continue }
      grouped[section, default: []].append(entry)
    }
    return SkinStoreSection.ordered.compactMap { section in
      guard let list = grouped[section], !list.isEmpty else { return nil }
      return (section, list)
    }
  }

  /// Local file name for a download: `<entry id>.<deltaskin|manicskin>`. The library keys off the
  /// extension, and many feed URLs end in a name that is unsafe or ambiguous as a path component.
  static func downloadFileName(for entry: SkinCatalogEntry) -> String? {
    guard let ext = installableExtension(for: entry.downloadURL) else { return nil }
    let stem = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
      .components(separatedBy: unsafeFileNameCharacters).filter { !$0.isEmpty }.joined(separator: "-")
    return "\(stem.isEmpty ? fallbackFileStem : stem).\(ext)"
  }
}
#endif
```

- [ ] **Step 4: Run to verify it passes** — Expected: PASS.
- [ ] **Step 5: Commit** — `git add Source/iOS/App/DolphiniOS/UI/Emulation/Skins/Store/SkinStorePolicy.swift Source/iOS/App/DolphiniOSTests/SkinStorePolicyTests.swift && git commit -m "feat(skins): sort the catalog into GameCube, Wii and N64 shelves"`.

---

### Task 5: Download and install

**Files:**
- Create: `DolphiniOS/UI/Emulation/Skins/Store/SkinStoreDownloader.swift`
- Create: `DolphiniOS/UI/Emulation/Skins/Store/SkinStoreDownloadDelegate.swift`
- Create: `DolphiniOS/UI/Emulation/Skins/Store/SkinStoreInstalledRecord.swift`
- Create: `DolphiniOS/UI/Emulation/Skins/Store/SkinStoreInstaller.swift`
- Test: `DolphiniOSTests/SkinStoreInstallerTests.swift`

**Interfaces:**
- Consumes: `SkinStorePolicy`, `SkinStoreSection.retarget`, `SkinLibrary.importSkin(from:retargetingTo:)`, `SkinLibrary.defaultRootURL()`, `SkinLibrary.storeRecordFileName`, `InstalledSkin`.
- Produces: `protocol SkinStoreDownloading: Sendable { func download(from: URL, to: URL, progress: @escaping @Sendable (Double) -> Void) async throws }`, `struct URLSessionSkinStoreDownloader: SkinStoreDownloading` with nested `struct HTTPStatusError: LocalizedError { statusCode }`.
- Produces: `struct SkinStoreInstalledRecord { init(fileURL: URL = …); func load() -> [String: String]; func markInstalled(catalogId:skinIdentifier:); func remove(catalogIds: Set<String>) }`.
- Produces: `enum SkinStoreInstallState: Equatable { idle, downloading(progress: Double), installing, installed, failed(message: String); var isBusy }`; `@MainActor final class SkinStoreInstaller: ObservableObject` with `static let shared`, `typealias InstallStep = @MainActor (_ file: URL, _ section: SkinStoreSection) throws -> InstalledSkin`, `init(downloader:record:installStep:)`, `static func libraryInstallStep(_ library: SkinLibrary) -> InstallStep`, `@Published states`, `@Published installedIds: Set<String>`, `func state(for:) -> SkinStoreInstallState`, `func startInstall(_:)`, `func cancelInstall(_:)`, `func install(_:) async`, `func reconcileInstalled(with installedSkinIds: Set<String>)`.

- [ ] **Step 1: Write the failing tests** — `DolphiniOSTests/SkinStoreInstallerTests.swift`:

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Combine
import XCTest
import Zip
@testable import iCube

/// The installer's state machine with the network stubbed, plus one pass through a real `SkinLibrary`.
@MainActor
final class SkinStoreInstallerTests: XCTestCase {
  /// Writes `source` (or a placeholder) to the destination, reports scripted progress, optionally fails.
  private struct FakeDownloader: SkinStoreDownloading {
    var error: Error?
    var source: URL?
    var progressSteps: [Double] = [0.25, 0.5, 1]

    func download(from _: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
      for step in progressSteps { progress(step) }
      if let error { throw error }
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      if let source {
        try FileManager.default.copyItem(at: source, to: destination)
      } else {
        try Data("skin".utf8).write(to: destination)
      }
    }
  }

  private var scratch: URL!
  private var recordURL: URL { scratch.appendingPathComponent("store.json") }

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SkinStoreInstallerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  private func record() -> SkinStoreInstalledRecord { SkinStoreInstalledRecord(fileURL: recordURL) }

  private func installed(id: String = "x", name: String = "Skin", gameType: SkinGameType = .gameCube) -> InstalledSkin {
    InstalledSkin(id: id, name: name, gameType: gameType, directory: scratch.appendingPathComponent(id))
  }

  private func entry(id: String = SkinCatalogFixture.gameCubePocketID, systems: [String] = ["gamecube"],
                     url: String = "https://deltastyles.com/files/skins/760/gamecubepocket.manicskin") throws -> SkinCatalogEntry {
    try SkinCatalogEntry(id: id, name: "GameCube Pocket", systems: systems, downloadURL: XCTUnwrap(URL(string: url)))
  }

  func testSuccessfulInstallRecordsTheCatalogId() async throws {
    var seen: [(file: String, section: SkinStoreSection, fileExists: Bool)] = []
    let installer = SkinStoreInstaller(downloader: FakeDownloader(), record: record(), installStep: { file, section in
      seen.append((file.lastPathComponent, section, FileManager.default.fileExists(atPath: file.path)))
      return self.installed(id: "com.starvingartist.gamecubepocket")
    })
    let skin = try entry()
    XCTAssertEqual(installer.state(for: skin), .idle)

    await installer.install(skin)

    XCTAssertEqual(installer.state(for: skin), .installed)
    XCTAssertEqual(seen.count, 1)
    XCTAssertEqual(seen.first?.file, "\(SkinCatalogFixture.gameCubePocketID).manicskin", "named <entry id>.<ext>")
    XCTAssertEqual(seen.first?.section, .gameCube)
    XCTAssertEqual(seen.first?.fileExists, true)
    XCTAssertEqual(record().load(), [SkinCatalogFixture.gameCubePocketID: "com.starvingartist.gamecubepocket"])
  }

  func testInstalledStateSurvivesANewInstaller() async throws {
    let first = SkinStoreInstaller(downloader: FakeDownloader(), record: record(), installStep: { _, _ in self.installed() })
    let skin = try entry()
    await first.install(skin)
    let second = SkinStoreInstaller(downloader: FakeDownloader(), record: record(), installStep: { _, _ in
      XCTFail("must not install")
      return self.installed()
    })
    XCTAssertEqual(second.state(for: skin), .installed)
  }

  func testDownloadFailureSurfacesMessage() async throws {
    let installer = SkinStoreInstaller(downloader: FakeDownloader(error: URLSessionSkinStoreDownloader.HTTPStatusError(statusCode: 404)),
                                       record: record(), installStep: { _, _ in
      XCTFail("install must not run after a failed download")
      return self.installed()
    })
    let skin = try entry()
    await installer.install(skin)
    XCTAssertEqual(installer.state(for: skin), .failed(message: URLSessionSkinStoreDownloader.HTTPStatusError(statusCode: 404).localizedDescription))
    XCTAssertFalse(installer.installedIds.contains(skin.id))
  }

  /// A dead link that answers HTML with 200 reaches the library as a non-archive.
  func testInstallStepFailureSurfacesMessage() async throws {
    let installer = SkinStoreInstaller(downloader: FakeDownloader(), record: record(),
                                       installStep: { _, _ in throw SkinImportError.unreadableArchive })
    let skin = try entry()
    await installer.install(skin)
    XCTAssertEqual(installer.state(for: skin), .failed(message: SkinImportError.describe(SkinImportError.unreadableArchive)))
    XCTAssertEqual(record().load(), [:])
  }

  func testStatesPassThroughDownloadingAndInstalling() async throws {
    var observed: [SkinStoreInstallState] = []
    let installer = SkinStoreInstaller(downloader: FakeDownloader(), record: record(), installStep: { _, _ in self.installed() })
    let skin = try entry()
    let cancellable = installer.$states.sink { states in
      if let state = states[skin.id] { observed.append(state) }
    }
    defer { cancellable.cancel() }

    await installer.install(skin)

    XCTAssertEqual(observed.first, .downloading(progress: 0))
    XCTAssertTrue(observed.contains(.installing))
    XCTAssertEqual(observed.last, .installed)
  }

  func testCancellationReturnsToIdle() async throws {
    let installer = SkinStoreInstaller(downloader: FakeDownloader(error: CancellationError()), record: record(),
                                       installStep: { _, _ in self.installed() })
    let skin = try entry()
    await installer.install(skin)
    XCTAssertEqual(installer.state(for: skin), .idle)
  }

  func testTemporaryDownloadFolderIsRemoved() async throws {
    var downloadedTo: URL?
    let installer = SkinStoreInstaller(downloader: FakeDownloader(), record: record(), installStep: { file, _ in
      downloadedTo = file
      return self.installed()
    })
    await installer.install(try entry())
    let folder = try XCTUnwrap(downloadedTo).deletingLastPathComponent()
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
  }

  func testHiddenEntryFailsWithoutDownloading() async throws {
    let installer = SkinStoreInstaller(downloader: FakeDownloader(error: URLError(.badURL)), record: record(),
                                       installStep: { _, _ in self.installed() })
    let zip = try entry(id: SkinCatalogFixture.n64ZipID, systems: ["n64"], url: "https://deltastyles.com/files/skins/758/x.zip")
    await installer.install(zip)
    guard case .failed = installer.state(for: zip) else { return XCTFail("a .zip entry must not install") }
  }

  func testReconcileForgetsDeletedSkins() async throws {
    let record = record()
    record.markInstalled(catalogId: "kept", skinIdentifier: "skin.kept")
    record.markInstalled(catalogId: "deleted", skinIdentifier: "skin.deleted")
    let installer = SkinStoreInstaller(downloader: FakeDownloader(), record: record, installStep: { _, _ in self.installed() })
    XCTAssertEqual(installer.installedIds, ["kept", "deleted"])

    installer.reconcileInstalled(with: ["skin.kept", "something.else"])

    XCTAssertEqual(installer.installedIds, ["kept"])
    XCTAssertEqual(record.load(), ["kept": "skin.kept"])
  }

  /// The default install step, end to end: a real archive through a real library, with the N64 shelf's retarget.
  func testLibraryInstallStepInstallsAndRetargets() async throws {
    let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "TestCube", withExtension: "deltaskin", subdirectory: "Skins"))
    let packed = scratch.appendingPathComponent("Packed", isDirectory: true)
    try FileManager.default.copyItem(at: fixture, to: packed)
    let infoURL = packed.appendingPathComponent("info.json")
    let json = try String(contentsOf: infoURL, encoding: .utf8)
      .replacingOccurrences(of: "public.aoshuang.game.ngc", with: "com.rileytestut.delta.game.n64")
    try json.write(to: infoURL, atomically: true, encoding: .utf8)
    let archive = scratch.appendingPathComponent("n64.deltaskin")
    try Zip.zipFiles(paths: FileManager.default.contentsOfDirectory(at: packed, includingPropertiesForKeys: nil),
                     zipFilePath: archive, password: nil, progress: nil)

    let library = SkinLibrary(rootURL: scratch.appendingPathComponent("Skins"))
    let installer = SkinStoreInstaller(downloader: FakeDownloader(source: archive), record: record(),
                                       installStep: SkinStoreInstaller.libraryInstallStep(library))
    let n64 = try entry(id: SkinCatalogFixture.n64PackID, systems: ["n64"], url: "https://deltastyles.com/files/skins/551/x.deltaskin")

    await installer.install(n64)

    XCTAssertEqual(installer.state(for: n64), .installed)
    XCTAssertEqual(library.skins.map(\.id), ["com.joemattiello.icube.testcube-gamecube"])
    XCTAssertEqual(library.skins.first?.gameType, .gameCube)
    XCTAssertEqual(record().load(), [SkinCatalogFixture.n64PackID: "com.joemattiello.icube.testcube-gamecube"])
  }
}
#endif
```

- [ ] **Step 2: Run to verify it fails** — `make test TEST_ARGS="-only-testing:iCubeTests/SkinStoreInstallerTests"`. Expected: `cannot find 'SkinStoreInstaller'`.

- [ ] **Step 3: Implement.** `Store/SkinStoreDownloader.swift`:

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// Fetches a skin file to a local path. Abstracted so the installer's state machine can be tested
/// without the network.
protocol SkinStoreDownloading: Sendable {
  /// Downloads `url` to `destination` (overwriting it), reporting progress in 0...1. Throws on
  /// transport failure, a non-2xx status, or cancellation.
  func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// Downloads a skin with `URLSessionDownloadTask`, reporting progress. Delegate-based rather than
/// `URLSession.download(from:delegate:)`: the async variant delivers no `didWriteData`, so no progress.
struct URLSessionSkinStoreDownloader: SkinStoreDownloading {
  /// A non-2xx answer. deltastyles.com serves an HTML page for a dead link, which would otherwise
  /// reach the library as a "not a skin archive".
  struct HTTPStatusError: LocalizedError {
    var statusCode: Int

    var errorDescription: String? { String(format: L("The skin's host answered with HTTP %d."), statusCode) }
  }

  private static let defaultTimeout: TimeInterval = 60

  var timeout: TimeInterval = URLSessionSkinStoreDownloader.defaultTimeout

  func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
    let delegate = SkinStoreDownloadDelegate(destination: destination, progress: progress)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    // The session retains its delegate until invalidated; invalidate once the continuation has resumed.
    defer { session.finishTasksAndInvalidate() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        delegate.start(session.downloadTask(with: url), continuation: continuation)
      }
    } onCancel: {
      delegate.cancel()
    }
  }
}
#endif
```

`Store/SkinStoreDownloadDelegate.swift`:

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// Bridges `URLSessionSkinStoreDownloader`'s delegate callbacks to one continuation. All mutable
/// state sits behind `lock`: URLSession calls in on its own serial delegate queue, and `cancel()` can
/// arrive from any thread.
final class SkinStoreDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let destination: URL
  private let progress: @Sendable (Double) -> Void

  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Error>?
  private var task: URLSessionDownloadTask?
  private var cancelled = false
  /// Set in `didFinishDownloadingTo` when the file cannot be kept.
  private var finishError: Error?

  init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
    self.destination = destination
    self.progress = progress
  }

  func start(_ task: URLSessionDownloadTask, continuation: CheckedContinuation<Void, Error>) {
    let alreadyCancelled = lock.withLock {
      self.continuation = continuation
      self.task = task
      return cancelled
    }
    task.resume()
    // didCompleteWithError(.cancelled) resumes the continuation.
    if alreadyCancelled { task.cancel() }
  }

  func cancel() {
    let task = lock.withLock {
      cancelled = true
      return self.task
    }
    task?.cancel()
  }

  func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64,
                  totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
    guard totalBytesExpectedToWrite > 0 else { return }
    progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
  }

  func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
    // `location` is deleted when this method returns, so the move happens here, synchronously.
    let error: Error?
    if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      error = URLSessionSkinStoreDownloader.HTTPStatusError(statusCode: http.statusCode)
    } else {
      do {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        try fileManager.moveItem(at: location, to: destination)
        error = nil
      } catch let moveError {
        error = moveError
      }
    }
    lock.withLock { finishError = error }
  }

  func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
    let (continuation, finishError, cancelled) = lock.withLock {
      let pending = self.continuation
      self.continuation = nil
      return (pending, self.finishError, self.cancelled)
    }
    guard let continuation else { return }
    if cancelled {
      continuation.resume(throwing: CancellationError())
    } else if let failure = error ?? finishError {
      continuation.resume(throwing: failure)
    } else {
      progress(1)
      continuation.resume()
    }
  }
}
#endif
```

`Store/SkinStoreInstalledRecord.swift`:

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// Which catalog entries the store has installed: `[catalog id: installed skin identifier]`, in a
/// JSON file beside the library's `selection.json`. Keyed by catalog id so a skin the player later
/// deletes can be noticed (`SkinStoreInstaller.reconcileInstalled`) instead of showing "Installed"
/// forever.
struct SkinStoreInstalledRecord {
  let fileURL: URL

  init(fileURL: URL = SkinLibrary.defaultRootURL().appendingPathComponent(SkinLibrary.storeRecordFileName)) {
    self.fileURL = fileURL
  }

  func load() -> [String: String] {
    guard let data = try? Data(contentsOf: fileURL) else { return [:] }
    return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
  }

  func markInstalled(catalogId: String, skinIdentifier: String) {
    var current = load()
    current[catalogId] = skinIdentifier
    save(current)
  }

  func remove(catalogIds: Set<String>) {
    guard !catalogIds.isEmpty else { return }
    var current = load()
    for id in catalogIds { current[id] = nil }
    save(current)
  }

  private func save(_ record: [String: String]) {
    try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let data = try? JSONEncoder().encode(record) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }
}
#endif
```

`Store/SkinStoreInstaller.swift`:

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// Where one catalog entry is in the download → install pipeline.
enum SkinStoreInstallState: Sendable, Equatable {
  case idle
  /// `progress` is 0...1; it stays 0 when the server sends no length.
  case downloading(progress: Double)
  case installing
  case installed
  case failed(message: String)

  var isBusy: Bool {
    switch self {
    case .downloading, .installing: return true
    case .idle, .installed, .failed: return false
    }
  }
}

/// Downloads and installs skins from the store, publishing per-entry state for SwiftUI.
///
/// Per entry: download to `<tmp>/SkinStore-<uuid>/<entry id>.<ext>` → `SkinLibrary.importSkin`
/// (as-is, or rewritten to GameCube for the N64 shelf) → record the catalog id. The library already
/// vets the archive, unzips, validates `info.json` and announces the change, so an unreadable skin
/// fails here with the library's own message. Files are always fetched from the entry's
/// `downloadURL`; iCube never re-hosts them.
@MainActor
final class SkinStoreInstaller: ObservableObject {
  static let shared = SkinStoreInstaller()

  /// Turns a downloaded file into an installed skin. Injected for tests.
  typealias InstallStep = @MainActor (_ file: URL, _ section: SkinStoreSection) throws -> InstalledSkin

  enum InstallError: LocalizedError {
    /// The entry is one the policy hides (a `.zip`, an extensionless link).
    case notInstallable(String)

    var errorDescription: String? {
      switch self {
      case .notInstallable(let name): return String(format: L("%@ isn't a skin iCube can install."), name)
      }
    }
  }

  private static let temporaryFolderPrefix = "SkinStore-"

  /// Transient state for entries touched this session. Read through `state(for:)`, which folds in `installedIds`.
  @Published private(set) var states: [String: SkinStoreInstallState] = [:]
  /// Catalog ids installed from the store (persisted).
  @Published private(set) var installedIds: Set<String>

  private let downloader: any SkinStoreDownloading
  private let record: SkinStoreInstalledRecord
  private let installStep: InstallStep
  private var tasks: [String: Task<Void, Never>] = [:]

  init(downloader: any SkinStoreDownloading = URLSessionSkinStoreDownloader(),
       record: SkinStoreInstalledRecord = SkinStoreInstalledRecord(),
       installStep: @escaping InstallStep = SkinStoreInstaller.libraryInstallStep(.shared)) {
    self.downloader = downloader
    self.record = record
    self.installStep = installStep
    installedIds = Set(record.load().keys)
  }

  /// The default install step: the library's import, rewritten to the shelf's target when it has one.
  static func libraryInstallStep(_ library: SkinLibrary) -> InstallStep {
    { file, section in try library.importSkin(from: file, retargetingTo: section.retarget) }
  }

  // MARK: - State

  func state(for entry: SkinCatalogEntry) -> SkinStoreInstallState {
    if let state = states[entry.id], state != .idle { return state }
    return installedIds.contains(entry.id) ? .installed : .idle
  }

  /// Forgets store installs whose skin is no longer in the library (the player deleted it), so the
  /// store offers it again. Pass every installed skin identifier.
  func reconcileInstalled(with installedSkinIds: Set<String>) {
    let gone = Set(record.load().filter { !installedSkinIds.contains($0.value) }.keys)
    guard !gone.isEmpty else { return }
    record.remove(catalogIds: gone)
    installedIds.subtract(gone)
    for id in gone where states[id] == .installed { states[id] = nil }
    NSLog("[SKINSTORE] %d installed skin(s) no longer present", gone.count)
  }

  // MARK: - Install

  /// Starts installing `entry` in the background. A second call while one is running is ignored.
  func startInstall(_ entry: SkinCatalogEntry) {
    guard tasks[entry.id] == nil else { return }
    tasks[entry.id] = Task { [weak self] in
      await self?.install(entry)
      self?.tasks[entry.id] = nil
    }
  }

  /// Cancels a running install; the entry returns to idle.
  func cancelInstall(_ entry: SkinCatalogEntry) {
    tasks[entry.id]?.cancel()
  }

  /// Downloads and installs `entry`, updating `states` along the way.
  func install(_ entry: SkinCatalogEntry) async {
    if states[entry.id]?.isBusy == true { return }
    guard let section = SkinStorePolicy.section(for: entry), let fileName = SkinStorePolicy.downloadFileName(for: entry) else {
      states[entry.id] = .failed(message: InstallError.notInstallable(entry.name).localizedDescription)
      return
    }

    states[entry.id] = .downloading(progress: 0)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(Self.temporaryFolderPrefix + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent(fileName)

    do {
      let id = entry.id
      try await downloader.download(from: entry.downloadURL, to: file) { [weak self] fraction in
        Task { @MainActor in self?.applyProgress(fraction, for: id) }
      }
      try Task.checkCancellation()

      states[entry.id] = .installing
      let skin = try installStep(file, section)
      record.markInstalled(catalogId: entry.id, skinIdentifier: skin.id)
      installedIds.insert(entry.id)
      states[entry.id] = .installed
      NSLog("[SKINSTORE] Installed '%@' [%@] as %@", entry.name, section.rawValue, skin.id)
    } catch {
      if Self.isCancellation(error) || Task.isCancelled {
        states[entry.id] = .idle
        return
      }
      let message = (error as? SkinImportError).map(SkinImportError.describe) ?? error.localizedDescription
      states[entry.id] = .failed(message: message)
      NSLog("[SKINSTORE] Install of '%@' failed: %@", entry.name, message)
    }
  }

  // MARK: - Private

  /// Progress hops arrive asynchronously and can land after the state moved on; only a still-downloading entry takes them.
  private func applyProgress(_ fraction: Double, for id: String) {
    guard case .downloading = states[id] else { return }
    states[id] = .downloading(progress: fraction)
  }

  private static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    return (error as? URLError)?.code == .cancelled
  }
}
#endif
```

- [ ] **Step 4: Run to verify it passes** — Expected: PASS.
- [ ] **Step 5: Commit** — `git add Source/iOS/App/DolphiniOS/UI/Emulation/Skins/Store/SkinStoreDownloader.swift Source/iOS/App/DolphiniOS/UI/Emulation/Skins/Store/SkinStoreDownloadDelegate.swift Source/iOS/App/DolphiniOS/UI/Emulation/Skins/Store/SkinStoreInstalledRecord.swift Source/iOS/App/DolphiniOS/UI/Emulation/Skins/Store/SkinStoreInstaller.swift Source/iOS/App/DolphiniOSTests/SkinStoreInstallerTests.swift && git commit -m "feat(skins): download and install skins from the catalog"`.

---

### Task 6: Store screen, picker entry point, strings

**Files:**
- Create: `Common/UI/Settings/SwiftUI/SkinStoreViewModel.swift`
- Create: `Common/UI/Settings/SwiftUI/SkinStoreView.swift`
- Modify: `Common/UI/Settings/SwiftUI/SkinPickerView.swift` (toolbar, ~line 82)
- Modify: `Common/UI/Localization/en.lproj/Core.strings`, `Common/UI/Localization/ja.lproj/Core.strings`
- Test: `DolphiniOSTests/SkinStoreViewModelTests.swift`

**Interfaces:**
- Consumes: `SkinCatalogService`, `SkinStorePolicy`, `SkinStoreInstaller`, `SkinLibrary.shared.skins`.
- Produces: `struct SkinStoreShelf: Identifiable { section; entries }`, `enum SkinStoreLoadState: Equatable { loading, loaded, failed(message:) }`, `@MainActor final class SkinStoreViewModel: ObservableObject` with `init(service:installer:library:)`, `@Published shelves`, `loadState`, `isRefreshing`, `offlineMessage`, `func loadIfNeeded() async`, `func refresh() async`, `func reconcileInstalled()`; `struct SkinStoreView: View` (wrap in a `NavigationStack`; `showsDoneButton` for sheets).

- [ ] **Step 1: Write the failing test** — `DolphiniOSTests/SkinStoreViewModelTests.swift`:

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest
@testable import iCube

@MainActor
final class SkinStoreViewModelTests: XCTestCase {
  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SkinStoreViewModelTests-\(UUID().uuidString)", isDirectory: true)

  override func setUpWithError() throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func service(offline: Bool) -> SkinCatalogService {
    SkinCatalogService(catalogURLs: [URL(fileURLWithPath: "/catalog.json")],
                       cacheURL: directory.appendingPathComponent(SkinCatalogService.cacheFileName),
                       fetch: { url in
                         if offline { throw URLError(.notConnectedToInternet) }
                         return (SkinCatalogFixture.data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) ?? URLResponse())
                       })
  }

  private func installer() -> SkinStoreInstaller {
    SkinStoreInstaller(downloader: URLSessionSkinStoreDownloader(),
                       record: SkinStoreInstalledRecord(fileURL: directory.appendingPathComponent("store.json")),
                       installStep: { _, _ in throw SkinImportError.unreadableArchive })
  }

  func testLoadGroupsTheCatalogIntoShelves() async {
    let model = SkinStoreViewModel(service: service(offline: false), installer: installer(), library: SkinLibrary(rootURL: directory.appendingPathComponent("Skins")))
    await model.loadIfNeeded()
    XCTAssertEqual(model.loadState, .loaded)
    XCTAssertEqual(model.shelves.map(\.section), [.gameCube, .wii, .nintendo64])
    XCTAssertEqual(model.shelves.map(\.entries.count), [2, 1, 3])
    XCTAssertNil(model.offlineMessage)
  }

  func testOfflineWithNoCacheFails() async {
    let model = SkinStoreViewModel(service: service(offline: true), installer: installer(), library: SkinLibrary(rootURL: directory.appendingPathComponent("Skins")))
    await model.loadIfNeeded()
    guard case .failed = model.loadState else { return XCTFail("expected failed, got \(model.loadState)") }
    XCTAssertTrue(model.shelves.isEmpty)
  }

  func testOfflineWithACacheShowsTheCacheAndSaysSo() async {
    _ = try? await service(offline: false).catalog()
    let model = SkinStoreViewModel(service: service(offline: true), installer: installer(), library: SkinLibrary(rootURL: directory.appendingPathComponent("Skins")))
    await model.refresh()
    XCTAssertEqual(model.loadState, .loaded)
    XCTAssertEqual(model.shelves.count, 3)
    XCTAssertNotNil(model.offlineMessage)
  }
}
#endif
```

- [ ] **Step 2: Run to verify it fails** — `make test TEST_ARGS="-only-testing:iCubeTests/SkinStoreViewModelTests"`. Expected: `cannot find 'SkinStoreViewModel'`.

- [ ] **Step 3: Implement** `Common/UI/Settings/SwiftUI/SkinStoreViewModel.swift`:

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import Foundation

/// One shelf of the store as shown: the section and its visible entries, in policy order.
struct SkinStoreShelf: Identifiable {
  let section: SkinStoreSection
  let entries: [SkinCatalogEntry]

  var id: SkinStoreSection { section }
}

/// What the store screen can show.
enum SkinStoreLoadState: Equatable {
  /// First load, nothing cached to paint yet.
  case loading
  /// A catalog is on screen (fresh, or a cached copy; see `SkinStoreViewModel.offlineMessage`).
  case loaded
  /// The download failed and there is no cached catalog.
  case failed(message: String)
}

/// Loads the skin catalog for `SkinStoreView` and groups it into shelves. A cached catalog paints
/// first so the screen is never blank while the feed downloads; when the download fails but a cache
/// exists, the cache stays on screen and `offlineMessage` says so.
@MainActor
final class SkinStoreViewModel: ObservableObject {
  @Published private(set) var shelves: [SkinStoreShelf] = []
  @Published private(set) var loadState: SkinStoreLoadState = .loading
  @Published private(set) var isRefreshing = false
  /// Set while a cached catalog stands in for a failed download.
  @Published private(set) var offlineMessage: String?

  let installer: SkinStoreInstaller
  private let service: SkinCatalogService
  private let library: SkinLibrary
  private var hasLoaded = false

  init(service: SkinCatalogService = .shared, installer: SkinStoreInstaller = .shared, library: SkinLibrary = .shared) {
    self.service = service
    self.installer = installer
    self.library = library
  }

  /// First appearance: cache first, then the network if the cache is stale.
  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    hasLoaded = true
    if let cached = await service.cachedCatalog() { apply(cached) }
    await load(forceRefresh: false)
  }

  /// Pull-to-refresh and the Refresh button: always asks the network.
  func refresh() async {
    await load(forceRefresh: true)
  }

  /// Drops "Installed" marks for skins the player has since deleted in the picker.
  func reconcileInstalled() {
    installer.reconcileInstalled(with: Set(library.skins.map(\.id)))
  }

  private func load(forceRefresh: Bool) async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    do {
      let result = try await service.load(forceRefresh: forceRefresh)
      apply(result.catalog)
      offlineMessage = result.networkError
    } catch {
      if loadState == .loaded {
        offlineMessage = error.localizedDescription
      } else {
        loadState = .failed(message: error.localizedDescription)
      }
    }
  }

  private func apply(_ catalog: SkinCatalog) {
    shelves = SkinStorePolicy.sections(for: catalog.skins).map { SkinStoreShelf(section: $0.section, entries: $0.entries) }
    loadState = .loaded
  }
}
#endif
```

`Common/UI/Settings/SwiftUI/SkinStoreView.swift`:

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI

/// Browse and install controller skins from the provenance-emu.com catalog. Shelves follow
/// `SkinStorePolicy`: GameCube, Wii, then N64 layouts rewritten to the GameCube pad. Files download
/// from each author's host; iCube never re-hosts them. Callers wrap it in a `NavigationStack`.
struct SkinStoreView: View {
  /// Adds a Done button for sheet presentation.
  var showsDoneButton = false

  @Environment(\.dismiss) private var dismiss
  @StateObject private var model: SkinStoreViewModel
  @ObservedObject private var installer: SkinStoreInstaller

  private static let submitURL = URL(string: "https://provenance-emu.com/skins/submit.html")
  private static let cardMinimumWidth: CGFloat = 160
  private static let cardMaximumWidth: CGFloat = 240

  init(showsDoneButton: Bool = false, model: SkinStoreViewModel? = nil) {
    self.showsDoneButton = showsDoneButton
    let model = model ?? SkinStoreViewModel()
    _model = StateObject(wrappedValue: model)
    _installer = ObservedObject(wrappedValue: model.installer)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.l.rawValue) {
        intro
        if let offline = model.offlineMessage { offlineBanner(offline) }
        switch model.loadState {
        case .loading:
          loadingView
        case .failed(let message):
          failedView(message)
        case .loaded:
          if model.shelves.isEmpty {
            emptyView
          } else {
            ForEach(model.shelves) { shelf in shelfView(shelf) }
          }
        }
        creditFooter
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(ICubeDesign.Spacing.m.rawValue)
    }
    .navigationTitle(L("Skin Store"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if showsDoneButton {
        ToolbarItem(placement: .cancellationAction) { Button(L("Done")) { dismiss() } }
      }
      ToolbarItem(placement: .primaryAction) {
        if model.isRefreshing {
          ProgressView()
        } else {
          Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
            .accessibilityLabel(L("Refresh"))
        }
      }
    }
    .refreshable { await model.refresh() }
    .task { await model.loadIfNeeded() }
    .onAppear { model.reconcileInstalled() }
    .onReceive(NotificationCenter.default.publisher(for: SkinLibrary.didChangeNotification)) { _ in model.reconcileInstalled() }
  }

  // MARK: - Shelves

  private func shelfView(_ shelf: SkinStoreShelf) -> some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.s.rawValue) {
      HStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
        Text(shelf.section.storeHeader).icubeText(.section)
        Text("\(shelf.entries.count)").icubeText(.tag).foregroundStyle(ICubeDesign.color(.textSecondary))
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isHeader)
      if let note = shelf.section.storeNote {
        Text(note).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
          .fixedSize(horizontal: false, vertical: true)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.cardMinimumWidth, maximum: Self.cardMaximumWidth),
                                   spacing: ICubeDesign.Spacing.s.rawValue, alignment: .top)],
                alignment: .leading, spacing: ICubeDesign.Spacing.s.rawValue) {
        ForEach(shelf.entries) { entry in
          SkinStoreCard(entry: entry, section: shelf.section, state: installer.state(for: entry),
                        onInstall: { installer.startInstall(entry) }, onCancel: { installer.cancelInstall(entry) })
        }
      }
    }
  }

  // MARK: - States

  private var intro: some View {
    Text(L("Controller skins made by the community. Installed skins show up in the skin picker, where you choose one per controller and orientation."))
      .icubeText(.detail)
      .foregroundStyle(ICubeDesign.color(.textSecondary))
      .fixedSize(horizontal: false, vertical: true)
  }

  private var loadingView: some View {
    VStack(spacing: ICubeDesign.Spacing.s.rawValue) {
      ProgressView()
      Text(L("Loading skins")).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, ICubeDesign.Spacing.xl.rawValue)
  }

  private func failedView(_ message: String) -> some View {
    VStack(spacing: ICubeDesign.Spacing.s.rawValue) {
      Image(systemName: "wifi.exclamationmark").font(ICubeDesign.symbolFont(.tilePrimary)).foregroundStyle(ICubeDesign.color(.textSecondary))
      Text(L("Couldn't load the skin store")).icubeText(.body)
      Text(message).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
      Button(L("Try Again")) { Task { await model.refresh() } }
        .buttonStyle(.bordered)
        .disabled(model.isRefreshing)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, ICubeDesign.Spacing.xl.rawValue)
  }

  private func offlineBanner(_ message: String) -> some View {
    HStack(alignment: .top, spacing: ICubeDesign.Spacing.xs.rawValue) {
      Image(systemName: "wifi.slash").foregroundStyle(ICubeDesign.color(.accent))
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
        Text(L("Offline. Showing skins from your last visit.")).icubeText(.detail)
        Text(message).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary)).lineLimit(2)
      }
      Spacer(minLength: 0)
    }
    .padding(ICubeDesign.Spacing.s.rawValue)
    .background(ICubeDesign.color(.rowSurface), in: RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous))
  }

  private var emptyView: some View {
    VStack(spacing: ICubeDesign.Spacing.s.rawValue) {
      Text(L("No GameCube or Wii skins in the catalog yet.")).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
      if let url = Self.submitURL { Link(L("Submit a skin"), destination: url).icubeText(.body) }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, ICubeDesign.Spacing.xl.rawValue)
  }

  private var creditFooter: some View {
    Text(L("Skins are listed by the Provenance skin catalog and download from each author's own site. Each card credits its author and where it's hosted."))
      .icubeText(.detail)
      .foregroundStyle(ICubeDesign.color(.textSecondary))
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// Store-screen copy for each shelf, kept out of the policy so wording can change without touching routing.
private extension SkinStoreSection {
  var storeHeader: String {
    switch self {
    case .gameCube: return L("GameCube")
    case .wii: return L("Wii")
    case .nintendo64: return L("Made for Nintendo 64")
    }
  }

  var storeNote: String? {
    switch self {
    case .gameCube, .wii: return nil
    case .nintendo64:
      return L("Made for the Nintendo 64. iCube puts A, B, Z, L, R, Start, the D-pad and the stick on the GameCube pad and the C buttons on the C-stick, so the art keeps its N64 labels.")
    }
  }

  /// The badge on a card: the console the skin was made for.
  var badge: String {
    switch self {
    case .gameCube: return L("GameCube")
    case .wii: return L("Wii")
    case .nintendo64: return L("N64")
    }
  }
}

/// One skin in the store: thumbnail, name, author, host, the console it was made for, and its install control.
private struct SkinStoreCard: View {
  let entry: SkinCatalogEntry
  let section: SkinStoreSection
  let state: SkinStoreInstallState
  let onInstall: () -> Void
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xs.rawValue) {
      SkinStoreThumbnail(url: entry.thumbnailURL, badge: section.badge)
        .overlay(alignment: .topLeading) {
          Text(section.badge).icubeText(.tag)
            .padding(.horizontal, ICubeDesign.Spacing.xs.rawValue).padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(ICubeDesign.Spacing.xs.rawValue)
        }
      Text(entry.name).icubeText(.body).lineLimit(2).fixedSize(horizontal: false, vertical: true)
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
        if let author = entry.author, !author.isEmpty {
          Text(String(format: L("by %@"), author)).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary)).lineLimit(1)
        }
        if let host = entry.sourceHost {
          Text(host).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textTertiary)).lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      SkinStoreActionView(state: state, onInstall: onInstall, onCancel: onCancel)
    }
    .padding(ICubeDesign.Spacing.s.rawValue)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(ICubeDesign.color(.rowSurface), in: RoundedRectangle(cornerRadius: ICubeDesign.Radius.large.rawValue, style: .continuous))
  }
}

/// Square skin preview for a card. Many feed entries have no thumbnail; those and failed loads get a gamepad glyph.
private struct SkinStoreThumbnail: View {
  let url: URL?
  let badge: String

  var body: some View {
    ZStack {
      if let url {
        AsyncImage(url: url) { phase in
          switch phase {
          case .success(let image): image.resizable().scaledToFit()
          case .failure: placeholder
          case .empty: placeholder.overlay(ProgressView())
          @unknown default: placeholder
          }
        }
      } else {
        placeholder
      }
    }
    .aspectRatio(1, contentMode: .fit)
    .background(ICubeDesign.color(.rowSurface))
    .clipShape(RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous))
    .accessibilityHidden(true)
  }

  private var placeholder: some View {
    VStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
      Image(systemName: "gamecontroller").font(ICubeDesign.symbolFont(.tile))
      Text(badge).icubeText(.tag)
    }
    .foregroundStyle(ICubeDesign.color(.textTertiary))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// The install control at the bottom of a card: Install, download progress with cancel, Installing,
/// Installed, or the failure with Retry.
private struct SkinStoreActionView: View {
  let state: SkinStoreInstallState
  let onInstall: () -> Void
  let onCancel: () -> Void

  private static let minimumHeight: CGFloat = 28

  var body: some View {
    switch state {
    case .idle:
      actionPill(L("Install"), systemImage: "arrow.down.circle.fill", action: onInstall)
    case .downloading(let progress):
      HStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
        // The downloader reports 0 until it knows the length, and stays there when the server never says.
        if progress > 0 {
          ProgressView(value: progress).tint(ICubeDesign.color(.accent))
        } else {
          ProgressView()
          Text(L("Downloading")).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
          Spacer(minLength: 0)
        }
        Button(action: onCancel) {
          Image(systemName: "xmark.circle.fill").foregroundStyle(ICubeDesign.color(.textSecondary))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Cancel Download"))
      }
      .frame(minHeight: Self.minimumHeight)
    case .installing:
      HStack(spacing: ICubeDesign.Spacing.xs.rawValue) {
        ProgressView()
        Text(L("Installing")).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary))
      }
      .frame(minHeight: Self.minimumHeight)
    case .installed:
      Label(L("Installed"), systemImage: "checkmark.circle.fill").icubeText(.detail).foregroundStyle(ICubeDesign.color(.accent))
        .frame(minHeight: Self.minimumHeight)
    case .failed(let message):
      VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
        Text(message).icubeText(.detail).foregroundStyle(ICubeDesign.color(.destructive)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        actionPill(L("Retry"), systemImage: "arrow.clockwise", action: onInstall)
      }
    }
  }

  private func actionPill(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage).icubeText(.detail)
        .padding(.horizontal, ICubeDesign.Spacing.s.rawValue).padding(.vertical, ICubeDesign.Spacing.xxs.rawValue)
        .background(ICubeDesign.color(.selectedFill), in: Capsule())
        .foregroundStyle(ICubeDesign.color(.accent))
    }
    .buttonStyle(.plain)
  }
}
#endif
```

In `SkinPickerView.swift`, add `@State private var showStore = false` beside `showImporter`, change the toolbar to:

```swift
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        HStack {
          Button(L("Browse Catalog…")) { showStore = true }
          Button(L("Import…")) { showImporter = true }
        }
      }
    }
    .sheet(isPresented: $showStore) {
      NavigationStack { SkinStoreView(showsDoneButton: true) }
    }
```

Add identity entries to **both** `Core.strings` files, in the block after `"No skins imported for this controller yet. …"` (keys exactly as used above):

```
"Browse Catalog…" = "Browse Catalog…";
"Skin Store" = "Skin Store";
"Controller skins made by the community. Installed skins show up in the skin picker, where you choose one per controller and orientation." = "Controller skins made by the community. Installed skins show up in the skin picker, where you choose one per controller and orientation.";
"Loading skins" = "Loading skins";
"Couldn't load the skin store" = "Couldn't load the skin store";
"Offline. Showing skins from your last visit." = "Offline. Showing skins from your last visit.";
"No GameCube or Wii skins in the catalog yet." = "No GameCube or Wii skins in the catalog yet.";
"Submit a skin" = "Submit a skin";
"Skins are listed by the Provenance skin catalog and download from each author's own site. Each card credits its author and where it's hosted." = "Skins are listed by the Provenance skin catalog and download from each author's own site. Each card credits its author and where it's hosted.";
"Made for Nintendo 64" = "Made for Nintendo 64";
"Made for the Nintendo 64. iCube puts A, B, Z, L, R, Start, the D-pad and the stick on the GameCube pad and the C buttons on the C-stick, so the art keeps its N64 labels." = "Made for the Nintendo 64. iCube puts A, B, Z, L, R, Start, the D-pad and the stick on the GameCube pad and the C buttons on the C-stick, so the art keeps its N64 labels.";
"N64" = "N64";
"by %@" = "by %@";
"Downloading" = "Downloading";
"Cancel Download" = "Cancel Download";
"Installing" = "Installing";
"Installed" = "Installed";
"Retry" = "Retry";
"%@ isn't a skin iCube can install." = "%@ isn't a skin iCube can install.";
"The skin's host answered with HTTP %d." = "The skin's host answered with HTTP %d.";
"The skin catalog server answered with HTTP %d." = "The skin catalog server answered with HTTP %d.";
"The skin catalog could not be downloaded: %@" = "The skin catalog could not be downloaded: %@";
"The skin catalog could not be read: %@" = "The skin catalog could not be read: %@";
```

(`"GameCube"`, `"Wii"`, `"Done"`, `"Refresh"`, `"Try Again"`, `"Install"` already exist; add any the checker still reports.)

- [ ] **Step 4: Run** — `make test TEST_ARGS="-only-testing:iCubeTests/SkinStoreViewModelTests"` → PASS; `python3 Project/Scripts/check_localized_keys.py --check` → 0 missing; `python3 Project/Scripts/check_design_tokens.py --check` → passes (the two new `Common/` files must report 0; `SkinPickerView.swift` stays at its baseline of 2).
- [ ] **Step 5: Commit** — `git add Source/iOS/App/Common/UI/Settings/SwiftUI/SkinStoreView.swift Source/iOS/App/Common/UI/Settings/SwiftUI/SkinStoreViewModel.swift Source/iOS/App/Common/UI/Settings/SwiftUI/SkinPickerView.swift Source/iOS/App/Common/UI/Localization/en.lproj/Core.strings Source/iOS/App/Common/UI/Localization/ja.lproj/Core.strings Source/iOS/App/DolphiniOSTests/SkinStoreViewModelTests.swift && git commit -m "feat(skins): browse and install skins from the catalog"`.

---

### Task 7: Gate

- [ ] **Step 1: Full skin test run** — `make test TEST_ARGS="-only-testing:iCubeTests/SkinCatalogDecodingTests -only-testing:iCubeTests/SkinCatalogServiceTests -only-testing:iCubeTests/SkinStorePolicyTests -only-testing:iCubeTests/SkinStoreInstallerTests -only-testing:iCubeTests/SkinStoreViewModelTests -only-testing:iCubeTests/SkinLibraryTests -only-testing:iCubeTests/SkinInputMapTests -only-testing:iCubeTests/SkinMountTests -only-testing:iCubeTests/ControllerHubModelBuilderTests"` → all PASS.
- [ ] **Step 2: tvOS compile** — `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination generic/platform=tvOS -derivedDataPath build-Xcode-tvos CODE_SIGNING_ALLOWED=NO` → succeeds (every new file is `#if os(iOS)`).
- [ ] **Step 3: Lint scripts** — `python3 Project/Scripts/check_localized_keys.py --check`, `python3 Project/Scripts/check_design_tokens.py --check`, `python3 Project/Scripts/check_button_types.py` → all pass.
- [ ] **Step 4: Restore tracked slices** — `git checkout -- build/xcframework`; `git status` shows nothing else modified.
- [ ] **Step 5: Owner device pass** (not automatable): open Controllers hub → On-Screen Controls → Skins → Browse Catalog; install GameCube Pocket, the N64 "[CRT GAMEPAD]" skin; pick each for GameCube portrait; boot a GameCube game; every button presses, C buttons move the camera on the N64 skin; delete the N64 skin in the picker and confirm the store offers it again.
