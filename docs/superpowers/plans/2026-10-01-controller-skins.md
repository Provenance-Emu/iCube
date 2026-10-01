# Controller Skins (Delta / Manic) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let iCube players import Delta (`.deltaskin`) and Manic EMU (`.manicskin`) controller skins for GameCube and Wii and play with them instead of the Swift-drawn touch overlay, choosable per pad kind and orientation.

**Architecture:** Port a trimmed copy of iFly's skin parser (itself a fork of Provenance PVUI's DeltaSkins) into the app target under `DolphiniOS/UI/Emulation/Skins/`. A new `SkinOverlayView` draws the skin and writes input through the SAME paths the Swift-drawn overlay uses (`TouchOverlayInput`, `TouchOverlayHitTester`, `TCManagerInterface`), so skins and the procedural overlay share all input semantics. The choice between them is made where the overlay is mounted today (`TouchPadsContainer.syncProgrammaticOverlay`).

**Tech Stack:** Swift 5, SwiftUI + UIKit touch surfaces, `marmelroy/Zip` (already a dependency) to unzip skins at import, CoreGraphics `CGPDFDocument` for PDF assets, XCTest in `iCubeTests`.

**Spec:** none yet. This plan supersedes the "skin import is out of scope" non-goal in
`docs/superpowers/specs/2026-09-24-programmatic-touch-overlay-design.md` (lines 7, 21, 37). The
research behind it (iFly vs Provenance skin code, gaps found) is summarized under "Background".

## Global Constraints

