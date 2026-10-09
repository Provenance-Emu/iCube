# Settings on the Menu Engine Implementation Plan (PR 3 of the unified menu UX)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Executors see only their own `### Task N` text.** Every rule that affects a task is restated inside that task; the Global Constraints and the deviation list below are for reviewers. Line numbers in this plan are pointers only: grep for the symbol.

**Goal:** Settings renders through `MenuModel`/`MenuScreen` with a sidebar shell on tvOS and iPad, every row carrying a one-line description, controller-adjustable rows, generated search, and the four largest leaf screens (Performance Tuning, Graphics Hacks, Graphics General, Graphics Enhancements) migrated to model builders.

**Architecture:** Each migrated leaf becomes a plain `State` snapshot, a `Change` enum, a pure `ModelBuilder.make(state:apply:)`, and a thin host view that syncs the snapshot from Config and applies changes to Config. Rows are built with the shared `SettingsRow` factory. The root becomes a `SettingsRootModelBuilder` whose rows point at leaf views; `SettingsRootView` picks a sidebar shell (tvOS, iPad at regular width) or a grouped list (iPhone). Unmigrated leaves stay reachable: the root rows are `.action` rows that select/push the leaf's own view.

**Tech Stack:** Swift 5, SwiftUI, XCTest (`iCubeTests`), Tuist.

**Spec:** `docs/superpowers/specs/2026-10-07-unified-menu-ux-design.md` §4.1 (`ValueStepper`), §6, §8, §9, §10 item 3. Depends on PR 2 (`.cycle`, `description`, `longPress`, `FocusButtonStyle`, the long-press picker in `MenuScreen`).

