# Controller Hub Reorganisation Implementation Plan (PR 4 of the unified menu UX)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Controllers hub lets a player change the three things they change most, without entering a detail screen: which device a player uses, what that player plays as (GameCube Controller, Wii Remote, with Nunchuk, with Classic, Sideways), and how the Wii pointer is driven. "Overlay Style" becomes Touch Controls → Layout. The "More Controller Settings" level goes away.

**Architecture:** A pure `PlaysAs` value composes the Wii slot kind, extension and sideways flag; `PlaysAsTransition.plan` turns a change into ordered steps that the view model executes through a new `ControllerHubWriting` seam. The hub model gains a row group per player (title, Device, Plays as, Pointer) built from the existing `ControllerHubState`, a renamed Touch Controls section, and a Setup section that absorbs the old More screen. The player detail screen loses Extension and Sideways and gains the two rows that moved down from More.

**Tech Stack:** Swift 5, SwiftUI, `@Observable`, XCTest (`iCubeTests`), Tuist.

**Spec:** `docs/superpowers/specs/2026-10-07-unified-menu-ux-design.md` §7, §8, §9, §10 item 4. Depends on PR 2 (`.cycle`, `description`, long-press picker). Does not depend on PR 3.

**Spec deviations, decided while planning:**
- **A player is a row group, not one row with three pills.** The engine's tvOS contract is one control per row (the controller hub spec documents compound rows as the thing that breaks tvOS focus), so each player gets a title row (pushes the detail screen) followed by Device, Plays as and Pointer rows, each a `.cycle`. Left/right on tvOS, tap to cycle or long-press for the list on iOS. Same reach, no second level.
- **Pointer options are the real ones.** Spec §7.1 lists "Touch, Gyro, Right Stick, Off"; the app has `PointerMode` (Gyro, Touch – Follow, Touch – Drag) for the touchscreen Wii Remote and a Motion on/off switch for a gyro pad. The Pointer row cycles `PointerMode` on a touchscreen Wii row and Motion On/Off on a gyro-pad Wii row, and is absent elsewhere. No "Right Stick" mode exists.
- **Rows keep their port identity.** Changing Plays as from a Wii variant to GameCube Controller moves the device from Wii slot N to GameCube port N (and back), so the row re-appears under its new title; the focus router's reconcile keeps focus at the same index.

## Global Constraints

- Minimum targets iOS 17 / tvOS 17; every changed file compiles for both.
- Builders and `PlaysAs`/`PlaysAsTransition` are pure: no bridge, no `ControllerManager`, no `GCController`.
- Every write goes through `ControllerHubWriting` (new) or the existing `PlayerScreenIO`; the view models never call `DOLConfigBridge` or `ControllerManager` directly except through those seams.
- Row ids: `gc-N`, `wii-N` for title rows; `gc-N-device`, `wii-N-device`, `gc-N-plays-as`, `wii-N-plays-as`, `wii-N-pointer`; section ids `players`, `touch-controls`, `devices`, `setup`, `help`.
- Strings through `L("...")`. Pause/resume only through `PauseArbiter`.
- Commits: conventional, subject < 72 chars, no LLM attribution trailers.
- New test files need `cd Source/iOS/App && tuist generate --no-open`. Tests: `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/<Class>"`. tvOS compile: `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube-tvOS (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos`.
- Worktree on branch `feat/controller-hub-reorg` from `develop` (after PR 2). After `git worktree add`, run `git config --worktree core.worktree <absolute worktree path>` and confirm `git rev-parse --show-toplevel`. DO NOT git reset / rebase / push / touch develop.
- Paths are relative to `Source/iOS/App/` unless they start with `docs/`. `Hub/` means `Common/Swift/Controllers/Hub/`, `Player/` means `Common/Swift/Controllers/Player/`.

## File map

| File | Responsibility |
|---|---|
| Create `Hub/PlaysAs.swift` | `PlaysAs` enum, titles, compose/decompose, options per row. |
| Create `Hub/PlaysAsTransition.swift` | Steps for a Plays as change. |
| Create `Hub/ControllerHubWriting.swift` | Write seam + live implementation. |
| Modify `Hub/ControllerHubState.swift` | `PlayerState` gains `isPinned`, `motionPointerEnabled`; hub state gains pointer and setup values; actions gain the new setters. |
| Modify `Hub/ControllerHubViewModel.swift` | Reader additions, writer, `setDevice`, `setPlaysAs`, setup setters. |
| Modify `Hub/ControllerHubModelBuilder.swift` | Player groups, Touch Controls, Setup. |
| Modify `Common/Swift/Controllers/ControllerManager.swift` | `clear(port:system:)` wrapper. |
| Modify `Player/PlayerScreenModelBuilder.swift`, `PlayerScreenState.swift`, `PlayerScreenViewModel.swift` | Drop the Wii Remote section; add Advanced Motion and Stick Feel rows. |
| Create `Common/UI/Settings/SwiftUI/ControllerLightsView.swift` | The LED colour rows, out of More. |
| Delete `Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift` | Absorbed. |
| Tests: create `PlaysAsTests`, `PlaysAsTransitionTests`; extend `ControllerHubModelBuilderTests`, `ControllerHubViewModelTests`, `PlayerScreenModelBuilderTests`. |

---

