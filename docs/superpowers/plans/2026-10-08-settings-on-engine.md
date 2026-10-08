# Settings on the Menu Engine Implementation Plan (PR 3 of the unified menu UX)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Settings renders through `MenuModel`/`MenuScreen` with a sidebar shell on tvOS and iPad, every row carrying a one-line description, controller-adjustable rows, generated search, and the four largest leaf screens (Performance Tuning, Graphics Hacks, Graphics General, Graphics Enhancements) migrated to model builders.

**Architecture:** Each migrated leaf becomes a plain `State` snapshot, a `Change` enum, a pure `ModelBuilder.make(state:apply:)`, and a thin host view that syncs the snapshot from Config and applies changes to Config. The root becomes a `SettingsRootModelBuilder` whose rows point at leaf views; `SettingsRootView` picks a sidebar shell (tvOS, iPad regular width) or a grouped list (iPhone). Unmigrated leaves stay reachable through `.destination(AnyView)`.

**Tech Stack:** Swift 5, SwiftUI, XCTest (`iCubeTests`), Tuist.

**Spec:** `docs/superpowers/specs/2026-10-07-unified-menu-ux-design.md` §4.1 (`ValueStepper`), §6, §8, §9, §10 item 3. Depends on PR 2 (`.cycle`, `description`, `longPress`, `FocusButtonStyle`, the long-press picker in `MenuScreen`).

