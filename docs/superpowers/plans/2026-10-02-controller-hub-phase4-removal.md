# Controller Hub Phase 4 (Removal) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the controller screens the hub replaced. Leave exactly one place to set the pointer mode. Fold the two "style" rows into one "Overlay Style" row.

**Architecture:** This is a deletion phase with three small behaviour changes:
- The overlay's button art always follows the pad kind.
- The hub names a DSU-bound port the way the player screen does.
- Motion Debug becomes DEBUG-only.

Everything else is removing dead views, dead model members and dead strings, and rewording comments that name deleted types. No core (Dolphin C++) changes.

**Tech Stack:** Swift 5 / SwiftUI (iOS 17, tvOS 17), XCTest, Tuist-generated `iCube.xcworkspace`.

**Spec:** `docs/superpowers/specs/2026-09-28-controller-hub-design.md`, "Delivery phases" item 4 and "Removed or moved". Read it with the Phase 3 handoff, `docs/handoff-2026-09-30-controller-hub-phase3.md`, "Next (Phase 4)". The dead-code survey this plan is built from is in `~/.icube-debug/phase4-deadcode-map.md`.

## Global Constraints

- Ships for iOS 17+ and tvOS 17+. Every changed file must compile for both. Use `#if os(iOS)`/`#if os(tvOS)` guards as the surrounding code does.
- User-facing text goes through `L("…")`. CI runs `Source/iOS/App/Project/Scripts/check_localized_keys.py --check`, which fails when an `L` key is missing from `en.lproj/Core.strings`. Every new key needs en and ja entries. A removed key can be deleted from both.
- SwiftLint line length is 200.
- Commits use conventional prefixes (`fix:`, `refactor:`, `test:`, `docs:`). **No `Co-Authored-By` or other LLM attribution trailers.**
- Work in a git worktree of the iCube submodule. After `git worktree add`, set the per-worktree override:
  `git config --file "$(git rev-parse --git-common-dir)/worktrees/<name>/config.worktree" core.worktree "<abs worktree path>"`.
  Then check that `git -C <wt> rev-parse --show-toplevel` prints the worktree path and `git status --short` is empty.
- In a fresh worktree, copy the empty `Externals/*` submodule folders from the main checkout. Then run `cd Source/iOS/App && tuist generate --no-open`. Rerun `tuist generate` after deleting or adding a Swift file.
- A local build rewrites the TRACKED `build/xcframework` slices. Run `git checkout -- build/xcframework` before every commit.
- Test command (use a simulator no other session is using):
  `cd Source/iOS/App && make test DEST="platform=iOS Simulator,id=<udid>" TEST_ARGS="-skipPackagePluginValidation -skipMacroValidation"`.
  To run one class, add `-only-testing:iCubeTests/<Class>` to `TEST_ARGS`. The console interleaves test lines; read the counts with:
  `xcrun xcresulttool get test-results summary --path "$(ls -td build-Xcode-ios/Logs/Test/*.xcresult | head -1)"`.
- Before merging: `cd Source/iOS/App && make gate-release` (Release, iOS and tvOS).
- The decisions this phase implements, made by the user on 2026-10-02:
  - **One "Overlay Style" row.** The hub's "On-Screen Style" (`ControllerManager.overlayMode`, which pad shows) is renamed "Overlay Style".
  - More Controller Settings' colour override ("Overlay Style", `touch_overlay_style`) is removed. The button art always follows the pad kind (today's Auto).
  - `EnhancedMotionControlsView` (Advanced Motion Settings) stays, for the options with no other home: Horizontal Movement, 6DOF with Wiimote/Nunchuk motion, and Apply Recommended Settings (decision 6).

## File Map

