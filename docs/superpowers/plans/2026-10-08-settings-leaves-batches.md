# Remaining Settings Leaves Implementation Plan (PR 5, three batches)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every settings leaf that is a plain form renders through the menu engine, in three independently shippable batches, so the sidebar shell, descriptions, controller adjustment and generated search cover all of Settings.

**Architecture:** The PR 3 leaf pattern, repeated: a `State` snapshot, a `Change` enum, a pure `ModelBuilder.make(state:apply:)`, and a host view whose `apply(_:)` is the only Config writer, wrapped in `.settingsLeaf(title:helpKey:sync:)`. A leaf with a control the engine has no role for (a date picker, a login form) either uses a `.custom` row or stays hand-built, listed below.

**Tech Stack:** Swift 5, SwiftUI, XCTest (`iCubeTests`), Tuist.

**Spec:** `docs/superpowers/specs/2026-10-07-unified-menu-ux-design.md` §6.5, §10 item 5. Depends on PR 3 (`.stepper`, `ValueStepper`, `.settingsLeaf`, `SettingsRootModelBuilder`, `SettingsSearchIndex`). Read `docs/superpowers/plans/2026-10-08-settings-on-engine.md` Task 3 first: it is the worked example this plan repeats.

## What stays hand-built, and why

| Leaf | Reason |
|---|---|
| `ConfigAchievementsView` | Username/password text entry and a login button with async state. No text role in the engine; a `.custom` row would just re-embed the form. |
| `ShaderSettingsView` | Preset picker with rendered previews and a parameter editor. |
| `CloudSyncSettingsView`, `ContinuityBrowseView`, `DSUSettingsView`, `PerformanceABView`, `SkinPickerView`, `ControllerLightsView`, `WebUISettingsView`, `AboutView` | Lists of live things (devices, servers, snapshots, skins, URLs), not settings forms. |
| `AudioEffectEditors` | Effect chains with per-effect parameter sliders; reached from the Audio leaf as `.destination` rows. |

These keep their `.destination(AnyView)` entry in `SettingsRootModelBuilder` and show up in search by title, description and keywords only.

## Global Constraints

Same as PR 3's, plus:

- One batch per PR, in the order below. Each batch ends with the whole test target green on the iOS simulator and a tvOS compile.
- Row ids lowercase-kebab, unique within a leaf. Descriptions are the existing caption strings copied verbatim; a row with no caption gets one sentence written for it. Never a nil description.
- `apply(_:)` keeps every side effect the old `onSet` closure had (listed per leaf below). Read the old file before deleting it; the tables here come from a survey of control kinds and are not a substitute for reading the captions and closures.
- Each migrated leaf registers `makeModel:` on its `SettingsLeafEntry` in `SettingsRootModelBuilder.sections` so search sees its rows, and `SettingsSearchIndexTests` gains one assertion per batch (a row title from each migrated leaf is found).
- Worktree per batch: `feat/settings-leaves-a`, `-b`, `-c` from `develop`. After `git worktree add`, run `git config --worktree core.worktree <absolute worktree path>` and confirm `git rev-parse --show-toplevel`. DO NOT git reset / rebase / push / touch develop.
- Paths relative to `Source/iOS/App/`; `Leaves/` means `Common/UI/Settings/SwiftUI/Leaves/`.

## The template, written out once: Config Advanced

Every other leaf in this plan follows this file set exactly, so it is shown in full here and referenced by the batch tasks.

```swift
// Leaves/ConfigAdvancedState.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

struct ConfigAdvancedState: Equatable {
  var memOverride = false
  var mem1MB = 24
  var mem2MB = 64
  var rtcEnabled = false
  var rtcDate = Date(timeIntervalSince1970: 0)
}

enum ConfigAdvancedChange: Equatable {
  case memOverride(Bool)
  case mem1MB(Int)
  case mem2MB(Int)
  case rtcEnabled(Bool)
  case rtcDate(Date)
}
```

