# MenuKit + Unified Pause Overlay Implementation Plan (PR 2 of the unified menu UX)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One tile-grid pause overlay for iOS and tvOS, built from one `MenuModel`, whose top row is the quick bar (Resume, Quick Save, Quick Load, Fast Forward, Mute, Screenshot), with tap-to-cycle, long-press pickers and an info shelf.

**Architecture:** A small `MenuKit` folder (theme, focus button style, tile face, info shelf, back coalescer) with no bridge dependencies. `MenuModel` gains `description`, `longPress` and a `.cycle` role; `MenuScreen` gains a `.tiles(columns:)` style rendered natively on both platforms. `PauseMenuModelBuilder` produces three sections; `PauseMenuView` renders them through `MenuScreen` and loses its hand-built tvOS column.

**Tech Stack:** Swift 5, SwiftUI, XCTest (`iCubeTests`, iOS simulator), Tuist.

**Spec:** `docs/superpowers/specs/2026-10-07-unified-menu-ux-design.md` §4.1, §4.2, §5, §8, §9, §10 item 2. Depends on PR 1 (`PauseArbiter`, plan `2026-10-07-pause-arbiter.md`) being merged: this plan uses `PauseArbiter.shared.userResume()` and `.pauseClaim`.

**Deferred to the settings plan (PR 3):** `ValueStepper` and `SheetScaffold` from spec §4.1. The pause overlay does not use them.

## Global Constraints

- Minimum targets iOS 17 / tvOS 17; every changed file compiles for both. `MenuKit` and `MenuScreen` have no `#if` around whole files; platform branches are local.
- `MenuKit` files import only `SwiftUI`/`Foundation` and `MenuModel`. No `TVEmulationBridge`, no `ControllerManager`, no `DOL*`.
- `MenuItem.id`s are stable strings. Item ids in the pause model: `resume`, `quick-save`, `quick-load`, `fast-forward`, `mute`, `screenshot`, `save-states`, `cheats`, `shaders`, `controllers`, `continuity`, `recenter-pointer`, `settings`, `reset`, `exit`.
- Strings go through `L("...")` (`Common/Swift/Localized.swift`).
- Pause/resume only through `PauseArbiter` (`UILayerPauseCallsTests` enforces it).
- Commits: conventional, subject < 72 chars, no LLM attribution trailers.
- New test files need `cd Source/iOS/App && tuist generate --no-open` or they silently do not run. Tests: `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/<Class>"`. tvOS compile: `xcodebuild build -workspace iCube.xcworkspace -scheme "iCube-tvOS (NJB)" -destination "generic/platform=tvOS Simulator" CODE_SIGNING_ALLOWED=NO -derivedDataPath build-Xcode-tvos` (confirm the scheme with `xcodebuild -list`).
- Worktree on branch `feat/menukit-pause-overlay` from `develop` (after PR 1 lands). After `git worktree add`, run `git config --worktree core.worktree <absolute worktree path>` and confirm `git rev-parse --show-toplevel`. DO NOT git reset / rebase / push / touch develop.
- Paths are relative to `Source/iOS/App/` unless they start with `docs/`.

## File map

| File | Responsibility |
|---|---|
| Modify `Common/Swift/Menu/MenuModel.swift` | `description`, `longPress`, `.cycle`. |
| Modify `Common/Swift/Menu/MenuControllerNav.swift` | `activateOnRelease`, `.longActivate`. |
| Modify `Common/Swift/Menu/MenuFocusRouter.swift` | `longActivatedID` in `MenuFocusUpdate`. |
| Create `Common/Swift/MenuKit/MenuTheme.swift` | Theme protocol, `ICubeTheme`, environment key. |
| Create `Common/Swift/MenuKit/FocusButtonStyle.swift` | Ring + scale focus style, both platforms. |
| Create `Common/Swift/MenuKit/TileFace.swift` | A tile's face. |
| Create `Common/Swift/MenuKit/InfoShelf.swift` | Description shelf. |
| Create `Common/Swift/MenuKit/BackCoalescer.swift` | Opening-press guard. |
| Modify `Common/Swift/Menu/MenuScreen.swift` | `.tiles` style, long-press picker overlay, info shelf. |
| Create `Common/Swift/Shaders/ShaderQuickApply.swift` | Apply/MRU/options extracted from `ShaderQuickPickerView`. |
| Modify `Common/Swift/Shaders/ShaderQuickPickerView.swift:337-376` | Call `ShaderQuickApply`. |
| Modify `Common/Swift/TopBar/QuickScreenshot.swift` | `saveFromPausePreview()`. |
| Create `Common/Swift/PauseTileLayout.swift` | Column count rule. |
| Modify `Common/Swift/PauseMenuView.swift` | New shared root; delete tvOS hand-built menu and the FF picker pane/overlay. |
| Tests: extend `MenuModelTests`, `MenuFocusRouterTests`, `PauseMenuModelBuilderTests`, `QuickScreenshotTests`; create `BackCoalescerTests`, `ShaderQuickApplyTests`, `PauseTileLayoutTests`, `PauseMenuSnapshotTests`. |

---

### Task 1: MenuModel — description, longPress, cycle

**Files:**
- Modify: `Common/Swift/Menu/MenuModel.swift`
- Test: `DolphiniOSTests/MenuModelTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum MenuLongPress {
    case options(title: String, options: [(String, AnyHashable)], selection: Binding<AnyHashable>)
    case action(() -> Void)
  }
  // MenuItem gains:
  var description: String?
  var longPress: MenuLongPress?
  // MenuItemRole gains:
  case cycle(options: [(String, AnyHashable)], selection: Binding<AnyHashable>)
  // MenuItem gains:
  var effectiveLongPress: MenuLongPress?     // explicit, else derived from .cycle
  var currentValueTitle: String?             // .cycle/.picker: selected option title; .toggle: "On"/"Off"
  ```

- [ ] **Step 1: Write the failing tests** (append to `MenuModelTests`)

```swift
  // MARK: Cycle / long-press (unified menu UX spec §4.2)

  private final class Box { var value: AnyHashable = AnyHashable(200) }

  private func cycleItem(_ box: Box, longPress: MenuLongPress? = nil) -> MenuItem {
    let options: [(String, AnyHashable)] = [("Off", -1), ("2x", 200), ("4x", 400)]
    return MenuItem(
      id: "ff", title: "Fast Forward",
      role: .cycle(options: options, selection: Binding(get: { box.value }, set: { box.value = $0 })),
      description: "Tap to cycle", longPress: longPress)
  }

  func test_cycleItem_derivesLongPressFromItsOptions() {
    let box = Box()
    guard case .options(let title, let options, _)? = cycleItem(box).effectiveLongPress else {
      return XCTFail("a .cycle item with no explicit longPress offers its own options")
    }
    XCTAssertEqual(title, "Fast Forward")
    XCTAssertEqual(options.map(\.0), ["Off", "2x", "4x"])
  }

  func test_explicitLongPress_winsOverDerived() {
    let box = Box()
    var ran = false
    let item = cycleItem(box, longPress: .action { ran = true })
    if case .action(let run)? = item.effectiveLongPress { run() } else { XCTFail("explicit long press kept") }
    XCTAssertTrue(ran)
  }

  func test_currentValueTitle_forCycleToggleAndAction() {
    let box = Box()
    XCTAssertEqual(cycleItem(box).currentValueTitle, "2x")
    box.value = AnyHashable(999)
    XCTAssertEqual(cycleItem(box).currentValueTitle, "—", "an unknown value renders as a dash (spec §8)")
    let on = MenuItem(id: "m", title: "Mute", role: .toggle(.constant(true)))
    XCTAssertEqual(on.currentValueTitle, "On")
    XCTAssertNil(MenuItem(id: "a", title: "A", role: .action {}).currentValueTitle)
  }

  func test_cycled_unknownCurrent_landsOnFirstOption() {
    let options: [(String, AnyHashable)] = [("Off", -1), ("2x", 200)]
    XCTAssertEqual(MenuItemRole.cycled(options: options, current: AnyHashable(999), step: 1), AnyHashable(-1))
  }
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Source/iOS/App && make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/MenuModelTests" 2>&1 | grep -E "error:|Executed" | head`
Expected: compile errors for `MenuLongPress`, `description:`, `.cycle`.

- [ ] **Step 3: Implement**