| File | Change |
|---|---|
| `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubModelBuilder.swift` | Rename the `osc-style` row; DSU-bound ports are never "(Disconnected)" |
| `Source/iOS/App/DolphiniOS/UI/Emulation/TouchOverlay/TouchOverlayArt.swift` | `Style` enum → `variant(for:)` |
| `Source/iOS/App/DolphiniOS/UI/Emulation/TouchOverlay/TouchOverlayView.swift` | Call `variant(for:)` |
| `Source/iOS/App/Project/Assets/DefaultPreferences.plist` | Drop `touch_overlay_style` |
| `Source/iOS/App/Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift` | Drop the colour picker, the Touch IR Pointer row and Pointer Sensitivity |
| `Source/iOS/App/Common/UI/Settings/SwiftUI/ControllersRootView.swift` | Delete `TouchIRMode`, `TouchIRModePicker` |
| `Source/iOS/App/Common/UI/Settings/SwiftUI/EnhancedMotionControlsView.swift` | Keep only the decision-6 options |
| `Source/iOS/App/Common/Swift/Controllers/ControllerSetupView.swift` | Delete |
| `Source/iOS/App/Common/Swift/Controllers/Remap/RemapPlayerView.swift` | Delete |
| `Source/iOS/App/Common/Swift/Controllers/Remap/RemapModel.swift` | Drop `RemapGroup.key`, `key(owner:id:)`, `RemapControllerNav` |
| `Source/iOS/App/DolphiniOSTests/RemapModelTests.swift` | `RemapControllerNav` → `MenuControllerNav`; drop the `key` test |
| `Source/iOS/App/Common/Swift/MotionDebugView.swift` | `#if DEBUG` |
| `Source/iOS/App/Common/UI/Settings/SwiftUI/DebugRootView.swift` | Motion Debug link DEBUG-only |
| `Source/iOS/App/Common/Swift/EmulationScreen.swift` | Delete the unreachable motion-debug state, sheets and tvOS button |
| `Source/iOS/App/DolphiniOSTests/ControllerHubModelBuilderTests.swift` | Title and DSU tests |
| `Source/iOS/App/DolphiniOSTests/TouchOverlayArtTests.swift` | Create |
| `Source/iOS/App/Common/UI/Localization/{en,ja}.lproj/Core.strings` | Remove dead keys |
| 12 files with stale comments (Task 5) | Reword |
| `docs/handoff-2026-10-02-controller-hub-phase4.md` | Create (device checklist) |

---

### Task 1: One "Overlay Style" row

**Files:**
- Modify: `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubModelBuilder.swift:101`
- Modify: `Source/iOS/App/DolphiniOS/UI/Emulation/TouchOverlay/TouchOverlayArt.swift:20-39`
- Modify: `Source/iOS/App/DolphiniOS/UI/Emulation/TouchOverlay/TouchOverlayView.swift:59`
- Modify: `Source/iOS/App/Project/Assets/DefaultPreferences.plist:13-14`
- Modify: `Source/iOS/App/Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift:24-25,87-97,166`
- Test: `Source/iOS/App/DolphiniOSTests/ControllerHubModelBuilderTests.swift`
- Test: `Source/iOS/App/DolphiniOSTests/TouchOverlayArtTests.swift` (create)

**Interfaces:**
- Produces: `TouchOverlayArt.variant(for padKind: TouchOverlayPadKind) -> TouchOverlayArt.Variant`, iOS only.
- Removes: `TouchOverlayArt.Style`, including `current()` and `resolvedVariant(padKind:)`, and the `touch_overlay_style` default.

- [ ] **Step 1: Write the failing tests**

In `ControllerHubModelBuilderTests.swift`, add this assertion to `test_stylePicker_offersAutoGameCubeWii_andWritesThroughTheAction`, right after its `guard case .picker…` line:

```swift
    XCTAssertEqual(model.item(id: "osc-style")?.title, "Overlay Style")
```

Create `Source/iOS/App/DolphiniOSTests/TouchOverlayArtTests.swift`:

```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

#if os(iOS)
import XCTest

@testable import iCube

/// The overlay's button art follows the pad shown (controller hub Phase 4: the separate colour
/// override is gone; the hub's "Overlay Style" picks the pad).
final class TouchOverlayArtTests: XCTestCase {
  func testGameCubePadUsesTheGameCubePalette() {
    XCTAssertEqual(TouchOverlayArt.variant(for: .gameCube), .gameCube)
  }

  func testEveryWiiPadUsesTheWiiPalette() {
    for kind in [TouchOverlayPadKind.wiiRemote, .wiiRemoteSideways, .wiiClassic] {
      XCTAssertEqual(TouchOverlayArt.variant(for: kind), .wii, kind.rawValue)
    }
  }

  /// A player who once picked a colour override keeps the stored integer; it must no longer apply.
  func testAStaleColourOverrideIsIgnored() {
    let key = "touch_overlay_style"
    let saved = UserDefaults.standard.object(forKey: key)
    defer { UserDefaults.standard.set(saved, forKey: key) }
    UserDefaults.standard.set(2, forKey: key)  // the old "Wii" override
    XCTAssertEqual(TouchOverlayArt.variant(for: .gameCube), .gameCube)
  }
}
#endif
```

- [ ] **Step 2: Run the tests to verify they fail**

Run `tuist generate --no-open` (new test file), then `make test` with `-only-testing:iCubeTests/TouchOverlayArtTests -only-testing:iCubeTests/ControllerHubModelBuilderTests`.
Expected: the build fails, because `TouchOverlayArt.variant(for:)` does not exist.

- [ ] **Step 3: Implement**

In `TouchOverlayArt.swift`, replace the whole `enum Style: Int, CaseIterable, Sendable { … }` block, together with its doc comment ("The Settings "Style" override…"), with:

