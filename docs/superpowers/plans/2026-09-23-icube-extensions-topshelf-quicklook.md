# iCube Top Shelf + Quick Look Extensions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give iCube a tvOS Top Shelf extension (Continue Playing + Favorites) and iOS/Catalyst Quick Look thumbnail + preview extensions, fed by an App Group snapshot the app writes.

**Architecture:** A new dependency-free SwiftPM package `PVLibrarySnapshot` defines the Codable snapshot, an App Group accessor, a pure-Swift disc-header reader and a lookup that resolves a file URL to a game. The app writes the snapshot JSON into the shared `UserDefaults` suite and mirrors cover JPEGs into the group container on launch, scan, play and favorite events. Three extension targets link only that package plus system frameworks. A `dolphinios://play?id=` route lets Top Shelf tiles boot a game.

**Tech Stack:** Swift 5 (app + extensions), Objective-C++ touch points (`TVGameItem.mm`, `EmulationCoordinator.mm`), Tuist `Project.swift` (source of truth) plus the hand-maintained fallback `DolphiniOS.xcodeproj`, TVServices, QuickLookThumbnailing, QuickLook, XCTest via `swift test`.

**Spec:** `docs/superpowers/specs/2026-09-23-extensions-topshelf-quicklook-design.md` (sections 2.3, 3.1–3.5, 4, 6 steps 1–4)

## Global Constraints

- Deployment floors: iOS 17.0, tvOS 17.0. No availability guards for APIs older than that.
- App group identifier: `group.com.joemattiello.icube` (exactly this string, in the Swift package, the ObjC helper, all entitlements files).
- Cover mirrors: JPEG, quality 0.85, long edge 1280 px, filename `cover_<gameID>.jpg`, directory `<group>/Library/Caches/LibraryMedia/`.
- Snapshot limits: `recentlyPlayed` max 12, `favorites` max 16, schema version 1, UserDefaults key `snapshot.v1`.
- Deep link: scheme `dolphinios`, host `play`, query `id=<6-char game id>`.
- All work in `Source/iOS/` of this repo. Tuist `Project.swift` is the source of truth. `DolphiniOS.xcodeproj` must be updated in Task 12 (release.yml builds it).
- Never commit `build/xcframework/**` changes made by local app builds: run `git checkout -- build/xcframework` before every commit that follows an app build.
- Commits: conventional prefix, subject under 72 chars, end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Use `git -c commit.gpgsign=false commit` if signing hangs.
- Extensions never link `PVlibDolphin.xcframework`, never import UIKit-only APIs on tvOS builds, and never read `UserDefaults.standard`.
- File paths below are relative to `Source/iOS/App/` unless they start with `Source/iOS/` or `docs/`.

---

### Task 1: `PVLibrarySnapshot` package skeleton, App Group accessor, snapshot model

**Files:**
- Create: `Source/iOS/PVLibrarySnapshot/Package.swift`
- Create: `Source/iOS/PVLibrarySnapshot/Sources/PVLibrarySnapshot/LibrarySnapshotAppGroup.swift`
- Create: `Source/iOS/PVLibrarySnapshot/Sources/PVLibrarySnapshot/LibraryPlatform.swift`
- Create: `Source/iOS/PVLibrarySnapshot/Sources/PVLibrarySnapshot/LibrarySnapshotGame.swift`
- Create: `Source/iOS/PVLibrarySnapshot/Sources/PVLibrarySnapshot/LibrarySnapshot.swift`
- Create: `Source/iOS/PVLibrarySnapshot/Sources/PVLibrarySnapshot/LibrarySnapshotStore.swift`
- Test: `Source/iOS/PVLibrarySnapshot/Tests/PVLibrarySnapshotTests/LibrarySnapshotTests.swift`

**Interfaces:**
- Produces: `LibrarySnapshotAppGroup.identifier`, `.isAvailable`, `.containerURL`, `.defaults`, `.mediaDirectory`, `.coverFilename(gameID:)`, `.coverURL(gameID:)`; `LibraryPlatform` enum; `LibrarySnapshotGame` struct with `launchURL` and `coverURL`; `LibrarySnapshot` struct with `build(from:now:)`, `game(id:)`, `game(filename:)`; `LibrarySnapshotStore.load()` / `.save(_:)`; `LibrarySnapshotKeys.snapshot`.

- [ ] **Step 1: Create the package manifest**

```swift
// Source/iOS/PVLibrarySnapshot/Package.swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PVLibrarySnapshot",
    platforms: [.iOS(.v17), .tvOS(.v17), .macOS(.v14), .macCatalyst(.v17), .visionOS(.v1)],
    products: [
        .library(name: "PVLibrarySnapshot", targets: ["PVLibrarySnapshot"])
    ],
    targets: [
        // Foundation only. Linked by the app AND by every extension, so it must never
        // depend on the Dolphin core, UIKit, or anything with a Realm/SwiftData store.
        .target(name: "PVLibrarySnapshot"),
        .testTarget(name: "PVLibrarySnapshotTests", dependencies: ["PVLibrarySnapshot"])
    ]
)
```

- [ ] **Step 2: Write the failing tests**

```swift
// Source/iOS/PVLibrarySnapshot/Tests/PVLibrarySnapshotTests/LibrarySnapshotTests.swift
import XCTest
@testable import PVLibrarySnapshot

final class LibrarySnapshotTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.joemattiello.icube.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func game(_ id: String, title: String, lastPlayed: Date? = nil, favorite: Bool = false) -> LibrarySnapshotGame {
        LibrarySnapshotGame(id: id, title: title, filePath: "/Software/\(title).rvz",
                            platform: .gamecube, gametdbID: id, region: "USA",
                            lastPlayed: lastPlayed, isFavorite: favorite, coverFilename: "cover_\(id).jpg")
    }

    func testAppGroupIdentifierIsFixed() {
        XCTAssertEqual(LibrarySnapshotAppGroup.identifier, "group.com.joemattiello.icube")
        XCTAssertEqual(LibrarySnapshotAppGroup.coverFilename(gameID: "GALE01"), "cover_GALE01.jpg")
    }

    func testLaunchURL() {
        let g = game("GALE01", title: "Melee")
        XCTAssertEqual(g.launchURL?.absoluteString, "dolphinios://play?id=GALE01")
    }

    func testBuildSortsRecentsAndFavorites() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let games = [
            game("AAAA01", title: "Zeta", lastPlayed: now.addingTimeInterval(-100), favorite: true),
            game("BBBB01", title: "Alpha", lastPlayed: now, favorite: true),
            game("CCCC01", title: "Mid", lastPlayed: nil, favorite: false),
        ]
        let snap = LibrarySnapshot.build(from: games, now: now)
        XCTAssertEqual(snap.schemaVersion, LibrarySnapshot.currentSchemaVersion)
        XCTAssertEqual(snap.updatedAt, now)
        XCTAssertEqual(snap.recentlyPlayed.map(\.id), ["BBBB01", "AAAA01"], "unplayed games are excluded, newest first")
        XCTAssertEqual(snap.favorites.map(\.title), ["Alpha", "Zeta"], "favorites alphabetical")
        XCTAssertEqual(snap.byGameID.count, 3)
        XCTAssertEqual(snap.game(id: "CCCC01")?.title, "Mid")
        XCTAssertEqual(snap.game(filename: "Mid.rvz")?.id, "CCCC01")
        XCTAssertNil(snap.game(filename: "Nope.iso"))
    }

    func testBuildCapsLists() {
        let games = (0..<40).map { i in
            game(String(format: "G%05d", i), title: "T\(i)", lastPlayed: Date(timeIntervalSince1970: Double(i)), favorite: true)
        }
        let snap = LibrarySnapshot.build(from: games)
        XCTAssertEqual(snap.recentlyPlayed.count, LibrarySnapshot.maxRecentlyPlayed)
        XCTAssertEqual(snap.favorites.count, LibrarySnapshot.maxFavorites)
    }

    func testStoreRoundTrip() {
        let store = LibrarySnapshotStore(defaults: defaults)
        XCTAssertTrue(store.load().byGameID.isEmpty, "empty suite decodes to the empty snapshot")
        let snap = LibrarySnapshot.build(from: [game("GALE01", title: "Melee", lastPlayed: Date())])
        XCTAssertTrue(store.save(snap))
        let loaded = store.load()
        XCTAssertEqual(loaded.recentlyPlayed.first?.id, "GALE01")
        XCTAssertEqual(loaded.byGameID["GALE01"]?.coverFilename, "cover_GALE01.jpg")
    }

    func testStoreRejectsNewerSchema() {
        var snap = LibrarySnapshot.build(from: [game("GALE01", title: "Melee")])
        snap.schemaVersion = LibrarySnapshot.currentSchemaVersion + 1
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        defaults.set(try! enc.encode(snap), forKey: LibrarySnapshotKeys.snapshot)
        XCTAssertTrue(LibrarySnapshotStore(defaults: defaults).load().byGameID.isEmpty)
    }

    func testStoreWithNilDefaultsIsInert() {
        let store = LibrarySnapshotStore(defaults: nil)
        XCTAssertFalse(store.save(.empty))
        XCTAssertTrue(store.load().byGameID.isEmpty)
    }

    func testGarbageDataDecodesToEmpty() {
        defaults.set(Data("not json".utf8), forKey: LibrarySnapshotKeys.snapshot)
        XCTAssertTrue(LibrarySnapshotStore(defaults: defaults).load().byGameID.isEmpty)
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd Source/iOS/PVLibrarySnapshot && swift test 2>&1 | tail -20`
Expected: compile errors, `cannot find 'LibrarySnapshotGame' in scope` and similar.

- [ ] **Step 4: Implement the model files**

```swift
// Sources/PVLibrarySnapshot/LibrarySnapshotAppGroup.swift
import Foundation

/// The one place the App Group id lives on the Swift side. The ObjC mirror is
/// `DOLAppGroupIdentifier` in `Common/SharedDefaults.m`; keep them identical.
public enum LibrarySnapshotAppGroup {
    public static let identifier = "group.com.joemattiello.icube"

    /// `nil` when the running process is not entitled to the group (unsigned CI
    /// build, wildcard profile, test process). Every caller must tolerate nil.
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public static var isAvailable: Bool { containerURL != nil }

    /// Shared suite, or nil when the group is unavailable. `UserDefaults(suiteName:)`
    /// itself never returns nil for a missing entitlement; it just silently fails to
    /// persist, which is why this is gated on `containerURL`.
    public static var defaults: UserDefaults? {
        guard isAvailable else { return nil }
        return UserDefaults(suiteName: identifier)
    }

    /// tvOS only allows writes under Library/Caches inside a group container, so
    /// every platform uses that subtree for uniformity.
    public static var mediaDirectory: URL? {
        containerURL?.appendingPathComponent("Library/Caches/LibraryMedia", isDirectory: true)
    }

    public static func coverFilename(gameID: String) -> String { "cover_\(gameID).jpg" }

    public static func coverURL(gameID: String) -> URL? {
        mediaDirectory?.appendingPathComponent(coverFilename(gameID: gameID), isDirectory: false)
    }
}
```

```swift
// Sources/PVLibrarySnapshot/LibraryPlatform.swift
import Foundation

/// Mirrors `DiscIO::Platform` (Source/Core/DiscIO/Enums.h) without importing the core.
public enum LibraryPlatform: String, Codable, Sendable, CaseIterable {
    case gamecube, triforce, wii, wiiware, elfdol, unknown

    public init(discIOPlatform raw: Int) {
        switch raw {
        case 0: self = .gamecube
        case 1: self = .triforce
        case 2: self = .wii
        case 3: self = .wiiware
        case 4: self = .elfdol
        default: self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .gamecube: return "GameCube"
        case .triforce: return "Triforce"
        case .wii: return "Wii"
        case .wiiware: return "WiiWare"
        case .elfdol: return "Homebrew"
        case .unknown: return "Unknown"
        }
    }
}
```

```swift
// Sources/PVLibrarySnapshot/LibrarySnapshotGame.swift
import Foundation

public struct LibrarySnapshotGame: Codable, Sendable, Identifiable, Hashable {
    /// 6-character disc game id (e.g. `GALE01`), or the title id hex for WADs.
    public let id: String
    public let title: String
    public let filePath: String
    public let platform: LibraryPlatform
    public let gametdbID: String?
    public let region: String?
    public let lastPlayed: Date?
    public let isFavorite: Bool
    /// Basename inside `LibrarySnapshotAppGroup.mediaDirectory`, nil when the app has no cover.
    public let coverFilename: String?

    public init(id: String, title: String, filePath: String, platform: LibraryPlatform,
                gametdbID: String?, region: String?, lastPlayed: Date?, isFavorite: Bool,
                coverFilename: String?) {
        self.id = id
        self.title = title
        self.filePath = filePath
        self.platform = platform
        self.gametdbID = gametdbID
        self.region = region
        self.lastPlayed = lastPlayed
        self.isFavorite = isFavorite
        self.coverFilename = coverFilename
    }

    public var filename: String { (filePath as NSString).lastPathComponent }

    /// `dolphinios://play?id=<id>`, handled by `URLRouterService` in the app.
    public var launchURL: URL? {
        var components = URLComponents()
        components.scheme = "dolphinios"
        components.host = "play"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url
    }

    public var coverURL: URL? {
        guard let coverFilename else { return nil }
        return LibrarySnapshotAppGroup.mediaDirectory?.appendingPathComponent(coverFilename, isDirectory: false)
    }
}
```

```swift
// Sources/PVLibrarySnapshot/LibrarySnapshot.swift
import Foundation

public enum LibrarySnapshotKeys {
    public static let snapshot = "snapshot.v1"
}