In `MenuModel.swift`, add after `MenuItemRole`:
```swift
/// What a long-press of A (or a touch long-press) on an item does (unified menu UX spec §4.2).
enum MenuLongPress {
  /// A picker of every value; the `.cycle` role derives this from its own options.
  case options(title: String, options: [(String, AnyHashable)], selection: Binding<AnyHashable>)
  /// Something else, e.g. the Shaders tile opening the full picker.
  case action(() -> Void)
}
```
Add to `MenuItemRole`:
```swift
  /// Activate advances to the next option and wraps; the tile shows the current option as its badge.
  /// A long-press opens the full list. Unlike `.picker`, this never explodes into rows on tvOS.
  case cycle(options: [(String, AnyHashable)], selection: Binding<AnyHashable>)
```
Add two stored properties to `MenuItem` with matching `init` parameters (defaulted, appended after `isCompactOnTV` so existing call sites compile):
```swift
  /// One line shown in the info shelf while the item is focused.
  var description: String?
  var longPress: MenuLongPress?
```
Add the computed members:
```swift
extension MenuItem {
  /// The explicit long-press, else the one a `.cycle` role implies.
  var effectiveLongPress: MenuLongPress? {
    if let longPress { return longPress }
    if case .cycle(let options, let selection) = role {
      return .options(title: title, options: options, selection: selection)
    }
    return nil
  }

  /// The value a tile badge shows. `"—"` for a cycle/picker whose value matches no option (spec §8).
  var currentValueTitle: String? {
    switch role {
    case .cycle(let options, let selection), .picker(let options, let selection):
      return MenuItemRole.selectedTitle(options: options, current: selection.wrappedValue) ?? "—"
    case .toggle(let binding):
      return binding.wrappedValue ? L("On") : L("Off")
    default:
      return nil
    }
  }
}
```
`MenuItemRole.cycled` already lands on the first option for an unknown current (index -1, step +1). No change.

In `MenuScreen.performActivate`, add a case next to `.picker`:
```swift
    case .cycle(let options, let selection):
      if let next = MenuItemRole.cycled(options: options, current: selection.wrappedValue, step: 1) {
        selection.wrappedValue = next
      }
```
and in the `tick()` adjust block, accept `.cycle` as well as `.picker` (left/right step it). In `listRow` (iOS) and `tvRow` (tvOS) add `case .cycle:` to the `Button { performActivate(item) }` branch, showing `item.currentValueTitle` as the badge: `rowLabel(title:subtitle:icon:tint:badge: item.currentValueTitle ?? item.badge)`. In `MenuFocusRouter.isPicker(_:in:)` treat `.cycle` like `.picker` so a d-pad left/right on a cycle tile in a grid steps the value rather than moving columns.

- [ ] **Step 4: Run to verify pass**; also run `MenuFocusRouterTests` and `PauseMenuModelBuilderTests` (existing callers still compile).

- [ ] **Step 5: Commit**

```bash
git add Common/Swift/Menu/MenuModel.swift Common/Swift/Menu/MenuScreen.swift Common/Swift/Menu/MenuFocusRouter.swift DolphiniOSTests/MenuModelTests.swift
git commit -m "feat(menu): MenuItem description, longPress and .cycle role"
```

---

### Task 2: Controller long-press of A

**Files:**
- Modify: `Common/Swift/Menu/MenuControllerNav.swift`
- Modify: `Common/Swift/Menu/MenuFocusRouter.swift` (`apply`, both `update`s, `MenuFocusUpdate`)
- Test: `DolphiniOSTests/MenuFocusRouterTests.swift`

**Interfaces:**
- Produces: `MenuControllerNav.Config.activateOnRelease: Bool` (default false), `.longPressDuration: TimeInterval` (0.5), `MenuControllerNav.Event.longActivate`, `MenuFocusUpdate.longActivatedID: String?`.

- [ ] **Step 1: Write the failing tests** (append to `MenuFocusRouterTests`)

```swift
  // MARK: Long-press A (tiles)

  private var tilesCfg: MenuControllerNav.Config {
    var c = cfg
    c.activateOnRelease = true
    c.longPressDuration = 0.5
    return c
  }

  func test_tiles_shortPress_activatesOnRelease() {
    var router = MenuFocusRouter(config: tilesCfg)
    let model = twoSectionModel()
    var r = router.update(.init(a: true), at: 0, model: model, focusedID: "a", isActive: true)
    XCTAssertNil(r.activatedID, "press edge does nothing when activateOnRelease")
    r = router.update(.init(a: true), at: 0.2, model: model, focusedID: "a", isActive: true)
    XCTAssertNil(r.activatedID)
    r = router.update(.init(), at: 0.3, model: model, focusedID: "a", isActive: true)
    XCTAssertEqual(r.activatedID, "a", "release before the long-press threshold activates")
    XCTAssertNil(r.longActivatedID)
  }

  func test_tiles_longPress_firesOnce_andReleaseDoesNotActivate() {
    var router = MenuFocusRouter(config: tilesCfg)
    let model = twoSectionModel()
    _ = router.update(.init(a: true), at: 0, model: model, focusedID: "a", isActive: true)
    var r = router.update(.init(a: true), at: 0.55, model: model, focusedID: "a", isActive: true)
    XCTAssertEqual(r.longActivatedID, "a")
    r = router.update(.init(a: true), at: 1.0, model: model, focusedID: "a", isActive: true)
    XCTAssertNil(r.longActivatedID, "fires once per hold")
    r = router.update(.init(), at: 1.1, model: model, focusedID: "a", isActive: true)
    XCTAssertNil(r.activatedID, "the release after a long press is not a tap")
  }

  func test_list_defaultConfig_stillActivatesOnPressEdge() {
    var router = MenuFocusRouter(config: cfg)
    let r = router.update(.init(a: true), at: 0, model: twoSectionModel(), focusedID: "a", isActive: true)
    XCTAssertEqual(r.activatedID, "a")
  }

  func test_tiles_aHeldAtResync_neverActivatesOnRelease() {
    var router = MenuFocusRouter(config: tilesCfg)
    let model = twoSectionModel()
    router.resync(.init(a: true), at: 0)
    let r = router.update(.init(), at: 0.1, model: model, focusedID: "a", isActive: true)
    XCTAssertNil(r.activatedID, "the press that opened the screen must not activate on its release")
  }
```

- [ ] **Step 2: Run to verify failure** (`-only-testing:iCubeTests/MenuFocusRouterTests`). Expected: compile errors on `activateOnRelease`, `longActivatedID`.

- [ ] **Step 3: Implement**

`MenuControllerNav.Config`:
```swift
    /// Tiles: A activates on RELEASE (if shorter than `longPressDuration`) so a hold can mean
    /// something else. Lists keep the press-edge activate.
    var activateOnRelease = false
    var longPressDuration: TimeInterval = 0.5
```
`Event`: add `case longActivate`.
State: add `private var aDownAt: TimeInterval = 0` and `private var aLongFired = false`.
Replace the A block in `update`:
```swift
    if input.a {
      if !aLatched {
        aLatched = true
        aDownAt = time
        aLongFired = false
        if !config.activateOnRelease { events.append(.activate) }
      } else if config.activateOnRelease, !aLongFired, time - aDownAt >= config.longPressDuration {
        aLongFired = true
        events.append(.longActivate)
      }
    } else {
      if aLatched, config.activateOnRelease, !aLongFired { events.append(.activate) }
      aLatched = false
      aLongFired = false
    }
```
In `resync`, after `aLatched = input.a` add `aLongFired = input.a` (a hold adopted at resync never activates on its release).

`MenuFocusUpdate`: add `var longActivatedID: String?` and include it in `==`.
`MenuFocusRouter.apply`: add `var longActivated: String?`; `case .longActivate: if let current { longActivated = current }`; return it. Both `update`s pass it through (multi-pad: `if longActivated == nil { longActivated = padResult.longActivatedID }`).

- [ ] **Step 4: Run to verify pass**, then the full `MenuFocusRouterTests` and `RemapModelTests` (also a nav consumer).

- [ ] **Step 5: Commit**

```bash
git add Common/Swift/Menu/MenuControllerNav.swift Common/Swift/Menu/MenuFocusRouter.swift DolphiniOSTests/MenuFocusRouterTests.swift
git commit -m "feat(menu): long-press A event for tile menus"
```

---

### Task 3: MenuKit — theme, focus style, tile face, info shelf, back coalescer

**Files:**
- Create: `Common/Swift/MenuKit/MenuTheme.swift`, `FocusButtonStyle.swift`, `TileFace.swift`, `InfoShelf.swift`, `BackCoalescer.swift`
- Test: `DolphiniOSTests/BackCoalescerTests.swift`

**Interfaces:**
- Produces:
  ```swift
  protocol MenuTheme { var accent: Color; var tileFill: Material; var cornerRadius: CGFloat; var focusRingWidth: CGFloat; var focusScale: CGFloat; var tileMinHeight: CGFloat; var shelfHeight: CGFloat }
  struct ICubeTheme: MenuTheme
  extension EnvironmentValues { var menuTheme: any MenuTheme }
  struct FocusButtonStyle: ButtonStyle { var isFocusedOverride: Bool? }
  struct TileFace: View { init(icon: String?, title: String, badge: String?, tint: Color, isDestructive: Bool, isEnabled: Bool) }
  struct InfoShelf: View { init(text: String?, value: String?) }
  enum BackCoalescer { static let window: TimeInterval; static func shouldHonor(openedAt: Date, now: Date) -> Bool }
  ```

- [ ] **Step 1: Write the failing test**