```swift
// Leaves/ConfigAdvancedModelBuilder.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

enum ConfigAdvancedModelBuilder {
  static func make(state: ConfigAdvancedState, apply: @escaping (ConfigAdvancedChange) -> Void) -> MenuModel {
    let memory = MenuSection(id: "memory", header: L("Emulated Memory Size Override"), items: [
      MenuItem(id: "mem-override", title: L("Enable Emulated Memory Size Override"),
               role: .toggle(Binding(get: { state.memOverride }, set: { apply(.memOverride($0)) })),
               description: L("Adjusts the amount of RAM in the emulated console. Only some games need more; leave off unless a title asks for it.")),
      MenuItem(id: "mem1", title: L("MEM1 Size"),
               role: .stepper(MenuStepper(value: Binding(get: { Double(state.mem1MB) }, set: { apply(.mem1MB(Int($0))) }),
                                          range: 24 ... 64, step: 1, format: { "\(Int($0)) MB" })),
               isEnabled: state.memOverride, description: L("Main memory. The real console has 24 MB.")),
      MenuItem(id: "mem2", title: L("MEM2 Size"),
               role: .stepper(MenuStepper(value: Binding(get: { Double(state.mem2MB) }, set: { apply(.mem2MB(Int($0))) }),
                                          range: 64 ... 128, step: 1, format: { "\(Int($0)) MB" })),
               isEnabled: state.memOverride, description: L("Wii external memory. The real console has 64 MB.")),
    ])
    let rtc = MenuSection(id: "rtc", header: L("Custom RTC Options"), items: [
      MenuItem(id: "rtc-enabled", title: L("Enable Custom RTC"),
               role: .toggle(Binding(get: { state.rtcEnabled }, set: { apply(.rtcEnabled($0)) })),
               description: L("Starts the emulated clock at a date you choose instead of now.")),
      MenuItem(id: "rtc-date", title: L("Date and Time"),
               role: .custom(AnyView(RTCDateRow(date: Binding(get: { state.rtcDate }, set: { apply(.rtcDate($0)) }), isEnabled: state.rtcEnabled))),
               isEnabled: state.rtcEnabled, description: L("The emulated console's clock when the game starts.")),
    ])
    return MenuModel(sections: [memory, rtc])
  }
}

/// The one control the engine has no role for. tvOS has no `DatePicker`; it shows the date and steps
/// whole days with left/right.
struct RTCDateRow: View {
  let date: Binding<Date>
  let isEnabled: Bool
  var body: some View {
    #if os(tvOS)
    ValueStepper(stepper: MenuStepper(
      value: Binding(get: { date.wrappedValue.timeIntervalSince1970 }, set: { date.wrappedValue = Date(timeIntervalSince1970: $0) }),
      range: 0 ... 4_102_444_800, step: 86_400,
      format: { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .omitted) }), isEnabled: isEnabled)
    #else
    DatePicker("", selection: date, displayedComponents: [.date, .hourAndMinute]).labelsHidden().disabled(!isEnabled)
    #endif
  }
}
```
The description strings above are placeholders for the old file's captions where it has them; copy those verbatim and keep these only for rows the old file left uncaptioned.