public struct LibrarySnapshot: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maxRecentlyPlayed = 12
    public static let maxFavorites = 16

    public var schemaVersion: Int
    public var updatedAt: Date
    public var recentlyPlayed: [LibrarySnapshotGame]
    public var favorites: [LibrarySnapshotGame]
    /// Every game, keyed by game id. Quick Look uses this; Top Shelf does not.
    public var byGameID: [String: LibrarySnapshotGame]

    public init(schemaVersion: Int = LibrarySnapshot.currentSchemaVersion, updatedAt: Date,
                recentlyPlayed: [LibrarySnapshotGame], favorites: [LibrarySnapshotGame],
                byGameID: [String: LibrarySnapshotGame]) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.recentlyPlayed = recentlyPlayed
        self.favorites = favorites
        self.byGameID = byGameID
    }

    public static let empty = LibrarySnapshot(updatedAt: .distantPast, recentlyPlayed: [], favorites: [], byGameID: [:])

    /// Builds the derived lists. Recents: games with a `lastPlayed`, newest first.
    /// Favorites: alphabetical by title. First occurrence wins on duplicate ids.
    public static func build(from games: [LibrarySnapshotGame], now: Date = Date()) -> LibrarySnapshot {
        var byID: [String: LibrarySnapshotGame] = [:]
        for g in games where byID[g.id] == nil { byID[g.id] = g }
        let unique = Array(byID.values)
        let recents = unique
            .filter { $0.lastPlayed != nil }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(maxRecentlyPlayed)
        let favorites = unique
            .filter(\.isFavorite)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .prefix(maxFavorites)
        return LibrarySnapshot(updatedAt: now, recentlyPlayed: Array(recents),
                               favorites: Array(favorites), byGameID: byID)
    }

    public func game(id: String) -> LibrarySnapshotGame? { byGameID[id] }

    /// Last-path-component match, for containers whose header cannot be parsed.
    public func game(filename: String) -> LibrarySnapshotGame? {
        guard !filename.isEmpty else { return nil }
        return byGameID.values.first { $0.filename == filename }
    }
}
```

```swift
// Sources/PVLibrarySnapshot/LibrarySnapshotStore.swift
import Foundation