```swift
  /// The palette for a pad kind: GameCube art for the GameCube pad, Wii art for every Wii pad.
  /// The Settings colour override that could force one palette everywhere was removed in
  /// controller hub Phase 4; the hub's "Overlay Style" picks the pad instead.
  static func variant(for padKind: TouchOverlayPadKind) -> Variant {
    padKind == .gameCube ? .gameCube : .wii
  }
```

In `TouchOverlayView.swift:59`, replace

```swift
      let variant = TouchOverlayArt.Style.current().resolvedVariant(padKind: padKind)
```

with

```swift
      let variant = TouchOverlayArt.variant(for: padKind)
```

In `ControllerHubModelBuilder.swift:101`, change `title: L("On-Screen Style")` to `title: L("Overlay Style")`.

In `DefaultPreferences.plist`, delete the two lines:

```xml
	<key>touch_overlay_style</key>
	<integer>0</integer>
```

In `ControllerMoreSettingsView.swift`:
- Delete the `/// Raw `TouchOverlayArt.Style` integer…` comment and the `@State private var touchOverlayStyle = 0` line under it.
- Delete the whole `settingsCaption( Picker(L("Overlay Style"), …) … L("Overrides whether the programmatic overlay's button art uses GameCube or Wii coloring, or matches the pad kind automatically."))` expression (lines 87-97).
- In `syncFromConfig()`, delete `touchOverlayStyle = UserDefaults.standard.integer(forKey: "touch_overlay_style")`.

- [ ] **Step 4: Run the tests to verify they pass**

Same command as Step 2. Expected: PASS for `TouchOverlayArtTests` (3 tests) and `ControllerHubModelBuilderTests`.
Then check that nothing still reads the key or the old type:
`git grep -n "touch_overlay_style\|TouchOverlayArt.Style\|resolvedVariant" -- Source/iOS`
It should print only the `TouchOverlayArtTests.swift` lines.

- [ ] **Step 5: Commit**

```bash
git checkout -- build/xcframework
git add -A Source/iOS/App
git commit -m "refactor(controllers): one Overlay Style row; art follows the pad"
```

---

### Task 2: One place sets the pointer mode

The player screen's Pointer row and the top bar (both through `PointerModeController`) are the only pointer-mode pickers left. More Controller Settings and Advanced Motion Settings lose theirs, and More loses Pointer Sensitivity, which the player screen's Touch – Drag "Sensitivity" row replaces (same key, `touch_overlay_ir_pointer_gain`).

**Files:**
- Modify: `Source/iOS/App/Common/UI/Settings/SwiftUI/ControllersRootView.swift:115-131`
- Modify: `Source/iOS/App/Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift`
- Modify (rewrite): `Source/iOS/App/Common/UI/Settings/SwiftUI/EnhancedMotionControlsView.swift`

**Interfaces:**
- Consumes: `PointerModeController.shared.set(_ mode: PointerMode)` and `PointerMode.gyro`.
- Consumes the setters `MotionSettings.setEnhancedShakeDetection(_:)`, `setInvertRoll(_:)` and `setInvertPitch(_:)`, the notification `Notification.Name.DOLMotionSettingsChanged`, and the keys `MotionSettings.Key.useYawForHorizontal`, `.full6DOF`, `.wiimoteIMU` and `.nunchukIMU`.
- Removes: `TouchIRMode` and `TouchIRModePicker`.

These are SwiftUI view edits with no unit seam. The checks are the build, the grep in Step 4 and device checklist items 4-6.

- [ ] **Step 1: Delete the old picker types**

In `ControllersRootView.swift`, delete `enum TouchIRMode …` (3 lines) and the whole `struct TouchIRModePicker: View { … }`. That is everything from `enum TouchIRMode: Int, CaseIterable` through the closing brace of `TouchIRModePicker`, just before `#if os(iOS)`.

- [ ] **Step 2: Trim More Controller Settings**

In `ControllerMoreSettingsView.swift`:
- Replace the type's doc comment (lines 9-11) with:

```swift
/// Controller settings outside the hub's sections, pushed from its "More Controller Settings" row.
/// The pointer mode and its sensitivity live on the player screen (controller hub Phase 4).
```

- Delete `@State private var touchIRMode: TouchIRMode = .drag`.
- Delete `@State private var touchOverlayIRPointerGain = 1.0`.
- Delete, at the top of the "Alternate Input Sources" section, the comment `// TouchIRModePicker's rows set the mode…` and the whole `settingsNavCaption(destination: TouchIRModePicker(…), …) { Text("\(L("Touch IR Pointer")): \(touchIRMode.label)") }` expression.
- In `if touchOverlayProgrammatic { … }`, delete the whole `settingsCaption( HStack { Text(L("Pointer Sensitivity")) … }, L("Scales how far the Wii Remote pointer moves per drag in Drag mode. Doesn't affect Follow or Gyro mode."))` expression. Keep the Edit IR Area link.
- In `syncFromConfig()`, delete `touchIRMode = TouchIRMode.from(raw: DOLConfigBridge.mainTouchPadIRMode())` and `touchOverlayIRPointerGain = Double(TouchOverlayIRGeometry.clampDragGain(MotionSettings.irPointerGain()))`.