```swift
// Leaves/ConfigAdvancedView.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct ConfigAdvancedView: View {
  @State private var state = ConfigAdvancedState()

  var body: some View {
    MenuScreen(model: ConfigAdvancedModelBuilder.make(state: state, apply: apply), style: .list)
      .settingsLeaf(title: L("Advanced"), helpKey: nil, sync: sync)
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
Getter names are the ones the old `sync()` uses; take them from the old file. The old `helpKey` (its `HelpButton(helpKey:)` argument, when present) goes into `.settingsLeaf`.

```swift
// DolphiniOSTests/ConfigAdvancedModelBuilderTests.swift
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

  func test_rowOrder() {
    XCTAssertEqual(model().allItems.map(\.id), ["mem-override", "mem1", "mem2", "rtc-enabled", "rtc-date"])
  }

  func test_everyRow_described_andBuildWritesNothing() {
    for item in model().allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
    XCTAssertTrue(changes.isEmpty)
  }

  func test_memorySteppers_disabledUntilOverrideOn_andClampToTheirRanges() {
    XCTAssertEqual(model().item(id: "mem1")?.isEnabled, false)
    var state = ConfigAdvancedState()
    state.memOverride = true
    guard case .stepper(let stepper)? = model(state).item(id: "mem1")?.role else { return XCTFail("stepper") }
    XCTAssertEqual(stepper.range, 24 ... 64)
    stepper.value.wrappedValue = 30
    XCTAssertEqual(changes, [.mem1MB(30)])
  }

  func test_rtcDate_disabledUntilRtcOn() {
    XCTAssertEqual(model().item(id: "rtc-date")?.isEnabled, false)
  }
}
```

Each batch task below is: write the tests for each leaf in the batch (row order, every row described, build writes nothing, one toggle emits its change, each gating rule, each cycle's options) → regenerate and verify they fail → State/Change → builder → host → `git rm` the old file (moving any shared enum or sub-view it defines to `SettingsEnums.swift` / `SettingsSharedComponents.swift`) → register `makeModel:` in the root builder → add a search assertion → build both platforms → run the whole target → commit.

---

### Batch A (PR 5a): General, Interface, Advanced

**Files:**
- Create: `Leaves/ConfigGeneral{State,ModelBuilder,View}.swift`, `Leaves/ConfigInterface{...}.swift`, `Leaves/ConfigAdvanced{...}.swift`
- Delete: `Common/UI/Settings/SwiftUI/ConfigGeneralView.swift`, `ConfigInterfaceView.swift`, `ConfigAdvancedView.swift` (their `SpeedLimitPicker`, `FastForwardSpeedPicker`, `FallbackRegionPicker` sub-views go; the `FallbackRegion` enum and `LibraryBackgroundStyle` move to `SettingsEnums.swift`)
- Modify: `Common/UI/Settings/SwiftUI/SettingsRootModelBuilder.swift` (`makeModel:` for `general`, `interface`, `advanced`)
- Tests: create `ConfigGeneralModelBuilderTests`, `ConfigInterfaceModelBuilderTests`, `ConfigAdvancedModelBuilderTests` (above); extend `SettingsSearchIndexTests`

**Config General rows**, three sections with the old headers (`Basic Settings`, `Speed`, `Fallback Region`):

| id | kind | options / range | notes |
|---|---|---|---|
| `dual-core` | toggle | | `setMainCpuThread` |
| `dsp-thread` | toggle | | `setMainDSPThread` |
| `cheats` | toggle | | `setMainEnableCheats` |
| `override-region` | toggle | | `setMainOverrideRegionSettings` |
| `auto-disc-change` | toggle | | `setMainAutoDiscChange` |
| `fast-disc-speed` | toggle | | `setMainFastDiscSpeed` |
| `resume-where-left-off` | toggle | | UserDefaults `resume_where_left_off` |
| `speed-limit` | cycle | the old `SpeedLimitPicker`'s percent list, label `"\(p)%"` and `Unlimited` for 0 | `setMainEmulationSpeedPercent` |
| `fast-forward-speed` | cycle | the old `FastForwardSpeedPicker`'s list, same labels as `PauseMenuModelBuilder.fastForwardOptions` where they overlap | UserDefaults `fast_forward_speed_percent` (the pause overlay reads the same key) |
| `fallback-region` | cycle | `FallbackRegion.allCases` as `(label, rawValue)` | `setMainFallbackRegion` |

**Config Interface rows**, sections `Game List`, `Library UI`, `General`:

| id | kind | options | notes |
|---|---|---|---|
| `names-db` | toggle | | `setMainUseBuiltInTitleDatabase` |
| `covers` | toggle | | `setMainUseGameCovers` |
| `background-style` | cycle | `LibraryBackgroundStyle.allCases` | `@AppStorage("library_background_style")` becomes a UserDefaults write in `apply` and a read in `sync` |
| `show-subtitles` | toggle | | UserDefaults `library_show_subtitles` |
| `confirm-on-stop` | toggle | | `setMainConfirmOnStop` |
| `panic-handlers` | toggle | | `setMainUsePanicHandlers` |
| `osd-messages` | toggle | | `setMainOSDMessages` |

The `#if os(tvOS)` block at the old file's line ~51 holds a tvOS-only row set; keep its rows with `isTV` in the state (same trick as PR 3's `GraphicsGeneralState.isIOS`).

**Config Advanced**: the template above.