/// Reads and writes the snapshot in the shared suite. Nothing here traps or throws:
/// a missing group, a newer schema, or corrupt data all read as `.empty`.
public struct LibrarySnapshotStore {
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = LibrarySnapshotAppGroup.defaults) {
        self.defaults = defaults
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    public func load() -> LibrarySnapshot {
        guard let data = defaults?.data(forKey: LibrarySnapshotKeys.snapshot),
              let snap = try? Self.decoder().decode(LibrarySnapshot.self, from: data),
              snap.schemaVersion <= LibrarySnapshot.currentSchemaVersion else {
            return .empty
        }
        return snap
    }

    /// Returns false when the group is unavailable or encoding failed.
    @discardableResult
    public func save(_ snapshot: LibrarySnapshot) -> Bool {
        guard let defaults, let data = try? Self.encoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: LibrarySnapshotKeys.snapshot)
        return true
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd Source/iOS/PVLibrarySnapshot && swift test 2>&1 | tail -5`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add Source/iOS/PVLibrarySnapshot
git -c commit.gpgsign=false commit -m "feat(snapshot): PVLibrarySnapshot package with app group model + store

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `DiscHeaderReader` (pure-Swift disc header parser)

**Files:**
- Create: `Source/iOS/PVLibrarySnapshot/Sources/PVLibrarySnapshot/DiscHeaderReader.swift`
- Test: `Source/iOS/PVLibrarySnapshot/Tests/PVLibrarySnapshotTests/DiscHeaderReaderTests.swift`

**Interfaces:**
- Produces: `DiscHeader` (gameID, makerCode, discNumber, revision, title, platform, regionCode), `DiscContainer` enum, `DiscHeaderReader.container(of:)`, `DiscHeaderReader.read(url:)`, `DiscHeaderReader.parseDiscHeader(_:)` (internal, tested).

Header layout facts (GameCube/Wii disc header, 0x80 bytes): game id at 0x00 (6 ASCII: 4-char id + 2-char maker), disc number at 0x06, revision at 0x07, Wii magic `0x5D1C9EA3` big-endian at 0x18, GameCube magic `0xC2339F3D` big-endian at 0x1C, title at 0x20 (0x60 bytes, NUL-padded). Container offsets: ISO/GCM/NKit at 0; RVZ/WIA (magic `RVZ\x01` or `WIA\x01`) at 0x58; WBFS (magic `WBFS`) at `1 << byte[0x08]`; CISO (magic `CISO`) at 0x8000 when map byte 0x08 == 1; GCZ (`01 C0 0B B1` little-endian magic 0xB10BC001), TGC (`AE 0F 38 A2`) unsupported in v1.

- [ ] **Step 1: Write the failing tests with synthetic fixtures**

```swift
// Tests/PVLibrarySnapshotTests/DiscHeaderReaderTests.swift
import XCTest
@testable import PVLibrarySnapshot

final class DiscHeaderReaderTests: XCTestCase {
    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: fixtures

    /// A 0x80-byte disc header. `wii` selects the magic word.
    private func discHeader(id: String = "GALE01", disc: UInt8 = 0, rev: UInt8 = 2,
                            title: String = "Super Smash Bros. Melee", wii: Bool = false) -> Data {
        var d = Data(count: 0x80)
        d.replaceSubrange(0..<6, with: Array(id.utf8))
        d[6] = disc
        d[7] = rev
        let magic: UInt32 = wii ? 0x5D1C9EA3 : 0xC2339F3D
        let off = wii ? 0x18 : 0x1C
        d[off] = UInt8(magic >> 24); d[off + 1] = UInt8((magic >> 16) & 0xFF)
        d[off + 2] = UInt8((magic >> 8) & 0xFF); d[off + 3] = UInt8(magic & 0xFF)
        let t = Array(title.utf8.prefix(0x60))
        d.replaceSubrange(0x20..<(0x20 + t.count), with: t)
        return d
    }

    private func write(_ data: Data, _ name: String) -> URL {
        let url = tmp.appendingPathComponent(name)
        try! data.write(to: url)
        return url
    }

    private func padded(_ prefix: Data, to length: Int) -> Data {
        var d = prefix
        if d.count < length { d.append(Data(count: length - d.count)) }
        return d
    }

    // MARK: parseDiscHeader

    func testParsesGameCubeHeader() {
        let h = DiscHeaderReader.parseDiscHeader(discHeader())
        XCTAssertEqual(h?.gameID, "GALE01")
        XCTAssertEqual(h?.makerCode, "01")
        XCTAssertEqual(h?.discNumber, 0)
        XCTAssertEqual(h?.revision, 2)
        XCTAssertEqual(h?.title, "Super Smash Bros. Melee")
        XCTAssertEqual(h?.platform, .gamecube)
        XCTAssertEqual(h?.regionCode, "E")
    }

    func testParsesWiiHeader() {
        let h = DiscHeaderReader.parseDiscHeader(discHeader(id: "RMGP01", title: "SUPER MARIO GALAXY", wii: true))
        XCTAssertEqual(h?.platform, .wii)
        XCTAssertEqual(h?.regionCode, "P")
    }

    func testRejectsHeaderWithoutMagic() {
        var d = discHeader()
        d.replaceSubrange(0x18..<0x20, with: Data(count: 8))
        XCTAssertNil(DiscHeaderReader.parseDiscHeader(d))
    }

    func testRejectsNonAlphanumericGameID() {
        XCTAssertNil(DiscHeaderReader.parseDiscHeader(discHeader(id: "G@LE01")))
    }

    func testRejectsShortBuffer() {
        XCTAssertNil(DiscHeaderReader.parseDiscHeader(discHeader().prefix(0x40)))
    }

    // MARK: container detection

    func testDetectsContainers() {
        XCTAssertEqual(DiscHeaderReader.container(of: Data("RVZ\u{01}".utf8)), .rvz)
        XCTAssertEqual(DiscHeaderReader.container(of: Data("WIA\u{01}".utf8)), .wia)
        XCTAssertEqual(DiscHeaderReader.container(of: Data("WBFS".utf8)), .wbfs)
        XCTAssertEqual(DiscHeaderReader.container(of: Data("CISO".utf8)), .ciso)
        XCTAssertEqual(DiscHeaderReader.container(of: Data([0x01, 0xC0, 0x0B, 0xB1])), .gcz)
        XCTAssertEqual(DiscHeaderReader.container(of: Data([0xAE, 0x0F, 0x38, 0xA2])), .tgc)
        XCTAssertEqual(DiscHeaderReader.container(of: discHeader()), .iso)
        XCTAssertEqual(DiscHeaderReader.container(of: Data([0, 0, 0, 0])), .unknown)
        XCTAssertEqual(DiscHeaderReader.container(of: Data()), .unknown)
    }

    // MARK: read(url:)

    func testReadsRawISO() {
        let url = write(padded(discHeader(), to: 0x10000), "game.iso")
        XCTAssertEqual(DiscHeaderReader.read(url: url)?.gameID, "GALE01")
    }

    func testReadsRVZ() {
        var d = Data("RVZ\u{01}".utf8)
        d.append(Data(count: 0x58 - 4))
        d.append(discHeader(id: "GM4E01", title: "Mario Kart: Double Dash!!"))
        let url = write(padded(d, to: 0x200), "game.rvz")
        let h = DiscHeaderReader.read(url: url)
        XCTAssertEqual(h?.gameID, "GM4E01")
        XCTAssertEqual(h?.title, "Mario Kart: Double Dash!!")
    }

    func testReadsWBFS() {
        var d = Data("WBFS".utf8)
        d.append(Data(count: 4))              // n_hd_sec
        d.append(0x09)                        // hd_sec_sz_s → 512-byte sectors
        d = padded(d, to: 0x200)
        d.append(discHeader(id: "RSBE01", title: "Super Smash Bros. Brawl", wii: true))
        let url = write(padded(d, to: 0x400), "game.wbfs")
        XCTAssertEqual(DiscHeaderReader.read(url: url)?.gameID, "RSBE01")
        XCTAssertEqual(DiscHeaderReader.read(url: url)?.platform, .wii)
    }

    func testReadsCISO() {
        var d = Data("CISO".utf8)
        d.append(contentsOf: [0x00, 0x00, 0x20, 0x00]) // block size (LE), irrelevant here
        d.append(0x01)                                   // block 0 present
        d = padded(d, to: 0x8000)
        d.append(discHeader(id: "GZLE01", title: "Wind Waker"))
        let url = write(padded(d, to: 0x8100), "game.ciso")
        XCTAssertEqual(DiscHeaderReader.read(url: url)?.gameID, "GZLE01")
    }

    func testCISOWithoutBlockZeroIsNil() {
        var d = Data("CISO".utf8)
        d.append(Data(count: 4))
        d.append(0x00)
        let url = write(padded(d, to: 0x8100), "game.ciso")
        XCTAssertNil(DiscHeaderReader.read(url: url))
    }

    func testUnsupportedContainersReturnNil() {
        XCTAssertNil(DiscHeaderReader.read(url: write(padded(Data([0x01, 0xC0, 0x0B, 0xB1]), to: 0x100), "game.gcz")))
        XCTAssertNil(DiscHeaderReader.read(url: write(padded(Data([0xAE, 0x0F, 0x38, 0xA2]), to: 0x100), "game.tgc")))
    }

    func testEmptyAndGarbageFilesReturnNil() {
        XCTAssertNil(DiscHeaderReader.read(url: write(Data(), "empty.iso")))
        XCTAssertNil(DiscHeaderReader.read(url: write(Data((0..<4096).map { UInt8($0 % 251) }), "garbage.iso")))
        XCTAssertNil(DiscHeaderReader.read(url: tmp.appendingPathComponent("missing.iso")))
    }

    func testTruncatedISOReturnsNil() {
        XCTAssertNil(DiscHeaderReader.read(url: write(discHeader().prefix(0x30), "short.iso")))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Source/iOS/PVLibrarySnapshot && swift test --filter DiscHeaderReaderTests 2>&1 | tail -5`
Expected: compile error `cannot find 'DiscHeaderReader' in scope`.

- [ ] **Step 3: Implement the reader**

```swift
// Sources/PVLibrarySnapshot/DiscHeaderReader.swift
import Foundation

public struct DiscHeader: Equatable, Sendable {
    public let gameID: String
    public let makerCode: String
    public let discNumber: Int
    public let revision: Int
    public let title: String
    public let platform: LibraryPlatform

    /// 4th character of the game id: E=USA, P=Europe, J=Japan, K=Korea, ...
    public var regionCode: Character? {
        guard gameID.count >= 4 else { return nil }
        return gameID[gameID.index(gameID.startIndex, offsetBy: 3)]
    }
}

public enum DiscContainer: Equatable, Sendable {
    case iso, rvz, wia, wbfs, ciso, gcz, tgc, unknown
}

/// Reads the 0x80-byte disc header out of the containers iCube supports, without
/// the Dolphin core. Reads at most 64 KiB plus one sector-sized seek. Never throws.
public enum DiscHeaderReader {
    static let wiiMagic: UInt32 = 0x5D1C9EA3
    static let gameCubeMagic: UInt32 = 0xC2339F3D
    static let headerLength = 0x80
    static let titleOffset = 0x20
    static let titleLength = 0x60
    static let rvzHeaderOffset = 0x58
    static let cisoHeaderOffset = 0x8000
    static let initialReadLength = 0x10000

    public static func container(of data: Data) -> DiscContainer {
        guard data.count >= 4 else { return .unknown }
        let b = [UInt8](data.prefix(4))
        switch (b[0], b[1], b[2], b[3]) {
        case (0x52, 0x56, 0x5A, 0x01): return .rvz     // "RVZ\x01"
        case (0x57, 0x49, 0x41, 0x01): return .wia     // "WIA\x01"
        case (0x57, 0x42, 0x46, 0x53): return .wbfs    // "WBFS"
        case (0x43, 0x49, 0x53, 0x4F): return .ciso    // "CISO"
        case (0x01, 0xC0, 0x0B, 0xB1): return .gcz     // 0xB10BC001 LE
        case (0xAE, 0x0F, 0x38, 0xA2): return .tgc
        default:
            return parseDiscHeader(data) != nil ? .iso : .unknown
        }
    }

    public static func read(url: URL) -> DiscHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: initialReadLength), !head.isEmpty else { return nil }

        switch container(of: head) {
        case .iso:
            return parseDiscHeader(head)
        case .rvz, .wia:
            return parseDiscHeader(slice(head, at: rvzHeaderOffset))
        case .wbfs:
            guard head.count > 8 else { return nil }
            let shift = Int(head[8])
            guard (6...20).contains(shift) else { return nil }
            let offset = 1 << shift
            return parseDiscHeader(bytes(handle, head: head, at: offset, count: headerLength))
        case .ciso:
            guard head.count > 8, head[8] == 1 else { return nil }
            return parseDiscHeader(bytes(handle, head: head, at: cisoHeaderOffset, count: headerLength))
        case .gcz, .tgc, .unknown:
            return nil
        }
    }

    /// Parses a buffer whose first 0x80 bytes are a disc header. Requires one of the
    /// two magic words so arbitrary files are not misread as discs.
    static func parseDiscHeader(_ data: Data) -> DiscHeader? {
        guard data.count >= headerLength else { return nil }
        let d = Data(data)   // rebase indices to 0 for slices
        let idBytes = [UInt8](d[0..<6])
        guard idBytes.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) }) else { return nil }
        let platform: LibraryPlatform
        if be32(d, 0x18) == wiiMagic {
            platform = .wii
        } else if be32(d, 0x1C) == gameCubeMagic {
            platform = .gamecube
        } else {
            return nil
        }
        let gameID = String(decoding: idBytes, as: UTF8.self)
        let titleRaw = d[titleOffset..<(titleOffset + titleLength)]
        let titleBytes = titleRaw.prefix { $0 != 0 }.filter { $0 >= 0x20 && $0 <= 0x7E }
        let title = String(decoding: titleBytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return DiscHeader(gameID: gameID,
                          makerCode: String(gameID.suffix(2)),
                          discNumber: Int(d[6]),
                          revision: Int(d[7]),
                          title: title,
                          platform: platform)
    }

    // MARK: - helpers

    private static func be32(_ d: Data, _ off: Int) -> UInt32 {
        guard d.count >= off + 4 else { return 0 }
        return UInt32(d[off]) << 24 | UInt32(d[off + 1]) << 16 | UInt32(d[off + 2]) << 8 | UInt32(d[off + 3])
    }

    private static func slice(_ d: Data, at offset: Int) -> Data {
        guard d.count > offset else { return Data() }
        return Data(d[offset...])
    }

    /// Returns `count` bytes at `offset`, from the already-read head when possible,
    /// otherwise by seeking the handle.
    private static func bytes(_ handle: FileHandle, head: Data, at offset: Int, count: Int) -> Data {
        if head.count >= offset + count {
            return Data(head[offset..<(offset + count)])
        }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = try? handle.read(upToCount: count) else { return Data() }
        return data
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Source/iOS/PVLibrarySnapshot && swift test 2>&1 | tail -5`
Expected: all `DiscHeaderReaderTests` and `LibrarySnapshotTests` pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Source/iOS/PVLibrarySnapshot
git -c commit.gpgsign=false commit -m "feat(snapshot): pure-Swift disc header reader (iso/rvz/wia/wbfs/ciso)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: `LibraryLookup` (file URL → resolved game)

**Files:**
- Create: `Source/iOS/PVLibrarySnapshot/Sources/PVLibrarySnapshot/LibraryLookup.swift`
- Test: `Source/iOS/PVLibrarySnapshot/Tests/PVLibrarySnapshotTests/LibraryLookupTests.swift`

**Interfaces:**
- Consumes: `DiscHeaderReader.read(url:)`, `LibrarySnapshot.game(id:)`, `.game(filename:)`, `LibrarySnapshotStore.load()`.
- Produces: `ResolvedGame` (title, gameID, platform, region, discNumber, makerCode, snapshotGame, coverURL, isFavorite, lastPlayed), `LibraryLookup.realFilename(from:)`, `LibraryLookup.resolve(url:snapshot:header:)` (pure), `LibraryLookup.resolve(url:)`, `LibraryLookup.regionName(for:)`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/PVLibrarySnapshotTests/LibraryLookupTests.swift
import XCTest
@testable import PVLibrarySnapshot

final class LibraryLookupTests: XCTestCase {
    private let melee = LibrarySnapshotGame(id: "GALE01", title: "Super Smash Bros. Melee",
                                            filePath: "/Software/melee.rvz", platform: .gamecube,
                                            gametdbID: "GALE01", region: "USA", lastPlayed: Date(timeIntervalSince1970: 1),
                                            isFavorite: true, coverFilename: "cover_GALE01.jpg")
    private lazy var snapshot = LibrarySnapshot.build(from: [melee])
    private let header = DiscHeader(gameID: "GALE01", makerCode: "01", discNumber: 0, revision: 2,
                                    title: "SUPER SMASH BROS Melee", platform: .gamecube)

    func testRealFilenameStripsICloudPlaceholder() {
        XCTAssertEqual(LibraryLookup.realFilename(from: URL(fileURLWithPath: "/x/.melee.rvz.icloud")), "melee.rvz")
        XCTAssertEqual(LibraryLookup.realFilename(from: URL(fileURLWithPath: "/x/melee.rvz.icloud")), "melee.rvz")
        XCTAssertEqual(LibraryLookup.realFilename(from: URL(fileURLWithPath: "/x/melee.rvz")), "melee.rvz")
        XCTAssertEqual(LibraryLookup.realFilename(from: URL(fileURLWithPath: "/x/.hidden.iso")), ".hidden.iso")
    }

    func testHeaderPlusSnapshotPrefersSnapshotTitle() {
        let r = LibraryLookup.resolve(url: URL(fileURLWithPath: "/x/anything.rvz"), snapshot: snapshot, header: header)
        XCTAssertEqual(r.gameID, "GALE01")
        XCTAssertEqual(r.title, "Super Smash Bros. Melee")
        XCTAssertEqual(r.platform, .gamecube)
        XCTAssertEqual(r.region, "USA")
        XCTAssertTrue(r.isFavorite)
        XCTAssertEqual(r.snapshotGame?.id, "GALE01")
        XCTAssertEqual(r.discNumber, 0)
        XCTAssertEqual(r.makerCode, "01")
    }

    func testHeaderWithoutSnapshotUsesHeaderTitleAndRegionCode() {
        let r = LibraryLookup.resolve(url: URL(fileURLWithPath: "/x/melee.rvz"), snapshot: .empty, header: header)
        XCTAssertEqual(r.title, "SUPER SMASH BROS Melee")
        XCTAssertEqual(r.region, "USA")
        XCTAssertNil(r.snapshotGame)
        XCTAssertFalse(r.isFavorite)
    }

    func testNoHeaderFallsBackToFilenameMatch() {
        let r = LibraryLookup.resolve(url: URL(fileURLWithPath: "/y/melee.rvz"), snapshot: snapshot, header: nil)
        XCTAssertEqual(r.gameID, "GALE01")
        XCTAssertEqual(r.title, "Super Smash Bros. Melee")
    }

    func testNothingKnownDerivesTitleFromFilename() {
        let r = LibraryLookup.resolve(url: URL(fileURLWithPath: "/y/Some_Homebrew-Game.dol"), snapshot: .empty, header: nil)
        XCTAssertNil(r.gameID)
        XCTAssertEqual(r.title, "Some Homebrew Game")
        XCTAssertEqual(r.platform, .unknown)
        XCTAssertNil(r.coverURL)
    }

    func testEmptyHeaderTitleFallsBackToFilename() {
        let blank = DiscHeader(gameID: "GXXE01", makerCode: "01", discNumber: 0, revision: 0, title: "", platform: .gamecube)
        let r = LibraryLookup.resolve(url: URL(fileURLWithPath: "/y/mystery.iso"), snapshot: .empty, header: blank)
        XCTAssertEqual(r.title, "mystery")
    }

    func testRegionNames() {
        XCTAssertEqual(LibraryLookup.regionName(for: "E"), "USA")
        XCTAssertEqual(LibraryLookup.regionName(for: "P"), "Europe")
        XCTAssertEqual(LibraryLookup.regionName(for: "J"), "Japan")
        XCTAssertEqual(LibraryLookup.regionName(for: "K"), "Korea")
        XCTAssertNil(LibraryLookup.regionName(for: nil))
        XCTAssertNil(LibraryLookup.regionName(for: "Z"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Source/iOS/PVLibrarySnapshot && swift test --filter LibraryLookupTests 2>&1 | tail -5`
Expected: compile error `cannot find 'LibraryLookup' in scope`.

- [ ] **Step 3: Implement the lookup**

```swift
// Sources/PVLibrarySnapshot/LibraryLookup.swift
import Foundation

public struct ResolvedGame: Equatable, Sendable {
    public let title: String
    public let gameID: String?
    public let platform: LibraryPlatform
    public let region: String?
    public let discNumber: Int?
    public let makerCode: String?
    public let snapshotGame: LibrarySnapshotGame?
    /// Only set when the mirrored cover file actually exists on disk.
    public let coverURL: URL?

    public var isFavorite: Bool { snapshotGame?.isFavorite ?? false }
    public var lastPlayed: Date? { snapshotGame?.lastPlayed }
}

public enum LibraryLookup {
    /// iCloud evicts files to hidden `.Name.ext.icloud` placeholders; Quick Look hands
    /// us that URL. Recover the real name so the snapshot filename match still works.
    public static func realFilename(from url: URL) -> String {
        var name = url.lastPathComponent
        if name.hasSuffix(".icloud") {
            name = String(name.dropLast(".icloud".count))
            if name.hasPrefix(".") { name = String(name.dropFirst()) }
        }
        return name
    }

    /// Full pipeline: header read (skipped for iCloud placeholders), snapshot load, resolve.
    public static func resolve(url: URL, store: LibrarySnapshotStore = LibrarySnapshotStore()) -> ResolvedGame {
        let header = url.lastPathComponent.hasSuffix(".icloud") ? nil : DiscHeaderReader.read(url: url)
        return resolve(url: url, snapshot: store.load(), header: header)
    }

    /// Pure resolution, in priority order: header id → snapshot by id; no header →
    /// snapshot by filename; nothing → filename-derived title.
    public static func resolve(url: URL, snapshot: LibrarySnapshot, header: DiscHeader?) -> ResolvedGame {
        let filename = realFilename(from: url)
        let fromSnapshot: LibrarySnapshotGame?
        if let header {
            fromSnapshot = snapshot.game(id: header.gameID)
        } else {
            fromSnapshot = snapshot.game(filename: filename)
        }

        let gameID = header?.gameID ?? fromSnapshot?.id
        let platform = fromSnapshot?.platform ?? header?.platform ?? .unknown
        let headerTitle = header?.title.isEmpty == false ? header?.title : nil
        let title = fromSnapshot?.title ?? headerTitle ?? titleFromFilename(filename)
        let region = fromSnapshot?.region ?? regionName(for: header?.regionCode)
        let coverURL = fromSnapshot?.coverURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

        return ResolvedGame(title: title, gameID: gameID, platform: platform, region: region,
                            discNumber: header?.discNumber, makerCode: header?.makerCode,
                            snapshotGame: fromSnapshot, coverURL: coverURL)
    }

    public static func regionName(for code: Character?) -> String? {
        switch code {
        case "E": return "USA"
        case "P", "D", "F", "I", "S", "U", "X", "Y", "Z": return "Europe"
        case "J": return "Japan"
        case "K", "Q", "T": return "Korea"
        case "W": return "Taiwan"
        case "R": return "Russia"
        case "A": return "Region Free"
        default: return nil
        }
    }

    static func titleFromFilename(_ filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        let cleaned = base.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd Source/iOS/PVLibrarySnapshot && swift test 2>&1 | tail -5`
Expected: 0 failures across all three test files.

- [ ] **Step 5: Commit**

```bash
git add Source/iOS/PVLibrarySnapshot
git -c commit.gpgsign=false commit -m "feat(snapshot): LibraryLookup resolves a disc file to title/cover

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: App Group entitlements, extension entitlements, IPA signing, provisioning doc

**Files:**
- Modify: `DolphiniOS/DolphiniOS.entitlements`
- Modify: `DolphiniOS/iCube AppStore.entitlements`
- Modify: `Project/Entitlements/Public.entitlements`
- Modify: `Project/Entitlements/Private.entitlements`
- Create: `Project/Entitlements/Extension.entitlements`
- Create: `Source/iOS/Extensions/Shared/Extension.entitlements` (used by all three extension targets)
- Modify: `Project/Scripts/CreateIpa.sh:19-21`
- Create: `docs/app-group-entitlements.md`

**Interfaces:**
- Produces: the entitlement key `com.apple.security.application-groups = [group.com.joemattiello.icube]` on the app and on every extension, and an IPA script that re-signs `PlugIns/*.appex`.

- [ ] **Step 1: Add the app group to the four app entitlement files**

Insert this key/value pair into the top-level `<dict>` of each of the four files (alphabetical position is not required by codesign, but keep it next to the other `com.apple.security.*` keys):

```xml
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.com.joemattiello.icube</string>
	</array>
```

- [ ] **Step 2: Create the extension entitlements (two identical files)**

`Source/iOS/Extensions/Shared/Extension.entitlements` and `Project/Entitlements/Extension.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.com.joemattiello.icube</string>
	</array>
</dict>
</plist>
```

- [ ] **Step 3: Sign embedded extensions in CreateIpa.sh**

Replace lines 19-21 of `Project/Scripts/CreateIpa.sh` with:

```bash
# Sign inside-out: frameworks, then each embedded extension, then the main executable.
codesign -f -s "$SIGNING_CERTIFICATE" "$BASE_DIR/Payload/iCube.app/Frameworks/"*
EXTENSION_ENTITLEMENTS="$(dirname "$ENTITLEMENTS_PATH")/Extension.entitlements"
if [ -d "$BASE_DIR/Payload/iCube.app/PlugIns" ]; then
  for appex in "$BASE_DIR/Payload/iCube.app/PlugIns/"*.appex; do
    [ -e "$appex" ] || continue
    codesign -f -s "$SIGNING_CERTIFICATE" --entitlements "$EXTENSION_ENTITLEMENTS" "$appex"
  done
fi
codesign -f -s "$SIGNING_CERTIFICATE" --entitlements "$ENTITLEMENTS_PATH" "$BASE_DIR/Payload/iCube.app"
```

- [ ] **Step 4: Verify the plists parse and the script is valid shell**

Run:
```bash
cd Source/iOS/App && for f in DolphiniOS/DolphiniOS.entitlements "DolphiniOS/iCube AppStore.entitlements" Project/Entitlements/*.entitlements ../Extensions/Shared/Extension.entitlements; do plutil -lint "$f"; done && bash -n Project/Scripts/CreateIpa.sh && grep -c "group.com.joemattiello.icube" DolphiniOS/*.entitlements Project/Entitlements/*.entitlements ../Extensions/Shared/Extension.entitlements
```
Expected: every file `OK`, no bash syntax error, and each file reports a count of 1.

- [ ] **Step 5: Write the provisioning doc**

```markdown
<!-- docs/app-group-entitlements.md -->
# App Group `group.com.joemattiello.icube`

The Top Shelf and Quick Look extensions read a snapshot the app writes into this
group. Automatic signing registers the group on first build when Xcode is allowed
to update provisioning (`-allowProvisioningUpdates`, or the Xcode UI). If a build
fails with "Provisioning profile doesn't include the com.apple.security.application-groups
entitlement", do the portal steps once:

1. developer.apple.com → Identifiers → App Groups → (+) → identifier
   `group.com.joemattiello.icube`, description "iCube".
2. Identifiers → App IDs → enable **App Groups** and tick the group on every shipping
   bundle id (see `appConfigs` in `Source/iOS/App/Project.swift`):
   `com.joemattiello.iCube`, `-debug`, `-debug-jb`, `-jb`, `-ts`,
   `-njb-patreon-beta`, `-patreon-beta-jb`, `-ts-patreon-beta`,
   and their extension ids (`<app id>.topshelf`, `<app id>.thumbnail`, `<app id>.preview`).
3. Regenerate any manual profiles. Automatic signing does this itself.

## Trap: wildcard profiles

A "Team Provisioning Profile: *" cannot carry App Groups. A tvOS build signed with
one installs and runs, the extension loads, and every tile shows a title with **no
artwork** because the process is not actually a member of the group. iFly hit this
(`Scripts/release.sh` there passes `-allowProvisioningUpdates` for that reason).
Check with:

    codesign -d --entitlements :- /path/to/iCube.app | grep -A2 application-groups

## Sideload / CI re-sign

`Project/Scripts/CreateIpa.sh` signs `PlugIns/*.appex` with
`Project/Entitlements/Extension.entitlements` before signing the app. AltStore and
SideStore re-sign everything again with the user's own team, which does register
App Groups automatically.
```

- [ ] **Step 6: Commit**

```bash
git add Source/iOS/App/DolphiniOS/*.entitlements "Source/iOS/App/DolphiniOS/iCube AppStore.entitlements" Source/iOS/App/Project/Entitlements Source/iOS/App/Project/Scripts/CreateIpa.sh Source/iOS/Extensions/Shared docs/app-group-entitlements.md
git -c commit.gpgsign=false commit -m "build(entitlements): app group for Top Shelf/Quick Look extensions

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Shared UserDefaults suite, favorites/added-date migration, `LastPlayedStore`

**Files:**
- Create: `Common/SharedDefaults.h`
- Create: `Common/SharedDefaults.m`
- Create: `Common/Swift/SharedDefaults.swift`
- Create: `Common/Swift/LastPlayedStore.swift`
- Modify: `Common/UI/SoftwareList/TVGameItem.mm:214-228` (favorites read/write)
- Modify: `Common/UI/SoftwareList/TVGameItem.h` and `.mm` (add `hasCoverArt`)
- Modify: `Common/Swift/LibraryAddedDateStore.swift:106-112` (load/save)
- Modify: `Common/Emulation/EmulationCoordinator.mm:642` (post path in userInfo)
- Modify: `Common/Swift/BridgingHeader.h` (import `SharedDefaults.h`)
- Test: `Source/iOS/App/iCubeTests/LastPlayedStoreTests.swift` (add to the existing iCubeTests target glob `iCubeTests/**`; check `Project.swift:441-470` for the sources glob and add the file under that directory)

**Interfaces:**
- Produces: ObjC `NSString * const DOLAppGroupIdentifier`, `NSUserDefaults *DOLSharedUserDefaults(void)`; Swift `SharedDefaults.suite: UserDefaults`, `SharedDefaults.migrateIfNeeded()`; `LastPlayedStore.record(gameID:date:)`, `.lastPlayed(gameID:)`, `.all()`; `TVGameItem.hasCoverArt: Bool`; `DOLEmulationWillStartNotification` userInfo `["path": String]`.

- [ ] **Step 1: ObjC helper**

```objc
// Common/SharedDefaults.h
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Mirror of `LibrarySnapshotAppGroup.identifier` in Source/iOS/PVLibrarySnapshot. Keep identical.
FOUNDATION_EXPORT NSString * const DOLAppGroupIdentifier;

/// The App Group suite when this process is entitled to it, else standardUserDefaults.
/// Library state the extensions need (favorites, last played, added dates) lives here.
FOUNDATION_EXPORT NSUserDefaults *DOLSharedUserDefaults(void);

NS_ASSUME_NONNULL_END
```

```objc
// Common/SharedDefaults.m
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
#import "SharedDefaults.h"

NSString * const DOLAppGroupIdentifier = @"group.com.joemattiello.icube";

NSUserDefaults *DOLSharedUserDefaults(void) {
  static NSUserDefaults *shared = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSURL *container = [[NSFileManager defaultManager]
        containerURLForSecurityApplicationGroupIdentifier:DOLAppGroupIdentifier];
    NSUserDefaults *suite = container ? [[NSUserDefaults alloc] initWithSuiteName:DOLAppGroupIdentifier] : nil;
    shared = suite ?: [NSUserDefaults standardUserDefaults];
  });
  return shared;
}
```

Add `#import "SharedDefaults.h"` to `Common/Swift/BridgingHeader.h` next to the other Common imports.

- [ ] **Step 2: Swift side + migration**

```swift
// Common/Swift/SharedDefaults.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import PVLibrarySnapshot

enum SharedDefaults {
  /// Same object the ObjC side returns, so favorites written from TVGameItem.mm and
  /// last-played written here land in one suite.
  static var suite: UserDefaults { DOLSharedUserDefaults() }

  static var isAppGroupBacked: Bool { LibrarySnapshotAppGroup.isAvailable }

  private static let migratedKey = "shared_defaults_migrated_v1"
  static let migratedKeys = ["favorites_by_gameid", "library_added_dates_v1"]

  /// One-time copy of extension-relevant keys from `.standard` into the suite. The
  /// old values are left in place so a downgrade keeps working.
  static func migrateIfNeeded(from source: UserDefaults = .standard, to target: UserDefaults = suite) {
    guard source !== target, !target.bool(forKey: migratedKey) else { return }
    for key in migratedKeys where target.object(forKey: key) == nil {
      if let value = source.object(forKey: key) { target.set(value, forKey: key) }
    }
    target.set(true, forKey: migratedKey)
  }
}
```

```swift
// Common/Swift/LastPlayedStore.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// `[gameID: unix seconds]` in the shared suite. Written from the emulation launch
/// chokepoint (see LibrarySnapshotService), read by the snapshot writer.
enum LastPlayedStore {
  static let key = "last_played_v1"

  static func record(gameID: String, date: Date = Date(), in defaults: UserDefaults = SharedDefaults.suite) {
    guard !gameID.isEmpty else { return }
    var map = load(from: defaults)
    map[gameID] = date.timeIntervalSince1970
    defaults.set(map, forKey: key)
  }

  static func lastPlayed(gameID: String, in defaults: UserDefaults = SharedDefaults.suite) -> Date? {
    load(from: defaults)[gameID].map { Date(timeIntervalSince1970: $0) }
  }

  static func all(in defaults: UserDefaults = SharedDefaults.suite) -> [String: Date] {
    load(from: defaults).mapValues { Date(timeIntervalSince1970: $0) }
  }

  private static func load(from defaults: UserDefaults) -> [String: TimeInterval] {
    defaults.dictionary(forKey: key) as? [String: TimeInterval] ?? [:]
  }
}
```

- [ ] **Step 3: Unit tests (iCubeTests target)**

```swift
// Source/iOS/App/iCubeTests/LastPlayedStoreTests.swift
import XCTest
@testable import iCube

final class LastPlayedStoreTests: XCTestCase {
  private var suite: String!
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suite = "icube.tests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    super.tearDown()
  }

  func testRecordAndRead() {
    let d = Date(timeIntervalSince1970: 1_700_000_000)
    LastPlayedStore.record(gameID: "GALE01", date: d, in: defaults)
    XCTAssertEqual(LastPlayedStore.lastPlayed(gameID: "GALE01", in: defaults), d)
    XCTAssertNil(LastPlayedStore.lastPlayed(gameID: "NOPE00", in: defaults))
    XCTAssertEqual(LastPlayedStore.all(in: defaults).count, 1)
  }

  func testEmptyGameIDIgnored() {
    LastPlayedStore.record(gameID: "", in: defaults)
    XCTAssertTrue(LastPlayedStore.all(in: defaults).isEmpty)
  }

  func testMigrationCopiesOnceAndDoesNotOverwrite() {
    let source = UserDefaults(suiteName: suite + ".src")!
    defer { source.removePersistentDomain(forName: suite + ".src") }
    source.set(["GALE01": true], forKey: "favorites_by_gameid")
    SharedDefaults.migrateIfNeeded(from: source, to: defaults)
    XCTAssertEqual(defaults.dictionary(forKey: "favorites_by_gameid") as? [String: Bool], ["GALE01": true])
    source.set(["OTHER1": true], forKey: "favorites_by_gameid")
    SharedDefaults.migrateIfNeeded(from: source, to: defaults)
    XCTAssertEqual(defaults.dictionary(forKey: "favorites_by_gameid") as? [String: Bool], ["GALE01": true], "second run is a no-op")
  }
}
```

- [ ] **Step 4: Switch favorites and added dates to the suite**

In `Common/UI/SoftwareList/TVGameItem.mm`, add `#import "SharedDefaults.h"` and replace both `[NSUserDefaults standardUserDefaults]` calls at lines 216 and 222 with `DOLSharedUserDefaults()`.

In `Common/Swift/LibraryAddedDateStore.swift` replace the two `UserDefaults.standard` uses in `load()` / `save(_:)` with `SharedDefaults.suite`.

Add `hasCoverArt` to `TVGameItem`:

```objc
// TVGameItem.h, after coverImage
/// YES when the core has real cover art for this game (custom or GameTDB), NO when
/// `coverImage` is the NoCover placeholder. The snapshot writer only mirrors real art.
@property (nonatomic, readonly) BOOL hasCoverArt;
```

```objc
// TVGameItem.mm: add ivar `BOOL _hasCoverArt;`, set it right after the cover is fetched
// (line 71 area): `_hasCoverArt = !cover.buffer.empty();`
// In the DEBUG demo initializer set `_hasCoverArt = YES;` (its cover is procedural but real).
// Accessor next to the others: `- (BOOL)hasCoverArt { return _hasCoverArt; }`
```

- [ ] **Step 5: Carry the game path on the launch notification**

`Common/Emulation/EmulationCoordinator.mm:642` becomes:

```objc
  NSDictionary* willStartInfo = bootParameter.path ? @{ @"path": bootParameter.path } : nil;
  [[NSNotificationCenter defaultCenter] postNotificationName:DOLEmulationWillStartNotification object:self userInfo:willStartInfo];
```

- [ ] **Step 6: Add the package to Tuist and build**

In `Project.swift`: add `.local(path: "../PVLibrarySnapshot")` to `packages:` (next to `../PVSyncRules`) and `.package(product: "PVLibrarySnapshot")` to the `iCube` target `dependencies` (next to `.package(product: "PVSyncRules")`).

Run:
```bash
cd Source/iOS/App && tuist generate --no-open && xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination "generic/platform=iOS" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. Then the tests:
```bash
xcodebuild test -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination "platform=iOS Simulator,name=iPhone 16" -only-testing:iCubeTests/LastPlayedStoreTests 2>&1 | grep -E "Test Suite|passed|failed" | tail -5
```
Expected: `LastPlayedStoreTests` passed. (If the simulator build of the core is not present, run the tests in Task 12's device pass instead and note it.)

- [ ] **Step 7: Commit**

```bash
cd ../../.. && git checkout -- build/xcframework
git add Source/iOS/App/Common/SharedDefaults.h Source/iOS/App/Common/SharedDefaults.m Source/iOS/App/Common/Swift/SharedDefaults.swift Source/iOS/App/Common/Swift/LastPlayedStore.swift Source/iOS/App/Common/Swift/LibraryAddedDateStore.swift Source/iOS/App/Common/Swift/BridgingHeader.h Source/iOS/App/Common/UI/SoftwareList/TVGameItem.h Source/iOS/App/Common/UI/SoftwareList/TVGameItem.mm Source/iOS/App/Common/Emulation/EmulationCoordinator.mm Source/iOS/App/Project.swift Source/iOS/App/iCubeTests/LastPlayedStoreTests.swift
git -c commit.gpgsign=false commit -m "feat(library): shared defaults suite, last-played store, launch path

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `LibrarySnapshotWriter`, `CoverMirror`, `LibrarySnapshotService`

**Files:**
- Create: `Common/Swift/Snapshot/CoverMirror.swift`
- Create: `Common/Swift/Snapshot/LibrarySnapshotWriter.swift`
- Create: `Common/Services/LibrarySnapshotService.swift`
- Modify: `Common/Services/ServiceManager.swift:14-45` (register the service in both lists)
- Modify: `Common/Services/GameFileCacheService.swift:9` (write after the initial scan)

**Interfaces:**
- Consumes: `TVLibraryBridge.currentGames()`, `TVGameItem.hasCoverArt`, `LastPlayedStore.all()`, `LibrarySnapshot.build(from:)`, `LibrarySnapshotStore.save`, `LibrarySnapshotAppGroup.mediaDirectory`, `SharedDefaults.migrateIfNeeded()`.
- Produces: `LibrarySnapshotWriter.writeNow()` (MainActor), `LibrarySnapshotService.requestWrite()` (debounced, static), notification-driven refresh.

- [ ] **Step 1: CoverMirror**

```swift
// Common/Swift/Snapshot/CoverMirror.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import UIKit
import PVLibrarySnapshot

struct CoverJob: @unchecked Sendable {
  let gameID: String
  let image: UIImage
}

/// Writes 1280 px JPEG mirrors of cover art into the App Group so extensions can read
/// them. tvOS `.poster` @2x is 808×1216; anything smaller renders blank tiles.
enum CoverMirror {
  static let maxEdge: CGFloat = 1280
  static let jpegQuality: CGFloat = 0.85
  private static var loggedUnavailable = false

  /// Skips files that already exist. Safe to call from any queue.
  static func mirror(_ jobs: [CoverJob]) {
    guard let dir = LibrarySnapshotAppGroup.mediaDirectory else {
      if !loggedUnavailable {
        loggedUnavailable = true
        NSLog("[Snapshot] App Group container unavailable; cover mirroring skipped")
      }
      return
    }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for job in jobs {
      let url = dir.appendingPathComponent(LibrarySnapshotAppGroup.coverFilename(gameID: job.gameID))
      if FileManager.default.fileExists(atPath: url.path) { continue }
      guard let data = jpegData(job.image) else { continue }
      try? data.write(to: url, options: .atomic)
    }
  }

  static func jpegData(_ image: UIImage) -> Data? {
    let size = image.size
    let scale = min(1, maxEdge / max(size.width * image.scale, size.height * image.scale))
    let target = CGSize(width: (size.width * image.scale * scale).rounded(),
                        height: (size.height * image.scale * scale).rounded())
    guard target.width > 0, target.height > 0 else { return nil }
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = true
    let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
    return rendered.jpegData(compressionQuality: jpegQuality)
  }
}
```

- [ ] **Step 2: Writer**

```swift
// Common/Swift/Snapshot/LibrarySnapshotWriter.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import PVLibrarySnapshot
#if os(tvOS)
import TVServices
#endif

/// Projects the core's game list into the App Group snapshot. Collects on the main
/// actor (TVGameItem is main-thread), encodes and mirrors on a utility task.
@MainActor
enum LibrarySnapshotWriter {
  static func writeNow() {
    let items = TVLibraryBridge.currentGames().filter { !$0.isDemoItem }
    let lastPlayed = LastPlayedStore.all()
    var games: [LibrarySnapshotGame] = []
    var jobs: [CoverJob] = []
    games.reserveCapacity(items.count)

    for item in items {
      let gameID = item.gameID
      guard !gameID.isEmpty else { continue }
      let hasCover = item.hasCoverArt
      games.append(LibrarySnapshotGame(
        id: gameID,
        title: item.title,
        filePath: item.filePath,
        platform: LibraryPlatform(discIOPlatform: item.platform),
        gametdbID: item.gametdbID.isEmpty ? nil : item.gametdbID,
        region: item.countryName.isEmpty ? nil : item.countryName,
        lastPlayed: lastPlayed[gameID],
        isFavorite: item.isFavorite,
        coverFilename: hasCover ? LibrarySnapshotAppGroup.coverFilename(gameID: gameID) : nil))
      if hasCover { jobs.append(CoverJob(gameID: gameID, image: item.coverImage)) }
    }

    Task.detached(priority: .utility) {
      CoverMirror.mirror(jobs)
      let snapshot = LibrarySnapshot.build(from: games)
      let saved = LibrarySnapshotStore().save(snapshot)
      NSLog("[Snapshot] wrote %d games (%d recent, %d favorites) saved=%d",
            snapshot.byGameID.count, snapshot.recentlyPlayed.count, snapshot.favorites.count, saved ? 1 : 0)
      #if os(tvOS)
      if saved { TVTopShelfContentProvider.topShelfContentDidChange() }
      #endif
    }
  }
}
```

- [ ] **Step 3: Service with triggers and debounce**

```swift
// Common/Services/LibrarySnapshotService.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import UIKit

/// Owns when the App Group snapshot is rewritten: launch, foreground, library
/// changes, favorites, and every game boot (which also stamps last-played).
final class LibrarySnapshotService: UIResponder, UIApplicationDelegate {
  private static let debounce: TimeInterval = 2
  private static var pending: DispatchWorkItem?

  /// Coalesces bursts (a rescan posts many metadata updates) into one write.
  static func requestWrite(after delay: TimeInterval = debounce) {
    pending?.cancel()
    let work = DispatchWorkItem { LibrarySnapshotWriter.writeNow() }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    SharedDefaults.migrateIfNeeded()
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(emulationWillStart(_:)), name: NSNotification.Name("DOLEmulationWillStartNotification"), object: nil)
    for name in ["FavoritesChanged", "RemoteLibraryUpdated", "GameFileMetadataUpdated"] {
      nc.addObserver(self, selector: #selector(libraryChanged), name: NSNotification.Name(name), object: nil)
    }
    return true
  }

  func applicationDidBecomeActive(_ application: UIApplication) {
    Self.requestWrite(after: 3)
  }

  @objc private func libraryChanged() {
    Self.requestWrite()
  }

  @MainActor
  @objc private func emulationWillStart(_ note: Notification) {
    if let path = note.userInfo?["path"] as? String,
       let item = TVLibraryBridge.currentGames().first(where: { $0.filePath == path }) {
      LastPlayedStore.record(gameID: item.gameID)
    }
    Self.requestWrite(after: 0.5)
  }
}
```

Register it in `ServiceManager.swift` in **both** `services` arrays, immediately after `GameFileCacheService(),`:

```swift
    LibrarySnapshotService(),
```

In `GameFileCacheService.swift` change the launch rescan to request a write when the scan finishes:

```swift
    GameFileCacheManager.shared().rescanLocalAndFetchMetadata {
      DispatchQueue.main.async { LibrarySnapshotService.requestWrite(after: 0) }
    }
```

- [ ] **Step 4: Build both platforms**

Run:
```bash
cd Source/iOS/App && tuist generate --no-open && for p in iOS tvOS; do xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination "generic/platform=$p" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -2; done
```
Expected: `** BUILD SUCCEEDED **` twice.

- [ ] **Step 5: Commit**

```bash
cd ../../.. && git checkout -- build/xcframework
git add Source/iOS/App/Common/Swift/Snapshot Source/iOS/App/Common/Services/LibrarySnapshotService.swift Source/iOS/App/Common/Services/ServiceManager.swift Source/iOS/App/Common/Services/GameFileCacheService.swift
git -c commit.gpgsign=false commit -m "feat(library): write App Group snapshot + cover mirrors on library events

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: `dolphinios://play?id=` route and scene URL delivery

**Files:**
- Create: `Common/Swift/GameLaunchRequest.swift`
- Modify: `Common/Services/URLRouterService.swift:7-13`
- Modify: `Common/MainDisplaySceneDelegate.swift:15-50` (add `openURLContexts` + cold-launch URL)

**Interfaces:**
- Consumes: `TVEmulationBridge.isRunning()`, `.stop()`, notification `DOLLaunchGameByGameID` (handled by `TVLibraryView.spotlightLaunchByGameID`, which itself retries 10× for library hydration), `DOLEmulationRequestExitToLibrary`, `ServiceManager.shared.open(url:options:)`.
- Produces: `GameLaunchRequest.launch(gameID:)`.

Background: the app uses a `UIWindowSceneDelegate`, so `application(_:open:options:)` is never invoked by UIKit. Today no `scene(_:openURLContexts:)` exists, which means the DSU deep link is also dead. This task fixes delivery for both.

- [ ] **Step 1: Launch helper**

```swift
// Common/Swift/GameLaunchRequest.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Boots a game by id from outside the library UI (Top Shelf, URL). If a game is
/// running it is stopped first; the library remounts and its
/// `DOLLaunchGameByGameID` observer performs the actual boot.
@MainActor
enum GameLaunchRequest {
  private static let pollInterval: TimeInterval = 0.25
  private static let stopTimeout: TimeInterval = 10
  private static let remountDelay: TimeInterval = 0.5

  static func launch(gameID: String) {
    guard !gameID.isEmpty else { return }
    if TVEmulationBridge.isRunning() {
      TVEmulationBridge.stop()
      NotificationCenter.default.post(name: Notification.Name("DOLEmulationRequestExitToLibrary"), object: nil)
      waitForStop(deadline: Date().addingTimeInterval(stopTimeout)) { post(gameID) }
    } else {
      post(gameID)
    }
  }

  private static func waitForStop(deadline: Date, then completion: @escaping () -> Void) {
    if !TVEmulationBridge.isRunning() {
      DispatchQueue.main.asyncAfter(deadline: .now() + remountDelay, execute: completion)
      return
    }
    guard Date() < deadline else {
      NSLog("[Launch] core did not stop within %.0fs; giving up on %@", stopTimeout, "play link")
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval) { waitForStop(deadline: deadline, then: completion) }
  }

  private static func post(_ gameID: String) {
    NotificationCenter.default.post(name: NSNotification.Name("DOLLaunchGameByGameID"), object: nil, userInfo: ["gameID": gameID])
  }
}
```

- [ ] **Step 2: Route it**

In `URLRouterService.swift` replace the body of `application(_:open:options:)` with:

```swift
    // Supported:
    // dolphinios://play?id=GALE01                       (Top Shelf / external launch)
    // dolphinios://dsu/add?ip=192.168.1.23&port=26760&desc=My%20iPhone
    // Also accept legacy: dsu://192.168.1.23:26760
    if handlePlayLink(url) { return true }
    if handleDSULink(url) { return true }
    return false
```

and add the method:

```swift
  private func handlePlayLink(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "dolphinios", url.host?.lowercased() == "play" else { return false }
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard let id = items.first(where: { $0.name.lowercased() == "id" })?.value, !id.isEmpty else { return false }
    Task { @MainActor in GameLaunchRequest.launch(gameID: id) }
    return true
  }
```

- [ ] **Step 3: Deliver URLs through the scene delegate**

In `MainDisplaySceneDelegate.swift`, inside `scene(_:willConnectTo:options:)` after `window.makeKeyAndVisible()` and before the `#if !os(tvOS)` shortcut block, add:

```swift
      // Cold launch from a URL (Top Shelf tile, dolphinios:// link). Give the library
      // view time to mount its DOLLaunchGameByGameID observer, same delay as shortcuts.
      if let context = connectionOptions.urlContexts.first {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
          _ = ServiceManager.shared.open(url: context.url, options: [:])
        }
      }
```

and add the warm-launch entry point as a new method on the class:

```swift
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    for context in URLContexts {
      _ = ServiceManager.shared.open(url: context.url, options: [:])
    }
  }
```

- [ ] **Step 4: Build and verify on the simulator**

Run:
```bash
cd Source/iOS/App && xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination "generic/platform=tvOS" CODE_SIGNING_ALLOWED=NO 2>&1 | tail -2
```
Expected: `** BUILD SUCCEEDED **`. Device verification of the link itself happens in Task 12 (`xcrun devicectl device process launch --device <udid> --payload-url "dolphinios://play?id=<id>" com.joemattiello.iCube-debug`, or `xcrun simctl openurl booted "dolphinios://play?id=<id>"` on a tvOS simulator with a game imported).

- [ ] **Step 5: Commit**

```bash
cd ../../.. && git checkout -- build/xcframework
git add Source/iOS/App/Common/Swift/GameLaunchRequest.swift Source/iOS/App/Common/Services/URLRouterService.swift Source/iOS/App/Common/MainDisplaySceneDelegate.swift
git -c commit.gpgsign=false commit -m "feat(deeplink): dolphinios://play route; deliver URLs via the scene delegate

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Tuist extension scaffolding + Top Shelf target

**Files:**
- Modify: `Project.swift` (config table refactor, `extensionTarget(...)` helper, `iCubeTopShelf` target, app dependency, `targets:` list)
- Create: `Source/iOS/Extensions/iCubeTopShelf/TopShelfContentProvider.swift`
- Create: `Source/iOS/Extensions/iCubeTopShelf/PrivacyInfo.xcprivacy`
- Create: `Source/iOS/Extensions/iCubeTopShelf/Info.plist`

**Interfaces:**
- Consumes: `LibrarySnapshotStore.load()`, `LibrarySnapshotGame.launchURL`, `.coverURL`.
- Produces: Tuist helper `extensionTarget(name:suffix:destinations:deploymentTargets:infoPlist:sources:resources:deviceFamily:)` reused by Task 9 and Task 10; app extension `iCubeTopShelf` embedded on tvOS only.

- [ ] **Step 1: Refactor the config table in Project.swift**

Replace the `appConfigs` literal (lines 57-68) with a table plus derived arrays:

```swift
struct AppConfig {
    let name: String
    let debug: Bool
    let bundleId: String
    let entitlements: String
}

let configTable: [AppConfig] = [
    AppConfig(name: "Debug (Non-Jailbroken)",         debug: true,  bundleId: "com.joemattiello.iCube-debug",            entitlements: dfEnt),
    AppConfig(name: "Debug (Jailbroken)",             debug: true,  bundleId: "com.joemattiello.iCube-debug-jb",         entitlements: dfEnt),
    AppConfig(name: "Debug (AppStore)",               debug: true,  bundleId: "com.joemattiello.iCube",                  entitlements: appStoreEnt),
    AppConfig(name: "Release (Non-Jailbroken)",       debug: false, bundleId: "com.joemattiello.iCube",                  entitlements: dfEnt),
    AppConfig(name: "Release (Beta, Non-Jailbroken)", debug: false, bundleId: "com.joemattiello.iCube-njb-patreon-beta", entitlements: dfEnt),
    AppConfig(name: "Release (Jailbroken)",           debug: false, bundleId: "com.joemattiello.iCube-jb",               entitlements: dfEnt),
    AppConfig(name: "Release (TrollStore)",           debug: false, bundleId: "com.joemattiello.iCube-ts",               entitlements: dfEnt),
    AppConfig(name: "Release (AppStore)",             debug: false, bundleId: "com.joemattiello.iCube",                  entitlements: appStoreEnt),
    AppConfig(name: "Release (Beta, Jailbroken)",     debug: false, bundleId: "com.joemattiello.iCube-patreon-beta-jb",  entitlements: dfEnt),
    AppConfig(name: "Release (Beta, TrollStore)",     debug: false, bundleId: "com.joemattiello.iCube-ts-patreon-beta",  entitlements: dfEnt),
]

let appConfigs: [Configuration] = configTable.map {
    appCfg($0.name, debug: $0.debug, bundleId: $0.bundleId, entitlements: $0.entitlements)
}

/// Extension bundle ids are `<app id>.<suffix>` so each of the 8 app ids gets its own
/// extension id (App Store validation requires the prefix match).
func extensionConfigs(suffix: String) -> [Configuration] {
    configTable.map { cfg in
        let settings: SettingsDictionary = ["PRODUCT_BUNDLE_IDENTIFIER": .string("\(cfg.bundleId).\(suffix)")]
        return cfg.debug
            ? .debug(name: .configuration(cfg.name), settings: settings)
            : .release(name: .configuration(cfg.name), settings: settings)
    }
}
```

- [ ] **Step 2: Add the extension target helper (after the `iCubeTests` target definition)**

```swift
// MARK: - App extensions (Top Shelf, Quick Look)
//
// Tuist 4.x rejects a tvOS-only extension dependency on a multiplatform app, so the
// Top Shelf target is declared for iOS+tvOS and only EMBEDDED on tvOS via `.when`.
// All three extensions link PVLibrarySnapshot and system frameworks only. They must
// never inherit the app's bridging header or the Dolphin core.
let extensionEntitlements: Path = "../Extensions/Shared/Extension.entitlements"

func extensionTarget(
    name: String,
    suffix: String,
    destinations: Destinations,
    deploymentTargets: DeploymentTargets,
    infoPlist: InfoPlist,
    sources: SourceFilesList,
    resources: ResourceFileElements? = nil,
    deviceFamily: String,
    frameworks: [String]
) -> Target {
    Target.target(
        name: name,
        destinations: destinations,
        product: .appExtension,
        bundleId: "com.joemattiello.iCube.\(suffix)", // placeholder; real per-config ids in extensionConfigs
        deploymentTargets: deploymentTargets,
        infoPlist: infoPlist,
        sources: sources,
        resources: resources,
        entitlements: .file(path: extensionEntitlements),
        dependencies: [.package(product: "PVLibrarySnapshot")] + frameworks.map { .sdk(name: $0, type: .framework) },
        settings: .settings(
            base: [
                "SKIP_INSTALL": "YES",
                "SWIFT_VERSION": "5.0",
                "SWIFT_OBJC_BRIDGING_HEADER": "",
                "SWIFT_OBJC_INTEROP_MODE": "objc",
                "CODE_SIGN_STYLE": "Automatic",
                "DEVELOPMENT_TEAM": "S32Z3HMYVQ",
                "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
                "TARGETED_DEVICE_FAMILY": .string(deviceFamily),
                "LD_RUNPATH_SEARCH_PATHS": ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"],
                "MARKETING_VERSION": "1.0.0",
                "CURRENT_PROJECT_VERSION": "13",
            ],
            configurations: extensionConfigs(suffix: suffix)
        )
    )
}

let topShelf = extensionTarget(
    name: "iCubeTopShelf",
    suffix: "topshelf",
    destinations: [.iPhone, .iPad, .appleTv],
    deploymentTargets: .multiplatform(iOS: "17.0", tvOS: "17.0"),
    infoPlist: .file(path: "../Extensions/iCubeTopShelf/Info.plist"),
    sources: ["../Extensions/iCubeTopShelf/**/*.swift"],
    resources: ["../Extensions/iCubeTopShelf/PrivacyInfo.xcprivacy"],
    deviceFamily: "1,2,3",
    // TVServices does not exist on the iOS slice; the source imports it under
    // `#if os(tvOS)` and Xcode auto-links Swift-imported frameworks, so link nothing here.
    frameworks: []
)
```

The checked-in plist (shared with the fallback project in Task 12):

```xml
<!-- Source/iOS/Extensions/iCubeTopShelf/Info.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>iCube Top Shelf</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.tv-top-shelf</string>
		<key>NSExtensionPrincipalClass</key>
		<string>$(PRODUCT_MODULE_NAME).TopShelfContentProvider</string>
	</dict>