- [ ] **Step 3: Rewrite Advanced Motion Settings**

Replace everything in `EnhancedMotionControlsView.swift`, from `struct EnhancedMotionControlsView: View {` through the closing brace of that struct, which is the line before `private struct HorizontalMotionPicker`. Keep the file header, the imports and `HorizontalMotionPicker` as they are. The new struct:

```swift
/// Motion options with no home on the player screen (controller hub decision 6): which gesture
/// moves the gyro pointer sideways, and the full 6DOF motion mapping. The pointer mode, its
/// invert switches and Shake to Wiggle are on the player screen.
struct EnhancedMotionControlsView: View {
  @AppStorage(MotionSettings.Key.useYawForHorizontal) private var useYawForHorizontal: Bool = false
  @AppStorage(MotionSettings.Key.full6DOF) private var fullMotionEnabled: Bool = true
  @AppStorage(MotionSettings.Key.wiimoteIMU) private var wiimoteIMUEnabled: Bool = true
  @AppStorage(MotionSettings.Key.nunchukIMU) private var nunchuckIMUEnabled: Bool = false

  @State private var horizontalMotionMode: HorizontalMotionMode = .roll

  enum HorizontalMotionMode: Int, CaseIterable {
    case roll = 0, yaw = 1
    var label: String {
      switch self {
      case .roll: return L("Roll (Tilt Left/Right)")
      case .yaw: return L("Yaw (Turn Left/Right)")
      }
    }
    var description: String {
      switch self {
      case .roll: return L("Tilt device left/right to move cursor")
      case .yaw: return L("Rotate device left/right to move cursor")
      }
    }
  }

  var body: some View {
    List {
      Section(header: Text(L("Motion IR Cursor"))) {
        settingsNavCaption(
          destination: HorizontalMotionPicker(selected: $horizontalMotionMode),
          L("Whether tilting (roll) or turning (yaw) the device moves the pointer left/right.")
        ) {
          Text(L("Horizontal Movement"))
        }
        .onChange(of: horizontalMotionMode) { _, mode in
          useYawForHorizontal = (mode == .yaw)
        }
      }

      Section(header: Text(L("Full Motion Mapping"))) {
        settingsCaption(
          Toggle(L("Enable 6DOF Motion Controls"), isOn: $fullMotionEnabled),
          L("Maps device motion to all 6 axes (rotation + acceleration) for games like Wii Sports and Mario Kart. Active only when IR control isn't using gyro mode."))

        if fullMotionEnabled {
          VStack(alignment: .leading, spacing: 8) {
            Toggle(L("Wiimote Motion Controls"), isOn: $wiimoteIMUEnabled)
            Text(L("Maps device motion to Wiimote's built-in accelerometer and gyroscope. Required for most motion-controlled Wii games."))
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.leading)

          VStack(alignment: .leading, spacing: 8) {
            Toggle(L("Nunchuck Motion Controls"), isOn: $nunchuckIMUEnabled)
            Text(L("Maps device motion to Nunchuck's accelerometer. Used by fewer games, mainly for secondary motion controls when using Nunchuck + Wiimote."))
              .font(.caption)
              .foregroundColor(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.leading)
        }
      }

      Section(header: Text(L("Quick Setup"))) {
        Button(L("Apply Recommended Settings")) { applyRecommendedSettings() }
      }
    }
    .navigationTitle(L("Advanced Motion Settings"))
    .onAppear { horizontalMotionMode = useYawForHorizontal ? .yaw : .roll }
    // A running game re-reads motion settings on this notification.
    .onChange(of: useYawForHorizontal) { _, _ in notifyMotionSettingsChanged() }
    .onChange(of: fullMotionEnabled) { _, _ in notifyMotionSettingsChanged() }
    .onChange(of: wiimoteIMUEnabled) { _, _ in notifyMotionSettingsChanged() }
    .onChange(of: nunchuckIMUEnabled) { _, _ in notifyMotionSettingsChanged() }
  }

  /// The same values the old button set. The pointer mode goes through `PointerModeController`,
  /// the one writer; the shake and invert keys are written through `MotionSettings` because this
  /// screen no longer shows them.
  private func applyRecommendedSettings() {
    MotionSettings.setEnhancedShakeDetection(true)
    MotionSettings.setInvertRoll(false)
    MotionSettings.setInvertPitch(false)
    PointerModeController.shared.set(.gyro)
    fullMotionEnabled = true
    useYawForHorizontal = false
    wiimoteIMUEnabled = true
    nunchuckIMUEnabled = false
    horizontalMotionMode = .roll
    notifyMotionSettingsChanged()
    #if os(iOS)
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    #endif
  }

  private func notifyMotionSettingsChanged() {
    NotificationCenter.default.post(name: .DOLMotionSettingsChanged, object: nil)
  }
}
```