**Spec deviations, decided while planning:**
- **iPhone gets a grouped list, not a tab strip.** The sidebar lists the ~20 leaf pages grouped under 8 headers; a capsule strip of 20 items is worse than the list the iPhone has today. The iPhone root is the same `MenuModel` rendered as `MenuScreen(.list)` with icons and descriptions, pushing leaves. Spec §6.1's "tab-strip shell" is replaced by this.
- **The sidebar lists leaf pages, not sections.** Selecting a sidebar row shows that leaf in the pane (iFly's shape), so a setting is two moves away, not three.
- **`SheetScaffold` is dropped** from spec §4.1: nothing in PR 2 or PR 3 needs it.
- **Reset All** stays in the iPhone toolbar and becomes a destructive row in the About leaf on tvOS, not "at the bottom of General" (§6.2): the General leaf is not migrated in this PR.
- **No builder throws** (§8's "leaf builders that throw"): every builder takes a snapshot struct with defaults, so a missing Config key shows a default, never an empty section.

## Global Constraints

- Minimum targets iOS 17 / tvOS 17; every changed file compiles for both.
- Settings rows never save what they only displayed: a host syncs its snapshot from Config in `configSynced` and writes Config only from `apply(_:)`, which only a control reaches. `SettingsWriteBackTests` describes the rule; the builder tests here enforce it per leaf.
- Row ids are stable strings, lowercase-kebab, unique within a leaf (e.g. `efb-access`, `vi-skip-mode`).
- Descriptions are the caption strings the current views pass to `settingsCaption` / `rowWithCaption` / `settingsNavCaption`, copied verbatim (they are already localised through `L(...)`). A row that has no caption today gets a one-sentence description written for it; never leave `description` nil on a settings row.
- Strings go through `L("...")`.
- Pause/resume only through `PauseArbiter`.
- Commits: conventional, subject < 72 chars, no LLM attribution trailers.
- New test files need `cd Source/iOS/App && tuist generate --no-open`. Tests: `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/<Class>"`. tvOS compile: `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube-tvOS (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos` (confirm scheme name with `xcodebuild -list`).
- Worktree on branch `feat/settings-engine` from `develop` (after PR 2 lands). After `git worktree add`, run `git config --worktree core.worktree <absolute worktree path>` and confirm `git rev-parse --show-toplevel`. DO NOT git reset / rebase / push / touch develop.
- Paths are relative to `Source/iOS/App/` unless they start with `docs/`. `UI/Settings/SwiftUI/` means `Common/UI/Settings/SwiftUI/`.

## File map

| File | Responsibility |
|---|---|
| Modify `Common/Swift/Menu/MenuModel.swift` | `.stepper` role. |
| Create `Common/Swift/MenuKit/ValueStepper.swift` | tvOS/iOS numeric row control. |
| Modify `Common/Swift/Menu/MenuScreen.swift` | `.stepper` rows; `.cycle` list rows with left/right (tvOS) and long-press (iOS). |
| Create `UI/Settings/SwiftUI/SettingsLeafHost.swift` | Shared host modifier: title, help button, `configSynced`, start/end resync. |
| Create `UI/Settings/SwiftUI/Leaves/GraphicsHacks{State,ModelBuilder,View}.swift` | Hacks on the engine. |
| Create `UI/Settings/SwiftUI/Leaves/GraphicsEnhancements{State,ModelBuilder,View}.swift` | Enhancements on the engine. |
| Create `UI/Settings/SwiftUI/Leaves/GraphicsGeneral{State,ModelBuilder,View}.swift` | Video on the engine. |
| Create `UI/Settings/SwiftUI/Leaves/PerformanceTuning{State,ModelBuilder,View}.swift` | Performance on the engine. |
| Delete `UI/Settings/SwiftUI/GraphicsHacksView.swift`, `GraphicsEnhancementsView.swift`, `GraphicsGeneralView.swift`, `PerformanceTuningView.swift` | Replaced. Their private picker sub-views go with them; their `enum`s (`GraphicsBackend`, `AspectRatio`, `TargetFPS`, `InternalScale`, `ShaderCompileType`, `CpuEngine`) and the file-scope `settingsCaption`/`settingsNavCaption` helpers move to `UI/Settings/SwiftUI/SettingsEnums.swift` and stay in `SettingsSharedComponents.swift` respectively. |
| Create `UI/Settings/SwiftUI/SettingsRootModelBuilder.swift` | Root sections and rows. |
| Create `UI/Settings/SwiftUI/SettingsSearchIndex.swift` | Generated from the root and leaf models. |
| Create `UI/Settings/SwiftUI/SettingsSidebarShell.swift` | tvOS / iPad shell. |
| Create `UI/Settings/SwiftUI/WebUISettingsView.swift` | Web UI + WebDAV rows and the Safari sheet, out of the root. |
| Modify `UI/Settings/SwiftUI/SettingsRootView.swift` | Thin host choosing a shell. |
| Modify `UI/Settings/SwiftUI/AboutView.swift` | Absorbs Version, Core, Blog, Help rows. |
| Delete `Common/Swift/TVSettingsPage.swift` | Replaced by the sidebar shell; callers in `TVLibraryView.swift:567,1857` and `EmulationScreen.swift:534` use `SettingsRootView()`. |
| Tests: extend `MenuModelTests`; create `ValueStepperTests`, `GraphicsHacksModelBuilderTests`, `GraphicsEnhancementsModelBuilderTests`, `GraphicsGeneralModelBuilderTests`, `PerformanceTuningModelBuilderTests`, `SettingsRootModelBuilderTests`, `SettingsSearchIndexTests`, `SettingsSnapshotRenderTests`. |

---

### Task 1: `.stepper` role and `ValueStepper`

**Files:**
- Modify: `Common/Swift/Menu/MenuModel.swift`
- Create: `Common/Swift/MenuKit/ValueStepper.swift`
- Modify: `Common/Swift/Menu/MenuScreen.swift` (`listRow`, `tvRow`, `performActivate`, `tick`)
- Test: `DolphiniOSTests/MenuModelTests.swift`, create `DolphiniOSTests/ValueStepperTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct MenuStepper {
    var value: Binding<Double>
    var range: ClosedRange<Double>
    var step: Double
    var format: (Double) -> String
    func stepped(_ current: Double, by direction: Int) -> Double   // clamped, direction ±1
  }
  // MenuItemRole gains:
  case stepper(MenuStepper)
  struct ValueStepper: View { init(stepper: MenuStepper, isEnabled: Bool) }
  ```

- [ ] **Step 1: Write the failing tests**

Append to `MenuModelTests`:
```swift
  func test_stepper_clampsAndSteps() {
    var box: Double = 100
    let stepper = MenuStepper(value: Binding(get: { box }, set: { box = $0 }), range: 1 ... 400, step: 5, format: { "\(Int($0))%" })
    XCTAssertEqual(stepper.stepped(100, by: 1), 105)
    XCTAssertEqual(stepper.stepped(398, by: 1), 400, "clamped at the top")
    XCTAssertEqual(stepper.stepped(3, by: -1), 1, "clamped at the bottom")
    let item = MenuItem(id: "clock", title: "CPU Clock", role: .stepper(stepper))
    XCTAssertEqual(item.currentValueTitle, "100%")
  }
```
Create `ValueStepperTests`:
```swift
// DolphiniOSTests/ValueStepperTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

/// `ValueStepper` has no logic of its own beyond `MenuStepper.stepped`; this pins the formatting
/// contract its label relies on.
final class ValueStepperTests: XCTestCase {
  func test_format_isUsedForTheLabel() {
    let stepper = MenuStepper(value: .constant(0.5), range: 0 ... 30, step: 0.1, format: { String(format: "%.1f", $0) })
    XCTAssertEqual(stepper.format(stepper.value.wrappedValue), "0.5")
  }
}
```

- [ ] **Step 2: Regenerate, run, verify failure** (`MenuModelTests`, `ValueStepperTests`). Expected: `MenuStepper` not found.

- [ ] **Step 3: Implement**

`MenuModel.swift`:
```swift
/// A numeric setting: a `Slider` row on iOS, a left/right stepper row on tvOS (spec §6.3).
struct MenuStepper {
  var value: Binding<Double>
  var range: ClosedRange<Double>
  var step: Double
  var format: (Double) -> String

  func stepped(_ current: Double, by direction: Int) -> Double {
    min(range.upperBound, max(range.lowerBound, current + Double(direction) * step))
  }
}
```
Add `case stepper(MenuStepper)` to `MenuItemRole`. In `MenuItem.currentValueTitle` add `case .stepper(let stepper): return stepper.format(stepper.value.wrappedValue)`.

`ValueStepper.swift`:
```swift
// Common/Swift/MenuKit/ValueStepper.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One numeric row. tvOS: a focusable row that left/right steps (replaces `TVIntStepper`,
/// `TVFloatStepper`, `TVIntStepperOverlay`). iOS: a `Slider` with the formatted value beside it.
struct ValueStepper: View {
  let stepper: MenuStepper
  let isEnabled: Bool
  @Environment(\.menuTheme) private var theme
  #if os(tvOS)
  @FocusState private var isFocused: Bool
  #endif

  var body: some View {
    #if os(tvOS)
    HStack(spacing: 16) {
      Image(systemName: "chevron.left")
      Text(stepper.format(stepper.value.wrappedValue)).monospacedDigit()
      Image(systemName: "chevron.right")
    }
    .contentShape(Rectangle())
    .focusable(isEnabled)
    .focused($isFocused)
    .padding(8)
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(isFocused ? theme.accent : .clear, lineWidth: theme.focusRingWidth))
    .opacity(isEnabled ? 1 : 0.5)
    .onMoveCommand { direction in
      guard isEnabled else { return }
      switch direction {
      case .left: stepper.value.wrappedValue = stepper.stepped(stepper.value.wrappedValue, by: -1)
      case .right: stepper.value.wrappedValue = stepper.stepped(stepper.value.wrappedValue, by: 1)
      default: break
      }
    }
    #else
    HStack(spacing: 12) {
      Slider(value: stepper.value, in: stepper.range, step: stepper.step)
      Text(stepper.format(stepper.value.wrappedValue)).monospacedDigit().frame(minWidth: 56, alignment: .trailing)
    }
    .disabled(!isEnabled)
    #endif
  }
}
```
`MenuScreen`:
- `listRow` (iOS): `case .stepper(let stepper): VStack(alignment: .leading, spacing: 6) { rowLabel(item); ValueStepper(stepper: stepper, isEnabled: item.isEnabled) }`.
- `tvRow`: `case .stepper(let stepper): HStack { rowLabel(item); Spacer(); ValueStepper(stepper: stepper, isEnabled: item.isEnabled) }.focused($tvFocusedID, equals: item.id)`.
- `performActivate`: `case .stepper: break` (A does nothing; left/right adjust).
- iOS `tick()` adjust block: for `.stepper(let s)`, `s.value.wrappedValue = s.stepped(s.value.wrappedValue, by: adjust.step)`.
- `MenuFocusRouter.isPicker(_:in:)`: `.stepper` counts as a picker (left/right adjusts, never moves columns).
- Both renderers also show `item.description` under the title when present: in `rowLabel`, after the subtitle, `if let description = item.description { Text(description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }`. Add a `description:` parameter to the five-argument `rowLabel(title:subtitle:icon:tint:badge:)` with a default of `nil` so existing callers compile.
- `.cycle` list rows: iOS `listRow` adds `.simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in runLongPress(item) })` on the cycle Button; tvOS `tvRow` adds `.onMoveCommand` left/right stepping the cycle (same code as the tiles in PR 2 Task 4).

- [ ] **Step 4: Run to verify pass**; build both platforms.

- [ ] **Step 5: Commit**

```bash
git add Common/Swift/Menu/MenuModel.swift Common/Swift/Menu/MenuScreen.swift Common/Swift/Menu/MenuFocusRouter.swift Common/Swift/MenuKit/ValueStepper.swift DolphiniOSTests/MenuModelTests.swift DolphiniOSTests/ValueStepperTests.swift
git commit -m "feat(menu): .stepper role, ValueStepper, descriptions on list rows"
```

---

### Task 2: Leaf host scaffolding

**Files:**
- Create: `UI/Settings/SwiftUI/SettingsLeafHost.swift`
- Create: `UI/Settings/SwiftUI/SettingsEnums.swift` (move `GraphicsBackend`, `AspectRatio`, `TargetFPS`, `InternalScale`, `ShaderCompileType`, `CpuEngine` out of the four leaf files, unchanged)

**Interfaces:**
- Produces:
  ```swift
  extension View {
    /// Title, help sheet, Config sync on appear/Config change/emulation start+stop/foreground.
    func settingsLeaf(title: String, helpKey: String? = nil, sync: @escaping () -> Void) -> some View
  }
  ```

- [ ] **Step 1: Write it**

```swift
// UI/Settings/SwiftUI/SettingsLeafHost.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

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
      .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DOLEmulationDidStartNotification"))) { _ in sync() }
      .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DOLEmulationDidEndNotification"))) { _ in sync() }
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
  func settingsLeaf(title: String, helpKey: String? = nil, sync: @escaping () -> Void) -> some View {
    modifier(SettingsLeafHost(title: title, helpKey: helpKey, sync: sync))
  }
}
```
`HelpButton` is `ToolbarContent`; a conditional inside `.toolbar { }` needs `ToolbarContentBuilder`, which supports `if`. If the compiler rejects it, split into two modifiers (`.toolbar { HelpButton(...) }` applied only when `helpKey != nil` via `Group`).

- [ ] **Step 2: Move the enums**

Cut `enum GraphicsBackend`, `enum AspectRatio`, `enum TargetFPS`, `enum InternalScale`, `enum ShaderCompileType` from `GraphicsGeneralView.swift` and `enum CpuEngine` from `PerformanceTuningView.swift` into `SettingsEnums.swift`, unchanged. Build both platforms.

- [ ] **Step 3: Commit**

```bash
git add UI/Settings/SwiftUI/SettingsLeafHost.swift UI/Settings/SwiftUI/SettingsEnums.swift UI/Settings/SwiftUI/GraphicsGeneralView.swift UI/Settings/SwiftUI/PerformanceTuningView.swift
git commit -m "refactor(settings): leaf host modifier and shared settings enums"
```

---

### Task 3: Graphics Hacks on the engine (the reference migration)

**Files:**
- Create: `UI/Settings/SwiftUI/Leaves/GraphicsHacksState.swift`, `GraphicsHacksModelBuilder.swift`, `GraphicsHacksView.swift`
- Delete: `UI/Settings/SwiftUI/GraphicsHacksView.swift` (old; keep `MetalTriStatePicker` by moving it to `SettingsSharedComponents.swift`, it is used elsewhere)
- Test: create `DolphiniOSTests/GraphicsHacksModelBuilderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct GraphicsHacksState: Equatable { ...23 settings + backendSupportsBbox }
  enum GraphicsHacksChange: Equatable { case textureCacheSamples(Int), bboxEnabled(Bool), ... }
  enum GraphicsHacksModelBuilder {
    static func make(state: GraphicsHacksState, apply: @escaping (GraphicsHacksChange) -> Void) -> MenuModel
  }
  struct GraphicsHacksView: View   // same name as before, so the root keeps compiling
  ```

- [ ] **Step 1: Write the failing tests**

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

  func test_toggle_emitsOneChange_andNothingOnBuild() {
    let m = model()
    XCTAssertTrue(changes.isEmpty, "building the model must not write")
    guard case .toggle(let binding)? = m.item(id: "efb-access")?.role else { return XCTFail("toggle") }
    binding.wrappedValue = true
    XCTAssertEqual(changes, [.efbAccess(true)])
  }

  func test_cycle_textureCache_offersSafeDefaultFast() {
    guard case .cycle(let options, let selection)? = model().item(id: "texture-cache")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Safe", "Default", "Fast"])
    selection.wrappedValue = AnyHashable(512)
    XCTAssertEqual(changes, [.textureCacheSamples(512)])
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

  func test_skipDuplicateXfb_disabledWhileImmediateXfbOrViSkip() {
    var state = GraphicsHacksState()
    state.immediateXfb = true
    XCTAssertEqual(model(state).item(id: "skip-duplicate-xfb")?.isEnabled, false)
    state.immediateXfb = false
    state.viSkipMode = 1
    XCTAssertEqual(model(state).item(id: "skip-duplicate-xfb")?.isEnabled, false)
    state.viSkipMode = 0
    XCTAssertEqual(model(state).item(id: "skip-duplicate-xfb")?.isEnabled, true)
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
The three gating rules (`backendSupportsBbox`, `skipDuplicateXFBsEnabled`, `deferEfbCopiesEnabled`) are the ones the old view computes; read their exact expressions from the old `GraphicsHacksView.swift` (`skipDuplicateXFBsEnabled` and `deferEfbCopiesEnabled` are computed properties near the top of the file) and reproduce them in the builder so these tests match the old behaviour.

- [ ] **Step 2: Regenerate, run, verify failure.**

- [ ] **Step 3: State and Change**

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

- [ ] **Step 4: Builder**

```swift
// UI/Settings/SwiftUI/Leaves/GraphicsHacksModelBuilder.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Pure: snapshot in, changes out. Descriptions are the captions the hand-built screen showed.
enum GraphicsHacksModelBuilder {
  static func make(state: GraphicsHacksState, apply: @escaping (GraphicsHacksChange) -> Void) -> MenuModel {
    func toggle(_ id: String, _ title: String, _ value: Bool, _ description: String, enabled: Bool = true,
                _ change: @escaping (Bool) -> GraphicsHacksChange) -> MenuItem {
      MenuItem(id: id, title: title, role: .toggle(Binding(get: { value }, set: { apply(change($0)) })),
               isEnabled: enabled, description: description)
    }
    func cycle(_ id: String, _ title: String, _ options: [(String, AnyHashable)], _ value: Int, _ description: String,
               enabled: Bool = true, _ change: @escaping (Int) -> GraphicsHacksChange) -> MenuItem {
      MenuItem(id: id, title: title,
               role: .cycle(options: options, selection: Binding(get: { AnyHashable(value) }, set: { if let v = $0 as? Int { apply(change(v)) } })),
               isEnabled: enabled, description: description)
    }

    let skipDuplicateEnabled = !state.immediateXfb && state.viSkipMode != 1
    let deferEfbEnabled = !(state.skipEfbToRam && state.skipXfbToRam)
    let bbox = state.backendSupportsBbox

    let general = MenuSection(id: "general-hacks", header: L("General Hacks"), items: [
      cycle("texture-cache", L("Texture Cache Accuracy"), [(L("Safe"), 512), (L("Default"), 128), (L("Fast"), 0)], state.textureCacheSamples,
            L("Adjusts how strictly the GPU tracks texture updates from RAM. Safer is slower but avoids garbled text in some games."), GraphicsHacksChange.textureCacheSamples),
      toggle("bbox", L("Bounding Box Emulation"), state.bboxEnabled,
             bbox ? L("Emulates GameCube/Wii bounding-box tests on the GPU. Required by some games; leave off unless needed.")
                  : L("The current graphics backend does not support bounding box emulation on this device."),
             enabled: bbox, GraphicsHacksChange.bboxEnabled),
      cycle("bbox-sync", L("Bounding Box Sync"), [(L("Latched"), 0), (L("Force Sync"), 1)], state.bboxSyncMode,
            L("How iCube delivers bounding-box values. Latched serves a 1-frame-stale snapshot with no CPU stall (faster). Force Sync blocks for exact same-frame values — try it if a game's bbox-driven effects (some 2D/UI culling) look wrong."),
            enabled: state.bboxEnabled && bbox, GraphicsHacksChange.bboxSyncMode),
      toggle("efb-access", L("Enable EFB Access"), state.efbAccess,
             L("Lets the CPU read back the framebuffer. Required by some effects but costly; many games run fine and faster with it off."), GraphicsHacksChange.efbAccess),
      toggle("skip-efb-ram", L("Skip EFB Copy to RAM"), state.skipEfbToRam,
             L("Keeps embedded-framebuffer copies on the GPU instead of system RAM. Faster; breaks a few effects. Recommended on."), GraphicsHacksChange.skipEfbToRam),
      toggle("skip-xfb-ram", L("Skip XFB Copy to RAM"), state.skipXfbToRam,
             L("Keeps the external framebuffer on the GPU. Faster; can break games that read the final image."), GraphicsHacksChange.skipXfbToRam),
      toggle("immediate-xfb", L("Immediate XFB"), state.immediateXfb,
             L("Presents frames the moment they're drawn — lower latency, but can cause flicker or tearing in some games."), GraphicsHacksChange.immediateXfb),
      toggle("copy-efb-scaled", L("Copy EFB Scaled"), state.copyEfbScaled,
             L("Copies the framebuffer at the higher internal resolution rather than native. Keeps upscaled detail; recommended on."), GraphicsHacksChange.copyEfbScaled),
      toggle("early-xfb", L("Early XFB Output"), state.earlyXfbOutput,
             L("Outputs the frame earlier in the pipeline for lower latency. Recommended on; turn off if a game shows glitches."), GraphicsHacksChange.earlyXfbOutput),
      toggle("skip-duplicate-xfb", L("Skip Duplicate XFBs"), state.skipDuplicateXFBs,
             skipDuplicateEnabled ? L("Avoids re-presenting identical frames, saving GPU work. Recommended on.")
                                  : L("Unavailable while Immediate XFB or VI Skip is enabled — duplicate frames are already handled."),
             enabled: skipDuplicateEnabled, GraphicsHacksChange.skipDuplicateXFBs),
      toggle("efb-format-changes", L("Emulate EFB Format Changes"), state.efbFormatChanges,
             L("Emulates pixel-format changes some games rely on. Needed for correct colors/effects in those games; small cost."), GraphicsHacksChange.efbFormatChanges),
      toggle("vertex-rounding", L("Vertex Rounding"), state.vertexRounding,
             L("Rounds vertex positions to reduce seams between tiles at higher resolutions. Only helps above 1x; leave off at 1x."), GraphicsHacksChange.vertexRounding),
      toggle("force-progressive", L("Force Progressive Scan"), state.forceProgressive,
             L("Forces 480p output where games allow it, for a cleaner image."), GraphicsHacksChange.forceProgressive),
      toggle("defer-efb-copies", L("Defer EFB Copies"), state.deferEfbCopies,
             deferEfbEnabled ? L("Batches framebuffer copies to reduce overhead. Faster in most games; recommended on.")
                             : L("Unavailable while both EFB and XFB copies stay on the GPU — there is no RAM copy to defer."),
             enabled: deferEfbEnabled, GraphicsHacksChange.deferEfbCopies),
      cycle("vi-skip", L("VI Skip Mode"), [(L("Off"), 0), (L("On"), 1), (L("Auto"), 2)], state.viSkipMode,
            L("Skips video-interrupt frames to gain speed. Auto is the safe choice; On is more aggressive but can cause flicker."), GraphicsHacksChange.viSkipMode),
      toggle("fast-texture-sampling", L("Fast Texture Sampling"), state.fastTextureSampling,
             L("Uses faster, less precise texture sampling. Small speed win; rarely causes minor texture artifacts. Recommended on."), GraphicsHacksChange.fastTextureSampling),
      toggle("fast-math", L("Fast Math (Metal Shaders)"), state.fastMath,
             L("Lets Metal shaders use fast, relaxed-precision math. Can speed up the GPU; may cause subtle rendering differences."), GraphicsHacksChange.fastMath),
      toggle("compute-efb-xfb", L("Use Compute for EFB/XFB"), state.useComputeEfbXfb,
             L("Native-Metal compute acceleration for EFB/XFB. Experimental GPU perf knob; OFF by default. Applies on next launch."), GraphicsHacksChange.useComputeEfbXfb),
      toggle("compute-vertex-decode", L("Use Compute for Vertex Decode"), state.useComputeVertexDecode,
             L("Offload vertex decoding to a Metal compute shader (CPU→GPU). Experimental — currently only position-only-float formats use the GPU path (others fall back to CPU), so most games see little change yet. OFF by default. Applies on next launch."), GraphicsHacksChange.useComputeVertexDecode),
      toggle("no-mipmapping", L("No Mipmapping (iOS)"), state.noMipmapping,
             L("Disables mipmaps. Saves a little memory/bandwidth but makes distant textures shimmer. Leave off normally."), GraphicsHacksChange.noMipmapping),
      toggle("gpu-efb-peek", L("GPU EFB Peek Resolve"), state.gpuEfbPeekResolve,
             L("Experimental: resolves EFB peek reads on the GPU instead of a CPU readback. May reduce CPU-thread stalls for games that read the framebuffer; OFF by default. Verify visuals per game."), GraphicsHacksChange.gpuEfbPeekResolve),
    ])
    let interlace = MenuSection(id: "interlace", items: [
      toggle("vi-decimate-interlace", L("Interlaced Field Decimation"), state.viDecimateInterlace,
             L("Skips every other interlaced field for higher FPS. May reduce temporal resolution or cause flicker in some games."), GraphicsHacksChange.viDecimateInterlace),
    ])
    return MenuModel(sections: [general, interlace])
  }
}
```
The two gating expressions above are what the old view's `skipDuplicateXFBsEnabled` / `deferEfbCopiesEnabled` compute; confirm against the old file before deleting it and keep the old expression if it differs.

- [ ] **Step 5: Host view**

```swift
// UI/Settings/SwiftUI/Leaves/GraphicsHacksView.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Hacks, on the menu engine. `sync()` reads Config into the snapshot; `apply(_:)` is the only writer.
struct GraphicsHacksView: View {
  @State private var state = GraphicsHacksState()

  var body: some View {
    MenuScreen(model: GraphicsHacksModelBuilder.make(state: state, apply: apply), style: .list)
      .settingsLeaf(title: L("Hacks"), sync: sync)
  }

  private func sync() {
    var s = GraphicsHacksState()
    s.textureCacheSamples = DOLConfigBridge.gfxSafeTextureCacheColorSamples()
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
The getter for texture cache samples is whatever the old `sync()` used (`DOLConfigBridge.gfxSafeTextureCacheColorSamples()`; confirm the exact name in the old file's `sync()`).

- [ ] **Step 6: Delete the old file, move `MetalTriStatePicker`**

`git rm UI/Settings/SwiftUI/GraphicsHacksView.swift` after copying `struct MetalTriStatePicker` (old lines ~119-130) into `SettingsSharedComponents.swift` unchanged. Build both platforms; run `GraphicsHacksModelBuilderTests`.

- [ ] **Step 7: Commit**

```bash
git add UI/Settings/SwiftUI/Leaves/GraphicsHacks*.swift UI/Settings/SwiftUI/SettingsSharedComponents.swift DolphiniOSTests/GraphicsHacksModelBuilderTests.swift
git rm UI/Settings/SwiftUI/GraphicsHacksView.swift
git commit -m "feat(settings): Graphics Hacks on the menu engine"
```

---

### Task 4: Graphics Enhancements on the engine

Same shape as Task 3: `GraphicsEnhancementsState`, `GraphicsEnhancementsChange`, `GraphicsEnhancementsModelBuilder.make(state:apply:)`, `GraphicsEnhancementsView` with `sync()`/`apply(_:)`, old file deleted, tests in `DolphiniOSTests/GraphicsEnhancementsModelBuilderTests.swift`.

**Files:**
- Create: `UI/Settings/SwiftUI/Leaves/GraphicsEnhancements{State,ModelBuilder,View}.swift`
- Delete: `UI/Settings/SwiftUI/GraphicsEnhancementsView.swift`
- Test: create `DolphiniOSTests/GraphicsEnhancementsModelBuilderTests.swift`

**State** (defaults from the old `@State`s): `anisotropy = 1`, `msaa = 1`, `ssaa = false`, `outputResampling = 0`, `trueColor = true`, `disableCopyFilter = true`, `efbScale = 1`, `efbMaxScale = 6`, `efbOverride: DOLConfigOverride = .none`, `widescreenHack = false`, `disableFog = false`, `arbitraryMipmapDetection = false`, `arbitraryMipmapThreshold = 0.5`, `hdrOutput = false`, `gpuTextureDecoding = false`.

**Change**: one case per setting the user can edit (`efbScale(Int)`, `anisotropy(Int)`, `msaa(Int)`, `ssaa(Bool)`, `outputResampling(Int)`, `trueColor(Bool)`, `disableCopyFilter(Bool)`, `widescreenHack(Bool)`, `hdrOutput(Bool)`, `gpuTextureDecoding(Bool)`, `disableFog(Bool)`, `arbitraryMipmapDetection(Bool)`, `arbitraryMipmapThreshold(Double)`).

**Rows, in the old order**, four sections with the old headers (read them from the old file's `Section(content:header:)` calls):

| id | kind | options / range | enabled | badge | description |
|---|---|---|---|---|---|
| `efb-scale` | cycle | `Auto`(0), `1x (Native)`(1), then `2x`…`\(efbMaxScale)x` | `efbOverride == .none` | `ConfigOverrideBadge` title for `efbOverride` (`"Auto"`/`"Game"`/nil) | old caption |
| `anisotropy` | cycle | `1x, 2x, 4x, 8x, 16x` (values 1,2,4,8,16) | | | old caption |
| `msaa` | cycle | `Off`(1), `2x`(2), `4x`(4), `8x`(8) | | | old caption |
| `ssaa` | toggle | | | | old caption |
| `output-resampling` | cycle | the old `OutputResamplingPicker` option list, same labels and values | | | old caption |
| `true-color` | toggle | | | | old caption |
| `disable-copy-filter` | toggle | | | | old caption |
| `widescreen-hack` | toggle | | | | old caption |
| `hdr-output` | toggle | | | | old caption |
| `gpu-texture-decoding` | toggle | | | | old caption |
| `disable-fog` | toggle | | | | old caption |
| `arbitrary-mipmap` | toggle | | | | old caption |
| `arbitrary-mipmap-threshold` | stepper | `0 ... 30`, step `0.1`, format `%.1f` | `arbitraryMipmapDetection` | | old caption |

**apply(_:) side effects to keep** (from the old view): setting `efbScale` also calls `DOLConfigBridge.setGfxAutoIREnable(false)` when the new scale is not 0 (the old `onSet` closure at lines ~50-58 does this; copy its exact condition); setting `msaa` to 1 also sets `ssaa` false through `DOLConfigBridge.setGfxSsaa(false)` and the snapshot (old lines ~80-86). `sync()` reads `efbScale` from `gfxEfbScaleBase()` and `efbOverride` from `efbScaleOverride()`, as the old `sync()` does, so an Auto-IR CurrentRun value is never written back.

**Tests** (same file shape as Task 3): row order; every row described; `efb-scale` disabled and badged `"Game"` when `efbOverride = .game`; `msaa` set to 1 emits `[.msaa(1)]` only (the SSAA clearing is the host's job, assert it in a host-less way by checking the builder emits exactly one change); `arbitrary-mipmap-threshold` is a `.stepper` with range `0...30` and is disabled while detection is off; building emits no change.

- [ ] Steps: write tests → regenerate, verify failure → State/Change → builder → host view → `git rm` old file → build both → tests pass → commit `feat(settings): Graphics Enhancements on the menu engine`.

---

### Task 5: Graphics General (Video) on the engine

**Files:**
- Create: `UI/Settings/SwiftUI/Leaves/GraphicsGeneral{State,ModelBuilder,View}.swift`
- Delete: `UI/Settings/SwiftUI/GraphicsGeneralView.swift` (its picker sub-views `GraphicsBackendPickerView`, `GraphicsAspectRatioView`, `GraphicsTargetFPSView`, `GraphicsMinScaleView`, `GraphicsMaxScaleView` go with it; the enums already moved in Task 2)
- Test: create `DolphiniOSTests/GraphicsGeneralModelBuilderTests.swift`

**State**: `backend: GraphicsBackend = .metal`, `aspect: AspectRatio = .auto`, `vSync = false`, `showAutoIrOSD = false`, `tripleBuffering = false`, `forceScaleOneNonProMotion = false`, `overscanFullscreen = false`, `asyncPresent = false`, `autoIR = false`, `targetFPS: TargetFPS = .fps60`, `minScale: InternalScale = .x1_0`, `maxScale: InternalScale = .x2_0`, `frameCap = 0`, `instantReplay = false`, `clipSeconds = 15`, `shaderType: ShaderCompileType = .specialized`, `compileBeforeStart = true`, plus `isIOS: Bool` (the builder hides the iOS-only rows on tvOS; the host passes `true` under `#if os(iOS)`).

**Change**: one case per editable setting, carrying the enum or primitive the old `onSet` closure received.

**Rows, in the old order**, three sections: the unnamed first section, `Recording` (iOS only), `Shader Compilation`:

| id | kind | options / notes |
|---|---|---|
| `backend` | cycle | `GraphicsBackend.allCases` as `(label, backendKey)`; apply also writes `UserDefaults "ui_gfx_backend"` |
| `aspect-ratio` | cycle | `AspectRatio.allCases` as `(label, aspectRaw)` |
| `vsync` | toggle | |
| `auto-ir-osd` | toggle | |
| `triple-buffering` | toggle | UserDefaults `gfx_triple_buffering` |
| `force-scale-one` | toggle | UserDefaults `gfx_force_scale_one_non_promo` |
| `overscan-fullscreen` | toggle | `TVEmulationBridge.setOverscanFullscreenEnabled` |
| `async-present` | toggle | |
| `auto-ir` | toggle | |
| `target-fps` | cycle | `TargetFPS.allCases` |
| `min-scale` | cycle | `InternalScale.allCases` |
| `max-scale` | cycle | `InternalScale.allCases` |
| `frame-cap` | cycle, iOS only | `System Default`(0), `30`, `60`, `90`, `120`; UserDefaults `ui_frame_cap` |
| `instant-replay` | toggle, iOS only | UserDefaults `replaykit_instant_replay_enabled` |
| `save-clips-photos` | toggle, iOS only | UserDefaults `replaykit_save_to_photos` |
| `save-only-photos` | toggle, iOS only | UserDefaults `replaykit_save_only_photos` |
| `clip-length` | cycle, iOS only | the old `Clip Length` picker's options |
| `shader-compile-type` | cycle | `ShaderCompileType.allCases` |
| `compile-before-start` | toggle | |

If an enum lacks `CaseIterable`, add it in `SettingsEnums.swift`. The cycle values are the enum's raw/bridge value wrapped in `AnyHashable`; the builder maps back with the enum's `from(raw:)` or `init?(rawValue:)` as the old picker views did.

**Tests**: row order with `isIOS: true` includes the five iOS-only ids and with `isIOS: false` excludes them; every row described; `backend` cycle options equal `GraphicsBackend.allCases.map(\.label)`; toggling `vsync` emits `[.vSync(true)]`; building emits nothing.

- [ ] Steps as Task 4; commit `feat(settings): Video settings on the menu engine`.

---

### Task 6: Performance Tuning on the engine

**Files:**
- Create: `UI/Settings/SwiftUI/Leaves/PerformanceTuning{State,ModelBuilder,View}.swift`
- Delete: `UI/Settings/SwiftUI/PerformanceTuningView.swift` (`CpuEnginePicker` and `RecommendedBadge` go with it; `PerformanceABView` is its own file and stays)
- Test: create `DolphiniOSTests/PerformanceTuningModelBuilderTests.swift`

**State**: every `@State`/`@AppStorage` the old view declares (lines 24-90), same names and defaults, plus `jitAvailable`, `cpuClockOverride`, `vbiOverride`, `showValidation` (the manual collapsible), and `engine: CpuEngine` from which the builder derives `showEngineOpts`, `showCIROpts`, `showIROpts` with the old view's expressions (read them from the old file; they are computed properties near `showEngineOpts`).

**Change**: one case per editable setting, plus `showValidation(Bool)`, `resetOptimizationsToRecommended`, and `openPerformanceAB` (the host pushes `PerformanceABView` through a `.destination` row instead; so no change case for it).

**Sections and rows, in the old order:**
1. `cpu-options`, header `CPU Options`, footer text becomes the section's first row description? No: `MenuSection` has no footer. Put the footer text (which depends on `jitAvailable`) as the description of the `cpu-engine` row, prefixed to that row's own help. Rows: `cpu-engine` (cycle over `CpuEngine` cases the old `CpuEnginePicker` offers for `jitAvailable`), `mmu`, `adaptive-clock` (UserDefaults `adaptive_clock_enable`), `vertex-loader` (cycle `Software`(0), `NEON SIMD (default)`(1), `Compare (validate)`(2); UserDefaults `icube_vertex_loader_mode`), `pause-on-panic`, `accurate-cpu-cache`, `bypass-icache`, `ci-prefetch`, `neon-texture-decode`, `dcbz-hack`, `relaxed-idle`, `ff-ctr-idle`, `sync-on-skip-idle`.
2. `engine-optimizations`, header `Engine Optimizations`, only when `showEngineOpts`: `performance-ab` (`.destination(AnyView(PerformanceABView()))`, description from the old `settingsNavCaption`), `reset-optimizations` (`.action`, title `Reset Optimizations to Recommended`), then the `optRow`s in the old order. A `recommended: true` row gets `badge: L("Recommended")` and `tint: .green`. The `showCIROpts` and `showIROpts` groups keep their gating.
3. `validation`, header `Correctness Validation (developer, slow)`: first row `show-validation` is a `.toggle` on `showValidation` (replaces the manual collapsible button); the `validateRow`s follow only when `showValidation`, each `isEnabled: parentOn` with the old parent mapping.
4. `diagnostics`, header `Diagnostics`: the `CIR Hot-Block Profiler` toggle with its old binding target.
5. `clock-override`, header `Clock Override`: `cpu-clock-enabled` toggle (`isEnabled: cpuClockOverride == .none`), `cpu-clock-percent` stepper `1...400` step 1 format `"\(Int($0))%"` (`isEnabled: cpuClockEnabled && cpuClockOverride == .none`, badge from `ConfigOverrideBadge` title).
6. `vbi-override`, header `Override VBI Frequency`: same two rows for VBI.

**Tests**: section ids in order for a JIT-available Cached Interpreter state; `engine-optimizations` absent when `showEngineOpts` is false; `cpu-clock-percent` disabled and badged `"Auto"` when `cpuClockOverride = .auto`; validate rows absent until `showValidation`, and each disabled until its parent is on (pick two: `Specialized Ops: Validate` requires `cirSpecializedOps`; `Micro-Op Fusion: Validate` requires `cirMicroOpFusion`); `reset-optimizations` emits `.resetOptimizationsToRecommended`; every row described; building emits nothing.

- [ ] Steps as Task 4; commit `feat(settings): Performance Tuning on the menu engine`.

---

### Task 7: Root model, generated search, sidebar shell

**Files:**
- Create: `UI/Settings/SwiftUI/SettingsRootModelBuilder.swift`, `SettingsSearchIndex.swift`, `SettingsSidebarShell.swift`, `WebUISettingsView.swift`
- Modify: `UI/Settings/SwiftUI/SettingsRootView.swift`, `AboutView.swift`
- Delete: `Common/Swift/TVSettingsPage.swift`; update `Common/Swift/TVLibraryView.swift:567,1857` and `Common/Swift/EmulationScreen.swift:534` to `SettingsRootView()`
- Test: create `DolphiniOSTests/SettingsRootModelBuilderTests.swift`, `DolphiniOSTests/SettingsSearchIndexTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct SettingsLeafEntry: Identifiable {
    let id: String            // e.g. "graphics-hacks"
    let title: String
    let icon: String
    let description: String
    let keywords: [String]
    let makeView: () -> AnyView
    /// Migrated leaves only: their rows, for search. nil for a hand-built leaf.
    let makeModel: (() -> MenuModel)?
  }
  struct SettingsRootSection: Identifiable { let id: String; let header: String; let entries: [SettingsLeafEntry] }
  enum SettingsRootModelBuilder {
    static func sections(isIOS: Bool, achievements: Bool) -> [SettingsRootSection]
    static func model(sections: [SettingsRootSection], onSelect: @escaping (SettingsLeafEntry) -> Void) -> MenuModel
  }
  struct SettingsSearchHit: Equatable { let entryID: String; let rowTitle: String? }
  enum SettingsSearchIndex {
    static func hits(query: String, sections: [SettingsRootSection]) -> [SettingsSearchHit]
  }
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
  }

  func test_model_rowsAreDestinationsInOrder() {
    let sections = SettingsRootModelBuilder.sections(isIOS: false, achievements: false)
    let model = SettingsRootModelBuilder.model(sections: sections, onSelect: { _ in })
    XCTAssertEqual(model.sections.map(\.id), sections.map(\.id))
    XCTAssertEqual(model.allItems.map(\.id), sections.flatMap(\.entries).map(\.id))
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

  func test_entryTitle_matches() {
    XCTAssertTrue(SettingsSearchIndex.hits(query: "hacks", sections: sections).contains(SettingsSearchHit(entryID: "graphics-hacks", rowTitle: nil)))
  }

  func test_leafRowTitle_matches_withTheRowNamed() {
    let hits = SettingsSearchIndex.hits(query: "v-sync", sections: sections)
    XCTAssertTrue(hits.contains { $0.entryID == "graphics-video" && $0.rowTitle == "V-Sync" })
  }

  func test_keyword_matches() {
    XCTAssertTrue(SettingsSearchIndex.hits(query: "msaa", sections: sections).contains { $0.entryID == "graphics-enhancements" })
  }

  func test_emptyQuery_hasNoHits() {
    XCTAssertTrue(SettingsSearchIndex.hits(query: "  ", sections: sections).isEmpty)
  }
}
```

- [ ] **Step 2: Regenerate, run, verify failure.**

- [ ] **Step 3: Root builder**

```swift
// UI/Settings/SwiftUI/SettingsRootModelBuilder.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct SettingsLeafEntry: Identifiable {
  let id: String
  let title: String
  let icon: String
  let description: String
  let keywords: [String]
  let makeView: () -> AnyView
  let makeModel: (() -> MenuModel)?

  init(id: String, title: String, icon: String, description: String, keywords: [String] = [],
       makeModel: (() -> MenuModel)? = nil, @ViewBuilder view: @escaping () -> some View) {
    self.id = id
    self.title = title
    self.icon = icon
    self.description = description
    self.keywords = keywords
    self.makeModel = makeModel
    self.makeView = { AnyView(view()) }
  }
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
    if achievements {
      consoles.append(SettingsLeafEntry(id: "achievements", title: L("Achievements"), icon: "trophy", description: L("RetroAchievements sign-in and hardcore mode.")) { ConfigAchievementsView() })
    }
    return [
      SettingsRootSection(id: "general", header: L("General"), entries: [
        SettingsLeafEntry(id: "general", title: L("General"), icon: "gear", description: L("Dual core, cheats, speed limit and other core options.")) { ConfigGeneralView() },
        SettingsLeafEntry(id: "interface", title: L("Interface"), icon: "menubar.rectangle", description: L("On-screen messages, confirmations and panic handling.")) { ConfigInterfaceView() },
        SettingsLeafEntry(id: "advanced", title: L("Advanced"), icon: "cpu", description: L("Clock overrides and other expert options.")) { ConfigAdvancedView() },
      ]),
      SettingsRootSection(id: "graphics", header: L("Graphics"), entries: [
        SettingsLeafEntry(id: "graphics-video", title: L("Video"), icon: "display",
                          description: L("Backend, aspect ratio, V-Sync, auto resolution and shader compilation."),
                          makeModel: { GraphicsGeneralModelBuilder.make(state: GraphicsGeneralState(isIOS: isIOS), apply: { _ in }) }) { GraphicsGeneralView() },
        SettingsLeafEntry(id: "graphics-enhancements", title: L("Enhancements"), icon: "sparkles",
                          description: L("Internal resolution, anti-aliasing, filtering and colour."),
                          keywords: ["anisotropic", "anisotropy", "msaa", "anti-aliasing", "resampling", "efb scale", "internal resolution"],
                          makeModel: { GraphicsEnhancementsModelBuilder.make(state: GraphicsEnhancementsState(), apply: { _ in }) }) { GraphicsEnhancementsView() },
        SettingsLeafEntry(id: "graphics-hacks", title: L("Hacks"), icon: "wrench.and.screwdriver",
                          description: L("Speed-for-accuracy trade-offs in the GPU pipeline."),
                          keywords: ["texture cache", "vsync", "v-sync", "bbox", "vi skip", "efb"],
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
        SettingsLeafEntry(id: "controllers", title: L("Controllers"), icon: "gamecontroller", description: L("Players, devices, what each plays as, and remapping.")) { ControllersRootView() },
      ]),
      SettingsRootSection(id: "performance", header: L("Performance"), entries: [
        SettingsLeafEntry(id: "performance-tuning", title: L("Performance Tuning"), icon: "gauge.with.dots.needle.67percent",
                          description: L("CPU engine, optimisations, clock overrides. The CPU is the bottleneck on iCube."),
                          keywords: ["cpu", "interpreter", "cached interpreter", "jit", "speed limit", "fast forward"],
                          makeModel: { PerformanceTuningModelBuilder.make(state: PerformanceTuningState(), apply: { _ in }) }) { PerformanceTuningView() },
        SettingsLeafEntry(id: "debug", title: L("Debug"), icon: "ladybug", description: L("Developer switches: fastmem, JIT, logging, stall metrics."),
                          keywords: ["fastmem", "jit", "logging", "stall metrics", "wireframe", "haptics"]) { DebugRootView() },
      ]),
      SettingsRootSection(id: "sync-network", header: L("Sync & Network"), entries: [
        SettingsLeafEntry(id: "web-ui", title: L("Web UI & WebDAV"), icon: "network", description: L("Import games from a computer on the same Wi-Fi.")) { WebUISettingsView() },
        SettingsLeafEntry(id: "icloud", title: L("iCloud Sync"), icon: "icloud", description: L("Sync saves, states and settings across your devices.")) { CloudSyncSettingsView() },
        SettingsLeafEntry(id: "nearby", title: L("Nearby Devices"), icon: "antenna.radiowaves.left.and.right", description: L("Continue a game from another device, and manage paired ones.")) { ContinuityBrowseView() },
      ]),
      SettingsRootSection(id: "about", header: L("About"), entries: [
        SettingsLeafEntry(id: "about", title: L("About"), icon: "info.circle", description: L("Version, core, blog and help.")) { AboutView() },
      ]),
    ]
  }

  /// The root as one `MenuModel`: a row per leaf. The iPhone list renders it; the sidebar renders
  /// `sections` directly.
  static func model(sections: [SettingsRootSection], onSelect: @escaping (SettingsLeafEntry) -> Void) -> MenuModel {
    MenuModel(sections: sections.map { section in
      MenuSection(id: section.id, header: section.header, items: section.entries.map { entry in
        MenuItem(id: entry.id, title: entry.title, icon: entry.icon, role: .action { onSelect(entry) }, description: entry.description)
      })
    })
  }
}
```
`GraphicsGeneralState(isIOS:)` is the memberwise init with every other field defaulted; give `isIOS` a default of `true` in the struct so `GraphicsGeneralState()` also compiles.

- [ ] **Step 4: Search index**

```swift
// UI/Settings/SwiftUI/SettingsSearchIndex.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

struct SettingsSearchHit: Equatable {
  let entryID: String
  /// The matching row inside a migrated leaf, or nil when the leaf itself matched.
  let rowTitle: String?
}

/// Generated from the root entries and, for migrated leaves, their row titles and descriptions.
/// Replaces the hand-kept keyword lists (keywords still count, for hand-built leaves).
enum SettingsSearchIndex {
  static func hits(query: String, sections: [SettingsRootSection]) -> [SettingsSearchHit] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return [] }
    var hits: [SettingsSearchHit] = []
    for entry in sections.flatMap(\.entries) {
      if entry.title.localizedCaseInsensitiveContains(q)
          || entry.description.localizedCaseInsensitiveContains(q)
          || entry.keywords.contains(where: { $0.localizedCaseInsensitiveContains(q) }) {
        hits.append(SettingsSearchHit(entryID: entry.id, rowTitle: nil))
      }
      guard let model = entry.makeModel?() else { continue }
      for item in model.allItems
      where item.title.localizedCaseInsensitiveContains(q) || (item.description ?? "").localizedCaseInsensitiveContains(q) {
        hits.append(SettingsSearchHit(entryID: entry.id, rowTitle: item.title))
      }
    }
    return hits
  }
}
```

- [ ] **Step 5: Web UI leaf and About**

`WebUISettingsView.swift`: a `List` with the two rows the root had (Web UI URL, Finder / WebDAV URL), the `webImportFooter`, the `refreshLightweightInfo()` polling (moved verbatim), and on iOS the Safari sheet. Title `Web UI & WebDAV`.

`AboutView.swift`: prepend a section with the Version and Core rows (moved from the root, including the `DolphinLogo` image), and `NavigationLink`s to `DolphinBlogView()` and `WikiHelpView()` with the root's labels.

- [ ] **Step 6: Shells and the new root**

```swift
// UI/Settings/SwiftUI/SettingsSidebarShell.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// tvOS and iPad: a sidebar of leaf pages grouped under section headers, and the selected leaf in the
/// pane. The sidebar is its own focus section; moving right enters the pane, left returns.
struct SettingsSidebarShell: View {
  let sections: [SettingsRootSection]
  @State private var selectedID: String?
  @Environment(\.menuTheme) private var theme

  private var selected: SettingsLeafEntry? {
    sections.flatMap(\.entries).first { $0.id == selectedID }
  }

  var body: some View {
    HStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(sections) { section in
            Text(section.header)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.top, 18)
              .padding(.horizontal, 12)
            ForEach(section.entries) { entry in
              Button { selectedID = entry.id } label: {
                HStack(spacing: 12) {
                  Image(systemName: entry.icon).frame(width: 28)
                  Text(entry.title).lineLimit(1)
                  Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                  RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selectedID == entry.id ? theme.accent.opacity(0.25) : .clear))
              }
              .buttonStyle(FocusButtonStyle())
            }
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
      }
      .frame(width: sidebarWidth)
      #if os(tvOS)
      .focusSection()
      #endif
      Divider()
      NavigationStack {
        if let selected {
          selected.makeView()
            .id(selected.id)
        } else {
          Text(L("Choose a page")).foregroundStyle(.secondary)
        }
      }
      #if os(tvOS)
      .focusSection()
      #endif
    }
    .onAppear { if selectedID == nil { selectedID = sections.first?.entries.first?.id } }
  }

  private var sidebarWidth: CGFloat {
    #if os(tvOS)
    320
    #else
    260
    #endif
  }
}
```
`SettingsRootView` becomes:
```swift
struct SettingsRootView: View {
  @Environment(\.horizontalSizeClass) private var sizeClass
  @State private var showGlobalResetAlert = false
  @State private var jumpToControllersRequested = false
  #if os(iOS)
  @State private var searchText = ""
  @State private var pushed: SettingsLeafEntry?
  #endif

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

  var body: some View {
    Group {
      #if os(tvOS)
      SettingsSidebarShell(sections: sections)
      #else
      if sizeClass == .regular {
        SettingsSidebarShell(sections: sections)
      } else {
        phoneList
      }
      #endif
    }
    .background(Color.black.ignoresSafeArea())
    .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DOLSettingsSelectControllers"))) { _ in jumpToControllersRequested = true }
    .alert(L("Reset All Settings"), isPresented: $showGlobalResetAlert) {
      Button(L("Cancel"), role: .cancel) {}
      Button(L("Reset"), role: .destructive) { DOLConfigBridge.resetAllToDefaults() }
    } message: {
      Text(L("This will reset all settings to factory defaults. This may require restarting emulation."))
    }
  }

  #if os(iOS)
  private var phoneList: some View {
    NavigationStack {
      Group {
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
          MenuScreen(model: SettingsRootModelBuilder.model(sections: sections, onSelect: { pushed = $0 }), style: .list)
        } else {
          searchResults
        }
      }
      .navigationTitle(L("Settings"))
      .searchable(text: $searchText, prompt: L("Search Settings"))
      .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Reset All")) { showGlobalResetAlert = true } } }
      .navigationDestination(item: $pushed) { entry in entry.makeView() }
      .navigationDestination(isPresented: $jumpToControllersRequested) { DSUSettingsView() }
    }
  }

  private var searchResults: some View {
    let hits = SettingsSearchIndex.hits(query: searchText, sections: sections)
    let entries = sections.flatMap(\.entries)
    return List(hits, id: \.self) { hit in
      if let entry = entries.first(where: { $0.id == hit.entryID }) {
        Button { pushed = entry } label: {
          VStack(alignment: .leading, spacing: 2) {
            Label(entry.title, systemImage: entry.icon)
            if let row = hit.rowTitle { Text(row).font(.caption).foregroundStyle(.secondary) }
          }
        }
      }
    }
  }
  #endif
}
```
`SettingsLeafEntry` needs `Hashable` for `.navigationDestination(item:)`: conform by `id` only (`==` compares ids, `hash` combines id). `SettingsSearchHit` needs `Hashable` for `List(_, id: \.self)`: add it. The old generic `SettingsRootView<Background>` and its `init(backgroundView:)` are removed; `SettingsRootViewController.swift:16` and the three other call sites use the plain `SettingsRootView()`. On tvOS, the Reset All button moves into the About leaf as a destructive row (no toolbar in the sidebar shell).

Delete `TVSettingsPage.swift`; the three callers present `SettingsRootView()` in the same `.fullScreenCover`, keeping `.interactiveDismissDisabled(true)` and the `.onExitCommand` closing the cover, and (from PR 1) `.pauseClaim("settings")` in `EmulationScreen`.

- [ ] **Step 7: Build both platforms, run `SettingsRootModelBuilderTests`, `SettingsSearchIndexTests`, then the whole target.**

- [ ] **Step 8: Commit**

```bash
git add UI/Settings/SwiftUI/SettingsRootModelBuilder.swift UI/Settings/SwiftUI/SettingsSearchIndex.swift UI/Settings/SwiftUI/SettingsSidebarShell.swift UI/Settings/SwiftUI/WebUISettingsView.swift UI/Settings/SwiftUI/SettingsRootView.swift UI/Settings/SwiftUI/AboutView.swift Common/Swift/TVLibraryView.swift Common/Swift/EmulationScreen.swift UI/Settings/SettingsRootViewController.swift DolphiniOSTests/SettingsRootModelBuilderTests.swift DolphiniOSTests/SettingsSearchIndexTests.swift
git rm Common/Swift/TVSettingsPage.swift
git commit -m "feat(settings): sidebar shell, root model and generated search"
```

---

### Task 8: Snapshot renders, device gates, PR

**Files:**
- Create: `DolphiniOSTests/SettingsSnapshotRenderTests.swift` (same harness as `PauseMenuSnapshotTests`, env var `TEST_RUNNER_SETTINGS_SNAPSHOT_DIR`; renders `SettingsRootView()` at iPhone portrait and iPad 1024×768, and `GraphicsHacksView()` inside a `NavigationStack` at iPhone portrait).

- [ ] **Step 1: Write and run the snapshot test**; look at the PNGs: iPad shows the sidebar with eight headers and the first leaf in the pane; iPhone shows the grouped list with icons and descriptions; Hacks shows a description under every row and a value pill on the cycle rows.

- [ ] **Step 2: Device gates**

iPhone (Xbox pad and touch):
1. Settings root: d-pad walks rows; A pushes a leaf; B pops. Search "v-sync" lists Video with the row named; tapping opens Video.
2. Hacks: toggle Bounding Box off and on; Bounding Box Sync greys out and back. Left/right on VI Skip Mode cycles; long-press opens the list.
3. Performance: with Adaptive Clock active in a game, the CPU clock row shows "Auto" and is disabled; the VBI stepper slides and writes (check the value survives leaving and re-entering the page).
4. Enhancements: Internal Resolution cycles Auto → 1x → 2x…; choosing a fixed scale turns Auto IR off in Video.

Apple TV (Xbox pad):
5. Sidebar: up/down moves through headers and rows; right enters the pane on the first row; left from the first column returns to the sidebar; the focus ring and scale show.
6. Hacks on tvOS: left/right on a cycle row changes the pill; holding Select opens the list; a stepper row left/right steps; Menu returns to the library or the game (still paused, PR 1).
7. Settings from the pause overlay (PR 2) opens this shell full-screen and Menu returns.

- [ ] **Step 3: Open the PR against `develop`**

Title: `feat(settings): settings on the menu engine with a sidebar shell`. Body: spec §6 summary, the three deviations listed at the top of this plan, snapshot PNGs, device gate results, and the list of leaves still hand-built (General, Interface, Advanced, Audio, GameCube, Wii, Achievements, Graphics Advanced, Shaders, Controllers, Debug, Web UI, iCloud, Nearby, About) for the PR 5 batches. Do not push `develop`.