</dict>
</plist>
```

Tuist merges `.file` plists with `GENERATE_INFOPLIST_FILE`, so bundle id, version and executable keys still come from build settings.

Then in the `iCube` target's `dependencies:` array, replace the `APP_EMBEDS_APPEX` tail with:

```swift
    ] + (APP_EMBEDS_APPEX ? [.target(name: "LiveActivityExtension")] : [])
      + [.target(name: "iCubeTopShelf", condition: .when([.tvos]))],
```

and change the project's `targets:` to `[iCube, liveActivity, iCubeTests, topShelf]`.

- [ ] **Step 3: Provider source**

```swift
// Source/iOS/Extensions/iCubeTopShelf/TopShelfContentProvider.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
//
// tvOS Top Shelf rows for iCube. Reads the App Group snapshot written by the app's
// LibrarySnapshotWriter; links nothing but PVLibrarySnapshot + TVServices.
// The target is declared iOS+tvOS for Tuist's sake and embedded on tvOS only, so
// the iOS slice compiles to an empty module.

#if os(tvOS)
import Foundation
import TVServices
import PVLibrarySnapshot
import os

private let log = Logger(subsystem: "com.joemattiello.iCube", category: "topshelf")

final class TopShelfContentProvider: TVTopShelfContentProvider {
    static let maxItemsPerRow = 12

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        let snapshot = LibrarySnapshotStore().load()
        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []

        func addSection(_ title: String, _ games: [LibrarySnapshotGame]) {
            guard !games.isEmpty else { return }
            let items = games.prefix(Self.maxItemsPerRow).map { game -> TVTopShelfSectionedItem in
                let item = TVTopShelfSectionedItem(identifier: game.id)
                item.title = game.title
                item.imageShape = .poster
                if let url = game.coverURL, FileManager.default.fileExists(atPath: url.path) {
                    item.setImageURL(url, for: .screenScale1x)
                    item.setImageURL(url, for: .screenScale2x)
                }
                if let launch = game.launchURL {
                    let action = TVTopShelfAction(url: launch)
                    item.displayAction = action
                    item.playAction = action
                }
                return item
            }
            let collection = TVTopShelfItemCollection(items: Array(items))
            collection.title = title
            sections.append(collection)
        }

        addSection("Continue Playing", snapshot.recentlyPlayed)
        addSection("Favorites", snapshot.favorites)
        log.info("load: recent=\(snapshot.recentlyPlayed.count) favorites=\(snapshot.favorites.count) sections=\(sections.count)")

        guard !sections.isEmpty else {
            completionHandler(nil)   // tvOS falls back to the static Top Shelf brand image
            return
        }
        completionHandler(TVTopShelfSectionedContent(sections: sections))
    }
}
#endif
```

```xml
<!-- Source/iOS/Extensions/iCubeTopShelf/PrivacyInfo.xcprivacy -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array/>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>
		<dict>
			<key>NSPrivacyAccessedAPIType</key>
			<string>NSPrivacyAccessedAPICategoryUserDefaults</string>
			<key>NSPrivacyAccessedAPITypeReasons</key>
			<array>
				<string>CA92.1</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