- [ ] **Step 4: Build and check that only one picker is left**

Run `make test` (full suite). Expected: build succeeds and all tests pass, with the same counts as before this task.
Then run `git grep -n -w "TouchIRMode\|TouchIRModePicker" -- Source/iOS`. It should print nothing. `-w` keeps the surviving `TCWiiTouchIRMode` from matching.
Then run `git grep -n "PointerModeController.shared.set\|setMainTouchPadIRMode" -- Source/iOS`. It should print only the player screen's `PlayerScreenIO.swift`, the top bar's pointer menu in `EmulationScreen.swift` or `TopBar/`, `GameProfiles.swift`, `PointerModeController.swift` itself, `EnhancedMotionControlsView.swift` (Apply Recommended Settings) and tests. Any other hit is a picker this task missed; remove it the same way.

- [ ] **Step 5: Commit**

```bash
git checkout -- build/xcframework
git add -A Source/iOS/App
git commit -m "refactor(controllers): set the pointer mode in one place"
```

---

### Task 3: Delete the old controller setup and remap screens

**Files:**
- Delete: `Source/iOS/App/Common/Swift/Controllers/ControllerSetupView.swift`
- Delete: `Source/iOS/App/Common/Swift/Controllers/Remap/RemapPlayerView.swift`
- Modify: `Source/iOS/App/Common/Swift/Controllers/Remap/RemapModel.swift:44-51,~258-262`
- Modify: `Source/iOS/App/DolphiniOSTests/RemapModelTests.swift:95-104,220-266`

**Interfaces:**
- Removes: `ControllerSetupView`, `ControllerSetupSections`, `RemapPlayerView`, `RemapGroup.key`, `RemapGroup.key(owner:id:)` and `typealias RemapControllerNav`.
- `ControllerSetupSystem` stays. It lives in `Hub/ControllerHubState.swift`.

- [ ] **Step 1: Point the tests at the surviving names**

In `RemapModelTests.swift`, replace every `RemapControllerNav` with `MenuControllerNav` (lines ~220-266: `sed -i '' 's/RemapControllerNav/MenuControllerNav/g' Source/iOS/App/DolphiniOSTests/RemapModelTests.swift`). Delete the test `test_groupKeys_areUniqueWhenExtensionGroupsAreShown` and its 3-line doc comment above it (lines ~95-104). It covers `RemapGroup.key`, which only `RemapPlayerView` used.

- [ ] **Step 2: Delete the files and the dead members**

```bash
git rm Source/iOS/App/Common/Swift/Controllers/ControllerSetupView.swift \
       Source/iOS/App/Common/Swift/Controllers/Remap/RemapPlayerView.swift
```

In `RemapModel.swift`:
- Delete `var key: String { Self.key(owner: owner, id: id) }` and its doc comment, which starts "Unique across every group shown together".
- Delete `static func key(owner: RemapGroupOwner, id: Int) -> String { "\(owner)-\(id)" }` and its doc comment, which starts "Same value as `key`".
- Delete `typealias RemapControllerNav = MenuControllerNav` and its doc comment, which starts "D18 moved this engine".
- Replace the file comment at line 6, `// Pure model for the button-remap screen (`RemapPlayerView`). Nothing in this`, with `// Pure model behind the player screen's capture rows. Nothing in this`.

- [ ] **Step 3: Regenerate and run the tests**

Run `tuist generate --no-open`, then `make test`.
Expected:
- The build succeeds.
- `RemapModelTests` passes with one test fewer than before.
- Every other class passes unchanged.

Then run `git grep -n "ControllerSetupView\|ControllerSetupSections\|RemapPlayerView\|RemapControllerNav" -- Source/iOS`. It should print only the comment lines Task 5 rewrites.

- [ ] **Step 4: Commit**

```bash
git checkout -- build/xcframework
git add -A Source/iOS/App
git commit -m "refactor(controllers): delete ControllerSetupView and RemapPlayerView"
```

---

### Task 4: Motion Debug is DEBUG-only; drop its unreachable entry points

Motion Debug currently opens from three places:
- Settings → Debug → Motion Debug (`DebugRootView.swift:124`). DebugRootView ships in Release.
- A gyroscope button in the tvOS pause screen (`EmulationScreen.swift:~568`). It sets `showMotionDebug`, but the tvOS sheet is commented out (~548-553), so the button does nothing in any build.
- An iOS `#if DEBUG` sheet (`EmulationScreen.swift:~1406`). Nothing on iOS ever sets its flag.