**Spec deviations, decided while planning:**
- **iPhone gets a grouped list, not a tab strip.** The sidebar lists the ~20 leaf pages grouped under 8 headers; a capsule strip of 20 items is worse than the list the iPhone has today. The iPhone root is the same `MenuModel` rendered as `MenuScreen(.list)` with icons and descriptions, pushing leaves. Spec §6.1's "tab-strip shell" is replaced by this.
- **The sidebar lists leaf pages, not sections.** Selecting a sidebar row shows that leaf in the pane (iFly's shape), so a setting is two moves away, not three.
- **The sidebar shell is used on tvOS and on iPad at regular width only** (`userInterfaceIdiom == .pad && horizontalSizeClass == .regular`); iPhone, including Max/Plus landscape, is always the grouped list. Size class alone would drop search, Reset All and the deep link on a Max iPhone in landscape. (P16)
- **Reset All** stays in the iPhone toolbar and is also a destructive row in the About leaf on every platform (the only Reset All inside the sidebar shell), not "at the bottom of General" (§6.2): the General leaf is not migrated in this PR. The confirmation alert is one shared view that both places use. The sidebar shell has search on iPad (not tvOS, as before) and honours the `DOLSettingsSelectControllers` deep link by selecting the Controllers leaf. (P16)
- **Root rows are `.action` rows plus `makeView`, with a navigation chevron**, not `.destination(AnyView)` (§6.3, §6.5): the sidebar must select a leaf into its pane rather than push it, so the row cannot own the navigation. The chevron is a new `MenuItem.showsChevron` flag. (P17)
- **`ValueStepper` is `Double`-backed, not generic over `BinaryInteger`/`FloatingPoint`** (§4.1). Int settings round through it; `stepped()` snaps to the step grid so a 0.1 step cannot accumulate float drift into Config. (P7)
- **tvOS left/right on a `.cycle` or `.stepper` list row steps the value** (the spec makes rows controller-adjustable, §4.1); left on any other row moves focus to the sidebar; Menu/B always returns to the sidebar, and Menu at the sidebar leaves Settings. From a stepper row, left therefore does not reach the sidebar (Menu does). (P5)
- **`SheetScaffold` is dropped** from spec §4.1: nothing in PR 2 or PR 3 needs it.
- **No builder throws** (§8's "leaf builders that throw"): every builder takes a snapshot struct with defaults, so a missing Config key shows a default, never an empty section.

## Global Constraints

- Minimum targets iOS 17 / tvOS 17; every changed file compiles for both.
- Settings rows never save what they only displayed: a host syncs its snapshot from Config in `configSynced` and writes Config only from `apply(_:)`, which only a control reaches. `SettingsWriteBackTests` describes the rule. A builder is pure, so it cannot write; the rule is enforced in the hosts (no `DOLConfigBridge.set*` or `UserDefaults.set` inside `sync()`), and by reading each host's `sync()` in review.
- Row ids are stable strings, lowercase-kebab, unique within a leaf (e.g. `efb-access`, `vi-skip-mode`).
- Descriptions are the caption strings the current views pass to `settingsCaption` / `rowWithCaption` / `settingsNavCaption`, copied verbatim (they are already localised through `L(...)`). A row that has no caption today gets a one-sentence description written for it; never leave `description` nil on a settings row.
- Strings go through `L("...")`.
- Pause/resume only through `PauseArbiter`.
- Commits: conventional, subject < 72 chars, **no trailers and no LLM attribution lines of any kind** (owner rule; it overrides any harness default).
- Build commands, run from `Source/iOS/App` (the scheme is multi-platform; there is no `iCube-tvOS` scheme):
  ```bash
  xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-ios
  xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos
  ```
- New test files need `cd Source/iOS/App && tuist generate --no-open`. Tests: `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/<Class>"`.
- Worktree is on branch `feat/settings-engine`, stacked on `feat/menukit-pause-overlay` (PR 2). DO NOT git reset / rebase / push / touch develop.
- Paths are relative to `Source/iOS/App/` unless they start with `docs/`. `UI/Settings/SwiftUI/` means `Common/UI/Settings/SwiftUI/`.

## File map

| File | Responsibility |
|---|---|
| Modify `Common/Swift/Menu/MenuModel.swift` | `.stepper` role, `MenuSection.footer`, `MenuItem.showsChevron`. |
| Modify `Common/Swift/Menu/MenuControllerNav.swift`, `MenuFocusRouter.swift` | Stepper hold-to-repeat (`.adjustRepeat`), `.stepper` counts as a picker. |
| Create `Common/Swift/MenuKit/ValueStepper.swift` | iOS slider row control (tvOS builds its stepper row inside `MenuScreen`). |
| Modify `Common/Swift/Menu/MenuScreen.swift` | `.stepper` rows; `.cycle` list rows (value, badge, description, long-press, tvOS left/right); footers; chevrons. |
| Create `UI/Settings/SwiftUI/SettingsLeafHost.swift` | `SettingsLeafScreen` (MenuScreen + title + help + `configSynced` + start/end resync + Back), `settingsPaneBack` environment value. |
| Create `UI/Settings/SwiftUI/SettingsEnums.swift` | The six picker enums, `CpuEngine` made internal. |
| Modify `UI/Settings/SwiftUI/SettingsSharedComponents.swift` | `settingsCaption`/`settingsNavCaption` (moved), `MetalTriStatePicker` (moved), `ConfigOverrideBadge.title(for:)`, `SettingsResetAllButton`. |
| Create `UI/Settings/SwiftUI/Leaves/SettingsRowFactory.swift` | `SettingsRow.toggle/cycle/stepper/action/destination`, shared by Tasks 3-6. |
| Create `UI/Settings/SwiftUI/Leaves/GraphicsHacks{State,ModelBuilder,View}.swift` | Hacks on the engine. |
| Create `UI/Settings/SwiftUI/Leaves/GraphicsEnhancements{State,ModelBuilder,View}.swift` | Enhancements on the engine. |
| Create `UI/Settings/SwiftUI/Leaves/GraphicsGeneral{State,ModelBuilder,View}.swift` | Video on the engine. |
| Create `UI/Settings/SwiftUI/Leaves/PerformanceTuning{State,ModelBuilder,View}.swift` | Performance on the engine. |
| Delete `UI/Settings/SwiftUI/GraphicsHacksView.swift`, `GraphicsEnhancementsView.swift`, `GraphicsGeneralView.swift`, `PerformanceTuningView.swift` | Replaced. Their private picker sub-views go with them; their enums move to `SettingsEnums.swift` and the file-scope `settingsCaption`/`settingsNavCaption` helpers to `SettingsSharedComponents.swift` (Task 2). |
| Create `UI/Settings/SwiftUI/SettingsRootModelBuilder.swift` | Root sections and rows. |
| Create `UI/Settings/SwiftUI/SettingsSearchIndex.swift` | Value built once per Settings appearance from the root and leaf models; plus the shared results list view. |
| Create `UI/Settings/SwiftUI/SettingsSidebarShell.swift` | tvOS / iPad shell. |
| Create `UI/Settings/SwiftUI/WebUISettingsView.swift` | Web UI + WebDAV rows and the Safari sheet, out of the root. |
| Modify `UI/Settings/SwiftUI/SettingsRootView.swift` | Thin host choosing a shell. |
| Modify `UI/Settings/SwiftUI/AboutView.swift` | Absorbs the Blog and Help rows and the Reset All row (Version and Core are already there). |
| Delete `Common/Swift/TVSettingsPage.swift` | Replaced by the sidebar shell; its callers (grep `TVSettingsPage(`: `TVLibraryView.swift` twice, `EmulationScreen.swift` once) use `SettingsRootView()`. |
| Tests: extend `MenuModelTests`, `MenuFocusRouterTests`; create `ValueStepperTests`, `SettingsRowFactoryTests`, `SettingsSharedComponentsTests`, `GraphicsHacksModelBuilderTests`, `GraphicsEnhancementsModelBuilderTests`, `GraphicsGeneralModelBuilderTests`, `PerformanceTuningModelBuilderTests`, `SettingsRootModelBuilderTests`, `SettingsSearchIndexTests`, `SettingsSnapshotRenderTests`. |

---

### Task 1: `.stepper` role, `ValueStepper`, controller-adjustable rows, descriptions

Rulings that apply here (restated; you will not see the rest of the plan): **P4** cycle rows must show description, value and override badge; **P5** tvOS left/right steps cycle/stepper rows; **P6** stepper rows repeat while left/right is held (cycle rows do not); **P7** `ValueStepper` stays `Double`-backed and `stepped()` snaps to the step grid; **P10** no vacuous tests; **P17** root rows need a chevron flag; **P13** sections need a footer. Commits carry no trailers or attribution.

**Files:**
- Modify: `Common/Swift/Menu/MenuModel.swift` (`.stepper` role, `MenuStepper`, `MenuSection.footer`, `MenuItem.showsChevron`)
- Modify: `Common/Swift/Menu/MenuControllerNav.swift` (`Event.adjustRepeat`)
- Modify: `Common/Swift/Menu/MenuFocusRouter.swift` (`isPicker` counts `.stepper`; pass `.adjustRepeat` through for steppers only)
- Create: `Common/Swift/MenuKit/ValueStepper.swift` (`#if os(iOS)` entire file: SwiftUI `Slider` does not exist on tvOS)
- Modify: `Common/Swift/Menu/MenuScreen.swift` (grep for `listRow`, `tvRow`, `performActivate`, `tick`, `rowLabel`, `listSection`, `tvSection`, `tvCompactPicker`)
- Test: extend `DolphiniOSTests/MenuModelTests.swift` and `DolphiniOSTests/MenuFocusRouterTests.swift`; create `DolphiniOSTests/ValueStepperTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct MenuStepper {
    var value: Binding<Double>
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String
    /// direction is ±1. Clamped to `range`, then snapped to the grid `range.lowerBound + n * step`.
    func stepped(_ current: Double, by direction: Int) -> Double
  }
  // MenuItemRole gains:
  case stepper(MenuStepper)
  // MenuSection gains `var footer: String?` (init parameter `footer: String? = nil`, after `header`)
  // MenuItem gains `var showsChevron: Bool = false` (last init parameter)
  // MenuControllerNav.Event gains `case adjustRepeat(Int)`
  #if os(iOS)
  struct ValueStepper: View { init(stepper: MenuStepper, isEnabled: Bool) }
  #endif
  ```

- [ ] **Step 1: Write the failing tests**

Append to `MenuModelTests`:
```swift
  func test_stepper_currentValueTitle_usesTheFormat() {
    let stepper = MenuStepper(value: .constant(100), range: 1 ... 400, step: 5, format: { "\(Int($0))%" })
    XCTAssertEqual(MenuItem(id: "clock", title: "CPU Clock", role: .stepper(stepper)).currentValueTitle, "100%")
  }

  func test_section_keepsItsFooter() {
    let section = MenuSection(id: "s", header: "H", footer: "F", items: [])
    XCTAssertEqual(section.footer, "F")
    XCTAssertNil(MenuSection(id: "t", items: []).footer)
  }

  func test_item_showsChevron_defaultsOff() {
    XCTAssertFalse(MenuItem(id: "a", title: "A", role: .action({})).showsChevron)
    XCTAssertTrue(MenuItem(id: "b", title: "B", role: .action({}), showsChevron: true).showsChevron)
  }
```
Create `ValueStepperTests` (the logic is `MenuStepper.stepped`; there is no view logic to test):
```swift
// DolphiniOSTests/ValueStepperTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class ValueStepperTests: XCTestCase {
  private func stepper(range: ClosedRange<Double>, step: Double) -> MenuStepper {
    MenuStepper(value: .constant(range.lowerBound), range: range, step: step, format: { "\($0)" })
  }

  func test_stepped_clampsAtBothEnds() {
    let s = stepper(range: 0 ... 400, step: 5)
    XCTAssertEqual(s.stepped(100, by: 1), 105)
    XCTAssertEqual(s.stepped(398, by: 1), 400, "clamped at the top")
    XCTAssertEqual(s.stepped(3, by: -1), 0, "clamped at the bottom")
  }

  func test_stepped_tenthsDoNotDriftOffTheGrid() {
    let s = stepper(range: 0 ... 30, step: 0.1)
    var value = 0.0
    for _ in 0 ..< 3 { value = s.stepped(value, by: 1) }
    XCTAssertEqual(value, 0.3, "0.1 + 0.1 + 0.1 is 0.30000000000000004 without snapping")
    for _ in 0 ..< 7 { value = s.stepped(value, by: 1) }
    XCTAssertEqual(value, 1.0)
  }

  func test_stepped_snapsAnOffGridStartToTheGrid() {
    let s = stepper(range: 0 ... 30, step: 0.1)
    XCTAssertEqual(s.stepped(0.34, by: 1), 0.4)
    XCTAssertEqual(s.stepped(0.34, by: -1), 0.2)
  }

  func test_stepped_integerStepsStayIntegral() {
    let s = stepper(range: 1 ... 400, step: 1)
    XCTAssertEqual(s.stepped(37, by: 1), 38)
    XCTAssertEqual(s.stepped(37.0000001, by: -1), 36)
  }
}
```
Append to `MenuFocusRouterTests` (it already scripts `MenuControllerNav` through the router; reuse its `cfg`):
```swift
  // MARK: Stepper rows

  private func singleRowModel(_ role: MenuItemRole) -> MenuModel {
    MenuModel(sections: [MenuSection(id: "s", items: [MenuItem(id: "row", title: "Row", role: role)])])
  }

  private func stepperRole() -> MenuItemRole {
    .stepper(MenuStepper(value: .constant(50), range: 0 ... 100, step: 1, format: { "\(Int($0))" }))
  }

  private func cycleRole() -> MenuItemRole {
    .cycle(options: [("a", AnyHashable(0)), ("b", AnyHashable(1))], selection: .constant(AnyHashable(0)))
  }

  /// One tick of a held (or released) d-pad left on the single focused row, through the multi-pad API.
  private func leftTick(_ router: inout MenuFocusRouter, _ model: MenuModel, at time: TimeInterval, held: Bool) -> MenuFocusUpdate {
    router.update(padInputs: [("pad", MenuControllerNav.Input(left: held))], at: time, model: model, focusedID: "row", isActive: true)
  }

  func test_heldLeft_onStepper_repeatsAfterTheInitialDelay() {
    var router = MenuFocusRouter(config: cfg)
    let model = singleRowModel(stepperRole())
    _ = leftTick(&router, model, at: 0, held: false)   // a pad's first tick is a resync
    XCTAssertEqual(leftTick(&router, model, at: 0.1, held: true).adjust?.step, -1)
    XCTAssertNil(leftTick(&router, model, at: 0.3, held: true).adjust, "inside the initial delay")
    XCTAssertEqual(leftTick(&router, model, at: 0.55, held: true).adjust?.step, -1)
    XCTAssertNil(leftTick(&router, model, at: 0.58, held: true).adjust, "inside the repeat interval")
    XCTAssertEqual(leftTick(&router, model, at: 0.64, held: true).adjust?.step, -1)
  }

  func test_heldLeft_onCycle_stepsOncePerPress() {
    var router = MenuFocusRouter(config: cfg)
    let model = singleRowModel(cycleRole())
    _ = leftTick(&router, model, at: 0, held: false)
    XCTAssertEqual(leftTick(&router, model, at: 0.1, held: true).adjust?.step, -1)
    XCTAssertNil(leftTick(&router, model, at: 0.55, held: true).adjust, "a cycle row never repeats")
    XCTAssertNil(leftTick(&router, model, at: 1.2, held: true).adjust)
  }

  func test_leftRight_onStepper_adjustsInsteadOfMovingFocus() {
    var router = MenuFocusRouter(config: cfg)
    let model = MenuModel(sections: [MenuSection(id: "s", items: [
      MenuItem(id: "row", title: "Row", role: stepperRole()),
      MenuItem(id: "next", title: "Next", role: .action({})),
    ])])
    _ = leftTick(&router, model, at: 0, held: false)
    let result = leftTick(&router, model, at: 0.1, held: true)
    XCTAssertEqual(result.focusedID, "row")
    XCTAssertEqual(result.adjust?.id, "row")
  }
```

- [ ] **Step 2: Regenerate, run, verify failure** (`MenuModelTests`, `ValueStepperTests`, `MenuFocusRouterTests`). Expected: `MenuStepper`, `footer`, `showsChevron` not found.

- [ ] **Step 3: Model, nav and router**

`MenuModel.swift`:
```swift
/// A numeric setting: a `Slider` row on iOS, a left/right stepper row on tvOS (spec §6.3).
/// `Double`-backed on purpose: Int settings round through it, and `stepped` snaps to the grid.
struct MenuStepper {
  var value: Binding<Double>
  var range: ClosedRange<Double>
  var step: Double
  var format: (Double) -> String

  /// Digits kept when snapping: enough for any step this app uses (0.1 minimum) and few enough that
  /// `0.1 * 3` comes back as exactly `0.3`.
  private static let snapPrecision = 1_000_000.0

  func stepped(_ current: Double, by direction: Int) -> Double {
    let clamped = min(range.upperBound, max(range.lowerBound, current + Double(direction) * step))
    let onGrid = range.lowerBound + ((clamped - range.lowerBound) / step).rounded() * step
    let snapped = (onGrid * Self.snapPrecision).rounded() / Self.snapPrecision
    return min(range.upperBound, max(range.lowerBound, snapped))
  }
}
```
Add `case stepper(MenuStepper)` to `MenuItemRole`. In `MenuItem.currentValueTitle` add `case .stepper(let stepper): return stepper.format(stepper.value.wrappedValue)`. Add `var footer: String?` to `MenuSection` (init parameter after `header`, default nil) and `var showsChevron: Bool = false` to `MenuItem` (last init parameter, default false).

`MenuControllerNav.swift`: add `/// Left/right still held after Config.initialRepeatDelay: one per Config.repeatInterval. Only a stepper row acts on it (MenuFocusRouter).` `case adjustRepeat(Int)` to `Event`; update the `Input.left/right` doc ("One step per press; hold repeats via `.adjustRepeat`"). Reuse the existing `initialRepeatDelay`/`repeatInterval`, no new constants. New private state `heldAdjust = 0`, `adjustHoldStart`, `lastAdjustRepeat`, `suppressAdjustRepeatUntilRelease`. After the existing left/right edge handling in `update`:
```swift
    let adjustDirection = input.left == input.right ? 0 : (input.left ? -1 : 1)
    if adjustDirection != heldAdjust {
      heldAdjust = adjustDirection
      suppressAdjustRepeatUntilRelease = false
      adjustHoldStart = time
      lastAdjustRepeat = time
    } else if adjustDirection != 0, !suppressAdjustRepeatUntilRelease,
              time - adjustHoldStart >= config.initialRepeatDelay,
              time - lastAdjustRepeat >= config.repeatInterval {
      lastAdjustRepeat = time
      events.append(.adjustRepeat(adjustDirection))
    }
```
and in `resync`: `heldAdjust = input.left == input.right ? 0 : (input.left ? -1 : 1); adjustHoldStart = time; lastAdjustRepeat = time; suppressAdjustRepeatUntilRelease = heldAdjust != 0`.

`MenuFocusRouter.swift`: in `isPicker` add `.stepper` to the `case .picker, .cycle:` line. In `apply`, add:
```swift
      case .adjustRepeat(let step):
        // Only a stepper repeats: a 1...400 stepper needs ~400 presses otherwise. A cycle row keeps one step per press.
        if columns == 1, let current, MenuFocusRouter.isStepper(current, in: model) {
          adjust = (current, step)
        }
```
plus
```swift
  private static func isStepper(_ id: String, in model: MenuModel) -> Bool {
    if case .stepper? = model.item(id: id)?.role { return true }
    return false
  }
```

- [ ] **Step 4: `ValueStepper` (iOS slider only) and `MenuScreen`**

`ValueStepper.swift`:
```swift
// Common/Swift/MenuKit/ValueStepper.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import SwiftUI

/// The iOS control of a `.stepper` row: a `Slider` with the formatted value beside it. tvOS has no
/// `Slider`; `MenuScreen.tvRow` builds that row itself (see `tvSteppedRow`).
struct ValueStepper: View {
  let stepper: MenuStepper
  let isEnabled: Bool

  private static let valueMinWidth: CGFloat = 56

  var body: some View {
    HStack(spacing: 12) {
      Slider(value: stepper.value, in: stepper.range, step: stepper.step)
      Text(stepper.format(stepper.value.wrappedValue)).monospacedDigit()
        .frame(minWidth: Self.valueMinWidth, alignment: .trailing)
    }
    .disabled(!isEnabled)
  }
}
#endif
```
`MenuScreen.swift`:

1. `rowLabel(title:subtitle:icon:tint:badge:)` gains three defaulted parameters (existing callers keep compiling): `value: String? = nil, description: String? = nil, showsChevron: Bool = false`. Body: under the subtitle, `if let description { Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }`; trailing, before the existing badge text, `if let value { Text(value).foregroundStyle(.secondary) }`; after it `if showsChevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }`. `rowLabel(_ item:)` passes `badge: item.badge, description: item.description, showsChevron: item.showsChevron`.
2. **`.cycle` rows (iOS `listRow` and tvOS `tvRow`) no longer call the old 5-arg form.** They call `rowLabel(title: item.title, subtitle: item.subtitle, icon: item.icon, tint: item.tint, badge: item.badge, value: item.currentValueTitle, description: item.description)`: the description shows, the value shows, and an override badge ("Auto"/"Game") still shows beside it. (Tiles keep `item.currentValueTitle ?? item.badge`.)
3. iOS `listRow`: `.cycle` button gets `.simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in runLongPress(item) })`. New case:
   ```swift
   case .stepper(let stepper):
     VStack(alignment: .leading, spacing: 6) {
       rowLabel(item)
       ValueStepper(stepper: stepper, isEnabled: item.isEnabled)
     }
   ```
4. `performActivate`: `case .stepper: break` (A does nothing on a stepper; left/right adjust).
5. iOS `tick()` adjust block: handle the stepper before the options-based branch:
   ```swift
   if let adjust = result.adjust, let item = model.item(id: adjust.id), item.isEnabled {
     if case .stepper(let stepper) = item.role {
       stepper.value.wrappedValue = stepper.stepped(stepper.value.wrappedValue, by: adjust.step)
     } else if let stepping = item.role.steppable,
               let next = MenuItemRole.cycled(options: stepping.options, current: stepping.selection.wrappedValue, step: adjust.step) {
       stepping.selection.wrappedValue = next
     }
   }
   ```
6. **tvOS rows (P5).** PR 2 removed the tiles' `onMoveCommand` (commit f403268787), so there is nothing to copy from the tiles. The in-repo pattern is `tvCompactPicker`: one `.focusable` HStack that carries BOTH `.focused($tvFocusedID, equals: item.id)` and `.onMoveCommand`. Generalise it:
   ```swift
   /// A row that left/right steps: title, then "‹ value ›". Built like `tvCompactPicker` always was: a
   /// `.focusable` HStack with `.onMoveCommand`, not a `Button`, because select does nothing here.
   private func tvSteppedRow(_ item: MenuItem, valueTitle: String, step: @escaping (Int) -> Void) -> some View {
     HStack {
       rowLabel(item)
       Image(systemName: "chevron.left")
       Text(valueTitle).monospacedDigit()
       Image(systemName: "chevron.right")
     }
     .frame(maxWidth: .infinity, alignment: .leading)
     .contentShape(Rectangle())
     .focusable(item.isEnabled)
     .focused($tvFocusedID, equals: item.id)
     .padding(8)
     .overlay(
       RoundedRectangle(cornerRadius: 10)
         .stroke(tvFocusedID == item.id ? Color.accentColor : Color.clear, lineWidth: 4))
     .opacity(item.isEnabled ? 1 : 0.5)
     .onMoveCommand { direction in
       guard item.isEnabled else { return }
       switch direction {
       case .left: step(-1)
       case .right: step(1)
       default: break
       }
     }
   }
   ```
   `tvCompactPicker` becomes `tvSteppedRow(item, valueTitle: MenuItemRole.selectedTitle(options: options, current: selection.wrappedValue) ?? "") { stepPicker(selection, options: options, by: $0) }`. In `tvRow`:
   ```swift
   case .stepper(let stepper):
     tvSteppedRow(item, valueTitle: stepper.format(stepper.value.wrappedValue)) { direction in
       stepper.value.wrappedValue = stepper.stepped(stepper.value.wrappedValue, by: direction)
     }
   case .cycle(let options, let selection):
     Button { performActivate(item) } label: {
       rowLabel(title: item.title, subtitle: item.subtitle, icon: item.icon, tint: item.tint, badge: item.badge,
                value: item.currentValueTitle, description: item.description)
     }
     .disabled(!item.isEnabled)
     .focused($tvFocusedID, equals: item.id)
     .onMoveCommand { direction in      // A still cycles; left/right step without leaving the row
       guard item.isEnabled else { return }
       switch direction {
       case .left: stepPicker(selection, options: options, by: -1)
       case .right: stepPicker(selection, options: options, by: 1)
       default: break
       }
     }
   ```
   Left on any other row (toggle, action, destination) is untouched: the focus engine moves to the sidebar's focus section. `tvOS` `onMoveCommand` repeats while the direction is held, so no tvOS-side repeat code is needed (confirm on device, gate 6).
7. **Footers.** In `listSection` and `tvSection` add the footer to the existing two branches: `Section(header: Text(header), footer: footerView(section)) { ... }` and `Section(footer: footerView(section)) { ... }`, with
   ```swift
   @ViewBuilder
   private func footerView(_ section: MenuSection) -> some View {
     if let footer = section.footer { Text(footer) }
   }
   ```
8. `rowLabel(item)` already shows `item.description` (step 1), so toggle, picker, action and destination rows show it too. Grep the existing `MenuScreen(...)` call sites (`CheatsMenuView`, `ControllerHubView` and the Player screens) for items that set `description:`: those rows now show the text inline in `.list` style; confirm that is acceptable (it is the intent: every row carries a one-liner) and note any that look wrong.

`TVIntStepper`/`TVFloatStepper` stay: six call sites remain in `ConfigWiiView`, `ConfigAudioView` and `ConfigAdvancedView`. Tasks 4 and 6 stop using them; deleting them is not part of this PR.

- [ ] **Step 5: Run to verify pass** (`MenuModelTests`, `ValueStepperTests`, `MenuFocusRouterTests`, then the whole `iCubeTests` target), then build both platforms (commands in the section below).

Build, from `Source/iOS/App`:
```bash
xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-ios
xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos
```

- [ ] **Step 6: Commit** (subject only, no trailers, no attribution)

```bash
git add Common/Swift/Menu/MenuModel.swift Common/Swift/Menu/MenuControllerNav.swift Common/Swift/Menu/MenuFocusRouter.swift Common/Swift/Menu/MenuScreen.swift Common/Swift/MenuKit/ValueStepper.swift DolphiniOSTests/MenuModelTests.swift DolphiniOSTests/MenuFocusRouterTests.swift DolphiniOSTests/ValueStepperTests.swift
git commit -m "feat(menu): .stepper role, adjustable rows, footers, descriptions"
```

---

### Task 2: Leaf host scaffolding and moved shared code

Rulings that apply here (restated): **P1** `settingsCaption`/`settingsNavCaption` move unchanged into `SettingsSharedComponents.swift` (16 files use them and Task 6 deletes their home); **P2** `CpuEngine` becomes internal and `ConfigOverrideBadge` exposes `static func title(for:)` (the later tests cannot compile otherwise); **P14** every leaf host passes `onBack`, and a leaf in the sidebar pane returns to the sidebar instead of dismissing Settings; **P18** notification names come from existing constants; commits carry no trailers or attribution.

**Files:**
- Create: `UI/Settings/SwiftUI/SettingsLeafHost.swift`
- Create: `UI/Settings/SwiftUI/SettingsEnums.swift` (move `GraphicsBackend`, `AspectRatio`, `TargetFPS`, `InternalScale`, `ShaderCompileType` out of `GraphicsGeneralView.swift` and `CpuEngine` out of `PerformanceTuningView.swift`; those are the only two files with enums to move)
- Modify: `UI/Settings/SwiftUI/SettingsSharedComponents.swift` (receives `settingsCaption`, `settingsNavCaption`; `ConfigOverrideBadge.title(for:)`)
- Modify: `UI/Settings/SwiftUI/GraphicsGeneralView.swift`, `UI/Settings/SwiftUI/PerformanceTuningView.swift` (remove what moved)
- Test: create `DolphiniOSTests/SettingsSharedComponentsTests.swift`

**Interfaces:**
- Produces:
  ```swift
  /// MenuScreen + title + help button + Config sync, for an engine-backed leaf.
  struct SettingsLeafScreen: View {
    init(model: MenuModel, title: String, helpKey: String? = nil, sync: @escaping () -> Void)
  }
  extension EnvironmentValues { var settingsPaneBack: (() -> Void)? { get set } }   // set by the sidebar shell (Task 7)
  extension ConfigOverrideBadge { static func title(for override: DOLConfigOverride) -> String? }
  ```

- [ ] **Step 1: Write the failing test**

```swift
// DolphiniOSTests/SettingsSharedComponentsTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class SettingsSharedComponentsTests: XCTestCase {
  func test_overrideBadgeTitle_namesWhoIsDrivingTheKey() {
    XCTAssertEqual(ConfigOverrideBadge.title(for: .auto), L("Auto"))
    XCTAssertEqual(ConfigOverrideBadge.title(for: .game), L("Game"))
    XCTAssertNil(ConfigOverrideBadge.title(for: .none))
  }
}
```
Regenerate (`cd Source/iOS/App && tuist generate --no-open`), run `SettingsSharedComponentsTests`, expect a compile failure (`title(for:)` missing).

- [ ] **Step 2: Move shared code and widen access**

1. In `SettingsSharedComponents.swift`, `ConfigOverrideBadge`: replace the `private var title: String?` with `static func title(for override: DOLConfigOverride) -> String?` (same switch), and have `body` use `Self.title(for: override)`.
2. Cut the file-scope `settingsCaption` and `settingsNavCaption` functions (grep for them in `PerformanceTuningView.swift`; they carry their doc comments) and paste them unchanged into `SettingsSharedComponents.swift`.
3. Create `SettingsEnums.swift` and cut the six enums into it unchanged, **except `CpuEngine`, which changes from `private enum` to `enum`** (the builder, the state and the tests need it). Keep its raw-value comment block.

- [ ] **Step 3: Write the host**

```swift
// UI/Settings/SwiftUI/SettingsLeafHost.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import UIKit

private struct SettingsPaneBackKey: EnvironmentKey {
  static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
  /// Set by the sidebar shell on its pane: what Back means for a leaf shown in the pane (focus returns
  /// to the sidebar). `nil` outside the shell, where a leaf is pushed and Back pops it.
  var settingsPaneBack: (() -> Void)? {
    get { self[SettingsPaneBackKey.self] }
    set { self[SettingsPaneBackKey.self] = newValue }
  }
}

/// What every engine-backed settings leaf needs around its `MenuScreen`: a title, the help sheet
/// button, and the same resync points the hand-built leaves had (`configSynced`, emulation start/
/// end, foreground). `sync` assigns the host's snapshot only; it never writes Config.
private struct SettingsLeafHost: ViewModifier {
  let title: String
  let helpKey: String?
  let sync: () -> Void

  func body(content: Content) -> some View {
    content
      .navigationTitle(title)
      .configSynced(sync)
      .onReceive(NotificationCenter.default.publisher(for: Notification.Name(DOLEmulationDidStartNotification))) { _ in sync() }
      .onReceive(NotificationCenter.default.publisher(for: EmulationState.didEndName)) { _ in sync() }
      #if os(iOS)
      .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in sync() }
      #endif
      .toolbar {
        if let helpKey {
          HelpButton(helpKey: helpKey)
        }
      }
  }
}

extension View {
  /// Title, help sheet, Config sync on appear/Config change/emulation start+stop/foreground.
  func settingsLeaf(title: String, helpKey: String? = nil, sync: @escaping () -> Void) -> some View {
    modifier(SettingsLeafHost(title: title, helpKey: helpKey, sync: sync))
  }
}

/// A migrated leaf: its `MenuScreen` plus the host chrome. Back (a pad's B on iOS, Menu on tvOS) goes to
/// the sidebar when the shell supplies `settingsPaneBack`, and pops/dismisses otherwise. Without
/// `onBack` the pad's B did nothing on a pushed leaf, so a pad could push a leaf and never leave it.
struct SettingsLeafScreen: View {
  let model: MenuModel
  let title: String
  var helpKey: String?
  let sync: () -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.settingsPaneBack) private var paneBack

  var body: some View {
    MenuScreen(model: model, style: .list, onBack: { if let paneBack { paneBack() } else { dismiss() } })
      .settingsLeaf(title: title, helpKey: helpKey, sync: sync)
  }
}
```
Before writing, grep the notification constants: `EmulationState.didEndName` is a Swift constant (`Common/Services/EmulationState.swift`); the start notification is the ObjC constant `DOLEmulationDidStartNotification` (`Common/Emulation/EmulationCoordinator.h`), which Swift sees as an `NSString`. If the bridging header does not expose it, use `EmulationState.willStartName` and say so in the commit body. `HelpButton` is `ToolbarContent`; if the compiler rejects the `if let` inside `.toolbar { }`, wrap it in `ToolbarItem`-free `Group` or split into two modifiers applied via `helpKey == nil`.

- [ ] **Step 4: Run `SettingsSharedComponentsTests`; build both platforms**

```bash
cd Source/iOS/App
xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-ios
xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos
```
`SettingsLeafScreen` is unused until Task 3; the tests and build prove the moves.

- [ ] **Step 5: Commit** (no trailers, no attribution)

```bash
git add Common/UI/Settings/SwiftUI/SettingsLeafHost.swift Common/UI/Settings/SwiftUI/SettingsEnums.swift Common/UI/Settings/SwiftUI/SettingsSharedComponents.swift Common/UI/Settings/SwiftUI/GraphicsGeneralView.swift Common/UI/Settings/SwiftUI/PerformanceTuningView.swift DolphiniOSTests/SettingsSharedComponentsTests.swift
git commit -m "refactor(settings): leaf host, shared enums, moved caption helpers"
```

---

### Task 3: Graphics Hacks on the engine (the reference migration) and the shared row factory

Rulings that apply here (restated; you will not see the rest of the plan): **P8** keep the OLD gating rule for Skip Duplicate XFBs, `!immediateXfb && viSkipMode == 0`, and the texture-cache normalisation (a stored 64 must show "Default", not "—"); **P9** this task creates the shared `SettingsRow` factory that Tasks 4-6 use; **P10** no "nothing on build" tests (a pure builder cannot write); **P14** the host passes `onBack` (done by `SettingsLeafScreen` from Task 2) and the root pushes this leaf with pad Back; a covered root must not keep driving. Commits carry no trailers or attribution.

**Files:**
- Create: `UI/Settings/SwiftUI/Leaves/SettingsRowFactory.swift`
- Create: `UI/Settings/SwiftUI/Leaves/GraphicsHacksState.swift`, `GraphicsHacksModelBuilder.swift`, `GraphicsHacksView.swift`
- Modify: `UI/Settings/SwiftUI/SettingsSharedComponents.swift` (receives `struct MetalTriStatePicker`; grep for it in the old `GraphicsHacksView.swift`; `GraphicsAdvancedView` uses it)
- Delete: `UI/Settings/SwiftUI/GraphicsHacksView.swift`
- Test: create `DolphiniOSTests/SettingsRowFactoryTests.swift`, `DolphiniOSTests/GraphicsHacksModelBuilderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  /// The one place a settings row is turned into a MenuItem. Generic over the cycle value so
  /// Int, String and enum-valued settings all fit; helpers take a setter closure, not a Change type.
  enum SettingsRow {
    static func toggle(_ id: String, _ title: String, _ value: Bool, _ description: String,
                       enabled: Bool = true, badge: String? = nil, set: @escaping (Bool) -> Void) -> MenuItem
    static func cycle<V: Hashable>(_ id: String, _ title: String, _ options: [(String, V)], _ value: V, _ description: String,
                                   enabled: Bool = true, badge: String? = nil, set: @escaping (V) -> Void) -> MenuItem
    static func stepper(_ id: String, _ title: String, _ value: Double, range: ClosedRange<Double>, step: Double,
                        format: @escaping (Double) -> String, _ description: String,
                        enabled: Bool = true, badge: String? = nil, set: @escaping (Double) -> Void) -> MenuItem
    static func action(_ id: String, _ title: String, _ description: String, icon: String? = nil,
                       enabled: Bool = true, run: @escaping () -> Void) -> MenuItem
    static func destination(_ id: String, _ title: String, _ description: String, view: AnyView) -> MenuItem
  }
  struct GraphicsHacksState: Equatable { ...22 settings + backendSupportsBbox }
  enum GraphicsHacksChange: Equatable { case textureCacheSamples(Int), bboxEnabled(Bool), ... }
  enum GraphicsHacksModelBuilder {
    static func make(state: GraphicsHacksState, apply: @escaping (GraphicsHacksChange) -> Void) -> MenuModel
  }
  struct GraphicsHacksView: View   // same name as before, so the root keeps compiling
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// DolphiniOSTests/SettingsRowFactoryTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class SettingsRowFactoryTests: XCTestCase {
  func test_toggle_setReachesTheCallback_andDescriptionIsKept() {
    var received: [Bool] = []
    let item = SettingsRow.toggle("t", "Toggle", false, "Does a thing.") { received.append($0) }
    XCTAssertEqual(item.description, "Does a thing.")
    guard case .toggle(let binding) = item.role else { return XCTFail("toggle") }
    XCTAssertFalse(binding.wrappedValue)
    binding.wrappedValue = true
    XCTAssertEqual(received, [true])
  }

  func test_cycle_withIntValues_roundTripsThroughAnyHashable() {
    var received: [Int] = []
    let item = SettingsRow.cycle("c", "Cycle", [("Safe", 512), ("Default", 128)], 128, "d") { received.append($0) }
    XCTAssertEqual(item.currentValueTitle, "Default")
    guard case .cycle(_, let selection) = item.role else { return XCTFail("cycle") }
    selection.wrappedValue = AnyHashable(512)
    XCTAssertEqual(received, [512])
  }

  func test_cycle_withEnumValues_roundTrips() {
    var received: [GraphicsBackend] = []
    let item = SettingsRow.cycle("backend", "Backend", GraphicsBackend.allCases.map { ($0.label, $0) }, .metal, "d") { received.append($0) }
    XCTAssertEqual(item.currentValueTitle, GraphicsBackend.metal.label)
    guard case .cycle(_, let selection) = item.role else { return XCTFail("cycle") }
    selection.wrappedValue = AnyHashable(GraphicsBackend.vulkan)
    XCTAssertEqual(received, [.vulkan])
  }

  func test_cycle_aValueMatchingNoOption_showsADash() {
    let item = SettingsRow.cycle("c", "Cycle", [("A", 1), ("B", 2)], 99, "d") { _ in }
    XCTAssertEqual(item.currentValueTitle, "—", "spec §8: an unmatched value shows —, so builders must normalise first")
  }

  func test_cycle_ignoresAWrongTypedSelection() {
    var received: [Int] = []
    let item = SettingsRow.cycle("c", "Cycle", [("A", 1)], 1, "d") { received.append($0) }
    guard case .cycle(_, let selection) = item.role else { return XCTFail("cycle") }
    selection.wrappedValue = AnyHashable("not an int")
    XCTAssertTrue(received.isEmpty)
  }

  func test_stepper_formatsTheValue_andSetsThroughTheCallback() {
    var received: [Double] = []
    let item = SettingsRow.stepper("s", "Percent", 100, range: 1 ... 400, step: 1, format: { "\(Int($0))%" }, "d") { received.append($0) }
    XCTAssertEqual(item.currentValueTitle, "100%")
    guard case .stepper(let stepper) = item.role else { return XCTFail("stepper") }
    stepper.value.wrappedValue = 150
    XCTAssertEqual(received, [150])
  }

  func test_disabledAndBadge_areForwarded() {
    let item = SettingsRow.toggle("t", "T", true, "d", enabled: false, badge: "Auto") { _ in }
    XCTAssertFalse(item.isEnabled)
    XCTAssertEqual(item.badge, "Auto")
  }
}
```
```swift
// DolphiniOSTests/GraphicsHacksModelBuilderTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

final class GraphicsHacksModelBuilderTests: XCTestCase {
  private var changes: [GraphicsHacksChange] = []
  private func model(_ state: GraphicsHacksState = GraphicsHacksState()) -> MenuModel {
    GraphicsHacksModelBuilder.make(state: state) { self.changes.append($0) }
  }

  func test_rowOrder_matchesTheOldScreen() {
    XCTAssertEqual(model().allItems.map(\.id), [
      "texture-cache", "bbox", "bbox-sync", "efb-access", "skip-efb-ram", "skip-xfb-ram", "immediate-xfb",
      "copy-efb-scaled", "early-xfb", "skip-duplicate-xfb", "efb-format-changes", "vertex-rounding",
      "force-progressive", "defer-efb-copies", "vi-skip", "fast-texture-sampling", "fast-math",
      "compute-efb-xfb", "compute-vertex-decode", "no-mipmapping", "gpu-efb-peek", "vi-decimate-interlace",
    ])
  }

  func test_everyRow_hasADescription() {
    for item in model().allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
  }

  func test_toggle_emitsTheMatchingChange() {
    guard case .toggle(let binding)? = model().item(id: "efb-access")?.role else { return XCTFail("toggle") }
    binding.wrappedValue = true
    XCTAssertEqual(changes, [.efbAccess(true)])
  }

  func test_textureCache_offersSafeDefaultFast_andEmitsTheSampleCount() {
    guard case .cycle(let options, let selection)? = model().item(id: "texture-cache")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Safe", "Default", "Fast"])
    selection.wrappedValue = AnyHashable(512)
    XCTAssertEqual(changes, [.textureCacheSamples(512)])
  }

  func test_normalizedTextureCacheSamples_keepsSafeAndFast_mapsAnythingElseToDefault() {
    XCTAssertEqual(GraphicsHacksState.normalizedTextureCacheSamples(512), 512)
    XCTAssertEqual(GraphicsHacksState.normalizedTextureCacheSamples(0), 0)
    XCTAssertEqual(GraphicsHacksState.normalizedTextureCacheSamples(64), 128, "a stored 64 shows Default, not a dash")
    XCTAssertEqual(model(GraphicsHacksState(textureCacheSamples: 128)).item(id: "texture-cache")?.currentValueTitle, "Default")
  }

  func test_bboxRows_disabledWhenBackendLacksBbox() {
    var state = GraphicsHacksState()
    state.backendSupportsBbox = false
    let m = model(state)
    XCTAssertEqual(m.item(id: "bbox")?.isEnabled, false)
    XCTAssertEqual(m.item(id: "bbox-sync")?.isEnabled, false)
    XCTAssertTrue(m.item(id: "bbox")!.description!.contains("does not support"))
  }

  func test_bboxSync_disabledUntilBboxOn() {
    var state = GraphicsHacksState()
    state.bboxEnabled = false
    XCTAssertEqual(model(state).item(id: "bbox-sync")?.isEnabled, false)
    state.bboxEnabled = true
    XCTAssertEqual(model(state).item(id: "bbox-sync")?.isEnabled, true)
  }

  /// The OLD rule (`!immediateXfb && viSkipMode == 0`), probed at every VI Skip mode: only Off enables it, so
  /// the default state (Auto = 2) is disabled, exactly as the hand-built screen was.
  func test_skipDuplicateXfb_enabledOnlyWithViSkipOffAndNoImmediateXfb() {
    var state = GraphicsHacksState()
    state.immediateXfb = false
    for (mode, expected) in [(0, true), (1, false), (2, false)] {
      state.viSkipMode = mode
      XCTAssertEqual(model(state).item(id: "skip-duplicate-xfb")?.isEnabled, expected, "viSkipMode \(mode)")
    }
    state.viSkipMode = 0
    state.immediateXfb = true
    XCTAssertEqual(model(state).item(id: "skip-duplicate-xfb")?.isEnabled, false, "Immediate XFB disables it")
    XCTAssertEqual(GraphicsHacksState().viSkipMode, 2)
    XCTAssertEqual(model().item(id: "skip-duplicate-xfb")?.isEnabled, false, "the default state is disabled")
  }

  func test_deferEfbCopies_disabledWhenBothCopiesStayOnGPU() {
    var state = GraphicsHacksState()
    state.skipEfbToRam = true
    state.skipXfbToRam = true
    XCTAssertEqual(model(state).item(id: "defer-efb-copies")?.isEnabled, false)
    state.skipXfbToRam = false
    XCTAssertEqual(model(state).item(id: "defer-efb-copies")?.isEnabled, true)
  }
}
```
(`GraphicsHacksState(textureCacheSamples:)` needs the memberwise initialiser; keep the struct's properties `var` with defaults so it exists.)

- [ ] **Step 2: Regenerate (`cd Source/iOS/App && tuist generate --no-open`), run, verify failure.**

- [ ] **Step 3: The shared row factory**

```swift
// UI/Settings/SwiftUI/Leaves/SettingsRowFactory.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The one place a settings row becomes a `MenuItem`; Tasks 3-6 use it instead of nested helpers.
/// Rows never write anything themselves: `set` is the builder's `apply(.change(value))`.
enum SettingsRow {
  static func toggle(_ id: String, _ title: String, _ value: Bool, _ description: String,
                     enabled: Bool = true, badge: String? = nil, set: @escaping (Bool) -> Void) -> MenuItem {
    MenuItem(id: id, title: title, role: .toggle(Binding(get: { value }, set: set)),
             badge: badge, isEnabled: enabled, description: description)
  }

  static func cycle<V: Hashable>(_ id: String, _ title: String, _ options: [(String, V)], _ value: V, _ description: String,
                                 enabled: Bool = true, badge: String? = nil, set: @escaping (V) -> Void) -> MenuItem {
    MenuItem(id: id, title: title,
             role: .cycle(options: options.map { ($0.0, AnyHashable($0.1)) },
                          selection: Binding(get: { AnyHashable(value) }, set: { if let v = $0.base as? V { set(v) } })),
             badge: badge, isEnabled: enabled, description: description)
  }

  static func stepper(_ id: String, _ title: String, _ value: Double, range: ClosedRange<Double>, step: Double,
                      format: @escaping (Double) -> String, _ description: String,
                      enabled: Bool = true, badge: String? = nil, set: @escaping (Double) -> Void) -> MenuItem {
    MenuItem(id: id, title: title,
             role: .stepper(MenuStepper(value: Binding(get: { value }, set: set), range: range, step: step, format: format)),
             badge: badge, isEnabled: enabled, description: description)
  }

  static func action(_ id: String, _ title: String, _ description: String, icon: String? = nil,
                     enabled: Bool = true, run: @escaping () -> Void) -> MenuItem {
    MenuItem(id: id, title: title, icon: icon, role: .action(run), isEnabled: enabled, description: description)
  }

  static func destination(_ id: String, _ title: String, _ description: String, view: AnyView) -> MenuItem {
    MenuItem(id: id, title: title, role: .destination(view), description: description)
  }
}
```

- [ ] **Step 4: State and Change**

```swift
// UI/Settings/SwiftUI/Leaves/GraphicsHacksState.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Snapshot of Config for the Hacks screen. Defaults match the old view's `@State` defaults.
struct GraphicsHacksState: Equatable {
  var textureCacheSamples = 128
  var bboxEnabled = false
  var bboxSyncMode = 0
  var backendSupportsBbox = true
  var efbAccess = false
  var skipEfbToRam = true
  var skipXfbToRam = true
  var immediateXfb = false
  var copyEfbScaled = true
  var earlyXfbOutput = true
  var skipDuplicateXFBs = true
  var efbFormatChanges = false
  var vertexRounding = false
  var forceProgressive = true
  var deferEfbCopies = true
  var viSkipMode = 2
  var fastTextureSampling = true
  var fastMath = true
  var useComputeEfbXfb = false
  var useComputeVertexDecode = false
  var noMipmapping = false
  var gpuEfbPeekResolve = false
  var viDecimateInterlace = false

  /// The Safe/Default/Fast ladder: any stored value other than 512 or 0 shows as Default (128), never a dash.
  static func normalizedTextureCacheSamples(_ samples: Int) -> Int {
    switch samples {
    case 512, 0: return samples
    default: return 128
    }
  }
}

/// One user edit. The host applies it to its snapshot AND to Config; the builder only emits it.
enum GraphicsHacksChange: Equatable {
  case textureCacheSamples(Int)
  case bboxEnabled(Bool)
  case bboxSyncMode(Int)
  case efbAccess(Bool)
  case skipEfbToRam(Bool)
  case skipXfbToRam(Bool)
  case immediateXfb(Bool)
  case copyEfbScaled(Bool)
  case earlyXfbOutput(Bool)
  case skipDuplicateXFBs(Bool)
  case efbFormatChanges(Bool)
  case vertexRounding(Bool)
  case forceProgressive(Bool)
  case deferEfbCopies(Bool)
  case viSkipMode(Int)
  case fastTextureSampling(Bool)
  case fastMath(Bool)
  case useComputeEfbXfb(Bool)
  case useComputeVertexDecode(Bool)
  case noMipmapping(Bool)
  case gpuEfbPeekResolve(Bool)
  case viDecimateInterlace(Bool)
}
```

- [ ] **Step 5: Builder**

```swift
// UI/Settings/SwiftUI/Leaves/GraphicsHacksModelBuilder.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out (it cannot write). Descriptions are the captions the hand-built screen showed.
enum GraphicsHacksModelBuilder {
  static func make(state: GraphicsHacksState, apply: @escaping (GraphicsHacksChange) -> Void) -> MenuModel {
    let skipDuplicateEnabled = !state.immediateXfb && state.viSkipMode == 0
    let deferEfbEnabled = !(state.skipEfbToRam && state.skipXfbToRam)
    let bbox = state.backendSupportsBbox

    let general = MenuSection(id: "general-hacks", header: L("General Hacks"), items: [
      SettingsRow.cycle("texture-cache", L("Texture Cache Accuracy"), [(L("Safe"), 512), (L("Default"), 128), (L("Fast"), 0)], state.textureCacheSamples,
            L("Adjusts how strictly the GPU tracks texture updates from RAM. Safer is slower but avoids garbled text in some games."), set: { apply(.textureCacheSamples($0)) }),
      SettingsRow.toggle("bbox", L("Bounding Box Emulation"), state.bboxEnabled,
             bbox ? L("Emulates GameCube/Wii bounding-box tests on the GPU. Required by some games; leave off unless needed.")
                  : L("The current graphics backend does not support bounding box emulation on this device."),
             enabled: bbox, set: { apply(.bboxEnabled($0)) }),
      SettingsRow.cycle("bbox-sync", L("Bounding Box Sync"), [(L("Latched"), 0), (L("Force Sync"), 1)], state.bboxSyncMode,
            L("How iCube delivers bounding-box values. Latched serves a 1-frame-stale snapshot with no CPU stall (faster). Force Sync blocks for exact same-frame values — try it if a game's bbox-driven effects (some 2D/UI culling) look wrong."),
            enabled: state.bboxEnabled && bbox, set: { apply(.bboxSyncMode($0)) }),
      SettingsRow.toggle("efb-access", L("Enable EFB Access"), state.efbAccess,
             L("Lets the CPU read back the framebuffer. Required by some effects but costly; many games run fine and faster with it off."), set: { apply(.efbAccess($0)) }),
      SettingsRow.toggle("skip-efb-ram", L("Skip EFB Copy to RAM"), state.skipEfbToRam,
             L("Keeps embedded-framebuffer copies on the GPU instead of system RAM. Faster; breaks a few effects. Recommended on."), set: { apply(.skipEfbToRam($0)) }),
      SettingsRow.toggle("skip-xfb-ram", L("Skip XFB Copy to RAM"), state.skipXfbToRam,
             L("Keeps the external framebuffer on the GPU. Faster; can break games that read the final image."), set: { apply(.skipXfbToRam($0)) }),
      SettingsRow.toggle("immediate-xfb", L("Immediate XFB"), state.immediateXfb,
             L("Presents frames the moment they're drawn — lower latency, but can cause flicker or tearing in some games."), set: { apply(.immediateXfb($0)) }),
      SettingsRow.toggle("copy-efb-scaled", L("Copy EFB Scaled"), state.copyEfbScaled,
             L("Copies the framebuffer at the higher internal resolution rather than native. Keeps upscaled detail; recommended on."), set: { apply(.copyEfbScaled($0)) }),
      SettingsRow.toggle("early-xfb", L("Early XFB Output"), state.earlyXfbOutput,
             L("Outputs the frame earlier in the pipeline for lower latency. Recommended on; turn off if a game shows glitches."), set: { apply(.earlyXfbOutput($0)) }),
      SettingsRow.toggle("skip-duplicate-xfb", L("Skip Duplicate XFBs"), state.skipDuplicateXFBs,
             skipDuplicateEnabled ? L("Avoids re-presenting identical frames, saving GPU work. Recommended on.")
                                  : L("Unavailable while Immediate XFB or VI Skip is enabled — duplicate frames are already handled."),
             enabled: skipDuplicateEnabled, set: { apply(.skipDuplicateXFBs($0)) }),
      SettingsRow.toggle("efb-format-changes", L("Emulate EFB Format Changes"), state.efbFormatChanges,
             L("Emulates pixel-format changes some games rely on. Needed for correct colors/effects in those games; small cost."), set: { apply(.efbFormatChanges($0)) }),
      SettingsRow.toggle("vertex-rounding", L("Vertex Rounding"), state.vertexRounding,
             L("Rounds vertex positions to reduce seams between tiles at higher resolutions. Only helps above 1x; leave off at 1x."), set: { apply(.vertexRounding($0)) }),
      SettingsRow.toggle("force-progressive", L("Force Progressive Scan"), state.forceProgressive,
             L("Forces 480p output where games allow it, for a cleaner image."), set: { apply(.forceProgressive($0)) }),
      SettingsRow.toggle("defer-efb-copies", L("Defer EFB Copies"), state.deferEfbCopies,
             deferEfbEnabled ? L("Batches framebuffer copies to reduce overhead. Faster in most games; recommended on.")
                             : L("Unavailable while both EFB and XFB copies stay on the GPU — there is no RAM copy to defer."),
             enabled: deferEfbEnabled, set: { apply(.deferEfbCopies($0)) }),
      SettingsRow.cycle("vi-skip", L("VI Skip Mode"), [(L("Off"), 0), (L("On"), 1), (L("Auto"), 2)], state.viSkipMode,
            L("Skips video-interrupt frames to gain speed. Auto is the safe choice; On is more aggressive but can cause flicker."), set: { apply(.viSkipMode($0)) }),
      SettingsRow.toggle("fast-texture-sampling", L("Fast Texture Sampling"), state.fastTextureSampling,
             L("Uses faster, less precise texture sampling. Small speed win; rarely causes minor texture artifacts. Recommended on."), set: { apply(.fastTextureSampling($0)) }),
      SettingsRow.toggle("fast-math", L("Fast Math (Metal Shaders)"), state.fastMath,
             L("Lets Metal shaders use fast, relaxed-precision math. Can speed up the GPU; may cause subtle rendering differences."), set: { apply(.fastMath($0)) }),
      SettingsRow.toggle("compute-efb-xfb", L("Use Compute for EFB/XFB"), state.useComputeEfbXfb,
             L("Native-Metal compute acceleration for EFB/XFB. Experimental GPU perf knob; OFF by default. Applies on next launch."), set: { apply(.useComputeEfbXfb($0)) }),
      SettingsRow.toggle("compute-vertex-decode", L("Use Compute for Vertex Decode"), state.useComputeVertexDecode,
             L("Offload vertex decoding to a Metal compute shader (CPU→GPU). Experimental — currently only position-only-float formats use the GPU path (others fall back to CPU), so most games see little change yet. OFF by default. Applies on next launch."), set: { apply(.useComputeVertexDecode($0)) }),
      SettingsRow.toggle("no-mipmapping", L("No Mipmapping (iOS)"), state.noMipmapping,
             L("Disables mipmaps. Saves a little memory/bandwidth but makes distant textures shimmer. Leave off normally."), set: { apply(.noMipmapping($0)) }),
      SettingsRow.toggle("gpu-efb-peek", L("GPU EFB Peek Resolve"), state.gpuEfbPeekResolve,
             L("Experimental: resolves EFB peek reads on the GPU instead of a CPU readback. May reduce CPU-thread stalls for games that read the framebuffer; OFF by default. Verify visuals per game."), set: { apply(.gpuEfbPeekResolve($0)) }),
    ])
    let interlace = MenuSection(id: "interlace", items: [
      SettingsRow.toggle("vi-decimate-interlace", L("Interlaced Field Decimation"), state.viDecimateInterlace,
             L("Skips every other interlaced field for higher FPS. May reduce temporal resolution or cause flicker in some games."), set: { apply(.viDecimateInterlace($0)) }),
    ])
    return MenuModel(sections: [general, interlace])
  }
}
```
The gating expression for Skip Duplicate XFBs is `!state.immediateXfb && state.viSkipMode == 0`: it is the old view's `skipDuplicateXFBsEnabled`, and the test probes modes 0, 1 and 2. The Defer EFB Copies expression is the old `deferEfbCopiesEnabled`. Do not "improve" either.

- [ ] **Step 6: Host view**

```swift
// UI/Settings/SwiftUI/Leaves/GraphicsHacksView.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Hacks, on the menu engine. `sync()` reads Config into the snapshot and writes nothing; `apply(_:)` is the only writer.
struct GraphicsHacksView: View {
  @State private var state = GraphicsHacksState()

  var body: some View {
    SettingsLeafScreen(model: GraphicsHacksModelBuilder.make(state: state, apply: apply), title: L("Hacks"), sync: sync)
  }

  private func sync() {
    var s = GraphicsHacksState()
    s.textureCacheSamples = GraphicsHacksState.normalizedTextureCacheSamples(DOLConfigBridge.gfxSafeTextureCacheColorSamples())
    s.bboxEnabled = DOLConfigBridge.gfxHackBboxEnable()
    s.bboxSyncMode = DOLConfigBridge.gfxBboxSyncMode()
    s.backendSupportsBbox = DOLConfigBridge.gfxBackendSupportsBoundingBox()
    s.efbAccess = DOLConfigBridge.gfxHackEfbAccessEnable()
    s.skipEfbToRam = DOLConfigBridge.gfxHackSkipEfbCopyToRam()
    s.skipXfbToRam = DOLConfigBridge.gfxHackSkipXfbCopyToRam()
    s.immediateXfb = DOLConfigBridge.gfxHackImmediateXfb()
    s.copyEfbScaled = DOLConfigBridge.gfxHackCopyEfbScaled()
    s.earlyXfbOutput = DOLConfigBridge.gfxHackEarlyXfbOutput()
    s.skipDuplicateXFBs = DOLConfigBridge.gfxHackSkipDuplicateXFBs()
    s.efbFormatChanges = DOLConfigBridge.gfxHackEfbEmulateFormatChanges()
    s.vertexRounding = DOLConfigBridge.gfxHackVertexRounding()
    s.forceProgressive = DOLConfigBridge.gfxHackForceProgressive()
    s.deferEfbCopies = DOLConfigBridge.gfxHackDeferEfbCopies()
    s.viSkipMode = DOLConfigBridge.gfxHackViSkipMode()
    s.fastTextureSampling = DOLConfigBridge.gfxHackFastTextureSampling()
    s.fastMath = DOLConfigBridge.gfxHackFastMath()
    s.useComputeEfbXfb = DOLConfigBridge.gfxUseComputeEfbXfb()
    s.useComputeVertexDecode = DOLConfigBridge.gfxUseComputeVertexDecode()
    s.noMipmapping = DOLConfigBridge.gfxHackNoMipmapping()
    s.gpuEfbPeekResolve = DOLConfigBridge.gfxHackGpuEfbPeekResolve()
    s.viDecimateInterlace = DOLConfigBridge.gfxHackViDecimateInterlace()
    state = s
  }

  private func apply(_ change: GraphicsHacksChange) {
    switch change {
    case .textureCacheSamples(let v): state.textureCacheSamples = v; DOLConfigBridge.setGfxSafeTextureCacheColorSamples(v)
    case .bboxEnabled(let v): state.bboxEnabled = v; DOLConfigBridge.setGfxHackBboxEnable(v)
    case .bboxSyncMode(let v): state.bboxSyncMode = v; DOLConfigBridge.setGfxBboxSyncMode(v)
    case .efbAccess(let v): state.efbAccess = v; DOLConfigBridge.setGfxHackEfbAccessEnable(v)
    case .skipEfbToRam(let v): state.skipEfbToRam = v; DOLConfigBridge.setGfxHackSkipEfbCopyToRam(v)
    case .skipXfbToRam(let v): state.skipXfbToRam = v; DOLConfigBridge.setGfxHackSkipXfbCopyToRam(v)
    case .immediateXfb(let v): state.immediateXfb = v; DOLConfigBridge.setGfxHackImmediateXfb(v)
    case .copyEfbScaled(let v): state.copyEfbScaled = v; DOLConfigBridge.setGfxHackCopyEfbScaled(v)
    case .earlyXfbOutput(let v): state.earlyXfbOutput = v; DOLConfigBridge.setGfxHackEarlyXfbOutput(v)
    case .skipDuplicateXFBs(let v): state.skipDuplicateXFBs = v; DOLConfigBridge.setGfxHackSkipDuplicateXFBs(v)
    case .efbFormatChanges(let v): state.efbFormatChanges = v; DOLConfigBridge.setGfxHackEfbEmulateFormatChanges(v)
    case .vertexRounding(let v): state.vertexRounding = v; DOLConfigBridge.setGfxHackVertexRounding(v)
    case .forceProgressive(let v): state.forceProgressive = v; DOLConfigBridge.setGfxHackForceProgressive(v)
    case .deferEfbCopies(let v): state.deferEfbCopies = v; DOLConfigBridge.setGfxHackDeferEfbCopies(v)
    case .viSkipMode(let v): state.viSkipMode = v; DOLConfigBridge.setGfxHackViSkipMode(v)
    case .fastTextureSampling(let v): state.fastTextureSampling = v; DOLConfigBridge.setGfxHackFastTextureSampling(v)
    case .fastMath(let v): state.fastMath = v; DOLConfigBridge.setGfxHackFastMath(v)
    case .useComputeEfbXfb(let v): state.useComputeEfbXfb = v; DOLConfigBridge.setGfxUseComputeEfbXfb(v)
    case .useComputeVertexDecode(let v): state.useComputeVertexDecode = v; DOLConfigBridge.setGfxUseComputeVertexDecode(v)
    case .noMipmapping(let v): state.noMipmapping = v; DOLConfigBridge.setGfxHackNoMipmapping(v)
    case .gpuEfbPeekResolve(let v): state.gpuEfbPeekResolve = v; DOLConfigBridge.setGfxHackGpuEfbPeekResolve(v)
    case .viDecimateInterlace(let v): state.viDecimateInterlace = v; DOLConfigBridge.setGfxHackViDecimateInterlace(v)
    }
  }
}
```

- [ ] **Step 7: Delete the old file, move `MetalTriStatePicker`**

Copy `struct MetalTriStatePicker` (grep for it in the old `GraphicsHacksView.swift`) into `SettingsSharedComponents.swift` unchanged, then `git rm UI/Settings/SwiftUI/GraphicsHacksView.swift`. Build both platforms (commands below); run `SettingsRowFactoryTests` and `GraphicsHacksModelBuilderTests`.

```bash
cd Source/iOS/App
xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-ios
xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos
```

- [ ] **Step 8: Commit** (no trailers, no attribution)

```bash
git add Common/UI/Settings/SwiftUI/Leaves/SettingsRowFactory.swift Common/UI/Settings/SwiftUI/Leaves/GraphicsHacks*.swift Common/UI/Settings/SwiftUI/SettingsSharedComponents.swift DolphiniOSTests/SettingsRowFactoryTests.swift DolphiniOSTests/GraphicsHacksModelBuilderTests.swift
git rm Common/UI/Settings/SwiftUI/GraphicsHacksView.swift
git commit -m "feat(settings): Graphics Hacks on the menu engine, row factory"
```

---

### Task 4: Graphics Enhancements on the engine

Rulings that apply here (restated): **P9** build rows with `SettingsRow` (Task 3) instead of nested helpers; **P10** no "nothing on build" test, and the MSAA/EFB side effects are a pure, tested function; **P11** the arbitrary-mipmap threshold row stays HIDDEN while the feature is off, formatted `%.2f`, with the old range; **P14** the host is a `SettingsLeafScreen` (it passes `onBack`); **P5** the threshold is a `.stepper` row (tvOS left/right steps it, iOS shows a slider). Commits carry no trailers or attribution.

Shape: `GraphicsEnhancementsState`, `GraphicsEnhancementsChange`, `GraphicsEnhancementsModelBuilder.make(state:apply:)`, `GraphicsEnhancementsView` with `sync()`/`apply(_:)`, old file deleted.

**Files:**
- Create: `UI/Settings/SwiftUI/Leaves/GraphicsEnhancements{State,ModelBuilder,View}.swift`
- Delete: `UI/Settings/SwiftUI/GraphicsEnhancementsView.swift`
- Test: create `DolphiniOSTests/GraphicsEnhancementsModelBuilderTests.swift`

**State** (defaults from the old `@State`s): `anisotropy = 1`, `msaa = 1`, `ssaa = false`, `outputResampling = 0`, `trueColor = true`, `disableCopyFilter = true`, `efbScale = 1`, `efbMaxScale = 6`, `efbOverride: DOLConfigOverride = .none`, `widescreenHack = false`, `disableFog = false`, `arbitraryMipmapDetection = false`, `arbitraryMipmapThreshold = 0.5`, `hdrOutput = false`, `gpuTextureDecoding = false`. Plus `static func normalizedMsaa(_ samples: Int) -> Int` (the old `normalizedMsaa` ladder: `..<2 -> 1`, `2...3 -> 2`, `4...7 -> 4`, else 8; grep for it in the old view) so `sync()` and the tests share it.

**Change**: one case per setting the user can edit (`efbScale(Int)`, `anisotropy(Int)`, `msaa(Int)`, `ssaa(Bool)`, `outputResampling(Int)`, `trueColor(Bool)`, `disableCopyFilter(Bool)`, `widescreenHack(Bool)`, `hdrOutput(Bool)`, `gpuTextureDecoding(Bool)`, `disableFog(Bool)`, `arbitraryMipmapDetection(Bool)`, `arbitraryMipmapThreshold(Double)`).

**Rows, in the old order**, four sections with the old headers: `Internal Resolution`, `Texture Filtering`, `Enhancements`, `Compatibility` (grep the old file's `header: { Text(L(...)) }` closures to confirm). Every row's description is the old caption, verbatim:

| section | id | kind | options / range | enabled | badge | notes |
|---|---|---|---|---|---|---|
| Internal Resolution | `efb-scale` | cycle (Int) | `Auto (fit window)`(0), `1x (Native)`(1), then `2x`...`\(efbMaxScale)x` | `efbOverride == .none` | `ConfigOverrideBadge.title(for: efbOverride)` | label `Internal Resolution` |
| Texture Filtering | `anisotropy` | cycle (Int) | `1x, 2x, 4x, 8x, 16x` (values 1,2,4,8,16) | | | |
| | `msaa` | cycle (Int) | `None`(1), `2x`(2), `4x`(4), `8x`(8); title `Anti-Aliasing (MSAA)` (the search test relies on "MSAA" being in the title) | | | |
| | `ssaa` | toggle | | `msaa > 1` | | description switches on `msaa > 1` exactly as the old view's caption does |
| | `output-resampling` | cycle (Int) | `Default`(0), `Bilinear`(1), `B-Spline`(2), `Mitchell-Netravali`(3), `Catmull-Rom`(4), `Sharp Bilinear`(5), `Area Sampling`(6) | | | |
| Enhancements | `true-color` | toggle | | | | |
| | `disable-copy-filter` | toggle | | | | |
| | `widescreen-hack` | toggle | | | | |
| | `hdr-output` | toggle | | | | |
| | `gpu-texture-decoding` | toggle | | | | |
| Compatibility | `disable-fog` | toggle | | | | |
| | `arbitrary-mipmap` | toggle | | | | |
| | `arbitrary-mipmap-threshold` | stepper | `0 ... 30`, step `0.1`, format `String(format: "%.2f", $0)` (the old `Slider` is `in: 0.0 ... 30.0, step: 0.1` and the old label `%.2f`) | | | **omitted from the model** while `arbitraryMipmapDetection` is off (the old view hides it) |

**Side effects, as a pure function** (the old closures: picking an explicit EFB scale turns Auto-IR off; MSAA dropping to None clears SSAA). Put this in the State file:
```swift
/// What a change implies beyond writing its own key. Pure so the rules are tested; the host performs them.
enum GraphicsEnhancementsSideEffect: Equatable {
  /// Picking a fixed scale means the user wants that exact IR; Auto-IR also drives GFX_EFB_SCALE, so leaving it on makes the two fight.
  case autoIROff
  /// Desktop parity: SSAA only applies when MSAA > 1.
  case clearSSAA
}

extension GraphicsEnhancementsState {
  static func sideEffects(of change: GraphicsEnhancementsChange, in state: GraphicsEnhancementsState) -> [GraphicsEnhancementsSideEffect] {
    switch change {
    case .efbScale(let scale) where scale != 0: return [.autoIROff]
    case .msaa(let samples) where samples <= 1 && state.ssaa: return [.clearSSAA]
    default: return []
    }
  }
}
```
**Host `apply(_:)`**: compute `let effects = GraphicsEnhancementsState.sideEffects(of: change, in: state)` BEFORE mutating `state`, write the change's own key and snapshot field, then perform each effect: `.autoIROff` calls `DOLConfigBridge.setGfxAutoIREnable(false)`; `.clearSSAA` sets `state.ssaa = false` and calls `DOLConfigBridge.setGfxSsaa(false)`. `sync()` reads `efbScale` from `gfxEfbScaleBase()` and `efbOverride` from `efbScaleOverride()` (the user's own Base value, never an Auto-IR CurrentRun value), `msaa = GraphicsEnhancementsState.normalizedMsaa(DOLConfigBridge.gfxMsaa())`, and writes nothing.

The host body is `SettingsLeafScreen(model: GraphicsEnhancementsModelBuilder.make(state: state, apply: apply), title: L("Enhancements"), sync: sync)`; the threshold's write is `DOLConfigBridge.setGfxEnhanceArbitraryMipmapDetectionThreshold(Float(v))`. The old tvOS `TVIntStepper` for the threshold goes away with the old file.

**Tests** (`GraphicsEnhancementsModelBuilderTests`, same file shape as Task 3):
- `test_rowOrder_matchesTheOldScreen` for the default state (12 rows; the threshold absent) and `test_thresholdRow_appearsAfterDetection` (13 rows, ending `arbitrary-mipmap`, `arbitrary-mipmap-threshold`).
- `test_everyRow_hasADescription`.
- `test_efbScale_disabledAndBadgedGame_whenTheGameOverridesIt` (`efbOverride = .game` -> `isEnabled == false`, `badge == L("Game")`); same with `.auto` -> `L("Auto")`; with `.none` -> `badge == nil`.
- `test_efbScale_options_followEfbMaxScale` (`efbMaxScale = 4` -> titles `Auto (fit window)`, `1x (Native)`, `2x`, `3x`, `4x`).
- `test_ssaa_disabledWhileMsaaIsNone_andItsDescriptionSwitches`.
- `test_thresholdRow_isAStepperWithTheOldRangeAndFormat`: range `0 ... 30`, step `0.1`, `currentValueTitle == "0.50"` for the default.
- `test_msaaLadder_normalisesStoredSampleCounts` (`normalizedMsaa`: 0->1, 1->1, 3->2, 5->4, 16->8).
- Side effects, BOTH directions each: `.efbScale(0)` -> `[]`; `.efbScale(1)` and `.efbScale(4)` -> `[.autoIROff]`; `.msaa(1)` with `ssaa = true` -> `[.clearSSAA]`; `.msaa(1)` with `ssaa = false` -> `[]`; `.msaa(2)` with `ssaa = true` -> `[]`; `.ssaa(true)` -> `[]`; `.efbScale(2)` does not clear SSAA and `.msaa(1)` does not touch Auto-IR.

- [ ] **Step 1: Write the tests** as listed; regenerate (`cd Source/iOS/App && tuist generate --no-open`); run `GraphicsEnhancementsModelBuilderTests`, expect failure.
- [ ] **Step 2: State and Change (with `sideEffects` and `normalizedMsaa`), then the builder using `SettingsRow.cycle/toggle/stepper` (`set: { apply(.efbScale($0)) }` style), then the host view.**
- [ ] **Step 3: `git rm UI/Settings/SwiftUI/GraphicsEnhancementsView.swift`; run the tests, expect pass; build both platforms:**

```bash
cd Source/iOS/App
xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-ios
xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos
```
- [ ] **Step 4: Commit** (no trailers, no attribution)

```bash
git add Common/UI/Settings/SwiftUI/Leaves/GraphicsEnhancements*.swift DolphiniOSTests/GraphicsEnhancementsModelBuilderTests.swift
git rm Common/UI/Settings/SwiftUI/GraphicsEnhancementsView.swift
git commit -m "feat(settings): Graphics Enhancements on the menu engine"
```

---

### Task 5: Graphics General (Video) on the engine

Rulings that apply here (restated): **P9** build rows with `SettingsRow` (Task 3), generic over the cycle value (enum-valued cycles pass the enum itself); **P10** no "nothing on build" test; **P12** the state includes the two photo toggles, `tripleBuffering` defaults to TRUE when its key is unset, and `sync()` NEVER writes Config (the old `syncFromConfig` called `setGfxBackend`; that normalisation becomes display-only, so a stored invalid backend shows the normalised value without rewriting it); **P14** the host is a `SettingsLeafScreen` (it passes `onBack`). Commits carry no trailers or attribution.

**Files:**
- Create: `UI/Settings/SwiftUI/Leaves/GraphicsGeneral{State,ModelBuilder,View}.swift`
- Delete: `UI/Settings/SwiftUI/GraphicsGeneralView.swift` (its picker sub-views `GraphicsBackendPickerView`, `GraphicsAspectRatioView`, `GraphicsTargetFPSView`, `GraphicsMinScaleView`, `GraphicsMaxScaleView`, `GraphicsShaderTypeView` go with it; the enums already moved to `SettingsEnums.swift` in Task 2; grep that nothing else references the pickers)
- Test: create `DolphiniOSTests/GraphicsGeneralModelBuilderTests.swift`

**State**: `backend: GraphicsBackend = .metal`, `aspect: AspectRatio = .auto`, `vSync = false`, `showAutoIrOSD = false`, `tripleBuffering = true`, `forceScaleOneNonProMotion = false`, `overscanFullscreen = false`, `asyncPresent = false`, `autoIR = false`, `targetFPS: TargetFPS = .fps60`, `minScale: InternalScale = .x1_0`, `maxScale: InternalScale = .x2_0`, `frameCap = 0`, `instantReplay = false`, `saveClipsToPhotos = false`, `saveOnlyToPhotos = false`, `clipSeconds = 15`, `shaderType: ShaderCompileType = .specialized`, `compileBeforeStart = true`, plus `isIOS: Bool = true` (the builder omits the iOS-only rows when false; the host passes `true` under `#if os(iOS)`). The UserDefaults keys used by builder-adjacent code live in one `enum GraphicsGeneralDefaultsKey` in the State file: `backend = "ui_gfx_backend"`, `tripleBuffering = "gfx_triple_buffering"`, `forceScaleOne = "gfx_force_scale_one_non_promo"`, `overscanFullscreen = "gfx_overscan_fullscreen"`, `frameCap = "ui_frame_cap"`, `instantReplay = "replaykit_instant_replay_enabled"`, `saveToPhotos = "replaykit_save_to_photos"`, `saveOnlyPhotos = "replaykit_save_only_photos"`, `clipSeconds = "replaykit_clip_seconds"`.

**Change**: one case per editable setting, carrying the enum or primitive the old `onSet` closure received.

**Rows, in the old order**, three sections: the unnamed first section, `Recording` (iOS only), `Shader Compilation`. Every description is the old caption, verbatim (grep `captionRow(` and `settingsNavCaption(` in the old file):

| id | kind | options / notes |
|---|---|---|
| `backend` | cycle (`GraphicsBackend`) | `GraphicsBackend.allCases.map { ($0.label, $0) }`; apply writes `DOLConfigBridge.setGfxBackend(backendKey)` AND `UserDefaults ui_gfx_backend` |
| `aspect-ratio` | cycle (`AspectRatio`) | `AspectRatio.allCases` |
| `vsync` | toggle | |
| `auto-ir-osd` | toggle | |
| `triple-buffering` | toggle | UserDefaults `gfx_triple_buffering` |
| `force-scale-one` | toggle | UserDefaults `gfx_force_scale_one_non_promo` |
| `overscan-fullscreen` | toggle | `TVEmulationBridge.setOverscanFullscreenEnabled` |
| `async-present` | toggle | |
| `auto-ir` | toggle | |
| `target-fps` | cycle (`TargetFPS`) | `TargetFPS.allCases` |
| `min-scale` | cycle (`InternalScale`) | `InternalScale.allCases` |
| `max-scale` | cycle (`InternalScale`) | `InternalScale.allCases` |
| `frame-cap` | cycle (Int), iOS only | `System Default`(0), `30`, `60`, `90`, `120`; UserDefaults `ui_frame_cap` |
| `instant-replay` | toggle, iOS only | UserDefaults `replaykit_instant_replay_enabled` |
| `save-clips-photos` | toggle, iOS only | UserDefaults `replaykit_save_to_photos` |
| `save-only-photos` | toggle, iOS only | UserDefaults `replaykit_save_only_photos` |
| `clip-length` | cycle (Int), iOS only | `5s`(5), `10s`(10), `15s`(15), `30s`(30); UserDefaults `replaykit_clip_seconds` |
| `shader-compile-type` | cycle (`ShaderCompileType`) | `ShaderCompileType.allCases` |
| `compile-before-start` | toggle | |

The five iOS-only rows are `frame-cap` plus the four Recording rows; the Recording section is omitted entirely when `isIOS` is false.

**Host `sync()`** (assigns the snapshot, writes NOTHING): the effective backend key is `UserDefaults ui_gfx_backend` if non-empty, else `DOLConfigBridge.gfxBackend()`; `backend = GraphicsBackend.from(key:)`. **Do not call `setGfxBackend` there.** `tripleBuffering` is `UserDefaults.standard.object(forKey:) != nil ? bool(forKey:) : true`. The UserDefaults-backed iOS rows (`frameCap`, `instantReplay`, `saveClipsToPhotos`, `saveOnlyToPhotos`, `clipSeconds`) are read here too (the old view read them in `.onAppear`/live bindings); `clipSeconds` is `s > 0 ? s : 15`. Because they now live in the snapshot, `configSynced` + `SettingsLeafScreen` re-read them on appear and on foreground. The host body is `SettingsLeafScreen(model: GraphicsGeneralModelBuilder.make(state: state, apply: apply), title: L("General"), sync: sync)`.

**Tests** (`GraphicsGeneralModelBuilderTests`):
- `test_rowOrder_isIOS`: with `isIOS: true` the ids are exactly the 19 above in order; `test_rowOrder_notIOS`: with `isIOS: false` the five iOS-only ids are absent and the Recording section does not exist.
- `test_everyRow_hasADescription`.
- `test_backendCycle_listsEveryBackend_andEmitsTheEnum`: option titles equal `GraphicsBackend.allCases.map(\.label)`; selecting `.vulkan` emits `[.backend(.vulkan)]`.
- `test_vSync_toggleEmitsTheChange`: setting the `vsync` binding to true emits `[.vSync(true)]`.
- `test_scaleCycles_useTheInternalScaleLabels`.
- `test_tripleBuffering_defaultsOn`: `GraphicsGeneralState().tripleBuffering == true`.
- `test_photoToggles_reflectTheState`: `saveClipsToPhotos = true` -> the `save-clips-photos` toggle reads true.
- `test_clipLength_unmatchedValueIsNormalisedByTheHost`: document with a state test that `clipSeconds` defaults to 15, which matches an option (so the cycle never shows a dash).

- [ ] **Step 1: Write the tests**; regenerate (`cd Source/iOS/App && tuist generate --no-open`); run `GraphicsGeneralModelBuilderTests`, expect failure.
- [ ] **Step 2: State and Change, then the builder using `SettingsRow` (`set: { apply(.vSync($0)) }` style), then the host (`sync()` writes nothing; `apply(_:)` is the only writer).**
- [ ] **Step 3: `git rm UI/Settings/SwiftUI/GraphicsGeneralView.swift`; run the tests, expect pass; build both platforms:**

```bash
cd Source/iOS/App
xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-ios
xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos
```
- [ ] **Step 4: Commit** (no trailers, no attribution)

```bash
git add Common/UI/Settings/SwiftUI/Leaves/GraphicsGeneral*.swift DolphiniOSTests/GraphicsGeneralModelBuilderTests.swift
git rm Common/UI/Settings/SwiftUI/GraphicsGeneralView.swift
git commit -m "feat(settings): Video settings on the menu engine"
```

---

### Task 6: Performance Tuning on the engine

Rulings that apply here (restated): **P2** `CpuEngine` is internal (Task 2) and the badge title comes from `ConfigOverrideBadge.title(for:)`; **P9** build rows with `SettingsRow` (Task 3), cycle generic over `CpuEngine`; **P10** no "nothing on build" test; **P13** (a) no `openPerformanceAB` Change case: it is a navigation row; (b) keep the footers: they become `MenuSection.footer` (Task 1); (c) keep the fallback for non-CIR engines; (d) map JIT to Cached Interpreter in the engine cycle when JIT is unavailable; (e) read the vertex-loader key with default 1 when unset; (f) prefix duplicate-titled row ids; (g) `showValidation` is host `@State`, not part of the snapshot; **P14** the host is a `SettingsLeafScreen` (it passes `onBack`). Commits carry no trailers or attribution.

**Files:**
- Create: `UI/Settings/SwiftUI/Leaves/PerformanceTuning{State,ModelBuilder,View}.swift`
- Delete: `UI/Settings/SwiftUI/PerformanceTuningView.swift` (`CpuEnginePicker` and `RecommendedBadge` go with it; `PerformanceABView` is its own file and stays; `settingsCaption`/`settingsNavCaption`/`CpuEngine` already moved in Task 2)
- Test: create `DolphiniOSTests/PerformanceTuningModelBuilderTests.swift`

**State**: every `@State`/`@AppStorage` the old view declares (grep the `@State private var` / `@AppStorage` block at the top of `PerformanceTuningView`), same names and defaults, except: `showValidation` is NOT in the state; `adaptiveClock` and `vertexLoaderMode` are plain fields now. Plus `jitAvailable`, `cpuClockOverride`, `vbiOverride`, and `engine: CpuEngine`. Derived (computed on the state, with the old view's expressions: `effectiveEngine`, `showCIROpts`, `showIROpts`, `showEngineOpts`):
```swift
var effectiveEngine: CpuEngine {
  if !jitAvailable && (engine == .jit64 || engine == .jitARM64) { return .cachedInterpreter }
  return engine
}
var showCIROpts: Bool { effectiveEngine == .cachedInterpreter }
var showIROpts: Bool { effectiveEngine == .cachedInterpreterIR }
var showEngineOpts: Bool { showCIROpts || showIROpts }
```
UserDefaults keys in one `enum PerformanceTuningDefaultsKey` (`adaptiveClock = "adaptive_clock_enable"`, `vertexLoaderMode = "icube_vertex_loader_mode"`, `cirProfile = "icube.cirProfile"`); `PerformanceABView` may keep its own copies. **Vertex loader default (P13e):** `@AppStorage` supplied a default of 1; raw `UserDefaults.integer(forKey:)` on an unset key returns 0 = Software, and `DefaultPreferences.plist` has no entry. So `sync()` reads `UserDefaults.standard.object(forKey: key) == nil ? 1 : integer(forKey: key)`, and the state default is 1.

**Change**: do not write ~45 hand-named cases. Use `PerformanceTuningFlag` (one case per `Bool` setting, named like the old `@State` var: `mmu`, `pauseOnPanic`, `writeBackCache`, `disableICache`, `lowDCBZ`, `cachedInterpreterPrefetch`, `neonTextureDecode`, `relaxedIdleDetection`, `fastForwardCtrIdle`, `syncOnSkipIdle`, `adaptiveClock`, `cpuClockEnabled`, `vbiEnabled`, `cirProfile`, and every `cir*` / `cirIr*` flag and its `*Validate` twin) with `var keyPath: WritableKeyPath<PerformanceTuningState, Bool>`; and
```swift
enum PerformanceTuningChange: Equatable {
  case flag(PerformanceTuningFlag, Bool)
  case cpuEngine(CpuEngine)
  case vertexLoaderMode(Int)
  case cpuClockPercent(Int)
  case vbiPercent(Int)
  case showValidation(Bool)            // host @State only, never Config
  case resetOptimizationsToRecommended
}
```
(No `openPerformanceAB` case.) The host's `apply(_:)` has one `switch flag` that mirrors the old closures one-to-one (`.mmu` -> `DOLConfigBridge.setMainMMU`, `.cirPicLoadStore` -> `setCirPicLoadStore`, and so on, copied from the old `set:`/`onSet` arguments), after assigning `state[keyPath: flag.keyPath] = value`. `.cirProfile` and `.adaptiveClock` write UserDefaults; `.resetOptimizationsToRecommended` calls `DOLConfigBridge.resetCirOptimizationsToDefaults()` then `sync()`.

**Builder**: `PerformanceTuningModelBuilder.make(state:showValidation:apply:) -> MenuModel` (`showValidation` is a parameter, not state; search calls it with `true` so the validators are searchable).

**Sections and rows, in the old order:**
1. `cpu-options`, header `CPU Options`, `footer` = the old footer text, switching on `state.jitAvailable` (both strings are in the old view's first `Section(header:footer:)`). Rows: `cpu-engine` (cycle over `CpuEngine`; options are `CpuEngine.allCases` when JIT is available, else `[.interpreter, .cachedInterpreter, .cachedInterpreterIR]`; the cycle's VALUE is `state.effectiveEngine` so a stored JIT core on a jitless build shows Cached Interpreter, not a dash; title `CPU Emulation Engine`; description: the old picker footer, the jitAvailable variant), `mmu`, `adaptive-clock`, `vertex-loader` (cycle: `Software`(0), `NEON SIMD (default)`(1), `Compare (validate)`(2)), `pause-on-panic`, `accurate-cpu-cache`, `bypass-icache`, `ci-prefetch`, `neon-texture-decode`, `dcbz-hack`, `relaxed-idle`, `ff-ctr-idle`, `sync-on-skip-idle`.
2. When `state.showEngineOpts`: `engine-optimizations`, header `Engine Optimizations`, `footer` = the old `engineOptsFooter` text (IR variant when `showIROpts`). Rows: `performance-ab` (`SettingsRow.destination(..., view: AnyView(PerformanceABView()))`, description = the old `settingsNavCaption` text, title `Performance A/B & Snapshots`), `reset-optimizations` (`SettingsRow.action`, title `Reset Optimizations to Recommended`, emits `.resetOptimizationsToRecommended`), then the `optRow`s in the old order. **Otherwise (P13c)** a `engine-optimizations-hint` section with the same header and ONE disabled row `engine-optimizations-hint` (title `Select a Cached Interpreter engine`, description the old fallback text: "Select Cached Interpreter or Cached Interpreter (IR) as the CPU engine above to configure optimizations. The plain Interpreter and JIT engines don't use these.").
   - A row for a `recommended: true` optimisation gets `badge: L("Recommended")` (the old green capsule is lost; accepted) and keeps its description.
   - **Row ids (P13f).** Titles repeat across the two engine groups (`Micro-Op Fusion`, `Specialized Ops: Validate`). Rule: rows shared by both engines (PIC Load/Store, Specialized Ops, Block Linking, Dynamic Links, NEON Paired-Single Math) use the bare kebab of the title (`pic-load-store`, `specialized-ops`, `block-linking`, `dynamic-links`, `neon-paired-single-math`); rows inside the old `if showCIROpts` get `cir-` (`cir-micro-op-fusion`, `cir-dead-flag-elimination`...); rows inside `if showIROpts` get `ir-` (`ir-micro-op-fusion`, `ir-constant-address-fusion`...); validate rows add `validate-` after the prefix (`validate-neon-paired-single-math`, `cir-validate-specialized-ops`, `ir-validate-specialized-ops`).
3. When `state.showEngineOpts` (the old file nests Validation inside the engine options): `validation`, header `Correctness Validation (developer, slow)`: first row `show-validation` is a `.toggle` on the `showValidation` parameter (replaces the manual collapsible button) emitting `.showValidation`; the `validateRow`s follow only when `showValidation`, each `enabled: parentOn` with the old parent mapping (grep `validateRow(` for each `parentOn:`).
4. When `state.showCIROpts` (the profiler is a Cached Interpreter feature in the old file): `diagnostics`, header `Diagnostics`: `cir-profiler` toggle on `cirProfile`.
5. `clock-override`, header `Clock Override`: `cpu-clock-enabled` toggle (`enabled: cpuClockOverride == .none`), `cpu-clock-percent` stepper (`SettingsRow.stepper`, range `PerformanceTuningLimits.clockPercentRange` (declare `enum PerformanceTuningLimits { static let clockPercentRange: ClosedRange<Double> = 1 ... 400 }` in the State file), step 1, format `"\(Int($0))%"`, `enabled: cpuClockEnabled && cpuClockOverride == .none`, `badge: ConfigOverrideBadge.title(for: cpuClockOverride)`).
6. `vbi-override`, header `Override VBI Frequency`: `vbi-enabled`, `vbi-percent`, same shape with `vbiOverride`.

**Host**: `@State private var state = PerformanceTuningState()` and `@State private var showValidation = false`. `sync()` mirrors the old `syncPerformanceTuning()` (`jitAvailable = JitManager.shared().acquiredJit`, the clock fields from the `*Base()` getters, the overrides from `overclockOverride()`/`viOverclockOverride()`), assigns the snapshot and writes nothing. `showValidation` survives `DOLConfigChanged` resyncs because it lives outside the snapshot. The body is `SettingsLeafScreen(model: PerformanceTuningModelBuilder.make(state: state, showValidation: showValidation, apply: apply), title: L("Performance Tuning"), sync: sync)`.

**Tests** (`PerformanceTuningModelBuilderTests`; helper `model(_ state:, showValidation: Bool = false)`):
- `test_sections_inOrder_forACachedInterpreter`: `jitAvailable = true`, `engine = .cachedInterpreter` -> `["cpu-options", "engine-optimizations", "validation", "diagnostics", "clock-override", "vbi-override"]`.
- `test_engineOptimizations_absent_andFallbackShown_forTheJITEngine`: `engine = .jitARM64`, `jitAvailable = true` -> no `engine-optimizations`, no `validation`, no `diagnostics`; an `engine-optimizations-hint` row exists and is disabled. For `.cachedInterpreter` the hint is absent.
- `test_irEngine_showsIRRows_notCIRRows_andNoDiagnostics`.
- `test_engineCycle_showsCachedInterpreter_whenJITIsUnavailable`: `jitAvailable = false`, `engine = .jitARM64` -> `item(id: "cpu-engine")?.currentValueTitle == CpuEngine.cachedInterpreter.label`, and the options exclude the JIT engines.
- `test_cpuClockPercent_disabledAndBadgedAuto_whenAdaptiveClockDrivesIt`: `cpuClockOverride = .auto` -> both clock rows disabled, `badge == L("Auto")`.
- `test_cpuClockPercent_isAStepper_1to400`.
- `test_validateRows_absentUntilShown_andDisabledUntilTheirParentIsOn`: with `showValidation: false` no `*validate*` ids; with `true`, `cir-validate-specialized-ops` is disabled until `cirSpecializedOps`... use two pairs (`cir-validate-specialized-ops` needs `cirSpecializedOps`; `cir-validate-micro-op-fusion` needs `cirMicroOpFusion`) and check them enabled when the parent is on.
- `test_rowIds_areUnique_inEveryEngineState`: build the model for CIR and IR with `showValidation: true` and assert `Set(ids).count == ids.count`.
- `test_resetOptimizations_emitsItsChange`: activate the `reset-optimizations` action row -> `[.resetOptimizationsToRecommended]`.
- `test_showValidationToggle_emitsShowValidation_notAFlag`.
- `test_everyRow_hasADescription`.
- `test_vertexLoaderDefault_isNEON`: `PerformanceTuningState().vertexLoaderMode == 1` and the cycle shows `NEON SIMD (default)`.

- [ ] **Step 1: Write the tests**; regenerate (`cd Source/iOS/App && tuist generate --no-open`); run `PerformanceTuningModelBuilderTests`, expect failure.
- [ ] **Step 2: State, Flag, Change, builder, host.**
- [ ] **Step 3: `git rm UI/Settings/SwiftUI/PerformanceTuningView.swift`; run the tests, expect pass; build both platforms:**

```bash
cd Source/iOS/App
xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-ios
xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos
```
- [ ] **Step 4: Commit** (no trailers, no attribution)

```bash
git add Common/UI/Settings/SwiftUI/Leaves/PerformanceTuning*.swift DolphiniOSTests/PerformanceTuningModelBuilderTests.swift
git rm Common/UI/Settings/SwiftUI/PerformanceTuningView.swift
git commit -m "feat(settings): Performance Tuning on the menu engine"
```

---

### Task 7: Root model, generated search, sidebar shell

Rulings that apply here (restated; you will not see the rest of the plan):
- **P3** the root builder references `ConfigAchievementsView` only under `#if USE_RETRO_ACHIEVEMENTS`.
- **P14** every `MenuScreen` host passes `onBack { dismiss() }`; every PUSHED unmigrated leaf gets `.padBackNavigation()` (not a view that hosts its own `MenuScreen`: `ControllersRootView` embeds `ControllerHubView`, so it is excluded; grep each other unmigrated leaf for `MenuScreen(`/`ControllerHubView` before wrapping); a covered root `MenuScreen` stops consuming pad input while a leaf is pushed (the pushed leaf's own controller scope sits above it in `ControllerFocusCoordinator`'s LIFO stack, which is why every pushed leaf must claim one).
- **P15** deleting `TVSettingsPage` must not trap the user on tvOS: the shell handles the exit command, and the opening press goes through `BackCoalescer` like the PR 2 pause menu.
- **P16** the sidebar shell is used on tvOS and iPad at regular width only; iPhone is always the grouped list; the shell has search (iPad), a Reset All destructive row in About (the alert is one shared view), and honours `jumpToControllersRequested` by selecting the Controllers leaf.
- **P17** root rows stay `.action` + `makeView` and show a navigation chevron (`MenuItem.showsChevron`, Task 1).
- **P18** `Hashable` where `navigationDestination`/`List` need it; rename the model-order test to what it checks; a search-index test covering every root row title; the index is built ONCE per Settings appearance, not per keystroke; no hand-kept keywords for migrated leaves; do not duplicate Version/Core in About (`AboutView` already shows them; only Blog and Help move); the iCloud row's `SyncStatusIndicator` is DROPPED (`MenuItem` has no trailing-accessory slot; ledger it in the PR body); iPad sidebar width 240; magic sizes are named constants.
- **P19** `WebUISettingsView` keeps Safari/context-menu bits behind `#if os(iOS)`; tvOS shows the URLs as text rows.
- **P21** `SettingsRootViewController.swift` already calls `SettingsRootView()` and needs no change (do not touch or `git add` it). Stale line numbers in this plan are pointers: grep for the symbol.
- Commits carry no trailers or attribution.

**Files:**
- Create: `UI/Settings/SwiftUI/SettingsRootModelBuilder.swift`, `SettingsSearchIndex.swift`, `SettingsSidebarShell.swift`, `WebUISettingsView.swift`
- Modify: `UI/Settings/SwiftUI/SettingsRootView.swift`, `AboutView.swift`, `SettingsSharedComponents.swift` (add `SettingsResetAllButton`)
- Delete: `Common/Swift/TVSettingsPage.swift`. Update its callers (grep `TVSettingsPage(`): `Common/Swift/TVLibraryView.swift` (an iOS `navigationDestinationItemCompat` push and a tvOS `.fullScreenCover`) and `Common/Swift/EmulationScreen.swift` (a tvOS `.fullScreenCover`, which also has its own `.onExitCommand { showSettings = false }` and a comment mentioning `TVSettingsPage`: delete both, the shell owns Menu now). Also update the doc comment in `Common/Services/WebServerLifecycleService.swift` that names `TVSettingsPage`. `PauseMenuView` and `EmulationScreen` already present `SettingsRootView()` directly and compile unchanged.
- Test: create `DolphiniOSTests/SettingsRootModelBuilderTests.swift`, `DolphiniOSTests/SettingsSearchIndexTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct SettingsLeafEntry: Identifiable, Hashable {     // Hashable by id (navigationDestination(item:))
    let id: String            // e.g. "graphics-hacks"
    let title: String
    let icon: String
    let description: String
    let keywords: [String]    // hand-built leaves only
    let hostsMenuScreen: Bool // true: migrated leaves and ControllersRootView; they handle pad Back themselves
    let makeView: () -> AnyView          // the raw leaf: what the sidebar pane shows
    let makeModel: (() -> MenuModel)?    // migrated leaves only: their rows, for search
    func pushedView() -> AnyView         // makeView(), plus .padBackNavigation() unless hostsMenuScreen
  }
  struct SettingsRootSection: Identifiable { let id: String; let header: String; let entries: [SettingsLeafEntry] }
  enum SettingsRootModelBuilder {
    static func sections(isIOS: Bool, achievements: Bool) -> [SettingsRootSection]
    static func model(sections: [SettingsRootSection], onSelect: @escaping (SettingsLeafEntry) -> Void) -> MenuModel
  }
  struct SettingsSearchHit: Hashable { let entryID: String; let rowTitle: String? }
  /// A value: built once per Settings appearance (it walks every migrated leaf's model), then queried per keystroke.
  struct SettingsSearchIndex {
    init(sections: [SettingsRootSection])
    func hits(query: String) -> [SettingsSearchHit]
  }
  struct SettingsResetAllButton<Label: View>: View { init(role: ButtonRole? = nil, @ViewBuilder label: () -> Label) }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// DolphiniOSTests/SettingsRootModelBuilderTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class SettingsRootModelBuilderTests: XCTestCase {
  func test_sections_inSpecOrder() {
    let sections = SettingsRootModelBuilder.sections(isIOS: true, achievements: true)
    XCTAssertEqual(sections.map(\.id), ["general", "graphics", "audio", "consoles", "controllers", "performance", "sync-network", "about"])
  }

  func test_everyEntry_hasDescriptionAndUniqueID() {
    let entries = SettingsRootModelBuilder.sections(isIOS: true, achievements: true).flatMap(\.entries)
    XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
    for entry in entries { XCTAssertFalse(entry.description.isEmpty, entry.id) }
  }

  func test_migratedLeaves_exposeTheirModels() {
    let entries = SettingsRootModelBuilder.sections(isIOS: true, achievements: true).flatMap(\.entries)
    for id in ["graphics-hacks", "graphics-enhancements", "graphics-video", "performance-tuning"] {
      XCTAssertNotNil(entries.first { $0.id == id }?.makeModel, id)
    }
    XCTAssertNil(entries.first { $0.id == "debug" }?.makeModel, "a hand-built leaf has no model")
  }

  func test_model_hasOneChevronActionRowPerEntry_inSectionOrder() {
    let sections = SettingsRootModelBuilder.sections(isIOS: false, achievements: false)
    let model = SettingsRootModelBuilder.model(sections: sections, onSelect: { _ in })
    XCTAssertEqual(model.sections.map(\.id), sections.map(\.id))
    XCTAssertEqual(model.allItems.map(\.id), sections.flatMap(\.entries).map(\.id))
    for item in model.allItems {
      XCTAssertTrue(item.showsChevron, item.id)
      guard case .action = item.role else { XCTFail("\(item.id) should be an .action row"); continue }
    }
  }

  func test_selectingARow_reportsItsEntry() {
    var selected: [String] = []
    let sections = SettingsRootModelBuilder.sections(isIOS: true, achievements: false)
    let model = SettingsRootModelBuilder.model(sections: sections, onSelect: { selected.append($0.id) })
    guard case .action(let run)? = model.item(id: "graphics-hacks")?.role else { return XCTFail("action") }
    run()
    XCTAssertEqual(selected, ["graphics-hacks"])
  }
}
```
```swift
// DolphiniOSTests/SettingsSearchIndexTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class SettingsSearchIndexTests: XCTestCase {
  private let sections = SettingsRootModelBuilder.sections(isIOS: true, achievements: true)
  private lazy var index = SettingsSearchIndex(sections: sections)

  /// Spec §9: search covers every root row title.
  func test_everyRootRowTitle_isFound() {
    for entry in sections.flatMap(\.entries) {
      XCTAssertTrue(index.hits(query: entry.title).contains(SettingsSearchHit(entryID: entry.id, rowTitle: nil)), entry.title)
    }
  }

  func test_leafRowTitle_matches_withTheRowNamed() {
    let hits = index.hits(query: "v-sync")
    XCTAssertTrue(hits.contains { $0.entryID == "graphics-video" && $0.rowTitle == "V-Sync" })
  }

  /// Migrated leaves are found through their generated row titles, not hand-kept keywords.
  func test_migratedLeafRows_areFoundByTheirOwnTitles() {
    XCTAssertTrue(index.hits(query: "msaa").contains { $0.entryID == "graphics-enhancements" && ($0.rowTitle ?? "").contains("MSAA") })
    XCTAssertTrue(index.hits(query: "texture cache").contains { $0.entryID == "graphics-hacks" })
    XCTAssertTrue(index.hits(query: "adaptive clock").contains { $0.entryID == "performance-tuning" })
  }

  func test_validatorRows_areSearchable() {
    XCTAssertTrue(index.hits(query: "Validate").contains { $0.entryID == "performance-tuning" })
  }

  /// A hand-built leaf has no model, so its keywords still count.
  func test_keyword_matchesAHandBuiltLeaf() {
    XCTAssertTrue(index.hits(query: "fastmem").contains(SettingsSearchHit(entryID: "debug", rowTitle: nil)))
  }

  func test_emptyQuery_hasNoHits() {
    XCTAssertTrue(index.hits(query: "  ").isEmpty)
  }
}
```
(`private lazy var` in an XCTestCase is fine; if the compiler objects, build `index` inside each test.)

- [ ] **Step 2: Regenerate (`cd Source/iOS/App && tuist generate --no-open`), run, verify failure.**

- [ ] **Step 3: Root builder** (`SettingsRootModelBuilder.swift`)

```swift
// UI/Settings/SwiftUI/SettingsRootModelBuilder.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct SettingsLeafEntry: Identifiable, Hashable {
  let id: String
  let title: String
  let icon: String
  let description: String
  let keywords: [String]
  let hostsMenuScreen: Bool
  let makeView: () -> AnyView
  let makeModel: (() -> MenuModel)?

  init(id: String, title: String, icon: String, description: String, keywords: [String] = [],
       hostsMenuScreen: Bool = false, makeModel: (() -> MenuModel)? = nil,
       @ViewBuilder view: @escaping () -> some View) {
    self.id = id
    self.title = title
    self.icon = icon
    self.description = description
    self.keywords = keywords
    self.hostsMenuScreen = hostsMenuScreen
    self.makeModel = makeModel
    self.makeView = { AnyView(view()) }
  }

  /// What iPhone push and search results show. A leaf that is not itself a `MenuScreen` has no pad Back,
  /// so a pad that pushed it could never leave it (see `PadBackNavigation`).
  func pushedView() -> AnyView {
    hostsMenuScreen ? makeView() : AnyView(makeView().padBackNavigation())
  }

  static func == (lhs: SettingsLeafEntry, rhs: SettingsLeafEntry) -> Bool { lhs.id == rhs.id }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct SettingsRootSection: Identifiable {
  let id: String
  let header: String
  let entries: [SettingsLeafEntry]
}

/// Spec §6.2: eight sections. Every leaf is one row; migrated leaves also expose their model so search
/// can see their rows. `isIOS`/`achievements` replace the `#if`s the old root had.
enum SettingsRootModelBuilder {
  static func sections(isIOS: Bool, achievements: Bool) -> [SettingsRootSection] {
    var consoles = [
      SettingsLeafEntry(id: "console-gamecube", title: L("GameCube"), icon: "cube", description: L("Memory cards, slots and GameCube-only options.")) { ConfigGameCubeView() },
      SettingsLeafEntry(id: "console-wii", title: L("Wii"), icon: "tv.and.hifispeaker.fill", description: L("System language, aspect, SD card and Wii-only options.")) { ConfigWiiView() },
    ]
    // ConfigAchievementsView only exists under this flag; the `achievements` argument alone would not compile without it.
    #if USE_RETRO_ACHIEVEMENTS
    if achievements {
      consoles.append(SettingsLeafEntry(id: "achievements", title: L("Achievements"), icon: "trophy", description: L("RetroAchievements sign-in and hardcore mode.")) { ConfigAchievementsView() })
    }
    #endif
    return [
      SettingsRootSection(id: "general", header: L("General"), entries: [
        SettingsLeafEntry(id: "general", title: L("General"), icon: "gear", description: L("Dual core, cheats, speed limit and other core options.")) { ConfigGeneralView() },
        SettingsLeafEntry(id: "interface", title: L("Interface"), icon: "menubar.rectangle", description: L("On-screen messages, confirmations and panic handling.")) { ConfigInterfaceView() },
        SettingsLeafEntry(id: "advanced", title: L("Advanced"), icon: "cpu", description: L("Clock overrides and other expert options.")) { ConfigAdvancedView() },
      ]),
      SettingsRootSection(id: "graphics", header: L("Graphics"), entries: [
        SettingsLeafEntry(id: "graphics-video", title: L("Video"), icon: "display",
                          description: L("Backend, aspect ratio, V-Sync, auto resolution and shader compilation."),
                          hostsMenuScreen: true,
                          makeModel: { GraphicsGeneralModelBuilder.make(state: GraphicsGeneralState(isIOS: isIOS), apply: { _ in }) }) { GraphicsGeneralView() },
        SettingsLeafEntry(id: "graphics-enhancements", title: L("Enhancements"), icon: "sparkles",
                          description: L("Internal resolution, anti-aliasing, filtering and colour."),
                          hostsMenuScreen: true,
                          makeModel: { GraphicsEnhancementsModelBuilder.make(state: GraphicsEnhancementsState(), apply: { _ in }) }) { GraphicsEnhancementsView() },
        SettingsLeafEntry(id: "graphics-hacks", title: L("Hacks"), icon: "wrench.and.screwdriver",
                          description: L("Speed-for-accuracy trade-offs in the GPU pipeline."),
                          hostsMenuScreen: true,
                          makeModel: { GraphicsHacksModelBuilder.make(state: GraphicsHacksState(), apply: { _ in }) }) { GraphicsHacksView() },
        SettingsLeafEntry(id: "graphics-advanced", title: L("Graphics Advanced"), icon: "slider.horizontal.3",
                          description: L("Metal presentation and buffer upload options."),
                          keywords: ["present drawable", "manually upload buffers", "metal"]) { GraphicsAdvancedView() },
        SettingsLeafEntry(id: "shaders", title: L("Shaders"), icon: "paintbrush", description: L("Post-processing presets and their parameters.")) { ShaderSettingsView() },
      ]),
      SettingsRootSection(id: "audio", header: L("Audio"), entries: [
        SettingsLeafEntry(id: "audio", title: L("Audio"), icon: "speaker.wave.3", description: L("Volume, DSP engine, stretching and effects.")) { ConfigAudioView() },
      ]),
      SettingsRootSection(id: "consoles", header: L("GameCube & Wii"), entries: consoles),
      SettingsRootSection(id: "controllers", header: L("Controllers"), entries: [
        // ControllersRootView embeds ControllerHubView (a MenuScreen), so it handles pad Back itself.
        SettingsLeafEntry(id: "controllers", title: L("Controllers"), icon: "gamecontroller",
                          description: L("Players, devices, what each plays as, and remapping."),
                          hostsMenuScreen: true) { ControllersRootView() },
      ]),
      SettingsRootSection(id: "performance", header: L("Performance"), entries: [
        SettingsLeafEntry(id: "performance-tuning", title: L("Performance Tuning"), icon: "gauge.with.dots.needle.67percent",
                          description: L("CPU engine, optimisations, clock overrides. The CPU is the bottleneck on iCube."),
                          hostsMenuScreen: true,
                          // showValidation: true so the correctness-validation rows are searchable.
                          makeModel: { PerformanceTuningModelBuilder.make(state: PerformanceTuningState(), showValidation: true, apply: { _ in }) }) { PerformanceTuningView() },
        SettingsLeafEntry(id: "debug", title: L("Debug"), icon: "ladybug", description: L("Developer switches: fastmem, JIT, logging, stall metrics."),
                          keywords: ["fastmem", "jit", "logging", "stall metrics", "wireframe", "haptics"]) { DebugRootView() },
      ]),
      SettingsRootSection(id: "sync-network", header: L("Sync & Network"), entries: [
        SettingsLeafEntry(id: "web-ui", title: L("Web UI & WebDAV"), icon: "network", description: L("Import games from a computer on the same Wi-Fi.")) { WebUISettingsView() },
        SettingsLeafEntry(id: "icloud", title: L("iCloud Sync"), icon: "icloud", description: L("Sync saves, states and settings across your devices.")) { CloudSyncSettingsView() },
        SettingsLeafEntry(id: "nearby", title: L("Nearby Devices"), icon: "antenna.radiowaves.left.and.right", description: L("Continue a game from another device, and manage paired ones.")) { ContinuityBrowseView() },
      ]),
      SettingsRootSection(id: "about", header: L("About"), entries: [
        SettingsLeafEntry(id: "about", title: L("About"), icon: "info.circle", description: L("Version, core, blog, help and Reset All Settings.")) { AboutView() },
      ]),
    ]
  }

  /// The root as one `MenuModel`: a chevron row per leaf. The iPhone list renders it; the sidebar renders `sections` directly.
  /// Rows stay `.action` (not `.destination`) because the sidebar must select a leaf into its pane instead of pushing it.
  static func model(sections: [SettingsRootSection], onSelect: @escaping (SettingsLeafEntry) -> Void) -> MenuModel {
    MenuModel(sections: sections.map { section in
      MenuSection(id: section.id, header: section.header, items: section.entries.map { entry in
        MenuItem(id: entry.id, title: entry.title, icon: entry.icon, role: .action { onSelect(entry) },
                 description: entry.description, showsChevron: true)
      })
    })
  }
}
```
`GraphicsGeneralState(isIOS:)` is the memberwise init with every other field defaulted (`isIOS` defaults to `true`, Task 5). The Hacks/Enhancements/Performance entries carry NO `keywords`: their rows are searched through `makeModel`. The View `GraphicsGeneralView`/`GraphicsHacksView`/etc. are the Task 3-6 hosts. The Debug, Graphics Advanced and Shaders leaves are the unmigrated ones that keep keywords; before relying on `hostsMenuScreen: false` for them, grep each file for `MenuScreen(`/`ControllerHubView`; set `hostsMenuScreen: true` for any that host one.

- [ ] **Step 4: Search index and results list**

```swift
// UI/Settings/SwiftUI/SettingsSearchIndex.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct SettingsSearchHit: Hashable {
  let entryID: String
  /// The matching row inside a migrated leaf, or nil when the leaf itself matched.
  let rowTitle: String?
}

/// Generated from the root entries and, for migrated leaves, their row titles and descriptions
/// (a hand-built leaf has no model, so only its keywords count). Built once when Settings appears:
/// walking four models per keystroke is wasted work.
struct SettingsSearchIndex {
  private struct Row {
    let hit: SettingsSearchHit
    let terms: [String]
  }

  private let rows: [Row]

  init(sections: [SettingsRootSection]) {
    var rows: [Row] = []
    for entry in sections.flatMap(\.entries) {
      rows.append(Row(hit: SettingsSearchHit(entryID: entry.id, rowTitle: nil), terms: [entry.title, entry.description] + entry.keywords))
      guard let model = entry.makeModel?() else { continue }
      for item in model.allItems {
        rows.append(Row(hit: SettingsSearchHit(entryID: entry.id, rowTitle: item.title), terms: [item.title, item.description ?? ""]))
      }
    }
    self.rows = rows
  }

  func hits(query: String) -> [SettingsSearchHit] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return [] }
    return rows.filter { row in row.terms.contains { $0.localizedCaseInsensitiveContains(q) } }.map(\.hit)
  }
}

/// Search results, shared by the iPhone list and the iPad sidebar.
struct SettingsSearchResults: View {
  let hits: [SettingsSearchHit]
  let entries: [SettingsLeafEntry]
  let onSelect: (SettingsLeafEntry) -> Void

  var body: some View {
    List(hits, id: \.self) { hit in
      if let entry = entries.first(where: { $0.id == hit.entryID }) {
        Button { onSelect(entry) } label: {
          VStack(alignment: .leading, spacing: 2) {
            Label(entry.title, systemImage: entry.icon)
            if let row = hit.rowTitle { Text(row).font(.caption).foregroundStyle(.secondary) }
          }
        }
      }
    }
  }
}
```

- [ ] **Step 5: Web UI leaf, About, Reset All**

`WebUISettingsView.swift`: a `List` with the two rows the old root had (Web UI URL and Finder / WebDAV URL; grep `Text(L("Web UI"))` and `L("Finder / WebDAV")` in the old `SettingsRootView.swift`), the `webImportFooter`, the `refreshLightweightInfo()` polling (moved verbatim, including `webURLDisplay`/`webDavDisplay` state) and the Safari sheet. `SafariView` and `networkURLContextMenu` are iOS-only: keep the old `#if os(iOS)` guards; on tvOS the two rows are plain text rows ("Not Running" or the URL), exactly as the old tvOS branch rendered them. Title `Web UI & WebDAV`.

`AboutView.swift` already shows Version and Core in its centred text: do NOT add them again. Before the trailing `Color.clear.frame(height: 0)` in the `VStack`, add:
```swift
        NavigationLink(destination: DolphinBlogView()) { Label(L("Dolphin Blog"), systemImage: "newspaper") }
        NavigationLink(destination: WikiHelpView()) { Label(L("Help"), systemImage: "questionmark.circle") }
        SettingsResetAllButton(role: .destructive) { Label(L("Reset All Settings"), systemImage: "arrow.counterclockwise") }
```
(`WikiHelpView` is the in-app documentation browser; it works offline and on tvOS.) On tvOS check the rows focus and look right inside the `ScrollView`.

`SettingsSharedComponents.swift`:
```swift
/// Reset All Settings, with its confirmation. One view so the iPhone toolbar and the About leaf share the alert text
/// (the sidebar shell has no toolbar, so About is where tvOS and iPad reach it).
struct SettingsResetAllButton<Label: View>: View {
  var role: ButtonRole?
  let label: Label
  @State private var confirming = false

  init(role: ButtonRole? = nil, @ViewBuilder label: () -> Label) {
    self.role = role
    self.label = label()
  }

  var body: some View {
    Button(role: role) { confirming = true } label: { label }
      .alert(L("Reset All Settings"), isPresented: $confirming) {
        Button(L("Cancel"), role: .cancel) {}
        Button(L("Reset"), role: .destructive) { DOLConfigBridge.resetAllToDefaults() }
      } message: {
        Text(L("This will reset all settings to factory defaults. This may require restarting emulation."))
      }
  }
}
```

- [ ] **Step 6: Shell and the new root**

```swift
// UI/Settings/SwiftUI/SettingsSidebarShell.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// tvOS and iPad (regular width): a sidebar of leaf pages grouped under section headers, and the selected
/// leaf in the pane. The sidebar is its own focus section; right enters the pane. Back (Menu / B) from a
/// leaf returns to the sidebar; Menu at the sidebar leaves Settings (through `BackCoalescer`, so the press
/// that opened Settings cannot close it again).
struct SettingsSidebarShell: View {
  let sections: [SettingsRootSection]
  let searchIndex: SettingsSearchIndex?
  @Binding var jumpToControllers: Bool

  @State private var selectedID: String?
  @FocusState private var sidebarFocus: String?
  @State private var openedAt = Date()
  @Environment(\.menuTheme) private var theme
  @Environment(\.dismiss) private var dismiss
  #if os(iOS)
  @State private var searchText = ""
  #endif

  private enum Layout {
    static let sidebarWidthTV: CGFloat = 320
    static let sidebarWidthPad: CGFloat = 240
    static let iconWidth: CGFloat = 28
    static let rowRadius: CGFloat = 10
    static let selectedOpacity = 0.25
    static let headerTopPadding: CGFloat = 18
  }

  private var entries: [SettingsLeafEntry] { sections.flatMap(\.entries) }
  private var selected: SettingsLeafEntry? { entries.first { $0.id == selectedID } }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
        .frame(width: sidebarWidth)
        #if os(tvOS)
        .focusSection()
        #endif
      Divider()
      NavigationStack {
        if let selected {
          selected.makeView().id(selected.id)
        } else {
          Text(L("Choose a page")).foregroundStyle(.secondary)
        }
      }
      // A leaf in the pane is the root of this stack: its Back must return to the sidebar, not dismiss Settings.
      .environment(\.settingsPaneBack, { sidebarFocus = selectedID })
      #if os(tvOS)
      .focusSection()
      #endif
    }
    .defaultFocus($sidebarFocus, sections.first?.entries.first?.id)
    .onAppear {
      openedAt = Date()
      if selectedID == nil { selectedID = sections.first?.entries.first?.id }
    }
    .onChange(of: jumpToControllers) { _, requested in
      guard requested else { return }
      selectedID = "controllers"      // the DSU deep link lands on the Controllers leaf
      jumpToControllers = false
    }
    #if os(tvOS)
    .onExitCommand(perform: handleExit)
    #endif
  }

  #if os(tvOS)
  /// Menu. Focus in the sidebar: leave Settings. Focus anywhere else (a migrated or hand-built leaf): back to the sidebar.
  private func handleExit() {
    if sidebarFocus != nil {
      guard BackCoalescer.shouldHonor(openedAt: openedAt, now: Date()) else { return }
      dismiss()
    } else {
      sidebarFocus = selectedID
    }
  }
  #endif

  @ViewBuilder
  private var sidebar: some View {
    #if os(iOS)
    NavigationStack {
      Group {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
          sidebarList
        } else {
          SettingsSearchResults(hits: searchIndex?.hits(query: searchText) ?? [], entries: entries) { entry in
            selectedID = entry.id
            searchText = ""
          }
        }
      }
      .navigationTitle(L("Settings"))
      .searchable(text: $searchText, prompt: L("Search Settings"))
    }
    #else
    sidebarList
    #endif
  }

  private var sidebarList: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(sections) { section in
          Text(section.header)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, Layout.headerTopPadding)
            .padding(.horizontal, 12)
          ForEach(section.entries) { entry in
            Button { selectedID = entry.id } label: {
              HStack(spacing: 12) {
                Image(systemName: entry.icon).frame(width: Layout.iconWidth)
                Text(entry.title).lineLimit(1)
                Spacer(minLength: 0)
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                RoundedRectangle(cornerRadius: Layout.rowRadius, style: .continuous)
                  .fill(selectedID == entry.id ? theme.accent.opacity(Layout.selectedOpacity) : .clear))
            }
            .buttonStyle(FocusButtonStyle())
            .focused($sidebarFocus, equals: entry.id)
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 24)
    }
  }

  private var sidebarWidth: CGFloat {
    #if os(tvOS)
    Layout.sidebarWidthTV
    #else
    Layout.sidebarWidthPad
    #endif
  }
}
```
iPad has no sidebar focus engine for a pad; `settingsPaneBack` there sets a `FocusState` that nothing renders, i.e. B on a pad inside the iPad pane does nothing (Settings closes with its own Close/gesture). That is a known limit: the iPad sidebar itself is touch/pointer/keyboard.

`SettingsRootView` becomes (replace the old generic view wholesale; `SettingsRootViewController` keeps calling `SettingsRootView()`):
```swift
struct SettingsRootView: View {
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.dismiss) private var dismiss
  @State private var jumpToControllersRequested = false
  @State private var searchIndex: SettingsSearchIndex?
  #if os(iOS)
  @State private var searchText = ""
  @State private var pushed: SettingsLeafEntry?
  #endif

  private static let selectControllersNotification = Notification.Name("DOLSettingsSelectControllers")

  private var sections: [SettingsRootSection] {
    #if os(iOS)
    let isIOS = true
    #else
    let isIOS = false
    #endif
    #if USE_RETRO_ACHIEVEMENTS
    let achievements = true
    #else
    let achievements = false
    #endif
    return SettingsRootModelBuilder.sections(isIOS: isIOS, achievements: achievements)
  }

  /// tvOS always; iPad only at regular width. Not the size class alone: it is also `.regular` on a Max iPhone in landscape,
  /// which would drop the search, the toolbar Reset All and the deep link.
  #if os(iOS)
  private var usesSidebar: Bool {
    UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
  }
  #endif

  var body: some View {
    Group {
      #if os(tvOS)
      SettingsSidebarShell(sections: sections, searchIndex: searchIndex, jumpToControllers: $jumpToControllersRequested)
      #else
      if usesSidebar {
        SettingsSidebarShell(sections: sections, searchIndex: searchIndex, jumpToControllers: $jumpToControllersRequested)
      } else {
        phoneList
      }
      #endif
    }
    .background(Color.black.ignoresSafeArea())
    .onReceive(NotificationCenter.default.publisher(for: Self.selectControllersNotification)) { _ in jumpToControllersRequested = true }
    .task { if searchIndex == nil { searchIndex = SettingsSearchIndex(sections: sections) } }   // once per appearance
  }

  #if os(iOS)
  private var phoneList: some View {
    NavigationStack {
      Group {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
          MenuScreen(model: SettingsRootModelBuilder.model(sections: sections, onSelect: { pushed = $0 }), style: .list,
                     onBack: { dismiss() })
        } else {
          SettingsSearchResults(hits: searchIndex?.hits(query: searchText) ?? [], entries: sections.flatMap(\.entries)) { pushed = $0 }
        }
      }
      .navigationTitle(L("Settings"))
      .searchable(text: $searchText, prompt: L("Search Settings"))
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          SettingsResetAllButton { Text(L("Reset All")) }
        }
      }
      .navigationDestination(item: $pushed) { entry in entry.pushedView() }
      // DSU-add deep link (dolphinios://dsu/add, legacy dsu://) opens the DSU server list, where the server it just added shows.
      .navigationDestination(isPresented: $jumpToControllersRequested) { DSUSettingsView().padBackNavigation() }
    }
  }
  #endif
}
```
Notes: `GraphicsAdvancedView`, `ShaderSettingsView`, `DebugRootView` and the rest are pushed through `pushedView()` and so get pad Back; `MenuScreen` migrated leaves and `ControllersRootView` do not (they handle it). The old `refreshLightweightInfo()`/`webImportFooter`/Safari state moved to `WebUISettingsView`; the old `SettingsEntry`/`filteredSettingsSections` are deleted. Delete `Common/Swift/TVSettingsPage.swift` and update its callers:
- `TVLibraryView.swift`, iOS `navigationDestinationItemCompat(item: settingsBinding)`: `SettingsRootView().navigationBarTitleDisplayMode(.inline)`.
- `TVLibraryView.swift`, tvOS: `.fullScreenCover(isPresented: $showSettings) { SettingsRootView().interactiveDismissDisabled(true) }` (the shell dismisses on Menu at the sidebar; the old tvOS "Close" toolbar button is gone).
- `EmulationScreen.swift`, tvOS: `SettingsRootView().pauseClaim("settings").interactiveDismissDisabled(true)`, with the `.onExitCommand { showSettings = false }` and the stale comment about `TVSettingsPage` removed.

- [ ] **Step 7: Build both platforms, run the new test classes, then the whole `iCubeTests` target.**

```bash
cd Source/iOS/App
xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-ios
xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos
```
A clean tvOS build proves nothing about focus; the Task 8 device gates do.

- [ ] **Step 8: Commit** (no trailers, no attribution; do not `git add` `SettingsRootViewController.swift`)

```bash
git add Common/UI/Settings/SwiftUI/SettingsRootModelBuilder.swift Common/UI/Settings/SwiftUI/SettingsSearchIndex.swift Common/UI/Settings/SwiftUI/SettingsSidebarShell.swift Common/UI/Settings/SwiftUI/WebUISettingsView.swift Common/UI/Settings/SwiftUI/SettingsRootView.swift Common/UI/Settings/SwiftUI/AboutView.swift Common/UI/Settings/SwiftUI/SettingsSharedComponents.swift Common/Swift/TVLibraryView.swift Common/Swift/EmulationScreen.swift Common/Services/WebServerLifecycleService.swift DolphiniOSTests/SettingsRootModelBuilderTests.swift DolphiniOSTests/SettingsSearchIndexTests.swift
git rm Common/Swift/TVSettingsPage.swift
git commit -m "feat(settings): sidebar shell, root model and generated search"
```

---

### Task 8: Snapshot renders, device gates, PR

Rulings that apply here (restated): **P20** the snapshot test file is `#if os(iOS) && DEBUG`, like `PauseMenuSnapshotTests`, and the PR body adds an iPad sidebar device gate; **P5, P6, P14, P15, P16** each gain a device gate below. Commits carry no trailers or attribution; the PR body carries none either.

**Files:**
- Create: `DolphiniOSTests/SettingsSnapshotRenderTests.swift`. Copy the harness of `DolphiniOSTests/PauseMenuSnapshotTests.swift` (including the `#if os(iOS) && DEBUG` wrapper and the `TEST_RUNNER_SETTINGS_SNAPSHOT_DIR` env var; export it with the `TEST_RUNNER_` prefix so `xcodebuild` forwards it). Renders `SettingsRootView()` at iPhone portrait and iPad 1024x768 (the iPad render needs a regular size class and the `.pad` idiom: run it on an iPad simulator destination), and `GraphicsHacksView()` inside a `NavigationStack` at iPhone portrait.

- [ ] **Step 1: Write and run the snapshot test** (`cd Source/iOS/App && tuist generate --no-open` first); look at the PNGs: iPad shows the sidebar with eight headers and the first leaf in the pane; iPhone shows the grouped list with icons, descriptions and chevrons; Hacks shows a description under every row and a value on the cycle rows.

- [ ] **Step 2: Device gates**

iPhone (Xbox pad and touch):
1. Settings root: d-pad walks rows; A pushes a leaf; **B pops it, and B on a pushed hand-built leaf (General, Debug, Web UI) also pops** (`padBackNavigation`); B at the root closes Settings; while a leaf is pushed the hidden root does not move. Search "v-sync" lists Video with the row named; tapping opens Video.
2. Hacks: toggle Bounding Box off and on; Bounding Box Sync greys out and back. Left/right on VI Skip Mode cycles; long-press opens the list. Skip Duplicate XFBs is greyed in the default state (VI Skip Auto) and enabled only with VI Skip Off.
3. Performance: with Adaptive Clock active in a game, the CPU clock row shows "Auto" and is disabled; the VBI stepper writes (leave and re-enter the page: the value survived); **holding d-pad left/right on a stepper repeats after about 0.4 s and a cycle row still steps once per press**.
4. Enhancements: Internal Resolution cycles Auto, 1x, 2x...; choosing a fixed scale turns Auto IR off in Video; turning MSAA to None clears SSAA; the mipmap threshold row appears only with detection on and reads `0.50` style values.
5. Video: change nothing and re-enter: Config is untouched (a stored unknown backend is shown normalised but not rewritten).

Apple TV (Xbox pad or Siri Remote):
6. Sidebar: up/down moves through headers and rows; right enters the pane on the first row; left from a toggle row returns to the sidebar; the focus ring shows. **On a cycle or stepper row, left/right steps the value (and does NOT leave the row); Menu returns to the sidebar; Menu at the sidebar leaves Settings.** Holding right on a stepper keeps stepping. Inside a leaf that pushed a child screen, Menu pops the child first.
7. Opening Settings from the library and from the pause overlay (PR 2): the Menu release of the press that opened it does not close it again (`BackCoalescer`); the old "Close" button is gone and Menu at the sidebar is the only exit.
8. Reset All Settings: About leaf, destructive row, alert, cancel works (do not confirm on a device with data you care about).
9. Hacks on tvOS: holding Select on a cycle row opens the list.
10. DSU deep link (`dolphinios://dsu/add`) while Settings is open selects the Controllers leaf.

iPad (regular width, touch + pointer; a pad only moves within a pane leaf):
11. The sidebar shows eight headers, search works (rows inside migrated leaves are found and open the leaf), tapping a row shows the leaf in the pane, Reset All is in About, the DSU deep link selects Controllers. Rotating or entering Split View compact swaps to the grouped list without crashing.

- [ ] **Step 3: Open the PR against `develop`** (stacked on PR 2: say so in the body)

Title: `feat(settings): settings on the menu engine with a sidebar shell`. Body: spec §6 summary; the deviations listed at the top of this plan (iPhone grouped list, leaf-page sidebar, shell only on tvOS/iPad-regular, Reset All in About, `.action` root rows with a chevron, Double-backed stepper with grid snapping, tvOS left/right stepping, `SheetScaffold` dropped); snapshot PNGs; device gate results; and these ledger items: the iCloud row loses its `SyncStatusIndicator` (no accessory slot in `MenuItem`), the sidebar shell has no search on tvOS (as before), a pad cannot navigate the iPad sidebar itself (touch/pointer only), the old green "Recommended" capsule became a text badge, and the list of leaves still hand-built (General, Interface, Advanced, Audio, GameCube, Wii, Achievements, Graphics Advanced, Shaders, Controllers, Debug, Web UI, iCloud, Nearby, About) for the PR 5 batches. No LLM attribution anywhere. Do not push `develop`.