```

- [ ] **Step 4: Generate, build tvOS, verify the appex is embedded**

Run:
```bash
cd Source/iOS/App && tuist generate --no-open && xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination "generic/platform=tvOS" -derivedDataPath build-Xcode CODE_SIGNING_ALLOWED=NO 2>&1 | tail -2 && ls "build-Xcode/Build/Products/Debug (Non-Jailbroken)-appletvos/iCube.app/PlugIns/" && plutil -p "build-Xcode/Build/Products/Debug (Non-Jailbroken)-appletvos/iCube.app/PlugIns/iCubeTopShelf.appex/Info.plist" | grep -E "CFBundleIdentifier|NSExtensionPointIdentifier|PrincipalClass"
```
Expected: `** BUILD SUCCEEDED **`, `iCubeTopShelf.appex` listed, bundle id `com.joemattiello.iCube-debug.topshelf`, point `com.apple.tv-top-shelf`, principal `iCubeTopShelf.TopShelfContentProvider`.

Then confirm the iOS build does **not** embed it:
```bash
xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination "generic/platform=iOS" -derivedDataPath build-Xcode CODE_SIGNING_ALLOWED=NO 2>&1 | tail -1 && ls "build-Xcode/Build/Products/Debug (Non-Jailbroken)-iphoneos/iCube.app/PlugIns" 2>&1
```
Expected: `** BUILD SUCCEEDED **` and `No such file or directory` for PlugIns (until Task 9 adds the iOS extensions).

- [ ] **Step 5: Commit**

```bash
cd ../../.. && git checkout -- build/xcframework
git add Source/iOS/App/Project.swift Source/iOS/Extensions/iCubeTopShelf
git -c commit.gpgsign=false commit -m "feat(tvos): Top Shelf extension with Continue Playing + Favorites rows

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Quick Look thumbnail extension