**Files:**
- Modify: `Source/iOS/App/Common/Swift/MotionDebugView.swift:4` and its final `#endif`
- Modify: `Source/iOS/App/Common/UI/Settings/SwiftUI/DebugRootView.swift:123-127`
- Modify: `Source/iOS/App/Common/Swift/EmulationScreen.swift`

- [ ] **Step 1: Gate the view and its link**

In `MotionDebugView.swift`, change line 4 `#if canImport(CoreMotion)` to `#if DEBUG && canImport(CoreMotion)`, and change the last line `#endif // canImport(CoreMotion)` to `#endif // DEBUG && canImport(CoreMotion)`. Then delete the now-redundant inner `#if DEBUG` / `#endif` pair around `MotionDebugView_Previews`, keeping the preview struct itself.

In `DebugRootView.swift`, change the `#if canImport(CoreMotion)` that opens the Motion Debug `NavigationLink` to `#if DEBUG && canImport(CoreMotion)`, and its `#endif // canImport(CoreMotion)` to `#endif // DEBUG && canImport(CoreMotion)`.

- [ ] **Step 2: Delete the dead entry points in EmulationScreen**

- In the tvOS block (~line 244), delete `@State private var showMotionDebug = false`.
- In the iOS block (~lines 293-295), delete the three lines `#if DEBUG` / `@State private var showMotionDebug = false` / `#endif`.
- Delete the commented-out tvOS sheet, the six `//` lines starting `//    .sheet(isPresented: $showMotionDebug) {` (~548-553).
- In the tvOS pause-menu overlay's `HStack`, delete the whole `Button { showMotionDebug = true } label: { Image(systemName: "gyroscope") … }` with its modifiers, through `.padding([.top, .trailing], 8)`. The speedometer button after it stays.
- Delete the iOS `#if DEBUG` / `.sheet(isPresented: $showMotionDebug) { NavigationStack { MotionDebugView() } }` / `#endif` block (~1405-1411).

- [ ] **Step 3: Check both platforms build**

Run `git grep -n "showMotionDebug" -- Source/iOS`. It should print nothing.
Run `make test`. Expected: the build succeeds and all tests pass.
Run `cd Source/iOS/App && make gate-release`. Expected: both `** BUILD SUCCEEDED **` lines. This is the Release iOS and tvOS build, where `MotionDebugView` no longer exists. Afterwards run `git checkout -- build/xcframework`.

- [ ] **Step 4: Commit**

```bash
git add -A Source/iOS/App
git commit -m "refactor(motion): Motion Debug only in DEBUG builds"
```

---

### Task 5: The hub names a DSU-bound port; stale comments

**Files:**
- Modify: `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubModelBuilder.swift:61-69`
- Test: `Source/iOS/App/DolphiniOSTests/ControllerHubModelBuilderTests.swift`
- Modify (comments only): the twelve files listed in Step 4.

**Interfaces:**
- Consumes: `PlayerScreenState.isMissing(_ qualifier: String, pads: [ConnectedPadState]) -> Bool`. It is true only for an `MFi/` qualifier whose pad isn't connected.

- [ ] **Step 1: Write the failing test**

Add to `ControllerHubModelBuilderTests.swift`, after `test_playerRow_boundToAPadThatIsGone_saysDisconnected`:

```swift
  /// A DSU device is never a GCController, so it is never in the pad list; the hub must name it,
  /// not call it disconnected (the player screen's rule, decision 11).
  func test_playerRow_boundToADSUDevice_namesIt() {
    let model = make(state(system: .gamecube, bound: ["gc-2": "DSUClient/0/Pad C"]))
    XCTAssertEqual(model.item(id: "gc-2")?.subtitle, "Pad C · GameCube Controller")
  }
```

- [ ] **Step 2: Run it to verify it fails**

Run `make test` with `-only-testing:iCubeTests/ControllerHubModelBuilderTests`.
Expected: FAIL. The subtitle is `"Pad C (Disconnected) · GameCube Controller"`.

- [ ] **Step 3: Implement**

In `ControllerHubModelBuilder.deviceName(for:pads:)`, replace the last three lines:

```swift
    // Bound, but the pad is not connected: the binding is kept and returns with the pad.
    let name = qualifier.split(separator: "/", maxSplits: 2).last.map(String.init) ?? qualifier
    return String(format: L("%@ (Disconnected)"), name)
```

with

```swift
    let name = qualifier.split(separator: "/", maxSplits: 2).last.map(String.init) ?? qualifier
    // Only a missing MFi pad is "Disconnected" (its binding returns with the pad); a DSU device is
    // never in the pad list. The player screen uses the same rule.
    return PlayerScreenState.isMissing(qualifier, pads: pads) ? String(format: L("%@ (Disconnected)"), name) : name
```

- [ ] **Step 4: Reword the comments that name deleted code**