```swift
// DolphiniOSTests/BackCoalescerTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// Spec §4.1: the release of the press that opened a menu arrives as an exit/back command on tvOS and
/// must not close it. Everything after the window is honoured.
final class BackCoalescerTests: XCTestCase {
  func test_backInsideWindow_isDropped() {
    let opened = Date(timeIntervalSinceReferenceDate: 100)
    XCTAssertFalse(BackCoalescer.shouldHonor(openedAt: opened, now: opened.addingTimeInterval(0.1)))
  }

  func test_backAfterWindow_isHonoured() {
    let opened = Date(timeIntervalSinceReferenceDate: 100)
    XCTAssertTrue(BackCoalescer.shouldHonor(openedAt: opened, now: opened.addingTimeInterval(BackCoalescer.window)))
  }
}
```

- [ ] **Step 2: Regenerate, run, verify failure** (`-only-testing:iCubeTests/BackCoalescerTests`). Expected: `BackCoalescer` not found.

- [ ] **Step 3: Write the kit**

```swift
// Common/Swift/MenuKit/MenuTheme.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The few tokens the menu kit draws with (unified menu UX spec §4.1). One palette; ported from iFly's
/// Theme protocol with the Dreamcast branding removed. iCube keeps its blurred cover-art backdrop and
/// material tiles, so the theme never owns a background colour.
protocol MenuTheme {
  var accent: Color { get }
  var tileFill: Material { get }
  var cornerRadius: CGFloat { get }
  var focusRingWidth: CGFloat { get }
  var focusScale: CGFloat { get }
  var tileMinHeight: CGFloat { get }
  var shelfHeight: CGFloat { get }
}

struct ICubeTheme: MenuTheme {
  var accent: Color = .accentColor
  var tileFill: Material = .ultraThinMaterial
  var cornerRadius: CGFloat = 16
  var focusRingWidth: CGFloat = 4
  var focusScale: CGFloat = 1.06
  #if os(tvOS)
  var tileMinHeight: CGFloat = 180
  var shelfHeight: CGFloat = 80
  #else
  var tileMinHeight: CGFloat = 96
  var shelfHeight: CGFloat = 56
  #endif
}

private struct MenuThemeKey: EnvironmentKey {
  static let defaultValue: any MenuTheme = ICubeTheme()
}

extension EnvironmentValues {
  var menuTheme: any MenuTheme {
    get { self[MenuThemeKey.self] }
    set { self[MenuThemeKey.self] = newValue }
  }
}
```

```swift
// Common/Swift/MenuKit/FocusButtonStyle.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Accent ring, scale and spring on focus, identical on both platforms.
///
/// `@Environment(\.isFocused)` is only correct when read INSIDE `makeBody` (iFly's finding); read in an
/// outer modifier it lags or never updates on tvOS. iOS has no focus engine for a game pad, so the
/// polled focus is passed in as `isFocusedOverride`.
struct FocusButtonStyle: ButtonStyle {
  var isFocusedOverride: Bool? = nil
  @Environment(\.isFocused) private var isFocused
  @Environment(\.menuTheme) private var theme

  func makeBody(configuration: Configuration) -> some View {
    let focused = isFocusedOverride ?? isFocused
    configuration.label
      .overlay(
        RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
          .stroke(theme.accent, lineWidth: focused ? theme.focusRingWidth : 0)
      )
      .scaleEffect(focused ? theme.focusScale : 1)
      .zIndex(focused ? 1 : 0)
      .opacity(configuration.isPressed ? 0.85 : 1)
      .animation(.spring(response: 0.3, dampingFraction: 0.7), value: focused)
      #if os(tvOS)
      .focusEffectDisabled()
      #endif
  }
}
```

```swift
// Common/Swift/MenuKit/TileFace.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// One tile: icon badge top-left, value badge top-right, title bottom. The host wraps it in a `Button`
/// with `FocusButtonStyle`; the face itself has no gesture.
struct TileFace: View {
  let icon: String?
  let title: String
  let badge: String?
  let tint: Color
  let isDestructive: Bool
  let isEnabled: Bool
  @Environment(\.menuTheme) private var theme

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top) {
        if let icon {
          Image(systemName: icon)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(isDestructive ? .red : tint)
            .frame(width: 44, height: 44)
            .background(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((isDestructive ? Color.red : tint).opacity(0.15))
            )
        }
        Spacer(minLength: 0)
        if let badge, !badge.isEmpty {
          Text(badge)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.18)))
        }
      }
      Spacer(minLength: 0)
      Text(title)
        .font(.headline)
        .foregroundStyle(isDestructive ? .red : .white)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: theme.tileMinHeight, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        .fill(theme.tileFill)
        .overlay(
          RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
            .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    )
    .opacity(isEnabled ? 1 : 0.45)
  }
}
```

```swift
// Common/Swift/MenuKit/InfoShelf.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Fixed-height bar under a tile grid: the focused item's description, and its current value when it
/// has one. Keeps its height when there is nothing to say so the grid never jumps.
struct InfoShelf: View {
  let text: String?
  let value: String?
  @Environment(\.menuTheme) private var theme

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "info.circle")
        .foregroundStyle(.white.opacity(0.7))
      Text(text ?? " ")
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(3)
      Spacer(minLength: 0)
      if let value, !value.isEmpty {
        Text(value)
          .font(.subheadline.weight(.semibold))
          .monospacedDigit()
          .foregroundStyle(.white)
      }
    }
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity, minHeight: theme.shelfHeight, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        .fill(theme.tileFill)
    )
  }
}
```

```swift
// Common/Swift/MenuKit/BackCoalescer.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// On tvOS the release of the press that opened a menu can arrive as an exit command and close it
/// again. Drop back/exit for a short window after opening.
enum BackCoalescer {
  static let window: TimeInterval = 0.25

  static func shouldHonor(openedAt: Date, now: Date) -> Bool {
    now.timeIntervalSince(openedAt) >= window
  }
}
```

- [ ] **Step 4: Run to verify pass**; build iOS and tvOS (commands in Global Constraints).

- [ ] **Step 5: Commit**

```bash
git add Common/Swift/MenuKit DolphiniOSTests/BackCoalescerTests.swift
git commit -m "feat(menukit): theme, focus button style, tile face, info shelf"
```

---

### Task 4: MenuScreen `.tiles` style with long-press picker and info shelf

**Files:**
- Modify: `Common/Swift/Menu/MenuScreen.swift`

**Interfaces:**
- Consumes: Task 1 (`effectiveLongPress`, `currentValueTitle`, `.cycle`), Task 2 (`longActivatedID`, `Config.activateOnRelease`), Task 3 (kit views).
- Produces: `MenuStyle.tiles(columns: Int)`; `MenuScreen.init(model:style:onBack:modal:)` (explicit, same labels as the memberwise one).

- [ ] **Step 1: Add the style and the explicit init**

```swift
enum MenuStyle: Equatable {
  case grid
  case list
  /// Pause-overlay tiles (unified menu UX spec §5): `columns` per row, an `InfoShelf` beneath, rendered
  /// natively on BOTH platforms (unlike `.grid`/`.list`, which tvOS flattens to a `List`).
  case tiles(columns: Int)

  var columns: Int {
    switch self {
    case .tiles(let columns): return max(1, columns)
    case .grid, .list: return 1
    }
  }

  var navConfig: MenuControllerNav.Config {
    var config = MenuControllerNav.Config()
    if case .tiles = self { config.activateOnRelease = true }
    return config
  }
}
```
`MenuScreen` gains:
```swift
  init(model: MenuModel, style: MenuStyle = .list, onBack: (() -> Void)? = nil, modal: MenuModal? = nil) {
    self.model = model
    self.style = style
    self.onBack = onBack
    self.modal = modal
    #if os(iOS)
    _router = State(initialValue: MenuFocusRouter(config: style.navConfig))
    #endif
  }
```
and the `@State private var router = MenuFocusRouter()` line loses its default value (`@State private var router: MenuFocusRouter`).

In `gridBody`'s `.onChange(of: columnCount, initial: true)` nothing changes; for tiles, `tick()` passes `style.columns` when `case .tiles`, `gridColumnCount` when `.grid`, 1 otherwise.

- [ ] **Step 2: Shared state for the long-press picker**