- [ ] Tests → fail → implement the three leaves → delete old files → register `makeModel:` → search assertion (`"dual core"` finds `general`) → build both → full test run → commit `feat(settings): General, Interface and Advanced on the menu engine` → PR `feat(settings): settings leaves batch A`.

---

### Batch B (PR 5b): GameCube, Wii, Audio

**Files:**
- Create: `Leaves/ConfigGameCube{...}.swift`, `Leaves/ConfigWii{...}.swift`, `Leaves/ConfigAudio{...}.swift`
- Delete: `ConfigGameCubeView.swift`, `ConfigWiiView.swift`, `ConfigAudioView.swift` (keep `AudioEffectEditors.swift`; the picker sub-views `GCLanguagePicker`, `WiiAspectRatioPicker`, `WiiLanguagePicker`, `WiiAudioModePicker`, `WiiSensorBarPosPicker` go; their option lists become the cycle options)
- Modify: root builder (`makeModel:` for `console-gamecube`, `console-wii`, `audio`)
- Tests: three builder test files; search assertion

**GameCube rows**: `load-main-menu` (toggle; the old binding inverts `skipIPL`: `apply(.loadMainMenu(v))` writes `setMainSkipIPL(!v)`), `language` (cycle over the old `GCLanguagePicker` list).