**Files:**
- Modify: `Project.swift` (add `thumbnail` target, app dependency, targets list)
- Create: `Source/iOS/Extensions/iCubeThumbnail/ThumbnailProvider.swift`
- Create: `Source/iOS/Extensions/iCubeThumbnail/PlaceholderRenderer.swift`
- Create: `Source/iOS/Extensions/iCubeThumbnail/PrivacyInfo.xcprivacy` (same content as Task 8's)
- Create: `Source/iOS/Extensions/iCubeThumbnail/Info.plist`

**Interfaces:**
- Consumes: `LibraryLookup.resolve(url:)`, `ResolvedGame.coverURL/.platform/.gameID/.title`, Task 8's `extensionTarget(...)`.
- Produces: `PlaceholderRenderer.draw(_:in:size:)` (also used by Task 10 for the preview's fallback image).

Supported UTIs (declared by the app in `DolphiniOS/Info.plist`): `me.oatmealdome.dolphinios.generic-software`, `me.oatmealdome.dolphinios.gamecube-software`, `me.oatmealdome.dolphinios.wii-software`, `me.oatmealdome.dolphinios.rvz-image`, `me.oatmealdome.dolphinios.wia-image`, `me.oatmealdome.dolphinios.nkit-image`, `public.iso-image`.

- [ ] **Step 1: Tuist target**

Add after `topShelf` in `Project.swift`:

```swift
let thumbnail = extensionTarget(
    name: "iCubeThumbnail",
    suffix: "thumbnail",
    destinations: [.iPhone, .iPad, .macCatalyst],
    deploymentTargets: .multiplatform(iOS: "17.0"),
    infoPlist: .file(path: "../Extensions/iCubeThumbnail/Info.plist"),
    sources: ["../Extensions/iCubeThumbnail/**/*.swift"],
    resources: ["../Extensions/iCubeThumbnail/PrivacyInfo.xcprivacy"],
    deviceFamily: "1,2",
    frameworks: ["QuickLookThumbnailing"]
)
```

App dependency (append to the same array as Task 8): `.target(name: "iCubeThumbnail", condition: .when([.ios, .catalyst]))`. Targets list: `[iCube, liveActivity, iCubeTests, topShelf, thumbnail]`.

The plist:

```xml
<!-- Source/iOS/Extensions/iCubeThumbnail/Info.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>iCube Thumbnails</string>
	<key>NSExtension</key>
	<dict>
		<key>NSExtensionAttributes</key>
		<dict>
			<key>QLSupportedContentTypes</key>
			<array>
				<string>me.oatmealdome.dolphinios.generic-software</string>
				<string>me.oatmealdome.dolphinios.gamecube-software</string>
				<string>me.oatmealdome.dolphinios.wii-software</string>
				<string>me.oatmealdome.dolphinios.rvz-image</string>
				<string>me.oatmealdome.dolphinios.wia-image</string>
				<string>me.oatmealdome.dolphinios.nkit-image</string>
				<string>public.iso-image</string>
			</array>
			<key>QLThumbnailMinimumDimension</key>
			<integer>0</integer>
		</dict>
		<key>NSExtensionPointIdentifier</key>
		<string>com.apple.quicklook.thumbnail</string>
		<key>NSExtensionPrincipalClass</key>
		<string>$(PRODUCT_MODULE_NAME).ThumbnailProvider</string>
	</dict>
</dict>
</plist>
```

- [ ] **Step 2: Placeholder renderer**

```swift
// Source/iOS/Extensions/iCubeThumbnail/PlaceholderRenderer.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import UIKit
import PVLibrarySnapshot

/// Draws the no-cover tile: platform-tinted gradient, platform glyph, game id (or
/// filename-derived title). Used by the thumbnail reply and the preview fallback.
enum PlaceholderRenderer {
    static func colors(for platform: LibraryPlatform) -> (top: UIColor, bottom: UIColor) {
        switch platform {
        case .gamecube, .triforce:
            return (UIColor(red: 0.42, green: 0.32, blue: 0.68, alpha: 1), UIColor(red: 0.20, green: 0.13, blue: 0.38, alpha: 1))
        case .wii, .wiiware:
            return (UIColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1), UIColor(red: 0.55, green: 0.70, blue: 0.90, alpha: 1))
        case .elfdol, .unknown:
            return (UIColor(white: 0.40, alpha: 1), UIColor(white: 0.16, alpha: 1))
        }
    }

    static func glyph(for platform: LibraryPlatform) -> String {
        switch platform {
        case .gamecube, .triforce: return "🟪"
        case .wii, .wiiware: return "⬜️"
        case .elfdol, .unknown: return "🎮"
        }
    }

    /// Draws into the current graphics context. `size` is the full tile.
    static func draw(_ game: ResolvedGame, in context: CGContext, size: CGSize) {
        let palette = colors(for: game.platform)
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [palette.top.cgColor, palette.bottom.cgColor] as CFArray,
                                     locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }

        let isLight = game.platform == .wii || game.platform == .wiiware
        let textColor: UIColor = isLight ? UIColor(white: 0.12, alpha: 1) : .white

        let glyph = glyph(for: game.platform) as NSString
        let glyphFont = UIFont.systemFont(ofSize: min(size.width, size.height) * 0.36)
        let glyphSize = glyph.size(withAttributes: [.font: glyphFont])
        glyph.draw(at: CGPoint(x: (size.width - glyphSize.width) / 2, y: size.height * 0.22), withAttributes: [.font: glyphFont])

        let label = (game.gameID ?? game.title) as NSString
        let labelFont = UIFont.monospacedSystemFont(ofSize: max(8, min(size.width, size.height) * 0.11), weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: textColor, .paragraphStyle: paragraph]
        let inset = size.width * 0.08
        label.draw(in: CGRect(x: inset, y: size.height * 0.68, width: size.width - inset * 2, height: labelFont.lineHeight * 2), withAttributes: attrs)
    }

    static func image(for game: ResolvedGame, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            draw(game, in: ctx.cgContext, size: size)
        }
    }
}
```

- [ ] **Step 3: Thumbnail provider**

```swift
// Source/iOS/Extensions/iCubeThumbnail/ThumbnailProvider.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import UIKit
import QuickLookThumbnailing
import PVLibrarySnapshot

/// Files app / Finder thumbnails for GameCube and Wii disc images. Reads at most
/// 64 KiB of the file for the header and one mirrored JPEG from the App Group.
/// Never returns an error for a readable file: unknown discs get a drawn placeholder.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let game = LibraryLookup.resolve(url: request.fileURL)

        if let cover = game.coverURL {
            handler(QLThumbnailReply(imageFileURL: cover), nil)
            return
        }

        // Poster aspect inside the requested box, so the tile matches real covers.
        let box = request.maximumSize
        let posterAspect: CGFloat = 0.7
        let size = box.width / box.height > posterAspect
            ? CGSize(width: (box.height * posterAspect).rounded(), height: box.height)
            : CGSize(width: box.width, height: (box.width / posterAspect).rounded())

        handler(QLThumbnailReply(contextSize: size, currentContextDrawing: {
            guard let context = UIGraphicsGetCurrentContext() else { return false }
            PlaceholderRenderer.draw(game, in: context, size: size)
            return true
        }), nil)
    }
}
```

- [ ] **Step 4: Generate, build iOS, verify embed and UTIs**

Run:
```bash
cd Source/iOS/App && tuist generate --no-open && xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination "generic/platform=iOS" -derivedDataPath build-Xcode CODE_SIGNING_ALLOWED=NO 2>&1 | tail -2 && plutil -p "build-Xcode/Build/Products/Debug (Non-Jailbroken)-iphoneos/iCube.app/PlugIns/iCubeThumbnail.appex/Info.plist" | grep -E "CFBundleIdentifier|quicklook|rvz-image" && otool -L "build-Xcode/Build/Products/Debug (Non-Jailbroken)-iphoneos/iCube.app/PlugIns/iCubeThumbnail.appex/iCubeThumbnail" | grep -ci dolphin
```
Expected: `** BUILD SUCCEEDED **`, bundle id `com.joemattiello.iCube-debug.thumbnail`, point `com.apple.quicklook.thumbnail`, the `rvz-image` UTI present, and `0` Dolphin libraries linked.

- [ ] **Step 5: Commit**

```bash
cd ../../.. && git checkout -- build/xcframework
git add Source/iOS/App/Project.swift Source/iOS/Extensions/iCubeThumbnail
git -c commit.gpgsign=false commit -m "feat(ios): Quick Look thumbnail extension for GC/Wii disc images

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Quick Look preview extension

**Files:**
- Modify: `Project.swift` (add `preview` target, app dependency, targets list)
- Create: `Source/iOS/Extensions/iCubeQuickLookPreview/PreviewProvider.swift`
- Create: `Source/iOS/Extensions/iCubeQuickLookPreview/PreviewCard.swift`
- Create: `Source/iOS/Extensions/iCubeQuickLookPreview/PrivacyInfo.xcprivacy` (same content as Task 8's)
- Create: `Source/iOS/Extensions/iCubeQuickLookPreview/Info.plist`
- Create: symlink or copy of `PlaceholderRenderer.swift`: add `"../Extensions/iCubeThumbnail/PlaceholderRenderer.swift"` to this target's `sources` (shared file, compiled into both, like iFly's `WidgetSharedData.swift`).
- Test: `Source/iOS/PVLibrarySnapshot/Tests/PVLibrarySnapshotTests/PreviewCardFormattingTests.swift` is NOT possible (the card lives in the extension). Instead put the pure formatting helpers in the package: create `Source/iOS/PVLibrarySnapshot/Sources/PVLibrarySnapshot/PreviewFormatting.swift` and test it there.

**Interfaces:**
- Consumes: `LibraryLookup.resolve(url:)`, `PlaceholderRenderer.image(for:size:)`.
- Produces: `PreviewFormatting.fileSizeString(_:)`, `.escape(_:)`, `.relativeDate(_:now:)` in the package; `PreviewCard.html(game:filename:fileSize:coverData:)` in the extension.

- [ ] **Step 1: Failing tests for the formatting helpers**

```swift
// Tests/PVLibrarySnapshotTests/PreviewFormattingTests.swift
import XCTest
@testable import PVLibrarySnapshot

final class PreviewFormattingTests: XCTestCase {
    func testEscapesHTML() {
        XCTAssertEqual(PreviewFormatting.escape("Tom & \"Jerry\" <3"), "Tom &amp; &quot;Jerry&quot; &lt;3")
    }

    func testFileSize() {
        XCTAssertEqual(PreviewFormatting.fileSizeString(0), "0 bytes")
        XCTAssertEqual(PreviewFormatting.fileSizeString(1_459_978_240), "1.46 GB")
        XCTAssertEqual(PreviewFormatting.fileSizeString(4_699_979_776), "4.7 GB")
    }

    func testRelativeDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(PreviewFormatting.relativeDate(now.addingTimeInterval(-30), now: now), "Just now")
        XCTAssertEqual(PreviewFormatting.relativeDate(now.addingTimeInterval(-3 * 3600), now: now), "3 hours ago")
        XCTAssertEqual(PreviewFormatting.relativeDate(now.addingTimeInterval(-2 * 86400), now: now), "2 days ago")
        XCTAssertNil(PreviewFormatting.relativeDate(nil, now: now))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Source/iOS/PVLibrarySnapshot && swift test --filter PreviewFormattingTests 2>&1 | tail -3`
Expected: `cannot find 'PreviewFormatting' in scope`.

- [ ] **Step 3: Implement the helpers**

```swift
// Sources/PVLibrarySnapshot/PreviewFormatting.swift
import Foundation

public enum PreviewFormatting {
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    public static func fileSizeString(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 bytes" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.isAdaptive = true
        return f.string(fromByteCount: bytes)
    }

    public static func relativeDate(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.locale = Locale(identifier: "en_US")
        return f.localizedString(for: date, relativeTo: now)
    }
}
```

Run: `swift test 2>&1 | tail -3` → 0 failures. If `fileSizeString` output differs on your macOS (ByteCountFormatter locale), adjust the expected strings to what `en_US` produces and note it in the commit; the intent is adaptive GB/MB units.

- [ ] **Step 4: Tuist target**

```swift
let preview = extensionTarget(
    name: "iCubeQuickLookPreview",
    suffix: "preview",
    destinations: [.iPhone, .iPad, .macCatalyst],
    deploymentTargets: .multiplatform(iOS: "17.0"),
    infoPlist: .file(path: "../Extensions/iCubeQuickLookPreview/Info.plist"),
    sources: [
        "../Extensions/iCubeQuickLookPreview/**/*.swift",
        "../Extensions/iCubeThumbnail/PlaceholderRenderer.swift",
    ],
    resources: ["../Extensions/iCubeQuickLookPreview/PrivacyInfo.xcprivacy"],
    deviceFamily: "1,2",
    frameworks: ["QuickLook"]
)
```

App dependency: `.target(name: "iCubeQuickLookPreview", condition: .when([.ios, .catalyst]))`. Targets: `[iCube, liveActivity, iCubeTests, topShelf, thumbnail, preview]`.

The plist is the Thumbnail one with these differences: `CFBundleDisplayName` = `iCube Preview`; inside `NSExtensionAttributes` replace the `QLThumbnailMinimumDimension` entry with `<key>QLIsDataBasedPreview</key><true/>` (keep the same seven UTIs); `NSExtensionPointIdentifier` = `com.apple.quicklook.preview`; `NSExtensionPrincipalClass` = `$(PRODUCT_MODULE_NAME).PreviewProvider`. Write it out in full at `Source/iOS/Extensions/iCubeQuickLookPreview/Info.plist`.

- [ ] **Step 5: Card + provider**

```swift
// Source/iOS/Extensions/iCubeQuickLookPreview/PreviewCard.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import PVLibrarySnapshot

enum PreviewCard {
    static func html(game: ResolvedGame, filename: String, fileSize: Int64, coverData: Data?) -> String {
        let e = PreviewFormatting.escape
        var rows: [(String, String)] = [("Platform", game.platform.displayName)]
        if let id = game.gameID { rows.append(("Game ID", id)) }
        if let region = game.region { rows.append(("Region", region)) }
        if let disc = game.discNumber, disc > 0 { rows.append(("Disc", "\(disc + 1)")) }
        if let maker = game.makerCode { rows.append(("Maker", maker)) }
        if let tdb = game.snapshotGame?.gametdbID, tdb != game.gameID { rows.append(("GameTDB", tdb)) }
        rows.append(("File", filename))
        rows.append(("Size", PreviewFormatting.fileSizeString(fileSize)))
        if let played = PreviewFormatting.relativeDate(game.lastPlayed) { rows.append(("Last played", played)) }
        if game.isFavorite { rows.append(("Favorite", "★")) }

        let rowHTML = rows.map { "<tr><th>\(e($0.0))</th><td>\(e($0.1))</td></tr>" }.joined()
        let cover = coverData.map { "<img class=\"cover\" src=\"data:image/jpeg;base64,\($0.base64EncodedString())\" alt=\"\">" } ?? ""

        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light dark; }
          body { margin:0; font: -apple-system-body; font-family: -apple-system, system-ui; background: Canvas; color: CanvasText; }
          .wrap { padding: 24px; display: flex; flex-direction: column; align-items: center; gap: 16px; }
          .cover { width: 240px; max-width: 70%; border-radius: 10px; box-shadow: 0 8px 24px rgba(0,0,0,.35); }
          h1 { font-size: 22px; margin: 0; text-align: center; }
          table { border-collapse: collapse; width: 100%; max-width: 480px; }
          th { text-align: left; font-weight: 600; opacity: .7; padding: 6px 12px 6px 0; white-space: nowrap; vertical-align: top; }
          td { padding: 6px 0; word-break: break-all; }
          tr + tr th, tr + tr td { border-top: 1px solid rgba(128,128,128,.25); }
        </style></head><body><div class="wrap">
        \(cover)
        <h1>\(e(game.title))</h1>
        <table>\(rowHTML)</table>
        </div></body></html>
        """
    }
}
```

```swift
// Source/iOS/Extensions/iCubeQuickLookPreview/PreviewProvider.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later
import QuickLook
import UIKit
import UniformTypeIdentifiers
import PVLibrarySnapshot

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    private static let placeholderSize = CGSize(width: 480, height: 686)

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let game = LibraryLookup.resolve(url: url)
        let filename = LibraryLookup.realFilename(from: url)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0

        let coverData: Data?
        if let cover = game.coverURL, let data = try? Data(contentsOf: cover) {
            coverData = data
        } else {
            coverData = PlaceholderRenderer.image(for: game, size: Self.placeholderSize).jpegData(compressionQuality: 0.85)
        }

        let html = Data(PreviewCard.html(game: game, filename: filename, fileSize: size, coverData: coverData).utf8)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 600, height: 800)) { reply in
            reply.stringEncoding = .utf8
            return html
        }
    }
}
```

- [ ] **Step 6: Generate, build iOS, verify both Quick Look appexes**

Run:
```bash
cd Source/iOS/App && tuist generate --no-open && xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination "generic/platform=iOS" -derivedDataPath build-Xcode CODE_SIGNING_ALLOWED=NO 2>&1 | tail -2 && ls "build-Xcode/Build/Products/Debug (Non-Jailbroken)-iphoneos/iCube.app/PlugIns/"
```
Expected: `** BUILD SUCCEEDED **`, `iCubeThumbnail.appex` and `iCubeQuickLookPreview.appex` listed (no Top Shelf on iOS). Also build tvOS once more to be sure the Quick Look targets are not embedded there:
```bash
xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination "generic/platform=tvOS" -derivedDataPath build-Xcode CODE_SIGNING_ALLOWED=NO 2>&1 | tail -1 && ls "build-Xcode/Build/Products/Debug (Non-Jailbroken)-appletvos/iCube.app/PlugIns/"
```
Expected: only `iCubeTopShelf.appex`.

- [ ] **Step 7: Commit**

```bash
cd ../../.. && git checkout -- build/xcframework
git add Source/iOS/App/Project.swift Source/iOS/Extensions/iCubeQuickLookPreview Source/iOS/PVLibrarySnapshot
git -c commit.gpgsign=false commit -m "feat(ios): Quick Look preview extension with metadata card

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Device gates (iPhone + Apple TV)

**Files:** none changed unless a gate fails.

**Interfaces:** consumes everything above.

- [ ] **Step 1: iPhone build, install, launch**

Follow the commands in the "Commands that worked" block of the local-build notes (udid `5BD0518D-E8D9-5115-919A-A7C12481E82D`, config `Debug (Non-Jailbroken)`, `-allowProvisioningUpdates`). If signing fails on the App Group entitlement, do the portal steps in `docs/app-group-entitlements.md` and retry. Confirm the group is really in the signed app:
```bash
codesign -d --entitlements :- "Source/iOS/App/build-Xcode/Build/Products/Debug (Non-Jailbroken)-iphoneos/iCube.app" 2>/dev/null | grep -A2 application-groups
```
Expected: `group.com.joemattiello.icube` printed.

- [ ] **Step 2: Files app thumbnails**

Launch iCube once so the library scans (this writes the snapshot and mirrors covers). Then in Files → On My iPhone → iCube → Software, switch to icon view. Expected: an RVZ/ISO with a downloaded cover shows that cover; a GCZ (or a disc with no cover) shows the platform-tinted placeholder with its game id. Long-press → Quick Look shows the card with title, platform, id, region, size. Take a screenshot with `xcrun devicectl device screenshot`? Not available; use the phone's screenshot and AirDrop, or `idevicescreenshot` if installed. Record pass/fail in the commit message of Step 5.

- [ ] **Step 3: Apple TV build and Top Shelf**

Build tvOS for the real Apple TV (or the tvOS simulator for layout only):
```bash
cd Source/iOS/App && xcodebuild -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)" -derivedDataPath build-Xcode -allowProvisioningUpdates build 2>&1 | tail -1 && xcrun simctl install booted "build-Xcode/Build/Products/Debug (Non-Jailbroken)-appletvsimulator/iCube.app"
```
Import a game (WebDAV/upload server, or `xcrun simctl` file copy into the app's Caches/Software), launch it once, exit, go to the tvOS home screen, focus iCube in the top row. Expected: "Continue Playing" row with the game and its cover; selecting the tile launches it (`dolphinios://play?id=`). On the simulator, artwork may be blank when the simulator's group entitlement is not honoured; the real Apple TV is the artwork gate. Pull the extension log:
```bash
xcrun simctl spawn booted log show --last 5m --predicate 'subsystem == "com.joemattiello.iCube" AND category == "topshelf"' | tail -5
```
Expected: a `load: recent=1 favorites=0 sections=1` line.

- [ ] **Step 4: DSU deep link regression**

`xcrun simctl openurl booted "dolphinios://dsu/add?ip=10.0.0.5&port=26760&desc=Test"` on the iOS simulator (or the phone via Safari). Expected: snackbar "Added DSU server" and Settings → Controllers opens. This confirms Task 7's scene-delegate fix.

- [ ] **Step 5: Record**

Append a "Verified on device" paragraph to `docs/app-group-entitlements.md` with the date, the device, and what was seen. Commit:
```bash
git add docs/app-group-entitlements.md && git -c commit.gpgsign=false commit -m "docs: record Top Shelf / Quick Look device verification

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 12: Fallback `DolphiniOS.xcodeproj` parity

**Files:**
- Modify: `DolphiniOS.xcodeproj/project.pbxproj`

**Interfaces:** consumes the generated `iCube.xcodeproj/project.pbxproj` from `tuist generate` as the reference.

`release.yml` builds this project, so it must contain the three extension targets, the `PVLibrarySnapshot` local package, the new app sources (`Common/SharedDefaults.m`, the `Snapshot/` folder, `GameLaunchRequest.swift`, `LibrarySnapshotService.swift`) and the app group entitlements (those files are shared, nothing to do). The project already uses `PBXFileSystemSynchronizedRootGroup` for several folders and its `Common`/`DolphiniOS` groups pick up new files automatically only if they are synchronized; check with `grep -c "SharedDefaults.m" DolphiniOS.xcodeproj/project.pbxproj` after Step 2 and add explicit `PBXFileReference`/`PBXBuildFile` entries if the count is 0.

- [ ] **Step 1: Generate the reference project**

Run: `cd Source/iOS/App && tuist generate --no-open && grep -n "iCubeTopShelf\|iCubeThumbnail\|iCubeQuickLookPreview\|PVLibrarySnapshot" iCube.xcodeproj/project.pbxproj | wc -l`
Expected: a non-zero count; this file is the template for the blocks below.

- [ ] **Step 2: Add objects to `DolphiniOS.xcodeproj/project.pbxproj`**

For each of the three extensions, add, using UUIDs prefixed `C0C0CAFE` followed by a 16-hex-digit counter (e.g. `C0C0CAFE0000000000000101` for the Top Shelf native target, `...0102` its product ref, `...0103` its sources phase, `...0104` frameworks phase, `...0105` resources phase, `...0106` its synchronized root group, `...0107` its configuration list, `...0110`–`...0119` its ten `XCBuildConfiguration`s, `...0120` the container proxy, `...0121` the target dependency, `...0122` the embed build file; then `...02xx` for Thumbnail and `...03xx` for Preview):

1. `PBXFileReference` for the product: `{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = iCubeTopShelf.appex; sourceTree = BUILT_PRODUCTS_DIR; }` and add it to the `Products` group children.
2. `PBXFileSystemSynchronizedRootGroup` with `path = "../Extensions/iCubeTopShelf"; sourceTree = "<group>";` (Thumbnail: `../Extensions/iCubeThumbnail`; Preview: `../Extensions/iCubeQuickLookPreview`, plus a `PBXBuildFile` for `../Extensions/iCubeThumbnail/PlaceholderRenderer.swift` in the Preview sources phase). Add each group to the main group's children.
3. `PBXNativeTarget` mirroring the `LiveActivityExtension` block at lines 1883-1903: `buildPhases = (Sources, Frameworks, Resources)`, `fileSystemSynchronizedGroups = (<its group>)`, `packageProductDependencies = (<a new XCSwiftPackageProductDependency for PVLibrarySnapshot>)`, `productType = "com.apple.product-type.app-extension"`.
4. `XCLocalSwiftPackageReference` with `relativePath = ../PVLibrarySnapshot;` added to the project's `packageReferences`, and one `XCSwiftPackageProductDependency` (`productName = PVLibrarySnapshot`) per extension target plus one for the `iCube` app target (added to its `packageProductDependencies` and a `PBXBuildFile` in its Frameworks phase).
5. `XCConfigurationList` with ten `XCBuildConfiguration`s (one per configuration name, same names as the app). Each carries exactly: `CODE_SIGN_ENTITLEMENTS = "../Extensions/Shared/Extension.entitlements"; CODE_SIGN_STYLE = Automatic; DEVELOPMENT_TEAM = S32Z3HMYVQ; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_FILE = "../Extensions/<ExtensionDir>/Info.plist"; PRODUCT_BUNDLE_IDENTIFIER = "<app id for that config>.topshelf"; PRODUCT_NAME = "$(TARGET_NAME)"; SKIP_INSTALL = YES; SWIFT_OBJC_BRIDGING_HEADER = ""; SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = "1,2,3"; SDKROOT = appletvos; SUPPORTED_PLATFORMS = "appletvos appletvsimulator iphoneos iphonesimulator"; LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks");` Thumbnail/Preview: `SDKROOT = iphoneos; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; SUPPORTS_MACCATALYST = YES; TARGETED_DEVICE_FAMILY = "1,2";`. Copy the per-config app ids from `configTable` in `Project.swift`.
6. `PBXContainerItemProxy` + `PBXTargetDependency` (with `platformFilters = (tvos, );` for Top Shelf and `(ios, maccatalyst, );` for the other two) added to the `iCube` target's `dependencies`.
7. A new `PBXCopyFilesBuildPhase` named `Embed Foundation Extensions` with `dstSubfolderSpec = 13; dstPath = "";` on the `iCube` target (add it to `buildPhases` after `Resources`), containing one `PBXBuildFile` per appex with `settings = {ATTRIBUTES = (RemoveHeadersOnCopy, ); }` and the same `platformFilters` as the dependency.
8. Add the three targets to the `PBXProject.targets` list and to `TargetAttributes` with `CreatedOnToolsVersion = 16.2;`.

- [ ] **Step 3: Info.plists and resource exclusions**

The three `Info.plist` files already exist (Tasks 8–10) and are what `INFOPLIST_FILE` points at. Exclude each `Info.plist` from its synchronized group's build files with a `PBXFileSystemSynchronizedBuildFileExceptionSet` (`membershipExceptions = (Info.plist,);`, referenced from the group's `exceptions`) so the plist is not also copied as a resource. Provenance's `Extensions/TopShelfv2` group in its pbxproj is the shape to copy.

- [ ] **Step 4: Verify the fallback project builds both platforms with the extensions embedded**

Run:
```bash
cd Source/iOS/App && xcodebuild -project DolphiniOS.xcodeproj -list | sed -n '/Targets:/,/Build Configurations:/p' && for p in iOS tvOS; do xcodebuild build -project DolphiniOS.xcodeproj -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination "generic/platform=$p" -derivedDataPath build-Xcode-fallback CODE_SIGNING_ALLOWED=NO 2>&1 | tail -1; done && ls "build-Xcode-fallback/Build/Products/Debug (Non-Jailbroken)-iphoneos/iCube.app/PlugIns" "build-Xcode-fallback/Build/Products/Debug (Non-Jailbroken)-appletvos/iCube.app/PlugIns"
```
Expected: the three extension targets listed; two `** BUILD SUCCEEDED **`; iOS PlugIns = Thumbnail + Preview, tvOS PlugIns = Top Shelf. Re-run the Tuist build from Task 10 Step 6 once more to confirm nothing regressed.

- [ ] **Step 5: Commit**

```bash
cd ../../.. && git checkout -- build/xcframework
git add Source/iOS/App/DolphiniOS.xcodeproj/project.pbxproj Source/iOS/App/Project.swift Source/iOS/Extensions/*/Info.plist
git -c commit.gpgsign=false commit -m "build(xcodeproj): add extension targets to the fallback project

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review notes

- Spec 3.1: package, app group, model, header reader, lookup → Tasks 1–3 (store is named `LibrarySnapshotStore` and covers the spec's "reader"; the spec's `LibrarySnapshotKeys` lives in `LibrarySnapshot.swift`).
- Spec 3.2: last-played store, shared suite migration, writer, triggers, `play` route → Tasks 5–7. The "wait for first scan" behaviour of the route is provided by `TVLibraryView.spotlightLaunchByGameID`'s existing 10-attempt retry plus the 0.6 s cold-launch delay.
- Spec 3.3: Top Shelf → Task 8. Spec 3.4: Quick Look → Tasks 9–10. Spec 3.5: entitlements, doc, IPA signing → Task 4. Spec 4 gates → Task 11. Fallback project → Task 12.
- Out of scope (unchanged from spec): library "recently played" sort, recent-saves row, GCZ/TGC/WAD parsing, a Mac product.
