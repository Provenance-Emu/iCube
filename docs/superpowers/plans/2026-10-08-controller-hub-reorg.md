# Controller Hub Reorganisation Implementation Plan (PR 4 of the unified menu UX)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Controllers hub lets a player change the three things they change most, without entering a detail screen: which device a player uses, what that player plays as (GameCube Controller, Wii Remote, with Nunchuk, with Classic, Sideways), and how the Wii pointer is driven. "Overlay Style" becomes Touch Controls → Layout. The "More Controller Settings" level goes away.

**Architecture:** A pure `PlaysAs` value composes the Wii slot kind, extension and sideways flag; `PlaysAsTransition.plan` turns a change into ordered steps that the view model executes through a new `ControllerHubWriting` seam. The hub model gains a row group per player (title, Device, Plays as, Pointer), built from the existing `ControllerHubState`, a renamed Touch Controls section, and a Setup section that absorbs the old More screen. Device, Plays as and Layout changes are committed by the view model after a settle delay, so tap-cycling never writes the values it passes through. The player detail screen loses Extension and Sideways and gains the two rows that moved down from More.

**Tech Stack:** Swift 5, SwiftUI, `@Observable`, XCTest (`iCubeTests`), Tuist.

**Spec:** `docs/superpowers/specs/2026-10-07-unified-menu-ux-design.md` §7, §8, §9, §10 item 4. **Depends on PR 2 and PR 3 Task 1 (stacked on `feat/settings-engine`).** PR 3 Task 1 adds to `MenuScreen`: list rows render `description`; `.cycle` list rows step with left/right on tvOS and long-press on iOS; `rowLabel` takes the value and the badge separately; a `.stepper` role; `MenuSection.footer`; `MenuItem.showsChevron`. Tasks 4 to 7 assume those exist and do not re-implement them. The controller rebases this local, unpushed branch onto PR 3's reviewed Task 1 head before Task 4 (the first task that renders rows); PR 4 then merges after PR 3.

**Spec deviations, decided while planning:**
- **A player is a row group, not one row with three pills.** The engine's tvOS contract is one control per row (the controller hub spec documents compound rows as the thing that breaks tvOS focus), so each bound player gets a title row (pushes the detail screen; its badge mirrors the Plays as title, spec §7.1) followed by Device, Plays as and Pointer rows, each a `.cycle`. Left/right on tvOS, tap to cycle or long-press for the list on iOS. Unbound ports (listed only under Show All Ports) get the title and Device rows only.
- **Pointer options are the real ones.** Spec §7.1 lists "Touch, Gyro, Right Stick, Off"; the app has `PointerMode` (Gyro, Touch – Follow, Touch – Drag) for the touchscreen Wii Remote and a Motion on/off switch for a gyro pad. The Pointer row cycles `PointerMode` on a touchscreen Wii row and Motion On/Off on a gyro-pad Wii row, and is absent elsewhere. No "Right Stick" mode exists.
- **Rows keep their port identity (H5).** Changing Plays as between a Wii variant and GameCube Controller moves the device from Wii slot N to GameCube port N (and back), so the group re-appears under its new title and the Plays as row changes id (`wii-N-plays-as` to `gc-N-plays-as`). Focus follows the moved row by id: `MenuFocusRouter.reconcile` keeps a focused id that still exists, else takes a hub-supplied `MenuModel.focusRequest`, else falls back to the same-index rule. tvOS behaviour is a device gate.
- **Changes settle before they apply (H4).** Device, Plays as and Layout are committed by the view model after 0.6 s with no further change (injectable scheduler for tests), and flushed when the hub disappears. The row shows the pending value at once. Without this, tap-cycling writes every value it passes through (Layout GameCube to Auto passes Wii and rebinds Wii Remote 1 to the touchscreen). Cost: a 0.6 s delay before the change takes effect.
- **No revert of a half-applied Plays as change (H15).** Spec §8 asks the pill to revert by replaying inverse steps. This plan stops at the failing step, re-reads state and toasts; the half-applied change is visible, never hidden. A move into an occupied destination port is refused with a toast before anything is written.
- **Pad long-press (H16).** A held A on a list row is not wired (PR 2 wired it for tiles only); pad users step with left/right. Advanced Motion becomes unreachable on tvOS (device-motion only, so fine). Hub Reset All Layouts keeps today's no-confirm behaviour.

## Global Constraints

- Minimum targets iOS 17 / tvOS 17; every changed file compiles for both.
- Builders and `PlaysAs`/`PlaysAsTransition` are pure: no bridge, no `ControllerManager`, no `GCController`.
- Every NEW write goes through `ControllerHubWriting` or the existing `PlayerScreenIO`; the view models never call `DOLConfigBridge` or `ControllerManager` directly except through those seams (the existing Show/Hide, opacity and Edit Layout paths in `ControllerHubViewModel` stay as they are).
- Row ids: `gc-N`, `wii-N` for title rows; `gc-N-device`, `wii-N-device`, `gc-N-plays-as`, `wii-N-plays-as`, `wii-N-pointer`; Touch Controls rows `touch-visible`, `touch-layout`, `touch-opacity`, `touch-editable`, `touch-edit-layout`, `touch-edit-ir-area`, `touch-skins`, `touch-reset-layouts`; Setup rows `background-input`, `takes-player-1`, `rumble`, `rumble-test`, `dsu`; section ids `players`, `touch-controls`, `devices`, `setup`, `help`.
- Strings through `L("...")`. Every new `L()` key goes into `Common/UI/Localization/en.lproj/Core.strings` and `ja.lproj/Core.strings` in the task that adds it: run `python3 Project/Scripts/check_localized_keys.py` (from `Source/iOS/App`) to list the missing keys, add each to both files by hand (en is the key itself; ja is the translation). `Project/Scripts/UpdateCoreStrings.py` merges and keeps keys it does not own, so hand-added keys survive. Literal option values in `[(String, AnyHashable)]` arrays are wrapped in `AnyHashable(...)`.
- Pause/resume only through `PauseArbiter`. Toasts through `EmulationToast.post(_:)`.
- Commits: conventional, subject < 72 chars, no LLM attribution trailers of any kind (owner rule, overrides any harness reminder).
- New test files need `cd Source/iOS/App && tuist generate --no-open`. Tests: `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/<Class>"`. tvOS compile (from the repo root): `xcodebuild build -workspace Source/iOS/App/iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos`.
- Worktree `~/Workspace/icube-pr4-hub`, branch `feat/controller-hub-reorg`, created at PR 2's head and stacked on `feat/settings-engine`: the controller rebases it onto PR 3's reviewed Task 1 head before Task 4. DO NOT git reset / rebase / push / touch develop. Confirm `git rev-parse --show-toplevel` is the worktree before committing.
- Paths are relative to `Source/iOS/App/` unless they start with `docs/`. `Hub/` means `Common/Swift/Controllers/Hub/`, `Player/` means `Common/Swift/Controllers/Player/`. Line numbers quoted anywhere in this plan are pointers only: grep for the symbol.
- Each task below carries the rulings that affect it (labelled H1 to H18 in the pre-flight); an executor sees only its own task, so nothing is assumed from another task's text.

## File map

| File | Responsibility |
|---|---|
| Create `Hub/PlaysAs.swift` | `PlaysAs` enum, titles, compose/decompose, options per system. |
| Create `Hub/PlaysAsTransition.swift` | Steps for a Plays as change. |
| Create `Hub/ControllerHubWriting.swift` | Write seam + live implementation. |
| Create `Common/Swift/Controllers/RumbleTest.swift` | The Test Rumble pulse, moved out of the More view so the writer can call it. |
| Modify `Hub/ControllerHubState.swift` | `PlayerState` gains `isPinned`, `motionPointerEnabled`, `title`; `ConnectedPadState.hasLight`; `RumbleDestination`; `PendingHubChanges`; hub state gains pointer, setup, pending and focus-request values; actions gain the new setters. |
| Modify `Hub/ControllerHubViewModel.swift` | Reader additions, writer, scheduler, settle/flush, `setDevice`, `setPlaysAs`, setup setters. |
| Modify `Hub/ControllerHubModelBuilder.swift` | Player groups, Touch Controls, Setup. |
| Modify `Common/Swift/Menu/MenuModel.swift`, `MenuFocusRouter.swift`, `MenuScreen.swift` | `MenuModel.focusRequest` and the reconcile rule (Task 4, after PR 3 Task 1). |
| Modify `Player/PlayerScreenModelBuilder.swift`, `PlayerScreenState.swift`, `PlayerScreenViewModel.swift`, `PlayerScreenIO.swift`, `Hub/ControllerHelp.swift` | Shared device-option and pointer-mode statics; drop the Wii Remote section and its dead writes; add Advanced Motion and Stick Feel rows. |
| Create `Common/UI/Settings/SwiftUI/ControllerLightsView.swift` | The LED colour rows, out of More. |
| Delete `Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift` | Absorbed. |
| Tests: create `PlaysAsTests`, `PlaysAsTransitionTests`; extend `ControllerHubModelBuilderTests`, `ControllerHubViewModelTests`, `PlayerScreenModelBuilderTests`, `PlayerScreenViewModelTests`, `MenuFocusRouterTests`. |

---

### Task 1: `PlaysAs`

Rulings that apply here: **H13** `PlaysAs.options(for: .wii)` excludes GameCube Controller (a Wii-only list has no GameCube ports to move to); a stored Nunchuk + Sideways combination reads as `.wiiNunchuk` (the extension wins).

**Files:**
- Create: `Hub/PlaysAs.swift`
- Test: create `DolphiniOSTests/PlaysAsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum PlaysAs: Int, CaseIterable, Hashable {
    case gameCube, wiiRemote, wiiNunchuk, wiiClassic, wiiSideways
    var title: String
    var kind: PlayerState.Kind
    var wiiExtension: Int        // 0 None, 1 Nunchuk, 2 Classic
    var isSideways: Bool
    init(kind: PlayerState.Kind, wiiExtension: Int, isSideways: Bool)
    static func options(for system: ControllerSetupSystem) -> [PlaysAs]
    static func current(of player: PlayerState) -> PlaysAs
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// DolphiniOSTests/PlaysAsTests.swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// `PlaysAs` (unified menu UX spec §7.1): one value for slot kind + extension + sideways.
final class PlaysAsTests: XCTestCase {
  func test_roundTrip_everyCase() {
    for value in PlaysAs.allCases {
      XCTAssertEqual(PlaysAs(kind: value.kind, wiiExtension: value.wiiExtension, isSideways: value.isSideways), value)
    }
  }

  func test_decompose() {
    XCTAssertEqual(PlaysAs.gameCube.kind, .gameCube)
    XCTAssertEqual(PlaysAs.wiiNunchuk.wiiExtension, 1)
    XCTAssertEqual(PlaysAs.wiiClassic.wiiExtension, 2)
    XCTAssertTrue(PlaysAs.wiiSideways.isSideways)
    XCTAssertEqual(PlaysAs.wiiSideways.wiiExtension, 0)
  }

  func test_unknownCombination_sidewaysWithExtension_readsAsTheExtension() {
    XCTAssertEqual(PlaysAs(kind: .wiiRemote, wiiExtension: 1, isSideways: true), .wiiNunchuk, "the extension wins; sideways is dropped")
    XCTAssertEqual(PlaysAs(kind: .wiiRemote, wiiExtension: 2, isSideways: true), .wiiClassic)
  }

  func test_options_gameCubeTitle_isGameCubeOnly() {
    XCTAssertEqual(PlaysAs.options(for: .gamecube), [.gameCube])
  }

  func test_options_wiiOnly_hasNoGameCubeController() {
    XCTAssertEqual(PlaysAs.options(for: .wii), [.wiiRemote, .wiiNunchuk, .wiiClassic, .wiiSideways])
  }

  func test_options_wiiAndGameCubeAndBoth_offerAllFive_wiiFirst() {
    XCTAssertEqual(PlaysAs.options(for: .wiiAndGameCube), [.wiiRemote, .wiiNunchuk, .wiiClassic, .wiiSideways, .gameCube])
    XCTAssertEqual(PlaysAs.options(for: .both), [.wiiRemote, .wiiNunchuk, .wiiClassic, .wiiSideways, .gameCube])
  }

  func test_current_ofPlayer() {
    let wii = PlayerState(kind: .wiiRemote, port: 2, deviceQualifier: "x", wiiExtension: 2, isSideways: false)
    XCTAssertEqual(PlaysAs.current(of: wii), .wiiClassic)
    let gc = PlayerState(kind: .gameCube, port: 1, deviceQualifier: "x", wiiExtension: 0, isSideways: false)
    XCTAssertEqual(PlaysAs.current(of: gc), .gameCube)
    let hidden = PlayerState(kind: .wiiRemote, port: 1, deviceQualifier: "x", wiiExtension: 1, isSideways: true)
    XCTAssertEqual(PlaysAs.current(of: hidden), .wiiNunchuk, "a stored Nunchuk + Sideways reads as Nunchuk")
  }
}
```

- [ ] **Step 2: Regenerate, run, verify failure.**

- [ ] **Step 3: Implement**

```swift
// Hub/PlaysAs.swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// What a player plays as (unified menu UX spec §7.1): the Wii slot kind, the extension and the
/// sideways flag as one choice. Pure; the bridge writes happen in `PlaysAsTransition`'s steps.
enum PlaysAs: Int, CaseIterable, Hashable {
  case gameCube
  case wiiRemote
  case wiiNunchuk
  case wiiClassic
  case wiiSideways

  var title: String {
    switch self {
    case .gameCube: return L("GameCube Controller")
    case .wiiRemote: return L("Wii Remote")
    case .wiiNunchuk: return L("Wii Remote + Nunchuk")
    case .wiiClassic: return L("Wii Classic Controller")
    case .wiiSideways: return L("Wii Remote Sideways")
    }
  }

  var kind: PlayerState.Kind { self == .gameCube ? .gameCube : .wiiRemote }

  /// `WiimoteSlotOptions` numbering: 0 None, 1 Nunchuk, 2 Classic.
  var wiiExtension: Int {
    switch self {
    case .wiiNunchuk: return 1
    case .wiiClassic: return 2
    default: return 0
    }
  }

  var isSideways: Bool { self == .wiiSideways }

  /// The extension wins over sideways: a sideways remote with a Nunchuk is not a thing the UI offers,
  /// so a stored Nunchuk + Sideways reads as Nunchuk (`PlaysAsTransition` clears the hidden flag).
  init(kind: PlayerState.Kind, wiiExtension: Int, isSideways: Bool) {
    switch (kind, wiiExtension, isSideways) {
    case (.gameCube, _, _): self = .gameCube
    case (.wiiRemote, 1, _): self = .wiiNunchuk
    case (.wiiRemote, 2, _): self = .wiiClassic
    case (.wiiRemote, _, true): self = .wiiSideways
    default: self = .wiiRemote
    }
  }

  /// A Wii-only list has no GameCube ports, so no GameCube Controller; a GameCube title has only
  /// GameCube ports; a Wii title that also takes GameCube ports (or Settings with every port)
  /// offers everything, Wii first.
  static func options(for system: ControllerSetupSystem) -> [PlaysAs] {
    switch system {
    case .gamecube: return [.gameCube]
    case .wii: return [.wiiRemote, .wiiNunchuk, .wiiClassic, .wiiSideways]
    case .both, .wiiAndGameCube: return [.wiiRemote, .wiiNunchuk, .wiiClassic, .wiiSideways, .gameCube]
    }
  }

  static func current(of player: PlayerState) -> PlaysAs {
    PlaysAs(kind: player.kind, wiiExtension: player.wiiExtension, isSideways: player.isSideways)
  }
}
```

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit**