```swift
  /// A long-press picker up over the tiles. Rows are frozen underneath: the nested `MenuScreen`
  /// claims the controller scope on iOS; on tvOS it is the focused subtree.
  private struct LongPressPicker: Identifiable {
    let id: String   // the item id
    let title: String
    let options: [(String, AnyHashable)]
    let selection: Binding<AnyHashable>
  }
  @State private var longPressPicker: LongPressPicker?
  /// Set by a touch/remote long-press so the Button action that fires on the same release is ignored once.
  @State private var suppressActivateFor: String?

  private func runLongPress(_ item: MenuItem) {
    guard item.isEnabled, let longPress = item.effectiveLongPress else { return }
    suppressActivateFor = item.id
    switch longPress {
    case .action(let run): run()
    case .options(let title, let options, let selection):
      longPressPicker = LongPressPicker(id: item.id, title: title, options: options, selection: selection)
    }
  }

  private func activateFromButton(_ item: MenuItem) {
    if suppressActivateFor == item.id {
      suppressActivateFor = nil
      return
    }
    performActivate(item)
  }

  private var longPressPickerModel: MenuModel {
    guard let picker = longPressPicker else { return MenuModel() }
    let items = picker.options.map { option in
      MenuItem(
        id: "\(picker.id)#\(option.1)", title: option.0,
        icon: option.1 == picker.selection.wrappedValue ? "checkmark" : nil,
        role: .action {
          picker.selection.wrappedValue = option.1
          longPressPicker = nil
        })
    }
    return MenuModel(sections: [MenuSection(id: "long-press", items: items)])
  }

  @ViewBuilder
  private func longPressOverlay() -> some View {
    if let picker = longPressPicker {
      ZStack {
        Color.black.opacity(0.55).ignoresSafeArea()
        VStack(alignment: .leading, spacing: 8) {
          Text(picker.title).font(.headline).foregroundStyle(.white)
          MenuScreen(model: longPressPickerModel, style: .list, onBack: { longPressPicker = nil })
            .frame(maxHeight: CGFloat(picker.options.count) * 64 + 24)
        }
        .padding(16)
        .frame(maxWidth: 420)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
        .padding(24)
        #if os(tvOS)
        .focusSection()
        #endif
      }
      .transition(.opacity)
    }
  }
```
`content` wraps every style's body in `ZStack { body; longPressOverlay() }`.

- [ ] **Step 3: iOS tiles body**

```swift
  #if os(iOS)
  private var tilesBody: some View {
    let columns = style.columns
    return VStack(spacing: 12) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          ForEach(model.sections) { section in
            if let header = section.header {
              Text(header).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
              ForEach(section.items) { item in tile(item, focused: focusedID == item.id) }
            }
          }
        }
        .padding(16)
      }
      InfoShelf(text: focusedItem?.description, value: focusedItem?.currentValueTitle)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
  }

  private var focusedItem: MenuItem? { focusedID.flatMap { model.item(id: $0) } }
  #endif

  private func tile(_ item: MenuItem, focused: Bool) -> some View {
    let isDestructive: Bool = { if case .destructive = item.role { return true } else { return false } }()
    return Button { activateFromButton(item) } label: {
      TileFace(
        icon: item.icon, title: item.title, badge: item.currentValueTitle ?? item.badge,
        tint: item.tint ?? .accentColor, isDestructive: isDestructive, isEnabled: item.isEnabled)
    }
    .buttonStyle(FocusButtonStyle(isFocusedOverride: focused))
    .disabled(!item.isEnabled)
    .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in runLongPress(item) })
    .id(item.id)
  }
```
On iOS `tick()` additionally handles `result.longActivatedID`: `if let id = result.longActivatedID, let item = model.item(id: id) { runLongPress(item) }` — and because the nav path never fires the Button action, clear `suppressActivateFor = nil` right after that call on this path.

- [ ] **Step 4: tvOS tiles body**

Eager rows (the focus engine must see every tile) and native focus:
```swift
  #if os(tvOS)
  private var tvTilesBody: some View {
    let columns = style.columns
    return VStack(spacing: 20) {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          ForEach(model.sections) { section in
            if let header = section.header {
              Text(header).font(.headline).foregroundStyle(.white.opacity(0.7))
            }
            ForEach(Array(section.items.chunked(into: columns).enumerated()), id: \.offset) { _, row in
              HStack(spacing: 24) {
                ForEach(row) { item in
                  tile(item, focused: tvFocusedID == item.id)
                    .focused($tvFocusedID, equals: item.id)
                }
                ForEach(0 ..< max(0, columns - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
              }
            }
          }
        }
        .padding(24)
      }
      .focusSection()
      InfoShelf(text: tvFocusedItem?.description, value: tvFocusedItem?.currentValueTitle)
        .padding(.horizontal, 24)
    }
  }

  private var tvFocusedItem: MenuItem? { tvFocusedID.flatMap { model.item(id: $0) } }
  #endif
```
`FocusButtonStyle` reads `isFocused` itself on tvOS; passing `focused:` there is harmless and keeps one `tile(_:focused:)`. Add a small `Array.chunked(into:)` extension in `MenuScreen.swift` (private):
```swift
private extension Array {
  func chunked(into size: Int) -> [[Element]] {
    stride(from: 0, to: count, by: Swift.max(1, size)).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
  }
}
```
`tvListBody`'s `defaultFocus` logic is reused: in `content`, `case .tiles: tvTilesBody.defaultFocus($tvFocusedID, model.focusableIDs.first)` when there is a first id. tvOS d-pad left/right on a `.cycle` tile: add `.onMoveCommand` to the tile on tvOS that steps the value for `.cycle` items (left: -1, right: +1) and lets other directions fall through (`default: break` — the focus engine still moves focus because `onMoveCommand` on a focused Button does not consume moves it does not handle; verify on device, and if focus stops moving, restrict the modifier to `.cycle` tiles only).

- [ ] **Step 5: Build both platforms**; run `MenuModelTests`, `MenuFocusRouterTests`, `PauseMenuModelBuilderTests` (unchanged behaviour for `.grid` and `.list`).

- [ ] **Step 6: Commit**

```bash
git add Common/Swift/Menu/MenuScreen.swift
git commit -m "feat(menu): MenuScreen .tiles style with info shelf and long-press picker"
```

---

### Task 5: Quick-action helpers — shader cycle and paused screenshot

**Files:**
- Create: `Common/Swift/Shaders/ShaderQuickApply.swift`
- Modify: `Common/Swift/Shaders/ShaderQuickPickerView.swift:337-376`
- Modify: `Common/Swift/TopBar/QuickScreenshot.swift`
- Test: create `DolphiniOSTests/ShaderQuickApplyTests.swift`; extend `DolphiniOSTests/QuickScreenshotTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum ShaderQuickApply {
    static let noneValue: AnyHashable          // AnyHashable("")
    static var currentPath: String?            // UserDefaults "shader_preset_path"
    static func displayName(forPath: String) -> String
    static func options(mru: [String], current: String?) -> [(String, AnyHashable)]   // "None" first
    static func apply(path: String?)           // live apply + defaults + MRU; nil = None
    static func pushMRU(_ normalized: String, defaults: UserDefaults = .standard)
  }
  // QuickScreenshot gains:
  static let pausePreviewFreshness: TimeInterval   // 60
  static func copyPausePreview(from preview: URL, to destination: URL, now: Date) -> Outcome
  static func saveFromPausePreview() -> Outcome
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// DolphiniOSTests/ShaderQuickApplyTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

final class ShaderQuickApplyTests: XCTestCase {
  func test_displayName_isFileNameWithoutExtension() {
    XCTAssertEqual(ShaderQuickApply.displayName(forPath: "/Shaders/crt/crt-royale.slangp"), "crt-royale")
  }

  func test_options_noneFirst_thenMRU_withCurrentIncluded() {
    let options = ShaderQuickApply.options(mru: ["/a/one.slangp", "/b/two.slangp"], current: "/c/three.slangp")
    XCTAssertEqual(options.map(\.0), ["None", "three", "one", "two"])
    XCTAssertEqual(options.first?.1, ShaderQuickApply.noneValue)
    XCTAssertEqual(options[1].1, AnyHashable("/c/three.slangp"))
  }

  func test_options_currentAlreadyInMRU_isNotDuplicated() {
    let options = ShaderQuickApply.options(mru: ["/a/one.slangp"], current: "/a/one.slangp")
    XCTAssertEqual(options.map(\.0), ["None", "one"])
  }

  func test_pushMRU_frontInsertsDedupesAndCaps() {
    let defaults = UserDefaults(suiteName: "ShaderQuickApplyTests")!
    defaults.removePersistentDomain(forName: "ShaderQuickApplyTests")
    for i in 0 ..< 12 { ShaderQuickApply.pushMRU("/p/\(i).slangp", defaults: defaults) }
    ShaderQuickApply.pushMRU("/p/5.slangp", defaults: defaults)
    let list = defaults.stringArray(forKey: "shader_mru") ?? []
    XCTAssertEqual(list.count, 10)
    XCTAssertEqual(list.first, "/p/5.slangp")
    XCTAssertEqual(list.filter { $0 == "/p/5.slangp" }.count, 1)
  }
}
```
Append to `QuickScreenshotTests`:
```swift
  func test_copyPausePreview_freshFileIsCopied() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let preview = dir.appendingPathComponent("preview.png")
    try Data([1, 2, 3]).write(to: preview)
    let dest = dir.appendingPathComponent("shot.png")
    XCTAssertEqual(QuickScreenshot.copyPausePreview(from: preview, to: dest, now: Date()), .saved)
    XCTAssertEqual(try Data(contentsOf: dest), Data([1, 2, 3]))
  }

  func test_copyPausePreview_staleFileIsRefused() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let preview = dir.appendingPathComponent("preview.png")
    try Data([1]).write(to: preview)
    let later = Date().addingTimeInterval(QuickScreenshot.pausePreviewFreshness + 1)
    XCTAssertEqual(QuickScreenshot.copyPausePreview(from: preview, to: dir.appendingPathComponent("x.png"), now: later), .pausedNoFrame)
  }
```