Apply each replacement exactly. Paths are relative to `Source/iOS/App/Common/`.

- `Swift/Controllers/WiimoteSlotOptions.swift:6-7`: replace "shared by `ControllerSetupSections` and `RemapPlayerView`, so a change made on either screen goes through exactly the same path" with "shared by the hub and the player screen, so a change made on either goes through exactly the same path". Keep the rest of the sentence.
- `Swift/Controllers/Hub/ControllerHubState.swift:7-8`: replace "Moved here from `ControllerSetupView.swift`, which Phase 4 deletes." with "Moved here from the old controller setup screen (deleted in Phase 4)."
- `Swift/Controllers/Hub/ControllerHubViewModel.swift:38`: replace "(the rule `ControllerSetupSections.reloadQualifiers` used)" with "(the rule the old controller setup screen used)".
- `UI/Settings/SwiftUI/GraphicsAdvancedView.swift:241-243`: delete the three-line `// NOTE: The per-port Type→Configure flow …` comment. Everything it describes is gone.
- `UI/Settings/SwiftUI/DebugRootView.swift:54-55`: replace the comment with `// The master "Connect MFi Controllers" toggle is in More Controller Settings.`
- `Swift/Menu/MenuScreen.swift:51`: replace "— like `RemapPlayerView`, not a `valueChangedHandler`" with "— not a `valueChangedHandler`".
- `Swift/Menu/MenuScreen.swift:56-57`: replace "which is the same reasoning `RemapPlayerView`'s doc comment gives for why IT polls." with "which is why it polls."
- `Swift/Menu/MenuScreen.swift:446`: replace "(the same reasoning `ControllerSetupView.wiiOptionRows`/`tvOptionRow` already documents)" with "(see the tvOS focus notes in docs/superpowers/specs/2026-09-28-controller-hub-design.md)".
- `Swift/Menu/MenuFocusRouter.swift:118`: replace "(unlike `RemapPlayerView`, which starts with no highlight)" with "(unlike a screen that starts with no highlight)".
- `Swift/Menu/MenuModel.swift:132-133`: replace "— disabled items are skipped, matching `RemapPlayerView`'s `.disabled` sections never appearing in `focusOrder`." with "— disabled items are skipped."
- `Swift/Controllers/Player/PlayerScreenView.swift:7`: replace "player rows in place of `RemapPlayerView`." with "player rows."
- `Swift/Controllers/Player/PlayerScreenViewModel.swift:88`: replace "as `RemapPlayerView` polled" with "as the old remap screen polled".
- `Swift/Controllers/Player/PlayerScreenViewModel.swift:395`: replace "(RemapPlayerView.swift:617-624)" with "(seen in the old remap screen)".
- `Swift/Controllers/Player/PlayerScreenViewModel.swift:529`: replace "(RemapPlayerView.swift:430-434)" with "(seen in the old remap screen)".
- `Swift/Controllers/Player/PlayerScreenIO.swift:174`: replace "(the "profiles loading weird" bug, RemapPlayerView.swift:586-591)" with "(the "profiles loading weird" bug)".
- `Swift/Controllers/Player/PlayerScreenState.swift:131`: replace "(MFi or DSU, as `RemapPlayerView.deviceIsPhysical`)" with "(MFi or DSU)".
- `Swift/Controllers/Remap/RemapModel.swift`: Task 3 fixed line 6. Rerun the grep below for any other mention.

- [ ] **Step 5: Run the tests and the grep**

Run `make test`. Expected: all pass, including `test_playerRow_boundToADSUDevice_namesIt` and the unchanged `test_playerRow_boundToAPadThatIsGone_saysDisconnected`.
Run `git grep -n "ControllerSetupView\|ControllerSetupSections\|RemapPlayerView\|RemapControllerNav\|TouchIRModePicker" -- Source/iOS`. It should print nothing.

- [ ] **Step 6: Commit**

```bash
git checkout -- build/xcframework
git add -A Source/iOS/App
git commit -m "fix(controllers): the hub names a DSU-bound port; drop stale references"
```

---

### Task 6: Dead strings, final gates, handoff

**Files:**
- Modify: `Source/iOS/App/Common/UI/Localization/en.lproj/Core.strings`, `ja.lproj/Core.strings`
- Create: `docs/handoff-2026-10-02-controller-hub-phase4.md`

- [ ] **Step 1: Remove the keys no code uses any more**

For each key below, first confirm that `git grep -n -F 'L("<key>")' -- Source/iOS` prints nothing. Then delete its line from both `en.lproj/Core.strings` and `ja.lproj/Core.strings`. Each key is one `"<key>" = "<value>";` line in each file. Delete it with an exact-line match, for example: `python3 - <<'EOF'` that drops lines starting with `"<key>" =`. Skip any key the grep still finds.