```bash
git add Common/Swift/Controllers/Hub/PlaysAs.swift DolphiniOSTests/PlaysAsTests.swift
git commit -m "feat(controllers): PlaysAs value for slot kind, extension and sideways"
```

---

### Task 2: `PlaysAsTransition`

Rulings that apply here: **H13** a stored Nunchuk/Classic + Sideways reads as the extension, and a transition to any non-sideways Wii target clears the sideways flag explicitly, including when the target equals the value it reads as.

**Files:**
- Create: `Hub/PlaysAsTransition.swift`
- Test: create `DolphiniOSTests/PlaysAsTransitionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum PlaysAsStep: Equatable {
    case setExtension(wiimote: Int, value: Int)
    case setSideways(wiimote: Int, enabled: Bool)
    /// Assign `qualifier` to `to` first, then clear `from`; both 1-based ports.
    case moveDevice(qualifier: String, from: PlayerSlot, to: PlayerSlot)
    case clearSlot(PlayerSlot)
  }
  enum PlaysAsTransition {
    static func plan(from player: PlayerState, to target: PlaysAs) -> [PlaysAsStep]
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// DolphiniOSTests/PlaysAsTransitionTests.swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class PlaysAsTransitionTests: XCTestCase {
  private let pad = "MFi/0/Xbox Wireless Controller"

  private func wii(_ port: Int, ext: Int = 0, sideways: Bool = false, device: String? = nil) -> PlayerState {
    PlayerState(kind: .wiiRemote, port: port, deviceQualifier: device ?? pad, wiiExtension: ext, isSideways: sideways)
  }

  private func gc(_ port: Int, device: String? = nil) -> PlayerState {
    PlayerState(kind: .gameCube, port: port, deviceQualifier: device ?? pad, wiiExtension: 0, isSideways: false)
  }

  func test_sameValue_isNoOp() {
    XCTAssertEqual(PlaysAsTransition.plan(from: wii(1, ext: 1), to: .wiiNunchuk), [])
    XCTAssertEqual(PlaysAsTransition.plan(from: wii(1, sideways: true), to: .wiiSideways), [])
  }

  func test_wiiToWii_changesExtensionAndSidewaysOnly() {
    XCTAssertEqual(PlaysAsTransition.plan(from: wii(2), to: .wiiClassic), [.setExtension(wiimote: 2, value: 2), .setSideways(wiimote: 2, enabled: false)])
    XCTAssertEqual(PlaysAsTransition.plan(from: wii(2, ext: 2), to: .wiiSideways), [.setExtension(wiimote: 2, value: 0), .setSideways(wiimote: 2, enabled: true)])
  }

  func test_storedNunchukPlusSideways_readsAsNunchuk_andEveryNonSidewaysTargetClearsTheFlag() {
    let hidden = wii(1, ext: 1, sideways: true)
    XCTAssertEqual(PlaysAs.current(of: hidden), .wiiNunchuk)
    XCTAssertEqual(PlaysAsTransition.plan(from: hidden, to: .wiiNunchuk), [.setExtension(wiimote: 1, value: 1), .setSideways(wiimote: 1, enabled: false)],
                   "the target equals what the player reads as, but the hidden flag is still cleared")
    XCTAssertEqual(PlaysAsTransition.plan(from: hidden, to: .wiiClassic), [.setExtension(wiimote: 1, value: 2), .setSideways(wiimote: 1, enabled: false)])
    XCTAssertEqual(PlaysAsTransition.plan(from: hidden, to: .wiiRemote), [.setExtension(wiimote: 1, value: 0), .setSideways(wiimote: 1, enabled: false)])
  }

  func test_wiiToGameCube_movesTheDeviceToTheSamePortNumber() {
    XCTAssertEqual(PlaysAsTransition.plan(from: wii(3, ext: 1), to: .gameCube), [
      .moveDevice(qualifier: pad, from: PlayerSlot(kind: .wiiRemote, port: 3), to: PlayerSlot(kind: .gameCube, port: 3)),
    ])
  }

  func test_gameCubeToWii_movesThenSetsExtensionAndSideways() {
    XCTAssertEqual(PlaysAsTransition.plan(from: gc(1), to: .wiiNunchuk), [
      .moveDevice(qualifier: pad, from: PlayerSlot(kind: .gameCube, port: 1), to: PlayerSlot(kind: .wiiRemote, port: 1)),
      .setExtension(wiimote: 1, value: 1),
      .setSideways(wiimote: 1, enabled: false),
    ])
  }

  func test_unboundPort_changingKind_clearsTheOldSlotOnly() {
    XCTAssertEqual(PlaysAsTransition.plan(from: wii(4, device: ""), to: .gameCube), [
      .clearSlot(PlayerSlot(kind: .wiiRemote, port: 4)),
    ])
  }
}
```

- [ ] **Step 2: Regenerate, run, verify failure.**

- [ ] **Step 3: Implement**

```swift
// Hub/PlaysAsTransition.swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum PlaysAsStep: Equatable {
  case setExtension(wiimote: Int, value: Int)
  case setSideways(wiimote: Int, enabled: Bool)
  /// Assign `qualifier` to `to` FIRST, then clear `from`, so a refused assignment leaves the
  /// player as they were.
  case moveDevice(qualifier: String, from: PlayerSlot, to: PlayerSlot)
  case clearSlot(PlayerSlot)
}

/// The ordered writes a Plays as change needs. Pure, so the order is tested; the view model runs
/// them through `ControllerHubWriting`.
enum PlaysAsTransition {
  static func plan(from player: PlayerState, to target: PlaysAs) -> [PlaysAsStep] {
    let current = PlaysAs.current(of: player)
    // A stored Nunchuk/Classic + Sideways reads as the extension (`PlaysAs.init`); a Wii target
    // still clears the hidden flag, even when it equals what the player reads as.
    let hasHiddenSideways = player.kind == .wiiRemote && player.isSideways && !current.isSideways
    guard current != target || (hasHiddenSideways && target.kind == .wiiRemote) else { return [] }
    var steps: [PlaysAsStep] = []
    let from = PlayerSlot(kind: player.kind, port: player.port)
    let to = PlayerSlot(kind: target.kind, port: player.port)
    if from.kind != to.kind {
      if player.isBound {
        steps.append(.moveDevice(qualifier: player.deviceQualifier, from: from, to: to))
      } else {
        steps.append(.clearSlot(from))
      }
    }
    if target.kind == .wiiRemote {
      steps.append(.setExtension(wiimote: player.port, value: target.wiiExtension))
      steps.append(.setSideways(wiimote: player.port, enabled: target.isSideways))
    }
    return steps
  }
}
```

- [ ] **Step 4: Run to verify pass.**

- [ ] **Step 5: Commit**

```bash
git add Common/Swift/Controllers/Hub/PlaysAsTransition.swift DolphiniOSTests/PlaysAsTransitionTests.swift
git commit -m "feat(controllers): ordered steps for a Plays as change"
```

---

### Task 3: Write seam, reader additions, settle, view model setters

Rulings that apply here (restated; you will not see the rest of the plan): **H2** this task must compile and pass on its own: `ControllerHubActions` KEEPS `moreSettingsDestination` (Task 4 removes it together with the builder change and the builder test helper), `lightsDestination` returns an `EmptyView` placeholder until Task 6, and every conformer of `ControllerHubReading` is updated (`ControllerHubViewModelTests.FakeReader` AND `PlayerScreenViewModelTests.FakeHubReader`) with all new requirements, `pointerIsThisGameOnly` included, and `ControllerHubModelBuilderTests.actions(...)` gets the new closures. **H3** `LiveControllerHubWriter.assign` delegates to `PlayerScreenIO.setDevice` (no duplicated touchscreen/pad branches) and returns whether the binding actually took (re-read the bound device for that slot); `clear` uses the existing `clearDefaultDevice(forWiimote:/forGCPort:)` through `PlayerScreenIO.setDevice(.noDevice, ...)`, which unpins; there is NO new `ControllerManager.clear(port:system:)`. A Plays as move into an occupied destination port is refused with a toast ("<port> is in use"): moving would overwrite that port's device. **H4** Device, Plays as and Layout changes are committed after a 0.6 s settle with no further change (injectable scheduler), the row shows the pending value at once, a pending change is flushed on disappear. **H5** after a Plays as change moves a player between Wii and GameCube, the view model requests focus on the moved row by id (`<kind>-N-plays-as`). **H8** `PlayerState.isPinned/motionPointerEnabled` are filled from the same `PlayerScreenIO` reads `PlayerScreenState` uses (one source: the IO). **H9** the Plays as extension/sideways path marks the profile edited exactly as `PlayerScreenViewModel` does. **H12** `rumble_destination` becomes one key constant plus a small enum (0/1/2, default 1) used by reader, writer and fakes; toasts use `EmulationToast.post`; the writer's `nonisolated init` carries the swiftlint comment its siblings carry; new `L()` keys go into Core.strings. **H14** no vacuous tests: `setDevice` asserts the reload, the settle and refusal paths are tested. **H15** on a step failure the view model stops, re-reads state and toasts; it does NOT replay inverse steps. **H18** no attribution trailers.