- [ ] **Step 2: Regenerate, run, verify failure** (`ShaderQuickApplyTests`, `QuickScreenshotTests`).

- [ ] **Step 3: Implement**

```swift
// Common/Swift/Shaders/ShaderQuickApply.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The apply/MRU logic `ShaderQuickPickerView` had inline, shared with the pause overlay's Shaders
/// tile, which cycles through the recently used presets (unified menu UX spec §5.2).
enum ShaderQuickApply {
  static let noneValue: AnyHashable = AnyHashable("")
  static let mruKey = "shader_mru"
  static let presetPathKey = "shader_preset_path"
  static let enabledKey = "shader_enabled"
  static let mruLimit = 10

  static var currentPath: String? { UserDefaults.standard.string(forKey: presetPathKey) }

  static func displayName(forPath path: String) -> String {
    URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
  }

  /// "None", then the current preset (if any) and the MRU list, deduplicated, in that order.
  static func options(mru: [String], current: String?) -> [(String, AnyHashable)] {
    var paths: [String] = []
    if let current, !current.isEmpty { paths.append(current) }
    for path in mru where !paths.contains(path) { paths.append(path) }
    return [(L("None"), noneValue)] + paths.map { (displayName(forPath: $0), AnyHashable($0)) }
  }

  /// Applies to the live pipeline and persists. `nil` is "None": clears the preset without touching
  /// `shader_enabled` (turning one shader off is not disabling the feature).
  static func apply(path: String?) {
    let defaults = UserDefaults.standard
    guard let path, !path.isEmpty else {
      defaults.removeObject(forKey: presetPathKey)
      NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
      DOLShaderPostProcessor.shared.applyPresetPath(nil)
      return
    }
    let normalized = ShaderLibrary.normalizedPath(path)
    defaults.set(true, forKey: enabledKey)
    defaults.set(normalized, forKey: presetPathKey)
    NotificationCenter.default.post(name: Notification.Name("DOLShaderSettingsDidChange"), object: nil)
    DOLShaderPostProcessor.shared.applyPresetPath(normalized)
    pushMRU(normalized)
  }

  static func pushMRU(_ normalized: String, defaults: UserDefaults = .standard) {
    var list = (defaults.stringArray(forKey: mruKey) ?? []).filter { $0 != normalized }
    list.insert(normalized, at: 0)
    if list.count > mruLimit { list = Array(list.prefix(mruLimit)) }
    defaults.set(list, forKey: mruKey)
  }
}
```
`ShaderQuickPickerView.apply(_:)` becomes:
```swift
  private func apply(_ preset: ShaderPreset?) {
    guard let preset else {
      currentPath = nil
      ShaderQuickApply.apply(path: nil)
      return
    }
    let normalized = ShaderLibrary.normalizedPath(preset.id.path)
    currentPath = normalized
    enabled = true
    ShaderQuickApply.apply(path: normalized)
    mru = UserDefaults.standard.stringArray(forKey: ShaderQuickApply.mruKey) ?? []
  }
```
and its private `pushMRU` is deleted. Check `ShaderLibrary.normalizedPath` is callable from a non-view context (it is a static).

`QuickScreenshot` additions:
```swift
  /// How old the pause preview may be and still count as "the current frame" (same window
  /// `SaveStateService` uses for save thumbnails).
  static let pausePreviewFreshness: TimeInterval = 60

  /// The pause overlay's Screenshot tile: the core writes no frame while paused, but the pause preview
  /// (`SaveStateService.capturePausePreview`) is the last live one. `.pausedNoFrame` when it is stale.
  static func copyPausePreview(from preview: URL, to destination: URL, now: Date) -> Outcome {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: preview.path),
          let modified = attrs[.modificationDate] as? Date,
          now.timeIntervalSince(modified) < pausePreviewFreshness else { return .pausedNoFrame }
    do {
      try FileManager.default.copyItem(at: preview, to: destination)
      return .saved
    } catch {
      return .failed
    }
  }

  @MainActor
  static func saveFromPausePreview(now: Date = Date()) -> Outcome {
    guard let gameID = SaveStateService.currentGameID,
          let userDirectory = DolphinPaths.userDirectoryURL(),
          let url = destination(gameID: gameID, date: now, userDirectory: userDirectory) else { return .failed }
    return copyPausePreview(from: SaveStateService.pausePreviewURL, to: url, now: now)
  }
```

- [ ] **Step 4: Run to verify pass**; build both platforms.

- [ ] **Step 5: Commit**

```bash
git add Common/Swift/Shaders/ShaderQuickApply.swift Common/Swift/Shaders/ShaderQuickPickerView.swift Common/Swift/TopBar/QuickScreenshot.swift DolphiniOSTests/ShaderQuickApplyTests.swift DolphiniOSTests/QuickScreenshotTests.swift
git commit -m "feat(pause): shader quick-apply helper and paused screenshot from preview"
```

---

### Task 6: PauseTileLayout and the new PauseMenuModelBuilder

**Files:**
- Create: `Common/Swift/PauseTileLayout.swift`
- Modify: `Common/Swift/PauseMenuView.swift:1420-1500` (`PauseMenuState`, `PauseMenuActions`, `PauseMenuModelBuilder`)
- Test: create `DolphiniOSTests/PauseTileLayoutTests.swift`; rewrite `DolphiniOSTests/PauseMenuModelBuilderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum PauseTileLayout { static func columns(forWidth: CGFloat, isTV: Bool) -> Int }
  struct PauseMenuState {
    var quickSlot: Int; var isMuted: Bool; var activeCheatCount: Int
    var shaderOptions: [(String, AnyHashable)]; var showsRecenterPointer: Bool
  }
  struct PauseMenuBindings {
    var mute: Binding<Bool>; var fastForward: Binding<AnyHashable>
    var quickSlot: Binding<AnyHashable>; var shader: Binding<AnyHashable>
  }
  struct PauseMenuActions {
    var resume, quickSave, quickLoad, screenshot, openSaveStates, openCheats, openControllers,
        openShaders, openContinuity, openSettings, requestReset, requestExit, recenterPointer: () -> Void
  }
  enum PauseMenuModelBuilder {
    static let fastForwardOff: AnyHashable          // AnyHashable(-1)
    static let fastForwardOptions: [(String, AnyHashable)]   // Off, 2x, 4x, 8x, Unlimited(0)
    static func make(state: PauseMenuState, bindings: PauseMenuBindings, actions: PauseMenuActions) -> MenuModel
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// DolphiniOSTests/PauseTileLayoutTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// Spec §5.1: 6 columns on tvOS, 3 on an iPhone in portrait, 4 in landscape, 4–6 on iPad by width.
final class PauseTileLayoutTests: XCTestCase {
  func test_tv_isAlwaysSix() {
    XCTAssertEqual(PauseTileLayout.columns(forWidth: 1920, isTV: true), 6)
    XCTAssertEqual(PauseTileLayout.columns(forWidth: 100, isTV: true), 6)
  }

  func test_phonePortrait_three_landscape_four() {
    XCTAssertEqual(PauseTileLayout.columns(forWidth: 393, isTV: false), 3)
    XCTAssertEqual(PauseTileLayout.columns(forWidth: 852, isTV: false), 4)
  }

  func test_ipad_fourToSixByWidth() {
    XCTAssertEqual(PauseTileLayout.columns(forWidth: 744, isTV: false), 4)
    XCTAssertEqual(PauseTileLayout.columns(forWidth: 1024, isTV: false), 5)
    XCTAssertEqual(PauseTileLayout.columns(forWidth: 1366, isTV: false), 6)
  }
}
```
Replace `PauseMenuModelBuilderTests` wholesale:
```swift
// DolphiniOSTests/PauseMenuModelBuilderTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

/// `PauseMenuModelBuilder` (unified menu UX spec §5): pure builder, three sections, every tile described.
final class PauseMenuModelBuilderTests: XCTestCase {
  private final class Box { var value: AnyHashable; init(_ v: AnyHashable) { value = v } }

  private func bindings(ff: Box = Box(PauseMenuModelBuilder.fastForwardOff), slot: Box = Box(3), muted: Box = Box(false), shader: Box = Box(ShaderQuickApply.noneValue)) -> PauseMenuBindings {
    PauseMenuBindings(
      mute: Binding(get: { muted.value as? Bool ?? false }, set: { muted.value = $0 }),
      fastForward: Binding(get: { ff.value }, set: { ff.value = $0 }),
      quickSlot: Binding(get: { slot.value }, set: { slot.value = $0 }),
      shader: Binding(get: { shader.value }, set: { shader.value = $0 }))
  }

  private var log: [String] = []
  private func actions() -> PauseMenuActions {
    PauseMenuActions(
      resume: { self.log.append("resume") }, quickSave: { self.log.append("save") }, quickLoad: { self.log.append("load") },
      screenshot: { self.log.append("shot") }, openSaveStates: {}, openCheats: {}, openControllers: {},
      openShaders: { self.log.append("shaders") }, openContinuity: {}, openSettings: {}, requestReset: {},
      requestExit: {}, recenterPointer: {})
  }

  private func state(recenter: Bool = false, cheats: Int = 0) -> PauseMenuState {
    PauseMenuState(
      quickSlot: 3, isMuted: false, activeCheatCount: cheats,
      shaderOptions: [("None", ShaderQuickApply.noneValue), ("crt", AnyHashable("/s/crt.slangp"))],
      showsRecenterPointer: recenter)
  }

  func test_threeSections_inOrder_withExpectedTiles() {
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    XCTAssertEqual(model.sections.map(\.id), ["quick", "game", "system"])
    XCTAssertEqual(model.sections[0].items.map(\.id), ["resume", "quick-save", "quick-load", "fast-forward", "mute", "screenshot"])
    XCTAssertEqual(model.sections[1].items.map(\.id), ["save-states", "cheats", "shaders", "controllers", "continuity"])
    XCTAssertEqual(model.sections[2].items.map(\.id), ["settings", "reset", "exit"])
  }

  func test_everyTile_hasADescription() {
    let model = PauseMenuModelBuilder.make(state: state(recenter: true), bindings: bindings(), actions: actions())
    for item in model.allItems {
      XCTAssertFalse((item.description ?? "").isEmpty, "\(item.id) has no description")
    }
  }

  func test_recenterPointer_onlyWhenFlagged() {
    let without = PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    XCTAssertNil(without.item(id: "recenter-pointer"))
    let with = PauseMenuModelBuilder.make(state: state(recenter: true), bindings: bindings(), actions: actions())
    XCTAssertEqual(with.sections[1].items.map(\.id), ["save-states", "cheats", "shaders", "controllers", "continuity", "recenter-pointer"])
  }

  func test_fastForward_isACycle_offFirst_fiveOptions() {
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    guard case .cycle(let options, _)? = model.item(id: "fast-forward")?.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["Off", "2x", "4x", "8x", "Unlimited"])
    XCTAssertEqual(options.map(\.1), [AnyHashable(-1), AnyHashable(200), AnyHashable(400), AnyHashable(800), AnyHashable(0)])
  }

  func test_quickSave_badgeIsSlot_andLongPressOffersTenSlots() {
    let slot = Box(3)
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(slot: slot), actions: actions())
    let item = model.item(id: "quick-save")!
    XCTAssertEqual(item.badge, "Slot 3")
    guard case .options(_, let options, let selection)? = item.effectiveLongPress else { return XCTFail("slot picker") }
    XCTAssertEqual(options.count, 10)
    selection.wrappedValue = AnyHashable(7)
    XCTAssertEqual(slot.value, AnyHashable(7))
    if case .action(let run) = item.role { run() }
    XCTAssertEqual(log, ["save"])
  }

  func test_mute_isAToggle() {
    let muted = Box(false)
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(muted: muted), actions: actions())
    guard case .toggle(let binding)? = model.item(id: "mute")?.role else { return XCTFail("toggle") }
    binding.wrappedValue = true
    XCTAssertEqual(muted.value, AnyHashable(true))
  }

  func test_shaders_cyclesOptions_andLongPressOpensFullPicker() {
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    let item = model.item(id: "shaders")!
    guard case .cycle(let options, _) = item.role else { return XCTFail("cycle") }
    XCTAssertEqual(options.map(\.0), ["None", "crt"])
    guard case .action(let run)? = item.effectiveLongPress else { return XCTFail("explicit long press") }
    run()
    XCTAssertEqual(log, ["shaders"])
  }

  func test_cheatsBadge_showsActiveCount() {
    let model = PauseMenuModelBuilder.make(state: state(cheats: 3), bindings: bindings(), actions: actions())
    XCTAssertEqual(model.item(id: "cheats")?.badge, "3")
    let none = PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    XCTAssertNil(none.item(id: "cheats")?.badge)
  }

  func test_resetAndExit_areDestructive() {
    let model = PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
    for id in ["reset", "exit"] {
      guard case .destructive = model.item(id: id)!.role else { return XCTFail("\(id) destructive") }
    }
  }
}
```