**Wii rows**, sections `Video`, `General`, `Wii Remotes`, `USB / SD` (the old footers become the first row's description suffix, or a disabled caption row as `PlayerScreenModelBuilder.helpCaption` does):

| id | kind | range / options | notes |
|---|---|---|---|
| `pal60` | toggle | | `setSysconfPAL60` |
| `aspect` | cycle | 4:3 (false), 16:9 (true) | `setSysconfWidescreen` |
| `screensaver` | toggle | | |
| `language` | cycle | old `WiiLanguagePicker` list | |
| `sound-mode` | cycle | old `WiiAudioModePicker` list | |
| `sensor-bar-position` | cycle | Bottom / Top | `setSysconfSensorBarPosition` |
| `sensor-bar-sensitivity` | stepper | `1 ... 5`, step 1 | |
| `speaker-volume` | stepper | `0 ... 7`, step 1 | |
| `wiimote-rumble` | toggle | | `setSysconfWiimoteMotor` |
| `touchpad-ir-follow` | toggle | | UserDefaults `touchpad_ir_follow_without_click` (confirm the key in the old file) |
| `skylander-portal` | toggle | | `setMainEmulateSkylanderPortal`; the old binding read the bridge live, so `sync` reads `mainEmulateSkylanderPortal()` |
| `usb-keyboard` | toggle | | |
| `wiilink` | toggle | | |
| `sd-card` | toggle | | |
| `sd-writes` | toggle | | |
| `sd-folder-sync` | toggle | | |

**Audio rows**, sections `Audio Backend`, `Master Effects Chain` (iOS), `CoreAudio Effects` (iOS), `Volume`, `Audio Stretching Settings`, `Misc. Controls`:

| id | kind | notes |
|---|---|---|
| `backend` | cycle | Default Device (""), AVAudioEngine, CoreAudio (Speaker), with the old display labels. The old view confirms a backend change with an Enable/Cancel alert; the host keeps that `.alert` and passes `MenuModal` to `MenuScreen` while it is up so a pad answers it. `apply(.backend)` only runs after confirmation. |
| `effects-chain` | destination, iOS | the old section's `NavigationLink` target in `AudioEffectEditors.swift` |
| `coreaudio-effects` | destination, iOS | likewise |
| `volume` | stepper | `0 ... 100`, format `"\(Int($0))%"`; `setAudioVolume`. `QuickMute` reads the same value, so a change here is reflected by the pause overlay's Mute badge on its next build. |
| `stretch` | toggle | |
| `stretch-latency` | stepper | `5 ... 200`, format `"\(Int($0)) ms"`, `isEnabled: stretch` |
| `mute-on-no-speed-limit` | toggle | |
| `obey-mute-switch` | toggle | |

- [ ] Same steps as Batch A; commit `feat(settings): GameCube, Wii and Audio on the menu engine` → PR `feat(settings): settings leaves batch B`.

---

### Batch C (PR 5c): Graphics Advanced, Debug, Enhanced Motion, Stick Feel

**Files:**
- Create: `Leaves/GraphicsAdvanced{...}.swift`, `Leaves/DebugRoot{...}.swift`, `Leaves/EnhancedMotion{...}.swift`, `Leaves/AnalogStick{...}.swift`
- Delete: `GraphicsAdvancedView.swift`, `DebugRootView.swift`, `EnhancedMotionControlsView.swift`, and `AnalogStickSettingsView` from `ControllersRootView.swift` (the file keeps `ControllersRootView` and `TouchOverlayLayoutEditorView`)
- Modify: root builder (`makeModel:` for `graphics-advanced`, `debug`); `PlayerScreenViewModel.actions` (PR 4) keeps pointing at `EnhancedMotionControlsView()` / `AnalogStickSettingsView()`, whose names are unchanged
- Tests: four builder test files; search assertion

**Graphics Advanced rows**, sections `Performance Statistics`, `Debugging`, `Shader Threads`, `Utility`, `Misc`, `Rendering`, `Experimental`: every `Toggle` in the survey becomes a toggle row with its old caption; `compiler-threads` and `precompiler-threads` are steppers `1 ... maxThreads` (`maxThreads` in the state, read as the old view reads it); `present-drawable` and `manually-upload-buffers` are cycles Off(0) / On(1) / Auto(2) (the old `MetalTriStatePicker` lists). `prefetch-textures` keeps its `isEnabled: hiresTextures` gating if the old view has it (check the `.disabled` modifier near line 126).

**Debug rows**: toggles and actions as in the survey (`fastmem`, `instant-replay` iOS, `retry-jit` action, `enable-jit-stikdebug` action iOS, `reset-launch-times` action, `motion-debug` destination, `stall-metrics` toggle, `perf-bench` toggle, `wireframe` toggle, `console-logging` toggle, `logging-verbosity` cycle over the old button's value list, `input-debug` toggle, `template-covers` toggle). The Environment section's read-only rows (JIT status and the like, old lines ~61-110) become disabled caption rows built the way `PlayerScreenModelBuilder.helpCaption` builds them, with the values in the title. The destructive button at line ~159 becomes a `.destructive` row with the host confirming through `MenuModal`. The `.task` at line ~210 moves into the host's `sync` path (an `async` refresh that assigns the state on the main actor). The DEBUG-only `Gallery` link PR 4 moved here stays as a `.destination` under `#if os(iOS) && DEBUG`.

**Enhanced Motion rows**: `horizontal-motion` cycle over the old `HorizontalMotionPicker` modes, `wiimote-imu`, `six-dof`, `nunchuk-imu` toggles (all `MotionSettings.Key` UserDefaults; `apply` writes UserDefaults, `sync` reads them), `recommended` action running the old `applyRecommendedSettings()` logic moved into the host.

**Stick Feel rows**: `gain` stepper `0.1 ... 3.0` step `0.05` format `%.2f`, `deadzone` stepper `0.0 ... 0.49` step `0.01`, `smoothing` stepper (range from the old file) — UserDefaults `dsu_gyro_gain`, `dsu_deadzone`, `dsu_smoothing`.

- [ ] Same steps; commit `feat(settings): Graphics Advanced, Debug, Motion and Stick Feel on the menu engine` → PR `feat(settings): settings leaves batch C`.

---

### After Batch C

- [ ] Grep `Common/UI/Settings/SwiftUI` for `settingsCaption(`, `settingsNavCaption(`, `TVIntStepper`, `TVFloatStepper`, `SettingsSelectRow`: the only remaining callers should be the hand-built leaves in the table at the top. Delete `TVIntStepper`, `TVFloatStepper` and `TVIntStepperOverlay` if nothing uses them (the quick overlay in `EmulationScreen` used `TVIntStepperOverlay`; replace that use with `ValueStepper` in the same PR if it is still there).
- [ ] Update `CLAUDE.md`'s settings note, if one exists, to say leaves are `State` + `Change` + `ModelBuilder` + host, and that new settings go in a builder, never a hand-built `Form`.
- [ ] Device gate once, on both platforms: open every migrated leaf, change one value in each, leave and re-enter: the value persists and the game-INI badges still show on the clock and resolution rows.