**Files:**
- Create: `Hub/ControllerHubWriting.swift`
- Create: `Common/Swift/Controllers/RumbleTest.swift` (the Test Rumble pulse, moved out of `ControllerMoreSettingsView`, which then calls it; this keeps the task compiling and puts no iOS-only type in the writer's way)
- Modify: `Hub/ControllerHubState.swift` (`PlayerState`, `ConnectedPadState`, `RumbleDestination`, `PendingHubChanges`, `ControllerHubState`, `ControllerHubActions`)
- Modify: `Hub/ControllerHubViewModel.swift` (`ControllerHubReading`, `LiveControllerHubReader`, scheduler, `reload`, `actions`, new methods)
- Modify: `Player/PlayerScreenViewModel.swift` (`readPlayer` fills the two new `PlayerState` fields from `io`)
- Modify: `Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift` (its Test Rumble button calls `RumbleTest.run()`)
- Modify: `Common/UI/Localization/en.lproj/Core.strings`, `ja.lproj/Core.strings`
- Test: `DolphiniOSTests/ControllerHubViewModelTests.swift`; also `DolphiniOSTests/PlayerScreenViewModelTests.swift` (`FakeHubReader`) and `DolphiniOSTests/ControllerHubModelBuilderTests.swift` (`actions(...)` helper only)

**Interfaces:**
- Produces:
  ```swift
  @MainActor protocol ControllerHubWriting {
    func setDevice(_ choice: PlayerDeviceChoice, slot: PlayerSlot)
    /// True only when the slot's bound device now matches `qualifier` (re-read after the write).
    func assign(qualifier: String, slot: PlayerSlot) -> Bool
    func clear(slot: PlayerSlot)
    func setExtension(_ value: Int, wiimote: Int)
    func setSideways(_ enabled: Bool, wiimote: Int)
    func setPointerMode(_ mode: PointerMode)
    func setMotionPointer(_ enabled: Bool, wiimote: Int)
    func setOverlayMode(_ mode: ControllerManager.OverlayMode)
    func setBackgroundInput(_ enabled: Bool)
    func setRumbleDestination(_ value: RumbleDestination)
    func setConnectTakesPlayer1(_ enabled: Bool)
    func testRumble()
    func resetOverlayLayouts()
    func setTouchOverlayProgrammatic(_ enabled: Bool)
  }
  struct LiveControllerHubWriter: ControllerHubWriting

  enum RumbleDestination: Int, CaseIterable { case deviceHaptics = 0, controller = 1, both = 2 }
  //   static let defaultsKey = "rumble_destination"   (also read natively: Source/Core/InputCommon/ControllerInterface/iOS/Motor.mm)
  //   static let `default`: RumbleDestination = .controller
  //   var title: String
  //   static func stored(in defaults: UserDefaults = .standard) -> RumbleDestination

  struct PendingHubChanges: Equatable {
    var devices: [String: PlayerDeviceChoice] = [:]   // by PlayerState.id
    var playsAs: [String: PlaysAs] = [:]              // by PlayerState.id
    var overlayMode: ControllerManager.OverlayMode?
    var isEmpty: Bool
  }

  // ControllerHubReading gains:
  func isPinned(_ slot: PlayerSlot) -> Bool
  func isMotionPointerEnabled(wiimote: Int) -> Bool
  func pointerMode() -> PointerMode
  func pointerIsThisGameOnly() -> Bool
  func backgroundInput() -> Bool
  func rumbleDestination() -> RumbleDestination
  func connectTakesPlayer1() -> Bool
  func touchOverlayProgrammatic() -> Bool
  // PlayerState gains: var isPinned = false; var motionPointerEnabled = false; var title: String (extension)
  // ConnectedPadState gains: var hasLight = false
  // ControllerHubState gains: pointerMode: PointerMode, pointerIsThisGameOnly: Bool, backgroundInput: Bool,
  //   rumbleDestination: RumbleDestination, connectTakesPlayer1: Bool, touchOverlayProgrammatic: Bool,
  //   pending: PendingHubChanges, focusRequest: String?
  // ControllerHubActions gains:
  var setDevice: (PlayerState, PlayerDeviceChoice) -> Void      // wired to chooseDevice (settles)
  var setPlaysAs: (PlayerState, PlaysAs) -> Void                // wired to choosePlaysAs (settles)
  var setPointerMode: (PointerMode) -> Void
  var setMotionPointer: (PlayerState, Bool) -> Void
  var setBackgroundInput: (Bool) -> Void
  var setRumbleDestination: (RumbleDestination) -> Void
  var setConnectTakesPlayer1: (Bool) -> Void
  var testRumble: () -> Void
  var setTouchOverlayProgrammatic: (Bool) -> Void
  var resetOverlayLayouts: () -> Void
  var lightsDestination: () -> AnyView                          // EmptyView placeholder until Task 6
  // existing `setOverlayMode` is re-wired to chooseOverlayMode (settles); `moreSettingsDestination` is KEPT until Task 4.

  @MainActor protocol ControllerHubScheduling {
    /// Runs `work` once after `delay` seconds. The returned closure cancels it.
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void
  }
  struct MainQueueHubScheduler: ControllerHubScheduling
  // ControllerHubViewModel gains:
  static let settleDelay: TimeInterval = 0.6
  func chooseDevice(_ player: PlayerState, _ choice: PlayerDeviceChoice)
  func choosePlaysAs(_ player: PlayerState, _ target: PlaysAs)
  func chooseOverlayMode(_ mode: ControllerManager.OverlayMode)
  func flushPending()
  func setDevice(_ player: PlayerState, _ choice: PlayerDeviceChoice)   // the committing write
  func setPlaysAs(_ player: PlayerState, _ target: PlaysAs)             // the committing write
  func setOverlayMode(_ mode: ControllerManager.OverlayMode)            // the committing write
  ```

- [ ] **Step 1: Write the failing tests** (in `ControllerHubViewModelTests`).

Extend `FakeReader` with the new reads, stored and defaulted: `pointerMode = .touchFollow`, `pointerThisGameOnly = false`, `backgroundInput = false`, `rumble: RumbleDestination = .controller`, `connectTakesPlayer1 = true`, `touchOverlayProgrammatic = true`, `pinned: Set<String> = []` (player ids), `motion: Set<Int> = []` (wiimote ports), with `isPinned(_ slot:)` returning `pinned.contains(slot.playerID)`.

In `PlayerScreenViewModelTests.swift`, `FakeHubReader` (the private class at the top) conforms to `ControllerHubReading` too: add the eight new requirements as constant stubs (`false`, `.touchFollow`, `.controller`, `true`...). In `ControllerHubModelBuilderTests`, the `actions(...)` helper gains the eleven new closures with no-op defaults and a `setOverlayMode` it already has; it keeps `moreSettingsDestination`.

Add to `ControllerHubViewModelTests`:

```swift
  @MainActor
  private final class FakeScheduler: ControllerHubScheduling {
    private final class Job {
      let delay: TimeInterval
      let work: @MainActor () -> Void
      var isCancelled = false
      init(delay: TimeInterval, work: @escaping @MainActor () -> Void) { self.delay = delay; self.work = work }
    }
    private var jobs: [Job] = []
    /// Delays of the jobs that are scheduled and not cancelled.
    var liveDelays: [TimeInterval] { jobs.filter { !$0.isCancelled }.map(\.delay) }
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
      let job = Job(delay: delay, work: work)
      jobs.append(job)
      return { job.isCancelled = true }
    }
    /// Runs every live job once, as the settle delay elapsing would.
    func fire() {
      let due = jobs.filter { !$0.isCancelled }
      jobs.removeAll()
      due.forEach { $0.work() }
    }
  }

  /// Writes land in the fake reader, as the real config does, so `reload()` shows them.
  @MainActor
  private final class FakeWriter: ControllerHubWriting {
    private let reader: FakeReader
    var log: [String] = []
    var refuseAssign = false
    init(reader: FakeReader) { self.reader = reader }

    private func bind(_ qualifier: String, _ slot: PlayerSlot) {
      if slot.kind == .gameCube { reader.gameCube[slot.port] = qualifier } else { reader.wii[slot.port] = qualifier }
    }
    func setDevice(_ choice: PlayerDeviceChoice, slot: PlayerSlot) {
      log.append("setDevice \(choice) \(slot.playerID)")
      switch choice {
      case .noDevice: bind("", slot)
      case .touchscreen: bind("iOS/4/Touchscreen", slot)
      case .pad(let qualifier): bind(qualifier, slot)
      case .automatic: break
      }
    }
    func assign(qualifier: String, slot: PlayerSlot) -> Bool {
      log.append("assign \(qualifier) \(slot.playerID)")
      guard !refuseAssign else { return false }
      bind(qualifier, slot)
      return true
    }
    func clear(slot: PlayerSlot) { log.append("clear \(slot.playerID)"); bind("", slot) }
    func setExtension(_ value: Int, wiimote: Int) { log.append("ext \(wiimote) \(value)") }
    func setSideways(_ enabled: Bool, wiimote: Int) { log.append("side \(wiimote) \(enabled)") }
    func setPointerMode(_ mode: PointerMode) { log.append("pointer \(mode)") }
    func setMotionPointer(_ enabled: Bool, wiimote: Int) { log.append("motion \(wiimote) \(enabled)") }
    func setOverlayMode(_ mode: ControllerManager.OverlayMode) { log.append("layout \(mode)") }
    func setBackgroundInput(_ enabled: Bool) { log.append("bg \(enabled)") }
    func setRumbleDestination(_ value: RumbleDestination) { log.append("rumble \(value)") }
    func setConnectTakesPlayer1(_ enabled: Bool) { log.append("takes \(enabled)") }
    func testRumble() { log.append("testRumble") }
    func resetOverlayLayouts() { log.append("resetLayouts") }
    func setTouchOverlayProgrammatic(_ enabled: Bool) { log.append("programmatic \(enabled)") }
  }

  private static let xbox = "MFi/0/Xbox Wireless Controller"
  private static let touch = "iOS/4/Touchscreen"

  @MainActor
  private func makeModel(
    system: ControllerSetupSystem = .wiiAndGameCube, reader: FakeReader, writer: FakeWriter, scheduler: FakeScheduler = FakeScheduler(),
    memory: PlayerProfileMemory = PlayerProfileMemory()
  ) -> ControllerHubViewModel {
    let model = ControllerHubViewModel(
      system: system, reader: reader, writer: writer, scheduler: scheduler, memory: memory, notificationCenter: NotificationCenter())
    model.reload()
    return model
  }

  /// The texts posted as toasts while `body` runs.
  @MainActor
  private func toasts(during body: () -> Void) -> [String] {
    var seen: [String] = []
    let token = NotificationCenter.default.addObserver(forName: .dolShowSnackbar, object: nil, queue: nil) { note in
      seen.append(note.userInfo?[EmulationToast.textKey] as? String ?? "")
    }
    defer { NotificationCenter.default.removeObserver(token) }
    body()
    return seen
  }

  // MARK: Plays as

  @MainActor
  func test_setPlaysAs_wiiToGameCube_assignsThenClears_andReloads() {
    let reader = FakeReader()
    reader.wii[1] = Self.xbox
    let writer = FakeWriter(reader: reader)
    let model = makeModel(reader: reader, writer: writer)
    model.setPlaysAs(model.state.players[0], .gameCube)
    XCTAssertEqual(writer.log, ["assign \(Self.xbox) gc-1", "clear wii-1"])
    XCTAssertEqual(model.state.players.first { $0.id == "gc-1" }?.deviceQualifier, Self.xbox, "reloaded: the pad now sits on the GameCube port")
    XCTAssertEqual(model.state.players.first { $0.id == "wii-1" }?.deviceQualifier, "")
  }

  @MainActor
  func test_setPlaysAs_movingBetweenWiiAndGameCube_requestsFocusOnTheMovedRow() {
    let reader = FakeReader()
    reader.wii[1] = Self.xbox
    let model = makeModel(reader: reader, writer: FakeWriter(reader: reader))
    model.setPlaysAs(model.state.players[0], .gameCube)
    XCTAssertEqual(model.state.focusRequest, "gc-1-plays-as")
    let moved = model.state.players.first { $0.id == "gc-1" }!
    model.setPlaysAs(moved, .wiiClassic)
    XCTAssertEqual(model.state.focusRequest, "wii-1-plays-as")
    model.reload()
    XCTAssertNil(model.state.focusRequest, "a request is one-shot: the next reload drops it")
  }

  @MainActor
  func test_setPlaysAs_wiiToWii_requestsNoFocusMove() {
    let reader = FakeReader()
    reader.wii[1] = Self.xbox
    let model = makeModel(reader: reader, writer: FakeWriter(reader: reader))
    model.setPlaysAs(model.state.players[0], .wiiNunchuk)
    XCTAssertNil(model.state.focusRequest, "the row keeps its id")
  }

  @MainActor
  func test_setPlaysAs_refusedAssign_leavesTheOldSlotAlone_andToasts() {
    let reader = FakeReader()
    reader.wii[1] = Self.xbox
    let writer = FakeWriter(reader: reader)
    writer.refuseAssign = true
    let model = makeModel(reader: reader, writer: writer)
    let seen = toasts { model.setPlaysAs(model.state.players[0], .gameCube) }
    XCTAssertEqual(writer.log, ["assign \(Self.xbox) gc-1"], "no clear after a refused assignment")
    XCTAssertEqual(model.state.players[0].deviceQualifier, Self.xbox, "state re-read: the Wii Remote still has the pad")
    XCTAssertEqual(seen, ["Couldn't move the controller"])
    XCTAssertNil(model.state.focusRequest)
  }

  @MainActor
  func test_setPlaysAs_intoAnOccupiedPort_isRefusedBeforeAnyWrite() {
    let reader = FakeReader()
    reader.wii[1] = Self.xbox
    reader.gameCube[1] = "MFi/1/DualSense Wireless Controller"
    let writer = FakeWriter(reader: reader)
    let model = makeModel(reader: reader, writer: writer)
    let seen = toasts { model.setPlaysAs(model.state.players[0], .gameCube) }
    XCTAssertEqual(writer.log, [], "moving would overwrite Player 1's device")
    XCTAssertEqual(seen, ["Player 1 is in use"])
    XCTAssertEqual(model.state.players.first { $0.id == "gc-1" }?.deviceQualifier, "MFi/1/DualSense Wireless Controller")
  }

  @MainActor
  func test_setPlaysAs_gameCubeToNunchuk_movesThenSetsExtension() {
    let reader = FakeReader()
    reader.gameCube[2] = Self.touch
    let writer = FakeWriter(reader: reader)
    let model = makeModel(reader: reader, writer: writer)
    let gc2 = model.state.players.first { $0.id == "gc-2" }!
    model.setPlaysAs(gc2, .wiiNunchuk)
    XCTAssertEqual(writer.log, ["assign \(Self.touch) wii-2", "clear gc-2", "ext 2 1", "side 2 false"])
  }

  /// Ruling H9: the profile shows "(edited)" after an extension change, as on the player screen.
  @MainActor
  func test_setPlaysAs_extensionChange_marksTheProfileEdited() {
    let reader = FakeReader()
    reader.wii[1] = Self.xbox
    let memory = PlayerProfileMemory()
    memory.remember("Physical Controller", for: "wii-1", qualifier: Self.xbox)
    let model = makeModel(reader: reader, writer: FakeWriter(reader: reader), memory: memory)
    model.setPlaysAs(model.state.players[0], .wiiNunchuk)
    XCTAssertEqual(memory.entry(for: "wii-1", qualifier: Self.xbox)?.edited, true)
  }

  // MARK: Settle (ruling H4)

  @MainActor
  func test_chooseDevice_writesNothingUntilTheSettleDelayElapses_andShowsTheChoiceAtOnce() {
    let reader = FakeReader()
    reader.gameCube[1] = Self.xbox
    let writer = FakeWriter(reader: reader)
    let scheduler = FakeScheduler()
    let model = makeModel(system: .gamecube, reader: reader, writer: writer, scheduler: scheduler)
    model.chooseDevice(model.state.players[0], .touchscreen)
    XCTAssertEqual(writer.log, [])
    XCTAssertEqual(model.state.pending.devices["gc-1"], .touchscreen, "the row shows the pending value")
    XCTAssertEqual(scheduler.liveDelays, [ControllerHubViewModel.settleDelay])
    scheduler.fire()
    XCTAssertEqual(writer.log, ["setDevice touchscreen gc-1"])
    XCTAssertTrue(model.state.pending.isEmpty)
    XCTAssertEqual(model.state.players[0].deviceQualifier, Self.touch, "reloaded after the commit")
  }

  @MainActor
  func test_rapidChoices_commitOnlyTheLast_andRestartTheDelay() {
    let reader = FakeReader()
    reader.gameCube[1] = Self.xbox
    let writer = FakeWriter(reader: reader)
    let scheduler = FakeScheduler()
    let model = makeModel(system: .gamecube, reader: reader, writer: writer, scheduler: scheduler)
    let player = model.state.players[0]
    model.chooseDevice(player, .noDevice)
    model.chooseDevice(player, .touchscreen)
    model.chooseDevice(player, .pad("MFi/1/DualSense Wireless Controller"))
    XCTAssertEqual(scheduler.liveDelays.count, 1, "each choice cancels the previous timer")
    scheduler.fire()
    XCTAssertEqual(writer.log, ["setDevice pad(\"MFi/1/DualSense Wireless Controller\") gc-1"], "None and Touchscreen were never written")
  }

  @MainActor
  func test_choosingTheCommittedValueAgain_cancelsThePendingChange() {
    let reader = FakeReader()
    reader.gameCube[1] = Self.xbox
    let writer = FakeWriter(reader: reader)
    let scheduler = FakeScheduler()
    let model = makeModel(system: .gamecube, reader: reader, writer: writer, scheduler: scheduler)
    let player = model.state.players[0]
    model.chooseDevice(player, .touchscreen)
    model.chooseDevice(player, .pad(Self.xbox))
    XCTAssertTrue(model.state.pending.isEmpty)
    XCTAssertEqual(scheduler.liveDelays, [])
    scheduler.fire()
    XCTAssertEqual(writer.log, [])
  }

  /// The Layout GameCube-to-Auto trap: Wii must never be written on the way.
  @MainActor
  func test_layoutCycledThroughWii_writesOnlyTheFinalMode() {
    let reader = FakeReader()   // committed mode: .wii
    let writer = FakeWriter(reader: reader)
    let scheduler = FakeScheduler()
    let model = makeModel(system: .wii, reader: reader, writer: writer, scheduler: scheduler)
    model.chooseOverlayMode(.auto)
    model.chooseOverlayMode(.gamecube)
    model.chooseOverlayMode(.auto)
    XCTAssertEqual(model.state.pending.overlayMode, .auto)
    scheduler.fire()
    XCTAssertEqual(writer.log, ["layout auto"])
  }

  /// A pad that moves to Touchscreen and then plays as GameCube: the plays-as commit must see the
  /// device the first commit wrote, not the snapshot taken when the player was chosen.
  @MainActor
  func test_commit_runsDeviceBeforePlaysAs_andPlaysAsSeesTheNewDevice() {
    let reader = FakeReader()
    reader.wii[1] = Self.xbox
    let writer = FakeWriter(reader: reader)
    let scheduler = FakeScheduler()
    let model = makeModel(reader: reader, writer: writer, scheduler: scheduler)
    let player = model.state.players[0]
    model.chooseDevice(player, .touchscreen)
    model.choosePlaysAs(player, .gameCube)
    scheduler.fire()
    XCTAssertEqual(writer.log, ["setDevice touchscreen wii-1", "assign \(Self.touch) gc-1", "clear wii-1"])
  }

  @MainActor
  func test_stop_flushesAPendingChange() {
    let reader = FakeReader()
    reader.gameCube[1] = Self.xbox
    let writer = FakeWriter(reader: reader)
    let model = makeModel(system: .gamecube, reader: reader, writer: writer)
    model.chooseDevice(model.state.players[0], .touchscreen)
    model.stop()
    XCTAssertEqual(writer.log, ["setDevice touchscreen gc-1"], "a pushed player screen must see the committed device")
    XCTAssertTrue(model.state.pending.isEmpty)
  }

  // MARK: Reads and setup writes

  @MainActor
  func test_setDevice_goesThroughTheWriter_andReloads() {
    let reader = FakeReader()
    let writer = FakeWriter(reader: reader)
    let model = makeModel(system: .gamecube, reader: reader, writer: writer)
    XCTAssertEqual(model.state.players[0].deviceQualifier, "")
    model.setDevice(model.state.players[0], .touchscreen)
    XCTAssertEqual(writer.log, ["setDevice touchscreen gc-1"])
    XCTAssertEqual(model.state.players[0].deviceQualifier, Self.touch, "the snapshot was re-read after the write")
  }

  @MainActor
  func test_reload_snapshotsPointerAndSetup() {
    let reader = FakeReader()
    reader.pointerMode = .gyro
    reader.pointerThisGameOnly = true
    reader.motion = [2]
    reader.pinned = ["gc-1"]
    reader.rumble = .both
    reader.backgroundInput = true
    let model = makeModel(reader: reader, writer: FakeWriter(reader: reader))
    XCTAssertEqual(model.state.pointerMode, .gyro)
    XCTAssertTrue(model.state.pointerIsThisGameOnly)
    XCTAssertTrue(model.state.players.first { $0.id == "wii-2" }!.motionPointerEnabled)
    XCTAssertFalse(model.state.players.first { $0.id == "wii-3" }!.motionPointerEnabled)
    XCTAssertTrue(model.state.players.first { $0.id == "gc-1" }!.isPinned)
    XCTAssertEqual(model.state.rumbleDestination, .both)
    XCTAssertTrue(model.state.backgroundInput)
  }

  @MainActor
  func test_setupAndPointerActions_writeThroughTheWriter() {
    let reader = FakeReader()
    let writer = FakeWriter(reader: reader)
    let model = makeModel(reader: reader, writer: writer)
    let wii2 = model.state.players.first { $0.id == "wii-2" }!
    model.actions.setPointerMode(.gyro)
    model.actions.setMotionPointer(wii2, true)
    model.actions.setBackgroundInput(true)
    model.actions.setRumbleDestination(.both)
    model.actions.setConnectTakesPlayer1(false)
    model.actions.setTouchOverlayProgrammatic(false)
    model.actions.testRumble()
    model.actions.resetOverlayLayouts()
    XCTAssertEqual(writer.log, ["pointer gyro", "motion 2 true", "bg true", "rumble both", "takes false", "programmatic false", "testRumble", "resetLayouts"])
  }

  func test_rumbleDestination_defaultsToController_andReadsTheStoredValue() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "RumbleDestinationTests"))
    defaults.removePersistentDomain(forName: "RumbleDestinationTests")
    XCTAssertEqual(RumbleDestination.stored(in: defaults), .controller)
    defaults.set(2, forKey: RumbleDestination.defaultsKey)
    XCTAssertEqual(RumbleDestination.stored(in: defaults), .both)
    defaults.set(9, forKey: RumbleDestination.defaultsKey)
    XCTAssertEqual(RumbleDestination.stored(in: defaults), .controller, "an unknown value falls back to the default")
    defaults.removePersistentDomain(forName: "RumbleDestinationTests")
  }
```
Existing tests that construct `ControllerHubViewModel(system:reader:notificationCenter:)` keep compiling: `writer`, `scheduler` and `memory` have defaults.

- [ ] **Step 2: Regenerate, run, verify failure.**

- [ ] **Step 3: Small types: `RumbleDestination`, `PendingHubChanges`, `PlayerState` additions, Test Rumble extraction**

In `Hub/ControllerHubState.swift`:

```swift
/// Where a game's rumble goes. The raw values are stored under `defaultsKey` and read natively by
/// `Source/Core/InputCommon/ControllerInterface/iOS/Motor.mm`: do not renumber.
enum RumbleDestination: Int, CaseIterable {
  case deviceHaptics = 0
  case controller = 1
  case both = 2

  static let defaultsKey = "rumble_destination"
  static let `default`: RumbleDestination = .controller

  var title: String {
    switch self {
    case .deviceHaptics: return L("Device Haptics")
    case .controller: return L("Controller")
    case .both: return L("Both")
    }
  }

  static func stored(in defaults: UserDefaults = .standard) -> RumbleDestination {
    (defaults.object(forKey: defaultsKey) as? Int).flatMap(RumbleDestination.init(rawValue:)) ?? .default
  }
}

/// Choices the player made that the view model has not written yet (ruling H4). The builder shows
/// them in place of the stored values; the view model commits them after the settle delay.
struct PendingHubChanges: Equatable {
  var devices: [String: PlayerDeviceChoice] = [:]
  var playsAs: [String: PlaysAs] = [:]
  var overlayMode: ControllerManager.OverlayMode?

  var isEmpty: Bool { devices.isEmpty && playsAs.isEmpty && overlayMode == nil }
}
```
`PlayerState` gains `var isPinned = false`, `var motionPointerEnabled = false` (defaulted so the memberwise calls in tests compile) and, next to `id`:
```swift
  /// "Player 1" / "Wii Remote 1".
  var title: String { String(format: kind == .gameCube ? L("Player %d") : L("Wii Remote %d"), port) }
```
(The builder keeps its private `title(for:)` until Task 4 switches to `player.title` and deletes it.) `ConnectedPadState` gains `var hasLight = false` after `hasGyro`. `ControllerHubState` gains `pointerMode`, `pointerIsThisGameOnly`, `backgroundInput`, `rumbleDestination`, `connectTakesPlayer1`, `touchOverlayProgrammatic`, `pending = PendingHubChanges()`, `focusRequest: String? = nil`; `empty(system:)` supplies `.touchFollow, false, false, .default, true, true`. `ControllerHubActions` gains the closures listed in Interfaces and keeps `moreSettingsDestination`.

`Common/Swift/Controllers/RumbleTest.swift`: `#if os(iOS)` `import CoreHaptics`, `import GameController`; `enum RumbleTest { static func run() }` whose body is the old `ControllerMoreSettingsView.testRumble()` moved verbatim (including the final toast, but post it with `EmulationToast.post(message)`). In `ControllerMoreSettingsView`, delete `testRumble()` and make the Test Rumble button call `RumbleTest.run()`; drop its now-unused `CoreHaptics` import if nothing else there uses it.

- [ ] **Step 4: The seam**

```swift
// Hub/ControllerHubWriting.swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation
import GameController

/// Everything the hub writes, behind one seam (the mirror of `ControllerHubReading`).
@MainActor
protocol ControllerHubWriting {
  func setDevice(_ choice: PlayerDeviceChoice, slot: PlayerSlot)
  /// True only when the slot's bound device now matches `qualifier`, read back after the write: a
  /// DSU device or a disconnected pad cannot be bound by `PlayerScreenIO.setDevice` (it returns
  /// without binding), and a Plays as move must not clear the old slot then.
  func assign(qualifier: String, slot: PlayerSlot) -> Bool
  /// Unbinds the slot's device and unpins the slot.
  func clear(slot: PlayerSlot)
  func setExtension(_ value: Int, wiimote: Int)
  func setSideways(_ enabled: Bool, wiimote: Int)
  func setPointerMode(_ mode: PointerMode)
  func setMotionPointer(_ enabled: Bool, wiimote: Int)
  func setOverlayMode(_ mode: ControllerManager.OverlayMode)
  func setBackgroundInput(_ enabled: Bool)
  func setRumbleDestination(_ value: RumbleDestination)
  func setConnectTakesPlayer1(_ enabled: Bool)
  func testRumble()
  func resetOverlayLayouts()
  func setTouchOverlayProgrammatic(_ enabled: Bool)
}

struct LiveControllerHubWriter: ControllerHubWriting {
  nonisolated init() {} // swiftlint:disable:this unneeded_synthesized_initializer

  private let io = LivePlayerScreenIO()
  private let reader = LiveControllerHubReader()

  func setDevice(_ choice: PlayerDeviceChoice, slot: PlayerSlot) {
    io.setDevice(choice, slot: slot)
    // Decision 12 (the player screen does the same): the app turns the IMU pointer off on every
    // touchscreen-bound Wii Remote, so a gyro pad taking over would leave its pointer off.
    if slot.kind == .wiiRemote, case .pad(let qualifier) = choice,
       GCController.controllers().first(where: { (TVControllerMappingBridge.qualifiedName(for: $0) as String) == qualifier })?
         .motion?.hasRotationRate == true {
      io.setMotionPointerEnabled(true, wiimote: slot.port)
    }
  }

  func assign(qualifier: String, slot: PlayerSlot) -> Bool {
    let choice = PlayerDeviceChoice(qualifier: qualifier)
    setDevice(choice, slot: slot)
    let bound = slot.kind == .gameCube ? reader.boundQualifier(forGCPort: slot.port) : reader.boundQualifier(forWiimote: slot.port)
    return PlayerDeviceChoice(qualifier: bound) == choice
  }

  func clear(slot: PlayerSlot) { io.setDevice(.noDevice, slot: slot) }

  func setExtension(_ value: Int, wiimote: Int) { WiimoteSlotOptions.setExtension(value, forWiimote: wiimote) }
  func setSideways(_ enabled: Bool, wiimote: Int) { WiimoteSlotOptions.setSideways(enabled, forWiimote: wiimote) }
  func setPointerMode(_ mode: PointerMode) { PointerModeController.shared.set(mode) }
  func setMotionPointer(_ enabled: Bool, wiimote: Int) { io.setMotionPointerEnabled(enabled, wiimote: wiimote) }

  func setOverlayMode(_ mode: ControllerManager.OverlayMode) {
    ControllerManager.shared.overlayMode = mode
    // The top bar's rule: picking a specific style also shows the controls.
    if mode != .auto { ControllerManager.shared.overlayVisible = true }
  }

  func setBackgroundInput(_ enabled: Bool) { DOLConfigBridge.setMainBackgroundInput(enabled) }
  func setRumbleDestination(_ value: RumbleDestination) { UserDefaults.standard.set(value.rawValue, forKey: RumbleDestination.defaultsKey) }
  func setConnectTakesPlayer1(_ enabled: Bool) { UserDefaults.standard.set(enabled, forKey: ControllerManager.connectTakesPlayer1DefaultsKey) }

  func testRumble() {
    #if os(iOS)
    RumbleTest.run()
    #endif
  }

  func resetOverlayLayouts() {
    #if os(iOS)
    for kind in TouchOverlayPadKind.allCases { TouchOverlayLayoutStore.shared.reset(padKind: kind) }
    #endif
  }

  func setTouchOverlayProgrammatic(_ enabled: Bool) {
    #if os(iOS)
    TouchOverlayFlag.isProgrammatic = enabled
    #endif
  }
}
```
`LivePlayerScreenIO` and `LiveControllerHubReader` both have `nonisolated init()`, so they can be stored-property defaults of a type whose own init is `nonisolated`. Why `clear` goes through `io.setDevice(.noDevice, ...)`: that is the existing `ControllerManager.clearDefaultDevice(forWiimote:/forGCPort:)` (assignment cleared AND slot unpinned, then `reconcile(autoAssign: false)`); do not add a new `ControllerManager` method.

- [ ] **Step 5: Reader, state, actions, view model**

`ControllerHubReading` gains the eight reads listed in Interfaces. `LiveControllerHubReader` implements them: `isPinned(_ slot:)` → `LivePlayerScreenIO().isPinned(slot)` and `isMotionPointerEnabled(wiimote:)` → `LivePlayerScreenIO().isMotionPointerEnabled(wiimote:)` (one source: the IO, ruling H8); `pointerMode` → `PointerModeController.shared.mode`; `pointerIsThisGameOnly` → `PointerModeController.shared.isThisGameOnly`; `backgroundInput` → `DOLConfigBridge.mainBackgroundInput()`; `rumbleDestination` → `RumbleDestination.stored()`; `connectTakesPlayer1` → `ControllerManager.connectTakesPlayer1()`; `touchOverlayProgrammatic` → `TouchOverlayFlag.isProgrammatic` on iOS, `false` on tvOS. `connectedPads()` also fills `hasLight: controller.light != nil`.

The scheduler (same file):
```swift
/// Runs deferred work for the settle delay; a protocol so tests fire it by hand.
@MainActor
protocol ControllerHubScheduling {
  /// Runs `work` once after `delay` seconds. The returned closure cancels it.
  func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void
}

struct MainQueueHubScheduler: ControllerHubScheduling {
  nonisolated init() {} // swiftlint:disable:this unneeded_synthesized_initializer

  func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> () -> Void {
    let task = Task { @MainActor in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      work()
    }
    return { task.cancel() }
  }
}
```

`ControllerHubViewModel`:
```swift
  /// How long a Device, Plays as or Layout choice must stand unchanged before it is written
  /// (ruling H4): tap-cycling otherwise writes every value it passes through.
  static let settleDelay: TimeInterval = 0.6

  private let writer: any ControllerHubWriting
  private let scheduler: any ControllerHubScheduling
  private let memory: PlayerProfileMemory
  @ObservationIgnored private var cancelSettle: (() -> Void)?

  init(system: ControllerSetupSystem, reader: any ControllerHubReading = LiveControllerHubReader(),
       writer: any ControllerHubWriting = LiveControllerHubWriter(),
       scheduler: any ControllerHubScheduling = MainQueueHubScheduler(),
       memory: PlayerProfileMemory = .shared, notificationCenter: NotificationCenter = .default)
```
`reload()` keeps `showAllPorts` AND `pending` from the previous state, drops `focusRequest`, and fills the new fields: per player `isPinned: reader.isPinned(slot)` and `motionPointerEnabled: slot.kind == .wiiRemote && reader.isMotionPointerEnabled(wiimote: slot.port)` (set on the `PlayerState` after it is built), plus the hub-level reads.

`stop()` calls `flushPending()` before removing the observers.

```swift
  // MARK: Settling choices (ruling H4)

  func chooseDevice(_ player: PlayerState, _ choice: PlayerDeviceChoice) {
    state.pending.devices[player.id] = choice == PlayerDeviceChoice(qualifier: player.deviceQualifier) ? nil : choice
    settle()
  }

  func choosePlaysAs(_ player: PlayerState, _ target: PlaysAs) {
    state.pending.playsAs[player.id] = target == PlaysAs.current(of: player) ? nil : target
    settle()
  }

  func chooseOverlayMode(_ mode: ControllerManager.OverlayMode) {
    state.pending.overlayMode = mode == state.overlayMode ? nil : mode
    settle()
  }

  /// Restarts the delay; nothing pending, nothing scheduled.
  private func settle() {
    cancelSettle?()
    cancelSettle = nil
    guard !state.pending.isEmpty else { return }
    cancelSettle = scheduler.schedule(after: Self.settleDelay) { [weak self] in self?.commitPending() }
  }

  /// Commits now whatever is pending (the hub is going away: a pushed player screen must see it).
  func flushPending() {
    guard !state.pending.isEmpty else { return }
    commitPending()
  }

  /// Devices first, then Plays as (looked up again by id, so it sees the device just written), then
  /// Layout.
  private func commitPending() {
    cancelSettle?()
    cancelSettle = nil
    let pending = state.pending
    state.pending = PendingHubChanges()
    for (id, choice) in pending.devices.sorted(by: { $0.key < $1.key }) {
      if let player = state.players.first(where: { $0.id == id }) { setDevice(player, choice) }
    }
    for (id, target) in pending.playsAs.sorted(by: { $0.key < $1.key }) {
      if let player = state.players.first(where: { $0.id == id }) { setPlaysAs(player, target) }
    }
    if let mode = pending.overlayMode { setOverlayMode(mode) }
  }

  // MARK: Committing writes

  func setDevice(_ player: PlayerState, _ choice: PlayerDeviceChoice) {
    writer.setDevice(choice, slot: PlayerSlot(kind: player.kind, port: player.port))
    reload()
  }

  /// Announces the choice BEFORE applying it (see `chooseOnScreenControls`).
  func setOverlayMode(_ mode: ControllerManager.OverlayMode) {
    chooseOnScreenControls { writer.setOverlayMode(mode) }
  }

  /// Runs `PlaysAsTransition.plan` in order. On a failing step the view model stops, re-reads state
  /// and toasts; it does not replay inverse steps (ruling H15), so a half-applied change is visible.
  func setPlaysAs(_ player: PlayerState, _ target: PlaysAs) {
    for step in PlaysAsTransition.plan(from: player, to: target) {
      switch step {
      case .setExtension(let wiimote, let value):
        writer.setExtension(value, wiimote: wiimote)
        if value != player.wiiExtension { markEdited(wiimote: wiimote, qualifier: player.deviceQualifier) }
      case .setSideways(let wiimote, let enabled):
        writer.setSideways(enabled, wiimote: wiimote)
        if enabled != player.isSideways { markEdited(wiimote: wiimote, qualifier: player.deviceQualifier) }
      case .clearSlot(let slot):
        writer.clear(slot: slot)
      case .moveDevice(let qualifier, let from, let to):
        // Moving into a port that has a device would overwrite it: refuse before writing anything.
        if let destination = state.players.first(where: { $0.kind == to.kind && $0.port == to.port }), destination.isBound {
          EmulationToast.post(String(format: L("%@ is in use"), destination.title))
          reload()
          return
        }
        guard writer.assign(qualifier: qualifier, slot: to) else {
          EmulationToast.post(L("Couldn't move the controller"))
          reload()
          return
        }
        writer.clear(slot: from)
      }
    }
    reload()
    if target.kind != player.kind {
      state.focusRequest = "\(target.kind == .gameCube ? "gc" : "wii")-\(player.port)-plays-as"
    }
  }

  /// The player screen's `setExtension`/`setSideways` mark the remembered profile edited; the hub
  /// does the same. Any capture is already over: `PlayerScreenViewModel.stop()` ends it when the
  /// player screen leaves, and the hub is only visible then.
  private func markEdited(wiimote: Int, qualifier: String) {
    memory.markEdited(PlayerSlot(kind: .wiiRemote, port: wiimote).playerID, qualifier: qualifier)
  }
```
`actions` wires: `setDevice: { [weak self] in self?.chooseDevice($0, $1) }`, `setPlaysAs: { [weak self] in self?.choosePlaysAs($0, $1) }`, `setOverlayMode: { [weak self] in self?.chooseOverlayMode($0) }` (replacing the inline closure that wrote `ControllerManager` directly), `setPointerMode: { [weak self] mode in self?.writer.setPointerMode(mode); self?.reload() }`, `setMotionPointer: { [weak self] player, on in self?.writer.setMotionPointer(on, wiimote: player.port); self?.reload() }`, the three setup setters likewise (write then reload), `testRumble: { [weak self] in self?.writer.testRumble() }`, `resetOverlayLayouts`, `setTouchOverlayProgrammatic` (the last also reload), and `lightsDestination: { AnyView(EmptyView()) }` (placeholder; Task 6 swaps in the real view). `moreSettingsDestination` is unchanged.

`PlayerScreenViewModel.readPlayer()` (the "same reads as the hub" function): after building the `PlayerState`, set `isPinned = io.isPinned(slot)` and `motionPointerEnabled = slot.kind == .wiiRemote && io.isMotionPointerEnabled(wiimote: slot.port)`; in `makeSnapshot()` pass `player.motionPointerEnabled` and `player.isPinned` to `PlayerScreenState` instead of reading the IO a second time. Existing `PlayerScreenViewModelTests` (`motionPointerEnabled`, `isPinned`) keep passing.

New keys: `Couldn't move the controller`, `%@ is in use` (check with `check_localized_keys.py`; add both to en and ja Core.strings).

- [ ] **Step 6: Build both platforms; run `ControllerHubViewModelTests`, `ControllerHubModelBuilderTests`, `PlayerScreenViewModelTests`** (new tests pass, old ones unchanged).

- [ ] **Step 7: Commit**

```bash
git add Common/Swift/Controllers/Hub/ControllerHubWriting.swift Common/Swift/Controllers/RumbleTest.swift Common/Swift/Controllers/Hub/ControllerHubState.swift Common/Swift/Controllers/Hub/ControllerHubViewModel.swift Common/Swift/Controllers/Player/PlayerScreenViewModel.swift Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift Common/UI/Localization/en.lproj/Core.strings Common/UI/Localization/ja.lproj/Core.strings DolphiniOSTests/ControllerHubViewModelTests.swift DolphiniOSTests/ControllerHubModelBuilderTests.swift DolphiniOSTests/PlayerScreenViewModelTests.swift
git commit -m "feat(controllers): hub write seam, settle delay, Plays as and device setters"
```

---

### Task 4: Hub model — player groups, Touch Controls, Setup, focus-follow

Rulings that apply here (restated): **H1** this is the first task that renders rows; it needs PR 3 Task 1 (list rows render `description`; `.cycle` list rows step with left/right on tvOS and long-press on iOS; `rowLabel` takes value and badge separately). The controller has rebased this branch onto it. **Step 0 verifies that; stop and report if it fails.** **H2** this task removes `moreSettingsDestination` from `ControllerHubActions` together with the builder's `more` section and from the `actions(...)` test helper. **H4** the rows read pending values (`state.pending`). **H5** focus follows a moved row by id: `MenuModel.focusRequest` plus a `reconcile` rule. **H6** the Layout row's description says Auto follows the RUNNING GAME'S SYSTEM and attached pads, not Player 1's Plays as (`EmulationScreen.isWiiSystem`). **H7** the existing builder tests this task breaks are listed below with how each changes. **H8** the Device options and the pointer-mode list are shared statics extracted from `PlayerScreenModelBuilder`, not copies. **H10** unbound ports (listed only under Show All Ports) get the title and Device rows only. **H11** the player title row's badge mirrors its Plays as title. **H12** rumble uses `RumbleDestination`; literal option values are wrapped in `AnyHashable(...)`; new `L()` keys go into Core.strings en/ja. **H14** no vacuous tests: device cycle, setup toggles and pointer toggle assert their writes; add tests for unbound ports skipping rows. **H16** pad A-hold on list rows is not wired; pad users step with left/right. **H18** no attribution trailers.

**Files:**
- Modify: `Hub/ControllerHubModelBuilder.swift` (also its header doc comment: Players / Touch Controls / Connected Devices / Setup / Help)
- Modify: `Hub/ControllerHubState.swift` (remove `moreSettingsDestination`)
- Modify: `Hub/ControllerHubViewModel.swift` (remove the `moreSettingsDestination` wiring; nothing else)
- Modify: `Player/PlayerScreenModelBuilder.swift` (shared statics only: `pointerModes`, `deviceOptions(isPinned:...)`)
- Modify: `Common/Swift/Menu/MenuModel.swift`, `Common/Swift/Menu/MenuFocusRouter.swift`, `Common/Swift/Menu/MenuScreen.swift` (`focusRequest`)
- Modify: `Common/UI/Localization/en.lproj/Core.strings`, `ja.lproj/Core.strings`
- Test: `DolphiniOSTests/ControllerHubModelBuilderTests.swift`, `DolphiniOSTests/MenuFocusRouterTests.swift`, `DolphiniOSTests/PlayerScreenModelBuilderTests.swift` (the shared `deviceOptions` overload only)

**Interfaces:**
- Consumes: Task 1 `PlaysAs`, Task 3 state and actions (`state.pending`, `state.focusRequest`, `ConnectedPadState.hasLight`, `PlayerState.title/isPinned/motionPointerEnabled`, `RumbleDestination`), PR 3 Task 1 menu features.
- Produces: sections `players`, `touch-controls` (iOS), `devices`, `setup`, `help`; row ids per Global Constraints; `MenuModel.focusRequest`; and
  ```swift
  // PlayerScreenModelBuilder
  static let pointerModes: [PointerMode]            // [.touchFollow, .touchDrag, .gyro]
  static func deviceOptions(isPinned: Bool, current: PlayerDeviceChoice, pads: [ConnectedPadState],
                            currentTitle: String, platform: PlatformKind) -> [DeviceOption]
  // MenuModel
  var focusRequest: String?                         // init(sections:focusRequest:), default nil
  // MenuFocusRouter
  static func reconcile(focusedID: String?, previousOrder: [String], model: MenuModel, requestedID: String? = nil) -> String?
  ```

- [ ] **Step 0: Verify the PR 3 Task 1 precondition.** `git log --oneline` shows PR 3's Task 1 commit under this branch, and `grep -n "showsChevron\|footer\|case stepper" Common/Swift/Menu/MenuModel.swift` finds all three. If not, stop and report: do not re-implement them here.

- [ ] **Step 1: Update the tests**

In `ControllerHubModelBuilderTests`, the `actions(...)` helper gets recording parameters for the new closures (`setDevice`, `setPlaysAs`, `setPointerMode`, `setMotionPointer`, `setBackgroundInput`, `setRumbleDestination`, `setConnectTakesPlayer1`, `testRumble`, `setTouchOverlayProgrammatic`, `resetOverlayLayouts`; all defaulting to no-ops, `lightsDestination: { AnyView(EmptyView()) }`) and DROPS `moreSettingsDestination`. The `state(...)` helper gains `isPinned: Set<String> = []` and `pending: PendingHubChanges = PendingHubChanges()` parameters, applied to `hub.players` / `hub.pending`. The real helper names stay (`make`, `ids`, `run`, `state`, `actions`).

Existing tests this task breaks, and how each changes:

| Existing test | Change |
|---|---|
| `test_iOS_sectionOrder` | expects `["players", "touch-controls", "devices", "setup", "help"]` |
| `test_tvOS_hasNoOnScreenControls` | rename `test_tvOS_hasNoTouchControls`; expects `["players", "devices", "setup", "help"]` |
| `test_unboundPorts_collapseUnderShowAllPorts` | expects `["gc-1", "gc-1-device", "show-all-ports"]` |
| `test_showAllPorts_listsEveryPortInTheRunningGamesOrder` | expects `wii-1, wii-1-device, wii-1-plays-as, wii-1-pointer`, then `wii-2, wii-2-device`, `wii-3, wii-3-device`, `wii-4, wii-4-device`, `gc-1, gc-1-device` through `gc-4, gc-4-device`, then `show-all-ports` (unbound ports have no Plays as or Pointer row, H10) |
| `test_everyPortBound_hasNoShowAllRow` | expects `gc-N, gc-N-device` for N = 1...4 (a GameCube title has no Plays as row) and no `show-all-ports` |
| `test_playerRow_namesThePortTheDeviceAndTheEmulatedController` | replaced by `test_playerGroup_...` below |
| `test_playerRow_boundToAPadThatIsGone_saysDisconnected` | asserts `model.item(id: "gc-2-device")?.currentValueTitle == "DualSense Wireless Controller (Disconnected)"` (the subtitle is gone) |
| `test_playerRow_boundToADSUDevice_namesIt` | asserts `gc-2-device` `currentValueTitle == "Pad C"` |
| `test_showHideAndStyleRows_onlyWhileAGameRuns` | section `touch-controls`; running contains `touch-visible` and `touch-layout`; not running (GameCube system) is exactly `["touch-opacity", "touch-editable", "touch-edit-layout", "touch-skins", "touch-reset-layouts"]` |
| `test_showHideToggle_writesThroughTheAction` | id `touch-visible` |
| `test_stylePicker_offersAutoGameCubeWii_andWritesThroughTheAction` | rename `test_layoutCycle_...`; id `touch-layout`, title `Layout`, guard `.cycle` (not `.picker`), option titles `["Auto", "GameCube", "Wii Remote"]` |
| `test_opacityPicker_offersQuarterSteps_andWritesAFraction` | id `touch-opacity`; guard `.cycle` (not `.picker`) |
| `test_editLayout_runsAnAction` | id `touch-edit-layout` |
| `test_skins_pushes_nextToEditLayout` | ids `touch-skins`/`touch-edit-layout`, section `touch-controls` |
| `test_editIRArea_runsAnAction_rightAfterEditLayout_whenTheSystemHasAPointer` | section `touch-controls`; `suffix(4)` is `["touch-edit-layout", "touch-edit-ir-area", "touch-skins", "touch-reset-layouts"]`; id `touch-edit-ir-area` |
| `test_editIRArea_hiddenInAGameCubeGame` | id `touch-edit-ir-area` |
| `test_skins_hiddenOnTvOS` | id `touch-skins`; also assert the `touch-controls` section is absent on tvOS (the whole section is iOS-only now) |
| `test_skins_listedWhenNoGameRuns` | id `touch-skins` |
| `test_dsuRow_summarisesTheClient_andPushes`, `..._summarisesOneServerAsSingular` | unchanged (they look the `dsu` row up by id model-wide; it now sits in `setup`) |
| `test_moreSettings_pushes` | deleted (the More section is gone) |
| unchanged | `test_slots_followTheSystem`, `test_nothingBound_leavesOnlyShowAllPorts`, `test_showAllRow_runsItsAction`, `test_playerRow_pushesThePlayerScreen`, `test_opacitySnapsToTheNearestChoice`, `test_padRow_showsBatteryAndPlayer_andIdentifies`, `test_noPads_showsADisabledPlaceholder`, `test_devices_offerNoWiiRemoteScanning`, the help tests, `test_settingsWithoutAGame_listsBothSystems` |

New tests:

```swift
  func test_playerGroup_titleDevicePlaysAs_andPointerOnATouchscreenWiiRow() {
    let model = make(state(system: .wiiAndGameCube, bound: ["wii-1": Self.touch, "gc-2": Self.xbox], wiiExtension: [1: 1],
                           pads: [ConnectedPadState(qualifier: Self.xbox, name: "Xbox", batteryPercent: nil, isCharging: false, playerLabel: nil)]))
    XCTAssertEqual(ids(model, section: "players"), ["wii-1", "wii-1-device", "wii-1-plays-as", "wii-1-pointer", "gc-2", "gc-2-device", "gc-2-plays-as", "show-all-ports"])
    XCTAssertEqual(model.item(id: "wii-1")?.title, "Wii Remote 1")
    XCTAssertEqual(model.item(id: "wii-1")?.badge, "Wii Remote + Nunchuk", "the title row's badge mirrors Plays as (spec 7.1)")
    XCTAssertEqual(model.item(id: "gc-2")?.badge, "GameCube Controller")
    XCTAssertEqual(model.item(id: "wii-1-plays-as")?.currentValueTitle, "Wii Remote + Nunchuk")
    XCTAssertEqual(model.item(id: "wii-1-device")?.currentValueTitle, "Touchscreen")
    XCTAssertEqual(model.item(id: "gc-2-device")?.currentValueTitle, "Xbox")
    XCTAssertEqual(model.item(id: "gc-2-plays-as")?.currentValueTitle, "GameCube Controller")
  }

  func test_unboundPorts_underShowAllPorts_getOnlyTitleAndDevice() {
    let model = make(state(system: .wiiAndGameCube, bound: ["wii-1": Self.touch], showAllPorts: true))
    let players = ids(model, section: "players")
    for unbound in ["wii-2", "wii-3", "wii-4", "gc-1", "gc-2", "gc-3", "gc-4"] {
      XCTAssertTrue(players.contains(unbound))
      XCTAssertTrue(players.contains("\(unbound)-device"))
      XCTAssertFalse(players.contains("\(unbound)-plays-as"), unbound)
      XCTAssertFalse(players.contains("\(unbound)-pointer"), unbound)
      XCTAssertNil(model.item(id: unbound)?.badge, "an unbound port plays as nothing")
    }
    XCTAssertEqual(model.item(id: "wii-2-device")?.currentValueTitle, "None")
  }

  func test_playsAs_gameCubeTitle_hasNoPlaysAsRow() {
    let model = make(state(system: .gamecube, bound: ["gc-1": Self.xbox]))
    XCTAssertEqual(ids(model, section: "players"), ["gc-1", "gc-1-device", "show-all-ports"])
  }

  func test_playsAs_wiiOnlyTitle_hasNoGameCubeOption() {
    guard case .cycle(let options, _)? = make(state(system: .wii, bound: ["wii-1": Self.touch])).item(id: "wii-1-plays-as")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Wii Remote", "Wii Remote + Nunchuk", "Wii Classic Controller", "Wii Remote Sideways"])
  }

  func test_playsAs_cycleWritesThroughTheAction() {
    var chosen: (String, PlaysAs)?
    let model = make(state(system: .wiiAndGameCube, bound: ["wii-1": Self.touch]), actions(setPlaysAs: { chosen = ($0.id, $1) }))
    guard case .cycle(let options, let selection)? = model.item(id: "wii-1-plays-as")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Wii Remote", "Wii Remote + Nunchuk", "Wii Classic Controller", "Wii Remote Sideways", "GameCube Controller"])
    selection.wrappedValue = AnyHashable(PlaysAs.gameCube)
    XCTAssertEqual(chosen?.0, "wii-1")
    XCTAssertEqual(chosen?.1, .gameCube)
  }

  func test_pendingChoices_areShownAtOnce_whileTheGroupStaysPut() {
    var pending = PendingHubChanges()
    pending.playsAs["wii-1"] = .gameCube
    pending.devices["wii-1"] = .noDevice
    let model = make(state(system: .wiiAndGameCube, bound: ["wii-1": Self.touch], pending: pending))
    XCTAssertEqual(model.item(id: "wii-1-plays-as")?.currentValueTitle, "GameCube Controller")
    XCTAssertEqual(model.item(id: "wii-1-device")?.currentValueTitle, "None")
    XCTAssertEqual(model.item(id: "wii-1")?.badge, "GameCube Controller")
    XCTAssertNotNil(model.item(id: "wii-1-plays-as"), "the row keeps its id until the change is committed")
  }

  func test_device_cycleOffersNoneTouchscreenAndPads_andAutoOnAPinnedPort_andWritesTheChoice() {
    var chosen: (String, PlayerDeviceChoice)?
    let pads = [ConnectedPadState(qualifier: Self.xbox, name: "Xbox", batteryPercent: nil, isCharging: false, playerLabel: nil)]
    let hub = state(system: .gamecube, bound: ["gc-1": Self.xbox], pads: pads, isPinned: ["gc-1"])
    let model = make(hub, actions(setDevice: { chosen = ($0.id, $1) }))
    guard case .cycle(let options, let selection)? = model.item(id: "gc-1-device")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Auto", "None", "Touchscreen", "Xbox"])
    selection.wrappedValue = AnyHashable(PlayerDeviceChoice.touchscreen)
    XCTAssertEqual(chosen?.0, "gc-1")
    XCTAssertEqual(chosen?.1, .touchscreen)
    guard case .cycle(let tvOptions, _)? = make(hub, platform: .tvos).item(id: "gc-1-device")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(tvOptions.map(\.0), ["Auto", "None", "Xbox"], "no touchscreen on tvOS")
    XCTAssertEqual(model.item(id: "gc-1-device")?.description, PlayerScreenHelp.devicePinned, "a pinned port explains itself")
  }

  func test_pointerRow_touchscreenWii_cyclesPointerMode_gyroPad_togglesMotion_padWithoutGyro_none() {
    var mode: PointerMode?
    var motion: (String, Bool)?
    var hub = state(system: .wiiAndGameCube, bound: ["wii-1": Self.touch, "wii-2": Self.xbox, "wii-3": "MFi/1/Plain Pad"],
                    pads: [ConnectedPadState(qualifier: Self.xbox, name: "Xbox", batteryPercent: nil, isCharging: false, playerLabel: nil, hasGyro: true),
                           ConnectedPadState(qualifier: "MFi/1/Plain Pad", name: "Plain", batteryPercent: nil, isCharging: false, playerLabel: nil)])
    hub.pointerMode = .gyro
    hub.pointerIsThisGameOnly = true
    let model = make(hub, actions(setPointerMode: { mode = $0 }, setMotionPointer: { motion = ($0.id, $1) }))
    guard case .cycle(let options, let selection)? = model.item(id: "wii-1-pointer")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Touch – Follow", "Touch – Drag", "Gyro"])
    XCTAssertEqual(model.item(id: "wii-1-pointer")?.badge, "This game", "a per-game override shows on the cycle row")
    selection.wrappedValue = AnyHashable(PointerMode.touchDrag)
    XCTAssertEqual(mode, .touchDrag)
    guard case .toggle(let binding)? = model.item(id: "wii-2-pointer")?.role else { return XCTFail("toggle") }
    binding.wrappedValue = true
    XCTAssertEqual(motion?.0, "wii-2")
    XCTAssertEqual(motion?.1, true)
    XCTAssertNil(model.item(id: "wii-3-pointer"))
    XCTAssertNil(make(hub, platform: .tvos).item(id: "wii-1-pointer"), "no touchscreen pointer on tvOS")
  }

  func test_touchControls_layoutRow_isNamedLayout_withAutoGameCubeWiiRemote_andTheRightDescription() throws {
    let model = make(state(system: .wii))
    XCTAssertEqual(ids(model, section: "touch-controls"), ["touch-visible", "touch-layout", "touch-opacity", "touch-editable", "touch-edit-layout", "touch-edit-ir-area", "touch-skins", "touch-reset-layouts"])
    let layout = try XCTUnwrap(model.item(id: "touch-layout"))
    XCTAssertEqual(layout.title, "Layout")
    guard case .cycle(let options, _) = layout.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Auto", "GameCube", "Wii Remote"])
    let description = try XCTUnwrap(layout.description)
    XCTAssertTrue(description.contains("running game's system"))
    XCTAssertFalse(description.contains("Player 1"), "Auto follows the game, not Player 1's Plays as (EmulationScreen.isWiiSystem)")
  }

  func test_pendingLayout_isShownAtOnce() {
    var pending = PendingHubChanges()
    pending.overlayMode = .gamecube
    XCTAssertEqual(make(state(system: .gamecube, pending: pending)).item(id: "touch-layout")?.currentValueTitle, "GameCube")
  }

  func test_touchControls_toggles_and_resetRun_theirActions() {
    var programmatic: Bool?
    var resets = 0
    let model = make(state(system: .gamecube), actions(setTouchOverlayProgrammatic: { programmatic = $0 }, resetOverlayLayouts: { resets += 1 }))
    guard case .toggle(let binding)? = model.item(id: "touch-editable")?.role else { return XCTFail("toggle") }
    binding.wrappedValue = false
    XCTAssertEqual(programmatic, false)
    guard case .destructive(let reset)? = model.item(id: "touch-reset-layouts")?.role else { return XCTFail("destructive") }
    reset()
    XCTAssertEqual(resets, 1)
  }

  func test_setup_rows_iOS_and_tvOS() {
    XCTAssertEqual(ids(make(state(system: .gamecube)), section: "setup"), ["background-input", "takes-player-1", "rumble", "rumble-test", "dsu"])
    XCTAssertEqual(ids(make(state(system: .gamecube), platform: .tvos), section: "setup"), ["background-input", "dsu"])
  }

  func test_setup_rowsWriteThroughTheirActions() {
    var log: [String] = []
    let model = make(state(system: .gamecube), actions(
      setBackgroundInput: { log.append("bg \($0)") }, setRumbleDestination: { log.append("rumble \($0)") },
      setConnectTakesPlayer1: { log.append("takes \($0)") }, testRumble: { log.append("test") }))
    guard case .toggle(let background)? = model.item(id: "background-input")?.role,
          case .toggle(let takes)? = model.item(id: "takes-player-1")?.role,
          case .cycle(let options, let rumble)? = model.item(id: "rumble")?.role else { return XCTFail("roles") }
    background.wrappedValue = true
    takes.wrappedValue = false
    XCTAssertEqual(options.map(\.0), ["Device Haptics", "Controller", "Both"])
    XCTAssertEqual(rumble.wrappedValue, AnyHashable(RumbleDestination.controller))
    rumble.wrappedValue = AnyHashable(RumbleDestination.both)
    run(model.item(id: "rumble-test"))
    XCTAssertEqual(log, ["bg true", "takes false", "rumble both", "test"])
  }

  func test_lightsRow_onlyWithALitPad() {
    var pad = ConnectedPadState(qualifier: Self.xbox, name: "Xbox", batteryPercent: nil, isCharging: false, playerLabel: nil)
    XCTAssertFalse(ids(make(state(system: .gamecube, pads: [pad])), section: "devices").contains("lights"))
    pad.hasLight = true
    XCTAssertTrue(ids(make(state(system: .gamecube, pads: [pad])), section: "devices").contains("lights"))
    XCTAssertFalse(ids(make(state(system: .gamecube, pads: [pad]), platform: .tvos), section: "devices").contains("lights"))
  }

  func test_focusRequest_isPassedToTheModel() {
    var hub = state(system: .wiiAndGameCube, bound: ["gc-1": Self.xbox])
    hub.focusRequest = "gc-1-plays-as"
    XCTAssertEqual(make(hub).focusRequest, "gc-1-plays-as")
    XCTAssertNil(make(state(system: .gamecube)).focusRequest)
  }
```
Append to `MenuFocusRouterTests` (reusing its `item(_:)` helper):
```swift
  func test_reconcile_prefersTheRequestedID_whenTheFocusedRowMoved() {
    // "b-old" vanished and "b-new" appeared elsewhere: focus follows the request, not index 1.
    let model = MenuModel(sections: [MenuSection(id: "s", items: [item("a"), item("c"), item("b-new")])])
    XCTAssertEqual(MenuFocusRouter.reconcile(focusedID: "b-old", previousOrder: ["a", "b-old", "c"], model: model, requestedID: "b-new"), "b-new")
  }

  func test_reconcile_keepsAFocusedIDThatStillExists_evenWithARequest() {
    let model = MenuModel(sections: [MenuSection(id: "s", items: [item("a"), item("b")])])
    XCTAssertEqual(MenuFocusRouter.reconcile(focusedID: "a", previousOrder: ["a", "b"], model: model, requestedID: "b"), "a")
  }

  func test_reconcile_ignoresARequestThatIsNotInTheModel() {
    let model = MenuModel(sections: [MenuSection(id: "s", items: [item("a"), item("c")])])
    XCTAssertEqual(MenuFocusRouter.reconcile(focusedID: "b", previousOrder: ["a", "b", "c"], model: model, requestedID: "nope"), "c", "falls back to the same-index rule")
  }
```
In `PlayerScreenModelBuilderTests` add a test for the shared overload: `deviceOptions(isPinned: true, current: .pad(Self.dualSense), pads: [pad(Self.xbox, "Xbox")], currentTitle: "DualSense (Disconnected)", platform: .ios)` ends with a `DeviceOption(choice: .pad(Self.dualSense), title: "DualSense (Disconnected)")` and starts with Auto; the existing `deviceOptions(state:platform:)` tests stay as they are.

- [ ] **Step 2: Run, verify failure.**

- [ ] **Step 3: Shared statics (ruling H8)** in `PlayerScreenModelBuilder`:

```swift
  /// The Wii pointer modes a touchscreen Wii Remote offers, in row order. The hub's Pointer row uses this list too.
  static let pointerModes: [PointerMode] = [.touchFollow, .touchDrag, .gyro]

  /// The Device list: Auto on a pinned port, None, Touchscreen (iOS), each connected pad, and the
  /// current device when it is a pad that is not connected (a disconnected pad, a DSU device), so the
  /// list can mark it current. The player screen and the hub both build their lists here.
  static func deviceOptions(isPinned: Bool, current: PlayerDeviceChoice, pads: [ConnectedPadState],
                            currentTitle: String, platform: PlatformKind) -> [DeviceOption] {
    var options: [DeviceOption] = []
    if isPinned { options.append(DeviceOption(choice: .automatic, title: L("Auto"))) }
    options.append(DeviceOption(choice: .noDevice, title: L("None")))
    if platform == .ios { options.append(DeviceOption(choice: .touchscreen, title: L("Touchscreen"))) }
    options += pads.map { DeviceOption(choice: .pad($0.qualifier), title: $0.name) }
    if case .pad(let qualifier) = current, !pads.contains(where: { $0.qualifier == qualifier }) {
      options.append(DeviceOption(choice: current, title: currentTitle))
    }
    return options
  }

  static func deviceOptions(state: PlayerScreenState, platform: PlatformKind) -> [DeviceOption] {
    deviceOptions(isPinned: state.isPinned, current: state.deviceChoice, pads: state.pads,
                  currentTitle: deviceSummary(state), platform: platform)
  }
```
and `pointerSection` uses `Self.pointerModes` instead of its local `modes`.

- [ ] **Step 4: Implement the builder**

Replace `playersSection`, `onScreenSection`, the `more` section and the devices rows (delete `emulatedController(for:)` and the private `title(for:)`; use `player.title`). `deviceName(for:pads:)` stays (used by `deviceRow`). Update the header doc comment.

```swift
  static func make(state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuModel {
    var sections = [playersSection(state: state, actions: actions, platform: platform)]
    if platform == .ios {
      sections.append(touchControlsSection(state: state, actions: actions))
    }
    sections.append(devicesSection(state: state, actions: actions, platform: platform))
    sections.append(setupSection(state: state, actions: actions, platform: platform))
    sections.append(helpSection(platform: platform))
    return MenuModel(sections: sections, focusRequest: state.focusRequest)
  }

  // MARK: Players: a group per port (spec §7.1, deviation: rows, not pills)

  private static func playersSection(state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuSection {
    let bound = state.players.filter(\.isBound)
    let shown = state.showAllPorts ? state.players : bound
    var items: [MenuItem] = []
    for player in shown {
      let playsAs = state.pending.playsAs[player.id] ?? PlaysAs.current(of: player)
      items.append(MenuItem(
        id: player.id, title: player.title, icon: player.kind == .gameCube ? "gamecontroller" : "wand.and.rays",
        role: .destination(actions.playerDestination(player)),
        badge: player.isBound ? playsAs.title : nil,
        description: L("Remap buttons, profiles, motion and advanced settings.")))
      items.append(deviceRow(for: player, state: state, actions: actions, platform: platform))
      // An unbound port has nothing to play as and no pointer: title and Device only.
      guard player.isBound else { continue }
      let options = PlaysAs.options(for: state.system)
      if options.count > 1 {
        items.append(MenuItem(
          id: "\(player.id)-plays-as", title: L("Plays as"), icon: "person.crop.rectangle",
          role: .cycle(options: options.map { ($0.title, AnyHashable($0)) }, selection: Binding(
            get: { AnyHashable(playsAs) },
            set: { if let value = $0.base as? PlaysAs { actions.setPlaysAs(player, value) } })),
          description: L("The controller the game sees. Wii Remote choices move this player to a Wii Remote slot; GameCube Controller moves it to a GameCube port.")))
      }
      if let pointer = pointerRow(for: player, state: state, actions: actions, platform: platform) {
        items.append(pointer)
      }
    }
    let hiddenCount = state.players.count - bound.count
    if hiddenCount > 0 {
      items.append(MenuItem(
        id: "show-all-ports", title: state.showAllPorts ? L("Hide Unused Ports") : L("Show All Ports"),
        icon: state.showAllPorts ? "chevron.up" : "chevron.down",
        role: .action(actions.toggleShowAllPorts), badge: state.showAllPorts ? nil : String(hiddenCount)))
    }
    return MenuSection(id: "players", header: L("Players"), items: items)
  }

  /// The player screen's Device list (`PlayerScreenModelBuilder.deviceOptions`), as a cycle.
  private static func deviceRow(for player: PlayerState, state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuItem {
    let committed = PlayerDeviceChoice(qualifier: player.deviceQualifier)
    let options = PlayerScreenModelBuilder.deviceOptions(
      isPinned: player.isPinned, current: committed, pads: state.pads,
      currentTitle: deviceName(for: player, pads: state.pads), platform: platform)
    let shown = state.pending.devices[player.id] ?? committed
    return MenuItem(
      id: "\(player.id)-device", title: L("Device"), icon: player.isPinned ? "pin.fill" : "gamecontroller",
      role: .cycle(options: options.map { ($0.title, AnyHashable($0.choice)) }, selection: Binding(
        get: { AnyHashable(shown) },
        set: { if let choice = $0.base as? PlayerDeviceChoice { actions.setDevice(player, choice) } })),
      description: player.isPinned ? PlayerScreenHelp.devicePinned : PlayerScreenHelp.device)
  }

  /// Touchscreen Wii Remote (iOS): the pointer mode. Gyro pad: Motion on/off. Otherwise none.
  private static func pointerRow(for player: PlayerState, state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuItem? {
    guard player.kind == .wiiRemote, player.isBound else { return nil }
    if DeviceFamily.from(qualifier: player.deviceQualifier) == .touchscreen {
      guard platform == .ios else { return nil }
      return MenuItem(
        id: "\(player.id)-pointer", title: L("Pointer"), icon: state.pointerMode.systemImage,
        role: .cycle(options: PlayerScreenModelBuilder.pointerModes.map { ($0.title, AnyHashable($0)) }, selection: Binding(
          get: { AnyHashable(state.pointerMode) },
          set: { if let mode = $0.base as? PointerMode { actions.setPointerMode(mode) } })),
        badge: state.pointerIsThisGameOnly ? L("This game") : nil,
        description: L("How the Wii pointer moves: follow your finger, drag it, or tilt the device."))
    }
    guard state.pads.first(where: { $0.qualifier == player.deviceQualifier })?.hasGyro == true else { return nil }
    return MenuItem(
      id: "\(player.id)-pointer", title: L("Pointer"), icon: "gyroscope",
      role: .toggle(Binding(get: { player.motionPointerEnabled }, set: { actions.setMotionPointer(player, $0) })),
      description: L("Aim with the controller's gyro."))
  }
```

Touch Controls, Setup, Devices:
```swift
  // MARK: Touch Controls (iOS; was On-Screen Controls)

  private static func touchControlsSection(state: ControllerHubState, actions: ControllerHubActions) -> MenuSection {
    var items: [MenuItem] = []
    // Visibility and layout are re-derived at every game start, so they only mean something in a
    // game. Layout also has a side effect (choosing Wii binds Wii Remote 1 to the touchscreen), which
    // should only fire from a running game, not from Settings.
    if state.isGameRunning {
      items.append(MenuItem(
        id: "touch-visible", title: L("Show Touch Controls"), icon: "hand.tap",
        role: .toggle(Binding(get: { state.overlayVisible }, set: { actions.setOverlayVisible($0) })),
        description: L("Draw the on-screen controller over the game.")))
      let layouts: [(String, AnyHashable)] = [
        (L("Auto"), AnyHashable(ControllerManager.OverlayMode.auto)),
        (L("GameCube"), AnyHashable(ControllerManager.OverlayMode.gamecube)),
        (L("Wii Remote"), AnyHashable(ControllerManager.OverlayMode.wii)),
      ]
      items.append(MenuItem(
        id: "touch-layout", title: L("Layout"), icon: "rectangle.3.group",
        role: .cycle(options: layouts, selection: Binding(
          get: { AnyHashable(state.pending.overlayMode ?? state.overlayMode) },
          set: { if let mode = $0.base as? ControllerManager.OverlayMode { actions.setOverlayMode(mode) } })),
        description: L("Which on-screen controller is drawn. Auto follows the running game's system and the attached controllers, not Player 1's Plays as.")))
    }
    items.append(MenuItem(
      id: "touch-opacity", title: L("Opacity"), icon: "circle.lefthalf.filled",
      role: .cycle(options: ControllerHubState.opacityChoices.map { ("\($0)%", AnyHashable($0)) }, selection: Binding(
        get: { AnyHashable(state.overlayOpacityPercent) },
        set: { if let percent = $0.base as? Int { actions.setOverlayOpacity(Float(percent) / 100) } })),
      description: L("How see-through the on-screen controls are.")))
    items.append(MenuItem(
      id: "touch-editable", title: L("Editable Controls"), icon: "slider.horizontal.below.rectangle",
      role: .toggle(Binding(get: { state.touchOverlayProgrammatic }, set: { actions.setTouchOverlayProgrammatic($0) })),
      description: L("On by default: controls you can move and resize from Edit Layout or with a long press in-game. Off uses the older fixed pads.")))
    items.append(MenuItem(id: "touch-edit-layout", title: L("Edit Layout…"), icon: "rectangle.and.pencil.and.ellipsis", role: .action(actions.editLayout),
                          description: L("Move and resize the on-screen controls on the game's own screen.")))
    if state.system != .gamecube {
      items.append(MenuItem(id: "touch-edit-ir-area", title: L("Edit IR Area…"), icon: "scope", role: .action(actions.editIRArea),
                            description: L("Where a touch moves the Wii pointer.")))
    }
    items.append(MenuItem(id: "touch-skins", title: L("Skins…"), icon: "paintpalette", role: .destination(actions.skinsDestination()),
                          description: L("Artwork for the on-screen controller.")))
    items.append(MenuItem(id: "touch-reset-layouts", title: L("Reset All Layouts"), icon: "arrow.counterclockwise", role: .destructive(actions.resetOverlayLayouts),
                          description: L("Put every on-screen layout back to its default.")))
    return MenuSection(id: "touch-controls", header: L("Touch Controls"), items: items)
  }

  // MARK: Setup (was More Controller Settings)

  private static func setupSection(state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuSection {
    var items = [MenuItem(
      id: "background-input", title: L("Background Input"), icon: "rectangle.on.rectangle",
      role: .toggle(Binding(get: { state.backgroundInput }, set: { actions.setBackgroundInput($0) })),
      description: L("Keep reading controllers while another app is in front."))]
    if platform == .ios {
      items.append(MenuItem(
        id: "takes-player-1", title: L("Controllers Take Player 1"), icon: "1.circle",
        role: .toggle(Binding(get: { state.connectTakesPlayer1 }, set: { actions.setConnectTakesPlayer1($0) })),
        description: L("A controller that connects while the on-screen controls are Player 1 becomes Player 1, even if you chose the on-screen controls there.")))
      items.append(MenuItem(
        id: "rumble", title: L("Rumble Output"), icon: "waveform",
        role: .cycle(options: RumbleDestination.allCases.map { ($0.title, AnyHashable($0)) }, selection: Binding(
          get: { AnyHashable(state.rumbleDestination) },
          set: { if let value = $0.base as? RumbleDestination { actions.setRumbleDestination(value) } })),
        description: L("Where a game's rumble goes.")))
      items.append(MenuItem(id: "rumble-test", title: L("Test Rumble"), icon: "waveform.path", role: .action(actions.testRumble),
                            description: L("A short pulse on the chosen output.")))
    }
    items.append(MenuItem(
      id: "dsu", title: L("Motion Source (DSU)"), subtitle: dsuSummary(state), icon: "dot.radiowaves.left.and.right",
      role: .destination(actions.dsuDestination()),
      description: L("Use a phone or a DSU server as a motion controller.")))
    return MenuSection(id: "setup", header: L("Setup"), items: items)
  }
```
`devicesSection(state:actions:platform:)` keeps its pad rows and the `no-pads` placeholder and loses the DSU row (now in Setup). After them, when `platform == .ios` and `state.pads.contains(where: \.hasLight)`, append `MenuItem(id: "lights", title: L("Controller Lights"), icon: "lightbulb", role: .destination(actions.lightsDestination()), description: L("The colour of each controller's light bar."))`. `ControllerHubActions` loses `moreSettingsDestination`, and `ControllerHubViewModel.actions` loses its wiring.

- [ ] **Step 5: Focus follows a moved row (ruling H5)**

`MenuModel` gains `var focusRequest: String?` (init `init(sections: [MenuSection] = [], focusRequest: String? = nil)`) with the doc comment "An id the host wants focused after a rebuild that MOVED the focused row; never overrides a focused id that still exists." `MenuFocusRouter.reconcile` gains `requestedID`:
```swift
  static func reconcile(focusedID: String?, previousOrder: [String], model: MenuModel, requestedID: String? = nil) -> String? {
    let order = model.focusableIDs
    guard !order.isEmpty else { return nil }
    guard let focusedID else { return order.first }
    if order.contains(focusedID) { return focusedID }
    // The focused row's id vanished because the hub moved it (Plays as across Wii and GameCube):
    // follow the host's request before falling back to the same-index rule.
    if let requestedID, order.contains(requestedID) { return requestedID }
    if let oldIndex = previousOrder.firstIndex(of: focusedID) {
      return order[min(oldIndex, order.count - 1)]
    }
    return order.first
  }
```
Update its doc comment. `MenuScreen` (iOS `.onChange(of: model.focusableIDs)`) passes `requestedID: model.focusRequest`; on tvOS (the `#else` branch of `body`) add `.onChange(of: model.focusRequest) { _, id in if let id, model.focusableIDs.contains(id) { tvFocusedID = id } }`. tvOS native focus has no router: this is a device gate (Task 7).

- [ ] **Step 6: Strings.** Run `check_localized_keys.py`; add every missing key (the descriptions above, `Plays as`, `Layout`, `Show Touch Controls`, `Touch Controls`, `Setup`, `Editable Controls`, `Reset All Layouts`, `Controller Lights`, `This game` if absent...) to en and ja Core.strings.

- [ ] **Step 7: Build both platforms; run `ControllerHubModelBuilderTests`, `MenuFocusRouterTests`, `PlayerScreenModelBuilderTests`, `ControllerHubViewModelTests`.**

- [ ] **Step 8: Commit**

```bash
git add Common/Swift/Controllers/Hub/ControllerHubModelBuilder.swift Common/Swift/Controllers/Hub/ControllerHubState.swift Common/Swift/Controllers/Hub/ControllerHubViewModel.swift Common/Swift/Controllers/Player/PlayerScreenModelBuilder.swift Common/Swift/Menu/MenuModel.swift Common/Swift/Menu/MenuFocusRouter.swift Common/Swift/Menu/MenuScreen.swift Common/UI/Localization/en.lproj/Core.strings Common/UI/Localization/ja.lproj/Core.strings DolphiniOSTests/ControllerHubModelBuilderTests.swift DolphiniOSTests/MenuFocusRouterTests.swift DolphiniOSTests/PlayerScreenModelBuilderTests.swift
git commit -m "feat(controllers): hub rows for device, plays as and pointer; Touch Controls and Setup"
```

---

### Task 5: Player detail screen — drop Extension/Sideways, add the moved rows

Rulings that apply here (restated): **H7** this task lists every existing test it breaks and how each changes, and uses the file's real test helpers (`state(_:device:pads:controls:)`, `boundGameCube`, `pad(_:_:gyro:)`, `make(_:_:platform:)`, `ids(_:section:)`, `sectionIDs(_:)`; `Self.touch`, `Self.xbox`), not invented ones. **H8** no dead code: delete `PlayerScreenIO.setExtension/setSideways` (protocol, `LivePlayerScreenIO`, `FakeIO`) and `PlayerScreenHelp.extensionCaption`/`.sideways` with their `L()` strings once nothing calls them (the hub writer calls `WiimoteSlotOptions` directly). **H14** tests assert something (each new row test checks both presence and absence). **H16** Advanced Motion becomes unreachable on tvOS; that is accepted. **H12** new `L()` keys go into Core.strings en/ja. **H18** no attribution trailers.

**Files:**
- Modify: `Player/PlayerScreenModelBuilder.swift` (delete `wiiSection`; add rows; update the header doc comment: no "Wii Remote (Wii ports): Extension, Sideways" line, and the Help paragraph no longer lists a Wii Remote row), `Player/PlayerScreenState.swift` (`PlayerScreenActions` loses `setExtension`/`setSideways`, gains `advancedMotionDestination`, `stickFeelDestination`), `Player/PlayerScreenViewModel.swift` (delete `setExtension(_:)`/`setSideways(_:)` and their action wiring; wire the two destinations), `Player/PlayerScreenIO.swift` (delete both writes), `Hub/ControllerHelp.swift` (delete `extensionCaption` and `sideways`)
- Modify: `Common/UI/Localization/en.lproj/Core.strings`, `ja.lproj/Core.strings` (remove the keys nothing uses any more: the extension caption, the sideways caption, `Extension: %@`, and `Extension`/`Sideways` if no `L()` call remains; grep each)
- Test: `DolphiniOSTests/PlayerScreenModelBuilderTests.swift`, `DolphiniOSTests/PlayerScreenViewModelTests.swift` (`FakeIO`)

- [ ] **Step 1: Update the tests**

Existing tests this task breaks, and how each changes:

| Existing test / helper | Change |
|---|---|
| `actions(_:)` helper (PlayerScreenModelBuilderTests, around :25-48) | remove `setExtension:` and `setSideways:`; add `advancedMotionDestination: { AnyView(EmptyView()) }, stickFeelDestination: { AnyView(EmptyView()) }` |
| `test_gameCubePort_neverShowsWiiSections_evenOnTheTouchscreen` | the `"wii"` assertion is vacuous now (no Wii section exists for any port): drop it, keep `XCTAssertFalse(ids.contains("pointer"))`, add `XCTAssertTrue(ids.contains("stick-feel"))` (a touchscreen GameCube port still has Stick Feel) |
| `test_wiiPort_onTheTouchscreen_iOS` | section list becomes `["device", "profile", "buttons-hint", "pointer", "stick-feel", "advanced"]` |
| `test_extensionOptions_sayExtensionOnTVOS` | deleted |
| `test_help_playerRowsHaveCaptions` | delete the `wii` lines (`wii-extension`/`wii-sideways` subtitles and the `PlayerScreenHelp.extensionCaption`/`.sideways` references); the GameCube asserts stay |
| other whole-list section assertions (`:188`, `:198`, `:252`, `:269`) | `filter`/`contains` forms: unchanged; grep every `sectionIDs(` equality against a touchscreen-bound port and add `stick-feel` before `advanced` |
| `FakeIO` (PlayerScreenViewModelTests) | delete its `setExtension`/`setSideways` |

New tests:
```swift
  func test_wiiPort_hasNoWiiRemoteSection_playsAsLivesInTheHub() {
    let model = make(state(.wiiRemote, device: Self.touch))
    XCTAssertFalse(sectionIDs(model).contains("wii"))
    XCTAssertNil(model.item(id: "wii-extension"))
    XCTAssertNil(model.item(id: "wii-sideways"))
  }

  func test_pointerSection_endsWithAdvancedMotion_onTheTouchscreen() {
    let model = make(state(.wiiRemote, device: Self.touch))
    XCTAssertEqual(model.sections.first { $0.id == "pointer" }?.items.last?.id, "pointer-advanced")
    guard case .destination? = model.item(id: "pointer-advanced")?.role else { return XCTFail("pushes") }
  }

  func test_gyroPad_pointerSection_hasNoAdvancedMotion() {
    let model = make(state(.wiiRemote, device: Self.xbox, pads: [pad(Self.xbox, "Xbox Wireless Controller", gyro: true)]))
    XCTAssertEqual(ids(model, section: "pointer"), ["pointer-motion"])
    XCTAssertNil(model.item(id: "pointer-advanced"))
  }

  func test_touchscreenPort_offersStickFeel_afterThePointerSection_padDoesNot() {
    let touch = make(state(.wiiRemote, device: Self.touch))
    XCTAssertNotNil(touch.item(id: "stick-feel"))
    let order = sectionIDs(touch)
    XCTAssertEqual(order.firstIndex(of: "stick-feel"), order.firstIndex(of: "pointer").map { $0 + 1 })
    XCTAssertNil(make(boundGameCube).item(id: "stick-feel"))
  }
```

- [ ] **Step 2: Run, verify failure.**

- [ ] **Step 3: Implement**

In `PlayerScreenModelBuilder.make`, remove the `wiiSection` append and the function. The stick-feel section goes after the (conditional) pointer section and before the advanced sections, whether or not the pointer section exists:
```swift
    sections += buttonSections(state: state, actions: actions)
    if showsPointerAndMotion(state: state, platform: platform) {
      sections.append(pointerSection(state: state, actions: actions))
    }
    if state.isTouchscreen {
      sections.append(MenuSection(id: "stick-feel", items: [MenuItem(
        id: "stick-feel", title: L("On-Screen Stick Feel…"), icon: "l.joystick",
        role: .destination(actions.stickFeelDestination()),
        description: L("Gain, dead zone and smoothing of the on-screen sticks and triggers."))]))
    }
    sections += advancedSections(state: state, actions: actions)
```
In `pointerSection` (touchscreen branch), after the shake row:
```swift
    items.append(MenuItem(
      id: "pointer-advanced", title: L("Advanced Motion…"), icon: "gyroscope",
      role: .destination(actions.advancedMotionDestination()),
      description: L("Smoothing, dead zones and the motion sensor's own options.")))
```
`PlayerScreenActions`: remove `setExtension`, `setSideways`; add `var advancedMotionDestination: () -> AnyView` and `var stickFeelDestination: () -> AnyView`. `PlayerScreenViewModel.actions`: `advancedMotionDestination: { AnyView(EnhancedMotionControlsView().padBackNavigation()) }`, `stickFeelDestination: { AnyView(AnalogStickSettingsView().padBackNavigation()) }`; delete `setExtension(_:)`/`setSideways(_:)`. Delete `setExtension`/`setSideways` from the `PlayerScreenIO` protocol and `LivePlayerScreenIO` (grep confirms nothing else calls them: the hub writer uses `WiimoteSlotOptions` directly), and `PlayerScreenHelp.extensionCaption`/`.sideways` from `ControllerHelp.swift`, with their Core.strings entries.

- [ ] **Step 4: Build both platforms; run `PlayerScreenModelBuilderTests`, `PlayerScreenViewModelTests`, `PlayerScreenLeavesTests`, `PlayerScreenIOTests`, `PlayerScreenStateTests`.**

- [ ] **Step 5: Commit**

```bash
git add Common/Swift/Controllers/Player Common/Swift/Controllers/Hub/ControllerHelp.swift Common/UI/Localization/en.lproj/Core.strings Common/UI/Localization/ja.lproj/Core.strings DolphiniOSTests/PlayerScreen*Tests.swift
git commit -m "refactor(controllers): player screen drops Extension/Sideways, gains Advanced Motion and Stick Feel"
```

---

### Task 6: Delete More Controller Settings; Controller Lights view

Rulings that apply here (restated): **H2** `lightsDestination` gets its real view here, wrapped in `#if os(iOS)` with an `EmptyView` else-branch (`ControllerLightsView` is iOS-only). **H17** stale comments that still name the removed screens are updated too, beyond the one in `ControllersRootView` (list below); stale line numbers are pointers only, grep for the symbols. **H18** no attribution trailers. (Test Rumble was already moved out of the More view in Task 3, so nothing about it happens here.)

**Files:**
- Create: `Common/UI/Settings/SwiftUI/ControllerLightsView.swift`
- Delete: `Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift`
- Modify: `Hub/ControllerHubViewModel.swift` (`lightsDestination` real view)
- Modify: `Common/UI/Settings/SwiftUI/DebugRootView.swift` (Gallery link)
- Modify (comments only): `Common/UI/Settings/SwiftUI/ControllersRootView.swift`, `Common/Swift/Menu/PadBackNavigation.swift`, `Common/Swift/Controllers/ControllerManager.swift`, `DolphiniOS/UI/Emulation/TouchOverlay/TouchOverlayModel.swift`, `DolphiniOS/UI/Emulation/TouchOverlay/TouchOverlayArt.swift`, `DolphiniOSTests/TouchOverlayArtTests.swift`, `DolphiniOSTests/OverlayModePersistenceTests.swift`

- [ ] **Step 1: Extract the lights view**

`ControllerLightsView` is the old file's `Controller Lights` section as its own `List`: `@State private var litControllers: [GCController]`, refreshed on appear and on `GCControllerDidConnect`/`Disconnect`, one `ColorPicker` row per controller with a light using the old `ledBinding(for:)`. Title `Controller Lights`. Wrap the file in `#if os(iOS)`. In `ControllerHubViewModel.actions`:
```swift
      lightsDestination: {
        #if os(iOS)
        AnyView(ControllerLightsView().padBackNavigation())
        #else
        AnyView(EmptyView())
        #endif
      },
```

- [ ] **Step 2: Delete the old view**

`git rm Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift`. Grep for `ControllerMoreSettingsView` (expected: only comments remain). Its DEBUG `Gallery` link (`TouchOverlayGalleryView`) moves to `DebugRootView` as a `NavigationLink` in the Diagnostics section under `#if os(iOS) && DEBUG`. Its other rows are covered: Background Input, Take Player 1, Rumble, Test Rumble, Editable Controls and Reset Layouts are in Setup/Touch Controls; Advanced Motion and Stick Feel are on the player screen; Lights is here.

Update the comments that still name removed things (grep for `More Controller Settings`, `ControllerMoreSettingsView`, `Overlay Style`):
- `ControllersRootView.swift`: the `AnalogStickSettingsView` doc ("More Controller Settings and the DSU controller both push this one screen" becomes "the player screen and the DSU controller..."), the `ControllersRootView` doc ("behind its More Controller Settings row" becomes the hub's Setup section and player screens), and the editor doc ("by the Controllers hub and More Controller Settings outside one" becomes "by the Controllers hub outside one").
- `PadBackNavigation.swift` doc (lists More Controller Settings among pushed plain lists).
- `ControllerManager.swift`: the `overlayMode` doc and `storedOverlayMode` doc ("Overlay Style" becomes "Touch Controls → Layout"), and the `connectTakesPlayer1` doc ("More Controller Settings" becomes "Setup").
- `TouchOverlayModel.swift` (`TouchOverlayFlag` doc: "set from More Controller Settings" becomes "Touch Controls → Editable Controls"), `TouchOverlayArt.swift` and the two tests' comments ("Overlay Style" becomes "Layout").

- [ ] **Step 3: Build both platforms, run the whole test target.**

- [ ] **Step 4: Commit**

```bash
git add Common/UI/Settings/SwiftUI/ControllerLightsView.swift Common/UI/Settings/SwiftUI/DebugRootView.swift Common/UI/Settings/SwiftUI/ControllersRootView.swift Common/Swift/Menu/PadBackNavigation.swift Common/Swift/Controllers/ControllerManager.swift Common/Swift/Controllers/Hub DolphiniOS/UI/Emulation/TouchOverlay/TouchOverlayModel.swift DolphiniOS/UI/Emulation/TouchOverlay/TouchOverlayArt.swift DolphiniOSTests/TouchOverlayArtTests.swift DolphiniOSTests/OverlayModePersistenceTests.swift
git rm Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift
git commit -m "refactor(controllers): fold More Controller Settings into the hub"
```

---

### Task 7: Device gates and PR

Rulings that apply here (restated): **H4** a change takes effect 0.6 s after the last tap; **H5** focus follows a moved Plays as row; **H16** pad A-hold on list rows is not wired, pad users step with left/right, Advanced Motion is unreachable on tvOS, Reset All Layouts has no confirm. **H18** no attribution trailers in the PR body or commits.

- [ ] **Step 1: iPhone, Wii title (Xbox pad connected, touchscreen available)**

1. Open Controllers from the pause overlay. Wii Remote 1 shows four rows: title (badge = its Plays as), Device, Plays as, Pointer, each with its description visible. A pad's d-pad left/right steps each cycle row; a touch long-press opens the option list. Show All Ports lists the unbound ports with only a title and a Device row.
2. Tap Plays as repeatedly through Nunchuk, Classic, Sideways and stop on Wii Remote + Nunchuk. Nothing is written while tapping; about 0.6 s after the last tap the change applies. Resume: the game sees the Nunchuk (a title that requires it, such as Super Mario Galaxy).
3. Set Plays as to GameCube Controller: the group moves under "Player 1" and the pad's focus ring (if a pad drives the menu) lands on the moved Plays as row, not another player's. A title that accepts both, such as Mario Kart Wii, sees a GameCube pad. If Player 1's port already has a device, the change is refused with a "Player 1 is in use. Change that player's device first." toast and nothing moves; after a GameCube title this refusal is the expected first result.
4. Set it back to Wii Remote Sideways: the group returns as "Wii Remote 1"; the touch overlay draws the sideways layout when the device is the touchscreen.
5. Touch Controls → Layout: cycle Auto, GameCube, Wii Remote and back to Auto within one second; Wii Remote 1 is NOT rebound to the touchscreen (only the final value is written). Choosing Wii Remote and waiting draws the Wii overlay and binds Wii Remote 1 to the touchscreen as before. The row's description says Auto follows the running game's system.
6. Setup: Rumble Output cycles; Test Rumble pulses; Background Input toggles and survives leaving the hub. Cycle Device on a player and immediately push the player's title row: the device change is already committed on the player screen.
7. The Player 1 title row still opens the detail screen; it has no Extension or Sideways rows and does have Advanced Motion… (touchscreen Wii) and On-Screen Stick Feel… (touchscreen) rows. Changing Plays as in the hub shows "(edited)" on the player screen's profile row.
8. Move a touchscreen player from Wii to GameCube during a Wii game: the overlay switches to the GameCube layout and its touches drive the GameCube port; Layout now reads GameCube.

- [ ] **Step 2: Apple TV, Wii title (Xbox pad)**

1. Hub from the pause overlay: Device row cycles with left/right; Plays as cycles; descriptions show; no Pointer row for the pad unless it has a gyro; no Touch Controls section; Setup shows Background Input and Motion Source only.
2. Change Plays as from a Wii variant to GameCube Controller: native focus follows the moved row (device gate for the `MenuScreen` tvOS focus request). Press Menu back to the game: still paused (PR 1), and the change applied on resume (or on leaving the hub, whichever comes first).

- [ ] **Step 3: Open the PR against `develop`**

Title: `feat(controllers): hub rows for Device, Plays as and Pointer; Touch Controls`. Body: spec §7 summary, the deviations at the top of this plan (row group, real pointer options, focus-follow, settle delay, no revert, no pad long-press), device gate results, the stacking (depends on PR 3 Task 1 / `feat/settings-engine`; merge PR 3 first), and a note that `ControllerMoreSettingsView` is gone (its rows are in Setup, Touch Controls, Connected Devices, and the player screen). No attribution trailers. Do not push `develop`.