- [ ] **Step 2: Regenerate, run, verify failure** (both classes).

- [ ] **Step 3: Implement**

```swift
// Common/Swift/PauseTileLayout.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreGraphics

/// Spec §5.1 column rule for the pause overlay's tile grid.
enum PauseTileLayout {
  static let tvColumns = 6

  static func columns(forWidth width: CGFloat, isTV: Bool) -> Int {
    if isTV { return tvColumns }
    switch width {
    case ..<600: return 3
    case ..<900: return 4
    case ..<1200: return 5
    default: return 6
    }
  }
}
```
Replace `PauseMenuState`, `PauseMenuActions` and `PauseMenuModelBuilder` in `PauseMenuView.swift`:
```swift
/// Plain snapshot — no bridge reads inside the builder.
struct PauseMenuState {
  var quickSlot: Int
  var isMuted: Bool
  var activeCheatCount: Int
  /// "None" first, then recent presets; the Shaders tile cycles these.
  var shaderOptions: [(String, AnyHashable)]
  /// Wii title on iOS, where the pointer is driven by touch or the gyro.
  var showsRecenterPointer: Bool
}

/// Live bindings for the in-place tiles. Writing one applies immediately; the host rebuilds the model.
struct PauseMenuBindings {
  var mute: Binding<Bool>
  var fastForward: Binding<AnyHashable>
  var quickSlot: Binding<AnyHashable>
  var shader: Binding<AnyHashable>
}

struct PauseMenuActions {
  var resume: () -> Void
  var quickSave: () -> Void
  var quickLoad: () -> Void
  var screenshot: () -> Void
  var openSaveStates: () -> Void
  var openCheats: () -> Void
  var openControllers: () -> Void
  var openShaders: () -> Void
  var openContinuity: () -> Void
  var openSettings: () -> Void
  var requestReset: () -> Void
  var requestExit: () -> Void
  var recenterPointer: () -> Void
}

/// Unified menu UX spec §5: Quick / Game / System. Shared by iOS and tvOS.
enum PauseMenuModelBuilder {
  static let fastForwardOff: AnyHashable = AnyHashable(-1)
  static let fastForwardOptions: [(String, AnyHashable)] = [
    (L("Off"), fastForwardOff), ("2x", AnyHashable(200)), ("4x", AnyHashable(400)), ("8x", AnyHashable(800)), (L("Unlimited"), AnyHashable(0)),
  ]
  static let slotCount = 10

  static func make(state: PauseMenuState, bindings: PauseMenuBindings, actions: PauseMenuActions) -> MenuModel {
    let slotOptions: [(String, AnyHashable)] = (1 ... slotCount).map { (String(format: L("Slot %d"), $0), AnyHashable($0)) }
    let slotBadge = String(format: L("Slot %d"), state.quickSlot)
    let slotPicker = MenuLongPress.options(title: L("Quick Slot"), options: slotOptions, selection: bindings.quickSlot)

    let quick = MenuSection(id: "quick", header: L("Quick"), items: [
      MenuItem(id: "resume", title: L("Resume"), icon: "play.fill", tint: .blue, role: .action(actions.resume),
               description: L("Return to the game.")),
      MenuItem(id: "quick-save", title: L("Quick Save"), icon: "square.and.arrow.down", tint: .green, role: .action(actions.quickSave),
               badge: slotBadge, description: L("Save to the quick slot. Long-press to choose the slot."), longPress: slotPicker),
      MenuItem(id: "quick-load", title: L("Quick Load"), icon: "square.and.arrow.up", tint: .green, role: .action(actions.quickLoad),
               badge: slotBadge, description: L("Load the quick slot. Long-press to choose the slot."), longPress: slotPicker),
      MenuItem(id: "fast-forward", title: L("Fast Forward"), icon: "forward.fill", tint: .cyan,
               role: .cycle(options: fastForwardOptions, selection: bindings.fastForward),
               description: L("Tap to cycle the speed. Long-press to pick one. Takes effect on resume.")),
      MenuItem(id: "mute", title: L("Mute"), icon: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", tint: .cyan,
               role: .toggle(bindings.mute), description: L("Silence the game's audio.")),
      MenuItem(id: "screenshot", title: L("Screenshot"), icon: "camera", tint: .pink, role: .action(actions.screenshot),
               description: L("Save the last frame to ScreenShots.")),
    ])

    var game: [MenuItem] = [
      MenuItem(id: "save-states", title: L("Save States"), icon: "square.stack.3d.up", tint: .purple, role: .action(actions.openSaveStates),
               description: L("Save, load and browse every slot.")),
      MenuItem(id: "cheats", title: L("Cheats"), icon: "star.circle", tint: .yellow, role: .action(actions.openCheats),
               badge: state.activeCheatCount > 0 ? "\(state.activeCheatCount)" : nil,
               description: L("Enable Gecko and Action Replay codes for this game.")),
      MenuItem(id: "shaders", title: L("Shaders"), icon: "wand.and.stars", tint: .orange,
               role: .cycle(options: state.shaderOptions, selection: bindings.shader),
               description: L("Tap to cycle recent shaders. Long-press for the full picker."),
               longPress: .action(actions.openShaders)),
      MenuItem(id: "controllers", title: L("Controllers"), icon: "gamecontroller", tint: .green, role: .action(actions.openControllers),
               description: L("Players, devices and what each one plays as.")),
      MenuItem(id: "continuity", title: L("Continue Elsewhere"), icon: "arrow.triangle.branch", tint: .teal, role: .action(actions.openContinuity),
               description: L("Hand this game to a nearby device.")),
    ]
    if state.showsRecenterPointer {
      game.append(MenuItem(id: "recenter-pointer", title: L("Recenter Pointer"), icon: "scope", tint: .green, role: .action(actions.recenterPointer),
                           description: L("Center the Wii pointer on how you hold the device.")))
    }

    let system = MenuSection(id: "system", header: L("System"), items: [
      MenuItem(id: "settings", title: L("Settings"), icon: "gearshape", tint: .gray, role: .action(actions.openSettings),
               description: L("Game and system options.")),
      MenuItem(id: "reset", title: L("Reset"), icon: "arrow.counterclockwise.circle", tint: .orange, role: .destructive(actions.requestReset),
               description: L("Restart the game from power-on. Unsaved progress is lost.")),
      MenuItem(id: "exit", title: L("Exit"), icon: "xmark.circle", tint: .red, role: .destructive(actions.requestExit),
               description: L("Return to the library. Unsaved progress is lost.")),
    ])
    return MenuModel(sections: [quick, MenuSection(id: "game", header: L("Game"), items: game), system])
  }
}
```

