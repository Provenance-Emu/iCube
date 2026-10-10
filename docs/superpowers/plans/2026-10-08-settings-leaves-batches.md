# Remaining Settings Leaves Implementation Plan (three batches)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Executors see only their own task** (from its `### Task` heading to the next one). Every task therefore repeats the rules it needs (read-first list, rulings, existing-test edits, close-out). If a rule changes, change it in every task.

**Goal:** Every settings leaf that is a plain form renders through the menu engine, in three independently mergeable batches, so the sidebar shell, descriptions, controller adjustment and generated search cover all of Settings.

**Architecture:** The PR 3 leaf pattern, repeated, with nothing new invented:

- `Leaves/<Leaf>State.swift`: an `Equatable` `State` snapshot (defaults copy the old view's `@State` defaults), a `Change` enum (one case per user edit; a `Flag` enum with a `keyPath` when a screen has more than ~12 Bool rows, as `PerformanceTuningState` does), and named UserDefaults keys.
- `Leaves/<Leaf>ModelBuilder.swift`: a pure `ModelBuilder.make(state:apply:)` built from the `SettingsRow` factory (`toggle`/`cycle`/`stepper`/`action`/`destination`, plus `custom`/`destructive`/`caption` from Task 1). It never reads a bridge, a singleton or UserDefaults.
- `Leaves/<Leaf>View.swift`: the host. `sync()` only READS Config/UserDefaults into a fresh `State` (`var s = State(); …; state = s`) and writes nothing; `apply(_:)` is the only writer; body is `SettingsLeafScreen(model:title:helpKey:sync:)`, which gives pad Back and the sidebar pane Back. The one exception is Q3's seed step (Config Advanced has none; General and GameCube do).
- `DolphiniOSTests/<Leaf>ModelBuilderTests.swift`: table-driven (every row emits its own `Change`, both values for toggles), pure normalisers/seeders tested, no "nothing is written on build" tests.

**Tech Stack:** Swift 5, SwiftUI, XCTest (`iCubeTests`), Tuist.

**Spec:** `docs/superpowers/specs/2026-10-07-unified-menu-ux-design.md` §6.5, §10 item 5. Depends on PR 3 (`SettingsLeafScreen`, `SettingsRow`, `SettingsRootModelBuilder`, `SettingsSearchIndex`, `ValueStepper`). Ground truth for the pattern is PR 3's shipped code: `Leaves/GraphicsGeneral*`, `Leaves/GraphicsEnhancements*`, `Leaves/GraphicsHacks*`, `Leaves/PerformanceTuning*`.

## What stays hand-built, and why

| Leaf | Reason |
|---|---|
| `ConfigAchievementsView` | Username/password text entry and a login button with async state. No text role in the engine; a `.custom` row would just re-embed the form. |
| `ShaderSettingsView` | Preset picker with rendered previews and a parameter editor. |
| `CloudSyncSettingsView`, `ContinuityBrowseView`, `DSUSettingsView`, `PerformanceABView`, `SkinPickerView`, `ControllerLightsView`, `WebUISettingsView`, `AboutView` | Lists of live things (devices, servers, snapshots, skins, URLs), not settings forms. |
| `AudioEffectEditors` | Effect chains with per-effect parameter sliders. The Audio leaf embeds them inline as `.custom` rows (iOS only); they are not rewritten. |

These keep their `.destination(AnyView)` entry in `SettingsRootModelBuilder` and show up in search by title, description and keywords only.

## Global Constraints

The `Q1`-`Q11` tags in the tasks refer to the controller's decided rulings (`.superpowers/sdd/pr5-rulings.md`, controller-side); each task states what the ruling means for it, so you do not need that file.

Paths are relative to `Source/iOS/App/` unless absolute. `SW/` means `Common/UI/Settings/SwiftUI/`, `Leaves/` means `SW/Leaves/`, `Tests/` means `DolphiniOSTests/`.

- **Order and merging.** Task 1 (shared extensions), then Batch A (Tasks 2-4), Batch B (Tasks 5-7), Batch C (Tasks 8-12). There are no pull requests and no on-device test tasks: the last task of a batch ends with "Stop: the controller merges this batch into develop after review." Batch A branches from develop after PR 3 (`feat/settings-engine`) has merged; Batch B from develop after Batch A merged; **Batch C from develop after PR 4 (`feat/controller-hub-reorg`) has merged**, because it edits `DebugRootView`, `ControllersRootView`, `PlayerScreenViewModel` and `DSUControllerView` as PR 4 leaves them.
- **Worktree per batch:** `feat/settings-leaves-a`, `-b`, `-c`. After `git worktree add`, run `git config --worktree core.worktree <absolute worktree path>` and confirm `git rev-parse --show-toplevel`. DO NOT git reset / rebase / push / touch develop.
- **One leaf per task, suite green after each task.** Create the host and `git rm` the old file in the same step (two `struct ConfigAdvancedView` in the module will not compile). Move any shared enum or sub-view the old file defined before deleting it.
- **Row ids** lowercase-kebab, unique within a leaf. **Descriptions** are the old captions copied verbatim; where the old row had no caption, or the old text lived in a deleted picker screen's `HelpButton` (plain text, markup stripped), fold it into the row description (Q9). A row with no old text gets one written sentence. Never a nil/empty description. `L()` every user-visible string; old raw literals ("Background Style", "MEM1", "Clean") become `L()` keys.
- **`apply(_:)` keeps every side effect the old `onSet` closure had.** Read the old file in full before deleting it; the row tables here are a survey, not a substitute for reading the captions and closures.
- **Migrated leaves with a root entry** register `hostsMenuScreen: true` AND `makeModel:` in `SettingsRootModelBuilder.sections` (so `pushedView()` does not add a second pad-Back scope and search sees the rows), and the batch updates the three root/search tests that hardcode the migrated set (Q1, spelled out per task).
- **Tests** follow PR 3's ledger P10: table-driven, no "nothing on build" tests, pure normalisers/seeders tested.
- **Verification commands** (from `Source/iOS/App`):
  - after adding/deleting files: `tuist generate --no-open`
  - one class: `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/<Class>"`
  - whole target (end of each batch): `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro"`
  - tvOS compile: `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos`
  - localisation: `python3 Project/Scripts/check_localized_keys.py --check` exits 0; each new `L("...")` key gets an identity line `"key" = "key";` appended to `Common/UI/Localization/en.lproj/Core.strings` and `ja.lproj/Core.strings`
- **Never commit** build-generated `Core.strings` drift (stage only your own lines with `git add -p`) or `build/xcframework` (`git checkout -- build/xcframework` before committing). Commit subjects ≤ 72 chars, conventional commits, no attribution trailer of any kind.

## Existing tests that change (summary; each task spells out its own edit)

| Test | Changes in | How |
|---|---|---|
| `SettingsRootModelBuilderTests.test_hostsMenuScreen_isExactlyTheMigratedLeavesAndControllers` | Tasks 2, 3, 4, 5, 6, 7, 8, 11 | its hardcoded id set gains the migrated leaf's entry id |
| `SettingsRootModelBuilderTests.test_migratedLeaves_exposeTheirModels` | same | the id list gains the entry; Task 11 also deletes the `debug` nil-`makeModel` assertion |
| `SettingsSearchIndexTests.test_keyword_matchesAHandBuiltLeaf` | Task 11 | `debug` stops being hand-built; test becomes a description match on the hand-built `web-ui` entry |
| `SettingsSearchIndexTests` (new assertion per leaf) | Tasks 2-8, 11 | a row title from the migrated leaf is found |
| `SettingsRowFactoryTests` | Task 1 | one test per new factory function |

---

### Task 1: Shared extensions (SettingsRow kinds, shared enums)

**Branch:** `feat/settings-leaves-a` from develop once PR 3 has merged. This is the first commit on it; nothing else lands before it (Q8).

**Why first:** Batches then touch only their own leaves plus root/search registration and `Core.strings`. `SettingsLeafScreen` needs no new parameter (Q4: the Audio alert attaches `.alert` to the host); `SettingsLeafHost.swift` is not expected to change. If a later task finds it needs a host addition, amend this task, do not fork the pattern.

**Read first:** `Leaves/SettingsRowFactory.swift`, `Tests/SettingsRowFactoryTests.swift`, `SW/SettingsEnums.swift`, `PlayerHelpCaption` in `Common/Swift/Controllers/Player/PlayerScreenModelBuilder.swift`, `SW/ConfigGeneralView.swift` (private `Region`), `SW/ConfigInterfaceView.swift` (nested `LibraryBackgroundStyle`), `SW/EnhancedMotionControlsView.swift` (nested `HorizontalMotionMode`).

**Files:**
- Modify: `Leaves/SettingsRowFactory.swift`, `SW/SettingsEnums.swift`
- Modify (mechanical, so the old views keep compiling against the moved enums): `SW/ConfigGeneralView.swift`, `SW/ConfigInterfaceView.swift`, `SW/EnhancedMotionControlsView.swift`
- Modify: `Tests/SettingsRowFactoryTests.swift`; create `Tests/SettingsEnumsTests.swift`
- Modify: both `Core.strings` (three new keys, below)

**Rulings applied:** Q8 (this whole task), Q4 (`Region` becomes internal in SettingsEnums with its Error case; the picker excludes Error), Q10.

- [ ] **Step 1: Tests first.** Add to `SettingsRowFactoryTests`:

```swift
func test_custom_isACustomRow_withDescription_andEnabledFlag() {
  let item = SettingsRow.custom("c", "Custom", AnyView(EmptyView()), "Describes it.", enabled: false)
  XCTAssertEqual(item.title, "Custom")
  XCTAssertEqual(item.description, "Describes it.")
  XCTAssertFalse(item.isEnabled)
  guard case .custom = item.role else { return XCTFail("custom") }
}

func test_destructive_runsItsClosure_andKeepsDescriptionAndIcon() {
  var runs = 0
  let item = SettingsRow.destructive("d", "Forget", "Forgets them.", icon: "trash") { runs += 1 }
  XCTAssertEqual(item.description, "Forgets them.")
  XCTAssertEqual(item.icon, "trash")
  guard case .destructive(let run) = item.role else { return XCTFail("destructive") }
  run()
  XCTAssertEqual(runs, 1)
}

func test_caption_isADisabledTextRow_whoseDescriptionIsItsText() {
  let item = SettingsRow.caption("hint", "Do the thing first.")
  XCTAssertFalse(item.isEnabled, "a caption is never focused")
  XCTAssertEqual(item.description, "Do the thing first.")
  guard case .custom = item.role else { return XCTFail("custom") }
}

func test_icon_isForwardedByToggleCycleAndStepper() {
  XCTAssertEqual(SettingsRow.toggle("t", "T", true, "d", icon: "star") { _ in }.icon, "star")
  XCTAssertEqual(SettingsRow.cycle("c", "C", [("A", 1)], 1, "d", icon: "star") { _ in }.icon, "star")
  XCTAssertEqual(SettingsRow.stepper("s", "S", 1, range: 0 ... 2, step: 1, format: { "\($0)" }, "d", icon: "star") { _ in }.icon, "star")
}
```

Create `Tests/SettingsEnumsTests.swift`:

```swift
final class SettingsEnumsTests: XCTestCase {
  func test_region_selectableExcludesTheErrorPlaceholder_andKeepsTheRawValues() {
    XCTAssertEqual(Region.selectable, [.ntscJ, .ntscU, .pal, .ntscK])
    XCTAssertEqual(Region.ntscJ.rawValue, 0); XCTAssertEqual(Region.ntscU.rawValue, 1); XCTAssertEqual(Region.pal.rawValue, 2)
    XCTAssertEqual(Region.unknown.rawValue, 3); XCTAssertEqual(Region.ntscK.rawValue, 4)
  }

  func test_region_unknownRawValuesReadAsTheErrorCase() {
    for raw in [3, 5, -1, 99] { XCTAssertEqual(Region.from(raw: raw), .unknown, "raw \(raw)") }
    XCTAssertEqual(Region.unknown.label, "Error")
  }

  func test_libraryBackgroundStyle_unsetOrUnknownStoredValueIsGradient() {
    XCTAssertEqual(LibraryBackgroundStyle.from(stored: nil), .gradient)
    XCTAssertEqual(LibraryBackgroundStyle.from(stored: "bogus"), .gradient)
    for style in LibraryBackgroundStyle.allCases { XCTAssertEqual(LibraryBackgroundStyle.from(stored: style.rawValue), style) }
  }

  func test_horizontalMotionMode_rawValuesAndLabels() {
    XCTAssertEqual(HorizontalMotionMode.roll.rawValue, 0)
    XCTAssertEqual(HorizontalMotionMode.yaw.rawValue, 1)
    XCTAssertFalse(HorizontalMotionMode.roll.label.isEmpty)
    XCTAssertFalse(HorizontalMotionMode.yaw.description.isEmpty)
  }
}
```

- [ ] **Step 2: Factory.** In `Leaves/SettingsRowFactory.swift` add an `icon: String? = nil` parameter (after `badge:`, before `set:`) to `toggle`, `cycle` and `stepper`, passing it to `MenuItem(icon:)`; existing callers are unaffected. Add:

```swift
/// A row the engine has no role for. A `.custom` row renders only its view, so the view carries its own title.
static func custom(_ id: String, _ title: String, _ view: AnyView, _ description: String, enabled: Bool = true) -> MenuItem {
  MenuItem(id: id, title: title, role: .custom(view), isEnabled: enabled, description: description)
}

static func destructive(_ id: String, _ title: String, _ description: String, icon: String? = nil,
                        enabled: Bool = true, run: @escaping () -> Void) -> MenuItem {
  MenuItem(id: id, title: title, icon: icon, role: .destructive(run), isEnabled: enabled, description: description)
}

/// Read-only text: never focused (`isEnabled` false), so a pad's focus walks past it and tvOS skips it.
/// `description` carries the same text so "every row is described" holds for captions too.
static func caption(_ id: String, _ text: String) -> MenuItem {
  MenuItem(id: id, title: text, role: .custom(AnyView(PlayerHelpCaption(text: text))), isEnabled: false, description: text)
}
```
A read-only status row ("JIT: Acquired") needs no new API: it is `SettingsRow.action(id, title, description, enabled: false, badge: value, run: {})`, the form `PerformanceTuningModelBuilder` already uses.

- [ ] **Step 3: Enums.** Append to `SW/SettingsEnums.swift`:

```swift
// MARK: - General / Interface / Motion

/// Mirrors Dolphin's DiscIO::Region. Raw values are what `mainFallbackRegion()` stores; `unknown` is the core's Error value.
enum Region: Int, CaseIterable { case ntscJ = 0, ntscU = 1, pal = 2, unknown = 3, ntscK = 4
  var label: String { switch self { case .ntscJ: return "NTSC-J"; case .ntscU: return "NTSC-U"; case .pal: return "PAL"; case .ntscK: return "NTSC-K"; case .unknown: return "Error" } }
  static func from(raw: Int) -> Region { Region(rawValue: raw) ?? .unknown }
  /// What a picker offers: every region except the Error placeholder.
  static let selectable = allCases.filter { $0 != .unknown }
}

/// Library backdrop. Raw values are what `@AppStorage("library_background_style")` stores (TVLibraryView keeps its own identical enum).
enum LibraryBackgroundStyle: String, CaseIterable { case clean, gradient, animated
  var label: String { switch self { case .clean: return L("Clean"); case .gradient: return L("GameCube Gradient"); case .animated: return L("Animated (Full Effects)") } }
  /// AppStorage fell back to `.gradient` for an unset or unknown raw value; so does this.
  static func from(stored: String?) -> LibraryBackgroundStyle { stored.flatMap(LibraryBackgroundStyle.init(rawValue:)) ?? .gradient }
}

/// Which gesture moves the gyro pointer sideways.
enum HorizontalMotionMode: Int, CaseIterable { case roll = 0, yaw = 1
  var label: String { switch self { case .roll: return L("Roll (Tilt Left/Right)"); case .yaw: return L("Yaw (Turn Left/Right)") } }
  var description: String { switch self { case .roll: return L("Tilt device left/right to move cursor"); case .yaw: return L("Rotate device left/right to move cursor") } }
}
```

- [ ] **Step 4: Repoint the old views (mechanical).** Delete `private enum Region` from `SW/ConfigGeneralView.swift` (its `FallbackRegionPicker` keeps listing `Region.allCases`; Task 4 removes that). Delete the nested `LibraryBackgroundStyle` from `SW/ConfigInterfaceView.swift` and change `style.displayName` to `style.label`. Delete the nested `HorizontalMotionMode` from `SW/EnhancedMotionControlsView.swift` and change `EnhancedMotionControlsView.HorizontalMotionMode` to `HorizontalMotionMode` in `HorizontalMotionPicker`. Do not touch `TVLibraryView`.
- [ ] **Step 5: Strings.** The three `LibraryBackgroundStyle` labels were raw literals; add identity entries for "Clean", "GameCube Gradient", "Animated (Full Effects)" to both `Core.strings` files.

**Close-out** (every step required)
- [ ] `cd Source/iOS/App && tuist generate --no-open`
- [ ] `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/SettingsRowFactoryTests -only-testing:iCubeTests/SettingsEnumsTests"`: green
- [ ] tvOS compile: `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos`
- [ ] `python3 Project/Scripts/check_localized_keys.py --check` exits 0
- [ ] `git checkout -- build/xcframework`; stage only this task's files and your own `Core.strings` lines (`git add -p`)
- [ ] Commit `refactor(settings): shared row kinds and enums for the remaining leaves` (no trailer)
- [ ] **Stop: the controller merges this commit into develop after review, before Task 2 starts.**

---

## Batch A: General, Interface, Advanced

### Task 2: Config Advanced (the full worked example)

**Branch:** `feat/settings-leaves-a` (Task 1 is already merged into develop).

Every later task follows this file set exactly; this task shows it in full.

**Read first:** `Leaves/GraphicsGeneral{State,ModelBuilder,View}.swift`, `Leaves/SettingsRowFactory.swift`, `SW/SettingsLeafHost.swift` (`SettingsLeafScreen`), `SW/SettingsRootModelBuilder.swift`, `Tests/GraphicsGeneralModelBuilderTests.swift`, `Tests/SettingsRootModelBuilderTests.swift`, `Tests/SettingsSearchIndexTests.swift`, and the old `SW/ConfigAdvancedView.swift` in full.

**Files:**
- Create: `Leaves/ConfigAdvancedState.swift`, `Leaves/ConfigAdvancedModelBuilder.swift`, `Leaves/ConfigAdvancedView.swift`, `Tests/ConfigAdvancedModelBuilderTests.swift`
- Delete: `SW/ConfigAdvancedView.swift` (its trailing dangling `///` comment goes with it)
- Modify: `SW/SettingsRootModelBuilder.swift` (`advanced` entry), `Tests/SettingsRootModelBuilderTests.swift`, `Tests/SettingsSearchIndexTests.swift`, both `Core.strings`

**Rulings applied:** Q1 (SettingsLeafScreen, `hostsMenuScreen: true` + `makeModel:`, test edits), Q2 (tvOS gets NO RTC date row; the MEM1/MEM2 steppers render on tvOS through the engine's `.stepper`, replacing `TVIntStepper`), Q7, Q9 (old header "Memory Override" and its footer, old captions verbatim, RTC default 946684800), Q10.

**Behaviour to preserve** (from the old file): section "Memory Override" with footer `L("For CPU and interpreter performance options, see Performance Tuning in Settings or Config.")`; toggle `Enable Emulated Memory Size Override` (`setMainRamOverrideEnable`) with the long ⚠️ caption copied verbatim; MEM1 24...64 (`setMainMem1SizeMB`) and MEM2 64...128 (`setMainMem2SizeMB`), both disabled until the override is on, no old caption (written descriptions below); section "Custom RTC Options": toggle `Enable Custom RTC` (`setMainCustomRtcEnable`, caption verbatim), then (iOS only) a date+time picker disabled until RTC is on (`setMainCustomRtcValue(Int(date.timeIntervalSince1970))`). The state's default RTC date is 946684800 (2000-01-01 UTC), not 0.

- [ ] **Step 1: Tests first** (`Tests/ConfigAdvancedModelBuilderTests.swift`), then `tuist generate --no-open` and confirm they fail to compile for the right reason:

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class ConfigAdvancedModelBuilderTests: XCTestCase {
  private var changes: [ConfigAdvancedChange] = []
  private func model(_ state: ConfigAdvancedState = ConfigAdvancedState()) -> MenuModel {
    ConfigAdvancedModelBuilder.make(state: state) { self.changes.append($0) }
  }
  private func state(_ edit: (inout ConfigAdvancedState) -> Void) -> ConfigAdvancedState {
    var s = ConfigAdvancedState()
    edit(&s)
    return s
  }

  func test_rowOrder_andSections() {
    var ids = ["mem-override", "mem1", "mem2", "rtc-enabled"]
    #if !os(tvOS)
    ids.append("rtc-date")
    #endif
    XCTAssertEqual(model().allItems.map(\.id), ids)
    XCTAssertEqual(model().sections.map(\.header), ["Memory Override", "Custom RTC Options"])
    XCTAssertEqual(model().sections[0].footer, "For CPU and interpreter performance options, see Performance Tuning in Settings or Config.")
  }

  func test_everyRow_hasADescription() {
    for item in model().allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
  }

  func test_everyToggleRow_emitsItsOwnChange() {
    let expected: [(String, (Bool) -> ConfigAdvancedChange)] = [
      ("mem-override", { .memOverride($0) }), ("rtc-enabled", { .rtcEnabled($0) }),
    ]
    let m = model()
    for (id, change) in expected {
      guard case .toggle(let binding)? = m.item(id: id)?.role else { XCTFail("\(id) is not a toggle"); continue }
      for value in [true, false] {
        changes = []
        binding.wrappedValue = value
        XCTAssertEqual(changes, [change(value)], id)
      }
    }
  }

  func test_memorySteppers_haveTheirRanges_andEmitTheirOwnChange() {
    let m = model(state { $0.memOverride = true })
    let expected: [(String, ClosedRange<Double>, Double, ConfigAdvancedChange)] = [
      ("mem1", 24 ... 64, 30, .mem1MB(30)),
      ("mem2", 64 ... 128, 100, .mem2MB(100)),
    ]
    for (id, range, value, change) in expected {
      guard case .stepper(let stepper)? = m.item(id: id)?.role else { XCTFail("\(id) is not a stepper"); continue }
      XCTAssertEqual(stepper.range, range, id)
      changes = []
      stepper.value.wrappedValue = value
      XCTAssertEqual(changes, [change], id)
    }
  }

  func test_memorySteppers_showTheirMegabytes() {
    let m = model(state { $0.mem1MB = 48; $0.mem2MB = 96 })
    XCTAssertEqual(m.item(id: "mem1")?.currentValueTitle, "48 MB")
    XCTAssertEqual(m.item(id: "mem2")?.currentValueTitle, "96 MB")
  }

  func test_memorySteppers_disabledUntilTheOverrideIsOn() {
    XCTAssertEqual(model().item(id: "mem1")?.isEnabled, false)
    XCTAssertEqual(model().item(id: "mem2")?.isEnabled, false)
    XCTAssertEqual(model(state { $0.memOverride = true }).item(id: "mem2")?.isEnabled, true)
  }

  func test_rtcDefaultDate_is2000_01_01() {
    XCTAssertEqual(ConfigAdvancedState().rtcDate.timeIntervalSince1970, 946_684_800)
  }

  func test_rtcDateBinding_emitsTheDate() {
    let binding = ConfigAdvancedModelBuilder.rtcDateBinding(ConfigAdvancedState()) { self.changes.append($0) }
    let date = Date(timeIntervalSince1970: 1_000_000_000)
    binding.wrappedValue = date
    XCTAssertEqual(changes, [.rtcDate(date)])
  }

  #if !os(tvOS)
  func test_rtcDate_isACustomRow_disabledUntilRtcIsOn() {
    guard case .custom? = model().item(id: "rtc-date")?.role else { return XCTFail("custom") }
    XCTAssertEqual(model().item(id: "rtc-date")?.isEnabled, false)
    XCTAssertEqual(model(state { $0.rtcEnabled = true }).item(id: "rtc-date")?.isEnabled, true)
  }
  #endif
}
```

- [ ] **Step 2: State + Change** (`Leaves/ConfigAdvancedState.swift`):

```swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

enum ConfigAdvancedLimits {
  static let mem1MB: ClosedRange<Double> = 24 ... 64
  static let mem2MB: ClosedRange<Double> = 64 ... 128
  /// 2000-01-01 UTC: what the old view showed for an RTC that was never set.
  static let defaultRtcSeconds: TimeInterval = 946_684_800
}

/// Snapshot of Config for the Advanced screen. Defaults match the old view's `@State` defaults.
struct ConfigAdvancedState: Equatable {
  var memOverride = false
  var mem1MB = 24
  var mem2MB = 64
  var rtcEnabled = false
  var rtcDate = Date(timeIntervalSince1970: ConfigAdvancedLimits.defaultRtcSeconds)
}

/// One user edit. The host applies it to its snapshot AND to Config; the builder only emits it.
enum ConfigAdvancedChange: Equatable {
  case memOverride(Bool)
  case mem1MB(Int)
  case mem2MB(Int)
  case rtcEnabled(Bool)
  case rtcDate(Date)
}
```

- [ ] **Step 3: Builder** (`Leaves/ConfigAdvancedModelBuilder.swift`):

```swift
import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed.
enum ConfigAdvancedModelBuilder {
  static func make(state: ConfigAdvancedState, apply: @escaping (ConfigAdvancedChange) -> Void) -> MenuModel {
    let memory = MenuSection(
      id: "memory-override", header: L("Memory Override"),
      footer: L("For CPU and interpreter performance options, see Performance Tuning in Settings or Config."),
      items: [
        SettingsRow.toggle("mem-override", L("Enable Emulated Memory Size Override"), state.memOverride,
                           L("Changes the emulated console's RAM. MEM1 is main memory (24–64 MB); MEM2 is Wii extended memory (64–128 MB). ⚠️ Enabling this breaks many games and invalidates save states made at a different size."),
                           set: { apply(.memOverride($0)) }),
        SettingsRow.stepper("mem1", L("MEM1"), Double(state.mem1MB), range: ConfigAdvancedLimits.mem1MB, step: 1, format: megabytes,
                            L("Main memory. The real console has 24 MB."),
                            enabled: state.memOverride, set: { apply(.mem1MB(Int($0))) }),
        SettingsRow.stepper("mem2", L("MEM2"), Double(state.mem2MB), range: ConfigAdvancedLimits.mem2MB, step: 1, format: megabytes,
                            L("Wii extended memory. The real console has 64 MB."),
                            enabled: state.memOverride, set: { apply(.mem2MB(Int($0))) }),
      ])

    let rtcToggle = SettingsRow.toggle("rtc-enabled", L("Enable Custom RTC"), state.rtcEnabled,
                                       L("Sets a custom real-time clock for the emulated console, separate from your device clock. Useful for time-based game events. If unsure, leave off."),
                                       set: { apply(.rtcEnabled($0)) })
    return MenuModel(sections: [memory, MenuSection(id: "custom-rtc", header: L("Custom RTC Options"), items: [rtcToggle] + rtcDateRow(state, apply))])
  }

  /// The old tvOS view had no date row (tvOS has no DatePicker); keep it that way.
  private static func rtcDateRow(_ state: ConfigAdvancedState, _ apply: @escaping (ConfigAdvancedChange) -> Void) -> [MenuItem] {
    #if os(tvOS)
    return []
    #else
    let caption = L("The emulated console's clock when the game starts.")
    return [SettingsRow.custom(
      "rtc-date", L("Date and Time"),
      AnyView(SettingsDateRow(title: L("Date and Time"), caption: caption, date: rtcDateBinding(state, apply), isEnabled: state.rtcEnabled)),
      caption, enabled: state.rtcEnabled)]
    #endif
  }

  /// Split out so a test can drive the date without a view.
  static func rtcDateBinding(_ state: ConfigAdvancedState, _ apply: @escaping (ConfigAdvancedChange) -> Void) -> Binding<Date> {
    Binding(get: { state.rtcDate }, set: { apply(.rtcDate($0)) })
  }

  private static func megabytes(_ value: Double) -> String { String(format: L("%1$ld MB"), Int(value)) }
}

#if !os(tvOS)
/// The one control the engine has no role for. A `.custom` row renders only its view, so the row owns its title and caption.
struct SettingsDateRow: View {
  let title: String
  let caption: String
  let date: Binding<Date>
  let isEnabled: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      DatePicker(title, selection: date, displayedComponents: [.date, .hourAndMinute])
      Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .disabled(!isEnabled)
  }
}
#endif
```

- [ ] **Step 4: Host** (`Leaves/ConfigAdvancedView.swift`), and in the same step `git rm SW/ConfigAdvancedView.swift`:

```swift
import SwiftUI

/// Advanced, on the menu engine. `sync()` reads Config into the snapshot and writes nothing; `apply(_:)` is the only writer.
struct ConfigAdvancedView: View {
  @State private var state = ConfigAdvancedState()

  var body: some View {
    SettingsLeafScreen(model: ConfigAdvancedModelBuilder.make(state: state, apply: apply), title: L("Advanced"), sync: sync)
  }

  private func sync() {
    var s = ConfigAdvancedState()
    s.memOverride = DOLConfigBridge.mainRamOverrideEnable()
    s.mem1MB = DOLConfigBridge.mainMem1SizeMB()
    s.mem2MB = DOLConfigBridge.mainMem2SizeMB()
    s.rtcEnabled = DOLConfigBridge.mainCustomRtcEnable()
    s.rtcDate = Date(timeIntervalSince1970: TimeInterval(DOLConfigBridge.mainCustomRtcValue()))
    state = s
  }

  private func apply(_ change: ConfigAdvancedChange) {
    switch change {
    case .memOverride(let v): state.memOverride = v; DOLConfigBridge.setMainRamOverrideEnable(v)
    case .mem1MB(let v): state.mem1MB = v; DOLConfigBridge.setMainMem1SizeMB(v)
    case .mem2MB(let v): state.mem2MB = v; DOLConfigBridge.setMainMem2SizeMB(v)
    case .rtcEnabled(let v): state.rtcEnabled = v; DOLConfigBridge.setMainCustomRtcEnable(v)
    case .rtcDate(let v): state.rtcDate = v; DOLConfigBridge.setMainCustomRtcValue(Int(v.timeIntervalSince1970))
    }
  }
}
```

- [ ] **Step 5: Register** in `SW/SettingsRootModelBuilder.swift`: change the `advanced` entry to
  `SettingsLeafEntry(id: "advanced", title: L("Advanced"), icon: "cpu", description: L("Clock overrides and other expert options."), hostsMenuScreen: true, makeModel: { ConfigAdvancedModelBuilder.make(state: ConfigAdvancedState(), apply: { _ in }) }) { ConfigAdvancedView() }`.
- [ ] **Step 6: Existing tests this task changes (Q1).** In `Tests/SettingsRootModelBuilderTests.swift`: `test_hostsMenuScreen_isExactlyTheMigratedLeavesAndControllers` expects `["graphics-video", "graphics-enhancements", "graphics-hacks", "performance-tuning", "controllers", "advanced"]`; `test_migratedLeaves_exposeTheirModels` adds `"advanced"` to its id list. In `Tests/SettingsSearchIndexTests.swift` add:

```swift
func test_advancedRows_areFoundByTheirOwnTitles() {
  XCTAssertTrue(index.hits(query: "memory size").contains { $0.entryID == "advanced" && ($0.rowTitle ?? "").contains("Memory Size") })
}
```
  `test_keyword_matchesAHandBuiltLeaf` keeps working (`debug` is still hand-built).
- [ ] **Step 7: New `L()` keys** needing identity entries in both `Core.strings`: "MEM1", "MEM2", "%1$ld MB", "Date and Time", "Main memory. The real console has 24 MB.", "Wii extended memory. The real console has 64 MB.", "The emulated console's clock when the game starts." (reuse existing keys where `check_localized_keys.py` says they exist).

**Close-out** (every step required)
- [ ] `cd Source/iOS/App && tuist generate --no-open`
- [ ] `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/ConfigAdvancedModelBuilderTests -only-testing:iCubeTests/SettingsRootModelBuilderTests -only-testing:iCubeTests/SettingsSearchIndexTests"`: green
- [ ] tvOS compile: `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos`
- [ ] `python3 Project/Scripts/check_localized_keys.py --check` exits 0
- [ ] `git checkout -- build/xcframework`; stage only this task's files and your own `Core.strings` lines (`git add -p`)
- [ ] Commit `feat(settings): Advanced on the menu engine` (no trailer)

---

### Task 3: Config Interface

**Read first:** `Leaves/GraphicsGeneral{State,ModelBuilder,View}.swift`, `Leaves/SettingsRowFactory.swift`, `Tests/GraphicsGeneralModelBuilderTests.swift`, `Tests/SettingsRootModelBuilderTests.swift`, `Tests/SettingsSearchIndexTests.swift`, `Leaves/ConfigAdvanced{State,ModelBuilder,View}.swift` (Task 2, the worked example), and the old `SW/ConfigInterfaceView.swift` in full.

**Files:**
- Create: `Leaves/ConfigInterface{State,ModelBuilder,View}.swift`, `Tests/ConfigInterfaceModelBuilderTests.swift`
- Delete: `SW/ConfigInterfaceView.swift`
- Modify: `SW/SettingsRootModelBuilder.swift` (`interface` entry), `Tests/SettingsRootModelBuilderTests.swift`, `Tests/SettingsSearchIndexTests.swift`, both `Core.strings`

**Rulings applied:** Q1, Q2 (leaves keep the old platform guards: the old `pickerStyleForPlatform` was only a picker-style helper, not a row set, so there is no tvOS-only row and no `isTV` state; the cycle row replaces the menu `Picker` on both platforms), Q7, Q9, Q10. `LibraryBackgroundStyle` is the shared enum from Task 1; `TVLibraryView`'s own copy is left alone.

**Rows** (sections keep the old headers; descriptions are the old captions verbatim):

| section | id | kind | write | notes |
|---|---|---|---|---|
| `game-list` "Game List" | `names-db` | toggle | `setMainUseBuiltInTitleDatabase` | title `Use Built-In Database of Game Names` |
| | `covers` | toggle | `setMainUseGameCovers` | title `Download Game Covers from GameTDB.com for Use in Grid Mode` |
| `library-ui` "Library UI" | `background-style` | cycle over `LibraryBackgroundStyle.allCases` | UserDefaults `library_background_style` (rawValue) | icon `paintbrush.fill`, title now `L("Background Style")` |
| | `show-subtitles` | toggle | UserDefaults `library_show_subtitles` | icon `textformat.123`, title now `L("Show Game ID Subtitles")`; unset key means ON |
| `general` "General" | `confirm-on-stop` | toggle | `setMainConfirmOnStop` | default ON |
| | `panic-handlers` | toggle | `setMainUsePanicHandlers` | default ON |
| | `osd-messages` | toggle | `setMainOSDMessages` | default ON |

- [ ] **Step 1: Tests first** (`Tests/ConfigInterfaceModelBuilderTests.swift`): same shape as `ConfigAdvancedModelBuilderTests` (Task 2): `test_rowOrder_andSections`; `test_everyRow_hasADescription`; `test_everyToggleRow_emitsItsOwnChange` over the 6 toggles (`names-db`, `covers`, `show-subtitles`, `confirm-on-stop`, `panic-handlers`, `osd-messages`) with both values; `test_backgroundStyleCycle_offersEveryStyle_andEmits` (options labels equal `LibraryBackgroundStyle.allCases.map(\.label)`; selecting `.animated` emits `.backgroundStyle(.animated)`; `currentValueTitle` follows `state.backgroundStyle`); pure-function tests:

```swift
func test_unsetSubtitlesKey_meansOn_storedWins() {
  XCTAssertTrue(ConfigInterfaceState.storedShowSubtitles(nil))
  XCTAssertTrue(ConfigInterfaceState.storedShowSubtitles(true))
  XCTAssertFalse(ConfigInterfaceState.storedShowSubtitles(false))
}
func test_defaults_matchTheOldView() {
  let s = ConfigInterfaceState()
  XCTAssertTrue(s.confirmOnStop); XCTAssertTrue(s.usePanicHandlers); XCTAssertTrue(s.osdMessages); XCTAssertTrue(s.showSubtitles)
  XCTAssertFalse(s.useNamesDB); XCTAssertFalse(s.useCovers)
  XCTAssertEqual(s.backgroundStyle, .gradient)
}
```
- [ ] **Step 2: State + Change.**

```swift
enum ConfigInterfaceDefaultsKey {
  static let backgroundStyle = "library_background_style"
  static let showSubtitles = "library_show_subtitles"
}

struct ConfigInterfaceState: Equatable {
  var useNamesDB = false
  var useCovers = false
  var backgroundStyle = LibraryBackgroundStyle.gradient
  var showSubtitles = true
  var confirmOnStop = true
  var usePanicHandlers = true
  var osdMessages = true

  /// `@AppStorage` supplied `true` for an unset key; `bool(forKey:)` would read false.
  static func storedShowSubtitles(_ stored: Bool?) -> Bool { stored ?? true }
}

enum ConfigInterfaceChange: Equatable {
  case useNamesDB(Bool), useCovers(Bool), backgroundStyle(LibraryBackgroundStyle), showSubtitles(Bool)
  case confirmOnStop(Bool), usePanicHandlers(Bool), osdMessages(Bool)
}
```
- [ ] **Step 3: Builder** with `SettingsRow.toggle`/`cycle` per the table (`icon:` where listed), cycle options `LibraryBackgroundStyle.allCases.map { ($0.label, $0) }`.
- [ ] **Step 4: Host**; `sync()` reads `DOLConfigBridge.mainUse…()` getters (as the old `sync()`), `LibraryBackgroundStyle.from(stored: defaults.string(forKey: ConfigInterfaceDefaultsKey.backgroundStyle))`, `ConfigInterfaceState.storedShowSubtitles(defaults.object(forKey: …) as? Bool)`; `apply` writes the bridge setters and `defaults.set(style.rawValue, forKey:)` / `defaults.set(v, forKey:)`. Title `L("Interface")`. `git rm SW/ConfigInterfaceView.swift` in this step.
- [ ] **Step 5: Register** the `interface` entry with `hostsMenuScreen: true` and `makeModel: { ConfigInterfaceModelBuilder.make(state: ConfigInterfaceState(), apply: { _ in }) }`.
- [ ] **Step 6: Existing tests (Q1).** `test_hostsMenuScreen_isExactlyTheMigratedLeavesAndControllers` set gains `"interface"`; `test_migratedLeaves_exposeTheirModels` list gains `"interface"`; add to `SettingsSearchIndexTests`:

```swift
func test_interfaceRows_areFoundByTheirOwnTitles() {
  XCTAssertTrue(index.hits(query: "panic handlers").contains { $0.entryID == "interface" })
}
```
- [ ] **Step 7: Strings.** New `L()` keys: "Background Style", "Show Game ID Subtitles" (the three style labels came in with Task 1).

**Close-out** (every step required)
- [ ] `cd Source/iOS/App && tuist generate --no-open`
- [ ] `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/ConfigInterfaceModelBuilderTests -only-testing:iCubeTests/SettingsRootModelBuilderTests -only-testing:iCubeTests/SettingsSearchIndexTests"`: green
- [ ] tvOS compile: `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos`
- [ ] `python3 Project/Scripts/check_localized_keys.py --check` exits 0
- [ ] `git checkout -- build/xcframework`; stage only this task's files and your own `Core.strings` lines (`git add -p`)
- [ ] Commit `feat(settings): Interface on the menu engine` (no trailer)

---

### Task 4: Config General

**Read first:** `Leaves/GraphicsGeneral{State,ModelBuilder,View}.swift` (normaliser pattern: `normalizedFrameCap`, `storedTripleBuffering`), `Leaves/SettingsRowFactory.swift`, `Leaves/ConfigAdvanced*.swift` (Task 2), `Tests/GraphicsGeneralModelBuilderTests.swift`, `Tests/SettingsRootModelBuilderTests.swift`, `Tests/SettingsSearchIndexTests.swift`, the old `SW/ConfigGeneralView.swift` in full (including `SpeedLimitPicker`, `FastForwardSpeedPicker`, `FallbackRegionPicker` and their `HelpButton` texts), `PauseMenuView.swift` lines ~70-90 and `PauseMenuModelBuilder.fastForwardOptions` (read-only; this task does not edit them), `SaveStateService.resumeDefaultsKey`.

**Files:**
- Create: `Leaves/ConfigGeneral{State,ModelBuilder,View}.swift`, `Tests/ConfigGeneralModelBuilderTests.swift`
- Delete: `SW/ConfigGeneralView.swift` (with `SpeedLimitPicker`, `FastForwardSpeedPicker`, `FallbackRegionPicker`)
- Modify: `SW/SettingsRootModelBuilder.swift` (`general` entry), `Tests/SettingsRootModelBuilderTests.swift`, `Tests/SettingsSearchIndexTests.swift`, both `Core.strings`

**Rulings applied:** Q1; Q3 (Fallback Region seed is an explicit host step, pure decision function tested, documented as the one exception to "sync writes nothing"; sync itself stays write-free and shows NTSC-U for an unknown stored region); Q4 (real shared `Region`, Error excluded from the options; fast-forward reads default 300 when unset); Q7; Q9 (picker help text folds into the row descriptions); Q10.

**Rows** (sections keep the old headers `Basic Settings`, `Speed`; the old one-row `Fallback Region` section drops its header and the row carries the title):

| id | kind | options / write | notes |
|---|---|---|---|
| `dual-core` | toggle | `setMainCpuThread` | caption verbatim |
| `dsp-thread` | toggle | `setMainDSPThread` | |
| `cheats` | toggle | `setMainEnableCheats` | |
| `override-region` | toggle | `setMainOverrideRegionSettings` | |
| `auto-disc-change` | toggle | `setMainAutoDiscChange` | |
| `fast-disc-speed` | toggle | `setMainFastDiscSpeed` | |
| `resume-where-left-off` | toggle | UserDefaults `SaveStateService.resumeDefaultsKey` | default OFF |
| `speed-limit` | cycle (icon `speedometer`) | `[0] + 10, 20 … 200`; `setMainEmulationSpeedPercent` | labels: `Unlimited` (0), `100% (Normal Speed)`, else `"\(p)%"`; description = old caption + the picker help: `L("If unsure, select 100%.")` |
| `fast-forward-speed` (icon `forward.fill`) | cycle | `[0, 200, 300, 400, 500, 600, 800, 1000]`; UserDefaults `fast_forward_speed_percent` | labels: `Unlimited`, `"\(p)% (\(p/100)x)"` as the old picker; description = old caption + `L("300% (3x) is recommended for most games.")` |
| `fallback-region` | cycle | `Region.selectable` (no Error); `setMainFallbackRegion(region.rawValue)` | description = old caption + `L("This setting cannot be changed while emulation is active.")` |

An off-ladder stored speed (e.g. 125%, or a fast-forward written by the pause overlay) must display, not show a dash: the option list is built with the stored value inserted in ascending position (`0` stays first) and labelled `"\(p)%"` (the old row showed the raw percent).

- [ ] **Step 1: Tests first** (`Tests/ConfigGeneralModelBuilderTests.swift`): row order and sections (`["Basic Settings", "Speed", nil]`); every row described; table-driven emission:

```swift
func test_everyToggleRow_emitsItsOwnChange() {
  let expected: [(String, (Bool) -> ConfigGeneralChange)] = [
    ("dual-core", { .dualCore($0) }), ("dsp-thread", { .dspThread($0) }), ("cheats", { .cheats($0) }),
    ("override-region", { .overrideRegion($0) }), ("auto-disc-change", { .autoDiscChange($0) }),
    ("fast-disc-speed", { .fastDiscSpeed($0) }), ("resume-where-left-off", { .resumeWhereLeftOff($0) }),
  ]
  // loop as in GraphicsGeneralModelBuilderTests.test_everyToggleRow_emitsItsOwnChange
}

func test_everyCycleRow_emitsItsOwnChange() {
  let expected: [(String, AnyHashable, ConfigGeneralChange)] = [
    ("speed-limit", AnyHashable(150), .speedLimit(150)),
    ("fast-forward-speed", AnyHashable(400), .fastForwardSpeed(400)),
    ("fallback-region", AnyHashable(Region.pal), .fallbackRegion(.pal)),
  ]
  // loop as in the Graphics test
}
```
plus: `test_fallbackRegionCycle_excludesTheErrorCase` (options labels `["NTSC-J", "NTSC-U", "PAL", "NTSC-K"]`); `test_speedLimitLabels` (0 → "Unlimited", 100 → "100% (Normal Speed)", 150 → "150%"); `test_speedLimitOptions_startWithUnlimited_andCover10to200`; `test_fastForwardLabels` (200 → "200% (2x)", 1000 → "1000% (10x)"); `test_offLadderSpeed_isInsertedInOrder_soTheRowNeverShowsADash` (125 sits between 120 and 130, `currentValueTitle == "125%"`; same for fast-forward 250 between 200 and 300); `test_fastForwardUnset_is300_butStoredZeroIsUnlimited` (`storedFastForward(nil) == 300`, `(0) == 0`, `(400) == 400`); `test_displayedRegion_showsNTSCU_forAnUnknownStoredValue`; `test_fallbackRegionSeed_onlyForAnUnknownRegion` (raw 3, 5, -1, 99 → `.ntscU`; raw 0, 1, 2, 4 → `nil`); `test_defaultsKey_isThePausesOverlaysKey` (`ConfigGeneralDefaultsKey.fastForwardSpeedPercent == "fast_forward_speed_percent"`, pinning the literal `PauseMenuView` and `TVEmulationBridge.mm` also use).
- [ ] **Step 2: State + Change.**

```swift
enum ConfigGeneralDefaultsKey {
  /// PauseMenuView and TVEmulationBridge.mm read this same key (each keeps its own constant; this batch does not edit them). A test pins the literal.
  static let fastForwardSpeedPercent = "fast_forward_speed_percent"
  static let resumeWhereLeftOff = SaveStateService.resumeDefaultsKey
}

struct ConfigGeneralState: Equatable {
  var dualCore = false, dspThread = false, cheats = false, overrideRegion = false, autoDiscChange = false, fastDiscSpeed = false
  var resumeWhereLeftOff = false
  var speedLimitPercent = 0
  var fastForwardSpeedPercent = ConfigGeneralState.defaultFastForwardPercent
  var fallbackRegion = Region.ntscU

  static let normalSpeedPercent = 100
  static let defaultFastForwardPercent = 300
  static let speedLimitLadder = [0] + Array(stride(from: 10, through: 200, by: 10))
  static let fastForwardLadder = [0, 200, 300, 400, 500, 600, 800, 1000]

  static func speedLimitLabel(_ percent: Int) -> String   // Unlimited / "100% (Normal Speed)" / "N%"
  static func fastForwardLabel(_ percent: Int) -> String  // Unlimited / "N% (Nx)" / off-ladder "N%"
  static func speedLimitOptions(including stored: Int) -> [(String, Int)]
  static func fastForwardOptions(including stored: Int) -> [(String, Int)]
  /// `integer(forKey:)` would turn an unset key into 0 (Unlimited): only a truly unset key is 300.
  static func storedFastForward(_ stored: Int?) -> Int { stored ?? defaultFastForwardPercent }
  /// Display only: an unknown stored region shows as NTSC-U, as the old view did.
  static func displayedRegion(raw: Int) -> Region { let r = Region.from(raw: raw); return r == .unknown ? .ntscU : r }
  /// What the host's seed step writes: NTSC-U when Config holds the Error region, else nothing.
  static func fallbackRegionSeed(configRaw: Int) -> Region? { Region.from(raw: configRaw) == .unknown ? .ntscU : nil }
}

enum ConfigGeneralChange: Equatable {
  case dualCore(Bool), dspThread(Bool), cheats(Bool), overrideRegion(Bool), autoDiscChange(Bool), fastDiscSpeed(Bool)
  case resumeWhereLeftOff(Bool)
  case speedLimit(Int), fastForwardSpeed(Int), fallbackRegion(Region)
}
```
- [ ] **Step 3: Builder** per the table (`SettingsRow.cycle("speed-limit", L("Speed Limit"), ConfigGeneralState.speedLimitOptions(including: state.speedLimitPercent), state.speedLimitPercent, …, icon: "speedometer", set: { apply(.speedLimit($0)) })`).
- [ ] **Step 4: Host.** `sync()`: `DOLConfigBridge.mainCpuThread()` etc. as the old `syncFromConfig`; `s.fastForwardSpeedPercent = ConfigGeneralState.storedFastForward(defaults.object(forKey: ConfigGeneralDefaultsKey.fastForwardSpeedPercent) as? Int)`; `s.fallbackRegion = ConfigGeneralState.displayedRegion(raw: DOLConfigBridge.mainFallbackRegion())`; `s.resumeWhereLeftOff = defaults.bool(forKey: ConfigGeneralDefaultsKey.resumeWhereLeftOff)`. Add the seed step as the only write outside `apply`:

```swift
var body: some View {
  SettingsLeafScreen(model: ConfigGeneralModelBuilder.make(state: state, apply: apply), title: L("General"), sync: sync)
    .onAppear(perform: seedFallbackRegion)
}

/// The one write outside `apply`: Config holding the Error region is replaced with NTSC-U once, as the old `syncFromConfig` did
/// on every sync. `sync()` itself only displays NTSC-U in that case, so the order of the two appear hooks does not matter.
private func seedFallbackRegion() {
  if let region = ConfigGeneralState.fallbackRegionSeed(configRaw: DOLConfigBridge.mainFallbackRegion()) {
    DOLConfigBridge.setMainFallbackRegion(region.rawValue)
  }
}
```
  `apply` writes the bridge setters (`setMainCpuThread`, …, `setMainEmulationSpeedPercent`, `setMainFallbackRegion(region.rawValue)`) and `defaults.set(v, forKey:)` for fast-forward and resume. `git rm SW/ConfigGeneralView.swift` in this step.
- [ ] **Step 5: Register** `general` with `hostsMenuScreen: true` and `makeModel: { ConfigGeneralModelBuilder.make(state: ConfigGeneralState(), apply: { _ in }) }`.
- [ ] **Step 6: Existing tests (Q1).** `hostsMenuScreen` set gains `"general"`; `test_migratedLeaves_exposeTheirModels` gains `"general"`; add `test_generalRows_areFoundByTheirOwnTitles` (`index.hits(query: "dual core")` contains `general`).
- [ ] **Step 7: Strings.** New keys: "Speed Limit", "Fast Forward Speed" if not already present, `"If unsure, select 100%."`, `"300% (3x) is recommended for most games."`, `"This setting cannot be changed while emulation is active."`; the checker lists any missing.

**Close-out** (every step required)
- [ ] `cd Source/iOS/App && tuist generate --no-open`
- [ ] `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/ConfigGeneralModelBuilderTests -only-testing:iCubeTests/SettingsRootModelBuilderTests -only-testing:iCubeTests/SettingsSearchIndexTests"`: green
- [ ] tvOS compile: `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos`
- [ ] `python3 Project/Scripts/check_localized_keys.py --check` exits 0
- [ ] `git checkout -- build/xcframework`; stage only this task's files and your own `Core.strings` lines (`git add -p`)
- [ ] Commit `feat(settings): General on the menu engine` (no trailer)
- [ ] **Batch A end:** whole target `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro"` green; tvOS compile green. **Stop: the controller merges this batch into develop after review.**

---

## Batch B: GameCube, Wii, Audio

### Task 5: Config GameCube

**Branch:** `feat/settings-leaves-b` from develop once Batch A has merged.

**Read first:** `Leaves/GraphicsGeneral{State,ModelBuilder,View}.swift`, `Leaves/ConfigGeneral*.swift` (Task 4: the seed step), `Leaves/ConfigAdvanced*.swift` (Task 2), `Leaves/SettingsRowFactory.swift`, `Tests/GraphicsGeneralModelBuilderTests.swift`, `Tests/SettingsRootModelBuilderTests.swift`, `Tests/SettingsSearchIndexTests.swift`, the old `SW/ConfigGameCubeView.swift` in full.

**Files:**
- Create: `Leaves/ConfigGameCube{State,ModelBuilder,View}.swift`, `Tests/ConfigGameCubeModelBuilderTests.swift`
- Delete: `SW/ConfigGameCubeView.swift` (with `GCLanguagePicker`; `gcLanguageFromLocale()` has no other caller and moves into the State file)
- Modify: `SW/SettingsRootModelBuilder.swift` (`console-gamecube` entry), `Tests/SettingsRootModelBuilderTests.swift`, `Tests/SettingsSearchIndexTests.swift`, both `Core.strings`

**Rulings applied:** Q1; Q3 (the language seed is an explicit host step with a pure decision function; `sync()` shows the locale-derived language when unset but writes nothing); Q7; Q9; Q10.

**Rows:** section `general` "General": `load-main-menu` toggle, title `Load GameCube Main Menu`, caption verbatim; the state holds `loadMainMenu` and `apply(.loadMainMenu(v))` writes `setMainSkipIPL(!v)`, `sync` reads `!mainSkipIPL()`. Section `system-language` (no header; the one row carries the old header text as its title): `language` cycle titled `System Language`, options `0 English, 1 German, 2 French, 3 Spanish, 4 Italian, 5 Dutch`, caption verbatim, write `setMainGCLanguage`.

- [ ] **Step 1: Tests first**: row order; every row described; `load-main-menu` toggle emits `.loadMainMenu(true/false)`; `language` cycle lists the six labels and emits `.language(3)`; pure tests:

```swift
func test_gcLanguage_fromThePreferredLanguageCode() {
  let cases: [(String, Int)] = [("en-US", 0), ("de-DE", 1), ("fr", 2), ("es-MX", 3), ("it", 4), ("nl-NL", 5), ("ja-JP", 0), ("zh-Hans", 0), ("", 0)]
  for (code, expected) in cases { XCTAssertEqual(ConfigGameCubeState.gcLanguage(forPreferredLanguage: code), expected, code) }
}
func test_displayedLanguage_trustsAStoredValue_clampsOldBugValues_andDerivesWhenUnset() {
  XCTAssertEqual(ConfigGameCubeState.displayedLanguage(isSet: true, stored: 3, preferredLanguage: "de"), 3)
  XCTAssertEqual(ConfigGameCubeState.displayedLanguage(isSet: true, stored: 6, preferredLanguage: "de"), 0, "the old 0...6 picker could store 6")
  XCTAssertEqual(ConfigGameCubeState.displayedLanguage(isSet: false, stored: 0, preferredLanguage: "fr"), 2)
}
func test_languageSeed_onlyWhenNeverChosen() {
  XCTAssertEqual(ConfigGameCubeState.languageSeed(isSet: false, preferredLanguage: "nl"), 5)
  XCTAssertNil(ConfigGameCubeState.languageSeed(isSet: true, preferredLanguage: "nl"))
}
```
- [ ] **Step 2: State + Change.**

```swift
struct ConfigGameCubeState: Equatable {
  var loadMainMenu = true   // the inverse of skipIPL, whose old @State default was false
  var language = 0          // English; sync derives the real value

  static let languageRange = 0 ... 5
  /// Maps the preferred language to the nearest GameCube IPL language (English/German/French/Spanish/Italian/Dutch only; anything else is English).
  static func gcLanguage(forPreferredLanguage code: String) -> Int
  static func displayedLanguage(isSet: Bool, stored: Int, preferredLanguage: String) -> Int
  static func languageSeed(isSet: Bool, preferredLanguage: String) -> Int?
}
enum ConfigGameCubeChange: Equatable { case loadMainMenu(Bool), language(Int) }
```
  (`gcLanguage` takes the code as a parameter: the host passes `Locale.preferredLanguages.first ?? Locale.current.identifier`; the function lower-cases and matches the leading `de|fr|es|it|nl`.)
- [ ] **Step 3: Builder**; **Step 4: Host** with

```swift
SettingsLeafScreen(model: …, title: L("GameCube"), sync: sync).onAppear(perform: seedLanguage)

/// The one write outside `apply` (see ConfigGeneralView.seedFallbackRegion): persist the locale-derived language once, so the game sees what the row shows.
private func seedLanguage() {
  if let seed = ConfigGameCubeState.languageSeed(isSet: DOLConfigBridge.mainGCLanguageIsSet(), preferredLanguage: Self.preferredLanguage) {
    DOLConfigBridge.setMainGCLanguage(seed)
  }
}
```
  `git rm SW/ConfigGameCubeView.swift` in this step.
- [ ] **Step 5: Register** `console-gamecube` (`hostsMenuScreen: true`, `makeModel:`). **Step 6: Existing tests (Q1):** `hostsMenuScreen` set gains `"console-gamecube"`; `test_migratedLeaves_exposeTheirModels` gains it; add `test_gameCubeRows_areFoundByTheirOwnTitles` (`"main menu"` finds `console-gamecube`).

**Close-out** (every step required)
- [ ] `cd Source/iOS/App && tuist generate --no-open`
- [ ] `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/ConfigGameCubeModelBuilderTests -only-testing:iCubeTests/SettingsRootModelBuilderTests -only-testing:iCubeTests/SettingsSearchIndexTests"`: green
- [ ] tvOS compile: `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos`
- [ ] `python3 Project/Scripts/check_localized_keys.py --check` exits 0
- [ ] `git checkout -- build/xcframework`; stage only this task's files and your own `Core.strings` lines (`git add -p`)
- [ ] Commit `feat(settings): GameCube on the menu engine` (no trailer)

---

### Task 6: Config Wii

**Branch:** `feat/settings-leaves-b` (continues Task 5).

**Read first:** `Leaves/GraphicsGeneral*.swift`, `Leaves/ConfigGeneral*.swift` and `Leaves/ConfigAdvanced*.swift` (Tasks 4, 2), `Leaves/SettingsRowFactory.swift`, `Tests/GraphicsGeneralModelBuilderTests.swift`, `Tests/SettingsRootModelBuilderTests.swift`, `Tests/SettingsSearchIndexTests.swift`, the old `SW/ConfigWiiView.swift` in full.

**Files:**
- Create: `Leaves/ConfigWii{State,ModelBuilder,View}.swift`, `Tests/ConfigWiiModelBuilderTests.swift`
- Delete: `SW/ConfigWiiView.swift` (with `WiiLanguagePicker`, `WiiAudioModePicker`, `WiiSensorBarPosPicker`, `WiiAspectRatioPicker`)
- Modify: `SW/SettingsRootModelBuilder.swift` (`console-wii` entry), `Tests/SettingsRootModelBuilderTests.swift`, `Tests/SettingsSearchIndexTests.swift`, both `Core.strings`

**Rulings applied:** Q1; Q2 (the old tvOS `TVIntStepper` rows become engine `.stepper` rows on both platforms); Q7; Q9 (the two section footers become `MenuSection.footer`); Q10.

**Rows** (sections and footers as the old view; there are NO SD-card or SD-writes toggles in the old UI, the old `@State sdCard`/`sdWrites` were synced but never shown, so they are not carried):

| section | id | kind | options / write | notes |
|---|---|---|---|---|
| `video` "Video", footer `These write to the emulated Wii's SYSCONF, so they affect Wii titles only and persist like a real Wii would.` | `pal60` | toggle | `setSysconfPAL60` | `Use PAL60 Mode (EuRGB60)` |
| | `aspect-ratio` | cycle `[("4:3", false), ("16:9", true)]` | `setSysconfWidescreen` | title `Aspect Ratio` |
| `general` "General" | `screensaver` | toggle | `setSysconfScreensaver` | |
| | `language` | cycle 0 Japanese, 1 English, 2 German, 3 French, 4 Spanish, 5 Italian, 6 Dutch, 7 Simplified Chinese, 8 Traditional Chinese, 9 Korean | `setSysconfLanguage` | title `System Language` |
| | `sound-mode` | cycle 0 Mono, 1 Stereo, 2 Surround | `setSysconfSoundMode` | title `Audio Settings` |
| `wii-remotes` "Wii Remotes" | `sensor-bar-position` | cycle 0 Bottom, 1 Top | `setSysconfSensorBarPosition` | |
| | `sensor-bar-sensitivity` | stepper 1...5 step 1 | `setSysconfSensorBarSensitivity` | |
| | `speaker-volume` | stepper 0...7 step 1 | `setSysconfSpeakerVolume` | |
| | `rumble` | toggle | `setSysconfWiimoteMotor` | title `Rumble` |
| | `touchpad-ir-follow` | toggle | UserDefaults `touchpad_ir_follow_without_click` | |
| `usb-sd` "USB / SD", footer `Emulated Wii peripherals. None of these affect emulation speed.` | `skylander-portal` | toggle | `setMainEmulateSkylanderPortal` | `sync` reads `mainEmulateSkylanderPortal()` (the old binding read it live) |
| | `usb-keyboard` | toggle | `setMainWiiKeyboard` | |
| | `wiilink` | toggle | `setMainWiiWiiLinkEnable` | |
| | `sd-folder-sync` | toggle | `setMainWiiSDCardEnableFolderSync` | |

Descriptions are the old captions verbatim. Stepper `format`: `{ "\(Int($0))" }`. State defaults copy the old `@State`: language 1, soundMode 1, sensorBarPos 0, sensorBarSens 2, speakerVol 4, wiimoteRumble true, the rest false.

- [ ] **Step 1: Tests first**: row order and section headers/footers; every row described; table-driven toggle emission (all 9 toggles, both values); table-driven cycle emission (`aspect-ratio` → `.widescreen(true)`, `language` → `.language(6)`, `sound-mode` → `.soundMode(2)`, `sensor-bar-position` → `.sensorBarPosition(1)`); table-driven stepper emission with ranges (`sensor-bar-sensitivity` 1...5, `speaker-volume` 0...7); label tests (`language` options map the ten labels; `aspect-ratio` shows "4:3" for false).
- [ ] **Step 2: State + Change**, **Step 3: Builder**, **Step 4: Host** (`sync` mirrors the old `syncWii` minus the dead SD fields; title `L("Wii")`; `git rm SW/ConfigWiiView.swift` here).
- [ ] **Step 5: Register** `console-wii` (`hostsMenuScreen: true`, `makeModel:`). **Step 6: Existing tests (Q1):** `hostsMenuScreen` set gains `"console-wii"`; `test_migratedLeaves_exposeTheirModels` gains it; add `test_wiiRows_areFoundByTheirOwnTitles` (`"sensor bar"` finds `console-wii`).

**Close-out** (every step required)
- [ ] `cd Source/iOS/App && tuist generate --no-open`
- [ ] `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/ConfigWiiModelBuilderTests -only-testing:iCubeTests/SettingsRootModelBuilderTests -only-testing:iCubeTests/SettingsSearchIndexTests"`: green
- [ ] tvOS compile: `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos`
- [ ] `python3 Project/Scripts/check_localized_keys.py --check` exits 0
- [ ] `git checkout -- build/xcframework`; stage only this task's files and your own `Core.strings` lines (`git add -p`)
- [ ] Commit `feat(settings): Wii on the menu engine` (no trailer)

---

### Task 7: Config Audio

**Branch:** `feat/settings-leaves-b` (continues Tasks 5-6).

**Read first:** `Leaves/GraphicsGeneral*.swift`, `Leaves/ConfigAdvanced*.swift` (Task 2), `Leaves/PerformanceTuningModelBuilder.swift` (footers, disabled rows), `Leaves/SettingsRowFactory.swift`, `Tests/GraphicsGeneralModelBuilderTests.swift`, `Tests/SettingsRootModelBuilderTests.swift`, `Tests/SettingsSearchIndexTests.swift`, `Tests/QuickMuteTests.swift`, the old `SW/ConfigAudioView.swift` in full and `SW/AudioEffectEditors.swift` (`FXChainEditor`, `CoreAudioDSPEditor`; the whole file is `#if os(iOS)`).

**Files:**
- Create: `Leaves/ConfigAudio{State,ModelBuilder,View}.swift`, `Tests/ConfigAudioModelBuilderTests.swift`
- Delete: `SW/ConfigAudioView.swift` (with `BackendPickerView`)
- Keep: `SW/AudioEffectEditors.swift` unchanged
- Modify: `SW/SettingsRootModelBuilder.swift` (`audio` entry), `Tests/SettingsRootModelBuilderTests.swift`, `Tests/SettingsSearchIndexTests.swift`, both `Core.strings`

**Rulings applied:** Q1; Q2 (effects rows are iOS only, `#if os(iOS)` inside the builder, exactly as the old guards; tvOS `TVIntStepper` rows become engine steppers); Q4 (the backend list is dynamic and carried in the state snapshot; the AVAudioEngine alert attaches `.alert` to the host's `SettingsLeafScreen`, no new parameter; effects rows stay inline, shown only for the matching backend, with their footers via `MenuSection.footer`); Q7; Q9; Q10.

**Rows:**

| section | id | kind | notes |
|---|---|---|---|
| `backend` (no header; the row carries the old header text as its title) | `backend` | cycle titled `Audio Backend` | options come from `state.backends` (raw names from `DOLConfigBridge.audioBackends()`); label via `ConfigAudioState.label(forBackend:)`: `""` → `Default Device`, `AVAudioEngine` → `AVAudioEngine`, `CoreAudio` → `CoreAudio (Speakers/HDMI)`, else the raw name. The cycle VALUE is the raw name (the old view compared annotated labels with a raw value, so CoreAudio never showed as selected). When `state.backend` is not in the list (e.g. `""`), it is added as the first option so the row never shows a dash. Description: `L("CoreAudio: Best for TV/HDMI speakers. AVAudioEngine: Enables AUv3 FXs.")` (the old footnote) |
| iOS, only while `backend` contains `AVAudioEngine`: `master-effects` header `Master Effects Chain`, footer `Effects apply post‑environment. Requires AVAudioEngine backend.` | `effects-chain` | custom: `AnyView(VStack { FXChainEditor() })` | title `Master Effects Chain`, description = the footer text |
| iOS, only else while `backend` contains `CoreAudio`: `coreaudio-effects` header `CoreAudio Effects`, footer `Built‑in echo, EQ, and bitcrush. Does not support AUv3 plugins.` | `coreaudio-effects` | custom: `AnyView(CoreAudioDSPEditor(embedded: true))` | |
| `volume` (no header) | `volume` | stepper titled `Volume`, 0...100 step 1, format `"\(Int($0))%"` | `setAudioVolume`; `QuickMute` reads the same value so the pause overlay's Mute badge reflects it on its next build |
| `stretching` "Audio Stretching Settings" | `stretch` | toggle `Enable Audio Stretching` | |
| | `stretch-latency` | stepper 5...200, format `String(format: L("%1$ld ms"), Int($0))`, enabled only while `stretch` | no old caption (write one) |
| `misc` "Misc. Controls" | `mute-on-no-speed-limit` | toggle `Mute When Disabling Speed Limit` | `setAudioMuteOnDisabledSpeedLimit` |
| | `obey-mute-switch` | toggle `Use Mute Hardware Switch` | `setAudioMuteSwitchObey` |

The old audio rows had no per-row captions besides the backend footnote and footers; write one sentence for each uncaptioned row.

- [ ] **Step 1: Tests first**: row order for `backend: ""`, `"CoreAudio"`, `"AVAudioEngine"` (effects rows present only on iOS and only for the matching backend, wrapped in `#if os(iOS)`), with their footers asserted through `model.section(containing:)?.footer`; every row described; table-driven toggle emission (`stretch`, `mute-on-no-speed-limit`, `obey-mute-switch`); stepper emission and ranges (`volume`, `stretch-latency`); `stretch-latency` disabled until `stretch`; `test_backendCycle_emitsTheRawName` (select `"CoreAudio"` → `.backend("CoreAudio")`, label is `CoreAudio (Speakers/HDMI)`); pure tests: `label(forBackend:)` table, `backendOptions` includes an unlisted current backend first as `Default Device`, `needsConfirmation(choosing:)` true only for `AVAudioEngine`; stretch-latency format `"30 ms"`.
- [ ] **Step 2: State + Change.**

```swift
struct ConfigAudioState: Equatable {
  var backend = ""                 // raw Config value; "" is the default device
  var backends: [String] = []      // raw names, DOLConfigBridge.audioBackends()
  var volume = 100
  var stretch = false
  var stretchLatencyMs = 30
  var muteOnNoSpeedLimit = false
  var obeyMuteSwitch = true

  static let avAudioEngine = "AVAudioEngine"
  static let coreAudio = "CoreAudio"
  static func label(forBackend raw: String) -> String
  var backendOptions: [(String, String)]   // (label, raw); current backend inserted first when unlisted
  static func needsConfirmation(choosing raw: String) -> Bool { raw == avAudioEngine }
  var showsAVAudioEngineEffects: Bool { backend.contains(Self.avAudioEngine) }
  var showsCoreAudioEffects: Bool { !showsAVAudioEngineEffects && backend.contains(Self.coreAudio) }
}
enum ConfigAudioChange: Equatable {
  case backend(String), volume(Int), stretch(Bool), stretchLatencyMs(Int), muteOnNoSpeedLimit(Bool), obeyMuteSwitch(Bool)
}
```
  (`ConfigAudioState` is `Equatable` by synthesis; `backendOptions` is computed, not stored.)
- [ ] **Step 3: Builder**, **Step 4: Host.** The alert:

```swift
@State private var pendingBackend: String?

var body: some View {
  SettingsLeafScreen(model: ConfigAudioModelBuilder.make(state: state, apply: apply), title: L("Audio"), sync: sync)
    .alert(L("Enable AVAudioEngine?"), isPresented: Binding(get: { pendingBackend != nil }, set: { if !$0 { pendingBackend = nil } })) {
      Button(L("Enable")) { let raw = pendingBackend; pendingBackend = nil; if let raw { commitBackend(raw) } }
      Button(L("Cancel"), role: .cancel) { pendingBackend = nil }
    } message: {
      Text(L("AVAudioEngine is in development and not recommended for general usage yet. Are you sure?"))
    }
}

// in apply:
case .backend(let raw):
  if ConfigAudioState.needsConfirmation(choosing: raw) { pendingBackend = raw } else { commitBackend(raw) }
```
  `commitBackend` sets `state.backend = raw` and `DOLConfigBridge.setAudioBackend(raw)`. `sync` reads `audioBackends()`, `audioBackend()`, `audioVolume()`, `audioStretch()`, `audioStretchLatencyMs()`, `audioMuteOnDisabledSpeedLimit()`, `audioMuteSwitchObey()`. `git rm SW/ConfigAudioView.swift` in this step.
- [ ] **Step 5: Register** `audio` (`hostsMenuScreen: true`, `makeModel:` with `ConfigAudioState()`: no backend, so effects rows are not searchable; they have no useful titles). **Step 6: Existing tests (Q1):** `hostsMenuScreen` set gains `"audio"`; `test_migratedLeaves_exposeTheirModels` gains it; add `test_audioRows_areFoundByTheirOwnTitles` (`"audio stretching"` finds `audio`).

**Close-out** (every step required)
- [ ] `cd Source/iOS/App && tuist generate --no-open`
- [ ] `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/ConfigAudioModelBuilderTests -only-testing:iCubeTests/SettingsRootModelBuilderTests -only-testing:iCubeTests/SettingsSearchIndexTests"`: green
- [ ] tvOS compile: `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos`
- [ ] `python3 Project/Scripts/check_localized_keys.py --check` exits 0
- [ ] `git checkout -- build/xcframework`; stage only this task's files and your own `Core.strings` lines (`git add -p`)
- [ ] Commit `feat(settings): Audio on the menu engine` (no trailer)
- [ ] **Batch B end:** whole target `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro"` green; tvOS compile green. **Stop: the controller merges this batch into develop after review.**

---

## Batch C: Graphics Advanced, Enhanced Motion, Stick Feel, Debug

### Task 8: Graphics Advanced

**Branch:** `feat/settings-leaves-c` from develop **once PR 4 (`feat/controller-hub-reorg`) AND Batch B have merged** (Q6). Do not start from an older base: this task reads develop's `GraphicsAdvancedView` including the texture-pack warning added in `17ad3076b3`.

**Read first:** `Leaves/GraphicsHacks*.swift` and `Leaves/PerformanceTuning{State,ModelBuilder,View}.swift` (the `Flag` + `keyPath` pattern, `test_everyFlag_hasExactlyOneRow`, `test_flagKeyPaths_areDistinct`), `Leaves/GraphicsGeneral*.swift`, `Leaves/SettingsRowFactory.swift`, `Tests/PerformanceTuningModelBuilderTests.swift`, `Tests/SettingsRootModelBuilderTests.swift`, `Tests/SettingsSearchIndexTests.swift`, and develop's `SW/GraphicsAdvancedView.swift` in full (the texture-pack block: `texturePackBytes`, `isTooLargeToPrefetch`, `installedTexturePackBytes`, `texturePackBytesOnDisk`).

**Files:**
- Create: `Leaves/GraphicsAdvanced{State,ModelBuilder,View}.swift`, `Tests/GraphicsAdvancedModelBuilderTests.swift`
- Delete: `SW/GraphicsAdvancedView.swift`
- Modify: `SW/SettingsSharedComponents.swift` (delete `MetalTriStatePicker`, its only user goes; leave `SettingsSelectRow`), `SW/SettingsRootModelBuilder.swift` (`graphics-advanced` entry: add `hostsMenuScreen`/`makeModel`, drop `keywords:`), `Tests/SettingsRootModelBuilderTests.swift`, `Tests/SettingsSearchIndexTests.swift`, both `Core.strings`

**Rulings applied:** Q1; Q2 (the old tvOS `TVIntStepper` thread rows become engine steppers); Q5 (the texture-pack warning is ported onto the migrated leaf); Q7; Q9; Q10. The `keywords:` on the root entry (`present drawable`, `manually upload buffers`, `metal`) are dropped: generated search finds those rows by their own titles (spec P18), and the new search assertion proves it.

**Flags** (one `GraphicsAdvancedFlag` case per Bool row; `keyPath` onto the state, `write(flag, v)` in the host). Old `@State` defaults in the last column; descriptions are the old captions verbatim.

| section (old header) | id | flag | write | default |
|---|---|---|---|---|
| `performance-statistics` "Performance Statistics", footer `These overlays can also be toggled in-game from the pause menu.` | `show-fps` `show-vps` `show-speed` `show-frame-times` `show-vblank-times` `show-graphs` `log-render-time` `speed-colors` | `showFPS` `showVPS` `showSpeed` `showFrameTimes` `showVBlankTimes` `showGraphs` `logRenderTime` `speedColors` | `setGfxShowFPS` `setGfxShowVPS` `setGfxShowSpeed` `setGfxShowFTimes` `setGfxShowVTimes` `setGfxShowGraphs` `setGfxLogRenderTimeToFile` `setGfxShowSpeedColors` | false |
| `debugging` "Debugging" | `overlay-stats` `api-validation-layer` | `overlayStats` `validationLayer` | `setGfxOverlayStats` `setGfxEnableValidationLayer` | false |
| `shader-threads` "Shader Threads" | `compiler-threads` `precompiler-threads` | steppers `1 ... maxThreads` | `setGfxShaderCompilerThreads` `setGfxShaderPrecompilerThreads` | `1`; `maxThreads` 2 |
| `utility` "Utility" | `load-custom-textures` `prefetch-custom-textures` (disabled while `!hiresTextures`) `texture-pack-warning` (see below) `disable-efb-copy-to-vram` `graphics-mods` | `hiresTextures` `prefetchTextures` — `disableEfbToVRAM` `graphicsMods` | `setGfxHiresTextures` `setGfxCacheHiresTextures` — `setGfxHackDisableCopyToVRAM` `setGfxModsEnable` | false |
| `misc` "Misc" | `crop` `progressive-scan` | `cropPicture` `progressiveScan` | `setGfxCrop` `setSysconfProgressiveScan` | false |
| `rendering` "Rendering" | `fast-depth` `per-pixel-lighting` `backend-multithreading` `shader-cache` `save-texture-cache-to-state` `prefer-vs-for-lines` `cpu-culling` | `fastDepth` `pixelLighting` `backendMT` `shaderCache` `saveTexCache` `preferVSForLines` `cpuCull` | `setGfxFastDepthCalc` `setGfxEnablePixelLighting` `setGfxBackendMultithreading` `setGfxShaderCache` `setGfxSaveTextureCacheToState` `setGfxPreferVSForLinePointExpansion` `setGfxCpuCull` | `fastDepth`, `backendMT`, `shaderCache` true; rest false |
| `experimental` "Experimental", footer `⚠️ Experimental — may cause instability or glitches in some games.` | `defer-efb-invalidation` | `deferEfbInvalidation` | `setGfxHackEfbDeferInvalidation` | false |
| | `use-present-drawable`, `manually-upload-buffers` | cycles `[("Off", 0), ("On", 1), ("Auto", 2)]` (the old `MetalTriStatePicker` list) | `setGfxMtlUsePresentDrawable`, `setGfxMtlManuallyUploadBuffers` | `2` (Auto) |

Thread steppers: format `"\(Int($0))"`, range `1 ... Double(state.maxThreads)`. Pure helpers in the State file, tested: `maxThreads(forProcessorCount:) = max(1, max(2, count) - 1)`; `threadCount(stored:maxThreads:) = stored <= 0 ? min(2, maxThreads) : stored`.

**Texture-pack warning (Q5).** State: `texturePackBytes: Int64 = 0` and `physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory`. Pure, injectable:

```swift
/// Prefetch keeps every texture of a pack resident, and the core lets that cache reach half of RAM (CustomAssetCache);
/// next to the emulator itself, a pack above a quarter of RAM risks a memory kill, so warn from there.
static let prefetchWarningRAMDivisor: UInt64 = 4
static func isTooLargeToPrefetch(bytes: Int64, physicalMemory: UInt64) -> Bool {
  bytes > 0 && UInt64(bytes) > physicalMemory / prefetchWarningRAMDivisor
}
var showsTexturePackWarning: Bool { hiresTextures && prefetchTextures && Self.isTooLargeToPrefetch(bytes: texturePackBytes, physicalMemory: physicalMemory) }
```
The builder inserts, right after `prefetch-custom-textures` when `showsTexturePackWarning`, `SettingsRow.custom("texture-pack-warning", text, AnyView(TexturePackWarningRow(text: text)), text, enabled: false)` where `text` is `String(format: L("Installed texture packs total %@, a large share of this device's memory. Prefetching them can crash the game; turn Prefetch off or remove packs you don't use."), ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))` and `TexturePackWarningRow` is a `Label(text, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)`. The disk scan moves verbatim into the State file as `enum TexturePackSize { static func bytesOnDisk() async -> Int64 }` (detached `.utility` task around a synchronous `nonisolated` enumerator over `UserFolderUtil.getUserFolder()/Load/Textures`). The host runs `.task { state.texturePackBytes = await TexturePackSize.bytesOnDisk() }`, and **`sync()` carries the field forward** (`s.texturePackBytes = state.texturePackBytes`) because `sync` builds a fresh state and would otherwise wipe it on every Config change.

- [ ] **Step 1: Tests first**: row order and section headers/footers; every row described; `test_everyFlag_hasExactlyOneRow`; `test_flagKeyPaths_areDistinct`; `test_everyToggleRow_readsAndEmitsItsOwnFlag` (both values) as in `PerformanceTuningModelBuilderTests`; thread steppers emit `.compilerThreads(3)` / `.precompilerThreads(2)` and use `1 ... maxThreads`; tri-state cycles list `Off/On/Auto` and emit `.presentDrawable(0)` / `.manuallyUploadBuffers(1)`; `prefetch-custom-textures` disabled until `hiresTextures`; warning row present only when custom textures AND prefetch are on and the pack is over a quarter of RAM, with boundary cases (`bytes == physicalMemory / 4` → false, `+ 1` → true, `0` → false, 8 GiB device with 3 GiB packs → true); `maxThreads(forProcessorCount:)` (1 → 1, 2 → 1, 6 → 5) and `threadCount(stored:maxThreads:)` (`-1`/`0` → `min(2, max)`, `3` → 3).
- [ ] **Step 2: State + Change** (`case flag(GraphicsAdvancedFlag, Bool)`, `compilerThreads(Int)`, `precompilerThreads(Int)`, `presentDrawable(Int)`, `manuallyUploadBuffers(Int)`), **Step 3: Builder**, **Step 4: Host** (`sync` mirrors the old `sync()`; title `L("Advanced")`; `.task` as above; `git rm SW/GraphicsAdvancedView.swift`; delete `MetalTriStatePicker` from `SettingsSharedComponents.swift`).
- [ ] **Step 5: Register** `graphics-advanced` with `hostsMenuScreen: true` and `makeModel: { GraphicsAdvancedModelBuilder.make(state: GraphicsAdvancedState(), apply: { _ in }) }`, and remove its `keywords:`.
- [ ] **Step 6: Existing tests (Q1).** `hostsMenuScreen` set gains `"graphics-advanced"`; `test_migratedLeaves_exposeTheirModels` gains it; add `test_graphicsAdvancedRows_areFoundByTheirOwnTitles` (`"present drawable"` and `"prefetch"` find `graphics-advanced`).

**Close-out** (every step required)
- [ ] `cd Source/iOS/App && tuist generate --no-open`
- [ ] `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/GraphicsAdvancedModelBuilderTests -only-testing:iCubeTests/SettingsRootModelBuilderTests -only-testing:iCubeTests/SettingsSearchIndexTests"`: green
- [ ] tvOS compile: `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos`
- [ ] `python3 Project/Scripts/check_localized_keys.py --check` exits 0
- [ ] `git checkout -- build/xcframework`; stage only this task's files and your own `Core.strings` lines (`git add -p`)
- [ ] Commit `feat(settings): Graphics Advanced on the menu engine` (no trailer)

---

### Task 9: Enhanced Motion

**Batch C rules:** branch `feat/settings-leaves-c` (from develop after PR 4 and Batch B merged, Q6). No root entry exists for this leaf, so there is no `hostsMenuScreen`/`makeModel`/search work.

**Read first:** `Leaves/GraphicsGeneral*.swift`, `Leaves/SettingsRowFactory.swift`, `Common/Swift/Controllers/MotionSettings.swift` (`Key`, `applyRecommended`), `Tests/MotionSettingsTests.swift`, `Tests/GraphicsGeneralModelBuilderTests.swift`, the old `SW/EnhancedMotionControlsView.swift` in full, and every call site: `grep -rn "EnhancedMotionControlsView()" Source/iOS/App` (after PR 4: `PlayerScreenViewModel.advancedMotionDestination`).

**Files:**
- Create: `Leaves/EnhancedMotion{State,ModelBuilder,View}.swift`, `Tests/EnhancedMotionModelBuilderTests.swift`
- Delete: `SW/EnhancedMotionControlsView.swift` (with `HorizontalMotionPicker`); the new host keeps the type name `EnhancedMotionControlsView`
- Modify: `Common/Swift/Controllers/Player/PlayerScreenViewModel.swift` (call site), both `Core.strings`

**Rulings applied:** Q1 (`SettingsLeafScreen`); Q5 (writes post `.DOLMotionSettingsChanged` on EVERY write and from Recommended; the Nunchuk row is hidden while 6DOF is off); Q6 (the leaf now hosts its own `MenuScreen` through `SettingsLeafScreen`, so PR 4's `.padBackNavigation()` wrapper at the call site is removed; any other direct push of this view gets `.clearingSettingsPaneBack()`); Q7; Q9; Q10.

**Rows** (the leaf title stays `L("Advanced Motion Settings")`; `HorizontalMotionMode` is the shared enum from Task 1):

| section | id | kind | write | notes |
|---|---|---|---|---|
| `gyro-pointer` "Gyro Pointer" | `horizontal-movement` | cycle `HorizontalMotionMode.allCases` | `useYawForHorizontal = (mode == .yaw)` | title `Horizontal Movement`; description = old caption + the selected mode's `description` |
| `full-motion` "Full Motion Mapping" | `wiimote-imu` | toggle `Wiimote Motion Controls` | `MotionSettings.Key.wiimoteIMU` | default ON |
| | `six-dof` | toggle `Enable 6DOF Motion Controls` | `MotionSettings.Key.full6DOF` | default ON |
| | `nunchuk-imu` | toggle `Nunchuck Motion Controls` (old spelling) | `MotionSettings.Key.nunchukIMU` | **only present while `full6DOF`**; description = the old inline caption; default OFF |
| `quick-setup` "Quick Setup" | `recommended` | action `Recommended Motion Settings` | `MotionSettings.applyRecommended()`, then resync, notification and (iOS) `UINotificationFeedbackGenerator().notificationOccurred(.success)` | caption verbatim |

State defaults: `horizontalMotionMode = .roll`, `wiimoteIMU = true`, `full6DOF = true` (so the default state, which search uses, contains the Nunchuk row), `nunchukIMU = false`. `sync` reads the `MotionSettings.useYawForHorizontal()/wiimoteIMU()/full6DOF()/nunchukIMU()` accessors.

- [ ] **Step 1: Tests first**: row order with 6DOF on and off (`nunchuk-imu` absent when off); every row described; toggles emit their own change both ways (`wiimote-imu`, `six-dof`, `nunchuk-imu`); cycle lists both modes and emits `.horizontalMotion(.yaw)`; the cycle description contains the selected mode's `description`; `recommended` is an action emitting `.applyRecommended`.
- [ ] **Step 2: State + Change** (`horizontalMotion(HorizontalMotionMode)`, `wiimoteIMU(Bool)`, `full6DOF(Bool)`, `nunchukIMU(Bool)`, `applyRecommended`), **Step 3: Builder**, **Step 4: Host.** All writes funnel through `apply`, which posts once at the end:

```swift
private func apply(_ change: EnhancedMotionChange) {
  let defaults = UserDefaults.standard
  switch change {
  case .horizontalMotion(let mode): state.horizontalMotionMode = mode; defaults.set(mode == .yaw, forKey: MotionSettings.Key.useYawForHorizontal)
  case .wiimoteIMU(let v): state.wiimoteIMU = v; defaults.set(v, forKey: MotionSettings.Key.wiimoteIMU)
  case .full6DOF(let v): state.full6DOF = v; defaults.set(v, forKey: MotionSettings.Key.full6DOF)
  case .nunchukIMU(let v): state.nunchukIMU = v; defaults.set(v, forKey: MotionSettings.Key.nunchukIMU)
  case .applyRecommended:
    MotionSettings.applyRecommended()
    sync()
    #if os(iOS)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    #endif
  }
  // A running game re-reads motion settings on this notification.
  NotificationCenter.default.post(name: .DOLMotionSettingsChanged, object: nil)
}
```
  `git rm SW/EnhancedMotionControlsView.swift` in this step.
- [ ] **Step 5: Call sites.** In `PlayerScreenViewModel` change `advancedMotionDestination: { AnyView(EnhancedMotionControlsView().padBackNavigation()) }` to `{ AnyView(EnhancedMotionControlsView()) }`. For every other `EnhancedMotionControlsView()` found by the grep: remove a `.padBackNavigation()` wrapper, and if it is pushed with `.navigationDestination`/`NavigationLink` outside the engine's `.destination` role, append `.clearingSettingsPaneBack()`.

**Close-out** (every step required)
- [ ] `cd Source/iOS/App && tuist generate --no-open`
- [ ] `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/EnhancedMotionModelBuilderTests -only-testing:iCubeTests/MotionSettingsTests"`: green
- [ ] tvOS compile: `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos`
- [ ] `python3 Project/Scripts/check_localized_keys.py --check` exits 0
- [ ] `git checkout -- build/xcframework`; stage only this task's files and your own `Core.strings` lines (`git add -p`)
- [ ] Commit `feat(settings): Enhanced Motion on the menu engine` (no trailer)

---

### Task 10: On-Screen Stick Feel

**Batch C rules:** branch `feat/settings-leaves-c` (from develop after PR 4 and Batch B merged, Q6). No root entry, so no `hostsMenuScreen`/`makeModel`/search work.

**Read first:** `Leaves/GraphicsGeneral*.swift`, `Leaves/SettingsRowFactory.swift`, `Tests/GraphicsGeneralModelBuilderTests.swift`, the old `AnalogStickSettingsView` at the top of `SW/ControllersRootView.swift`, and every call site: `grep -rn "AnalogStickSettingsView()" Source/iOS/App` (after PR 4: `PlayerScreenViewModel.stickFeelDestination`, `DSUControllerView` `.navigationDestination(isPresented: $showStickFeel)`, and `ControllerMoreSettingsView` if it still pushes it).

**Files:**
- Create: `Leaves/AnalogStick{State,ModelBuilder,View}.swift`, `Tests/AnalogStickModelBuilderTests.swift`
- Modify: `SW/ControllersRootView.swift` (remove `AnalogStickSettingsView` and its `MARK`; the file keeps `ControllersRootView` and `TouchOverlayLayoutEditorView`), `Common/Swift/Controllers/Player/PlayerScreenViewModel.swift`, `Common/Swift/Widgets/DSUControllerView.swift`, both `Core.strings`

**Rulings applied:** Q1; Q2 (the tvOS `TVFloatStepper` rows become engine steppers); Q6 (remove `.padBackNavigation()` wrappers on this leaf; the `DSUControllerView` push gets `.clearingSettingsPaneBack()`, because inside the Controllers pane Back would otherwise jump to the sidebar and leave this screen on the stack); Q7; Q9; Q10.

**Rows** (one section `stick-feel`, no header; the three old one-row sections' headers become the row titles; captions verbatim; the host keeps the type name `AnalogStickSettingsView` and the title `L("On-Screen Stick Feel")`):

| id | title | range / step | format | key | default |
|---|---|---|---|---|---|
| `gain` | `Analog Stick Gain` | `0.1 ... 3.0` / `0.05` | `%.2f` | `dsu_gyro_gain` | 1.0 |
| `deadzone` | `Analog Stick Deadzone` | `0.0 ... 0.49` / `0.01` | `%.2f` | `dsu_deadzone` | 0.05 |
| `smoothing` | `Analog Stick Smoothing` | `0.0 ... 0.9` / `0.05` | `%.2f` | `dsu_smoothing` | 0.0 |

The old view read with `object(forKey:) as? Double ?? default` and wrote on change; keep that, in a pure helper `AnalogStickState.stored(_ object: Any?, default: Double) -> Double` (a stored `0.0` for smoothing is a real value, never "unset").

- [ ] **Step 1: Tests first**: row order and ids; every row described; table-driven stepper emission with ranges (`gain` 2.0 → `.gain(2.0)`, `deadzone` 0.2 → `.deadzone(0.2)`, `smoothing` 0.5 → `.smoothing(0.5)`); format `"1.00"`; `stored(nil, default: 1.0) == 1.0`, `stored(0.0, default: 1.0) == 0.0`, `stored("junk", default: 0.05) == 0.05`; defaults match the old view.
- [ ] **Step 2: State + Change** (`gain(Double)`, `deadzone(Double)`, `smoothing(Double)`), **Step 3: Builder**, **Step 4: Host** (`apply` sets state and `UserDefaults.standard.set(v, forKey:)`; remove the old struct from `ControllersRootView.swift`).
- [ ] **Step 5: Call sites.** `PlayerScreenViewModel.stickFeelDestination`: `{ AnyView(AnalogStickSettingsView()) }` (drop `.padBackNavigation()`). `DSUControllerView`: `.navigationDestination(isPresented: $showStickFeel) { AnalogStickSettingsView().clearingSettingsPaneBack() }`. Any other direct push found by the grep gets the same treatment as in Task 9 Step 5.

**Close-out** (every step required)
- [ ] `cd Source/iOS/App && tuist generate --no-open`
- [ ] `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/AnalogStickModelBuilderTests"`: green
- [ ] tvOS compile: `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos`
- [ ] `python3 Project/Scripts/check_localized_keys.py --check` exits 0
- [ ] `git checkout -- build/xcframework`; stage only this task's files and your own `Core.strings` lines (`git add -p`)
- [ ] Commit `feat(settings): On-Screen Stick Feel on the menu engine` (no trailer)

---

### Task 11: Debug

**Batch C rules:** branch `feat/settings-leaves-c` (from develop after PR 4 and Batch B merged, Q6). Read PR 4's `DebugRootView` as it now stands on develop: it adds a DEBUG-only `Gallery` link.

**Read first:** `Leaves/PerformanceTuning{State,ModelBuilder,View}.swift` (disabled `action` rows, `footer`), `Leaves/GraphicsGeneral*.swift` (`isIOS` in state, search state), `Leaves/GraphicsAdvanced*.swift` (Task 8: a field filled outside `sync` is carried forward), `Leaves/SettingsRowFactory.swift`, `Tests/PerformanceTuningModelBuilderTests.swift`, `Tests/SettingsRootModelBuilderTests.swift`, `Tests/SettingsSearchIndexTests.swift`, develop's `SW/DebugRootView.swift` in full.

**Files:**
- Create: `Leaves/DebugRoot{State,ModelBuilder,View}.swift`, `Tests/DebugRootModelBuilderTests.swift`
- Delete: `SW/DebugRootView.swift` (its trailing dangling `///` comment goes with it)
- Modify: `SW/SettingsRootModelBuilder.swift` (`debug` entry: add `hostsMenuScreen`/`makeModel`, drop `keywords:`), `Tests/SettingsRootModelBuilderTests.swift`, `Tests/SettingsSearchIndexTests.swift`, both `Core.strings`

**Rulings applied:** Q1; Q5 (Debug keeps EVERY row: JIT Setup Guide, Bench Token, the StikDebug help caption, both Fastmem rows; the builder never reads `JitManager`, `StikDebugLauncher`, the bench token or any singleton, the host snapshots them into State); Q7; Q9; Q10. Judgment: the old "Forget Approved Device(s)" button had no confirmation and `SettingsLeafScreen` takes no modal, so it stays a plain `.destructive` row (the button is its own undo for a mis-tapped "Always Allow").

**State shape.** Fields read cheaply and side-effect free by `sync()`: `fastmem`, `launchTimes`, `stallMetrics`, `benchEnabled`, `benchToken` (`UserDefaults "ICubeBenchServerToken"`, empty on a DEBUG build), `wireframe`, `loggingEnabled`, `loggingVerbosity`, `inputDebug`, `instantReplay`, `disableArtwork` (`library_disable_artwork`), `isIOS`. Fields hydrated ONCE by the host's `.task` in a nested `DebugHydratedState` (`userFolder`, `fastmemAvailable`, `jitAcquired`, `jitError`, `debuggerAttached`, `txmAuthorized`, `txmHandshakeBlocked`, `deviceHasTxm`, `jitSupported`, `stikDebugInstalled`, `approvedClients`): the old `.task` called `JitManager.recheckIfJitIsAcquired()` (a side effect) once, so it must NOT move into `sync`, which re-runs on every Config change, foreground and emulation start/end. `sync()` carries the nested struct forward (`s.hydrated = state.hydrated`) so a resync does not wipe it.

```swift
.task {
  guard !hydrated else { return }
  hydrated = true
  let manager = JitManager.shared()
  manager.recheckIfJitIsAcquired()
  state.hydrated = DebugHydratedState(userFolder: UserFolderUtil.getUserFolder(), fastmemAvailable: FastmemManager.shared().fastmemAvailable,
                                      jitAcquired: manager.acquiredJit, jitError: manager.acquisitionError ?? "", …,
                                      approvedClients: BenchAccessApproval.shared.rememberedAddresses)
}
```

**Rows** (sections and order as the old view; empty sections are dropped, so `Recording` is absent on tvOS):

| section | id | kind | notes |
|---|---|---|---|
| `cpu-memory` "CPU / Memory" | `fastmem` | toggle, enabled only when `fastmemAvailable` | `setMainFastmem` |
| `recording` "Recording" (iOS) | `instant-replay` | toggle | UserDefaults `replaykit_instant_replay_enabled` |
| `environment` "Environment" | `user-folder` | disabled action (status), value in the DESCRIPTION (a path is too long for a badge) | |
| | `jit-status` | status, badge `Acquired`/`Not Acquired` | |
| | `debugger-status` | status, badge `Attached`/`Not Attached` | |
| | `txm-region` | status, badge `Authorized`/`Not Authorized`; only when `deviceHasTxm` | |
| | `jit-error` | status, value in the description (`(none)` when empty) | |
| | `retry-jit-authorization` | action, only when `txmHandshakeBlocked` | `JitManager.shared().clearTXMHandshakeCookie()` then `hydrated.txmHandshakeBlocked = false`; caption verbatim |
| | `enable-jit-stikdebug` (iOS) | action, only when `DebugRootState.showsStikDebugEnable` | `StikDebugLauncher.enableJIT()`; caption verbatim |
| | `stikdebug-help` (iOS) | `SettingsRow.caption`, only when the row above shows and `!debuggerAttached && !txmAuthorized` | text = the old "StikDebug didn't attach?" paragraph |
| | `jit-guide` | destination `WikiPageView(path: WikiConstants.Paths.jitGuide, title: L("JIT Setup Guide"))` | caption verbatim |
| | `fastmem-available` | status, badge `Available`/`Not Available` | a second row titled "Fastmem" in the old view; the id differs from the toggle's |
| `diagnostics` "Diagnostics" | `launch-times` | status, badge `"\(launchTimes)"` | |
| | `reset-launch-times` | action | writes `launch_times` 0 |
| | `motion-debug` | destination `MotionDebugView()` under `#if DEBUG && canImport(CoreMotion)` | icon `sensor.tag.radiowaves.forward` |
| | `gallery` | destination `TouchOverlayGalleryView()` under `#if os(iOS) && DEBUG` | title `L("Gallery")` (PR 4 moved the link here as a raw literal) |
| | `stall-metrics` | toggle | `DOLConfigBridge.stallMetrics()` / `setStallMetrics`, read through `sync` (the refreshed snapshot replaces the old read-through binding) |
| | `perf-bench` | toggle | UserDefaults `ICubeBenchServerEnabled` |
| | `bench-token` | `SettingsRow.custom` (monospaced, `.textSelection(.enabled)` on iOS), only when `benchToken` is non-empty | caption verbatim |
| | `forget-approved-devices` | `SettingsRow.destructive`, only when `approvedClients` is non-empty; title `String(format: L("Forget %1$ld Approved Device(s)"), count)`; description `String(format: L("Currently allowed without prompting: %1$@"), clients.joined(separator: ", "))` | `BenchAccessApproval.shared.forgetAll()` then `hydrated.approvedClients = []` |
| `rendering` "Rendering" | `wireframe` | toggle | `gfxWireframe()` / `setGfxWireframe` |
| `logging` "Logging" | `console-logging` | toggle | UserDefaults `logger_console_enabled` |
| | `logging-verbosity` | cycle `1 ... 5` | `logger_console_verbosity`; `sync` shows `stored > 0 ? stored : LoggerIniMigration.defaultVerbosity`; the old button advanced `(v % 5) + 1`, which is the cycle's wrap |
| | `input-debug` | toggle | UserDefaults `input_debug` |
| `screenshots-artwork` "Screenshots / Artwork" | `template-covers` | toggle `Use Template Covers (Disable Artwork)` | `library_disable_artwork` |

Status rows are `SettingsRow.action(id, title, description, enabled: false, badge: value, run: {})`; each needs a written one-sentence description (the old rows had none). The StikDebug visibility rule is a pure computed property on the State, tested:

```swift
/// Shown only when actionable: JIT not acquired, or acquired on a TXM device with no broker attached and no region yet.
var showsStikDebugEnable: Bool {
  isIOS && hydrated.jitSupported && hydrated.deviceHasTxm && hydrated.stikDebugInstalled
    && (!hydrated.jitAcquired || (hydrated.deviceHasTxm && !hydrated.txmAuthorized && !hydrated.debuggerAttached))
}
```

- [ ] **Step 1: Tests first**: row order for a default state (guard the DEBUG-only rows with `#if DEBUG` / `canImport(CoreMotion)` in the test as in the builder), and for a populated state (`txmHandshakeBlocked`, `deviceHasTxm`, bench token, approved clients); every row described; table-driven toggle emission (`fastmem`, `instant-replay`, `stall-metrics`, `perf-bench`, `wireframe`, `console-logging`, `input-debug`, `template-covers`) both values; `logging-verbosity` options `1...5` and emission; action rows run (`retry-jit-authorization`, `reset-launch-times`, `enable-jit-stikdebug`) via the `Change` they emit; `forget-approved-devices` is `.destructive` and absent for an empty list; `fastmem` disabled when `!fastmemAvailable`; `Recording` section absent when `!isIOS`; `fastmem` and `fastmem-available` ids are distinct; `showsStikDebugEnable` truth table (jit unsupported, no TXM, StikDebug missing, acquired+authorized hides it, acquired+TXM+no broker shows it); the two `stikdebug-help` conditions; verbosity normaliser (0 or out of range → default).
- [ ] **Step 2: State + Change** (`fastmem(Bool)`, `instantReplay(Bool)`, `stallMetrics(Bool)`, `perfBench(Bool)`, `wireframe(Bool)`, `consoleLogging(Bool)`, `loggingVerbosity(Int)`, `inputDebug(Bool)`, `templateCovers(Bool)`, `retryJitAuthorization`, `enableJitViaStikDebug`, `resetLaunchTimes`, `forgetApprovedDevices`), **Step 3: Builder**, **Step 4: Host** (title `L("Debug")`; the `.enableJitViaStikDebug` case is wrapped in `#if os(iOS)`; `git rm SW/DebugRootView.swift`).
- [ ] **Step 5: Register** `debug` with `hostsMenuScreen: true` and `makeModel: { DebugRootModelBuilder.make(state: DebugRootState(isIOS: isIOS), apply: { _ in }) }`, and remove its `keywords:` (the rows are now searchable by their own titles; `haptics` had no row).
- [ ] **Step 6: Existing tests (Q1).** `hostsMenuScreen` set gains `"debug"`. `test_migratedLeaves_exposeTheirModels`: add `"debug"` to the id list and DELETE the `XCTAssertNil(entries.first { $0.id == "debug" }?.makeModel, …)` assertion (no hand-built leaf is left to assert on). `SettingsSearchIndexTests.test_keyword_matchesAHandBuiltLeaf` used `debug`'s `fastmem` keyword and no hand-built leaf with keywords remains; replace it with a description match on a leaf that stays hand-built:

```swift
/// A hand-built leaf has no model, so its title, description and keywords still count.
func test_handBuiltLeaf_isFoundByItsDescription() {
  XCTAssertTrue(index.hits(query: "wi-fi").contains(SettingsSearchHit(entryID: "web-ui", rowTitle: nil)))
}
func test_debugRows_areFoundByTheirOwnTitles() {
  XCTAssertTrue(index.hits(query: "fastmem").contains { $0.entryID == "debug" })
  XCTAssertTrue(index.hits(query: "wireframe").contains { $0.entryID == "debug" })
}
```

**Close-out** (every step required)
- [ ] `cd Source/iOS/App && tuist generate --no-open`
- [ ] `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/DebugRootModelBuilderTests -only-testing:iCubeTests/SettingsRootModelBuilderTests -only-testing:iCubeTests/SettingsSearchIndexTests"`: green
- [ ] tvOS compile: `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos`
- [ ] `python3 Project/Scripts/check_localized_keys.py --check` exits 0
- [ ] `git checkout -- build/xcframework`; stage only this task's files and your own `Core.strings` lines (`git add -p`)
- [ ] Commit `feat(settings): Debug on the menu engine` (no trailer)

---

### Task 12: Cleanup and documentation

**Batch C rules:** branch `feat/settings-leaves-c`; this task runs after Tasks 8-11 are committed.

- [ ] **Step 1: Dead helpers.** From `Source/iOS/App`, grep each of `settingsCaption(`, `settingsNavCaption(`, `SettingsSelectRow`, `TVIntStepper`, `TVFloatStepper`, `TVIntStepperOverlay`, `MetalTriStatePicker`. Delete only a helper with NO remaining caller. Expected survivors: `settingsCaption`/`SettingsSelectRow`/`TVIntStepper` (`ConfigAchievementsView`, `DSUSettingsView`, `SourcesView`, `ShaderDebugView`), `TVFloatStepper` (`ShaderQuickPickerView`, `ShaderSettingsView`), `TVIntStepperOverlay` (tvOS-only quick overlay in `EmulationScreen`; it stays, `ValueStepper` is iOS-only and cannot replace it). If a helper is deleted, its tests go with it.
- [ ] **Step 2: Docs.** If the repo's `CLAUDE.md` (or `docs/` settings note) has a Settings section, state that a settings leaf is `State` + `Change` + `ModelBuilder` + host rendered by `SettingsLeafScreen`, that `sync()` reads and `apply(_:)` writes (seeding is the only exception, an explicit host step), and that new settings go in a builder, never a hand-built `Form`. If no such note exists, skip this step.
- [ ] **Step 3: Final checks.** `grep -rn "settingsLeaf(" Source/iOS/App/Common/UI/Settings` shows only `SettingsLeafScreen`'s own use; every entry in `SettingsRootModelBuilder` except the hand-built table at the top of this plan has `hostsMenuScreen: true` and a `makeModel`; `python3 Project/Scripts/check_localized_keys.py --check` exits 0.

**Close-out** (every step required)
- [ ] `cd Source/iOS/App && tuist generate --no-open`
- [ ] Whole target: `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro"`: green
- [ ] tvOS compile: `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos`
- [ ] `git checkout -- build/xcframework`; stage only this task's files
- [ ] Commit `chore(settings): remove helpers the migrated leaves no longer use` (no trailer)
- [ ] **Batch C end: Stop. The controller merges this batch into develop after review.**