### Task 1: `PlaysAs`

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
  }

  func test_options_gameCubeTitle_isGameCubeOnly() {
    XCTAssertEqual(PlaysAs.options(for: .gamecube), [.gameCube])
  }

  func test_options_wiiTitle_offersAllFive_wiiFirst() {
    XCTAssertEqual(PlaysAs.options(for: .wiiAndGameCube), [.wiiRemote, .wiiNunchuk, .wiiClassic, .wiiSideways, .gameCube])
    XCTAssertEqual(PlaysAs.options(for: .both), [.wiiRemote, .wiiNunchuk, .wiiClassic, .wiiSideways, .gameCube])
  }

  func test_current_ofPlayer() {
    let wii = PlayerState(kind: .wiiRemote, port: 2, deviceQualifier: "x", wiiExtension: 2, isSideways: false)
    XCTAssertEqual(PlaysAs.current(of: wii), .wiiClassic)
    let gc = PlayerState(kind: .gameCube, port: 1, deviceQualifier: "x", wiiExtension: 0, isSideways: false)
    XCTAssertEqual(PlaysAs.current(of: gc), .gameCube)
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

  /// The extension wins over sideways: a sideways remote with a Nunchuk is not a thing the UI offers.
  init(kind: PlayerState.Kind, wiiExtension: Int, isSideways: Bool) {
    switch (kind, wiiExtension, isSideways) {
    case (.gameCube, _, _): self = .gameCube
    case (.wiiRemote, 1, _): self = .wiiNunchuk
    case (.wiiRemote, 2, _): self = .wiiClassic
    case (.wiiRemote, _, true): self = .wiiSideways
    default: self = .wiiRemote
    }
  }

  /// Wii titles offer everything, Wii first; a GameCube title has only GameCube ports.
  static func options(for system: ControllerSetupSystem) -> [PlaysAs] {
    switch system {
    case .gamecube: return [.gameCube]
    case .wii, .both, .wiiAndGameCube: return [.wiiRemote, .wiiNunchuk, .wiiClassic, .wiiSideways, .gameCube]
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
  }

  func test_wiiToWii_changesExtensionAndSidewaysOnly() {
    XCTAssertEqual(PlaysAsTransition.plan(from: wii(2), to: .wiiClassic), [.setExtension(wiimote: 2, value: 2), .setSideways(wiimote: 2, enabled: false)])
    XCTAssertEqual(PlaysAsTransition.plan(from: wii(2, ext: 2), to: .wiiSideways), [.setExtension(wiimote: 2, value: 0), .setSideways(wiimote: 2, enabled: true)])
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
  /// player as they were (spec §8: nothing half-applied).
  case moveDevice(qualifier: String, from: PlayerSlot, to: PlayerSlot)
  case clearSlot(PlayerSlot)
}

/// The ordered writes a Plays as change needs. Pure, so the order is tested; the view model runs
/// them through `ControllerHubWriting`.
enum PlaysAsTransition {
  static func plan(from player: PlayerState, to target: PlaysAs) -> [PlaysAsStep] {
    let current = PlaysAs.current(of: player)
    guard current != target else { return [] }
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

### Task 3: Write seam, reader additions, view model setters

**Files:**
- Create: `Hub/ControllerHubWriting.swift`
- Modify: `Hub/ControllerHubState.swift` (`PlayerState`, `ControllerHubState`, `ControllerHubActions`)
- Modify: `Hub/ControllerHubViewModel.swift` (`ControllerHubReading`, `LiveControllerHubReader`, `reload`, `actions`, new methods)
- Modify: `Common/Swift/Controllers/ControllerManager.swift` (add `clear(port:system:)`)
- Test: `DolphiniOSTests/ControllerHubViewModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor protocol ControllerHubWriting {
    func setDevice(_ choice: PlayerDeviceChoice, slot: PlayerSlot)
    /// False when the assignment was refused (no ControllerInterface device for the qualifier).
    func assign(qualifier: String, slot: PlayerSlot) -> Bool
    func clear(slot: PlayerSlot)
    func setExtension(_ value: Int, wiimote: Int)
    func setSideways(_ enabled: Bool, wiimote: Int)
    func setPointerMode(_ mode: PointerMode)
    func setMotionPointer(_ enabled: Bool, wiimote: Int)
    func setBackgroundInput(_ enabled: Bool)
    func setRumbleDestination(_ value: Int)
    func setConnectTakesPlayer1(_ enabled: Bool)
    func testRumble()
    func resetOverlayLayouts()
    func setTouchOverlayProgrammatic(_ enabled: Bool)
  }
  struct LiveControllerHubWriter: ControllerHubWriting
  // ControllerHubReading gains:
  func isPinned(_ slot: PlayerSlot) -> Bool
  func isMotionPointerEnabled(wiimote: Int) -> Bool
  func pointerMode() -> PointerMode
  func pointerIsThisGameOnly() -> Bool
  func backgroundInput() -> Bool
  func rumbleDestination() -> Int
  func connectTakesPlayer1() -> Bool
  func touchOverlayProgrammatic() -> Bool
  // PlayerState gains: var isPinned = false; var motionPointerEnabled = false
  // ControllerHubState gains: pointerMode: PointerMode, pointerIsThisGameOnly: Bool, backgroundInput: Bool,
  //   rumbleDestination: Int, connectTakesPlayer1: Bool, touchOverlayProgrammatic: Bool
  // ControllerHubActions gains:
  var setDevice: (PlayerState, PlayerDeviceChoice) -> Void
  var setPlaysAs: (PlayerState, PlaysAs) -> Void
  var setPointerMode: (PointerMode) -> Void
  var setMotionPointer: (PlayerState, Bool) -> Void
  var setBackgroundInput: (Bool) -> Void
  var setRumbleDestination: (Int) -> Void
  var setConnectTakesPlayer1: (Bool) -> Void
  var testRumble: () -> Void
  var setTouchOverlayProgrammatic: (Bool) -> Void
  var resetOverlayLayouts: () -> Void
  var lightsDestination: () -> AnyView
  // and loses: moreSettingsDestination
  // ControllerHubViewModel gains:
  func setDevice(_ player: PlayerState, _ choice: PlayerDeviceChoice)
  func setPlaysAs(_ player: PlayerState, _ target: PlaysAs)
  // ControllerManager gains:
  func clear(port portOneBased: Int, system: EmulatedSystem)
  ```

- [ ] **Step 1: Write the failing tests** (append to `ControllerHubViewModelTests`; extend `FakeReader` with the new reads returning stored values, defaults `pointerMode = .touchFollow`, `backgroundInput = false`, `rumbleDestination = 1`, `connectTakesPlayer1 = true`, `touchOverlayProgrammatic = true`, `pinned: Set<String> = []`, `motion: Set<Int> = []`)

```swift
  @MainActor
  private final class FakeWriter: ControllerHubWriting {
    var log: [String] = []
    var refuseAssign = false
    func setDevice(_ choice: PlayerDeviceChoice, slot: PlayerSlot) { log.append("setDevice \(choice) \(slot.playerID)") }
    func assign(qualifier: String, slot: PlayerSlot) -> Bool {
      log.append("assign \(qualifier) \(slot.playerID)")
      return !refuseAssign
    }
    func clear(slot: PlayerSlot) { log.append("clear \(slot.playerID)") }
    func setExtension(_ value: Int, wiimote: Int) { log.append("ext \(wiimote) \(value)") }
    func setSideways(_ enabled: Bool, wiimote: Int) { log.append("side \(wiimote) \(enabled)") }
    func setPointerMode(_ mode: PointerMode) { log.append("pointer \(mode)") }
    func setMotionPointer(_ enabled: Bool, wiimote: Int) { log.append("motion \(wiimote) \(enabled)") }
    func setBackgroundInput(_ enabled: Bool) { log.append("bg \(enabled)") }
    func setRumbleDestination(_ value: Int) { log.append("rumble \(value)") }
    func setConnectTakesPlayer1(_ enabled: Bool) { log.append("takes \(enabled)") }
    func testRumble() { log.append("testRumble") }
    func resetOverlayLayouts() { log.append("resetLayouts") }
    func setTouchOverlayProgrammatic(_ enabled: Bool) { log.append("programmatic \(enabled)") }
  }

  @MainActor
  func test_setPlaysAs_wiiToGameCube_assignsThenClears_andReloads() {
    let reader = FakeReader()
    reader.wii[1] = "MFi/0/Xbox Wireless Controller"
    let writer = FakeWriter()
    let model = ControllerHubViewModel(system: .wiiAndGameCube, reader: reader, writer: writer, notificationCenter: NotificationCenter())
    model.reload()
    model.setPlaysAs(model.state.players[0], .gameCube)
    XCTAssertEqual(writer.log, ["assign MFi/0/Xbox Wireless Controller gc-1", "clear wii-1"])
  }

  @MainActor
  func test_setPlaysAs_refusedAssign_leavesTheOldSlotAlone() {
    let reader = FakeReader()
    reader.wii[1] = "MFi/0/Xbox Wireless Controller"
    let writer = FakeWriter()
    writer.refuseAssign = true
    let model = ControllerHubViewModel(system: .wiiAndGameCube, reader: reader, writer: writer, notificationCenter: NotificationCenter())
    model.reload()
    model.setPlaysAs(model.state.players[0], .gameCube)
    XCTAssertEqual(writer.log, ["assign MFi/0/Xbox Wireless Controller gc-1"], "no clear after a refused assignment")
  }

  @MainActor
  func test_setPlaysAs_gameCubeToNunchuk_movesThenSetsExtension() {
    let reader = FakeReader()
    reader.gameCube[2] = "iOS/4/Touchscreen"
    let writer = FakeWriter()
    let model = ControllerHubViewModel(system: .wiiAndGameCube, reader: reader, writer: writer, notificationCenter: NotificationCenter())
    model.reload()
    let gc2 = model.state.players.first { $0.id == "gc-2" }!
    model.setPlaysAs(gc2, .wiiNunchuk)
    XCTAssertEqual(writer.log, ["assign iOS/4/Touchscreen wii-2", "clear gc-2", "ext 2 1", "side 2 false"])
  }

  @MainActor
  func test_setDevice_goesThroughTheWriter_andReloads() {
    let reader = FakeReader()
    let writer = FakeWriter()
    let model = ControllerHubViewModel(system: .gamecube, reader: reader, writer: writer, notificationCenter: NotificationCenter())
    model.reload()
    model.setDevice(model.state.players[0], .touchscreen)
    XCTAssertEqual(writer.log, ["setDevice touchscreen gc-1"])
  }

  @MainActor
  func test_reload_snapshotsPointerAndSetup() {
    let reader = FakeReader()
    reader.pointerMode = .gyro
    reader.motion = [2]
    reader.pinned = ["gc-1"]
    let model = ControllerHubViewModel(system: .wiiAndGameCube, reader: reader, writer: FakeWriter(), notificationCenter: NotificationCenter())
    model.reload()
    XCTAssertEqual(model.state.pointerMode, .gyro)
    XCTAssertTrue(model.state.players.first { $0.id == "wii-2" }!.motionPointerEnabled)
    XCTAssertTrue(model.state.players.first { $0.id == "gc-1" }!.isPinned)
    XCTAssertEqual(model.state.rumbleDestination, 1)
  }
```
Existing tests that construct `ControllerHubViewModel(system:reader:notificationCenter:)` keep compiling because `writer` gets a default of `LiveControllerHubWriter()`.

- [ ] **Step 2: Regenerate, run, verify failure.**

- [ ] **Step 3: The seam**

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
  /// False when the assignment was refused: `ControllerManager.assign` refuses a pad the
  /// ControllerInterface has not enumerated.
  func assign(qualifier: String, slot: PlayerSlot) -> Bool
  func clear(slot: PlayerSlot)
  func setExtension(_ value: Int, wiimote: Int)
  func setSideways(_ enabled: Bool, wiimote: Int)
  func setPointerMode(_ mode: PointerMode)
  func setMotionPointer(_ enabled: Bool, wiimote: Int)
  func setBackgroundInput(_ enabled: Bool)
  func setRumbleDestination(_ value: Int)
  func setConnectTakesPlayer1(_ enabled: Bool)
  func testRumble()
  func resetOverlayLayouts()
  func setTouchOverlayProgrammatic(_ enabled: Bool)
}

struct LiveControllerHubWriter: ControllerHubWriting {
  nonisolated init() {}

  private let io = LivePlayerScreenIO()

  func setDevice(_ choice: PlayerDeviceChoice, slot: PlayerSlot) { io.setDevice(choice, slot: slot) }

  func assign(qualifier: String, slot: PlayerSlot) -> Bool {
    let system: EmulatedSystem = slot.kind == .gameCube ? .gamecube : .wii
    if DeviceFamily.from(qualifier: qualifier) == .touchscreen {
      if system == .wii { ControllerManager.shared.assignTouchscreen(toWiimote: slot.port) } else { ControllerManager.shared.assignTouchscreen(toGCPort: slot.port) }
      return true
    }
    if let controller = GCController.controllers().first(where: { (TVControllerMappingBridge.qualifiedName(for: $0) as String) == qualifier }) {
      if system == .wii { ControllerManager.shared.assign(controller, toWiimote: slot.port) } else { ControllerManager.shared.assign(controller, toGCPort: slot.port) }
      return true
    }
    // A DSU device or a disconnected pad: bind the qualifier directly, as the player screen's Device list does.
    io.setDevice(.pad(qualifier), slot: slot)
    return true
  }

  func clear(slot: PlayerSlot) {
    ControllerManager.shared.clear(port: slot.port, system: slot.kind == .gameCube ? .gamecube : .wii)
  }

  func setExtension(_ value: Int, wiimote: Int) { WiimoteSlotOptions.setExtension(value, forWiimote: wiimote) }
  func setSideways(_ enabled: Bool, wiimote: Int) { WiimoteSlotOptions.setSideways(enabled, forWiimote: wiimote) }
  func setPointerMode(_ mode: PointerMode) { PointerModeController.shared.set(mode) }
  func setMotionPointer(_ enabled: Bool, wiimote: Int) { io.setMotionPointerEnabled(enabled, wiimote: wiimote) }
  func setBackgroundInput(_ enabled: Bool) { DOLConfigBridge.setMainBackgroundInput(enabled) }
  func setRumbleDestination(_ value: Int) { UserDefaults.standard.set(value, forKey: "rumble_destination") }
  func setConnectTakesPlayer1(_ enabled: Bool) { UserDefaults.standard.set(enabled, forKey: ControllerManager.connectTakesPlayer1DefaultsKey) }
  func testRumble() {
    #if os(iOS)
    ControllerLightsView.testRumble()   // moved from ControllerMoreSettingsView.testRumble in Task 6
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
`ControllerManager` wrapper, next to `assignTouchscreen(toWiimote:)`:
```swift
  /// Unbinds a port's device and deactivates nothing else; the mapping stays stashed for the
  /// device (`ControllerAssignmentService.clear`). The Plays as move's second half.
  func clear(port portOneBased: Int, system: EmulatedSystem) {
    assignmentService.clear(player: portOneBased - 1, system: system)
    reconcile(autoAssign: false)
  }
```
Check `LivePlayerScreenIO.setMotionPointerEnabled(_:wiimote:)` exists on the `PlayerScreenIO` protocol (the player view model calls `io.setMotionPointerEnabled(enabled, wiimote:)`), and whether `LivePlayerScreenIO()` has a `nonisolated` init; if not, construct it lazily inside each method.

- [ ] **Step 4: Reader, state, actions, view model**

`ControllerHubReading` gains the eight reads listed in Interfaces; `LiveControllerHubReader` implements them: `isPinned` → `ControllerManager.shared.isPinned(slot.kind == .gameCube ? .gamecube : .wii, player: slot.port - 1)`; `isMotionPointerEnabled` → `LivePlayerScreenIO().isMotionPointerEnabled(wiimote:)`; `pointerMode` → `PointerModeController.shared.mode`; `pointerIsThisGameOnly` → `.isThisGameOnly`; `backgroundInput` → `DOLConfigBridge.mainBackgroundInput()` (confirm the getter name in `ControllerMoreSettingsView`'s sync); `rumbleDestination` → `UserDefaults.standard.object(forKey: "rumble_destination") as? Int ?? 1`; `connectTakesPlayer1` → `ControllerManager.connectTakesPlayer1()`; `touchOverlayProgrammatic` → `TouchOverlayFlag.isProgrammatic` on iOS, `false` on tvOS.

`PlayerState` gains `var isPinned = false` and `var motionPointerEnabled = false` (defaulted so the memberwise calls in tests compile). `ControllerHubState` gains the six fields with defaults in `empty(system:)`: `.touchFollow, false, false, 1, true, true`. `ControllerHubActions` gains the closures and drops `moreSettingsDestination`.

`ControllerHubViewModel`:
```swift
  private let writer: any ControllerHubWriting

  init(system: ControllerSetupSystem, reader: any ControllerHubReading = LiveControllerHubReader(),
       writer: any ControllerHubWriting = LiveControllerHubWriter(), notificationCenter: NotificationCenter = .default)
```
`reload()` fills the new `PlayerState` fields (`isPinned: reader.isPinned(slot)`, `motionPointerEnabled: slot.kind == .wiiRemote ? reader.isMotionPointerEnabled(wiimote: slot.port) : false`) and the hub fields.
```swift
  func setDevice(_ player: PlayerState, _ choice: PlayerDeviceChoice) {
    writer.setDevice(choice, slot: PlayerSlot(kind: player.kind, port: player.port))
    reload()
  }

  /// Runs `PlaysAsTransition.plan` in order. A refused `moveDevice` stops the plan (spec §8).
  func setPlaysAs(_ player: PlayerState, _ target: PlaysAs) {
    for step in PlaysAsTransition.plan(from: player, to: target) {
      switch step {
      case .setExtension(let wiimote, let value): writer.setExtension(value, wiimote: wiimote)
      case .setSideways(let wiimote, let enabled): writer.setSideways(enabled, wiimote: wiimote)
      case .clearSlot(let slot): writer.clear(slot: slot)
      case .moveDevice(let qualifier, let from, let to):
        guard writer.assign(qualifier: qualifier, slot: to) else {
          notificationCenter.post(name: .dolShowSnackbar, object: nil, userInfo: [EmulationToast.textKey: L("Couldn't move the controller")])
          reload()
          return
        }
        writer.clear(slot: from)
      }
    }
    reload()
  }
```
`actions` wires: `setDevice: { [weak self] in self?.setDevice($0, $1) }`, `setPlaysAs: { [weak self] in self?.setPlaysAs($0, $1) }`, `setPointerMode: { [weak self] mode in self?.writer.setPointerMode(mode); self?.reload() }`, `setMotionPointer: { [weak self] player, on in self?.writer.setMotionPointer(on, wiimote: player.port); self?.reload() }`, the four setup setters likewise (write then reload), `testRumble: { [weak self] in self?.writer.testRumble() }`, `resetOverlayLayouts`, `setTouchOverlayProgrammatic`, `lightsDestination: { AnyView(ControllerLightsView().padBackNavigation()) }` (the view arrives in Task 6; until then return `AnyView(EmptyView())` and fix it in Task 6).

- [ ] **Step 5: Build both platforms; run `ControllerHubViewModelTests`** (new tests pass, old ones unchanged).

- [ ] **Step 6: Commit**

```bash
git add Common/Swift/Controllers/Hub/ControllerHubWriting.swift Common/Swift/Controllers/Hub/ControllerHubState.swift Common/Swift/Controllers/Hub/ControllerHubViewModel.swift Common/Swift/Controllers/ControllerManager.swift DolphiniOSTests/ControllerHubViewModelTests.swift
git commit -m "feat(controllers): hub write seam, Plays as and device setters"
```

---

### Task 4: Hub model — player groups, Touch Controls, Setup

**Files:**
- Modify: `Hub/ControllerHubModelBuilder.swift`
- Test: `DolphiniOSTests/ControllerHubModelBuilderTests.swift`

**Interfaces:**
- Consumes: Task 1 `PlaysAs`, Task 3 state and actions.
- Produces: sections `players`, `touch-controls` (iOS), `devices`, `setup`, `help`; row ids per Global Constraints.

- [ ] **Step 1: Update the tests**

In `ControllerHubModelBuilderTests`, the `actions(...)` helper adds the new closures with recording defaults (`setDevice: { _, _ in }`, `setPlaysAs: { _, _ in }`, `setPointerMode: { _ in }`, `setMotionPointer: { _, _ in }`, `setBackgroundInput: { _ in }`, `setRumbleDestination: { _ in }`, `setConnectTakesPlayer1: { _ in }`, `testRumble: {}`, `setTouchOverlayProgrammatic: { _ in }`, `resetOverlayLayouts: {}`, `lightsDestination: { AnyView(EmptyView()) }`) and drops `moreSettingsDestination`. Then:

- `test_iOS_sectionOrder` expects `["players", "touch-controls", "devices", "setup", "help"]`; `test_tvOS_hasNoOnScreenControls` expects `["players", "devices", "setup", "help"]`.
- Replace `test_playerRow_namesThePortTheDeviceAndTheEmulatedController` with:
```swift
  func test_playerGroup_titleDevicePlaysAs_andPointerOnATouchscreenWiiRow() {
    let model = make(state(system: .wiiAndGameCube, bound: ["wii-1": Self.touch, "gc-2": Self.xbox], wiiExtension: [1: 1],
                           pads: [ConnectedPadState(qualifier: Self.xbox, name: "Xbox", batteryPercent: nil, isCharging: false, playerLabel: nil)]))
    XCTAssertEqual(ids(model, section: "players"), ["wii-1", "wii-1-device", "wii-1-plays-as", "wii-1-pointer", "gc-2", "gc-2-device", "gc-2-plays-as", "show-all-ports"])
    XCTAssertEqual(model.item(id: "wii-1")?.title, "Wii Remote 1")
    XCTAssertEqual(model.item(id: "wii-1-plays-as")?.currentValueTitle, "Wii Remote + Nunchuk")
    XCTAssertEqual(model.item(id: "wii-1-device")?.currentValueTitle, "Touchscreen")
    XCTAssertEqual(model.item(id: "gc-2-device")?.currentValueTitle, "Xbox")
    XCTAssertEqual(model.item(id: "gc-2-plays-as")?.currentValueTitle, "GameCube Controller")
  }

  func test_playsAs_gameCubeTitle_hasNoPlaysAsRow() {
    let model = make(state(system: .gamecube, bound: ["gc-1": Self.xbox]))
    XCTAssertEqual(ids(model, section: "players"), ["gc-1", "gc-1-device", "show-all-ports"])
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

  func test_device_cycleOffersNoneTouchscreenAndPads_andAutoOnAPinnedPort() {
    var hub = state(system: .gamecube, bound: ["gc-1": Self.xbox], pads: [ConnectedPadState(qualifier: Self.xbox, name: "Xbox", batteryPercent: nil, isCharging: false, playerLabel: nil)])
    hub.players[0].isPinned = true
    guard case .cycle(let options, _)? = make(hub).item(id: "gc-1-device")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Auto", "None", "Touchscreen", "Xbox"])
    guard case .cycle(let tvOptions, _)? = make(hub, platform: .tvos).item(id: "gc-1-device")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(tvOptions.map(\.0), ["Auto", "None", "Xbox"], "no touchscreen on tvOS")
  }

  func test_pointerRow_touchscreenWii_cyclesPointerMode_gyroPad_togglesMotion_padWithoutGyro_none() {
    var hub = state(system: .wiiAndGameCube, bound: ["wii-1": Self.touch, "wii-2": Self.xbox, "wii-3": "MFi/1/Plain Pad"],
                    pads: [ConnectedPadState(qualifier: Self.xbox, name: "Xbox", batteryPercent: nil, isCharging: false, playerLabel: nil, hasGyro: true),
                           ConnectedPadState(qualifier: "MFi/1/Plain Pad", name: "Plain", batteryPercent: nil, isCharging: false, playerLabel: nil)])
    hub.pointerMode = .gyro
    let model = make(hub)
    guard case .cycle(let options, _)? = model.item(id: "wii-1-pointer")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Touch – Follow", "Touch – Drag", "Gyro"])
    guard case .toggle? = model.item(id: "wii-2-pointer")?.role else { return XCTFail("toggle") }
    XCTAssertNil(model.item(id: "wii-3-pointer"))
    XCTAssertNil(make(hub, platform: .tvos).item(id: "wii-1-pointer"), "no touchscreen pointer on tvOS")
  }

  func test_touchControls_layoutRow_isNamedLayout_withAutoGameCubeWiiRemote() {
    let model = make(state(system: .wii))
    XCTAssertEqual(ids(model, section: "touch-controls"), ["touch-visible", "touch-layout", "touch-opacity", "touch-editable", "touch-edit-layout", "touch-edit-ir-area", "touch-skins", "touch-reset-layouts"])
    let layout = model.item(id: "touch-layout")!
    XCTAssertEqual(layout.title, "Layout")
    guard case .cycle(let options, _) = layout.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Auto", "GameCube", "Wii Remote"])
    XCTAssertTrue(layout.description!.contains("Auto follows Player 1"))
  }

  func test_setup_rows_iOS_and_tvOS() {
    XCTAssertEqual(ids(make(state(system: .gamecube)), section: "setup"), ["background-input", "takes-player-1", "rumble", "rumble-test", "dsu"])
    XCTAssertEqual(ids(make(state(system: .gamecube), platform: .tvos), section: "setup"), ["background-input", "dsu"])
  }

  func test_lightsRow_onlyWithALitPad() {
    var pad = ConnectedPadState(qualifier: Self.xbox, name: "Xbox", batteryPercent: nil, isCharging: false, playerLabel: nil)
    XCTAssertFalse(ids(make(state(system: .gamecube, pads: [pad])), section: "devices").contains("lights"))
    pad.hasLight = true
    XCTAssertTrue(ids(make(state(system: .gamecube, pads: [pad])), section: "devices").contains("lights"))
  }
```
Rename `test_stylePicker_offersAutoGameCubeWii_andWritesThroughTheAction` to use id `touch-layout` and option titles `Auto, GameCube, Wii Remote`; `test_showHideAndStyleRows_onlyWhileAGameRuns` to ids `touch-visible`/`touch-layout`; `test_opacityPicker...` to `touch-opacity`; `test_editLayout_runsAnAction` to `touch-edit-layout`; `test_skins_*` to `touch-skins`; `test_editIRArea_*` to `touch-edit-ir-area`. Remove the "more" section assertions. `ConnectedPadState` gains `var hasLight = false` (set by `LiveControllerHubReader.connectedPads` from `controller.light != nil`).

- [ ] **Step 2: Run, verify failure.**

- [ ] **Step 3: Implement the builder**

Replace `playersSection`, `onScreenSection`, the `more` section and the devices rows:
```swift
  static func make(state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuModel {
    var sections = [playersSection(state: state, actions: actions, platform: platform)]
    if platform == .ios {
      sections.append(touchControlsSection(state: state, actions: actions))
    }
    sections.append(devicesSection(state: state, actions: actions))
    sections.append(setupSection(state: state, actions: actions, platform: platform))
    sections.append(helpSection(platform: platform))
    return MenuModel(sections: sections)
  }

  // MARK: Players: a group per port (spec §7.1, deviation: rows, not pills)

  private static func playersSection(state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuSection {
    let bound = state.players.filter(\.isBound)
    let shown = state.showAllPorts ? state.players : bound
    var items: [MenuItem] = []
    for player in shown {
      items.append(MenuItem(
        id: player.id, title: title(for: player), icon: player.kind == .gameCube ? "gamecontroller" : "wand.and.rays",
        role: .destination(actions.playerDestination(player)),
        description: L("Remap buttons, profiles, motion and advanced settings.")))
      items.append(deviceRow(for: player, state: state, actions: actions, platform: platform))
      let options = PlaysAs.options(for: state.system)
      if options.count > 1 {
        items.append(MenuItem(
          id: "\(player.id)-plays-as", title: L("Plays as"), icon: "person.crop.rectangle",
          role: .cycle(options: options.map { ($0.title, AnyHashable($0)) }, selection: Binding(
            get: { AnyHashable(PlaysAs.current(of: player)) },
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

  /// Auto (pinned port only), None, Touchscreen (iOS), each connected pad, and the bound device when
  /// it is none of those, so the row can show it. Same list as the player screen's Device list.
  private static func deviceRow(for player: PlayerState, state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuItem {
    var options: [(String, AnyHashable)] = []
    if player.isPinned { options.append((L("Auto"), AnyHashable(PlayerDeviceChoice.automatic))) }
    options.append((L("None"), AnyHashable(PlayerDeviceChoice.noDevice)))
    if platform == .ios { options.append((L("Touchscreen"), AnyHashable(PlayerDeviceChoice.touchscreen))) }
    options += state.pads.map { ($0.name, AnyHashable(PlayerDeviceChoice.pad($0.qualifier))) }
    let current = PlayerDeviceChoice(qualifier: player.deviceQualifier)
    if case .pad = current, !options.contains(where: { $0.1 == AnyHashable(current) }) {
      options.append((deviceName(for: player, pads: state.pads), AnyHashable(current)))
    }
    return MenuItem(
      id: "\(player.id)-device", title: L("Device"), icon: player.isPinned ? "pin.fill" : "gamecontroller",
      role: .cycle(options: options, selection: Binding(
        get: { AnyHashable(current) },
        set: { if let choice = $0.base as? PlayerDeviceChoice { actions.setDevice(player, choice) } })),
      description: player.isPinned ? L("You chose this device; controllers that connect leave this player alone. Auto lets them take it.")
                                   : L("The controller or touchscreen this player uses."))
  }

  /// Touchscreen Wii Remote (iOS): the pointer mode. Gyro pad: Motion on/off. Otherwise none.
  private static func pointerRow(for player: PlayerState, state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuItem? {
    guard player.kind == .wiiRemote, player.isBound else { return nil }
    let isTouch = DeviceFamily.from(qualifier: player.deviceQualifier) == .touchscreen
    if isTouch {
      guard platform == .ios else { return nil }
      let modes: [PointerMode] = [.touchFollow, .touchDrag, .gyro]
      return MenuItem(
        id: "\(player.id)-pointer", title: L("Pointer"), icon: state.pointerMode.systemImage,
        role: .cycle(options: modes.map { ($0.title, AnyHashable($0)) }, selection: Binding(
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

  // MARK: Touch Controls (iOS; was On-Screen Controls)

  private static func touchControlsSection(state: ControllerHubState, actions: ControllerHubActions) -> MenuSection {
    var items: [MenuItem] = []
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
          get: { AnyHashable(state.overlayMode) },
          set: { if let mode = $0.base as? ControllerManager.OverlayMode { actions.setOverlayMode(mode) } })),
        description: L("Which on-screen controller is drawn. Auto follows Player 1's Plays as.")))
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
      let rumble: [(String, AnyHashable)] = [(L("Device Haptics"), 0), (L("Controller"), 1), (L("Both"), 2)]
      items.append(MenuItem(
        id: "rumble", title: L("Rumble Output"), icon: "waveform",
        role: .cycle(options: rumble, selection: Binding(
          get: { AnyHashable(state.rumbleDestination) },
          set: { if let value = $0.base as? Int { actions.setRumbleDestination(value) } })),
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
`devicesSection` keeps its pad rows and loses the DSU row (now in Setup); after the pad rows, when `state.pads.contains(where: \.hasLight)` and `platform == .ios`, append `MenuItem(id: "lights", title: L("Controller Lights"), icon: "lightbulb", role: .destination(actions.lightsDestination()), description: L("The colour of each controller's light bar."))`. Delete the old `onScreenSection` and `emulatedController(for:)`; `deviceName(for:pads:)` stays (used by `deviceRow`). `devicesSection` needs the `platform` parameter.

- [ ] **Step 4: Build both platforms; run `ControllerHubModelBuilderTests`.**

- [ ] **Step 5: Commit**

```bash
git add Common/Swift/Controllers/Hub/ControllerHubModelBuilder.swift Common/Swift/Controllers/Hub/ControllerHubState.swift Common/Swift/Controllers/Hub/ControllerHubViewModel.swift DolphiniOSTests/ControllerHubModelBuilderTests.swift
git commit -m "feat(controllers): hub rows for device, plays as and pointer; Touch Controls and Setup"
```

---

### Task 5: Player detail screen — drop Extension/Sideways, add the moved rows

**Files:**
- Modify: `Player/PlayerScreenModelBuilder.swift` (delete `wiiSection`; add rows), `Player/PlayerScreenState.swift` (`PlayerScreenActions` loses `setExtension`/`setSideways`, gains `advancedMotionDestination`, `stickFeelDestination`), `Player/PlayerScreenViewModel.swift` (delete `setExtension`/`setSideways`, wire the two destinations)
- Test: `DolphiniOSTests/PlayerScreenModelBuilderTests.swift` and any other test constructing `PlayerScreenActions`

- [ ] **Step 1: Update the tests**

Delete `test_extensionOptions_sayExtensionOnTVOS`. In every `PlayerScreenActions(...)` construction in the tests, remove `setExtension:`/`setSideways:` and add `advancedMotionDestination: { AnyView(EmptyView()) }, stickFeelDestination: { AnyView(EmptyView()) }`. Add:
```swift
  func test_wiiPort_hasNoWiiRemoteSection_playsAsLivesInTheHub() {
    let model = make(wiiTouchState(), platform: .ios)
    XCTAssertFalse(model.sections.contains { $0.id == "wii" })
  }

  func test_pointerSection_endsWithAdvancedMotion_onTheTouchscreen() {
    let model = make(wiiTouchState(), platform: .ios)
    XCTAssertEqual(model.sections.first { $0.id == "pointer" }?.items.last?.id, "pointer-advanced")
  }

  func test_touchscreenPort_offersStickFeel_padDoesNot() {
    XCTAssertNotNil(make(wiiTouchState(), platform: .ios).item(id: "stick-feel"))
    XCTAssertNil(make(gcPadState(), platform: .ios).item(id: "stick-feel"))
  }
```
`wiiTouchState()` / `gcPadState()` are whatever the file's existing helpers for a touchscreen Wii port and a pad-bound GameCube port are called; use those names.

- [ ] **Step 2: Run, verify failure.**

- [ ] **Step 3: Implement**

In `PlayerScreenModelBuilder.make`, remove the `wiiSection` append and the function. In `pointerSection` (touchscreen branch), append after the shake row:
```swift
    items.append(MenuItem(
      id: "pointer-advanced", title: L("Advanced Motion…"), icon: "gyroscope",
      role: .destination(actions.advancedMotionDestination()),
      description: L("Smoothing, dead zones and the motion sensor's own options.")))
```
After the pointer section, when `state.isTouchscreen` (any kind):
```swift
    if state.isTouchscreen {
      sections.append(MenuSection(id: "stick-feel", items: [MenuItem(
        id: "stick-feel", title: L("On-Screen Stick Feel…"), icon: "l.joystick",
        role: .destination(actions.stickFeelDestination()),
        description: L("Gain, dead zone and smoothing of the on-screen sticks and triggers."))]))
    }
```
`PlayerScreenActions`: remove `setExtension`, `setSideways`; add `var advancedMotionDestination: () -> AnyView` and `var stickFeelDestination: () -> AnyView`. `PlayerScreenViewModel.actions`: `advancedMotionDestination: { AnyView(EnhancedMotionControlsView().padBackNavigation()) }`, `stickFeelDestination: { AnyView(AnalogStickSettingsView().padBackNavigation()) }`; delete `setExtension(_:)`, `setSideways(_:)`. `PlayerScreenIO` keeps its extension/sideways writes (the hub writer uses `WiimoteSlotOptions` directly; remove them from the protocol only if nothing else calls them; grep first).

- [ ] **Step 4: Build both platforms; run `PlayerScreenModelBuilderTests`, `PlayerScreenViewModelTests`, `PlayerScreenLeavesTests`, `PlayerScreenIOTests`.**

- [ ] **Step 5: Commit**

```bash
git add Common/Swift/Controllers/Player DolphiniOSTests/PlayerScreen*Tests.swift
git commit -m "refactor(controllers): player screen drops Extension/Sideways, gains Advanced Motion and Stick Feel"
```

---

### Task 6: Delete More Controller Settings; Controller Lights view

**Files:**
- Create: `Common/UI/Settings/SwiftUI/ControllerLightsView.swift`
- Delete: `Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift`
- Modify: `Hub/ControllerHubViewModel.swift` (`lightsDestination` real view), `Hub/ControllerHubWriting.swift` (`testRumble` real implementation)

- [ ] **Step 1: Extract the lights view**

`ControllerLightsView` is the old file's `Controller Lights` section as its own `List`: `@State private var litControllers: [GCController]`, refreshed on appear and on `GCControllerDidConnect`/`Disconnect`, one `ColorPicker` row per controller with a light using the old `ledBinding(for:)`. Title `Controller Lights`. Wrap the file in `#if os(iOS)`. Move the old `static func testRumble()` onto it (a static on an iOS-only type; `LiveControllerHubWriter.testRumble` already guards with `#if os(iOS)`).

- [ ] **Step 2: Delete the old view**

`git rm Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift`. Grep for `ControllerMoreSettingsView` (expected: no remaining references; `ControllersRootView.swift`'s doc comment mentions it, update the comment). The DEBUG `Gallery` link it had (`TouchOverlayGalleryView`) moves to `DebugRootView` as a `NavigationLink` under `#if os(iOS) && DEBUG`.

- [ ] **Step 3: Build both platforms, run the whole test target.**

- [ ] **Step 4: Commit**

```bash
git add Common/UI/Settings/SwiftUI/ControllerLightsView.swift Common/UI/Settings/SwiftUI/DebugRootView.swift Common/UI/Settings/SwiftUI/ControllersRootView.swift Common/Swift/Controllers/Hub
git rm Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift
git commit -m "refactor(controllers): fold More Controller Settings into the hub"
```

---

### Task 7: Device gates and PR

- [ ] **Step 1: iPhone, Wii title (Xbox pad connected, touchscreen available)**

1. Open Controllers from the pause overlay. Wii Remote 1 shows four rows: title, Device, Plays as, Pointer. Left/right on the pad cycles each; long-press of A opens the list.
2. Set Wii Remote 1 Plays as to Wii Remote + Nunchuk. Resume: the game sees the Nunchuk (a Nunchuk-required title such as Wii Sports Resort's or any title showing the Nunchuk prompt).
3. Set it to GameCube Controller: the row moves under "Player 1"; the game sees a GameCube pad (a title that accepts both, such as Mario Kart Wii).
4. Set it back to Wii Remote Sideways: the row returns as "Wii Remote 1"; the touch overlay draws the sideways layout when the device is the touchscreen.
5. Touch Controls → Layout cycles Auto / GameCube / Wii Remote; choosing Wii Remote draws the Wii overlay and binds Wii Remote 1 to the touchscreen as before.
6. Setup: Rumble Output cycles; Test Rumble pulses; Background Input toggles and survives leaving the hub.
7. Player 1 title row still opens the detail screen; it has no Extension or Sideways rows and does have Advanced Motion… and On-Screen Stick Feel… (touchscreen) rows.

- [ ] **Step 2: Apple TV, Wii title (Xbox pad)**

1. Hub from the pause overlay: Device row cycles with left/right; Plays as cycles; no Pointer row for the pad unless it has a gyro; no Touch Controls section; Setup shows Background Input and Motion Source only.
2. Change Plays as and press Menu back to the game: still paused (PR 1), and the change applies on resume.

- [ ] **Step 3: Open the PR against `develop`**

Title: `feat(controllers): hub rows for Device, Plays as and Pointer; Touch Controls`. Body: spec §7 summary, the three deviations at the top of this plan, device gate results, and a note that `ControllerMoreSettingsView` is gone (its rows are in Setup, Touch Controls, Connected Devices, and the player screen). Do not push `develop`.