- [ ] **Step 4: Run to verify pass** (`PauseTileLayoutTests`, `PauseMenuModelBuilderTests`). `PauseMenuView` itself still calls the old `make(state:actions:)` until Task 7; comment that call out only if the build blocks the tests, and restore it in Task 7.

- [ ] **Step 5: Commit**

```bash
git add Common/Swift/PauseTileLayout.swift Common/Swift/PauseMenuView.swift DolphiniOSTests/PauseTileLayoutTests.swift DolphiniOSTests/PauseMenuModelBuilderTests.swift
git commit -m "feat(pause): three-section pause model with cycle tiles and descriptions"
```

---

### Task 7: PauseMenuView — one root for both platforms

**Files:**
- Modify: `Common/Swift/PauseMenuView.swift` (root body, `mainMenu`, actions/bindings, deletions)
- Modify: `Common/Swift/EmulationScreen.swift:538-566` (tvOS cover: nothing structural; leave the speedometer button)

**Interfaces:**
- Consumes: `PauseMenuModelBuilder.make(state:bindings:actions:)`, `PauseTileLayout`, `MenuScreen(.tiles)`, `BackCoalescer`, `QuickSlot`, `QuickMute`, `QuickScreenshot.saveFromPausePreview`, `ShaderQuickApply`, `PauseArbiter.shared.userResume()`, `EmulationToastOverlay`.

- [ ] **Step 1: Delete the tvOS hand-built menu and the fast-forward pane**

Remove from `PauseMenuView.swift`: `tvMainMenu`, `tvMenuToggleRow`, `tvFastForwardChoiceRow`, `tvFastForwardSpeedMenu`, `settingsButtonRow`, `fastForwardConfirmModel`, `showFastForwardSpeedPicker`, `fastForwardSpeedChoices`, `fastForwardSubtitle`, `fastForwardSpeedLabel(percent:)`, the `.fastForwardSpeed` `Pane` case and its `switch` arms, the `FocusField` cases `.resume, .cheats, .mapping, .settings, .shaders, .continuity, .exit, .mute, .fastForward, .fastForwardOff, .fastForwardChoice` (keep `.openSaves, .back, .slot, .save, .load, .filmstrip` for the saves pane), the `.modifier(DefaultFocusCompat(focused: $focused, value: .resume))` line, `iosMainMenu`'s header/`MenuScreen(.grid)` block, and the `TvOSCard` struct. In `.onChange(of: pane)`, drop the `.main: focused = .resume` assignment (keep `refreshActiveCheatCount()`). `PauseMenuRow` (`Swift/Widgets/Pause Menu/PauseMenuRow.swift`) loses its only caller: delete the file.

- [ ] **Step 2: State, bindings and actions**

Add state:
```swift
  @State private var openedAt = Date()
  @State private var shaderOptions: [(String, AnyHashable)] = []
```
Fast-forward: keep `configuredFastForwardPercent`, `fastForwardEnabled`, `turnOffFastForward()`. Change `selectFastForwardSpeed` so it no longer resumes or closes:
```swift
  /// Persists `percent` and turns fast-forward on; the game picks it up when the player resumes.
  private func selectFastForwardSpeed(_ percent: Int) {
    TVEmulationBridge.setFastForwardSpeedPercent(percent)
    if !TVEmulationBridge.isFastForwardEnabled() { _ = TVEmulationBridge.toggleFastForward() }
    fastForwardEnabled = true
  }
```
Bindings and model:
```swift
  private var pauseMenuBindings: PauseMenuBindings {
    PauseMenuBindings(
      mute: Binding(get: { isMuted }, set: { _ in toggleMute() }),
      fastForward: Binding(
        get: { fastForwardEnabled ? AnyHashable(configuredFastForwardPercent) : PauseMenuModelBuilder.fastForwardOff },
        set: { value in
          if let percent = value as? Int, percent >= 0 { selectFastForwardSpeed(percent) } else { turnOffFastForward() }
        }),
      quickSlot: Binding(get: { AnyHashable(selectedSlot) }, set: { if let slot = $0 as? Int { selectedSlot = slot } }),
      shader: Binding(
        get: { AnyHashable(ShaderQuickApply.currentPath ?? "") },
        set: { value in
          let path = value as? String
          ShaderQuickApply.apply(path: (path?.isEmpty ?? true) ? nil : path)
          refreshShaderState()
        }))
  }

  private func refreshShaderState() {
    shaderOptions = ShaderQuickApply.options(
      mru: UserDefaults.standard.stringArray(forKey: ShaderQuickApply.mruKey) ?? [], current: ShaderQuickApply.currentPath)
  }

  private var pauseMenuModel: MenuModel {
    let state = PauseMenuState(
      quickSlot: selectedSlot,
      isMuted: isMuted,
      activeCheatCount: activeCheatCount,
      shaderOptions: shaderOptions,
      showsRecenterPointer: Self.showsRecenterPointer)
    let actions = PauseMenuActions(
      resume: { PauseArbiter.shared.userResume(); onClose() },
      quickSave: { _ = QuickSlot.save(slot: selectedSlot) },
      quickLoad: { QuickSlot.load(slot: selectedSlot) },
      screenshot: {
        switch QuickScreenshot.saveFromPausePreview() {
        case .saved: EmulationToast.post(L("Screenshot saved to ScreenShots"))
        case .pausedNoFrame: EmulationToast.post(L("No frame to save yet"))
        case .failed: EmulationToast.post(L("Screenshot failed"))
        }
      },
      openSaveStates: { pane = .saves },
      openCheats: { pane = .cheats },
      openControllers: {
        #if os(iOS)
        showControllersSheet = true
        #else
        pane = .controllers
        #endif
      },
      openShaders: { showShaders = true },
      openContinuity: { showContinuitySheet = true },
      openSettings: {
        #if os(iOS)
        showSettingsSheet = true
        #else
        onShowSettings()
        #endif
      },
      requestReset: { showResetDialog = true },
      requestExit: { showExitDialog = true },
      recenterPointer: {
        #if os(iOS)
        TCDeviceMotion.requestPointerRecenter()
        PauseArbiter.shared.userResume()
        onClose()
        #endif
      })
    return PauseMenuModelBuilder.make(state: state, bindings: pauseMenuBindings, actions: actions)
  }
```
In `.onAppear` add `refreshShaderState()` and `openedAt = Date()` (only when `pauseToken == nil`, i.e. the first appear). `.onChange(of: showShaders)` → when it turns false, `refreshShaderState()`.

- [ ] **Step 3: The shared root**

