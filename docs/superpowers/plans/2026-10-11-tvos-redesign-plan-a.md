# tvOS redesign completion, plan A: baseline, bug pass, settings leaves

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land packages 0, 1 and 2 of the tvOS redesign spec: a committed screenshot baseline with the launch hooks that make it reproducible, the fast-forward cycle fix, the floating speedometer button replaced by a pause tile, and every settings leaf on the iFly game-settings look.

**Architecture:** All tvOS chrome comes from the design module in `Common/Swift/MenuKit/` (`ICubeDesign*.swift`). Settings leaves render through `MenuScreen` (`.list` → `tvListBody` on tvOS), so the look is changed once in `MenuScreen.tvRowLabel`/`tvListBody` and the hand-built leaves are moved onto pure `MenuModel` builders so they take the same path. Pause state that the menu displays lives in `@State` on `PauseMenuView`, never re-read from `UserDefaults` inside a binding getter.

**Tech Stack:** Swift 5 / SwiftUI, tvOS 17+, XCTest (`iCubeTests`, iOS simulator only), Tuist-generated `iCube.xcworkspace`, `xcrun simctl` for tvOS screenshots, the Python lint scripts under `Source/iOS/App/Project/Scripts/`.

**Spec:** `docs/superpowers/specs/2026-10-11-tvos-redesign-completion-design.md` (packages 0, 1, 2 = §3, §4). The design tokens are in `docs/superpowers/specs/2026-10-10-icube-design-language.md`.

**Later plans:** package 3 (library polish), package 4 (pause completion, including the Shader picker and parameter screens), packages 5–7. The Nearby peer-detail and peer-library screens and the iCloud conflict screen keep their stock `List` in this plan; they are transactional flows (pairing-code entry, progress) and get a task in the pause-completion plan where the row style for text entry is decided.

## Global Constraints

- Paths are relative to `Source/iOS/App/`. Run every command from there unless stated.
- tvOS compile gate (one `xcodebuild` at a time; never `pkill xcodebuild`):
  ```sh
  xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination generic/platform=tvOS -derivedDataPath build-Xcode-tvos CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E ": error:|BUILD (SUCCEEDED|FAILED)"
  ```
- iOS tests: `make test TEST_ARGS="-only-testing:iCubeTests/<Class>"` (iPhone 17 Pro simulator; the first run in a fresh checkout builds the core slice, ~30 min).
- After adding any `.swift` file: `PATH=/opt/homebrew/bin:$PATH tuist generate --no-open`, or the file is not compiled and new tests silently do not run.
- Every new `L("…")` key needs `"key" = "key";` in `Common/UI/Localization/en.lproj/Core.strings` and a Japanese line in `ja.lproj/Core.strings`; `python3 Project/Scripts/check_localized_keys.py --check` must pass.
- `python3 Project/Scripts/check_design_tokens.py --check` must pass; when a file's count falls, run `--update` and commit `Project/Scripts/design_tokens_baseline.json`.
- `python3 Project/Scripts/check_button_types.py` must pass.
- Before every commit: `git -C ../../.. checkout -- build/xcframework` (the tracked core slices get rewritten by local builds). Never stage them. Never stage `Core.strings` lines you did not add.
- iPhone and iPad touch UI must not change. tvOS-only code goes behind `#if os(tvOS)`.
- Raw sizes, radii, line widths and colours live only in `MenuKit/ICubeDesign*.swift`; everything else uses `ICubeDesign.Spacing/Radius/Line`, `ICubeDesign.color(_:)`, `.icubeText(_:)`, `ICubeDesign.symbolFont(_:)`.
- Commit messages: conventional (`fix(tvos): …`, `feat(tvos): …`, `test: …`, `docs: …`), subject < 72 chars, no AI/LLM trailers.
- No pull requests: reviewed work lands on `develop` directly. Work in a worktree on branch `feat/tvos-redesign-a`. Worktree recipe (this repo is a submodule): after `git worktree add ~/Workspace/icube-redesign-a -b feat/tvos-redesign-a`, run `git config --file "$(git rev-parse --git-common-dir)/worktrees/icube-redesign-a/config.worktree" core.worktree ~/Workspace/icube-redesign-a`, then confirm `git rev-parse --show-toplevel` prints the worktree before any `git add`.

## Review Focus