- `Bind a game controller to this player to capture buttons. Touchscreen controls are laid out by the on-screen overlay.`
- `Connected Controllers`
- `GC Profiles`
- `Identify`
- `LED Color`
- `Profiles…`
- `Tap a control, then press the button or move the stick to bind it. Tap again to cancel; long-press to clear.`
- `Wii Remotes (Global)`
- `Wiimote Profiles`
- `Customize Buttons…`
- `Touch IR Pointer`
- `How the Wii Remote pointer is driven. Gyro uses device motion; Follow/Drag use touch gestures.`
- `IR Control Method`
- `How the Wii Remote IR pointer is controlled. Gyro uses device motion for added precision and unlocks the motion options below.`
- `On-Screen Style`
- `Overrides whether the programmatic overlay's button art uses GameCube or Wii coloring, or matches the pad kind automatically.`
- `Pointer Sensitivity`
- `Scales how far the Wii Remote pointer moves per drag in Drag mode. Doesn't affect Follow or Gyro mode.`
- `Invert Horizontal (Left/Right)`
- `Flips left/right pointer motion.`
- `Invert Vertical (Up/Down)`
- `Flips up/down pointer motion.`
- `Shake Detection`
- `Enable Advanced Shake Detection`
- `Uses a motion-pattern algorithm to detect shake gestures more reliably than Dolphin's basic detection.`

Leave `Continuous Scanning` and `GameCube Controllers`. They are in `Languages/po/dolphin-emu.pot`, and the build's pre-script would regenerate them.

- [ ] **Step 2: Check the localization**

Run from `Source/iOS/App`: `python3 Project/Scripts/check_localized_keys.py --check`. Expected: exit 0, no missing keys.

- [ ] **Step 3: Final gates**

- Run `make test`. Expected: every test passes. The total is the pre-phase count plus 4 (3 art tests, 1 DSU test) minus 1 (the `RemapGroup.key` test).
- Run `make gate-release`. Expected: iOS and tvOS Release both succeed. Then run `git checkout -- build/xcframework`.

- [ ] **Step 4: Write the handoff with the device checklist**

Create `docs/handoff-2026-10-02-controller-hub-phase4.md` with these sections:

```markdown
# Controller Hub Phase 4 (removal): handoff

## Landed
<one line per commit: sha, subject>

## Device checklist (iPhone, then Apple TV where noted)
1. Pause menu → Controllers, in a game: the On-Screen Controls section shows "Overlay Style" (Auto / GameCube / Wii). Picking GameCube in a Wii game shows the GameCube pad with GameCube art; Wii shows the Wii pad with Wii art.
2. Settings → Controllers → More Controller Settings: no colour "Overlay Style" picker, no "Touch IR Pointer" row, no "Pointer Sensitivity" slider. Edit IR Area, Reset All Overlay Layouts, Advanced Motion Settings and Analog Stick Settings are still there.
3. A player who had the old colour override set to Wii sees GameCube art on the GameCube pad.
4. Advanced Motion Settings: only Horizontal Movement, Full Motion Mapping (6DOF, Wiimote, Nunchuck) and Quick Setup. Horizontal Movement changes take effect in a running game.
5. Apply Recommended Settings: the player screen's Pointer row then reads Gyro, Invert X/Y off, Shake to Wiggle on.
6. The pointer mode changes only from the player screen's Pointer row and the top bar's pointer menu, and both show the same mode afterwards.
7. A Wii Remote bound to a DSU device: the hub's player row names the device, never "(Disconnected)". An MFi pad that is switched off still says "(Disconnected)".
8. Release/TestFlight build: Settings → Debug has no Motion Debug row. Apple TV pause screen: no gyroscope button; the speedometer button still opens the performance overlay.
9. Player screens still open from the hub on iOS and tvOS; capture, Load/Save Profile and Advanced still work (Phase 3 checklist items 1-10 spot check).

## Known gaps carried over
- (copy the Phase 3 handoff's "Known gaps" that still apply: pad Back on More/DSU pushed screens, the pad-disconnect profile stash, the Touchscreen-profile device flip)
```

Fill in "Landed" with `git log --oneline develop..HEAD`. Copy the still-open items from `docs/handoff-2026-09-30-controller-hub-phase3.md` "Known gaps" into the last section, verbatim except the two that Phase 4 closes: the hub's DSU "(Disconnected)" line and the `5bbeee6c33` dead-pad line (merged on 2026-10-02).

- [ ] **Step 5: Commit**

```bash
git add Source/iOS/App/Common/UI/Localization docs/handoff-2026-10-02-controller-hub-phase4.md
git commit -m "docs: controller hub phase 4 handoff; drop dead strings"
```

Merging and pushing need the user's go-ahead. Land by fast-forwarding develop to the branch from the main checkout, then bump the Provenance gitlink only when the user asks.