```swift
  @ViewBuilder
  private var mainMenu: some View {
    GeometryReader { proxy in
      let isTV = platform == .tvos
      let columns = PauseTileLayout.columns(forWidth: proxy.size.width, isTV: isTV)
      ZStack {
        backdrop
        if isTV {
          HStack(alignment: .top, spacing: 48) {
            coverColumn.frame(width: 220)
            tiles(columns: columns)
          }
          .padding(60)
        } else {
          VStack(alignment: .leading, spacing: 8) {
            compactHeader.padding(16)
            tiles(columns: columns)
          }
        }
        if showResetDialog {
          confirmOverlay(title: L("Reset System"),
                         message: L("Restart the game as if the console's reset button was pressed? Unsaved progress will be lost."),
                         model: resetConfirmModel, onBack: { showResetDialog = false })
        }
        if showExitDialog {
          confirmOverlay(title: L("Exit Game"), message: L("Do you want to quit the game? Unsaved progress will be lost."),
                         model: exitConfirmModel, onBack: { showExitDialog = false })
        }
        EmulationToastOverlay(barHeight: 0, barVisible: false)
      }
    }
  }

  private func tiles(columns: Int) -> some View {
    MenuScreen(model: pauseMenuModel, style: .tiles(columns: columns), onBack: {
      guard BackCoalescer.shouldHonor(openedAt: openedAt, now: Date()) else { return }
      onClose()
    })
  }

  private var backdrop: some View {
    ZStack {
      Image(uiImage: game.bannerImage ?? game.coverImage)
        .resizable().scaledToFill().blur(radius: 24).opacity(0.5).ignoresSafeArea()
      LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0.35), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
        .ignoresSafeArea()
    }
  }

  private var coverColumn: some View {
    VStack(alignment: .leading, spacing: 16) {
      Image(uiImage: game.coverImage)
        .resizable().aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: 220)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.6), radius: 20, x: 0, y: 10)
      Text(game.title).font(.title3.bold()).foregroundStyle(.white).lineLimit(2)
      Text(game.gameID).font(.caption).foregroundStyle(.white.opacity(0.7))
      Text(L("Paused")).font(.caption.weight(.semibold)).foregroundStyle(.white)
        .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Color.white.opacity(0.18)))
    }
  }

  private var compactHeader: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(uiImage: game.coverImage)
        .resizable().aspectRatio(2.0 / 3.0, contentMode: .fit).frame(width: 56)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(game.title).font(.headline).foregroundStyle(.white).lineLimit(1)
        Text(game.gameID).font(.caption).foregroundStyle(.white.opacity(0.7))
      }
      Spacer()
      Button(L("Close")) { onClose() }
        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(.ultraThinMaterial))
        .buttonStyle(.plain)
    }
  }
```
`confirmOverlay`'s height clamp becomes platform-aware:
```swift
        #if os(tvOS)
        MenuScreen(model: model, style: .list, onBack: onBack)
          .frame(maxHeight: CGFloat(model.allItems.count) * 110 + 40)
          .focusSection()
        #else
        MenuScreen(model: model, style: .grid, onBack: onBack)
          .frame(maxHeight: CGFloat(model.allItems.count) * 80 + 20)
        #endif
```
and its `.frame(maxWidth:)` is 380 on iOS, 640 on tvOS. The root `.onExitCommand` (tvOS) stays: `pane == .main ? onClose() : pane = .main`, but guarded by `BackCoalescer.shouldHonor(openedAt:now:)` for the `.main` case.

- [ ] **Step 4: Resolve `PlatformKind`/`platform` in the saves and tvOS panes**

Unchanged: `savesMenu`, `CheatsMenuView`, the tvOS `ControllerHubView` pane. The `#else` arms for `.controllers`/`.fastForwardSpeed` on iOS collapse to `case .controllers: mainMenu` (the iOS path never sets that pane).

- [ ] **Step 5: Build both platforms, run the full test target**

Expected: both builds succeed; `UILayerPauseCallsTests` still passes (no direct resume added); `PauseMenuModelBuilderTests` passes.

- [ ] **Step 6: Commit**

```bash
git add Common/Swift/PauseMenuView.swift
git rm Common/Swift/Widgets/Pause\ Menu/PauseMenuRow.swift
git commit -m "feat(pause): one tile-grid pause overlay for iOS and tvOS"
```

---

### Task 8: Snapshot renders

**Files:**
- Create: `DolphiniOSTests/PauseMenuSnapshotTests.swift`
- Modify: `Common/Swift/PauseMenuView.swift` (the `#if DEBUG` preview helper becomes `static func previewGame() -> TVGameItem`, internal)

- [ ] **Step 1: Expose the preview game**

Replace the private `makePreviewGame()` under `#if DEBUG` with
```swift
extension PauseMenuView {
  /// A stand-in `TVGameItem` for previews and snapshot tests.
  static func previewGame() -> TVGameItem {
    guard let cls = NSClassFromString("TVGameItem") as? NSObject.Type else {
      fatalError("TVGameItem class not found for preview")
    }
    let obj = cls.init()
    let img = UIImage(systemName: "gamecontroller")?.withTintColor(.white, renderingMode: .alwaysOriginal) ?? UIImage()
    obj.setValue("Preview Game", forKey: "title")
    obj.setValue("RMCP01", forKey: "gameID")
    obj.setValue(img, forKey: "coverImage")
    return unsafeBitCast(obj, to: TVGameItem.self)
  }
}
```
and update the two `#Preview`s to call `PauseMenuView.previewGame()`.

- [ ] **Step 2: Write the snapshot test** (modelled on `TopBarSnapshotTests`; skipped unless the env var is set)

```swift
// DolphiniOSTests/PauseMenuSnapshotTests.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS) && DEBUG
import SwiftUI
import UIKit
import XCTest

@testable import iCube

/// Renders the pause overlay at iPhone portrait/landscape and iPad widths to PNGs for eyeballing.
///   export TEST_RUNNER_PAUSE_MENU_SNAPSHOT_DIR=/tmp/shots
///   make test DEST="platform=iOS Simulator,id=<udid>" TEST_ARGS="-only-testing:iCubeTests/PauseMenuSnapshotTests"
@MainActor
final class PauseMenuSnapshotTests: XCTestCase {
  private static let outputDirKey = "PAUSE_MENU_SNAPSHOT_DIR"
  private static let sizes: [(String, CGSize)] = [
    ("iphone-portrait", CGSize(width: 393, height: 852)),
    ("iphone-landscape", CGSize(width: 852, height: 393)),
    ("ipad", CGSize(width: 1024, height: 768)),
  ]

  func testRenderPauseMenu() throws {
    guard let dir = ProcessInfo.processInfo.environment[Self.outputDirKey], !dir.isEmpty else {
      throw XCTSkip("set \(Self.outputDirKey) to render pause menu snapshots")
    }
    let outputDir = URL(fileURLWithPath: dir, isDirectory: true)
    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
    for (name, size) in Self.sizes {
      let view = PauseMenuView(selectedSlot: .constant(3), onClose: {}, onShowSettings: {}, platform: .ios, game: PauseMenuView.previewGame())
      let image = render(view, size: size, scene: scene)
      try XCTUnwrap(image.pngData()).write(to: outputDir.appendingPathComponent("pause-\(name).png"))
    }
  }

  private func render<V: View>(_ view: V, size: CGSize, scene: UIWindowScene) -> UIImage {
    let window = UIWindow(windowScene: scene)
    window.frame = CGRect(origin: .zero, size: size)
    let host = UIHostingController(rootView: view)
    host.safeAreaRegions = []
    window.rootViewController = host
    window.isHidden = false
    window.layoutIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let format = UIGraphicsImageRendererFormat()
    format.scale = 2
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
  }
}
#endif
```

- [ ] **Step 3: Regenerate and render**

Run:
```bash
export TEST_RUNNER_PAUSE_MENU_SNAPSHOT_DIR=/tmp/pause-shots
cd Source/iOS/App && tuist generate --no-open && make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/PauseMenuSnapshotTests"
```
Expected: three PNGs in `/tmp/pause-shots`. Open them: three sections, 3 columns on portrait, 4 on landscape, 5 on iPad, shelf at the bottom, no row cut off on portrait beyond one scrollable row.

- [ ] **Step 4: Commit**

```bash
git add Common/Swift/PauseMenuView.swift DolphiniOSTests/PauseMenuSnapshotTests.swift
git commit -m "test(pause): pause overlay snapshot renders"
```

---

### Task 9: Device gates and PR

- [ ] **Step 1: iPhone (Xbox pad and touch)**

1. Open the pause menu: three sections, info shelf updates as focus moves with the d-pad; tap and A both work.
2. Fast Forward: tap cycles Off → 2x → 4x → 8x → Unlimited → Off with the badge updating; long-press (touch) and hold A (pad) open the list; picking closes it. Resume: the game runs at the chosen speed.
3. Quick Save shows "Slot N"; long-press changes the slot; tap saves and a toast appears over the menu.
4. Screenshot: a file appears in ScreenShots/<gameID>; toast confirms.
5. Mute toggles with the badge; Cheats badge shows the active count.
6. Shaders: tap cycles None → recent presets (after using the full picker once); long-press opens the full picker; closing it updates the badge.
7. Reset and Exit confirm in place; Cancel is the first focus.
8. Enter every sub-surface and back out: the game never resumes (PR 1 arbiter).

- [ ] **Step 2: Apple TV (Xbox pad, then Siri Remote)**

1. Menu/View opens the overlay; the opening press never closes it; focus ring and scale show on the first tile.
2. Left/right on Fast Forward steps the value; hold Select/A opens the list.
3. B closes the overlay from the root; B inside Save States returns to the root.
4. Siri Remote: Menu opens and closes; the touch surface moves focus; Play/Pause resumes.
5. Settings from the overlay opens the full-screen settings; Menu returns with the game still paused.

- [ ] **Step 3: Open the PR against `develop`**

Title: `feat(ui): MenuKit and one tile-grid pause overlay for iOS and tvOS`. Body: spec §4.1/§4.2/§5 summary, the three snapshot PNGs attached, device gate results, and the note that `ValueStepper`/`SheetScaffold` are deferred to PR 3. Do not push `develop`.