1. **A leaf with a `.custom` row on tvOS** (the player screen's capture rows, `CheatsMenuView`): the custom view must render inside the restyled list without a system capsule and without being wrapped in the row chrome twice. Not unit-testable (focus is a runtime effect); pinned by Task 7's `settings-controllers` screenshot read and `PlayerScreenLeavesTests`.
2. **Exploded picker with the selected option disabled** (`isEnabled == false` on the item): the `Selected` value must still show and the row must not be focusable. Test in Task 7 (`test_disabledPicker_keepsItsValue_andIsNotFocusable`).
3. **Fast-forward when the stored percent is not on the tile ladder** (the General leaf can store any ladder value, e.g. 150): the tile must show "—" and the next press must go to 2x, not crash or stay. Test in Task 3.
4. **A pushed sub-leaf from a pane leaf** (Controllers → player screen): the header subtitle must be the parent's title and Back must pop the sub-leaf, not jump to the sidebar. Test in Task 6 (subtitle) plus the existing `SettingsLeafScreenTests` (back).
5. **iCloud leaf while `unavailableReason` is set**: Sync Now must be disabled and the footer must carry the reason, exactly as the Form did. Test in Task 11.

---

## File structure

| File | Responsibility |
|---|---|
| `Scripts/tvos_screens.sh` (new) | Build/install/launch the tvOS simulator app into each screen and screenshot it |
| `Common/Swift/TVRootView.swift` | DEBUG launch arguments `-ICubePausePreview`, `-ICubePausePane`, `-ICubeSettingsPreview` |
| `Common/Swift/PauseFastForwardState.swift` (new) | Pure fast-forward selection state for the pause tile |
| `Common/Swift/PauseMenuView.swift` | Uses `PauseFastForwardState`; `onShowPerfOverlay`; debug initial pane |
| `Common/Swift/EmulationScreen.swift` | Drops the floating speedometer button; passes `onShowPerfOverlay` |
| `Common/Swift/MenuKit/ICubeLeafHeader.swift` (new) | In-body title + subtitle for leaves (spec §4.2) |
| `Common/Swift/MenuKit/ICubeDesign.swift` | `IconBadge` constants |
| `Common/Swift/MenuKit/ICubeDesign+Focus.swift` | `icubeRowChrome(focused:)` for non-Button rows |
| `Common/Swift/Menu/MenuScreen.swift` | `tvHeader`/`tvInset`; row anatomy; exploded-picker selection; stepped row chrome |
| `Common/UI/Settings/SwiftUI/SettingsLeafHost.swift` | tvOS: header instead of `.navigationTitle`; parent-title environment |
| `Common/UI/Settings/SwiftUI/SettingsSidebarShell.swift` | `jumpToLeafID`; accent selection; hairline divider |
| `Common/UI/Settings/SwiftUI/SettingsRootView.swift` | `initialLeafID`; `jumpToLeafID` plumbing |
| `Common/UI/Settings/SwiftUI/AboutView.swift` + `AboutModelBuilder.swift` (new) | tvOS About on the engine |
| `Common/UI/Settings/SwiftUI/WebUISettingsView.swift` + `WebUIModelBuilder.swift` (new) | tvOS Web UI on the engine |
| `Common/UI/Settings/SwiftUI/CloudSyncSettingsView.swift` + `CloudSyncModelBuilder.swift` (new) | tvOS iCloud on the engine |
| `Common/Continuity/UI/ContinuityBrowseView.swift` + `ContinuityBrowseModelBuilder.swift` (new) | tvOS Nearby on the engine |
| `Common/Continuity/UI/ContinuityLibrarySharingView.swift` + `ContinuitySharingModelBuilder.swift` (new) | tvOS Share My Library and grant detail on the engine |
| `Common/Swift/Shaders/ShaderSettingsView.swift` + `ShaderSettingsModelBuilder.swift` (new) | tvOS Shaders leaf on the engine |
| `DolphiniOSTests/…Tests.swift` | One test file per builder/state above |
| `docs/superpowers/baselines/2026-10-11-tvos/` (new) | Baseline PNGs |

---

## Package 0: baseline

### Task 1: Preview launch arguments and the screenshot script

**Files:**
- Modify: `Common/Swift/TVRootView.swift`
- Modify: `Common/Swift/PauseMenuView.swift:25-31, 246-253` (debug initial pane)
- Modify: `Common/UI/Settings/SwiftUI/SettingsSidebarShell.swift:13, 85-102` (`jumpToLeafID`)
- Modify: `Common/UI/Settings/SwiftUI/SettingsRootView.swift:11, 46-58`
- Create: `Scripts/tvos_screens.sh`
- Modify: `../../../.gitignore` (add `/Source/iOS/App/build-Xcode-tvsim`)
- Test: `DolphiniOSTests/SettingsRootModelBuilderTests.swift`

**Interfaces:**
- Produces: `SettingsRootView(initialLeafID: String? = nil)`; `SettingsSidebarShell(sections:searchIndex:jumpToLeafID: Binding<String?>)`; `PauseMenuView.debugInitialPane: String?` (internal var, DEBUG only); launch arguments `-ICubeSettingsPreview <leafID>`, `-ICubePausePane saves|cheats|controllers|reset|exit`, existing `-ICubePausePreview`, existing `-SCREENSHOT_MODE 1`.

- [ ] **Step 1: Write the failing test** (every leaf id the script will ask for exists)

```swift
// DolphiniOSTests/SettingsRootModelBuilderTests.swift — add to the class
func test_tvScreenshotScript_leafIDs_exist() {
  let ids = Set(SettingsRootModelBuilder.sections(isIOS: false, achievements: false).flatMap(\.entries).map(\.id))
  for id in ["general", "interface", "advanced", "graphics-video", "graphics-enhancements", "graphics-hacks",
             "graphics-advanced", "shaders", "audio", "console-gamecube", "console-wii", "controllers",
             "performance-tuning", "debug", "web-ui", "icloud", "nearby", "about"] {
    XCTAssertTrue(ids.contains(id), id)
  }
}
```

- [ ] **Step 2: Run it**

Run: `make test TEST_ARGS="-only-testing:iCubeTests/SettingsRootModelBuilderTests"`
Expected: PASS already (the ids exist today). This test guards the script's list from drifting; keep it.

- [ ] **Step 3: Generalise the sidebar jump**

In `SettingsSidebarShell.swift` replace `@Binding var jumpToControllers: Bool` with `@Binding var jumpToLeafID: String?`, delete `private static let controllersID`, and replace `selectControllers()` and its two call sites:

```swift
.onAppear {
  #if os(tvOS)
  openedAt = Date()
  #endif
  if selectedID == nil { selectedID = sections.first?.entries.first?.id }
  consumeJump()
}
.onChange(of: jumpToLeafID) { _, _ in consumeJump() }

/// A deep link (DSU → "controllers") or a debug preview lands on one leaf.
private func consumeJump() {
  guard let id = jumpToLeafID, entries.contains(where: { $0.id == id }) else { jumpToLeafID = nil; return }
  selectedID = id
  sidebarFocus = id
  jumpToLeafID = nil
}
```

In `SettingsRootView.swift`:

```swift
struct SettingsRootView: View {
  /// A leaf to open first (the DSU deep link, the tvOS `-ICubeSettingsPreview` argument).
  var initialLeafID: String? = nil
  @State private var jumpToLeafID: String?
  …
  SettingsSidebarShell(sections: sections, searchIndex: nil, jumpToLeafID: $jumpToLeafID)      // tvOS
  SettingsSidebarShell(sections: sections, searchIndex: searchIndex, jumpToLeafID: $jumpToLeafID) // iPad
  …
  .onAppear { if jumpToLeafID == nil { jumpToLeafID = initialLeafID } }
  .onReceive(NotificationCenter.default.publisher(for: .dolSettingsSelectControllers)) { _ in jumpToLeafID = "controllers" }
```

The iPhone path keeps its own `jumpToControllersRequested` for `.navigationDestination(isPresented:)` at line 84; set it from the same `onReceive` (`jumpToControllersRequested = true`) so iPhone behaviour is unchanged. Find every other caller: `grep -rn "SettingsRootView(" Common` and leave them compiling (the new parameter has a default).

- [ ] **Step 4: Debug initial pane on the pause menu**

In `PauseMenuView.swift` add, next to `@State private var pane`:

```swift
#if DEBUG
/// `-ICubePausePane <saves|cheats|controllers|reset|exit>`: open a sub-pane for simulator screenshots.
var debugInitialPane: String?
#endif
```

and at the end of the existing `.onAppear` block (the one that sets `isMuted`, around line 146):

```swift
#if DEBUG
switch debugInitialPane {
case "saves": pane = .saves
case "cheats": pane = .cheats
case "controllers": pane = .controllers
case "reset": showResetDialog = true
case "exit": showExitDialog = true
default: break
}
debugInitialPane = nil
#endif
```

Statements are not allowed inside a `ViewBuilder`, so add the setter as a modifier-style method on `PauseMenuView` (DEBUG only):

```swift
#if DEBUG
func debugPane(_ pane: String?) -> PauseMenuView { var copy = self; copy.debugInitialPane = pane; return copy }
#endif
```

- [ ] **Step 5: Launch arguments in `TVRootView.swift`**

```swift
var body: some View {
  #if DEBUG
  let args = ProcessInfo.processInfo.arguments
  if args.contains("-ICubePausePreview") {
    PauseMenuView(selectedSlot: .constant(1), onClose: {}, onShowSettings: {}, platform: .tvos,
                  game: PauseMenuView.previewGame())
      .debugPane(Self.argument(after: "-ICubePausePane", in: args))
  } else if let leaf = Self.argument(after: "-ICubeSettingsPreview", in: args) {
    SettingsRootView(initialLeafID: leaf)
  } else {
    library
  }
  #else
  library
  #endif
}

#if DEBUG
private static func argument(after flag: String, in args: [String]) -> String? {
  guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
  return args[i + 1]
}
#endif
```

- [ ] **Step 6: The script**

Create `Scripts/tvos_screens.sh`:

```sh
#!/bin/sh
# Screenshot every tvOS screen on the Apple TV 4K (3rd gen, 1080p) simulator.
# Usage: Scripts/tvos_screens.sh <out-dir> [--no-build] [--light|--dark]
# Run from Source/iOS/App. Library views come from -SCREENSHOT_MODE 1 (16 demo titles).
set -eu
OUT="${1:?out dir}"; shift || true
BUILD=1; STYLE=dark
for a in "$@"; do case "$a" in --no-build) BUILD=0;; --light) STYLE=light;; --dark) STYLE=dark;; esac; done
UDID=59214C60-C1D5-460F-91DC-BA425B4868C4
BID=com.joemattiello.iCube-debug
DD=build-Xcode-tvsim
mkdir -p "$OUT"
if [ "$BUILD" = 1 ]; then
  xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" \
    -destination "platform=tvOS Simulator,id=$UDID" -derivedDataPath "$DD" \
    CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
    2>&1 | grep -E ": error:|BUILD (SUCCEEDED|FAILED)"
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl ui "$UDID" appearance "$STYLE"
xcrun simctl install "$UDID" "$DD"/Build/Products/*appletvsimulator/iCube*.app
shot() { # name, then launch args
  name="$1"; shift
  xcrun simctl terminate "$UDID" "$BID" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BID" "$@" >/dev/null
  sleep 4
  xcrun simctl io "$UDID" screenshot "$OUT/$name-$STYLE.png" >/dev/null
}
# Library: platform filter raw values are LibraryPlatformCategory's: all, gameCube, wii, wiiWare.
for view in all gameCube wii; do
  xcrun simctl spawn "$UDID" defaults write "$BID" library_platform_filter -string "$view"
  shot "library-$view" -SCREENSHOT_MODE 1
done
xcrun simctl spawn "$UDID" defaults delete "$BID" library_platform_filter 2>/dev/null || true
shot "library-home" -SCREENSHOT_MODE 1
shot "library-empty"
for leaf in general interface advanced graphics-video graphics-enhancements graphics-hacks graphics-advanced \
            shaders audio console-gamecube console-wii controllers performance-tuning debug web-ui icloud nearby about; do
  shot "settings-$leaf" -ICubeSettingsPreview "$leaf"
done
shot "pause-grid" -ICubePausePreview
for pane in saves cheats controllers reset exit; do
  shot "pause-$pane" -ICubePausePreview -ICubePausePane "$pane"
done
echo "wrote $(ls "$OUT" | wc -l | tr -d ' ') files to $OUT"
```

`chmod +x Scripts/tvos_screens.sh`.

- [ ] **Step 7: gitignore, tuist, compile**

Append `/Source/iOS/App/build-Xcode-tvsim` to the repository `.gitignore` (next to the `build-Xcode` line). Run `tuist generate --no-open`, the tvOS compile gate, and `make test TEST_ARGS="-only-testing:iCubeTests/SettingsRootModelBuilderTests -only-testing:iCubeTests/SettingsLeafScreenTests"`.

- [ ] **Step 8: Commit**

```sh
git add Common/Swift/TVRootView.swift Common/Swift/PauseMenuView.swift Common/UI/Settings/SwiftUI/SettingsSidebarShell.swift Common/UI/Settings/SwiftUI/SettingsRootView.swift Scripts/tvos_screens.sh ../../../.gitignore DolphiniOSTests/SettingsRootModelBuilderTests.swift
git commit -m "feat(tvos): preview launch arguments and a screenshot script"
```

### Task 2: Capture and commit the baseline

**Files:**
- Create: `docs/superpowers/baselines/2026-10-11-tvos/*.png` (repo root)

- [ ] **Step 1: Capture both appearances**

```sh
Scripts/tvos_screens.sh ../../../docs/superpowers/baselines/2026-10-11-tvos --dark
Scripts/tvos_screens.sh ../../../docs/superpowers/baselines/2026-10-11-tvos --no-build --light
```

- [ ] **Step 2: Look at them**

Open at least `library-all-dark.png`, `settings-debug-dark.png`, `settings-nearby-dark.png`, `pause-grid-dark.png`, `pause-exit-dark.png` with the Read tool. Write what you see in `docs/superpowers/baselines/2026-10-11-tvos/README.md`: for each screen, one line, "token rows" or "stock list / capsule" or "old look". This is the ground truth the spec's §4.1 asked for.

- [ ] **Step 3: Commit**

```sh
git -C ../../.. add docs/superpowers/baselines/2026-10-11-tvos
git -C ../../.. commit -m "docs(tvos): screenshot baseline before the redesign completion"
```

---

## Package 1: bug pass

### Task 3: Fast-forward tile cycles through every speed

**Files:**
- Create: `Common/Swift/PauseFastForwardState.swift`
- Modify: `Common/Swift/PauseMenuView.swift:69, 89-101, 146, 704-716`
- Test: `DolphiniOSTests/PauseFastForwardStateTests.swift` (new)

**Interfaces:**
- Produces:
  ```swift
  struct PauseFastForwardState: Equatable {
    var isEnabled: Bool
    var percent: Int                      // the stored speed, 0 = Unlimited
    var selection: AnyHashable { get }    // what the tile's binding returns
    enum Effect: Equatable { case turnOff, setSpeed(Int) }
    mutating func select(_ value: AnyHashable) -> Effect
  }
  ```

- [ ] **Step 1: Reproduce** (10 minutes, not optional)

`Scripts/tvos_screens.sh /tmp/ff --no-build` is not enough: the tile needs presses. Launch the pause preview by hand (`xcrun simctl launch 59214C60-… com.joemattiello.iCube-debug -ICubePausePreview`), open the simulator window, move focus to FAST FORWARD and press Select four times, screenshotting after each (`xcrun simctl io <udid> screenshot /tmp/ff-N.png`). Record the badge sequence in the commit message of Step 7. Expected from the code: the badge reads OFF, 2X, then stays 2X while `fast_forward_speed_percent` advances (check with `xcrun simctl spawn <udid> defaults read com.joemattiello.iCube-debug fast_forward_speed_percent`). Cause: after the first press `fastForwardEnabled` is already `true`, so later presses change nothing `PauseMenuView` observes, the view does not re-render, and `MenuScreen` keeps the stale model whose badge was computed at 2x. If the observed sequence differs, stop and write what you saw before changing code.

- [ ] **Step 2: Write the failing test**

```swift
// DolphiniOSTests/PauseFastForwardStateTests.swift
import XCTest
@testable import iCube

final class PauseFastForwardStateTests: XCTestCase {
  private let options = PauseMenuModelBuilder.fastForwardOptions

  func test_cyclingFromOff_visitsEverySpeedThenOff() {
    var state = PauseFastForwardState(isEnabled: false, percent: 300)
    var titles: [String] = []
    var effects: [PauseFastForwardState.Effect] = []
    for _ in 0 ..< options.count {
      let next = MenuItemRole.cycled(options: options, current: state.selection, step: 1)!
      effects.append(state.select(next))
      titles.append(MenuItemRole.selectedTitle(options: options, current: state.selection) ?? "—")
    }
    XCTAssertEqual(titles, ["2x", "3x", "4x", "8x", "Unlimited", "Off"])
    XCTAssertEqual(effects, [.setSpeed(200), .setSpeed(300), .setSpeed(400), .setSpeed(800), .setSpeed(0), .turnOff])
  }

  func test_storedPercentOffTheLadder_showsDash_andNextPressIsTwoX() {
    var state = PauseFastForwardState(isEnabled: true, percent: 150)
    XCTAssertNil(MenuItemRole.selectedTitle(options: options, current: state.selection))
    let next = MenuItemRole.cycled(options: options, current: state.selection, step: 1)!
    XCTAssertEqual(state.select(next), .setSpeed(200))
    XCTAssertEqual(state.percent, 200)
  }

  func test_selectOff_keepsLastPercentForNextTime() {
    var state = PauseFastForwardState(isEnabled: true, percent: 400)
    XCTAssertEqual(state.select(PauseMenuModelBuilder.fastForwardOff), .turnOff)
    XCTAssertFalse(state.isEnabled)
    XCTAssertEqual(state.percent, 400)
  }
}
```

- [ ] **Step 3: Run it to see it fail**

Run: `tuist generate --no-open && make test TEST_ARGS="-only-testing:iCubeTests/PauseFastForwardStateTests"`
Expected: compile error, `PauseFastForwardState` undefined.

- [ ] **Step 4: Implement the state**

```swift
// Common/Swift/PauseFastForwardState.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The pause menu's fast-forward selection. Owned as `@State` by `PauseMenuView` so every press
/// changes something the view observes; a binding getter that re-read UserDefaults left the view
/// (and the tile badge) unchanged after the first press.
struct PauseFastForwardState: Equatable {
  var isEnabled: Bool
  /// The configured speed in percent, 0 = Unlimited. Kept while off so Off → On restores it.
  var percent: Int

  enum Effect: Equatable { case turnOff, setSpeed(Int) }

  var selection: AnyHashable {
    isEnabled ? AnyHashable(percent) : PauseMenuModelBuilder.fastForwardOff
  }

  /// Applies a tile value and says what the bridge must do.
  mutating func select(_ value: AnyHashable) -> Effect {
    if let p = value as? Int, p >= 0 {
      isEnabled = true
      percent = p
      return .setSpeed(p)
    }
    isEnabled = false
    return .turnOff
  }
}
```

- [ ] **Step 5: Wire it into `PauseMenuView`**

Replace `@State private var fastForwardEnabled: Bool = false` with
`@State private var fastForward = PauseFastForwardState(isEnabled: false, percent: ConfigGeneralState.storedFastForward(nil))`.
Delete `configuredFastForwardPercent`. Change the appear line to:

```swift
fastForward = PauseFastForwardState(
  isEnabled: TVEmulationBridge.isFastForwardEnabled(),
  percent: ConfigGeneralState.storedFastForward(UserDefaults.standard.object(forKey: ConfigGeneralDefaultsKey.fastForwardSpeedPercent) as? Int))
```

Replace `selectFastForwardSpeed`/`turnOffFastForward` and the binding:

```swift
private func applyFastForward(_ effect: PauseFastForwardState.Effect) {
  switch effect {
  case .setSpeed(let percent):
    TVEmulationBridge.setFastForwardSpeedPercent(percent)
    if !TVEmulationBridge.isFastForwardEnabled() { _ = TVEmulationBridge.toggleFastForward() }
  case .turnOff:
    if TVEmulationBridge.isFastForwardEnabled() { _ = TVEmulationBridge.toggleFastForward() }
  }
}
…
fastForward: Binding(get: { fastForward.selection }, set: { applyFastForward(fastForward.select($0)) }),
```

`grep -n "fastForwardEnabled\|configuredFastForwardPercent\|selectFastForwardSpeed\|turnOffFastForward" Common/Swift/PauseMenuView.swift` must return nothing.

- [ ] **Step 6: Run tests and the gates**

Run: `make test TEST_ARGS="-only-testing:iCubeTests/PauseFastForwardStateTests -only-testing:iCubeTests/PauseMenuModelBuilderTests"` → PASS. tvOS compile gate → `BUILD SUCCEEDED`. Repeat Step 1 on the preview: badge now reads 2X, 3X, 4X, 8X.

- [ ] **Step 7: Commit**

```sh
git add Common/Swift/PauseFastForwardState.swift Common/Swift/PauseMenuView.swift DolphiniOSTests/PauseFastForwardStateTests.swift
git commit -m "fix(pause): fast-forward tile cycles past 2x"
```

### Task 4: Performance HUD tile replaces the floating speedometer button

**Files:**
- Modify: `Common/Swift/PauseMenuView.swift:246-253, 733-760, 836-850`
- Modify: `Common/Swift/EmulationScreen.swift:531-561, 1063-1069`
- Modify: `Common/UI/Localization/{en,ja}.lproj/Core.strings`
- Test: `DolphiniOSTests/PauseMenuModelBuilderTests.swift`

**Interfaces:**
- Produces: `PauseMenuActions.openPerfOverlay: () -> Void`; `PauseMenuView.init(selectedSlot:onClose:onShowSettings:onShowPerfOverlay:platform:game:)` with `onShowPerfOverlay` defaulting to `{}`; tile id `"perf-hud"`.

- [ ] **Step 1: Failing test**

```swift
// PauseMenuModelBuilderTests — add
func test_perfHUD_tile_isInGameSection_andCallsOpenPerfOverlay() {
  let m = PauseMenuModelBuilder.make(state: state(), bindings: bindings(), actions: actions())
  let item = m.item(id: "perf-hud")!
  XCTAssertEqual(m.section(containing: "perf-hud")?.id, "game")
  guard case .action(let run) = item.role else { return XCTFail("perf-hud is not an action") }
  run()
  XCTAssertEqual(log, ["perf"])
}
```

Add `openPerfOverlay: { self.log.append("perf") }` to the test's `actions()` helper (`state()` already exists in the file at line 31).

- [ ] **Step 2: Run, expect compile failure** (`openPerfOverlay` missing).

- [ ] **Step 3: Implement**

`PauseMenuActions` gains `var openPerfOverlay: () -> Void` (after `openSettings`). In `PauseMenuModelBuilder.make`, in the `game` array right after `save-states`:

```swift
MenuItem(id: "perf-hud", title: L("Performance HUD"), icon: "speedometer", tint: .cyan, role: .action(actions.openPerfOverlay),
         description: L("Frame rate, CPU and GPU timing drawn over the game.")),
```

`PauseMenuView`: add `let onShowPerfOverlay: () -> Void` and the init parameter `onShowPerfOverlay: @escaping () -> Void = {}` (keep argument order: after `onShowSettings`). Pass `openPerfOverlay: { onClose(); onShowPerfOverlay() }` where the view builds `PauseMenuActions` (line ~740). `EmulationScreen` tvOS and iOS presentations pass `onShowPerfOverlay: { refreshPerfOverlayState(); showPerfOverlay = true }`. Delete the tvOS `ZStack` overlay button (lines 540–560) so the cover is `PauseMenuView(...)` alone. Strings: add `"Performance HUD" = "Performance HUD";` and `"Frame rate, CPU and GPU timing drawn over the game." = "…";` to en, and ja lines `"Performance HUD" = "パフォーマンス HUD";`, `"Frame rate, CPU and GPU timing drawn over the game." = "フレームレート、CPU と GPU の処理時間をゲームの上に表示します。";`.

- [ ] **Step 4: Tests, gates**

`make test TEST_ARGS="-only-testing:iCubeTests/PauseMenuModelBuilderTests -only-testing:iCubeTests/PauseTileLayoutTests"`; `python3 Project/Scripts/check_localized_keys.py --check`; tvOS compile gate; `Scripts/tvos_screens.sh /tmp/p1 --no-build` after a sim build and confirm `pause-grid-dark.png` has no top-right button and shows the PERFORMANCE HUD tile. If `PauseTileLayoutTests` pins the tile count, update the expected count.

- [ ] **Step 5: Commit**

```sh
git add Common/Swift/PauseMenuView.swift Common/Swift/EmulationScreen.swift Common/UI/Localization DolphiniOSTests/PauseMenuModelBuilderTests.swift DolphiniOSTests/PauseTileLayoutTests.swift
git commit -m "feat(pause): Performance HUD tile replaces the floating button"
```

---

## Package 2: settings leaves on the iFly look

### Task 5: Leaf header and the design-module additions

**Files:**
- Create: `Common/Swift/MenuKit/ICubeLeafHeader.swift`
- Modify: `Common/Swift/MenuKit/ICubeDesign.swift` (after `enum Symbol`)
- Modify: `Common/Swift/MenuKit/ICubeDesign+Focus.swift` (end of file)
- Test: `DolphiniOSTests/ICubeLeafHeaderTests.swift` (new)

**Interfaces:**
- Produces:
  ```swift
  struct ICubeLeafHeader: View { let title: String; let subtitle: String? }
  extension ICubeLeafHeader { static func subtitle(parentTitle: String?) -> String }   // parent ?? L("Settings")
  extension EnvironmentValues { @Entry var icubeLeafParentTitle: String? }
  enum ICubeDesign.IconBadge { static let size: CGFloat = 44; static let tintOpacity: Double = 0.15 }
  extension View { func icubeRowChrome(focused: Bool) -> some View }
  ```

- [ ] **Step 1: Failing test**

```swift
// DolphiniOSTests/ICubeLeafHeaderTests.swift
import XCTest
@testable import iCube

final class ICubeLeafHeaderTests: XCTestCase {
  func test_subtitle_isSettingsAtTheRoot_andTheParentWhenPushed() {
    XCTAssertEqual(ICubeLeafHeader.subtitle(parentTitle: nil), "Settings")
    XCTAssertEqual(ICubeLeafHeader.subtitle(parentTitle: "Controllers"), "Controllers")
  }
  func test_iconBadge_isOnTheSpacingScaleOrTheOneAllowedSize() {
    XCTAssertEqual(ICubeDesign.IconBadge.size, 44)
  }
}
```

- [ ] **Step 2: Run, expect compile failure.**

- [ ] **Step 3: Implement**

```swift
// Common/Swift/MenuKit/ICubeLeafHeader.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The in-body title of a tvOS leaf (spec §4.2): display-face title, tag-role subtitle. The only
/// thing that draws a title on tvOS; `.navigationTitle` is not used there.
struct ICubeLeafHeader: View {
  let title: String
  let subtitle: String?

  var body: some View {
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
      Text(title)
        .icubeText(.title)
        .textCase(.uppercase)
        .foregroundStyle(ICubeDesign.titleGradient)
      if let subtitle {
        Text(subtitle)
          .icubeText(.tag)
          .foregroundStyle(ICubeDesign.color(.textSecondary))
      }
    }
    .padding(.bottom, ICubeDesign.Spacing.s.rawValue)
  }

  /// A root leaf is subtitled "Settings"; a pushed sub-leaf carries its parent's title.
  static func subtitle(parentTitle: String?) -> String {
    parentTitle ?? L("Settings")
  }
}

extension EnvironmentValues {
  /// Set on a pushed sub-leaf by `MenuScreen`: the title of the leaf that pushed it.
  @Entry var icubeLeafParentTitle: String? = nil
}
```

In `ICubeDesign.swift`, after `enum Symbol`:

```swift
extension ICubeDesign {
  /// The row icon badge (spec §3 Row): a 44 pt rounded square tinted at 15 %.
  enum IconBadge {
    static let size: CGFloat = 44
    static let tintOpacity: Double = 0.15
  }
}
```

In `ICubeDesign+Focus.swift`, at the end:

```swift
extension View {
  /// Row surface plus the focus ring, glow and scale, for a row that is not a `Button` (the stepped
  /// picker row reads left/right itself). Same drawing as `ICubeRowButtonStyle`.
  func icubeRowChrome(focused: Bool) -> some View {
    padding(.horizontal, ICubeDesign.Spacing.m.rawValue)
      .padding(.vertical, ICubeDesign.Spacing.s.rawValue)
      .frame(maxWidth: .infinity, minHeight: ICubeRowButtonStyle.minHeight, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous)
          .fill(focused ? ICubeDesign.color(.selectedFill) : ICubeDesign.color(.rowSurface))
      )
      .modifier(ICubeFocusChrome(focused: focused, pressed: false,
                                 radius: ICubeDesign.Radius.small.rawValue, scale: ICubeDesign.Motion.rowFocusScale))
  }
}
```

`ICubeRowButtonStyle.minHeight` is `fileprivate static`; it stays so because this extension is in the same file.

Spec §4.3 gives the row surface a 1 pt hairline. Add it to BOTH `ICubeRowButtonChrome.body` (after `.background(…)`) and `icubeRowChrome` (same place):

```swift
.overlay(
  RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous)
    .stroke(ICubeDesign.color(.hairline), lineWidth: ICubeDesign.Line.hairline.rawValue)
)
```

The focus ring drawn by `ICubeFocusChrome` sits on top of it when focused.

- [ ] **Step 4: Test, gate, commit**

`tuist generate --no-open`; `make test TEST_ARGS="-only-testing:iCubeTests/ICubeLeafHeaderTests -only-testing:iCubeTests/ICubeDesignTests"`; tvOS compile gate.

```sh
git add Common/Swift/MenuKit/ICubeLeafHeader.swift Common/Swift/MenuKit/ICubeDesign.swift Common/Swift/MenuKit/ICubeDesign+Focus.swift DolphiniOSTests/ICubeLeafHeaderTests.swift
git commit -m "feat(design): leaf header, icon badge and row chrome tokens"
```

### Task 6: `MenuScreen` draws the header; leaves stop using `.navigationTitle` on tvOS

**Files:**
- Modify: `Common/Swift/Menu/MenuScreen.swift:87-110, 800-820, 879-890`
- Modify: `Common/UI/Settings/SwiftUI/SettingsLeafHost.swift:44-48, 86-90`
- Test: `DolphiniOSTests/SettingsLeafScreenTests.swift`

**Interfaces:**
- Produces: `MenuScreen.init(model:style:onBack:modal:tvHeader:tvInset:)` with `tvHeader: ICubeLeafHeader? = nil`, `tvInset: ICubeDesign.Spacing = .l`.

- [ ] **Step 1: Failing test**

```swift
// SettingsLeafScreenTests — add
func test_tvHeader_usesParentTitleAsSubtitle() {
  XCTAssertEqual(SettingsLeafScreen.header(title: "Players", parentTitle: "Controllers").subtitle, "Controllers")
  XCTAssertEqual(SettingsLeafScreen.header(title: "Audio", parentTitle: nil).subtitle, "Settings")
  XCTAssertEqual(SettingsLeafScreen.header(title: "Audio", parentTitle: nil).title, "Audio")
}
```

- [ ] **Step 2: Run, expect compile failure.**

- [ ] **Step 3: Implement**

`MenuScreen`: add stored properties `var tvHeader: ICubeLeafHeader?` and `var tvInset: ICubeDesign.Spacing` and extend the init:

```swift
init(model: MenuModel, style: MenuStyle = .list, onBack: (() -> Void)? = nil, modal: MenuModal? = nil,
     tvHeader: ICubeLeafHeader? = nil, tvInset: ICubeDesign.Spacing = .l) {
  … existing assignments …
  self.tvHeader = tvHeader
  self.tvInset = tvInset
}
```

In `tvListBody`, the `VStack` content becomes:

```swift
VStack(alignment: .leading, spacing: ICubeDesign.Spacing.s.rawValue) {
  if let tvHeader { tvHeader }
  ForEach(model.sections) { section in … unchanged … }
}
.padding(.vertical, ICubeDesign.Spacing.l.rawValue)
.padding(.horizontal, tvInset.rawValue)
```

In `tvRow`'s `.destination` case, give the pushed view the parent title:

```swift
case .destination(let destinationView):
  NavigationLink {
    destinationView.clearingSettingsPaneBack().environment(\.icubeLeafParentTitle, tvHeader?.title)
  } label: { rowLabel(item) }
```

`SettingsLeafHost`: the modifier keeps `.navigationTitle(title)` under `#if !os(tvOS)` only. `SettingsLeafScreen` gains `@Environment(\.icubeLeafParentTitle) private var parentTitle` and

```swift
static func header(title: String, parentTitle: String?) -> ICubeLeafHeader {
  ICubeLeafHeader(title: title, subtitle: ICubeLeafHeader.subtitle(parentTitle: parentTitle))
}

var body: some View {
  #if os(tvOS)
  MenuScreen(model: model, style: .list, onBack: Self.backAction(paneBack: paneBack, dismiss: { dismiss() }),
             tvHeader: Self.header(title: title, parentTitle: parentTitle), tvInset: .xxl)
    .settingsLeaf(title: title, helpKey: helpKey, sync: sync)
  #else
  … unchanged …
  #endif
}
```

- [ ] **Step 4: Tests, gates, screenshots**

`make test TEST_ARGS="-only-testing:iCubeTests/SettingsLeafScreenTests -only-testing:iCubeTests/MenuModelTests -only-testing:iCubeTests/MenuFocusRouterTests"`; tvOS gate; `Scripts/tvos_screens.sh /tmp/p2 --dark` (builds) and read `settings-interface-dark.png`: an uppercase "INTERFACE" title with "SETTINGS" beneath, rows inset 80 from the pane edge.

- [ ] **Step 5: Commit**

```sh
git add Common/Swift/Menu/MenuScreen.swift Common/UI/Settings/SwiftUI/SettingsLeafHost.swift DolphiniOSTests/SettingsLeafScreenTests.swift
git commit -m "feat(tvos): in-body leaf titles instead of navigationTitle"
```

### Task 7: Row anatomy: icon badge, value colours, selected picker rows, stepped row chrome

**Files:**
- Modify: `Common/Swift/Menu/MenuScreen.swift:338-390 (tvRowLabel), 440-446, 879-935, 950-975`
- Modify: `Project/Scripts/design_tokens_baseline.json` (via `--update`)
- Test: `DolphiniOSTests/MenuModelTests.swift`

**Interfaces:**
- Produces: `MenuItemRole.valueTint(for role: MenuItemRole, value: AnyHashable?) -> ICubeColorRole` is NOT introduced; the rule lives in `MenuScreen` as `tvValueColor(_:)` below. Nothing outside `MenuScreen` changes.

- [ ] **Step 1: Failing test** (the one pure piece: which value text a row shows)

```swift
// MenuModelTests — add
func test_currentValueTitle_forExplodedPicker_isSelectedOptionTitle() {
  let sel = Binding<AnyHashable>(get: { AnyHashable(2) }, set: { _ in })
  let item = MenuItem(id: "x", title: "X", role: .picker(options: [("One", 1), ("Two", 2)], selection: sel))
  XCTAssertEqual(item.currentValueTitle, "Two")
}
func test_currentValueTitle_forCycleOffLadder_isDash() {
  let sel = Binding<AnyHashable>(get: { AnyHashable(150) }, set: { _ in })
  let item = MenuItem(id: "x", title: "X", role: .cycle(options: [("2x", 200)], selection: sel))
  XCTAssertEqual(item.currentValueTitle, "—")
}
```

```swift
func test_disabledPicker_keepsItsValue_andIsNotFocusable() {
  let sel = Binding<AnyHashable>(get: { AnyHashable(2) }, set: { _ in })
  let item = MenuItem(id: "x", title: "X", role: .picker(options: [("One", 1), ("Two", 2)], selection: sel), isEnabled: false)
  XCTAssertEqual(item.currentValueTitle, "Two")
  XCTAssertFalse(MenuModel(sections: [MenuSection(id: "s", items: [item])]).focusableIDs.contains("x"))
}
```

All three pass on today's code (they pin Review Focus 2 and 3 for the row); keep them.

- [ ] **Step 2: Rewrite `tvRowLabel`**

```swift
#if os(tvOS)
/// How a trailing value is coloured (spec §4.3): a live choice in accent, Off/neutral in secondary.
private enum TVValueStyle { case accent, neutral }

private func tvRowLabel(
  title: String, subtitle: String?, icon: String?, tint: Color?, badge: String?,
  value: String?, valueStyle: TVValueStyle = .neutral, description: String?, showsChevron: Bool
) -> some View {
  HStack(spacing: ICubeDesign.Spacing.m.rawValue) {
    if let icon {
      Image(systemName: icon)
        .font(ICubeDesign.symbolFont(.shelf))
        .foregroundStyle(tint ?? ICubeDesign.color(.accent))
        .frame(width: ICubeDesign.IconBadge.size, height: ICubeDesign.IconBadge.size)
        .background(
          RoundedRectangle(cornerRadius: ICubeDesign.Radius.small.rawValue, style: .continuous)
            .fill((tint ?? ICubeDesign.color(.accent)).opacity(ICubeDesign.IconBadge.tintOpacity)))
    }
    VStack(alignment: .leading, spacing: ICubeDesign.Spacing.xxs.rawValue) {
      Text(title)
        .icubeText(.nav)
        .foregroundStyle(ICubeDesign.color(.textPrimary))
        .lineLimit(1)
      if let subtitle {
        Text(subtitle).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary)).lineLimit(1)
      }
      if let description {
        Text(description).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary)).lineLimit(1)
      }
    }
    Spacer(minLength: ICubeDesign.Spacing.m.rawValue)
    if let value {
      Text(value)
        .icubeText(.body)
        .foregroundStyle(valueStyle == .accent ? ICubeDesign.color(.accent) : ICubeDesign.color(.textSecondary))
        .lineLimit(1)
    }
    if let badge {
      Text(badge).icubeText(.tag).foregroundStyle(ICubeDesign.color(.textSecondary))
    }
    if showsChevron {
      Image(systemName: "chevron.right").foregroundStyle(ICubeDesign.color(.textTertiary))
    }
  }
}
#endif
```

`rowLabel(...)` gains `valueStyle` only on tvOS: add a tvOS-only overload

```swift
#if os(tvOS)
private func rowLabel(_ item: MenuItem, value: String?, valueStyle: TVValueStyle) -> some View {
  tvRowLabel(title: item.title, subtitle: item.subtitle, icon: item.icon, tint: item.tint, badge: item.badge,
             value: value, valueStyle: valueStyle, description: item.description, showsChevron: item.showsChevron)
}
#endif
```

- [ ] **Step 3: Use it in `tvRow`**

- `.toggle`: label `rowLabel(item, value: on ? L("On") : L("Off"), valueStyle: on ? .accent : .neutral)` where `let on = binding.wrappedValue`.
- `.cycle`: label `rowLabel(item, value: "‹ \(item.currentValueTitle ?? "—") ›", valueStyle: .accent)`.
- `.picker` (exploded): each option row's label becomes `rowLabel(title: option.0, subtitle: nil, icon: nil, tint: nil, badge: nil, value: selected ? L("Selected") : nil, valueStyle: .accent, description: nil, showsChevron: false)` with `let selected = option.1 == selection.wrappedValue`; add `.buttonStyle(ICubeRowButtonStyle(isSelected: selected))` on that `Button`; delete the checkmark `Image`.
- `.destination`, `.action`, `.destructive`, `.navigation`: unchanged labels; for `.destructive` wrap the label in `.foregroundStyle(ICubeDesign.color(.destructive))` so icon and title read destructive.
- `.custom`: unchanged (the custom view renders itself, no row chrome).

- [ ] **Step 4: Stepped row on the row chrome**

Replace `tvSteppedRow`'s body:

```swift
HStack(spacing: ICubeDesign.Spacing.m.rawValue) {
  rowLabel(item)
  Spacer(minLength: 0)
  Image(systemName: "chevron.left").foregroundStyle(ICubeDesign.color(.textTertiary))
  Text(valueTitle).icubeText(.tag).foregroundStyle(ICubeDesign.color(.accent)).monospacedDigit()
  Image(systemName: "chevron.right").foregroundStyle(ICubeDesign.color(.textTertiary))
}
.contentShape(Rectangle())
.focusable(item.isEnabled)
.focused($tvFocusedID, equals: item.id)
.icubeRowChrome(focused: tvFocusedID == item.id)
.opacity(item.isEnabled ? 1 : 0.5)
.onMoveCommand { … unchanged … }
```

This removes the `cornerRadius: 10`, `lineWidth: 4`, `Color.accentColor` and `padding(8)` lines.

- [ ] **Step 5: Headers and footers**

`tvListSectionHeader`: `.foregroundStyle(ICubeDesign.color(.textPrimary))`, `.padding(.top, ICubeDesign.Spacing.l.rawValue)`. Footer `Text` in `tvListBody`: `.foregroundStyle(ICubeDesign.color(.textSecondary)).padding(.horizontal, ICubeDesign.Spacing.m.rawValue).padding(.top, ICubeDesign.Spacing.xs.rawValue)`.

- [ ] **Step 6: Strings**

Add `"Selected" = "Selected";` (en) and `"Selected" = "選択中";` (ja) if `grep -n '^"Selected"' Common/UI/Localization/en.lproj/Core.strings` finds nothing.

- [ ] **Step 7: Gates, baseline, screenshots**

`python3 Project/Scripts/check_design_tokens.py --check` must report `MenuScreen.swift` below 16 and ask for `--update`; run `--update`. `check_localized_keys.py --check`. tvOS gate. `make test TEST_ARGS="-only-testing:iCubeTests/MenuModelTests -only-testing:iCubeTests/PlayerScreenLeavesTests"`. Screenshots: `settings-general-dark.png` (toggles: On in accent), `settings-graphics-enhancements-dark.png` (a cycle row with ‹ › in accent), `settings-performance-tuning-dark.png` (an exploded picker with one SELECTED row), `settings-controllers-dark.png` (hub rows with badges). Read each with the Read tool; no white capsule anywhere.

- [ ] **Step 8: Commit**

```sh
git add Common/Swift/Menu/MenuScreen.swift Project/Scripts/design_tokens_baseline.json Common/UI/Localization DolphiniOSTests/MenuModelTests.swift
git commit -m "feat(tvos): settings rows on the iFly anatomy"
```

### Task 8: Sidebar selection in accent, hairline divider, header colour

**Files:**
- Modify: `Common/UI/Settings/SwiftUI/SettingsSidebarShell.swift:52-60, 126-160`
- Modify: `Project/Scripts/design_tokens_baseline.json`

- [ ] **Step 1: Implement**

Replace `Divider()` in `body` with

```swift
#if os(tvOS)
Rectangle().fill(ICubeDesign.color(.hairline)).frame(width: ICubeDesign.Line.hairline.rawValue)
#else
Divider()
#endif
```

In `tvSidebarList`: the section header `Text` → `.foregroundStyle(ICubeDesign.color(.textPrimary))`; the row label:

```swift
let selected = selectedID == entry.id
HStack(spacing: ICubeDesign.Spacing.s.rawValue) {
  Image(systemName: entry.icon)
    .font(ICubeDesign.symbolFont(.rail))
    .frame(width: ICubeDesign.Symbol.railColumn)
  Text(entry.title).icubeText(.nav).lineLimit(1)
  Spacer(minLength: 0)
}
.foregroundStyle(selected ? ICubeDesign.color(.accent) : ICubeDesign.color(.textPrimary))
```

- [ ] **Step 2: Gates, screenshot, commit**

tvOS gate; `check_design_tokens.py --check` then `--update` (the file's count goes to 0); `Scripts/tvos_screens.sh /tmp/p3 --dark` → `settings-audio-dark.png`: selected row's icon and text in accent, a 1 pt line between sidebar and pane.

```sh
git add Common/UI/Settings/SwiftUI/SettingsSidebarShell.swift Project/Scripts/design_tokens_baseline.json
git commit -m "fix(tvos): settings sidebar selection and hairline"
```

### Task 9: About on the engine (tvOS)

**Files:**
- Create: `Common/UI/Settings/SwiftUI/AboutModelBuilder.swift`
- Modify: `Common/UI/Settings/SwiftUI/AboutView.swift:33-150`
- Modify: `Common/UI/Localization/{en,ja}.lproj/Core.strings`
- Test: `DolphiniOSTests/AboutModelBuilderTests.swift` (new)

**Interfaces:**
- Produces:
  ```swift
  struct AboutLinks { static let github, site, dolphinios, dolphin, icube, source: URL }
  enum AboutModelBuilder {
    static func make(appVersion: String, coreVersion: String, open: @escaping (URL) -> Void,
                     blog: AnyView, help: AnyView, resetAll: @escaping () -> Void) -> MenuModel
  }
  ```

- [ ] **Step 1: Failing test**

```swift
// DolphiniOSTests/AboutModelBuilderTests.swift
import SwiftUI
import XCTest
@testable import iCube

final class AboutModelBuilderTests: XCTestCase {
  private var opened: [URL] = []
  private var resets = 0
  private func model() -> MenuModel {
    AboutModelBuilder.make(appVersion: "3.4.0 (12)", coreVersion: "5.0-2345", open: { self.opened.append($0) },
                           blog: AnyView(EmptyView()), help: AnyView(EmptyView()), resetAll: { self.resets += 1 })
  }

  func test_sections_andOrder() {
    XCTAssertEqual(model().sections.map(\.header), ["Version", "iCube", "Dolphin", "Help", nil])
    XCTAssertEqual(model().allItems.map(\.id),
                   ["version", "core", "icube-site", "source", "author-github", "author-site",
                    "dolphinios", "dolphin", "blog", "help", "reset-all"])
  }

  func test_linkRows_openTheirURL() {
    let m = model()
    for (id, url) in [("icube-site", AboutLinks.icube), ("source", AboutLinks.source), ("dolphin", AboutLinks.dolphin)] {
      guard case .action(let run) = m.item(id: id)?.role else { return XCTFail(id) }
      opened = []; run(); XCTAssertEqual(opened, [url], id)
    }
  }

  func test_resetAll_isDestructive_andEveryRowDescribed() {
    guard case .destructive = model().item(id: "reset-all")?.role else { return XCTFail() }
    for item in model().allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
  }
}
```

- [ ] **Step 2: Run, expect compile failure.**

- [ ] **Step 3: Implement the builder**

```swift
// Common/UI/Settings/SwiftUI/AboutModelBuilder.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

enum AboutLinks {
  static let github = URL(string: "https://github.com/JoeMatt")!
  static let site = URL(string: "https://joemattiello.dev")!
  static let dolphinios = URL(string: "https://dolphinios.oatmealdome.me")!
  static let dolphin = URL(string: "https://dolphin-emu.org")!
  static let icube = URL(string: "https://icube-emu.com")!
  static let source = URL(string: "https://github.com/Provenance-Emu/iCube")!
}

/// Pure: the About leaf as rows. Captions carry the legal text the hand-built screen showed.
enum AboutModelBuilder {
  static func make(appVersion: String, coreVersion: String, open: @escaping (URL) -> Void,
                   blog: AnyView, help: AnyView, resetAll: @escaping () -> Void) -> MenuModel {
    let version = MenuSection(id: "version", header: L("Version"),
                              footer: L("iCube is an unofficial and separately maintained port of Dolphin to iOS. The iCube Project has no relation to Dolphin Team."),
                              items: [
      SettingsRow.action("version", L("Version"), L("The app version and build number."), icon: "app.badge", badge: appVersion) {},
      SettingsRow.action("core", L("Core"), L("The Dolphin core this build embeds."), icon: "cpu", badge: coreVersion) {},
    ])
    let icube = MenuSection(id: "icube", header: L("iCube"), footer: L("SwiftUI version by Joe Mattiello"), items: [
      SettingsRow.action("icube-site", "icube-emu.com", L("The iCube website."), icon: "globe") { open(AboutLinks.icube) },
      SettingsRow.action("source", L("Source Code"), L("iCube on GitHub."), icon: "chevron.left.forwardslash.chevron.right") { open(AboutLinks.source) },
      SettingsRow.action("author-github", "github.com/JoeMatt", L("The author on GitHub."), icon: "person") { open(AboutLinks.github) },
      SettingsRow.action("author-site", "joemattiello.dev", L("The author's site."), icon: "person.text.rectangle") { open(AboutLinks.site) },
    ])
    let dolphin = MenuSection(id: "dolphin", header: L("Dolphin"),
                              footer: L("iCube is a fork of OatmealDome's DolphiniOS, based on the Dolphin emulator."), items: [
      SettingsRow.action("dolphinios", "dolphinios.oatmealdome.me", L("DolphiniOS, which iCube forked."), icon: "globe") { open(AboutLinks.dolphinios) },
      SettingsRow.action("dolphin", "dolphin-emu.org", L("The Dolphin emulator."), icon: "globe") { open(AboutLinks.dolphin) },
    ])
    let helpSection = MenuSection(id: "help", header: L("Help"), items: [
      SettingsRow.destination("blog", L("Dolphin Blog"), L("Progress reports from the Dolphin team."), icon: "newspaper", view: blog),
      SettingsRow.destination("help", L("Help"), L("The iCube wiki."), icon: "questionmark.circle", view: help),
    ])
    let maintenance = MenuSection(id: "maintenance",
                                  footer: L("\"GameCube\" and \"Wii\" are trademarks of Nintendo. iCube is not affiliated with Nintendo in any way. This software should not be used to play games you do not legally own."),
                                  items: [
      SettingsRow.destructive("reset-all", L("Reset All Settings"), L("Resets every setting to its default. May require restarting emulation."),
                              icon: "arrow.counterclockwise", run: resetAll),
    ])
    return MenuModel(sections: [version, icube, dolphin, helpSection, maintenance])
  }
}
```

Check `SettingsRow.destructive`'s parameter label (`run:`) at `SettingsRowFactory.swift:55` and `SettingsRow.action`'s `badge:` label; match them.

- [ ] **Step 4: tvOS branch in `AboutView`**

Wrap the existing `body` content in `#if os(tvOS) … #else … #endif`; the tvOS branch:

```swift
@State private var confirmReset = false
…
#if os(tvOS)
MenuScreen(model: AboutModelBuilder.make(
    appVersion: VersionManager.shared().appVersion.userFacing, coreVersion: VersionManager.shared().coreVersion,
    open: { openURL($0) }, blog: AnyView(DolphinBlogView()), help: AnyView(WikiHelpView()),
    resetAll: { confirmReset = true }),
  style: .list, onBack: SettingsLeafScreen.backAction(paneBack: paneBack, dismiss: { dismiss() }),
  tvHeader: SettingsLeafScreen.header(title: L("About"), parentTitle: parentTitle), tvInset: .xxl)
  .alert(L("Reset All Settings"), isPresented: $confirmReset) {
    Button(L("Cancel"), role: .cancel) {}
    Button(L("Reset"), role: .destructive) { DOLConfigBridge.resetAllToDefaults() }
  } message: { Text(L("This will reset all settings to factory defaults. This may require restarting emulation.")) }
#else
… the existing ScrollView body, unchanged …
#endif
```

with `@Environment(\.dismiss) private var dismiss`, `@Environment(\.settingsPaneBack) private var paneBack`, `@Environment(\.icubeLeafParentTitle) private var parentTitle`. The `.navigationTitle(L("About iCube"))` line moves inside the `#else`. The logo animation stays iOS-only; the tvOS leaf has no logo (the title is the brand).

- [ ] **Step 5: Strings, tests, gates, screenshot, commit**

New keys: every `L("…")` above that `grep` does not find in `en.lproj/Core.strings` (at least the descriptions and "Version", "Core", "iCube", "Dolphin", "Help", "Source Code" may exist). Add en and ja lines. `tuist generate --no-open`; `make test TEST_ARGS="-only-testing:iCubeTests/AboutModelBuilderTests"`; `check_localized_keys.py --check`; tvOS gate; `check_design_tokens.py --check` (AboutView's 6 are iOS-only lines and stay); screenshot `settings-about-dark.png`.

```sh
git add Common/UI/Settings/SwiftUI/AboutModelBuilder.swift Common/UI/Settings/SwiftUI/AboutView.swift Common/UI/Localization DolphiniOSTests/AboutModelBuilderTests.swift
git commit -m "feat(tvos): About leaf on the menu engine"
```

### Task 10: Web UI on the engine (tvOS)

**Files:**
- Create: `Common/UI/Settings/SwiftUI/WebUIModelBuilder.swift`
- Modify: `Common/UI/Settings/SwiftUI/WebUISettingsView.swift:26-45`
- Test: `DolphiniOSTests/WebUIModelBuilderTests.swift` (new)

**Interfaces:**
- Produces: `enum WebUIModelBuilder { static func make(webURL: String, webDavURL: String, open: @escaping (URL) -> Void) -> MenuModel }`

- [ ] **Step 1: Failing test**

```swift
// DolphiniOSTests/WebUIModelBuilderTests.swift
import XCTest
@testable import iCube

final class WebUIModelBuilderTests: XCTestCase {
  func test_rows_showAddresses_asBadges() {
    let m = WebUIModelBuilder.make(webURL: "http://192.168.1.2/", webDavURL: "http://192.168.1.2/", open: { _ in })
    XCTAssertEqual(m.allItems.map(\.id), ["web-ui", "webdav", "learn-more"])
    XCTAssertEqual(m.item(id: "web-ui")?.badge, "http://192.168.1.2/")
    XCTAssertEqual(m.item(id: "webdav")?.badge, "http://192.168.1.2/")
    XCTAssertFalse(m.sections[0].footer?.isEmpty ?? true)
  }
  func test_notRunning_showsNotRunning_andRowsStayDescribed() {
    let m = WebUIModelBuilder.make(webURL: "", webDavURL: "", open: { _ in })
    XCTAssertEqual(m.item(id: "web-ui")?.badge, "Not Running")
    for item in m.allItems { XCTAssertFalse((item.description ?? "").isEmpty, item.id) }
  }
}
```

- [ ] **Step 2: Run, expect compile failure.**

- [ ] **Step 3: Implement**

```swift
// Common/UI/Settings/SwiftUI/WebUIModelBuilder.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Pure: the upload server's addresses as rows. The addresses are badges (tag role) so they read as
/// values, and the rows are focusable so the info shelf explains each one.
enum WebUIModelBuilder {
  static let helpURL = URL(string: "https://icube-emu.com/help/web-import")!

  static func make(webURL: String, webDavURL: String, open: @escaping (URL) -> Void) -> MenuModel {
    func shown(_ s: String) -> String { s.isEmpty ? L("Not Running") : s }
    let addresses = MenuSection(id: "addresses", header: L("Addresses"),
      footer: L("Drop GameCube and Wii files onto iCube from a computer or phone on the same Wi-Fi. Open the address in a browser, or in Finder choose Go › Connect to Server and enter the same address as Guest."),
      items: [
        SettingsRow.action("web-ui", L("Web UI"), L("Open this address in a browser on another device to upload games."), icon: "globe", badge: shown(webURL)) {},
        SettingsRow.action("webdav", L("Finder / WebDAV"), L("Connect to this address from Finder as Guest to drag files in."), icon: "externaldrive.connected.to.line.below", badge: shown(webDavURL)) {},
      ])
    let help = MenuSection(id: "help", items: [
      SettingsRow.action("learn-more", L("Learn more"), helpURL.absoluteString, icon: "questionmark.circle") { open(helpURL) },
    ])
    return MenuModel(sections: [addresses, help])
  }
}
```

In `WebUISettingsView`, under `#if os(tvOS)` the body becomes a `MenuScreen` with `tvHeader: SettingsLeafScreen.header(title: L("Web UI & WebDAV"), parentTitle: parentTitle)`, `tvInset: .xl`, keeping `.task { await refresh() }`. iOS branch unchanged.

- [ ] **Step 4: Strings, tests, gates, screenshot, commit** (as Task 9, with `settings-web-ui-dark.png`)

```sh
git commit -m "feat(tvos): Web UI leaf on the menu engine"
```

### Task 11: iCloud Sync on the engine (tvOS)

**Files:**
- Create: `Common/UI/Settings/SwiftUI/CloudSyncModelBuilder.swift`
- Modify: `Common/UI/Settings/SwiftUI/CloudSyncSettingsView.swift:19-36`
- Test: `DolphiniOSTests/CloudSyncModelBuilderTests.swift` (new)

**Interfaces:**
- Produces:
  ```swift
  struct CloudSyncSnapshot {   // what the builder sees; built from CloudSyncCoordinator in the view
    var isEnabled: Bool; var isSyncing: Bool; var unavailableReason: String?; var lastError: String?
    var lastSyncDate: Date?; var countsByType: [SyncableFileType: Int]; var bytesByType: [SyncableFileType: Int64]
    var totalFiles: Int; var formattedTotalSize: String; var errorFiles: Int; var pendingConflicts: Int
    var recentEvents: [(message: String, file: String?)]
  }
  enum CloudSyncChange: Equatable { case enabled(Bool), syncNow, clearCloudData }
  enum CloudSyncModelBuilder { static func make(_ s: CloudSyncSnapshot, conflicts: AnyView, apply: @escaping (CloudSyncChange) -> Void) -> MenuModel }
  ```

- [ ] **Step 1: Failing test**

```swift
// DolphiniOSTests/CloudSyncModelBuilderTests.swift
import SwiftUI
import XCTest
@testable import iCube

final class CloudSyncModelBuilderTests: XCTestCase {
  private var changes: [CloudSyncChange] = []
  private func snap(enabled: Bool = true, syncing: Bool = false, reason: String? = nil, conflicts: Int = 0) -> CloudSyncSnapshot {
    CloudSyncSnapshot(isEnabled: enabled, isSyncing: syncing, unavailableReason: reason, lastError: nil, lastSyncDate: nil,
                      countsByType: [.saveState: 3], bytesByType: [.saveState: 2048], totalFiles: 3, formattedTotalSize: "2 KB",
                      errorFiles: 0, pendingConflicts: conflicts, recentEvents: [])
  }
  private func model(_ s: CloudSyncSnapshot) -> MenuModel {
    CloudSyncModelBuilder.make(s, conflicts: AnyView(EmptyView())) { self.changes.append($0) }
  }

  func test_disabled_showsOnlyStatusAndScope() {
    XCTAssertEqual(model(snap(enabled: false)).sections.map(\.id), ["status", "scope"])
  }
  func test_unavailableReason_disablesSyncNow_andIsTheFooter() {
    let m = model(snap(reason: "No iCloud account"))
    XCTAssertEqual(m.item(id: "sync-now")?.isEnabled, false)
    XCTAssertEqual(m.sections[0].footer, "No iCloud account")
  }
  func test_conflicts_sectionAppearsWithCount() {
    let m = model(snap(conflicts: 2))
    XCTAssertTrue(m.sections.map(\.id).contains("conflicts"))
    XCTAssertEqual(m.item(id: "conflicts")?.badge, "2")
  }
  func test_toggle_syncNow_clear_emitChanges() {
    let m = model(snap())
    guard case .toggle(let b) = m.item(id: "enabled")?.role else { return XCTFail() }
    b.wrappedValue = false
    guard case .action(let sync) = m.item(id: "sync-now")?.role else { return XCTFail() }
    sync()
    guard case .destructive(let clear) = m.item(id: "clear")?.role else { return XCTFail() }
    clear()
    XCTAssertEqual(changes, [.enabled(false), .syncNow, .clearCloudData])
  }
}
```

- [ ] **Step 2: Run, expect compile failure.**

- [ ] **Step 3: Implement**

```swift
// Common/UI/Settings/SwiftUI/CloudSyncModelBuilder.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct CloudSyncSnapshot {
  var isEnabled: Bool
  var isSyncing: Bool
  var unavailableReason: String?
  var lastError: String?
  var lastSyncDate: Date?
  var countsByType: [SyncableFileType: Int]
  var bytesByType: [SyncableFileType: Int64]
  var totalFiles: Int
  var formattedTotalSize: String
  var errorFiles: Int
  var pendingConflicts: Int
  var recentEvents: [(message: String, file: String?)]
}

enum CloudSyncChange: Equatable { case enabled(Bool), syncNow, clearCloudData }

/// Pure: mirrors `CloudSyncSettingsView`'s Form section for section. Read-only lines are captions.
enum CloudSyncModelBuilder {
  static func make(_ s: CloudSyncSnapshot, conflicts: AnyView, apply: @escaping (CloudSyncChange) -> Void) -> MenuModel {
    var sections: [MenuSection] = []

    var statusItems: [MenuItem] = [
      SettingsRow.toggle("enabled", L("Sync This Device"), s.isEnabled,
                         L("Keeps save states, memory cards, Wii saves and settings in step across your devices."),
                         icon: "icloud", set: { apply(.enabled($0)) }),
    ]
    if s.isEnabled {
      if let last = s.lastSyncDate {
        statusItems.append(SettingsRow.caption("last-synced", String(format: L("Last synced %@"), last.formatted(date: .abbreviated, time: .shortened))))
      }
      statusItems.append(SettingsRow.action("sync-now", L("Sync Now"), L("Runs a sync pass right away."), icon: "arrow.triangle.2.circlepath",
                                            enabled: !s.isSyncing && s.unavailableReason == nil) { apply(.syncNow) })
    }
    let footer = s.unavailableReason ?? s.lastError
      ?? L("Save states, memory cards, Wii saves and settings are kept in step across your devices. Games are never uploaded.")
    sections.append(MenuSection(id: "status", header: L("iCloud Sync"), footer: footer, items: statusItems))

    if s.isEnabled {
      if s.pendingConflicts > 0 {
        sections.append(MenuSection(id: "conflicts", header: L("Needs Your Decision"), items: [
          SettingsRow.destination("conflicts", L("Conflicts"), L("Files changed on two devices. Choose which copy to keep."),
                                  icon: "exclamationmark.icloud.fill", view: conflicts)
            .with { $0.badge = "\(s.pendingConflicts)" },
        ]))
      }
      var contents: [MenuItem] = []
      if s.totalFiles == 0 {
        contents.append(SettingsRow.caption("nothing", L("Nothing synced yet.")))
      } else {
        for type in SyncableFileType.allCases.sorted(by: { $0.pullPriority < $1.pullPriority }) {
          let count = s.countsByType[type] ?? 0
          if count > 0 {
            let bytes = ByteCountFormatter.string(fromByteCount: s.bytesByType[type] ?? 0, countStyle: .file)
            contents.append(SettingsRow.caption("type-\(type)", "\(CloudSyncSettingsView.displayName(for: type)): \(count) · \(bytes)"))
          }
        }
        contents.append(SettingsRow.caption("total", "\(L("Total")): \(s.totalFiles) · \(s.formattedTotalSize)"))
        if s.errorFiles > 0 { contents.append(SettingsRow.caption("errors", "\(L("Files With Errors")): \(s.errorFiles)")) }
      }
      sections.append(MenuSection(id: "contents", header: L("Synced Contents"), items: contents))
      sections.append(MenuSection(id: "maintenance", footer: L("Removes this app's data from iCloud. Files on this device are not touched."), items: [
        SettingsRow.destructive("clear", L("Clear iCloud Data"), L("Deletes iCube's data from iCloud. Asks first."),
                                icon: "trash", enabled: !s.isSyncing, run: { apply(.clearCloudData) }),
      ]))
      if !s.recentEvents.isEmpty {
        sections.append(MenuSection(id: "activity", header: L("Recent Activity"),
                                    items: s.recentEvents.prefix(20).enumerated().map { i, e in
                                      SettingsRow.caption("event-\(i)", e.file.map { "\(e.message) — \($0)" } ?? e.message) }))
      }
    }
    sections.append(MenuSection(id: "scope", header: L("What Is Synced"), items: [
      SettingsRow.caption("scope-1", "✓ " + L("Save states and resume points")),
      SettingsRow.caption("scope-2", "✓ " + L("GameCube memory cards")),
      SettingsRow.caption("scope-3", "✓ " + L("Wii save data")),
      SettingsRow.caption("scope-4", "✓ " + L("Settings, per-game settings and cheats")),
      SettingsRow.caption("scope-5", "✗ " + L("Games are never uploaded")),
      SettingsRow.caption("scope-6", "✗ " + L("Cover art is not uploaded — it is re-downloaded instead")),
      SettingsRow.caption("scope-7", "✗ " + L("System firmware is never uploaded")),
    ]))
    return MenuModel(sections: sections)
  }
}

private extension MenuItem {
  func with(_ edit: (inout MenuItem) -> Void) -> MenuItem { var c = self; edit(&c); return c }
}
```

`SettingsRow.caption` renders `PlayerHelpCaption` (`.font(.footnote)`, iOS-styled). Add a tvOS branch to `PlayerHelpCaption.body`: `#if os(tvOS) Text(text).icubeText(.detail).foregroundStyle(ICubeDesign.color(.textSecondary)).padding(.horizontal, ICubeDesign.Spacing.m.rawValue) #else … #endif`.

`CloudSyncSettingsView` tvOS branch: build `CloudSyncSnapshot` from `coordinator` (`statistics.lastSyncDate`, `statistics.countsByType`, `statistics.bytesByType`, `statistics.totalFiles`, `statistics.formattedTotalSize`, `statistics.errorFiles`, `pendingConflicts.count`, `recentEvents.map { ($0.message, $0.file) }`, `unavailableReason?.localizedDescription`, `lastError`), render `MenuScreen(model:…, tvHeader: SettingsLeafScreen.header(title: L("iCloud Sync"), parentTitle: parentTitle), tvInset: .xxl)`, keep `.task { await coordinator.refreshAvailability() }`, and apply: `.enabled(v)` → `coordinator.isEnabled = v`; `.syncNow` → `Task { await coordinator.syncNow() }`; `.clearCloudData` → `showClearConfirmation = true` with the existing `.confirmationDialog` moved onto the `MenuScreen`.

- [ ] **Step 4: Strings, tests, gates, screenshot, commit** (`settings-icloud-dark.png`)

```sh
git commit -m "feat(tvos): iCloud Sync leaf on the menu engine"
```

### Task 12: Nearby, Share My Library and the grant detail on the engine (tvOS)

**Files:**
- Create: `Common/Continuity/UI/ContinuityBrowseModelBuilder.swift`
- Create: `Common/Continuity/UI/ContinuitySharingModelBuilder.swift`
- Modify: `Common/Continuity/UI/ContinuityBrowseView.swift:29-82`
- Modify: `Common/Continuity/UI/ContinuityLibrarySharingView.swift:23-82, 171-212`
- Test: `DolphiniOSTests/ContinuityModelBuildersTests.swift` (new)

**Interfaces:**
- Produces:
  ```swift
  struct ContinuityPeerSummary: Equatable { let id: String; let name: String; let subtitle: String; let glyph: String }
  enum ContinuityBrowseModelBuilder {
    static func make(peers: [ContinuityPeerSummary], trusted: [(id: String, name: String)], sharesLibrary: Bool, showsDone: Bool,
                     peerDetail: @escaping (String) -> AnyView, trustedDetail: @escaping (String) -> AnyView,
                     sharing: AnyView, done: @escaping () -> Void) -> MenuModel
  }
  struct ContinuityGrantRowSummary: Equatable { let peerId: String; let name: String; let grantTitle: String }
  enum ContinuitySharingModelBuilder {
    static func make(sharesLibrary: Bool, grants: [ContinuityGrantRowSummary], excluded: [(gameID: String, title: String)],
                     grantDetail: @escaping (String, String) -> AnyView,
                     setShares: @escaping (Bool) -> Void, shareAgain: @escaping (String) -> Void) -> MenuModel
    static func grant(peerName: String, current: ContinuityLibraryGrant, hasExplicitGrant: Bool,
                      choose: @escaping (ContinuityLibraryGrant) -> Void, clear: @escaping () -> Void) -> MenuModel
  }
  ```
  The security notice becomes the first section's footer text, read from `ContinuityManager.transportSecurityNotice` (the string `ContinuitySecurityNotice` already shows).

- [ ] **Step 1: Failing test**

```swift
// DolphiniOSTests/ContinuityModelBuildersTests.swift
import SwiftUI
import XCTest
@testable import iCube

final class ContinuityModelBuildersTests: XCTestCase {
  func test_browse_emptyPeers_showsLookingCaption_andSharingRow() {
    let m = ContinuityBrowseModelBuilder.make(peers: [], trusted: [], sharesLibrary: true, showsDone: false,
                                              peerDetail: { _ in AnyView(EmptyView()) }, trustedDetail: { _ in AnyView(EmptyView()) },
                                              sharing: AnyView(EmptyView()), done: {})
    XCTAssertEqual(m.sections.map(\.id), ["peers", "this-device"])
    XCTAssertEqual(m.item(id: "looking")?.isEnabled, false)
    XCTAssertEqual(m.item(id: "share-library")?.badge, "On")
    XCTAssertEqual(m.sections[0].footer, ContinuityManager.transportSecurityNotice)
  }
  func test_browse_peersAndTrusted_becomeDestinationRows() {
    let m = ContinuityBrowseModelBuilder.make(
      peers: [.init(id: "p1", name: "Joe's iPad", subtitle: "Playing Melee", glyph: "ipad")],
      trusted: [("t1", "Living Room TV")], sharesLibrary: false, showsDone: true,
      peerDetail: { _ in AnyView(EmptyView()) }, trustedDetail: { _ in AnyView(EmptyView()) }, sharing: AnyView(EmptyView()), done: {})
    XCTAssertEqual(m.allItems.map(\.id), ["peer-p1", "share-library", "trusted-t1", "done"])
    XCTAssertEqual(m.item(id: "peer-p1")?.subtitle, "Playing Melee")
  }
  func test_sharing_toggle_andShareAgain() {
    var shares: [Bool] = []; var again: [String] = []
    let m = ContinuitySharingModelBuilder.make(sharesLibrary: true, grants: [], excluded: [("GALE01", "Melee")],
                                               grantDetail: { _, _ in AnyView(EmptyView()) }, setShares: { shares.append($0) }, shareAgain: { again.append($0) })
    guard case .toggle(let b) = m.item(id: "share")?.role else { return XCTFail() }
    b.wrappedValue = false
    guard case .action(let run) = m.item(id: "excluded-GALE01")?.role else { return XCTFail() }
    run()
    XCTAssertEqual(shares, [false]); XCTAssertEqual(again, ["GALE01"])
  }
  func test_grant_isAPicker_withClearOnlyWhenExplicit() {
    var chosen: [ContinuityLibraryGrant] = []
    let explicit = ContinuitySharingModelBuilder.grant(peerName: "iPad", current: .askPerGame, hasExplicitGrant: true, choose: { chosen.append($0) }, clear: {})
    guard case .picker(let options, let sel) = explicit.item(id: "grant")?.role else { return XCTFail() }
    XCTAssertEqual(options.map(\.0), ["Always Allow", "Ask Every Time", "Don't Share"])
    sel.wrappedValue = AnyHashable(ContinuityLibraryGrant.everything)
    XCTAssertEqual(chosen, [.everything])
    XCTAssertNotNil(explicit.item(id: "clear"))
    XCTAssertNil(ContinuitySharingModelBuilder.grant(peerName: "iPad", current: .askPerGame, hasExplicitGrant: false, choose: { _ in }, clear: {}).item(id: "clear"))
  }
}
```

- [ ] **Step 2: Run, expect compile failure.**

- [ ] **Step 3: Implement the builders**

```swift
// Common/Continuity/UI/ContinuityBrowseModelBuilder.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct ContinuityPeerSummary: Equatable {
  let id: String
  let name: String
  let subtitle: String
  let glyph: String
}

/// Pure: the Nearby leaf (`ContinuityBrowseView`) as rows.
enum ContinuityBrowseModelBuilder {
  static func make(peers: [ContinuityPeerSummary], trusted: [(id: String, name: String)], sharesLibrary: Bool, showsDone: Bool,
                   peerDetail: @escaping (String) -> AnyView, trustedDetail: @escaping (String) -> AnyView,
                   sharing: AnyView, done: @escaping () -> Void) -> MenuModel {
    var sections: [MenuSection] = []
    let peerRows: [MenuItem] = peers.isEmpty
      ? [SettingsRow.caption("looking", L("Looking for other devices running iCube on this network…"))]
      : peers.map { p in
          var item = SettingsRow.destination("peer-\(p.id)", p.name, L("Continue this device's game here, or browse its games."), icon: p.glyph, view: peerDetail(p.id))
          item.subtitle = p.subtitle
          return item
        }
    sections.append(MenuSection(id: "peers", header: L("Nearby Devices"), footer: ContinuityManager.transportSecurityNotice, items: peerRows))
    sections.append(MenuSection(id: "this-device", header: L("This Device"), items: [
      {
        var item = SettingsRow.destination("share-library", L("Share My Library"), L("Let paired devices browse and copy this device's games."),
                                           icon: "square.stack.3d.up", view: sharing)
        item.badge = sharesLibrary ? L("On") : L("Off")
        return item
      }(),
    ]))
    if !trusted.isEmpty {
      sections.append(MenuSection(id: "paired", header: L("Paired Devices"), items: trusted.map {
        SettingsRow.destination("trusted-\($0.id)", $0.name, L("When this device was paired, and forget it."), icon: "checkmark.shield", view: trustedDetail($0.id))
      }))
    }
    if showsDone {
      sections.append(MenuSection(id: "done", items: [SettingsRow.action("done", L("Done"), L("Close this screen."), icon: "checkmark", run: done)]))
    }
    return MenuModel(sections: sections)
  }
}
```

```swift
// Common/Continuity/UI/ContinuitySharingModelBuilder.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct ContinuityGrantRowSummary: Equatable {
  let peerId: String
  let name: String
  let grantTitle: String
}

/// Pure: Share My Library and one device's grant, as rows.
enum ContinuitySharingModelBuilder {
  static func make(sharesLibrary: Bool, grants: [ContinuityGrantRowSummary], excluded: [(gameID: String, title: String)],
                   grantDetail: @escaping (String, String) -> AnyView,
                   setShares: @escaping (Bool) -> Void, shareAgain: @escaping (String) -> Void) -> MenuModel {
    let share = MenuSection(id: "share", header: L("Share This Library"),
      footer: L("When this is on, devices you've paired with can browse this device's games and copy them. Only the game is sent — never your saves, memory cards or Wii save data."),
      items: [SettingsRow.toggle("share", L("Share My Library"), sharesLibrary, L("Serve this device's game list to paired devices."), icon: "square.stack.3d.up", set: setShares)])
    let paired = MenuSection(id: "paired", header: L("Paired Devices"),
      footer: L("\"Ask Every Time\" prompts you when a device tries to copy a game — not when it merely looks at your list."),
      items: grants.isEmpty ? [SettingsRow.caption("no-paired", L("No paired devices yet."))]
        : grants.map { g in
            var item = SettingsRow.destination("grant-\(g.peerId)", g.name, L("What this device may do with your library."), icon: "ipad.and.iphone", view: grantDetail(g.peerId, g.name))
            item.subtitle = g.grantTitle
            return item
          })
    let notShared = MenuSection(id: "excluded", header: L("Games Not Shared"),
      footer: L("Excluded games never appear in what this device serves, even to a device that already knows about them."),
      items: excluded.isEmpty ? [SettingsRow.caption("all-shared", L("Every game in your library is shared."))]
        : excluded.map { e in SettingsRow.action("excluded-\(e.gameID)", e.title, L("Share this game again."), icon: "arrow.uturn.backward", badge: L("Share Again")) { shareAgain(e.gameID) } })
    return MenuModel(sections: [share, paired, notShared])
  }

  static func grant(peerName: String, current: ContinuityLibraryGrant, hasExplicitGrant: Bool,
                    choose: @escaping (ContinuityLibraryGrant) -> Void, clear: @escaping () -> Void) -> MenuModel {
    let options = ContinuityLibraryGrant.allCases.map { (ContinuityGrantDetailView.title(for: $0), $0) }
    var sections = [MenuSection(id: "grant", header: L("When This Device Asks"), footer: ContinuityManager.transportSecurityNotice, items: [
      SettingsRow.picker("grant", peerName, options, current,
                         L("Always Allow copies without asking. Ask Every Time asks per game. Don't Share hides your list."),
                         set: choose),
    ])]
    if hasExplicitGrant {
      sections.append(MenuSection(id: "clear", footer: L("Clearing the setting puts this device back to asking you every time."), items: [
        SettingsRow.action("clear", L("Clear This Setting"), L("Back to asking every time."), icon: "arrow.counterclockwise", run: clear),
      ]))
    }
    return MenuModel(sections: sections)
  }
}
```

`ContinuityGrantDetailView.title(for:)` is `static` already; make `ContinuityGrantDetailView` non-private if it is private (it is declared `struct ContinuityGrantDetailView` at file scope: fine).

- [ ] **Step 4: tvOS branches in the views**

`ContinuityBrowseView.body` under `#if os(tvOS)`: compute `peers` from `manager.discoveredPeers` (name `peer.serviceName`, subtitle via the same rules as `ContinuityPeerRow.subtitle`, glyph via `ContinuityPeerRow.glyph(for:)`; make those two helpers `static` and `fileprivate` so the view can call them), `trusted` from `manager.trustedPeers.map { ($0.id, $0.name) }`, and render `MenuScreen(model:…, onBack: SettingsLeafScreen.backAction(paneBack: paneBack, dismiss: { dismiss() }), tvHeader: SettingsLeafScreen.header(title: L("Nearby"), parentTitle: parentTitle), tvInset: .xxl)` with the same `.continuityPairingPrompt().continuityLibraryPullPrompt().task {…}.onDisappear {…}` modifiers as the List. `peerDetail: { id in AnyView(ContinuityPeerDetailView(peer: manager.discoveredPeers.first { $0.id == id }!)) }` (guard with `first(where:)` and an `EmptyView` fallback instead of `!`), `trustedDetail` likewise with `ContinuityTrustedPeerDetailView`, `sharing: AnyView(ContinuityLibrarySharingView())`.

`ContinuityLibrarySharingView` tvOS branch: `grants: grantRows.map { .init(peerId: $0.peerId, name: $0.name, grantTitle: ContinuityGrantDetailView.describe($0.grant)) }`, `excluded: excludedGameIDs.map { ($0, Self.title(forGameID: $0)) }`, `grantDetail: { id, name in AnyView(ContinuityGrantDetailView(peerId: id, peerName: name)) }`, `setShares: { v in Task { await manager.setSharesLibrary(v) } }`, `shareAgain: { id in GameProfiles.shared.setExcludedFromNearbySharing(false, forGameID: id); reloadExclusions() }`; header title `L("Share My Library")`.

`ContinuityGrantDetailView` tvOS branch: `ContinuitySharingModelBuilder.grant(peerName: peerName, current: current, hasExplicitGrant: manager.libraryGrants[peerId] != nil, choose: { g in Task { await manager.setLibraryGrant(g, forPeerId: peerId) } }, clear: { Task { await manager.clearLibraryGrant(forPeerId: peerId); dismiss() } })`; header title `peerName`.

The peer detail (`ContinuityPeerDetailView`), trusted detail and `ContinuityPeerLibraryView` keep their `List` in this plan (see the header note).

- [ ] **Step 5: Strings, tests, gates, screenshot, commit** (`settings-nearby-dark.png`)

```sh
git commit -m "feat(tvos): Nearby and library sharing on the menu engine"
```

### Task 13: Shaders settings leaf on the engine (tvOS)

**Files:**
- Create: `Common/Swift/Shaders/ShaderSettingsModelBuilder.swift`
- Modify: `Common/Swift/Shaders/ShaderSettingsView.swift:222-270`
- Test: `DolphiniOSTests/ShaderSettingsModelBuilderTests.swift` (new)

**Interfaces:**
- Produces:
  ```swift
  struct ShaderSettingsSnapshot { var enabled: Bool; var presetLabel: String; var flipVertically: Bool; var preCopy: Bool; var lastError: String?; var isDebug: Bool }
  enum ShaderSettingsChange: Equatable { case enabled(Bool), flipVertically(Bool), preCopy(Bool) }
  enum ShaderSettingsModelBuilder { static func make(_ s: ShaderSettingsSnapshot, picker: AnyView, debugTools: AnyView, apply: @escaping (ShaderSettingsChange) -> Void) -> MenuModel }
  ```

- [ ] **Step 1: Failing test**

```swift
// DolphiniOSTests/ShaderSettingsModelBuilderTests.swift
import SwiftUI
import XCTest
@testable import iCube

final class ShaderSettingsModelBuilderTests: XCTestCase {
  private var changes: [ShaderSettingsChange] = []
  private func model(enabled: Bool = true, error: String? = nil, debug: Bool = false) -> MenuModel {
    ShaderSettingsModelBuilder.make(.init(enabled: enabled, presetLabel: "crt-royale", flipVertically: false, preCopy: false, lastError: error, isDebug: debug),
                                    picker: AnyView(EmptyView()), debugTools: AnyView(EmptyView())) { self.changes.append($0) }
  }
  func test_rows_andPresetDisabledWhenOff() {
    XCTAssertEqual(model().allItems.map(\.id), ["enabled", "preset", "flip", "precopy"])
    XCTAssertEqual(model().item(id: "preset")?.badge, "crt-royale")
    XCTAssertEqual(model(enabled: false).item(id: "preset")?.isEnabled, false)
  }
  func test_error_isACaption_andDebugAddsASection() {
    XCTAssertEqual(model(error: "compile failed").item(id: "error")?.isEnabled, false)
    XCTAssertEqual(model(debug: true).sections.last?.id, "developer")
  }
  func test_toggles_emitChanges() {
    let m = model()
    for (id, change) in [("enabled", ShaderSettingsChange.enabled(false)), ("flip", .flipVertically(false)), ("precopy", .preCopy(false))] {
      guard case .toggle(let b) = m.item(id: id)?.role else { return XCTFail(id) }
      changes = []; b.wrappedValue = false; XCTAssertEqual(changes, [change], id)
    }
  }
}
```

- [ ] **Step 2: Run, expect compile failure.**

- [ ] **Step 3: Implement**

```swift
// Common/Swift/Shaders/ShaderSettingsModelBuilder.swift
// Copyright 2026 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

struct ShaderSettingsSnapshot {
  var enabled: Bool
  var presetLabel: String
  var flipVertically: Bool
  var preCopy: Bool
  var lastError: String?
  var isDebug: Bool
}

enum ShaderSettingsChange: Equatable { case enabled(Bool), flipVertically(Bool), preCopy(Bool) }

/// Pure: the Shaders leaf as rows. The preset picker and the debug tools are pushed views.
enum ShaderSettingsModelBuilder {
  static func make(_ s: ShaderSettingsSnapshot, picker: AnyView, debugTools: AnyView, apply: @escaping (ShaderSettingsChange) -> Void) -> MenuModel {
    var main: [MenuItem] = [
      SettingsRow.toggle("enabled", L("Enable Shader"), s.enabled, L("Runs the chosen post-processing preset over the game."), icon: "wand.and.stars", set: { apply(.enabled($0)) }),
      {
        var item = SettingsRow.destination("preset", L("Preset"), L("Choose a shader preset."), icon: "paintbrush", view: picker)
        item.badge = s.presetLabel
        item.isEnabled = s.enabled
        return item
      }(),
    ]
    if let error = s.lastError { main.append(SettingsRow.caption("error", error)) }
    var sections = [
      MenuSection(id: "shader", header: L("Post-Processing Shader"),
                  footer: L("Note: Some shaders can reduce performance. Heavier effects may cause slowdowns depending on your device."), items: main),
      MenuSection(id: "advanced", header: L("Advanced"),
                  footer: L("Compatibility options for specific devices or shaders. Most people never need these."), items: [
        SettingsRow.toggle("flip", L("Flip vertically"), s.flipVertically, L("Flips the shader output for presets that render upside down."), icon: "arrow.up.and.down", set: { apply(.flipVertically($0)) }),
        SettingsRow.toggle("precopy", L("Enable pre-copy (compat)"), s.preCopy, L("Copies the frame before the shader runs. Fixes a few presets on some devices."), icon: "doc.on.doc", set: { apply(.preCopy($0)) }),
      ]),
    ]
    if s.isDebug {
      sections.append(MenuSection(id: "developer", header: L("Developer"), items: [
        SettingsRow.destination("debug-tools", L("Shader Debug Tools"), L("Compile log and pipeline inspection."), icon: "ladybug", view: debugTools),
      ]))
    }
    return MenuModel(sections: sections)
  }
}
```

`ShaderSettingsView` tvOS branch: snapshot from its `@State`s (`presetLabel` as computed today, `lastError: DOLShaderPostProcessor.shared.lastError`, `isDebug` from `#if DEBUG`), `picker: AnyView(ShaderPickerView(selectedPresetPath: $presetPath))`, `debugTools: AnyView(ShaderDeveloperDebugView())` (under `#if DEBUG`, else `AnyView(EmptyView())`), apply writes the same defaults keys and posts `DOLShaderSettingsDidChange` exactly as the `onChange` handlers do today; header `SettingsLeafScreen.header(title: L("Shaders"), parentTitle: parentTitle)`. Keep `.onAppear { sync() }` and `.onChange(of: presetPath)`. `ShaderPickerView` itself is restyled in the pause-completion plan.

- [ ] **Step 4: Strings, tests, gates, screenshot, commit** (`settings-shaders-dark.png`)

```sh
git commit -m "feat(tvos): Shaders leaf on the menu engine"
```

### Task 14: Achievements leaf, only if it ships on tvOS

**Files:** `Common/UI/Settings/SwiftUI/ConfigAchievementsView.swift`

- [ ] **Step 1:** `grep -rn "USE_RETRO_ACHIEVEMENTS" Project.swift Project/ Tuist/ 2>/dev/null`. If the flag is not set for the tvOS target, write "Achievements: not built for tvOS, no change" in the HANDOFF update (Task 15) and skip this task.
- [ ] **Step 2:** If it is set: the leaf has text fields (username, password, host). Keep the `List` for the credential rows and move the toggles into a `MenuScreen` above it under `#if os(tvOS)`, using an `AchievementsModelBuilder` shaped like Task 13's (toggles `enabled`, `hardcore`, `spectator`, `discord`, `progress` with `apply(.change(Bool))`), tested the same way. The text fields stay stock on tvOS for this plan and are listed in the HANDOFF as remaining.

### Task 15: Full gate, screenshots, HANDOFF, land

**Files:**
- Modify: `docs/HANDOFF.md` (repo root)
- Create: `docs/superpowers/baselines/2026-10-11-tvos-after-plan-a/*.png`

- [ ] **Step 1: Everything green**

```sh
python3 Project/Scripts/check_design_tokens.py --check
python3 Project/Scripts/check_localized_keys.py --check
python3 Project/Scripts/check_button_types.py
make test
```
then the tvOS compile gate and `make gate-release`.

- [ ] **Step 2: After screenshots**

`Scripts/tvos_screens.sh ../../../docs/superpowers/baselines/2026-10-11-tvos-after-plan-a --dark` and `--no-build --light`. Read every `settings-*-dark.png`: no stock list, no capsule, title present. Read `pause-grid-dark.png`: no floating button. Write the same README as Task 2 with the after state.

- [ ] **Step 3: HANDOFF**

Append to `docs/HANDOFF.md` a section "Plan A landed (date)": what changed per package, the preview launch arguments and the script, the leaves still on stock `List` (peer detail, trusted peer detail, peer library, sync conflicts, achievements text fields, Shader picker and parameters), and the owner's device checks: fast-forward feel at 8x and Unlimited, Performance HUD tile opens the overlay, every leaf's focus walk with the Siri Remote.

- [ ] **Step 4: Commit and land**

```sh
git -C ../../.. add docs/superpowers/baselines/2026-10-11-tvos-after-plan-a docs/HANDOFF.md
git -C ../../.. commit -m "docs(tvos): plan A after-screenshots and handoff"
```

Review (Sonnet per task was done at each task's gate; Opus on the whole branch now), then from the worktree: `git fetch origin && git rebase --autostash origin/develop && git push origin HEAD:develop`. Then in the Provenance superproject, bump the `Cores/Dolphin/dolphin-ios` gitlink to the new develop head and commit `chore(dolphin): bump iCube to <sha>`.