- iOS 17+ and tvOS 17+ must both still compile. Skins are iOS-only: every new file is `#if os(iOS)`.
- No new zip dependency: use `Zip` (already in `Project.swift` packages, see `DolphiniOS/UI/Import/ZipImportHelper.swift`).
- Do not depend on Provenance's PVUI (coupled to Realm/PVEmulatorCore/PVSettings).
- Skin input names are string constants declared once (`SkinInputName`), never literals at call sites.
- Raw `TCButtonType` ids only through `TouchOverlayDefaults`'s existing `ID` values or a new single table (`SkinInputMap`); profiles `Data/Sys/Profiles/{GCPad,Wiimote}/Touchscreen.ini` must keep matching.
- New app-target files need `cd Source/iOS/App && tuist generate --no-open`. New `Common/Services` files also need the 4 fallback `DolphiniOS.xcodeproj` entries (`C0C0CAFE`/`C0C0BEEF` ids); files under `DolphiniOS/UI/Emulation/` do not (that project doesn't list the touch overlay).
- Tests: `cd Source/iOS/App && make test DEST="platform=iOS Simulator,id=<udid>" TEST_ARGS="-only-testing:iCubeTests/<Class>"`. Release gate before commit: `make gate-release`.
- Local app builds overwrite the tracked `build/xcframework` slices: `git checkout -- build/xcframework` before every commit (check no other `xcodebuild` is building from this checkout first). Stage only your own files; this checkout is shared with other sessions.
- Commits: conventional prefixes, no LLM attribution trailers.

## Background (research 2026-10-01)

- iFly skin stack: `/Users/jmattiello/Workspace/Provenance/iFly/iFly/Sources/UI/Views/Skins/` (~12.8k lines with previews/pickers; the useful core is ~3-4k). Parser `Models/DeltaSkin.swift` (1076), types `Models/DeltaSkinTypes.swift` (583), `Models/DeltaSkinCodable.swift` (108), touch surface `Views/MultiTouchView.swift` (117), view `Views/DeltaSkinView.swift` (586) + `+Touch` (643).
- Provenance `PVUI/Sources/PVUIBase/SwiftUI/DeltaSkins/` is the more complete original (honours `extendedEdges` at `DeltaSkinView.swift:1685-1700`) but is not portable.
- Gaps in BOTH codebases that this port must fix: GameCube is mapped to `.n64` (iFly `DeltaSkinTypes.swift:369,497`); Manic's `public.aoshuang.game.ngc` is unknown and throws; `rightThumbstick*` is hard-coded to `"leftThumbstick"` (`DeltaSkinView.swift:259`, `DeltaSkinThumbstick.swift:10`), so a C-stick can't work; `buttons(for:)` keeps only `inputs.first`; iFly ignores `extendedEdges` (fixed `insetBy(-20)`).
- Sample skin (user-provided): `~/Downloads/gamecubepocket.zip`, "GameCube Pocket by starvingartist", `gameTypeIdentifier` `public.aoshuang.game.ngc`, iphone/edgeToEdge portrait+landscape, per-item PDF assets (Manic extension). Its inputs: `a b x y` buttons; `r1` = Z; `l2`/`r2` = L/R triggers; `start`; `menu`; `quickSave`/`quickLoad`; dpad dict `up/down/left/right`; `leftThumbstick*` = main stick; `rightThumbstick*` = C-stick. It is third-party art: do NOT commit it; tests use the hand-written fixture in Task 2.

## File Structure

All new code under `Source/iOS/App/DolphiniOS/UI/Emulation/Skins/` (picked up by the existing `DolphiniOS/**` glob; iOS-only via `#if os(iOS)`):

| File | Responsibility |
|---|---|
| `SkinGameType.swift` | Delta/Manic game-type identifiers → `.gameCube` / `.wii`; which `TouchOverlayPadKind`s a skin can serve |
| `SkinInputMap.swift` | `SkinInputName` constants; skin input name(s) → `TouchOverlayControlKind` per pad kind; special actions (menu, quick save/load) |
| `SkinModel.swift` | Trimmed port of iFly `DeltaSkin` Codable model: info, representations, items (all inputs kept), `extendedEdges`, thumbstick, per-item `asset` (Manic), screens, `mappingSize` |
| `SkinAssetRenderer.swift` | PDF/PNG asset → `UIImage` at a target size, with a small cache |
| `SkinLayout.swift` | One pure function: skin representation + canvas size → item hit/draw frames + game screen rect |
| `SkinLibrary.swift` | Skins directory, import (unzip + validate), list, delete, per-pad-kind/orientation selection |
| `SkinOverlayView.swift` | Draws the skin and turns touches into writes via `TouchOverlayInput`/`TCManagerInterface` |

Modified:
- `Common/Swift/EmulationScreen+TouchAndMotion.swift` — mount `SkinOverlayView` instead of `TouchOverlayView` when a skin is selected.
- `Common/Swift/EmulationScreen.swift` — game picture frame honours the skin's `screens` rect; menu/quick save/load actions.
- `DolphiniOS/Info.plist` — exported UTTypes + document types for `.deltaskin`/`.manicskin`.
- Controllers hub (`Common/Swift/Controllers/Hub/…`) — "Skins…" destination: import, pick, delete.
- `DolphiniOS/UI/Emulation/TouchOverlay/TouchOverlayGalleryView.swift` — show imported skins too.
- `docs/superpowers/specs/2026-09-24-programmatic-touch-overlay-design.md` — strike the non-goal, point here.

---

### Task 1: Game types and input mapping (pure)

**Files:**
- Create: `Source/iOS/App/DolphiniOS/UI/Emulation/Skins/SkinGameType.swift`
- Create: `Source/iOS/App/DolphiniOS/UI/Emulation/Skins/SkinInputMap.swift`
- Test: `Source/iOS/App/DolphiniOSTests/SkinInputMapTests.swift`

**Interfaces:**
- Produces: `enum SkinGameType { case gameCube, wii; init?(identifier: String); var padKinds: [TouchOverlayPadKind] }`; `enum SkinInputName` (string constants); `enum SkinAction { case control(TouchOverlayControlKind), menu, quickSave, quickLoad }`; `SkinInputMap.action(for inputs: [String], padKind: TouchOverlayPadKind) -> SkinAction?`; `SkinInputMap.stick(prefix: String, padKind:) -> TouchOverlayControlKind?` for thumbstick dicts.

- [ ] **Step 1: Write the failing tests**

```swift
#if os(iOS)
import XCTest
@testable import iCube

final class SkinInputMapTests: XCTestCase {
  func testGameTypeIdentifiers() {
    XCTAssertEqual(SkinGameType(identifier: "public.aoshuang.game.ngc"), .gameCube)
    XCTAssertEqual(SkinGameType(identifier: "com.rileytestut.delta.game.gc"), .gameCube)
    XCTAssertEqual(SkinGameType(identifier: "gamecube"), .gameCube)
    XCTAssertEqual(SkinGameType(identifier: "public.aoshuang.game.wii"), .wii)
    XCTAssertEqual(SkinGameType(identifier: "com.rileytestut.delta.game.wii"), .wii)
    XCTAssertNil(SkinGameType(identifier: "com.rileytestut.delta.game.n64"))
    XCTAssertEqual(SkinGameType.gameCube.padKinds, [.gameCube])
    XCTAssertEqual(SkinGameType.wii.padKinds, [.wiiRemote, .wiiRemoteSideways, .wiiClassic])
  }

  func testGameCubeButtonsMapToTouchscreenIds() {
    XCTAssertEqual(SkinInputMap.action(for: ["a"], padKind: .gameCube), .control(.button(id: 0)))
    XCTAssertEqual(SkinInputMap.action(for: ["b"], padKind: .gameCube), .control(.button(id: 1)))
    XCTAssertEqual(SkinInputMap.action(for: ["start"], padKind: .gameCube), .control(.button(id: 2)))
    XCTAssertEqual(SkinInputMap.action(for: ["x"], padKind: .gameCube), .control(.button(id: 3)))
    XCTAssertEqual(SkinInputMap.action(for: ["y"], padKind: .gameCube), .control(.button(id: 4)))
    XCTAssertEqual(SkinInputMap.action(for: ["r1"], padKind: .gameCube), .control(.button(id: 5)), "Manic uses r1 for Z")
    XCTAssertEqual(SkinInputMap.action(for: ["z"], padKind: .gameCube), .control(.button(id: 5)))
    XCTAssertEqual(SkinInputMap.action(for: ["l2"], padKind: .gameCube), .control(.axisButton(id: 20)))
    XCTAssertEqual(SkinInputMap.action(for: ["r2"], padKind: .gameCube), .control(.axisButton(id: 21)))
    XCTAssertEqual(SkinInputMap.action(for: ["l"], padKind: .gameCube), .control(.axisButton(id: 20)))
  }

  func testSpecialActions() {
    XCTAssertEqual(SkinInputMap.action(for: ["menu"], padKind: .gameCube), .menu)
    XCTAssertEqual(SkinInputMap.action(for: ["quickSave"], padKind: .wiiRemote), .quickSave)
    XCTAssertEqual(SkinInputMap.action(for: ["quickLoad"], padKind: .wiiClassic), .quickLoad)
  }

  func testSticksAndDpad() {
    XCTAssertEqual(SkinInputMap.stick(prefix: "leftThumbstick", padKind: .gameCube), .stick(baseId: 10))
    XCTAssertEqual(SkinInputMap.stick(prefix: "rightThumbstick", padKind: .gameCube), .stick(baseId: 15), "C-stick")
    XCTAssertEqual(SkinInputMap.stick(prefix: "leftThumbstick", padKind: .wiiRemote), .stick(baseId: 202), "Nunchuk")
    XCTAssertEqual(SkinInputMap.stick(prefix: "rightThumbstick", padKind: .wiiClassic), .stick(baseId: 318))
    XCTAssertNil(SkinInputMap.stick(prefix: "rightThumbstick", padKind: .wiiRemote))
    XCTAssertEqual(SkinInputMap.dpad(padKind: .gameCube), .dpad(baseId: 6))
    XCTAssertEqual(SkinInputMap.dpad(padKind: .wiiClassic), .dpad(baseId: 309))
  }

  func testWiiButtons() {
    XCTAssertEqual(SkinInputMap.action(for: ["a"], padKind: .wiiRemote), .control(.button(id: 100)))
    XCTAssertEqual(SkinInputMap.action(for: ["1"], padKind: .wiiRemote), .control(.button(id: 105)))
    XCTAssertEqual(SkinInputMap.action(for: ["c"], padKind: .wiiRemote), .control(.button(id: 200)))
    XCTAssertEqual(SkinInputMap.action(for: ["zl"], padKind: .wiiClassic), .control(.button(id: 307)))
  }

  func testUnknownInputIsIgnoredAndFirstKnownInputWins() {
    XCTAssertNil(SkinInputMap.action(for: ["toggleFastForward"], padKind: .gameCube))
    XCTAssertEqual(SkinInputMap.action(for: ["nonsense", "a"], padKind: .gameCube), .control(.button(id: 0)))
  }
}
#endif
```

- [ ] **Step 2: Run to verify it fails** — `make test … TEST_ARGS="-only-testing:iCubeTests/SkinInputMapTests"` → compile error "cannot find 'SkinInputMap'".

- [ ] **Step 3: Implement.** `SkinGameType.init?(identifier:)`: lowercase the string, take the part after the last `.`, map `ngc`, `gc`, `gamecube` → `.gameCube`; `wii` → `.wii`; anything else nil. `SkinInputMap` holds one `[String: Int]` table per pad kind built from `TouchOverlayDefaults`' ids. Expose them by making `TouchOverlayDefaults.ID` `internal` (rename to `TouchOverlayDefaults.ButtonID`) instead of duplicating the numbers. Trigger names (`l`, `l2`, `r`, `r2`, Classic `l`/`r`) map to `.axisButton`; all others to `.button`. Compare names case-insensitively. Constants live in `SkinInputName` (`static let a = "a"`, `quickSave = "quickSave"`, `leftThumbstick = "leftThumbstick"`, …).

- [ ] **Step 4: Run tests** → PASS.
- [ ] **Step 5: Commit** `feat(skins): map Delta/Manic skin inputs to touchscreen ids`.

### Task 2: Skin model (port of iFly's parser)

**Files:**
- Create: `Source/iOS/App/DolphiniOS/UI/Emulation/Skins/SkinModel.swift`
- Create: `Source/iOS/App/DolphiniOSTests/Fixtures/Skins/TestCube.deltaskin/info.json` (hand-written; no third-party art) and a 4x4 `bg.png`
- Test: `Source/iOS/App/DolphiniOSTests/SkinModelTests.swift`

**Interfaces:**
- Consumes: `SkinGameType` (Task 1).
- Produces: `struct SkinInfo: Decodable { name, identifier, gameType: SkinGameType, representations }`; `SkinInfo.representation(device: SkinDevice, orientation: TouchOverlayOrientation) -> SkinRepresentation?` (`edgeToEdge` falling back to `standard` and vice versa, like iFly's `lookupChain`); `struct SkinRepresentation { mappingSize: CGSize, items: [SkinItem], screens: [SkinScreen], background: SkinAsset?, translucent: Bool, extendedEdges: UIEdgeInsets }`; `struct SkinItem { inputs: SkinItemInputs, frame: CGRect, extendedEdges: UIEdgeInsets, asset: SkinAsset?, thumbstick: SkinThumbstick? }`; `enum SkinItemInputs { case buttons([String]), directional(up: String, down: String, left: String, right: String) }`; `SkinInfo.load(directory: URL) throws -> SkinInfo`.

- [ ] **Step 1: Write the fixture** — a minimal info.json with: `"gameTypeIdentifier": "public.aoshuang.game.ngc"`; `representations.iphone.edgeToEdge.portrait` with `mappingSize` 390x844, `assets.resizable` `bg.png`, `extendedEdges` `{top:5,bottom:5,left:5,right:5}`, a `screens` entry `outputFrame` `{x:0,y:60,width:390,height:292}`, and items: a button `["a"]` with its own `extendedEdges` `{left:20}` and Manic `asset.normal`; a multi-input item `["x","y"]`; a dpad dict; a `rightThumbstick*` dict with a `thumbstick` `{name, width, height}`; `["menu"]`; and a `"//"` comment line (iFly's `sanitizeSkinInfoJSON` strips these). Also a `landscape` entry under `standard` only.

- [ ] **Step 2: Write the failing tests**

```swift
#if os(iOS)
import XCTest
@testable import iCube

final class SkinModelTests: XCTestCase {
  private var fixture: URL {
    Bundle(for: Self.self).url(forResource: "TestCube", withExtension: "deltaskin", subdirectory: "Skins")!
  }

  func testParsesGameTypeAndRepresentations() throws {
    let info = try SkinInfo.load(directory: fixture)
    XCTAssertEqual(info.gameType, .gameCube)
    let portrait = try XCTUnwrap(info.representation(device: .iphone, orientation: .portrait))
    XCTAssertEqual(portrait.mappingSize, CGSize(width: 390, height: 844))
    XCTAssertEqual(portrait.screens.first?.outputFrame, CGRect(x: 0, y: 60, width: 390, height: 292))
    XCTAssertNotNil(info.representation(device: .iphone, orientation: .landscape), "edgeToEdge falls back to standard")
  }

  func testKeepsEveryInputAndPerItemEdges() throws {
    let items = try XCTUnwrap(SkinInfo.load(directory: fixture).representation(device: .iphone, orientation: .portrait)).items
    let multi = try XCTUnwrap(items.first { if case .buttons(let n) = $0.inputs { return n.count == 2 }; return false })
    XCTAssertEqual(multi.inputs, .buttons(["x", "y"]))
    let a = try XCTUnwrap(items.first { $0.inputs == .buttons(["a"]) })
    XCTAssertEqual(a.extendedEdges.left, 20, "item edges override the representation's")
    XCTAssertEqual(a.extendedEdges.top, 5, "unset item edges inherit the representation's")
    XCTAssertEqual(a.asset?.normal, "btn-a.pdf", "Manic per-item asset")
  }

  func testRightThumbstickIsItsOwnStick() throws {
    let items = try XCTUnwrap(SkinInfo.load(directory: fixture).representation(device: .iphone, orientation: .portrait)).items
    let stick = try XCTUnwrap(items.first { $0.thumbstick != nil })
    XCTAssertEqual(stick.inputs, .directional(up: "rightThumbstickUp", down: "rightThumbstickDown",
                                              left: "rightThumbstickLeft", right: "rightThumbstickRight"))
  }

  func testRejectsUnsupportedGameType() {
    let json = #"{"name":"N64","identifier":"x","gameTypeIdentifier":"com.rileytestut.delta.game.n64","representations":{}}"#
    XCTAssertThrowsError(try SkinInfo.decode(Data(json.utf8)))
  }
}
#endif
```

- [ ] **Step 3: Run** → fails (no `SkinInfo`).
- [ ] **Step 4: Implement** by porting from iFly `Models/DeltaSkin.swift` (`Info` :297, `OrientationRepresentations` :373, assets :490-575, `InputType` :631, thumbstick :665, `sanitizeSkinInfoJSON` :961) and `Models/DeltaSkinCodable.swift`. Changes while porting: drop ZIPFoundation (directories only); replace `DeltaSkinGameType` with `SkinGameType`; keep ALL item inputs (iFly keeps `inputs.first`); decode Manic per-item `asset` in the Codable model instead of iFly's raw-JSON side channel joined by frame (`DeltaSkinView+Loading.swift:~113`); per-item `extendedEdges` inherit missing sides from the representation's. Add the fixture folder to the `iCubeTests` target resources in `Project.swift` (`resources: ["DolphiniOSTests/Fixtures/**"]`), then `tuist generate --no-open`.
- [ ] **Step 5: Run** → PASS. **Step 6: Commit** `feat(skins): parse Delta/Manic skin info.json`.

### Task 3: Skin layout (pure)

**Files:**
- Create: `Source/iOS/App/DolphiniOS/UI/Emulation/Skins/SkinLayout.swift`
- Test: `Source/iOS/App/DolphiniOSTests/SkinLayoutTests.swift`

**Interfaces:**
- Consumes: `SkinRepresentation`, `SkinItem` (Task 2).
- Produces: `struct SkinLayout { let skinRect: CGRect; let gameRect: CGRect?; let items: [(item: SkinItem, drawFrame: CGRect, hitFrame: CGRect)] }`; `static func make(_ rep: SkinRepresentation, canvas: CGSize) -> SkinLayout`. ONE function used by both the skin view and the game picture placement (iFly duplicates this math in `EmulationView+Frame.swift:~486-540`; don't).

- [ ] **Step 1: Failing tests**

```swift
#if os(iOS)
import XCTest
@testable import iCube

final class SkinLayoutTests: XCTestCase {
  private func rep(mapping: CGSize, items: [SkinItem], screen: CGRect?) -> SkinRepresentation {
    SkinRepresentation(mappingSize: mapping, items: items, screens: screen.map { [SkinScreen(outputFrame: $0)] } ?? [],
                       background: nil, translucent: false, extendedEdges: .zero)
  }

  func testAspectFitsAndBottomAnchorsInPortrait() {
    let item = SkinItem(inputs: .buttons(["a"]), frame: CGRect(x: 10, y: 800, width: 40, height: 40),
                        extendedEdges: UIEdgeInsets(top: 5, left: 5, bottom: 5, right: 5), asset: nil, thumbstick: nil)
    let layout = SkinLayout.make(rep(mapping: CGSize(width: 390, height: 844), items: [item],
                                     screen: CGRect(x: 0, y: 60, width: 390, height: 292)),
                                 canvas: CGSize(width: 780, height: 1800))
    // Scale = min(780/390, 1800/844) = 2; skin is 780x1688, bottom-anchored: origin y = 1800-1688.
    XCTAssertEqual(layout.skinRect, CGRect(x: 0, y: 112, width: 780, height: 1688))
    XCTAssertEqual(layout.items[0].drawFrame, CGRect(x: 20, y: 112 + 1600, width: 80, height: 80))
    XCTAssertEqual(layout.items[0].hitFrame, CGRect(x: 10, y: 112 + 1590, width: 100, height: 100), "extendedEdges scale too")
    XCTAssertEqual(layout.gameRect, CGRect(x: 0, y: 112 + 120, width: 780, height: 584))
  }

  func testCentresInLandscapeAndHasNoGameRectWithoutScreens() {
    let layout = SkinLayout.make(rep(mapping: CGSize(width: 844, height: 390), items: [], screen: nil),
                                 canvas: CGSize(width: 1000, height: 390))
    XCTAssertEqual(layout.skinRect, CGRect(x: 78, y: 0, width: 844, height: 390))
    XCTAssertNil(layout.gameRect)
  }
}
#endif
```

- [ ] **Step 2: Run** → fails. **Step 3: Implement**: `scale = min(canvas.w / mapping.w, canvas.h / mapping.h)`; skin size = mapping × scale; x centred; y bottom-anchored when `canvas.height > canvas.width`, else centred; draw frame = item frame × scale + origin; hit frame = draw frame outset by `extendedEdges × scale`; `gameRect` = first screen's `outputFrame` mapped the same way. **Step 4: Run** → PASS. **Step 5: Commit** `feat(skins): one layout function for skin items and game screen`.

### Task 4: Skin library (import, list, select)

**Files:**
- Create: `Source/iOS/App/DolphiniOS/UI/Emulation/Skins/SkinLibrary.swift`
- Modify: `Source/iOS/App/DolphiniOS/Info.plist` (exported UTTypes + `CFBundleDocumentTypes`)
- Test: `Source/iOS/App/DolphiniOSTests/SkinLibraryTests.swift`

**Interfaces:**
- Consumes: `SkinInfo.load(directory:)`, `SkinGameType`.
- Produces: `@MainActor final class SkinLibrary: ObservableObject { static let shared; init(rootURL: URL); var skins: [InstalledSkin]; func importSkin(from archive: URL) throws -> InstalledSkin; func delete(_:) throws; func selectedSkin(for: TouchOverlayPadKind, orientation: TouchOverlayOrientation) -> InstalledSkin?; func select(_: InstalledSkin?, for:orientation:) }`; `struct InstalledSkin: Identifiable { id: String (info.identifier), name, gameType, directory: URL }`; `enum SkinImportError: Error { unreadableArchive, missingInfo, unsupportedGameType(String) }`.

- [ ] **Step 1: Failing tests** (zip the Task 2 fixture to a temp `.deltaskin` with `Zip.zipFiles` in `setUp`):
  - import → one installed skin, unzipped under `rootURL/<identifier>/info.json`;
  - importing the same identifier again replaces it (count stays 1);
  - an archive whose info.json has an N64 game type throws `.unsupportedGameType("com.rileytestut.delta.game.n64")` and leaves nothing behind;
  - a zip without info.json throws `.missingInfo`;
  - `select(skin, for: .gameCube, orientation: .portrait)` round-trips through a fresh `SkinLibrary(rootURL:)` (selection persisted as JSON in `rootURL/selection.json`, key `"<padKind>.<orientation>"`, like `TouchOverlayLayoutStore.key`); selecting a Wii skin for `.gameCube` is refused (`gameType.padKinds` check).
- [ ] **Step 2: Run** → fails. **Step 3: Implement**: root = `<UserFolder>/Skins` (`UserFolderUtil.getUserFolder()`); unzip into a temp dir with `Zip.unzipFile`, accept info.json at the root or one folder deep, validate with `SkinInfo.load`, then move to `root/<identifier>` (replace). Info.plist: add `UTExportedTypeDeclarations` `com.joemattiello.iCube.deltaskin` (`deltaskin`) and `com.joemattiello.iCube.manicskin` (`manicskin`), both conforming to `public.data`, `public.archive`, plus matching `CFBundleDocumentTypes` (role Viewer, `LSHandlerRank` Owner); route opened files with those extensions to `SkinLibrary.shared.importSkin` from the scene delegate's open-URL handler, the same way ROM imports are routed (`MainDisplaySceneDelegate.swift`). **Step 4: Run** → PASS. **Step 5: Commit** `feat(skins): import, store and select skins`.

### Task 5: Asset rendering

**Files:**
- Create: `Source/iOS/App/DolphiniOS/UI/Emulation/Skins/SkinAssetRenderer.swift`
- Test: `Source/iOS/App/DolphiniOSTests/SkinAssetRendererTests.swift`

**Interfaces:** Produces `enum SkinAssetRenderer { static func image(named: String, in directory: URL, size: CGSize, scale: CGFloat) -> UIImage? }` with an `NSCache` keyed by path+size.

- [ ] **Step 1: Failing tests**: a generated one-page PDF (draw with `UIGraphicsPDFRenderer` into the temp dir) renders to an image of exactly `size × scale` pixels; a PNG passes through; a missing file returns nil; a 10000 pt request is clamped to 4096 px on the long side (iFly's cap, `DeltaSkin.swift:~1000`).
- [ ] **Step 2: Run** → fails. **Step 3: Implement** by porting iFly's `CGPDFDocument` rasterizer (`DeltaSkin.swift:~1000`). **Step 4: Run** → PASS. **Step 5: Commit** `feat(skins): rasterize PDF/PNG skin assets`.

### Task 6: SkinOverlayView (draw + input)

**Files:**
- Create: `Source/iOS/App/DolphiniOS/UI/Emulation/Skins/SkinOverlayView.swift`
- Modify: `Source/iOS/App/DolphiniOS/UI/Emulation/TouchOverlay/TouchOverlayGalleryView.swift` (add installed skins to the gallery)
- Test: `Source/iOS/App/DolphiniOSTests/SkinOverlayInputTests.swift`

**Interfaces:**
- Consumes: Tasks 1-5; `TouchOverlayHitTester.union`/`dpadDirections`, `TouchOverlayInput.stickAxes`/`stickWrites`/`dpadWrites`, `TouchOverlayCluster`, `TouchOverlaySingleTouch` (existing in `TouchOverlay/`).
- Produces: `struct SkinOverlayView: View { init(skin: InstalledSkin, padKind: TouchOverlayPadKind, deviceId: Int, onAction: @escaping (SkinAction) -> Void) }`; pure `SkinOverlayInput.writes(forPressed: Set<Int>, items: [SkinLayout item], padKind:) -> [(id: Int, pressed: Bool)]` that the tests drive.

- [ ] **Step 1: Failing tests** on the pure part: a touch inside an item's `hitFrame` but outside its `drawFrame` presses it (extendedEdges honoured); an item with inputs `["x","y"]` presses BOTH ids; the dpad item resolves directions with `dpadDirections`; the `rightThumbstick` item writes `stickWrites(baseId: 15)` on GameCube; releasing every touch releases every id.
- [ ] **Step 2: Run** → fails. **Step 3: Implement**: background image (`representation.background`) full `skinRect`; per-item `asset.normal` over `drawFrame` (translucent skins at the configured overlay opacity, `DOLConfigBridge.mainTouchPadOpacity()`); sticks drawn with the item's `thumbstick` image moving inside `drawFrame`; touch surfaces reuse `TouchOverlayCluster` (buttons), the D-pad view's hit logic, and `TouchOverlaySingleTouch` (sticks). `menu`/`quickSave`/`quickLoad` call `onAction`. Gallery: a "Skins" section rendering `SkinOverlayView` with hit testing off on each preview device.
- [ ] **Step 4: Run** → PASS; render the gallery snapshot test with a fixture skin and look at it. **Step 5: Commit** `feat(skins): draw skins and route their touches`.

### Task 7: Mount skins in game + game picture placement

**Files:**
- Modify: `Source/iOS/App/Common/Swift/EmulationScreen+TouchAndMotion.swift` (`syncProgrammaticOverlay`, ~:197-235)
- Modify: `Source/iOS/App/Common/Swift/EmulationScreen.swift` (game picture frame; actions)
- Test: `Source/iOS/App/DolphiniOSTests/SkinMountTests.swift`

**Interfaces:**
- Consumes: `SkinLibrary.selectedSkin(for:orientation:)`, `SkinLayout.make`, `SkinOverlayView`.
- Produces: `enum OverlayChoice { case programmatic, skin(InstalledSkin) }` and `static func overlayChoice(padKind:, orientation:, library:) -> OverlayChoice` (pure, tested).

- [ ] **Step 1: Failing tests** for `overlayChoice`: no selection → `.programmatic`; a selection for the other orientation only → `.programmatic`; a selected skin whose files were deleted → `.programmatic` (and the selection is cleared).
- [ ] **Step 2: Run** → fails. **Step 3: Implement**: in `syncProgrammaticOverlay`, host `SkinOverlayView` instead of `TouchOverlayView` for `.skin`; keep `TouchOverlayHostContainer` teardown. In `EmulationScreen`, when a skin with a `gameRect` is active, place the Metal view at `gameRect` (aspect-fit inside it) instead of the default top/centre placement. `onAction`: `.menu` → open the pause menu (`showPauseMenu = true`); `.quickSave`/`.quickLoad` → `SaveStateService.saveSlot(selectedSlot)` / `TVEmulationBridge.loadState(fromSlot: selectedSlot)` (the top bar's existing calls). Skins only apply when `TouchOverlayFlag.isProgrammatic` is on (the xib pads are untouched).
- [ ] **Step 4: Run** → PASS; device check: import `~/Downloads/gamecubepocket.zip` renamed `.manicskin` via Files, select it, boot a GameCube game in portrait and landscape: every button presses, C-stick moves the camera, Menu opens the pause menu, game picture sits in the skin's screen area. **Step 5: Commit** `feat(skins): play with a skin in game`.

### Task 8: Choosing skins in the Controllers hub

**Files:**
- Create: `Source/iOS/App/Common/UI/Settings/SwiftUI/SkinPickerView.swift` (iOS-only)
- Modify: `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubViewModel.swift` (+ the model builder/state for a "Skins…" row next to "Edit Layout…")
- Modify: `docs/superpowers/specs/2026-09-24-programmatic-touch-overlay-design.md`
- Test: `Source/iOS/App/DolphiniOSTests/ControllerHubModelBuilderTests.swift` (row present on iOS)

- [ ] **Step 1: Failing test**: the hub model contains a "Skins" destination row on iOS.
- [ ] **Step 2: Run** → fails. **Step 3: Implement** `SkinPickerView`: segmented pad kind + orientation; list "Swift-drawn (default)" + installed skins matching `gameType.padKinds`, with a preview thumbnail (`SkinOverlayView` scaled, hit testing off); toolbar "Import…" (`.fileImporter` for the two UTTypes) and swipe-to-delete. Catalogue new strings with `L(...)`. Update the spec: remove the non-goal, link this plan. Coordinate with the Controller Hub phase 3 session before editing hub files (it owns `Common/Swift/Controllers/` work on `feature/controller-hub-phase3`).
- [ ] **Step 4: Run** → PASS, then `make gate-release`. **Step 5: Commit** `feat(skins): pick and import skins from the Controllers hub`.

---

## Self-review notes

- Spec coverage: import (T4, T8), parse incl. Manic extensions (T2), C-stick (T1, T2, T6), extendedEdges (T2, T3, T6), multi-input (T2, T6), game screen placement (T3, T7), menu/quick save/load (T1, T7), per pad kind + orientation choice (T4, T7, T8), Wii (T1 ids; Wii skin device test is part of T7's check if a Wii skin is available).
- Open question for the user before T7: should skins also replace the xib pads when the programmatic flag is off? This plan says no (skins ride on the new overlay path only).
