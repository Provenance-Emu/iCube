# Controller Hub — Phase 2: Hub — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One Controllers hub, opened from the pause menu, from Settings and from the top bar. After this phase the pause-menu and Settings controller screens are the same screen, and the "Profiles… / Customize Buttons… only open after a scroll" lockup is gone.

**Architecture:** The hub is built like the pause menu and Cheats already are on the D18 engine:
- `ControllerHubViewModel` (`@Observable`, `@MainActor`) reads the bridges into a plain `ControllerHubState` snapshot. It is the only hub unit that touches `ControllerManager`, `TVControllerMappingBridge`, `DOLConfigBridge` and `GCController`.
- `ControllerHubModelBuilder` is pure: state plus a `ControllerHubActions` struct in, `MenuModel` out.
- `MenuScreen` renders the model.

Player rows push the existing `RemapPlayerView`; Phase 3 replaces it. Everything below the hub is a push. No core (C++) changes.

**Tech Stack:** Swift 5 mode, SwiftUI (Observation, `NavigationStack`), XCTest (`@testable import iCube`), Tuist-generated project, iOS 17+ / tvOS 17+.

**Spec:** `docs/superpowers/specs/2026-09-28-controller-hub-design.md`. Read it first. This plan implements its "Delivery phases → 2. Hub". Phase 1's plan (`docs/superpowers/plans/2026-09-28-controller-hub-phase1-foundation.md`) and handoff (`docs/handoff-2026-09-28-controller-hub-phase1.md`) describe what this builds on.

## Global Constraints

- Platforms: iOS 17+ and tvOS 17+. Every change must compile for both (`make gate-release`).
- tvOS focus rules: a `List` row is one focus target. SwiftUI `Menu`/`Picker` have no usable tvOS presentation. Never `.buttonStyle(.borderless)` on tvOS.
- Notification names: declare `FOUNDATION_EXPORT NSNotificationName const DOLFooNotification;` in an ObjC `.h`, define it in the `.m`, and use `.DOLFoo` from Swift. Never a string literal at a call site.
- Existing `UserDefaults` key names must not change (user values carry over).
- Stage explicit file paths only; never `git add -A`/`git add Source`. `build/xcframework/*` is rewritten by local builds, so never stage it.
- Adding a source file needs `cd Source/iOS/App && tuist generate --no-open` before building.
- Gates, run from `Source/iOS/App`:
  - Tests: `make test SIM="iPhone 17 Pro"`, which must end in `** TEST SUCCEEDED **`.
  - Release compile for both platforms: `make gate-release`, which must print `** BUILD SUCCEEDED **` twice.
  - If another `xcodebuild` is running (`pgrep -f "xcodebuild .*iCube"`), wait for it to finish; the builds share the core's CMake directories.
- Commits: conventional (`feat:`, `fix:`, `refactor:`, `test:`), subject under 72 characters, ending with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- `MenuScreen` already renders a tvOS `.picker` as one focusable row per option. Do not add a `Menu` or `Picker` of your own on a tvOS path.
- No sheet nested in a sheet. Below the hub everything is a push (`NavigationLink`, `.navigationDestination`). Save Profile As… (Phase 3) uses `MenuModal`.
- No presentation or navigation-destination modifier (`.sheet`, `.fullScreenCover`, `.navigationDestination`, `.alert`) is attached to a row or a `Section` inside a `List`. Attach it to the `List` itself or to a view outside it.
- Every task compiles for iOS and tvOS (`make gate-release`) and keeps `make test` green.
- This checkout is shared with other sessions. DO NOT git reset / rebase / push / checkout, and do not touch develop's history. Commit only the files a task lists.

## Decisions made while planning (differences from the spec, and rulings)

- **`dsu_role` defaults to `"sender"`: the value the runtime acts on today.**
  - The only code that behaves differently by role is the library's "Start DSU Controller" button: `Common/Swift/TVLibraryView.swift:1702`, inside `#if os(iOS)`. It reads `UserDefaults.standard.string(forKey: "dsu_role") ?? "sender"`. With the key unset it starts the DSU sender session (`showDSUSession = true`).
  - `ControllersRootView.swift:118` declares `@AppStorage("dsu_role") … = "receiver"`. That value is display-only: it picks the Role picker's selection and whether "Enable DSU Client" is disabled. Its `.onChange` fires only when the user changes the role.
  - The DSU client itself runs on `DOLConfigBridge.dsuClientEnabled()`, which never reads the role.
  - Task 2 registers `"sender"` through a new `DSUSettings`, on every launch from `AppDelegate`.
  - Two consequences, handled in Tasks 2 and 5:
    - (a) tvOS has no Role picker (`#if !os(tvOS)`). The client toggle's `.disabled(dsuRole == "sender")` would therefore make the DSU client impossible to enable on tvOS, so the lock becomes iOS-only.
    - (b) On iOS, a user who turned the client on under the old "receiver" display default now sees it on but locked until they pick Receiver. The client keeps running; only the toggle is locked. The handoff records this.
- **The lockup mechanism, and why the hub cannot have it.**
  - `ControllerSetupSections` attaches its three `.sheet`s (Customize Buttons, GC Profiles, Wiimote Profiles) to the "Connected Controllers" `Section` inside a `List`.
  - A `Section` is not a view with its own host: its modifiers are carried by its rows. A `List` is a lazy `UICollectionView` that only builds cells for rows on screen.
  - On a phone that section sits below eight player rows, so none of its rows exist until the list is scrolled. Setting `mappingTarget` or `showProfileForGCPort` changes state that no mounted view observes, and the sheet appears only once a scroll builds a row of that section.
  - A second, older trap is fixed in-tree but has the same root. `ControllersRootView` reads `ControllerSetupView(system:).sections` from a transient value that is never inserted into the tree, so that value's `@State` never gets storage. (`ControllerSetupSections` exists to work around this.)
  - The hub removes both:
    - Its only presentation-like modifiers are `MenuScreen`'s `.navigationDestination`s, attached to the `List` as a whole. Rows push through `NavigationLink`.
    - Its state lives in a `@State` view model owned by `ControllerHubView`, a real node in every host.
    - The leaf screens that used to present sheets now push instead: the layout editor, the IR-area editor and Add DSU Server.
- **Hub rows push, so the engine must push `.destination` on a controller's A (Task 3).**
  - `MenuScreen.performActivate` ignores `.destination`, so on iOS a pad's A on a player row did nothing.
  - No production screen uses `.destination` today (`git grep -n "role: \.destination(" -- 'Source/iOS/App/*.swift'` finds none; the engine's own `case .destination` arms in MenuScreen.swift are not uses), so nothing else changes behaviour.
- **"More Controller Settings" row (not in the spec).** The spec's four hub sections do not cover everything Settings → Controllers had. The rest moves unchanged behind one row in its own section, pushing `ControllerMoreSettingsView`:
  - General: Connect MFi Controllers, Background Input, Rumble Output, auto-select on-screen layout, Test Rumble.
  - Wii Remotes: Enable Speaker, Connect Wiimotes for Controller Interface.
  - Alternate Input Sources: Touch IR Pointer, programmatic overlay (beta), overlay art style, Reset All Overlay Layouts, Edit IR Area…, Pointer Sensitivity, Advanced Motion Settings, Analog Stick Settings.
  - Controller Lights: per-pad LED colour (iOS).

  Phase 4 deletes what the player screen replaces.
- **On-Screen Controls, iOS only:**
  - "Show On-Screen Controls" appears only while a game runs. Outside a game `EmulationScreen.onAppear` re-derives visibility at the next boot, so the toggle would do nothing.
  - "On-Screen Style" (Auto / GameCube / Wii) always appears. It is `ControllerManager.overlayMode`, which lasts for the app session and is not persisted.
  - Opacity is a 25 / 50 / 75 / 100 % picker, snapped from the stored value. A slider cannot be reached by a pad on iOS or focused on tvOS.
  - Edit Layout… pushes the existing editor, split out of its sheet.
- **The top bar keeps Pointer, Recenter Pointer, Show/Hide and Controller Settings….** Its On-Screen Style submenu is removed (Task 7).
  - The hub's style and visibility choices tell the emulation screen first, through a new `DOLOnScreenControlsChosenNotification` (Tasks 6–7).
  - Without that, `EmulationScreen`'s `assignmentsChanged` observer re-derives visibility. `overlayMode = .wii` posts `assignmentsChanged` synchronously from its `didSet` (`ensureWiimote1EmulatedTouchscreen`), so a hub choice would be undone at once.
  - The top bar sets the screen's `userOverrideTouchControls` itself.
- **Help: hold-to-exit is listed on tvOS only.**
  - The iOS pad route (`PauseGestureTracker.menuButtonChanged`) drops a hold of `DOLMenuLongPressDuration` or longer without exiting.
  - The exit timer in `EmuEventVC.m` is `TARGET_OS_TV`.
  - `EmuEventVC`'s `UILongPressGestureRecognizer` is installed on iOS too, but no gamepad route on iOS is known to deliver `UIPressTypeMenu`. The line stays tvOS-only until someone verifies it on a device.
- **Per-game pointer mode (Task 1).**
  - `GameProfiles.applyConfigOverrides` now calls `PointerModeController.setCurrentRun(rawValue:)`, which writes the CurrentRun layer and posts `.DOLPointerModeDidChange`.
  - That is correct only because `DOLConfigBridge.mainTouchPadIRMode()` reads the active layer (`Config::Get`, `Common/Bridging/DOLConfigBridge.mm:244`). The emulation screen's re-read therefore sees the override, not the Base value.
  - An unknown stored value now falls back to Touch – Follow, as `set(rawValue:)` already does.
- **`PointerModeController` is `@MainActor`.**
  - `GameProfiles` is a plain class, and its callers run in `addObserver(queue: .main)` blocks and view actions. It therefore reaches the controller through `MainActor.assumeIsolated`, which traps rather than silently racing if a caller is ever off-main.
  - All other call sites are inside SwiftUI `View`s.
- **Players with nothing bound are collapsed, exactly as the spec says.**
  - With no port bound, the Players section is only "Show All Ports".
  - GameCube ports keep the title "Player N", matching `RemapPlayerView`'s title. Wii Remotes read "Wii Remote N".
- **Identify moves to the pad row.** Tapping a Connected Devices row flashes and rumbles that pad, as the old Identify button did. The LED colour picker is a compound row, so it moves to More (iOS).
- **`ControllerSetupView` has no callers after Task 8 and is left for Phase 4 to delete**, as the spec schedules. `ControllerSetupSystem` moves out of `ControllerSetupView.swift` and `forRunningGame` out of `PauseMenuView.swift` (Task 4), so Phase 4 can delete the file whole.
- **Localization is done the project's way (Task 9).**
  - `L()` reads the `Core` table. "Update Core Strings" merges `Languages/po/<lang>.po` into `Core.strings` and preserves keys the `.po` does not have.
  - App-only strings are therefore added as identity entries to `en.lproj` and `ja.lproj` `Core.strings`, and `check_localized_keys.py --check` is the gate.
  - The Japanese entries stay English until a translator supplies them.
- **The DSU deep link now opens the server list.** `dolphinios://dsu/add` and `dsu://` (`URLRouterService`) opened Settings → Controllers, which listed the added server. That page is now the hub, so `SettingsRootView`'s jump goes to `DSUSettingsView` instead (Task 8).
- **Spotted, not fixed:** `auto_touchpad_by_system` has no runtime reader. The "Auto-select On-Screen Controller by System" toggle is inert. It moves to More unchanged.

## File Structure

| File | Responsibility |
|---|---|
| Modify `Source/iOS/App/Common/Swift/Controllers/PointerModeController.swift` | `@MainActor`; `setCurrentRun(_:)` for per-game overrides |
| Modify `Source/iOS/App/Common/Swift/GameProfiles.swift` | Route the per-game pointer mode through `PointerModeController` |
| Create `Source/iOS/App/Common/Swift/Controllers/DSUSettings.swift` | `dsu_role` key, its registered default, typed read |
| Modify `Source/iOS/App/Common/AppDelegate.swift` | Register DSU defaults on every launch |
| Modify `Source/iOS/App/Common/Swift/TVLibraryView.swift` | Read the role through `DSUSettings` |
| Modify `Source/iOS/App/Common/Swift/Menu/MenuScreen.swift` | Controller A pushes a `.destination` row |
| Create `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubState.swift` | `ControllerSetupSystem` (moved), `PlayerState`, `ConnectedPadState`, `ControllerHubState`, `ControllerHubActions`, `PlatformKind.current` |
| Create `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHelp.swift` | The Help rows, from the pause routing table |
| Create `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubModelBuilder.swift` | Pure builder: state + actions → `MenuModel` |
| Create `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubViewModel.swift` | `ControllerHubReading` seam, live reader, the view model |
| Create `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubView.swift` | Hosts the view model in a `MenuScreen` |
| Create `Source/iOS/App/Common/UI/Settings/SwiftUI/DSUSettingsView.swift` | DSU client screen (moved), Add Server pushed |
| Create `Source/iOS/App/Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift` | Everything the hub does not cover (moved) |
| Modify `Source/iOS/App/Common/UI/Settings/SwiftUI/ControllersRootView.swift` | Pushable overlay editors; then the hub host |
| Modify `Source/iOS/App/Common/UI/Settings/SwiftUI/SettingsRootView.swift` | DSU deep link lands on `DSUSettingsView` |
| Modify `Source/iOS/App/Common/UI/Emulation/EmuEventVC.h` / `.m` | Declare `DOLOnScreenControlsChosenNotification` |
| Modify `Source/iOS/App/Common/Swift/PauseMenuView.swift` | Hub in the iOS sheet and the tvOS pane |
| Modify `Source/iOS/App/Common/Swift/EmulationScreen.swift` | Hub in the top-bar sheet; drop On-Screen Style; follow hub choices |
| Modify `Source/iOS/App/Common/Swift/Controllers/ControllerSetupView.swift` | `ControllerSetupSystem` moves out |
| Modify `Source/iOS/App/Common/UI/Localization/{en,ja}.lproj/Core.strings` | Identity entries for Phase 1 + 2 keys |
| Create tests `Source/iOS/App/DolphiniOSTests/{DSUSettingsTests,ControllerHubModelBuilderTests,ControllerHubViewModelTests}.swift` | Unit tests |
| Modify `Source/iOS/App/DolphiniOSTests/PointerModeControllerTests.swift` | Main-actor tests, CurrentRun writes |
| Create `docs/handoff-2026-09-28-controller-hub-phase2.md` | Handoff + device checklist |

All paths below are relative to the repo root unless a step `cd`s into `Source/iOS/App`.

---

### Task 1: PointerModeController on the main actor; per-game overrides go through it

**Files:**
- Modify: `Source/iOS/App/Common/Swift/Controllers/PointerModeController.swift` (whole file)
- Modify: `Source/iOS/App/DolphiniOSTests/PointerModeControllerTests.swift` (whole file)
- Modify: `Source/iOS/App/Common/Swift/GameProfiles.swift:229-234` (`applyConfigOverrides`, the IR-mode block)

**Interfaces:**
- Consumes: `PointerMode`, `PointerModeController`, and `.DOLPointerModeDidChange` from Phase 1.
- Produces:
  - `@MainActor final class PointerModeController`.
  - `init(read: @escaping () -> Int, write: @escaping (Int) -> Void, writeCurrentRun: @escaping (Int) -> Void, notificationCenter: NotificationCenter)`.
  - `func setCurrentRun(_ mode: PointerMode)` and `func setCurrentRun(rawValue: Int)`. Both write the CurrentRun layer and post `.DOLPointerModeDidChange`.

- [ ] **Step 1: Write the failing tests**

Replace `Source/iOS/App/DolphiniOSTests/PointerModeControllerTests.swift` with:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

/// `PointerModeController` is `@MainActor`, so each test is too, and the controller is built per test
/// (not in the nonisolated `setUp`), following `LocalGameDeleterTests`.
final class PointerModeControllerTests: XCTestCase {
  /// Stands in for the core config: a Base value and an optional CurrentRun override on top.
  private final class Layers {
    var base = 1
    var currentRun: Int?
  }

  @MainActor
  private func makeController(_ layers: Layers, center: NotificationCenter = NotificationCenter()) -> PointerModeController {
    PointerModeController(
      read: { layers.currentRun ?? layers.base },
      write: { layers.base = $0 },
      writeCurrentRun: { layers.currentRun = $0 },
      notificationCenter: center)
  }

  @MainActor
  func testRawValuesMatchTheCoreConfig() {
    XCTAssertEqual(PointerMode.gyro.rawValue, 0)
    XCTAssertEqual(PointerMode.touchFollow.rawValue, 1)
    XCTAssertEqual(PointerMode.touchDrag.rawValue, 2)
  }

  @MainActor
  func testSetWritesTheConfigAndReadsBack() {
    let layers = Layers()
    let controller = makeController(layers)
    controller.set(.gyro)
    XCTAssertEqual(layers.base, 0)
    XCTAssertEqual(controller.mode, .gyro)
  }

  @MainActor
  func testSetPostsTheChangeNotification() {
    let center = NotificationCenter()
    let controller = makeController(Layers(), center: center)
    let posted = expectation(forNotification: .DOLPointerModeDidChange, object: nil, notificationCenter: center)
    controller.set(.touchDrag)
    wait(for: [posted], timeout: 1)
  }

  @MainActor
  func testUnknownRawValueFallsBackToTouchFollow() {
    let layers = Layers()
    let controller = makeController(layers)
    controller.set(rawValue: 7)
    XCTAssertEqual(layers.base, PointerMode.touchFollow.rawValue)
    layers.base = 9
    XCTAssertEqual(controller.mode, .touchFollow)
  }

  @MainActor
  func testSetCurrentRunWritesOnlyTheCurrentRunLayer() {
    let layers = Layers()
    let controller = makeController(layers)
    controller.setCurrentRun(.gyro)
    XCTAssertEqual(layers.currentRun, 0)
    XCTAssertEqual(layers.base, 1, "a per-game override must not become the global setting")
    XCTAssertEqual(controller.mode, .gyro, "mode reads the active layer, so it reports the override")
  }

  @MainActor
  func testSetCurrentRunPostsTheChangeNotification() {
    let center = NotificationCenter()
    let controller = makeController(Layers(), center: center)
    let posted = expectation(forNotification: .DOLPointerModeDidChange, object: nil, notificationCenter: center)
    controller.setCurrentRun(rawValue: 2)
    wait(for: [posted], timeout: 1)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/PointerModeControllerTests"`
Expected: build failure, `extra argument 'writeCurrentRun' in call` (or `incorrect argument label`).

- [ ] **Step 3: Write the implementation**

Replace the `PointerModeController` class in `Source/iOS/App/Common/Swift/Controllers/PointerModeController.swift` (everything after `enum PointerMode { … }`) with:
```swift
/// The one place the pointer mode changes. It used to be set directly from nine call sites
/// across the top bar, Settings, Advanced Motion, Motion Debug, the tvOS game properties and the
/// DSU controller, each with its own labels, and only the top bar updated the live pad.
///
/// Main-actor isolated: the only observer of `.DOLPointerModeDidChange` (EmulationScreen) writes
/// SwiftUI state, and `NotificationCenter` delivers on the posting thread.
@MainActor
final class PointerModeController {
  static let shared = PointerModeController(
    read: { Int(DOLConfigBridge.mainTouchPadIRMode()) },
    write: { DOLConfigBridge.setMainTouchPadIRMode($0) },
    writeCurrentRun: { DOLConfigBridge.setCurrentRunMainTouchPadIRMode($0) },
    notificationCenter: .default)

  private let read: () -> Int
  private let write: (Int) -> Void
  private let writeCurrentRun: (Int) -> Void
  private let notificationCenter: NotificationCenter

  init(
    read: @escaping () -> Int,
    write: @escaping (Int) -> Void,
    writeCurrentRun: @escaping (Int) -> Void,
    notificationCenter: NotificationCenter
  ) {
    self.read = read
    self.write = write
    self.writeCurrentRun = writeCurrentRun
    self.notificationCenter = notificationCenter
  }

  /// The active value. `DOLConfigBridge.mainTouchPadIRMode()` is `Config::Get`, so a per-game
  /// CurrentRun override is what this reports while its title runs.
  var mode: PointerMode { PointerMode(rawValue: read()) ?? .touchFollow }

  func set(_ mode: PointerMode) {
    write(mode.rawValue)
    notifyChanged()
  }

  /// For call sites that hold the config's raw integer.
  func set(rawValue: Int) {
    set(PointerMode(rawValue: rawValue) ?? .touchFollow)
  }

  /// A per-game override (`GameProfiles`). Written to the CurrentRun layer so it ends with the
  /// title instead of becoming the global setting.
  func setCurrentRun(_ mode: PointerMode) {
    writeCurrentRun(mode.rawValue)
    notifyChanged()
  }

  func setCurrentRun(rawValue: Int) {
    setCurrentRun(PointerMode(rawValue: rawValue) ?? .touchFollow)
  }

  private func notifyChanged() {
    notificationCenter.post(name: .DOLPointerModeDidChange, object: nil)
  }
}
```

- [ ] **Step 4: Route the per-game override through it**

In `Source/iOS/App/Common/Swift/GameProfiles.swift`, `applyConfigOverrides(_:)`, replace
```swift
    if let mode = irOverride, mode >= 0, mode != DOLConfigBridge.mainTouchPadIRMode() {
      DOLConfigBridge.setCurrentRunMainTouchPadIRMode(mode)
    }
```
with
```swift
    if let mode = irOverride, mode >= 0, mode != DOLConfigBridge.mainTouchPadIRMode() {
      // Through PointerModeController so the live touch pad follows the per-game mode
      // (`.DOLPointerModeDidChange`). Every caller runs on the main queue: EmulationScreen's
      // `addObserver(queue: .main)` blocks and view actions.
      MainActor.assumeIsolated { PointerModeController.shared.setCurrentRun(rawValue: mode) }
    }
```

- [ ] **Step 5: Check no other writer bypasses it, and every caller is on the main actor**

Run: `git grep -n "setCurrentRunMainTouchPadIRMode\|setMainTouchPadIRMode(" -- 'Source/iOS/App/*.swift'`
Expected: only lines in `PointerModeController.swift`.

Then build (Step 6). The remaining callers of `PointerModeController.shared` are all inside `View` structs, which are main-actor isolated: `EmulationScreen.swift`, `MotionDebugView.swift`, `TVSoftwarePropertiesView.swift`, `Widgets/DSUControllerView.swift` (`toggleIRMode()` included), `ControllersRootView.swift`, `EnhancedMotionControlsView.swift`. If the compiler reports `call to main actor-isolated … in a synchronous nonisolated context` at one of them:
- If the call sits directly in a method, add `@MainActor` to that method.
- If it sits inside a closure the compiler treats as nonisolated (a `Binding(set:)`, an `asyncAfter` block), wrap the call in `MainActor.assumeIsolated { … }`. Every one of these runs on the main thread.

Do not add `nonisolated` or `DispatchQueue.main.async` wrappers.

- [ ] **Step 6: Run the tests and the gates**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/PointerModeControllerTests"`
Expected: `Executed 6 tests, with 0 failures`.
Then: `make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` and `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice (tvOS compiles `TVSoftwarePropertiesView`'s call site).

- [ ] **Step 7: Commit**

```bash
git add Source/iOS/App/Common/Swift/Controllers/PointerModeController.swift \
  Source/iOS/App/DolphiniOSTests/PointerModeControllerTests.swift Source/iOS/App/Common/Swift/GameProfiles.swift
git commit -m "fix(input): per-game pointer mode goes through PointerModeController"
```
Add any file Step 5 had to annotate to the same `git add`.

---

### Task 2: DSUSettings, one registered `dsu_role` default

**Files:**
- Create: `Source/iOS/App/Common/Swift/Controllers/DSUSettings.swift`
- Create: `Source/iOS/App/DolphiniOSTests/DSUSettingsTests.swift`
- Modify: `Source/iOS/App/Common/AppDelegate.swift:12` (after `MotionSettings.registerDefaults()`)
- Modify: `Source/iOS/App/Common/Swift/TVLibraryView.swift:1702-1703`
- Modify: `Source/iOS/App/Common/UI/Settings/SwiftUI/ControllersRootView.swift:118`, `:171-181`, `:186`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum DSUSettings`, with `DSUSettings.Key.role` (`"dsu_role"`) and `enum DSUSettings.Role: String { case receiver, sender }`.
  - `DSUSettings.defaults: [String: Any]`.
  - `static func registerDefaults(in store: UserDefaults = .standard)`.
  - `static func role(in store: UserDefaults = .standard) -> DSUSettings.Role`.
  - Task 5's `DSUSettingsView` uses `DSUSettings.Key.role` and `DSUSettings.Role`.

- [ ] **Step 1: Write the failing test**

`Source/iOS/App/DolphiniOSTests/DSUSettingsTests.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class DSUSettingsTests: XCTestCase {
  private var store: UserDefaults!
  private let suite = "DSUSettingsTests"

  override func setUp() {
    super.setUp()
    UserDefaults().removePersistentDomain(forName: suite)
    store = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: suite)
    super.tearDown()
  }

  /// "sender" is what the runtime did with the key unset: TVLibraryView's "Start DSU Controller"
  /// read `?? "sender"` and started the session.
  func testRegisteredRoleIsSender() {
    DSUSettings.registerDefaults(in: store)
    XCTAssertEqual(store.string(forKey: DSUSettings.Key.role), "sender")
    XCTAssertEqual(DSUSettings.role(in: store), .sender)
  }

  func testAUserChoiceBeatsTheRegisteredDefault() {
    DSUSettings.registerDefaults(in: store)
    store.set(DSUSettings.Role.receiver.rawValue, forKey: DSUSettings.Key.role)
    XCTAssertEqual(DSUSettings.role(in: store), .receiver)
  }

  func testAnUnknownStoredValueReadsAsSender() {
    store.set("server", forKey: DSUSettings.Key.role)
    XCTAssertEqual(DSUSettings.role(in: store), .sender)
  }

  func testKeyAndValuesAreTheExistingOnes() {
    XCTAssertEqual(DSUSettings.Key.role, "dsu_role")
    XCTAssertEqual(DSUSettings.Role.receiver.rawValue, "receiver")
    XCTAssertEqual(DSUSettings.Role.sender.rawValue, "sender")
  }

  /// FirstRunInitializationService registers DefaultPreferences.plist on every launch AFTER
  /// AppDelegate, so a DSU key left in it would silently override DSUSettings.defaults.
  func testBundledDefaultPreferencesDefineNoDSUSettingsKey() throws {
    let url = try XCTUnwrap(Bundle.main.url(forResource: "DefaultPreferences", withExtension: "plist"))
    let plist = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
    for key in DSUSettings.defaults.keys {
      XCTAssertNil(plist[key], "\(key) is registered by both DefaultPreferences.plist and DSUSettings")
    }
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/DSUSettingsTests"`
Expected: build failure, `cannot find 'DSUSettings' in scope`.

- [ ] **Step 3: Write the implementation**

`Source/iOS/App/Common/Swift/Controllers/DSUSettings.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The DSU role (`dsu_role`): whether this device receives motion from a DSU server or shares its
/// own input as one. The two readers disagreed on the unset value: Settings → Controllers showed
/// "receiver" while the library's "Start DSU Controller" (the only code that acts on the role)
/// treated it as "sender". Registered on every launch from `AppDelegate`, like `MotionSettings`.
/// `DefaultPreferences.plist` must not define it: `FirstRunInitializationService` registers that
/// plist on every launch after `AppDelegate`, and would win.
enum DSUSettings {
  enum Key {
    static let role = "dsu_role"
  }

  enum Role: String {
    case receiver
    case sender
  }

  /// "sender": what the app did with the key unset (`TVLibraryView`'s `?? "sender"`).
  static let defaults: [String: Any] = [Key.role: Role.sender.rawValue]

  static func registerDefaults(in store: UserDefaults = .standard) {
    store.register(defaults: defaults)
  }

  static func role(in store: UserDefaults = .standard) -> Role {
    Role(rawValue: store.string(forKey: Key.role) ?? "") ?? .sender
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/DSUSettingsTests"`
Expected: `Executed 5 tests, with 0 failures`.

- [ ] **Step 5: Adopt it**

1. `Source/iOS/App/Common/AppDelegate.swift`: directly after `MotionSettings.registerDefaults()` add
   ```swift
   DSUSettings.registerDefaults()
   ```
2. `Source/iOS/App/Common/Swift/TVLibraryView.swift` (~1702): replace
   ```swift
        let role = UserDefaults.standard.string(forKey: "dsu_role") ?? "sender"
        if role == "receiver" {
   ```
   with
   ```swift
        if DSUSettings.role() == .receiver {
   ```
3. `Source/iOS/App/Common/UI/Settings/SwiftUI/ControllersRootView.swift`:
   - Line 118: replace the `@AppStorage("dsu_role") …` line with
     ```swift
     @AppStorage(DSUSettings.Key.role) private var dsuRole: String = DSUSettings.Role.sender.rawValue
     ```
   - In the Role picker (~171-181), use the enum instead of the literals:
     ```swift
           Picker(L("Role"), selection: $dsuRole) {
             Text(L("Receiver")).tag(DSUSettings.Role.receiver.rawValue)
             Text(L("Sender")).tag(DSUSettings.Role.sender.rawValue)
           }
           .onChange(of: dsuRole) { role in
             if role == DSUSettings.Role.sender.rawValue {
     ```
     Leave the body of the `if` unchanged.
   - Line 186: replace `.disabled(dsuRole == "sender"),` with `.disabled(isDSUClientLocked),`. Then add this property to `ControllersRootView`, directly above `var body: some View {`:
     ```swift
     /// Sender mode shares this device's input instead of receiving it, so the client toggle is locked
     /// while Sender is picked. iOS only: tvOS has no Role picker, so with "sender" registered as the
     /// default a tvOS lock could never be lifted.
     private var isDSUClientLocked: Bool {
       #if os(iOS)
       return dsuRole == DSUSettings.Role.sender.rawValue
       #else
       return false
       #endif
     }
     ```
4. Verify: `git grep -n '"dsu_role"\|"receiver"\|"sender"' -- 'Source/iOS/App/*.swift'` prints only `DSUSettings.swift`.

- [ ] **Step 6: Run the full gates**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice.

- [ ] **Step 7: Commit**

```bash
git add Source/iOS/App/Common/Swift/Controllers/DSUSettings.swift Source/iOS/App/DolphiniOSTests/DSUSettingsTests.swift \
  Source/iOS/App/Common/AppDelegate.swift Source/iOS/App/Common/Swift/TVLibraryView.swift \
  Source/iOS/App/Common/UI/Settings/SwiftUI/ControllersRootView.swift
git commit -m "fix(dsu): register the dsu_role default the runtime acts on"
```

---

### Task 3: Menu engine — a controller's A pushes a `.destination` row on iOS

**Files:**
- Modify: `Source/iOS/App/Common/Swift/Menu/MenuScreen.swift`: the `PushedMenu` block (~85-93), `body` (~124-142), and `performActivate` with its doc comment (~186-207)

**Interfaces:**
- Consumes: nothing.
- Produces: on iOS, `MenuScreen` pushes a `.destination(AnyView)` item when a pad activates it. Touch is unchanged: the row's own `NavigationLink` handles it. On tvOS nothing changes, because the native `NavigationLink` handles select. Tasks 4–8 rely on this for every hub row that pushes.

No unit test: this is SwiftUI navigation state with no pure seam, and `MenuFocusRouter` already reports the activation (covered by `MenuFocusRouterTests`). The device checklist (Task 10, item 2) verifies it.

- [ ] **Step 1: Add the destination push state**

In `MenuScreen.swift`, directly after `@State private var pushedChild: PushedMenu?`:
```swift
  /// A `.destination` row pushed by a controller's A (iOS) or a grid card tap. A list row's tap goes
  /// through the row's own `NavigationLink` instead. Before this, A on such a row did nothing.
  private struct PushedDestination: Identifiable, Hashable {
    let id = UUID()
    let view: AnyView

    static func == (lhs: PushedDestination, rhs: PushedDestination) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
  }

  @State private var pushedDestination: PushedDestination?
```

- [ ] **Step 2: Attach its destination to the whole screen**

In `body`, directly after the existing
```swift
      .navigationDestination(item: $pushedChild) { child in
        MenuScreen(model: child.model, style: style, onBack: { pushedChild = nil })
      }
```
add
```swift
      .navigationDestination(item: $pushedDestination) { destination in
        destination.view
      }
```
It sits on `content` (the whole `List`/grid), never on a row. That is the placement the Global Constraints require.

- [ ] **Step 3: Push on activate**

In `performActivate(_:)`, replace
```swift
    case .destination, .custom:
      break
```
with
```swift
    case .destination(let destinationView):
      pushedDestination = PushedDestination(view: destinationView)
    case .custom:
      break
```
Update the doc comment above `performActivate` so it no longer says `.destination` is a no-op. Replace its last two sentences (from "`.destination`/`.custom` are escape hatches" to the end) with:
```swift
  /// `.destination` pushes its view (a list row's tap goes through its `NavigationLink` instead, so
  /// this path is the controller's A and grid cards). `.custom` owns its own gestures, so activation
  /// is a no-op for it.
```

- [ ] **Step 4: Run the gates**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **` (`MenuModelTests`, `MenuFocusRouterTests`, `RemapModelTests`, `PauseMenuModelBuilderTests`, `CheatsMenuModelBuilderTests` unchanged); `** BUILD SUCCEEDED **` twice.

- [ ] **Step 5: Commit**

```bash
git add Source/iOS/App/Common/Swift/Menu/MenuScreen.swift
git commit -m "feat(menu): a controller's A pushes a destination row"
```

---

### Task 4: Hub snapshot, Help lines and the pure ControllerHubModelBuilder

**Files:**
- Create: `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubState.swift`
- Create: `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHelp.swift`
- Create: `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubModelBuilder.swift`
- Create: `Source/iOS/App/DolphiniOSTests/ControllerHubModelBuilderTests.swift`
- Modify: `Source/iOS/App/Common/Swift/Controllers/ControllerSetupView.swift:9-22` (remove `enum ControllerSetupSystem`, moved)
- Modify: `Source/iOS/App/Common/Swift/PauseMenuView.swift:11-18` (remove `extension ControllerSetupSystem`, moved)

**Interfaces:**
- Consumes:
  - `DeviceFamily.from(qualifier:)` (Phase 1).
  - `ControllerManager.OverlayMode`.
  - `PlatformKind` (`PauseMenuView.swift`).
  - `DOLMenuLongPressDuration` (`EmuEventVC.h`).
  - `MenuModel` / `MenuSection` / `MenuItem` / `MenuItemRole`.
- Produces (Tasks 6–8 use these exact names):
  - `enum ControllerSetupSystem { case gamecube, wii, both, wiiAndGameCube }`, with `showsGameCube`, `showsWii`, `wiiFirst` and `static var forRunningGame` (moved, unchanged).
  - `extension PlatformKind { static var current: PlatformKind }`.
  - `struct PlayerState: Equatable` with:
    - `kind: Kind` (`enum Kind: Equatable { case gameCube, wiiRemote }`)
    - `port: Int` (1-based)
    - `deviceQualifier: String` (`""` = nothing bound)
    - `wiiExtension: Int`
    - `isSideways: Bool`
    - computed `id: String` (`"gc-N"` / `"wii-N"`) and `isBound: Bool`
  - `struct PlayerSlot: Equatable { kind: PlayerState.Kind; port: Int }`.
  - `struct ConnectedPadState: Equatable` with `qualifier: String`, `name: String`, `batteryPercent: Int?`, `isCharging: Bool`, `playerLabel: String?`.
  - `struct ControllerHubState` with:
    - `system: ControllerSetupSystem`
    - `players: [PlayerState]`
    - `showAllPorts: Bool`
    - `pads: [ConnectedPadState]`
    - `isGameRunning: Bool`
    - `overlayVisible: Bool`
    - `overlayMode: ControllerManager.OverlayMode`
    - `overlayOpacityPercent: Int`
    - `continuousScanning: Bool`
    - `dsuClientEnabled: Bool`
    - `dsuServerCount: Int`

    Plus `static func empty(system:) -> ControllerHubState`, `static func slots(for: ControllerSetupSystem) -> [PlayerSlot]`, `static let opacityChoices: [Int]` and `static func snappedOpacityPercent(_: Float) -> Int`.
  - `struct ControllerHubActions` (fields listed in Step 3).
  - `struct ControllerHelpLine: Equatable { id, action, how: String }` and `enum ControllerHelp { static func lines(platform: PlatformKind) -> [ControllerHelpLine] }`.
  - `enum ControllerHubModelBuilder { static func make(state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuModel }`.
  - Stable section ids: `"players"`, `"on-screen"`, `"devices"`, `"more"`, `"help"`.
  - Stable item ids: `PlayerState.id`, `"show-all-ports"`, `"osc-visible"`, `"osc-style"`, `"osc-opacity"`, `"osc-edit-layout"`, `"pad-<qualifier>"`, `"no-pads"`, `"wiimote-scan"`, `"dsu"`, `"more-settings"` and `"help-<line id>"`.

- [ ] **Step 1: Write the failing tests**

`Source/iOS/App/DolphiniOSTests/ControllerHubModelBuilderTests.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI
import XCTest

@testable import iCube

/// Covers `ControllerHubModelBuilder` (controller hub spec, "Controllers hub"): rows per system,
/// "Show All Ports" collapsing, platform differences. Pure: every action is a recorded closure,
/// every destination an `EmptyView`, as in `PauseMenuModelBuilderTests`.
final class ControllerHubModelBuilderTests: XCTestCase {

  private static let xbox = "MFi/0/Xbox Wireless Controller"
  private static let touch = "iOS/4/Touchscreen"

  private func actions(
    toggleShowAllPorts: @escaping () -> Void = {},
    setOverlayVisible: @escaping (Bool) -> Void = { _ in },
    setOverlayMode: @escaping (ControllerManager.OverlayMode) -> Void = { _ in },
    setOverlayOpacity: @escaping (Float) -> Void = { _ in },
    identifyPad: @escaping (String) -> Void = { _ in },
    setContinuousScanning: @escaping (Bool) -> Void = { _ in }
  ) -> ControllerHubActions {
    ControllerHubActions(
      playerDestination: { _ in AnyView(EmptyView()) },
      toggleShowAllPorts: toggleShowAllPorts,
      setOverlayVisible: setOverlayVisible,
      setOverlayMode: setOverlayMode,
      setOverlayOpacity: setOverlayOpacity,
      editLayoutDestination: { AnyView(EmptyView()) },
      identifyPad: identifyPad,
      setContinuousScanning: setContinuousScanning,
      dsuDestination: { AnyView(EmptyView()) },
      moreSettingsDestination: { AnyView(EmptyView()) })
  }

  /// Every port of `system`; `bound` maps a player id ("gc-1", "wii-2") to its device qualifier.
  private func state(
    system: ControllerSetupSystem,
    bound: [String: String] = [:],
    wiiExtension: [Int: Int] = [:],
    showAllPorts: Bool = false,
    pads: [ConnectedPadState] = [],
    isGameRunning: Bool = true
  ) -> ControllerHubState {
    var hub = ControllerHubState.empty(system: system)
    hub.players = ControllerHubState.slots(for: system).map { slot in
      let id = (slot.kind == .gameCube ? "gc-" : "wii-") + String(slot.port)
      return PlayerState(
        kind: slot.kind, port: slot.port, deviceQualifier: bound[id] ?? "",
        wiiExtension: slot.kind == .wiiRemote ? (wiiExtension[slot.port] ?? 0) : 0, isSideways: false)
    }
    hub.showAllPorts = showAllPorts
    hub.pads = pads
    hub.isGameRunning = isGameRunning
    return hub
  }

  private func make(_ state: ControllerHubState, _ actions: ControllerHubActions? = nil, platform: PlatformKind = .ios) -> MenuModel {
    ControllerHubModelBuilder.make(state: state, actions: actions ?? self.actions(), platform: platform)
  }

  private func ids(_ model: MenuModel, section id: String) -> [String] {
    model.sections.first { $0.id == id }?.items.map(\.id) ?? []
  }

  private func run(_ item: MenuItem?) {
    guard let item, case .action(let action) = item.role else { return XCTFail("not an action row") }
    action()
  }

  // MARK: Sections per platform

  func test_iOS_sectionOrder() {
    XCTAssertEqual(make(state(system: .gamecube)).sections.map(\.id), ["players", "on-screen", "devices", "more", "help"])
  }

  func test_tvOS_hasNoOnScreenControls() {
    XCTAssertEqual(make(state(system: .gamecube), platform: .tvos).sections.map(\.id), ["players", "devices", "more", "help"])
  }

  // MARK: Players

  func test_slots_followTheSystem() {
    func ids(_ system: ControllerSetupSystem) -> [String] {
      ControllerHubState.slots(for: system).map { ($0.kind == .gameCube ? "gc-" : "wii-") + String($0.port) }
    }
    XCTAssertEqual(ids(.gamecube), ["gc-1", "gc-2", "gc-3", "gc-4"])
    XCTAssertEqual(ids(.wii), ["wii-1", "wii-2", "wii-3", "wii-4"])
    XCTAssertEqual(ids(.both), ["gc-1", "gc-2", "gc-3", "gc-4", "wii-1", "wii-2", "wii-3", "wii-4"])
    XCTAssertEqual(ids(.wiiAndGameCube), ["wii-1", "wii-2", "wii-3", "wii-4", "gc-1", "gc-2", "gc-3", "gc-4"])
  }

  func test_unboundPorts_collapseUnderShowAllPorts() {
    let model = make(state(system: .gamecube, bound: ["gc-1": Self.xbox]))
    XCTAssertEqual(ids(model, section: "players"), ["gc-1", "show-all-ports"])
    XCTAssertEqual(model.item(id: "show-all-ports")?.title, "Show All Ports")
    XCTAssertEqual(model.item(id: "show-all-ports")?.badge, "3")
  }

  func test_showAllPorts_listsEveryPortInTheRunningGamesOrder() {
    let model = make(state(system: .wiiAndGameCube, bound: ["wii-1": Self.touch], showAllPorts: true))
    XCTAssertEqual(
      ids(model, section: "players"),
      ["wii-1", "wii-2", "wii-3", "wii-4", "gc-1", "gc-2", "gc-3", "gc-4", "show-all-ports"])
    XCTAssertEqual(model.item(id: "show-all-ports")?.title, "Hide Unused Ports")
    XCTAssertNil(model.item(id: "show-all-ports")?.badge)
  }

  func test_everyPortBound_hasNoShowAllRow() {
    let all = Dictionary(uniqueKeysWithValues: (1 ... 4).map { ("gc-\($0)", Self.xbox) })
    XCTAssertEqual(ids(make(state(system: .gamecube, bound: all)), section: "players"), ["gc-1", "gc-2", "gc-3", "gc-4"])
  }

  func test_nothingBound_leavesOnlyShowAllPorts() {
    XCTAssertEqual(ids(make(state(system: .both)), section: "players"), ["show-all-ports"])
  }

  func test_showAllRow_runsItsAction() {
    var toggled = false
    let model = make(state(system: .gamecube), actions(toggleShowAllPorts: { toggled = true }))
    run(model.item(id: "show-all-ports"))
    XCTAssertTrue(toggled)
  }

  func test_playerRow_namesThePortTheDeviceAndTheEmulatedController() {
    let pad = ConnectedPadState(qualifier: Self.xbox, name: "Xbox Wireless Controller", batteryPercent: nil, isCharging: false, playerLabel: "P1")
    let model = make(state(system: .wiiAndGameCube, bound: ["gc-1": Self.xbox, "wii-1": Self.touch], wiiExtension: [1: 1], pads: [pad]))
    XCTAssertEqual(model.item(id: "gc-1")?.title, "Player 1")
    XCTAssertEqual(model.item(id: "gc-1")?.subtitle, "Xbox Wireless Controller · GameCube Controller")
    XCTAssertEqual(model.item(id: "wii-1")?.title, "Wii Remote 1")
    XCTAssertEqual(model.item(id: "wii-1")?.subtitle, "Touchscreen · Wii Remote + Nunchuk")
  }

  func test_playerRow_boundToAPadThatIsGone_saysDisconnected() {
    let model = make(state(system: .gamecube, bound: ["gc-2": "MFi/1/DualSense Wireless Controller"]))
    XCTAssertEqual(model.item(id: "gc-2")?.subtitle, "DualSense Wireless Controller (Disconnected) · GameCube Controller")
  }

  func test_playerRow_pushesThePlayerScreen() {
    let model = make(state(system: .gamecube, bound: ["gc-1": Self.xbox]))
    guard case .destination = model.item(id: "gc-1")?.role else { return XCTFail("a player row must push") }
  }

  // MARK: On-Screen Controls (iOS)

  func test_showHideRow_onlyWhileAGameRuns() {
    XCTAssertTrue(ids(make(state(system: .gamecube, isGameRunning: true)), section: "on-screen").contains("osc-visible"))
    XCTAssertEqual(
      ids(make(state(system: .gamecube, isGameRunning: false)), section: "on-screen"),
      ["osc-style", "osc-opacity", "osc-edit-layout"])
  }

  func test_showHideToggle_writesThroughTheAction() {
    var written: Bool?
    let model = make(state(system: .gamecube), actions(setOverlayVisible: { written = $0 }))
    guard case .toggle(let binding)? = model.item(id: "osc-visible")?.role else { return XCTFail("not a toggle") }
    binding.wrappedValue = true
    XCTAssertEqual(written, true)
  }

  func test_stylePicker_offersAutoGameCubeWii_andWritesThroughTheAction() {
    var written: ControllerManager.OverlayMode?
    let model = make(state(system: .gamecube), actions(setOverlayMode: { written = $0 }))
    guard case .picker(let options, let selection)? = model.item(id: "osc-style")?.role else { return XCTFail("not a picker") }
    XCTAssertEqual(options.map { $0.0 }, ["Auto", "GameCube", "Wii"])
    XCTAssertEqual(selection.wrappedValue, AnyHashable(ControllerManager.OverlayMode.auto))
    selection.wrappedValue = AnyHashable(ControllerManager.OverlayMode.wii)
    XCTAssertEqual(written, .wii)
  }

  func test_opacityPicker_offersQuarterSteps_andWritesAFraction() {
    var written: Float?
    let model = make(state(system: .gamecube), actions(setOverlayOpacity: { written = $0 }))
    guard case .picker(let options, let selection)? = model.item(id: "osc-opacity")?.role else { return XCTFail("not a picker") }
    XCTAssertEqual(options.map { $0.0 }, ["25%", "50%", "75%", "100%"])
    selection.wrappedValue = AnyHashable(75)
    XCTAssertEqual(written, 0.75)
  }

  func test_opacitySnapsToTheNearestChoice() {
    XCTAssertEqual(ControllerHubState.snappedOpacityPercent(0.5), 50)
    XCTAssertEqual(ControllerHubState.snappedOpacityPercent(0.62), 50)
    XCTAssertEqual(ControllerHubState.snappedOpacityPercent(0.9), 100)
    XCTAssertEqual(ControllerHubState.snappedOpacityPercent(0.0), 25)
    XCTAssertEqual(ControllerHubState.snappedOpacityPercent(1.0), 100)
  }

  func test_editLayout_pushes() {
    guard case .destination = make(state(system: .gamecube)).item(id: "osc-edit-layout")?.role else {
      return XCTFail("Edit Layout must push, not present")
    }
  }

  // MARK: Connected Devices

  func test_padRow_showsBatteryAndPlayer_andIdentifies() {
    var identified: String?
    let pads = [
      ConnectedPadState(qualifier: Self.xbox, name: "Xbox Wireless Controller", batteryPercent: 80, isCharging: false, playerLabel: "P1"),
      ConnectedPadState(qualifier: "MFi/1/DualSense Wireless Controller", name: "DualSense Wireless Controller", batteryPercent: 40, isCharging: true, playerLabel: nil),
    ]
    let model = make(state(system: .gamecube, pads: pads), actions(identifyPad: { identified = $0 }))
    let xbox = model.item(id: "pad-\(Self.xbox)")
    XCTAssertEqual(xbox?.title, "Xbox Wireless Controller")
    XCTAssertEqual(xbox?.subtitle, "Battery 80%")
    XCTAssertEqual(xbox?.badge, "P1")
    XCTAssertEqual(model.item(id: "pad-MFi/1/DualSense Wireless Controller")?.subtitle, "Battery 40% · Charging")
    run(xbox)
    XCTAssertEqual(identified, Self.xbox)
  }

  func test_noPads_showsADisabledPlaceholder() {
    let model = make(state(system: .gamecube))
    XCTAssertEqual(model.item(id: "no-pads")?.isEnabled, false)
    XCTAssertFalse(model.focusableIDs.contains("no-pads"))
  }

  func test_continuousScanning_onlyWhenTheSystemHasWiiRemotes() {
    XCTAssertFalse(ids(make(state(system: .gamecube)), section: "devices").contains("wiimote-scan"))
    XCTAssertTrue(ids(make(state(system: .wiiAndGameCube)), section: "devices").contains("wiimote-scan"))
    XCTAssertTrue(ids(make(state(system: .both), platform: .tvos), section: "devices").contains("wiimote-scan"))
  }

  func test_continuousScanning_writesThroughTheAction() {
    var written: Bool?
    let model = make(state(system: .wii), actions(setContinuousScanning: { written = $0 }))
    guard case .toggle(let binding)? = model.item(id: "wiimote-scan")?.role else { return XCTFail("not a toggle") }
    binding.wrappedValue = true
    XCTAssertEqual(written, true)
  }

  func test_dsuRow_summarisesTheClient_andPushes() {
    var hub = state(system: .gamecube)
    XCTAssertEqual(make(hub).item(id: "dsu")?.subtitle, "Off")
    hub.dsuClientEnabled = true
    hub.dsuServerCount = 2
    let model = make(hub)
    XCTAssertEqual(model.item(id: "dsu")?.subtitle, "On · 2 servers")
    guard case .destination = model.item(id: "dsu")?.role else { return XCTFail("DSU must push") }
  }

  // MARK: More and Help

  func test_moreSettings_pushes() {
    guard case .destination = make(state(system: .gamecube)).item(id: "more-settings")?.role else {
      return XCTFail("More Controller Settings must push")
    }
  }

  /// A tvOS List scrolls only by moving focus, and a disabled row takes no focus, so Help rows are
  /// enabled no-op actions, or they would be unreachable below the fold.
  func test_helpRows_areEnabledSoTVOSCanReachThem() {
    let model = make(state(system: .gamecube), platform: .tvos)
    let help = ids(model, section: "help")
    XCTAssertFalse(help.isEmpty)
    XCTAssertTrue(help.allSatisfy { model.focusableIDs.contains($0) })
    XCTAssertEqual(model.sections.last?.id, "help")
  }

  func test_help_iOSListsPadRoutesOnly() {
    XCTAssertEqual(ControllerHelp.lines(platform: .ios).map(\.id), ["pause", "pause-chord", "fast-forward", "start"])
  }

  func test_help_tvOSAddsTheSiriRemote_withTheLongPressDuration() {
    let lines = ControllerHelp.lines(platform: .tvos)
    XCTAssertEqual(lines.map(\.id), ["pause", "pause-chord", "fast-forward", "start", "remote-pause", "remote-exit"])
    XCTAssertEqual(lines.last?.how, "Hold Back / Menu for \(Int(DOLMenuLongPressDuration)) s")
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/ControllerHubModelBuilderTests"`
Expected: build failure, `cannot find 'ControllerHubActions' in scope`.

- [ ] **Step 3: Write the snapshot types**

1. Delete `enum ControllerSetupSystem { … }` and its doc comment from `Source/iOS/App/Common/Swift/Controllers/ControllerSetupView.swift` (lines 9-22).
2. Delete `extension ControllerSetupSystem { … }` from `Source/iOS/App/Common/Swift/PauseMenuView.swift` (lines 11-18).
3. Create `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubState.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Which ports a controller screen lists. Distinct from `EmulatedSystem` (which the assignment
/// service switches on exhaustively) so `.both` can never leak into the service. Moved here from
/// `ControllerSetupView.swift`, which Phase 4 deletes.
enum ControllerSetupSystem {
  case gamecube
  case wii
  case both
  /// A running Wii title: Wii Remotes first, then the GameCube ports many Wii games also accept.
  case wiiAndGameCube

  var showsGameCube: Bool { self == .gamecube || self == .both || self == .wiiAndGameCube }
  var showsWii: Bool { self == .wii || self == .both || self == .wiiAndGameCube }
  var wiiFirst: Bool { self == .wiiAndGameCube }
}

extension ControllerSetupSystem {
  /// The ports the running game accepts: Wii titles get Wii Remotes and GameCube ports,
  /// GameCube titles the ports only. Read from the running core, not `ControllerManager.isWiiSystem`.
  static var forRunningGame: ControllerSetupSystem {
    let isWii = TVEmulationBridge.isRunning() ? TVEmulationBridge.isCurrentSystemWii() : ControllerManager.shared.isWiiSystem
    return isWii ? .wiiAndGameCube : .gamecube
  }
}

extension PlatformKind {
  static var current: PlatformKind {
    #if os(tvOS)
    return .tvos
    #else
    return .ios
    #endif
  }
}

/// One port as the hub shows it.
struct PlayerState: Equatable {
  enum Kind: Equatable {
    case gameCube
    case wiiRemote
  }

  let kind: Kind
  /// 1-based.
  let port: Int
  /// The bound device (`MFi/0/Xbox Wireless Controller`, `iOS/4/Touchscreen`), or "" when the
  /// port is off. A port's stock default device is the touchscreen even while the port is off,
  /// so the reader reports "" for an inactive port, never the stored qualifier.
  let deviceQualifier: String
  /// 0 None, 1 Nunchuk, 2 Classic (`WiimoteSlotOptions`). 0 for GameCube ports.
  let wiiExtension: Int
  let isSideways: Bool

  var id: String { (kind == .gameCube ? "gc-" : "wii-") + String(port) }
  var isBound: Bool { !deviceQualifier.isEmpty }
}

struct PlayerSlot: Equatable {
  let kind: PlayerState.Kind
  let port: Int
}

/// One connected pad, read from `GCController` by the view model.
struct ConnectedPadState: Equatable {
  /// `TVControllerMappingBridge.qualifiedName(for:)`, unique per pad (it carries the index).
  let qualifier: String
  let name: String
  /// nil while the pad reports no battery.
  let batteryPercent: Int?
  let isCharging: Bool
  /// "P1"…"P4", nil when the pad has no player index.
  let playerLabel: String?
}

/// Plain snapshot of everything the hub shows. No bridge reads happen after it is built;
/// `ControllerHubViewModel` rebuilds it.
struct ControllerHubState {
  var system: ControllerSetupSystem
  var players: [PlayerState]
  /// "Show All Ports": list unbound ports too. UI state, kept across reloads.
  var showAllPorts: Bool
  var pads: [ConnectedPadState]
  var isGameRunning: Bool
  var overlayVisible: Bool
  var overlayMode: ControllerManager.OverlayMode
  /// One of `opacityChoices`.
  var overlayOpacityPercent: Int
  var continuousScanning: Bool
  var dsuClientEnabled: Bool
  var dsuServerCount: Int

  static func empty(system: ControllerSetupSystem) -> ControllerHubState {
    ControllerHubState(
      system: system, players: [], showAllPorts: false, pads: [], isGameRunning: false,
      overlayVisible: false, overlayMode: .auto, overlayOpacityPercent: 50,
      continuousScanning: false, dsuClientEnabled: false, dsuServerCount: 0)
  }

  /// Ports in on-screen order: a running Wii title lists its Wii Remotes first.
  static func slots(for system: ControllerSetupSystem) -> [PlayerSlot] {
    let gameCube = (1 ... 4).map { PlayerSlot(kind: .gameCube, port: $0) }
    let wii = (1 ... 4).map { PlayerSlot(kind: .wiiRemote, port: $0) }
    switch system {
    case .gamecube: return gameCube
    case .wii: return wii
    case .both: return gameCube + wii
    case .wiiAndGameCube: return wii + gameCube
    }
  }

  /// The on-screen controls' opacity steps. A slider cannot be reached by a pad on iOS or focused
  /// on tvOS; four steps can, and d-pad left/right cycles them.
  static let opacityChoices = [25, 50, 75, 100]

  /// The choice nearest the stored opacity (0…1), so the picker always shows a selection.
  static func snappedOpacityPercent(_ opacity: Float) -> Int {
    let percent = Int((opacity * 100).rounded())
    return opacityChoices.min { abs($0 - percent) < abs($1 - percent) } ?? 100
  }
}

/// Plain closures: no bridge calls inside `ControllerHubModelBuilder`. Destinations are factories
/// so the builder never names a bridge-backed view.
struct ControllerHubActions {
  var playerDestination: (PlayerState) -> AnyView
  var toggleShowAllPorts: () -> Void
  var setOverlayVisible: (Bool) -> Void
  var setOverlayMode: (ControllerManager.OverlayMode) -> Void
  /// 0…1.
  var setOverlayOpacity: (Float) -> Void
  var editLayoutDestination: () -> AnyView
  /// The pad's qualifier.
  var identifyPad: (String) -> Void
  var setContinuousScanning: (Bool) -> Void
  var dsuDestination: () -> AnyView
  var moreSettingsDestination: () -> AnyView
}
```

- [ ] **Step 4: Write the Help lines**

`Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHelp.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

struct ControllerHelpLine: Equatable {
  let id: String
  let action: String
  let how: String
}

/// The hub's Help rows, one per in-game action. Generated from the routing that
/// `installPauseMenuHandlers` documents (the table in `ControllerExtensions.swift`) and
/// `PauseGestureTracker` implements. A route added there needs a line here.
///
/// Hold-to-exit is tvOS only. `EmuEventVC`'s exit timer is `TARGET_OS_TV`, and on iOS the pad
/// route (`PauseGestureTracker.menuButtonChanged`) drops a long hold without exiting.
enum ControllerHelp {
  static func lines(platform: PlatformKind) -> [ControllerHelpLine] {
    var lines = [
      ControllerHelpLine(id: "pause", action: L("Pause"), how: L("View / Share / − button, or Home on Xbox and PlayStation pads")),
      ControllerHelpLine(id: "pause-chord", action: L("Pause on any pad"), how: L("Hold all four shoulder buttons, then press Menu")),
      ControllerHelpLine(id: "fast-forward", action: L("Fast-forward"), how: L("Hold all four shoulder buttons")),
      ControllerHelpLine(id: "start", action: L("Start / +"), how: L("Menu / Options / + button")),
    ]
    if platform == .tvos {
      lines.append(ControllerHelpLine(id: "remote-pause", action: L("Pause with the Siri Remote"), how: L("Press Back / Menu")))
      lines.append(ControllerHelpLine(
        id: "remote-exit", action: L("Exit to Library"),
        how: String(format: L("Hold Back / Menu for %d s"), Int(DOLMenuLongPressDuration))))
    }
    return lines
  }
}
```

- [ ] **Step 5: Write the builder**

`Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubModelBuilder.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// Builds the Controllers hub (controller hub spec, "Controllers hub"):
/// - Players, with unbound ports under "Show All Ports".
/// - On-Screen Controls (iOS).
/// - Connected Devices.
/// - More.
/// - Help.
///
/// Pure: state and actions in, `MenuModel` out, no bridge calls, mirroring `PauseMenuModelBuilder`
/// and `CheatsMenuModelBuilder`. Rows that open something PUSH (`.destination`); nothing here
/// presents.
enum ControllerHubModelBuilder {
  static func make(state: ControllerHubState, actions: ControllerHubActions, platform: PlatformKind) -> MenuModel {
    var sections = [playersSection(state: state, actions: actions)]
    if platform == .ios {
      sections.append(onScreenSection(state: state, actions: actions))
    }
    sections.append(devicesSection(state: state, actions: actions))
    sections.append(MenuSection(id: "more", items: [
      MenuItem(
        id: "more-settings", title: L("More Controller Settings"), icon: "slider.horizontal.3",
        role: .destination(actions.moreSettingsDestination())),
    ]))
    sections.append(helpSection(platform: platform))
    return MenuModel(sections: sections)
  }

  // MARK: Players

  private static func playersSection(state: ControllerHubState, actions: ControllerHubActions) -> MenuSection {
    let bound = state.players.filter(\.isBound)
    let shown = state.showAllPorts ? state.players : bound
    var items = shown.map { player in
      MenuItem(
        id: player.id,
        title: title(for: player),
        subtitle: "\(deviceName(for: player, pads: state.pads)) · \(emulatedController(for: player))",
        icon: player.kind == .gameCube ? "gamecontroller" : "wand.and.rays",
        role: .destination(actions.playerDestination(player)))
    }
    let hiddenCount = state.players.count - bound.count
    if hiddenCount > 0 {
      items.append(MenuItem(
        id: "show-all-ports",
        title: state.showAllPorts ? L("Hide Unused Ports") : L("Show All Ports"),
        icon: state.showAllPorts ? "chevron.up" : "chevron.down",
        role: .action(actions.toggleShowAllPorts),
        badge: state.showAllPorts ? nil : String(hiddenCount)))
    }
    return MenuSection(id: "players", header: L("Players"), items: items)
  }

  private static func title(for player: PlayerState) -> String {
    String(format: player.kind == .gameCube ? L("Player %d") : L("Wii Remote %d"), player.port)
  }

  private static func deviceName(for player: PlayerState, pads: [ConnectedPadState]) -> String {
    let qualifier = player.deviceQualifier
    if qualifier.isEmpty { return L("No Device") }
    if DeviceFamily.from(qualifier: qualifier) == .touchscreen { return L("Touchscreen") }
    if let pad = pads.first(where: { $0.qualifier == qualifier }) { return pad.name }
    // Bound, but the pad is not connected: the binding is kept and returns with the pad.
    let name = qualifier.split(separator: "/", maxSplits: 2).last.map(String.init) ?? qualifier
    return String(format: L("%@ (Disconnected)"), name)
  }

  private static func emulatedController(for player: PlayerState) -> String {
    switch player.kind {
    case .gameCube:
      return L("GameCube Controller")
    case .wiiRemote:
      switch player.wiiExtension {
      case 1: return L("Wii Remote + Nunchuk")
      case 2: return L("Wii Remote + Classic Controller")
      default: return player.isSideways ? L("Wii Remote (Sideways)") : L("Wii Remote")
      }
    }
  }

  // MARK: On-Screen Controls (iOS)

  private static func onScreenSection(state: ControllerHubState, actions: ControllerHubActions) -> MenuSection {
    var items: [MenuItem] = []
    // Visibility is re-derived at every game start, so it only means something in a game.
    if state.isGameRunning {
      items.append(MenuItem(
        id: "osc-visible", title: L("Show On-Screen Controls"), icon: "hand.tap",
        role: .toggle(Binding(get: { state.overlayVisible }, set: { actions.setOverlayVisible($0) }))))
    }
    let styles: [(String, AnyHashable)] = [
      (L("Auto"), AnyHashable(ControllerManager.OverlayMode.auto)),
      (L("GameCube"), AnyHashable(ControllerManager.OverlayMode.gamecube)),
      (L("Wii"), AnyHashable(ControllerManager.OverlayMode.wii)),
    ]
    items.append(MenuItem(
      id: "osc-style", title: L("On-Screen Style"), icon: "rectangle.3.group",
      role: .picker(options: styles, selection: Binding(
        get: { AnyHashable(state.overlayMode) },
        set: { if let mode = $0.base as? ControllerManager.OverlayMode { actions.setOverlayMode(mode) } }))))
    items.append(MenuItem(
      id: "osc-opacity", title: L("Opacity"), icon: "circle.lefthalf.filled",
      role: .picker(
        options: ControllerHubState.opacityChoices.map { ("\($0)%", AnyHashable($0)) },
        selection: Binding(
          get: { AnyHashable(state.overlayOpacityPercent) },
          set: { if let percent = $0.base as? Int { actions.setOverlayOpacity(Float(percent) / 100) } }))))
    items.append(MenuItem(
      id: "osc-edit-layout", title: L("Edit Layout…"), icon: "rectangle.and.pencil.and.ellipsis",
      role: .destination(actions.editLayoutDestination())))
    return MenuSection(id: "on-screen", header: L("On-Screen Controls"), items: items)
  }

  // MARK: Connected Devices

  private static func devicesSection(state: ControllerHubState, actions: ControllerHubActions) -> MenuSection {
    var items = state.pads.map { pad in
      MenuItem(
        id: "pad-\(pad.qualifier)", title: pad.name, subtitle: batteryText(for: pad), icon: "gamecontroller.fill",
        role: .action { actions.identifyPad(pad.qualifier) }, badge: pad.playerLabel)
    }
    if items.isEmpty {
      items.append(MenuItem(id: "no-pads", title: L("No controllers connected"), role: .action({}), isEnabled: false))
    }
    if state.system.showsWii {
      items.append(MenuItem(
        id: "wiimote-scan", title: L("Continuous Wii Remote Scanning"), icon: "antenna.radiowaves.left.and.right",
        role: .toggle(Binding(get: { state.continuousScanning }, set: { actions.setContinuousScanning($0) }))))
    }
    items.append(MenuItem(
      id: "dsu", title: L("Motion Source (DSU)"), subtitle: dsuSummary(state), icon: "dot.radiowaves.left.and.right",
      role: .destination(actions.dsuDestination())))
    return MenuSection(id: "devices", header: L("Connected Devices"), items: items)
  }

  private static func batteryText(for pad: ConnectedPadState) -> String? {
    guard let percent = pad.batteryPercent else { return nil }
    return pad.isCharging
      ? String(format: L("Battery %d%% · Charging"), percent)
      : String(format: L("Battery %d%%"), percent)
  }

  private static func dsuSummary(_ state: ControllerHubState) -> String {
    guard state.dsuClientEnabled else { return L("Off") }
    return String(format: L("On · %d servers"), state.dsuServerCount)
  }

  // MARK: Help

  /// Enabled no-op rows: a tvOS List scrolls only by focus, and a disabled row takes none.
  private static func helpSection(platform: PlatformKind) -> MenuSection {
    MenuSection(id: "help", header: L("Help"), items: ControllerHelp.lines(platform: platform).map { line in
      MenuItem(id: "help-\(line.id)", title: line.action, subtitle: line.how, role: .action({}))
    })
  }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/ControllerHubModelBuilderTests"`
Expected: `Executed 26 tests, with 0 failures`.

- [ ] **Step 7: Run the full gates**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice. `ControllerSetupView`, `PauseMenuView` and `EmulationScreen` still compile: `ControllerSetupSystem` and `.forRunningGame` only moved.

- [ ] **Step 8: Commit**

```bash
git add Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubState.swift \
  Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHelp.swift \
  Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubModelBuilder.swift \
  Source/iOS/App/DolphiniOSTests/ControllerHubModelBuilderTests.swift \
  Source/iOS/App/Common/Swift/Controllers/ControllerSetupView.swift Source/iOS/App/Common/Swift/PauseMenuView.swift
git commit -m "feat(controllers): pure Controllers hub model builder"
```

---

### Task 5: Pushable leaf screens — DSU, More Controller Settings, overlay editors

These are the hub's destinations. Each is moved out of `ControllersRootView` with any sheet replaced by a push, so nothing is a sheet nested in the hub's sheet. `ControllersRootView` keeps its own DSU and settings copies until Task 8 replaces it. Only its two editor sheets change here, because the editor types are split.

**Files:**
- Create: `Source/iOS/App/Common/UI/Settings/SwiftUI/DSUSettingsView.swift`
- Create: `Source/iOS/App/Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift`
- Modify: `Source/iOS/App/Common/UI/Settings/SwiftUI/ControllersRootView.swift`:
  - `:23` (`AnalogStickSettingsView` becomes internal)
  - `:130-132` (editor state)
  - `:386-391`, `:406-410` (editor buttons)
  - `:442-447` (editor sheets)
  - `:660-739` (editor types)

**Interfaces:**
- Consumes:
  - `DSUSettings.Key.role` and `DSUSettings.Role` (Task 2).
  - `settingsCaption(_:_:)` and `settingsNavCaption(destination:_:label:)` (`PerformanceTuningView.swift`).
  - `TouchIRMode` and `TouchIRModePicker` (`ControllersRootView.swift`).
- Produces:
  - `struct DSUSettingsView: View` (`init()`).
  - `struct ControllerMoreSettingsView: View` (`init()`).
  - `struct AnalogStickSettingsView: View`, now internal.
  - iOS only: `struct TouchOverlayLayoutEditorView: View` (`init()`) and `struct TouchOverlayIRAreaEditorView: View` (`init()`). Neither owns a `NavigationStack`.
  - Task 6's view model pushes all of these.

- [ ] **Step 1: Split the overlay editors out of their sheets**

In `ControllersRootView.swift`, replace the two editor types, from `/// The Settings "Edit Layout…" preview` (~660) through the closing `}` of `struct TouchOverlayIRAreaEditorSheet` (~737), keeping the enclosing `#if os(iOS)` / `#endif`, with:
```swift
/// The "Edit Layout…" preview (task item 3): the programmatic overlay already in `.layout` edit
/// mode, with no live game/device context. `TouchOverlayView.init(initialEditMode:)` makes this
/// safe: every group's input is suppressed while any edit mode is active. There is no live game to
/// infer the Wii variant from, so the picker chooses which of the four pad kinds to edit.
///
/// `irMode: .none` (task item 2's DSU pass) rather than the live `mainTouchPadIRMode()`:
/// `TouchOverlayIRPadView`'s `mode`/`isEditingFlag` `didSet`s both call `forceReleaseAndCenter()`
/// on mount, which wrote to the placeholder `deviceId: 0`. `.none` makes both true no-ops.
///
/// Pushed, not presented. It owns no `NavigationStack`, so the Controllers hub (itself a sheet from
/// the pause menu and the top bar) pushes it instead of nesting a sheet.
struct TouchOverlayLayoutEditorView: View {
  @State private var padKind: TouchOverlayPadKind = .gameCube

  var body: some View {
    VStack(spacing: 0) {
      Picker(L("Layout"), selection: $padKind) {
        Text(L("GameCube")).tag(TouchOverlayPadKind.gameCube)
        Text(L("Wii Remote")).tag(TouchOverlayPadKind.wiiRemote)
        Text(L("Wii Remote (Sideways)")).tag(TouchOverlayPadKind.wiiRemoteSideways)
        Text(L("Wii + Classic Controller")).tag(TouchOverlayPadKind.wiiClassic)
      }
      .pickerStyle(.segmented)
      .padding()

      TouchOverlayView(padKind: padKind, deviceId: 0,
                       irMode: TCWiiTouchIRMode.none.rawValue, initialEditMode: .layout)
        .id(padKind)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }
    .navigationTitle(L("Edit Layout"))
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// The "Edit IR Area…" preview (task item 1): the same `TouchOverlayView`, seeded into `.irArea`
/// mode. Forces `padKind: .wiiRemote`: `wiiIRPad` exists only in that pad kind's default layout
/// (`TouchOverlayDefaults.wiiRemote`). `irMode: .none` for the same reason as the layout editor.
/// Pushed, like `TouchOverlayLayoutEditorView`.
struct TouchOverlayIRAreaEditorView: View {
  var body: some View {
    TouchOverlayView(padKind: .wiiRemote, deviceId: 0,
                     irMode: TCWiiTouchIRMode.none.rawValue, initialEditMode: .irArea)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black.opacity(0.85))
      .navigationTitle(L("Edit IR Area"))
      .navigationBarTitleDisplayMode(.inline)
  }
}
```
Then, in `struct ControllersRootView`:
1. Delete the three `@State` lines `showTouchOverlayEditor`, `touchOverlayEditorPadKind` and `showTouchOverlayIRAreaEditor` (~130-132).
2. Replace the "Edit Layout…" button
   ```swift
           Button {
             touchOverlayEditorPadKind = .gameCube
             showTouchOverlayEditor = true
           } label: {
             Label(L("Edit Layout…"), systemImage: "rectangle.and.pencil.and.ellipsis")
           }
   ```
   with
   ```swift
           NavigationLink {
             TouchOverlayLayoutEditorView()
           } label: {
             Label(L("Edit Layout…"), systemImage: "rectangle.and.pencil.and.ellipsis")
           }
   ```
3. Replace the "Edit IR Area…" button
   ```swift
             Button {
               showTouchOverlayIRAreaEditor = true
             } label: {
               Label(L("Edit IR Area…"), systemImage: "scope")
             }
   ```
   with
   ```swift
             NavigationLink {
               TouchOverlayIRAreaEditorView()
             } label: {
               Label(L("Edit IR Area…"), systemImage: "scope")
             }
   ```
4. Delete the `#if os(iOS)` block holding the two editor `.sheet`s (~441-448): `.sheet(isPresented: $showTouchOverlayEditor) { … }` and `.sheet(isPresented: $showTouchOverlayIRAreaEditor) { … }`, with their `#if os(iOS)` / `#endif`.
5. Line 23: change `private struct AnalogStickSettingsView: View {` to `struct AnalogStickSettingsView: View {`.

Check: `git grep -n "TouchOverlayLayoutEditorSheet\|TouchOverlayIRAreaEditorSheet\|showTouchOverlay" -- 'Source/iOS/App/*.swift'` prints only a doc-comment mention in `TouchOverlayView.swift:144`. Update that comment's `TouchOverlayIRAreaEditorSheet` to `TouchOverlayIRAreaEditorView`.

- [ ] **Step 2: Create the DSU screen**

`Source/iOS/App/Common/UI/Settings/SwiftUI/DSUSettingsView.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The DSU motion source, pushed from the Controllers hub ("Motion Source (DSU)"). Moved out of
/// Settings → Controllers unchanged, except that Add Server is pushed instead of presented: the
/// hub is itself a sheet from the pause menu and the top bar.
struct DSUSettingsView: View {
  @State private var dsuEnabled = false
  @State private var dsuServers: [[String: Any]] = [] // keys: description, address, port
  @State private var showAddServer = false
  @StateObject private var dsuBrowser = DSUDiscoveryBrowser()
  @State private var recentlyAdded: Set<String> = [] // address:port keys
  @AppStorage(DSUSettings.Key.role) private var dsuRole: String = DSUSettings.Role.sender.rawValue
  @State private var pingingServerKey: String?

  /// Sender mode shares this device's input instead of receiving it, so the client toggle is locked
  /// while Sender is picked. iOS only: tvOS has no Role picker, so with "sender" registered as the
  /// default a tvOS lock could never be lifted.
  private var isClientLocked: Bool {
    #if os(iOS)
    return dsuRole == DSUSettings.Role.sender.rawValue
    #else
    return false
    #endif
  }

  var body: some View {
    List {
      Section(
        header: HStack {
          Text("DSU Client")
          if !dsuBrowser.servers.isEmpty {
            Text(String(format: L("%d found"), dsuBrowser.servers.count))
              .font(.caption)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.blue.opacity(0.15), in: Capsule())
          }
        }
      ) {
        #if !os(tvOS)
        settingsCaption(
          Picker(L("Role"), selection: $dsuRole) {
            Text(L("Receiver")).tag(DSUSettings.Role.receiver.rawValue)
            Text(L("Sender")).tag(DSUSettings.Role.sender.rawValue)
          }
          .onChange(of: dsuRole) { _, role in
            if role == DSUSettings.Role.sender.rawValue {
              dsuEnabled = false
              DOLConfigBridge.setDsuClientEnabled(false)
            }
          },
          L("Receiver pulls motion/input from a DSU server; Sender shares this device's input instead."))
        #endif
        settingsCaption(
          Toggle(L("Enable DSU Client"), isOn: $dsuEnabled)
            .onChange(of: dsuEnabled) { _, enabled in DOLConfigBridge.setDsuClientEnabled(enabled) }
            .disabled(isClientLocked),
          L("Receives input from a Cemuhook DSU server on your network (e.g. a phone's gyro). Add servers below as IP:Port."))
        Toggle(L("Show DSU Debug HUD"), isOn: Binding(get: {
#if DEBUG
          true
#else
          UserDefaults.standard.bool(forKey: "ui_show_dsu_debug_hud")
#endif
        }, set: { v in
#if !DEBUG
          UserDefaults.standard.set(v, forKey: "ui_show_dsu_debug_hud")
#endif
        }))
        Toggle(L("Map IR (Gyro) to DSU Touch"), isOn: Binding(get: {
          UserDefaults.standard.bool(forKey: "dsu_map_ir_to_touch")
        }, set: { v in
          UserDefaults.standard.set(v, forKey: "dsu_map_ir_to_touch")
          NotificationCenter.default.post(name: Notification.Name("DOLMotionSettingsChanged"), object: nil)
        }))
        Toggle(L("Send DSU Gyro/Accel"), isOn: Binding(get: {
          let has = UserDefaults.standard.object(forKey: "dsu_enable_gyro") != nil
          return has ? UserDefaults.standard.bool(forKey: "dsu_enable_gyro") : true
        }, set: { v in
          UserDefaults.standard.set(v, forKey: "dsu_enable_gyro")
        }))
        if dsuServers.isEmpty {
          HStack {
            Text(L("Servers"))
            Spacer()
            Text(L("None")).foregroundStyle(.secondary)
          }
        } else {
          ForEach(0 ..< dsuServers.count, id: \.self) { idx in
            serverRow(idx)
          }
        }
        Button(action: { showAddServer = true }) {
          Label(L("Add Server"), systemImage: "plus")
        }
      }

      if !dsuBrowser.servers.isEmpty {
        Section(header: Text(L("Discovered on Network"))) {
          ForEach(dsuBrowser.servers) { s in
            discoveredRow(s)
          }
        }
      }
    }
    .navigationTitle(L("Motion Source (DSU)"))
    // On the List, never on a row: see the plan's lockup note.
    .navigationDestination(isPresented: $showAddServer) {
      AddDSUServerView { name, address, port in
        DOLConfigBridge.addDsuServer(name, address: address, port: port)
        refreshServers()
      }
    }
    .onAppear {
      dsuEnabled = DOLConfigBridge.dsuClientEnabled()
      refreshServers()
      dsuBrowser.start()
    }
    .onDisappear { dsuBrowser.stop() }
  }

  @ViewBuilder
  private func serverRow(_ idx: Int) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(serverTitle(idx))
        Text(serverAddressPort(idx)).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      let addr = (dsuServers[idx]["address"] as? String) ?? ""
      let sanAddr: String = {
        let trimmed = addr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = trimmed.firstIndex(of: "@") { return String(trimmed[..<at]) } else { return trimmed }
      }()
      let port = (dsuServers[idx]["port"] as? NSNumber)?.intValue ?? 26760
      let key = "\(sanAddr):\(port)"
      if pingingServerKey == key {
        ProgressView().padding(.vertical, 4)
      } else {
        Button {
          pingingServerKey = key
          NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Pinging %@…"), key)])
          DSUPingBridge.pingServerAddress(sanAddr, port: port, timeout: 1.0) { ok, info in
            pingingServerKey = nil
            let msg = ok ? String(format: L("Reachable: %@"), info ?? key) : L("No response")
            NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": msg])
          }
        } label: {
          Label(L("Test"), systemImage: "paperplane")
            .labelStyle(.titleAndIcon)
            .frame(minWidth: 72)
        }
        .buttonStyle(.bordered)
        #if !os(tvOS)
        .controlSize(.regular)
        #endif
        .padding(.vertical, 4)
      }
    }
    #if !os(tvOS)
    .swipeActions(edge: .trailing) {
      Button(role: .destructive) {
        DOLConfigBridge.removeDsuServer(at: idx)
        refreshServers()
      } label: { Label(L("Delete"), systemImage: "trash") }
    }
    #endif
  }

  @ViewBuilder
  private func discoveredRow(_ s: DSUDiscoveredServer) -> some View {
    let key = "\(s.address):\(s.port)"
    let isSaved = dsuServers.contains { server in
      ((server["address"] as? String) == s.address) && ((server["port"] as? NSNumber)?.intValue == s.port)
    }
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(s.name)
          if recentlyAdded.contains(key) {
            Text(L("New"))
              .font(.caption2)
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(Color.green.opacity(0.15), in: Capsule())
          }
        }
        Text(key).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if isSaved {
        Text(L("Saved"))
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(Color.blue.opacity(0.1), in: Capsule())
      } else {
        Button(L("Add")) {
          let trimmed = s.address.trimmingCharacters(in: .whitespacesAndNewlines)
          let addr = (trimmed.firstIndex(of: "@").map { String(trimmed[..<$0]) }) ?? trimmed
          DOLConfigBridge.addDsuServer(s.name, address: addr, port: s.port)
          refreshServers()
          recentlyAdded.insert(key)
          NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": String(format: L("Added DSU server: %@"), key)])
        }
        .buttonStyle(.bordered)
      }
    }
  }

  private func refreshServers() {
    dsuServers = DOLConfigBridge.dsuServersParsed() ?? []
  }

  private func serverTitle(_ idx: Int) -> String {
    if idx < 0 || idx >= dsuServers.count { return "Server \(idx + 1)" }
    let desc = (dsuServers[idx]["description"] as? String) ?? ""
    let addrPort = serverAddressPort(idx)
    if desc.isEmpty {
      return addrPort.isEmpty ? "Server \(idx + 1)" : addrPort
    }
    return addrPort.isEmpty ? desc : "\(desc) — \(addrPort)"
  }

  private func serverAddressPort(_ idx: Int) -> String {
    if idx < 0 || idx >= dsuServers.count { return "" }
    let addr = (dsuServers[idx]["address"] as? String) ?? ""
    let port = (dsuServers[idx]["port"] as? NSNumber)?.intValue ?? 0
    return port > 0 ? "\(addr):\(port)" : addr
  }
}

/// Add a DSU server by address. Pushed from `DSUSettingsView`; Back cancels.
private struct AddDSUServerView: View {
  let onAdd: (_ name: String, _ address: String, _ port: Int) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var serverName = "DS4"
  @State private var address = ""
  @State private var port = "26760"

  var body: some View {
    Form {
      Section(header: Text(L("Description"))) {
        TextField("DS4", text: $serverName)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled(true)
      }
      Section(header: Text(L("Server Address"))) {
        TextField("192.168.1.100", text: $address)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled(true)
          .keyboardType(.numbersAndPunctuation)
      }
      Section(header: Text(L("Port"))) {
        TextField("26760", text: $port)
          .keyboardType(.numberPad)
      }
    }
    .navigationTitle(L("Add DSU Server"))
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button(L("Add")) {
          onAdd(serverName, address, Int(port) ?? 26760)
          dismiss()
        }
        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }
}
```
`DSUDiscoveryBrowser.servers` is `[DSUDiscoveredServer]` (`DSUDiscovery.swift:23`), `Identifiable`, with the `name`, `address` and `port` the old `ControllersRootView` loop used.

- [ ] **Step 3: Create the More Controller Settings screen**

`Source/iOS/App/Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreHaptics
import GameController
import SwiftUI
import UIKit

/// Controller settings outside the hub's four sections, pushed from its "More Controller Settings"
/// row. Everything here was on Settings → Controllers before the hub. Controller hub Phase 4
/// removes what the player screen replaces (the pointer-mode picker, Advanced Motion Settings).
struct ControllerMoreSettingsView: View {
  @State private var autoSelectOnScreenBySystem = true
  @State private var connectWiimotes = false
  @State private var touchIRMode: TouchIRMode = .drag
  #if os(iOS)
  @State private var touchOverlayProgrammatic = false
  /// Raw `TouchOverlayArt.Style` integer (`touch_overlay_style`).
  @State private var touchOverlayStyle = 0
  @State private var touchOverlayIRPointerGain = 1.0
  #endif

  var body: some View {
    List {
      Section(header: Text(L("General"))) {
        settingsCaption(
          Toggle(L("Auto‑select On‑Screen Controller by System"), isOn: $autoSelectOnScreenBySystem)
            .onChange(of: autoSelectOnScreenBySystem) { _, newValue in
              UserDefaults.standard.set(newValue, forKey: "auto_touchpad_by_system")
            },
          L("Automatically shows the GameCube or Wii on-screen layout based on the game being played."))
        #if os(iOS)
        Button(action: { Self.testRumble() }) {
          Label(L("Test Rumble"), systemImage: "waveform")
        }
        #endif
      }

      Section(header: Text(L("Wii Remotes"))) {
        settingsCaption(
          Toggle(L("Connect Wiimotes for Controller Interface"), isOn: $connectWiimotes)
            .onChange(of: connectWiimotes) { _, newValue in
              DOLConfigBridge.setConnectWiimotesForControllerInterface(newValue)
            },
          L("Automatically pairs Wii Remotes when the controller interface is in use."))
      }

      Section(header: Text(L("Alternate Input Sources"))) {
        // TouchIRModePicker's rows set the mode through PointerModeController themselves.
        settingsNavCaption(
          destination: TouchIRModePicker(selected: $touchIRMode),
          L("How the Wii Remote pointer is driven. Gyro uses device motion; Follow/Drag use touch gestures.")
        ) {
          Text("\(L("Touch IR Pointer")): \(touchIRMode.label)")
        }

        #if os(iOS)
        settingsCaption(
          Toggle(L("Programmatic touch overlay (beta)"), isOn: $touchOverlayProgrammatic)
            .onChange(of: touchOverlayProgrammatic) { _, newValue in
              UserDefaults.standard.set(newValue, forKey: "touch_overlay_programmatic")
            },
          L("Replaces the on-screen GameCube/Wii pads with the new SwiftUI-rendered, user-editable overlay. Long-press the overlay in-game to move or resize its controls."))

        settingsCaption(
          Picker(L("Overlay Style"), selection: $touchOverlayStyle) {
            Text(L("Auto")).tag(0)
            Text(L("GameCube")).tag(1)
            Text(L("Wii")).tag(2)
          }
          .pickerStyle(.segmented)
          .onChange(of: touchOverlayStyle) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "touch_overlay_style")
          },
          L("Overrides whether the programmatic overlay's button art uses GameCube or Wii coloring, or matches the pad kind automatically."))

        Button(role: .destructive) {
          for kind in TouchOverlayPadKind.allCases { TouchOverlayLayoutStore.shared.reset(padKind: kind) }
        } label: {
          Label(L("Reset All Overlay Layouts"), systemImage: "arrow.counterclockwise")
        }

        // Gated on the beta flag: these only affect the programmatic overlay's live rendering.
        if touchOverlayProgrammatic {
          NavigationLink {
            TouchOverlayIRAreaEditorView()
          } label: {
            Label(L("Edit IR Area…"), systemImage: "scope")
          }

          settingsCaption(
            HStack {
              Text(L("Pointer Sensitivity"))
              Spacer()
              Slider(
                value: $touchOverlayIRPointerGain,
                in: Double(TouchOverlayIRGeometry.dragGainRange.lowerBound) ... Double(TouchOverlayIRGeometry.dragGainRange.upperBound))
                .frame(width: 220)
                .onChange(of: touchOverlayIRPointerGain) { _, gain in
                  UserDefaults.standard.set(gain, forKey: MotionSettings.Key.irPointerGain)
                }
            },
            L("Scales how far the Wii Remote pointer moves per drag in Drag mode. Doesn't affect Follow or Gyro mode."))
        }
        #endif

        NavigationLink(destination: EnhancedMotionControlsView()) {
          Label(L("Advanced Motion Settings"), systemImage: "gyroscope")
        }
        NavigationLink(destination: AnalogStickSettingsView()) {
          Label(L("Analog Stick Settings"), systemImage: "l.joystick")
        }
      }
    }
    .navigationTitle(L("More Controller Settings"))
    .onAppear { syncFromConfig() }
  }

  private func syncFromConfig() {
    if UserDefaults.standard.object(forKey: "auto_touchpad_by_system") == nil {
      UserDefaults.standard.set(true, forKey: "auto_touchpad_by_system")
    }
    autoSelectOnScreenBySystem = UserDefaults.standard.bool(forKey: "auto_touchpad_by_system")
    connectWiimotes = DOLConfigBridge.connectWiimotesForControllerInterface()
    touchIRMode = TouchIRMode.from(raw: DOLConfigBridge.mainTouchPadIRMode())
    #if os(iOS)
    touchOverlayProgrammatic = UserDefaults.standard.bool(forKey: "touch_overlay_programmatic")
    touchOverlayStyle = UserDefaults.standard.integer(forKey: "touch_overlay_style")
    touchOverlayIRPointerGain = Double(TouchOverlayIRGeometry.clampDragGain(MotionSettings.irPointerGain()))
    #endif
  }

  #if os(iOS)
  /// Pulses every connected controller's haptics and the device's, then reports what fired.
  private static func testRumble() {
    var controllersTestedCount = 0
    var deviceTested = false
    for controller in GCController.controllers() {
      guard let haptics = controller.haptics, let engine = haptics.createEngine(withLocality: .default) else { continue }
      do {
        try engine.start()
        let pattern = try CHHapticPattern(events: [
          CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.9),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8),
          ], relativeTime: 0),
        ], parameters: [])
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: 0)
        controllersTestedCount += 1
      } catch {}
    }
    if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
      do {
        let engine = try CHHapticEngine()
        try engine.start()
        let pattern = try CHHapticPattern(events: [
          CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0),
          ], relativeTime: 0),
        ], parameters: [])
        let player = try engine.makePlayer(with: pattern)
        try player.start(atTime: 0)
        deviceTested = true
      } catch {}
    }
    let message: String
    if controllersTestedCount > 0 && deviceTested {
      message = String(format: L("Tested %d controller(s) + device rumble"), controllersTestedCount)
    } else if controllersTestedCount > 0 {
      message = String(format: L("Tested %d controller(s) rumble"), controllersTestedCount)
    } else if deviceTested {
      message = L("Tested device rumble")
    } else {
      message = L("No haptic feedback available")
    }
    NotificationCenter.default.post(name: NSNotification.Name("DOLShowSnackbar"), object: nil, userInfo: ["text": message])
  }
  #endif
}
```

- [ ] **Step 4: Build and gate**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice. The new views have no callers until Task 6, and the build proves they compile on both platforms.

- [ ] **Step 5: Commit**

```bash
git add Source/iOS/App/Common/UI/Settings/SwiftUI/DSUSettingsView.swift \
  Source/iOS/App/Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift \
  Source/iOS/App/Common/UI/Settings/SwiftUI/ControllersRootView.swift \
  Source/iOS/App/DolphiniOS/UI/Emulation/TouchOverlay/TouchOverlayView.swift
git commit -m "refactor(settings): pushable DSU, More Controller Settings and editors"
```

---

### Task 6: ControllerHubViewModel and ControllerHubView

**Files:**
- Create: `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubViewModel.swift`
- Create: `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubView.swift`
- Create: `Source/iOS/App/DolphiniOSTests/ControllerHubViewModelTests.swift`
- Modify: `Source/iOS/App/Common/UI/Emulation/EmuEventVC.h`, `EmuEventVC.m` (declare `DOLOnScreenControlsChosenNotification`)

**Interfaces:**
- Consumes:
  - All of Task 4.
  - `RemapPlayerView(isGC:portOneBased:)`.
  - Task 5's `DSUSettingsView()`, `ControllerMoreSettingsView()` and `TouchOverlayLayoutEditorView()` (iOS).
  - `ControllerManager.assignmentsChanged`.
  - `TVControllerDevicesChangedNotification` (`TVControllerMappingBridge.h`, an `NSString*`).
- Produces:
  - `@MainActor protocol ControllerHubReading` (methods in Step 3) and `struct LiveControllerHubReader: ControllerHubReading`.
  - `@MainActor @Observable final class ControllerHubViewModel`, with:
    - `init(system: ControllerSetupSystem, reader: any ControllerHubReading = LiveControllerHubReader(), notificationCenter: NotificationCenter = .default)`
    - `private(set) var state: ControllerHubState`
    - `var actions: ControllerHubActions`
    - `func reload()`, `func start()` and `func stop()`
  - `struct ControllerHubView: View` with `init(system: ControllerSetupSystem, onBack: (() -> Void)? = nil, prepare: @escaping () -> Void = {})`.
  - `Notification.Name.DOLOnScreenControlsChosen`, posted before a hub choice changes the overlay. Task 7 observes it.

- [ ] **Step 1: Write the failing tests**

`Source/iOS/App/DolphiniOSTests/ControllerHubViewModelTests.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import XCTest

@testable import iCube

/// `ControllerHubViewModel` against a fake reader: which ports it reads in which order, and that
/// it reloads on assignment changes only while started. Observers deliver on the main queue, so
/// the notification tests wait on expectations instead of assuming inline delivery.
final class ControllerHubViewModelTests: XCTestCase {

  @MainActor
  private final class FakeReader: ControllerHubReading {
    var gameCube: [Int: String] = [:]
    var wii: [Int: String] = [:]
    var extensions: [Int: Int] = [:]
    var sideways: Set<Int> = []
    var pads: [ConnectedPadState] = []
    /// Counts snapshots: `reload()` asks for the pads exactly once.
    var padReads = 0
    var onPadRead: (() -> Void)?

    func boundQualifier(forGCPort port: Int) -> String { gameCube[port] ?? "" }
    func boundQualifier(forWiimote index: Int) -> String { wii[index] ?? "" }
    func wiiExtension(forWiimote index: Int) -> Int { extensions[index] ?? 0 }
    func isSideways(forWiimote index: Int) -> Bool { sideways.contains(index) }
    func connectedPads() -> [ConnectedPadState] {
      padReads += 1
      onPadRead?()
      return pads
    }
    func isGameRunning() -> Bool { true }
    func overlayVisible() -> Bool { true }
    func overlayMode() -> ControllerManager.OverlayMode { .wii }
    func overlayOpacity() -> Float { 0.62 }
    func continuousScanning() -> Bool { false }
    func dsuClientEnabled() -> Bool { true }
    func dsuServerCount() -> Int { 3 }
  }

  @MainActor
  func test_reload_readsEveryPortInTheSystemsOrder() {
    let reader = FakeReader()
    reader.wii[1] = "iOS/4/Touchscreen"
    reader.extensions[1] = 1
    reader.sideways = [2]
    reader.gameCube[2] = "MFi/0/Xbox Wireless Controller"
    let model = ControllerHubViewModel(system: .wiiAndGameCube, reader: reader, notificationCenter: NotificationCenter())

    model.reload()

    XCTAssertEqual(model.state.players.map(\.id), ["wii-1", "wii-2", "wii-3", "wii-4", "gc-1", "gc-2", "gc-3", "gc-4"])
    XCTAssertEqual(model.state.players[0].deviceQualifier, "iOS/4/Touchscreen")
    XCTAssertEqual(model.state.players[0].wiiExtension, 1)
    XCTAssertTrue(model.state.players[1].isSideways)
    XCTAssertEqual(model.state.players[5].deviceQualifier, "MFi/0/Xbox Wireless Controller")
    XCTAssertEqual(model.state.players[5].wiiExtension, 0, "GameCube ports carry no extension")
  }

  @MainActor
  func test_reload_snapshotsTheOverlayAndDevices() {
    let model = ControllerHubViewModel(system: .gamecube, reader: FakeReader(), notificationCenter: NotificationCenter())
    model.reload()
    XCTAssertTrue(model.state.isGameRunning)
    XCTAssertEqual(model.state.overlayMode, .wii)
    XCTAssertEqual(model.state.overlayOpacityPercent, 50, "0.62 snaps to 50 %")
    XCTAssertTrue(model.state.dsuClientEnabled)
    XCTAssertEqual(model.state.dsuServerCount, 3)
  }

  @MainActor
  func test_showAllPorts_survivesAReload() {
    let model = ControllerHubViewModel(system: .gamecube, reader: FakeReader(), notificationCenter: NotificationCenter())
    model.reload()
    model.actions.toggleShowAllPorts()
    model.reload()
    XCTAssertTrue(model.state.showAllPorts)
  }

  @MainActor
  func test_start_reloadsWhenAssignmentsChange() {
    let reader = FakeReader()
    let center = NotificationCenter()
    let model = ControllerHubViewModel(system: .gamecube, reader: reader, notificationCenter: center)
    model.start()
    XCTAssertEqual(reader.padReads, 1, "start() takes the first snapshot")

    let reloaded = expectation(description: "reloaded on assignmentsChanged")
    reader.onPadRead = { reloaded.fulfill() }
    center.post(name: ControllerManager.assignmentsChanged, object: nil)
    wait(for: [reloaded], timeout: 1)
    model.stop()
  }

  @MainActor
  func test_stop_removesTheObservers() {
    let reader = FakeReader()
    let center = NotificationCenter()
    let model = ControllerHubViewModel(system: .gamecube, reader: reader, notificationCenter: center)
    model.start()
    model.stop()

    let reloaded = expectation(description: "no reload after stop()")
    reloaded.isInverted = true
    reader.onPadRead = { reloaded.fulfill() }
    center.post(name: ControllerManager.assignmentsChanged, object: nil)
    wait(for: [reloaded], timeout: 0.3)
  }

  @MainActor
  func test_start_twice_installsOneSetOfObservers() {
    let reader = FakeReader()
    let center = NotificationCenter()
    let model = ControllerHubViewModel(system: .gamecube, reader: reader, notificationCenter: center)
    model.start()
    model.start()
    reader.padReads = 0

    center.post(name: ControllerManager.assignmentsChanged, object: nil)
    // Drain the main queue: delivery may be deferred, and a second observer would add a read.
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(reader.padReads, 1, "exactly one reload per notice")
    model.stop()
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/ControllerHubViewModelTests"`
Expected: build failure, `cannot find type 'ControllerHubReading' in scope`.

- [ ] **Step 3: Declare the notification**

In `Source/iOS/App/Common/UI/Emulation/EmuEventVC.h`, after the `DOLPointerModeDidChangeNotification` declaration:
```objc
/// Posted by the Controllers hub BEFORE it changes on-screen controls' visibility or style, so the
/// emulation screen stops re-deriving visibility from the touchscreen assignment, as it does for
/// the top bar's own buttons. It must precede the change: `overlayMode = .wii` posts
/// `ControllerAssignmentsChanged` synchronously.
FOUNDATION_EXPORT NSNotificationName const DOLOnScreenControlsChosenNotification;
```
In `EmuEventVC.m`, after the `DOLPointerModeDidChangeNotification` definition:
```objc
NSNotificationName const DOLOnScreenControlsChosenNotification = @"DOLOnScreenControlsChosen";
```

- [ ] **Step 4: Write the view model**

`Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubViewModel.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import CoreHaptics
import GameController
import Observation
import SwiftUI

/// Everything the hub reads, behind one seam, so `ControllerHubViewModel` is testable without the
/// core, the bridges or real pads.
@MainActor
protocol ControllerHubReading {
  /// The device bound to a GameCube port, or "" while the port is off.
  func boundQualifier(forGCPort port: Int) -> String
  /// The device bound to a Wii Remote slot, or "" while the slot is off.
  func boundQualifier(forWiimote index: Int) -> String
  func wiiExtension(forWiimote index: Int) -> Int
  func isSideways(forWiimote index: Int) -> Bool
  func connectedPads() -> [ConnectedPadState]
  func isGameRunning() -> Bool
  func overlayVisible() -> Bool
  func overlayMode() -> ControllerManager.OverlayMode
  /// 0…1.
  func overlayOpacity() -> Float
  func continuousScanning() -> Bool
  func dsuClientEnabled() -> Bool
  func dsuServerCount() -> Int
}

struct LiveControllerHubReader: ControllerHubReading {
  /// A port's stock default device is `iOS/0/Touchscreen` even while the port is off, so only an
  /// active port reports its device (the rule `ControllerSetupSections.reloadQualifiers` used).
  func boundQualifier(forGCPort port: Int) -> String {
    DOLConfigBridge.gcPortDevice(forPort: port) != 0 ? TVControllerMappingBridge.defaultDevice(forGCPort: port) as String : ""
  }

  func boundQualifier(forWiimote index: Int) -> String {
    DOLConfigBridge.wiimoteSource(for: index) != 0 ? TVControllerMappingBridge.defaultDevice(forWiimote: index) as String : ""
  }

  func wiiExtension(forWiimote index: Int) -> Int { WiimoteSlotOptions.selectedExtension(forWiimote: index) }
  func isSideways(forWiimote index: Int) -> Bool { WiimoteSlotOptions.isSideways(forWiimote: index) }

  func connectedPads() -> [ConnectedPadState] {
    GCController.controllers().map { controller in
      let battery = controller.battery
      let hasLevel = battery.map { $0.batteryLevel >= 0 && $0.batteryState != .unknown } ?? false
      return ConnectedPadState(
        qualifier: TVControllerMappingBridge.qualifiedName(for: controller) as String,
        name: controller.vendorName ?? controller.productCategory,
        batteryPercent: hasLevel ? battery.map { Int(($0.batteryLevel * 100).rounded()) } : nil,
        isCharging: battery?.batteryState == .charging,
        playerLabel: controller.playerIndex == .indexUnset ? nil : "P\(controller.playerIndex.rawValue + 1)")
    }
  }

  func isGameRunning() -> Bool { TVEmulationBridge.isRunning() }
  func overlayVisible() -> Bool { ControllerManager.shared.overlayVisible }
  func overlayMode() -> ControllerManager.OverlayMode { ControllerManager.shared.overlayMode }
  func overlayOpacity() -> Float { DOLConfigBridge.mainTouchPadOpacity() }
  func continuousScanning() -> Bool { DOLConfigBridge.wiimoteContinuousScanning() }
  func dsuClientEnabled() -> Bool { DOLConfigBridge.dsuClientEnabled() }
  func dsuServerCount() -> Int { DOLConfigBridge.dsuServersParsed()?.count ?? 0 }
}

/// The Controllers hub's state (controller hub spec, "Architecture"). The only hub unit that
/// touches `ControllerManager`, `TVControllerMappingBridge`, `DOLConfigBridge` and `GCController`.
///
/// `init` reads nothing and installs nothing: SwiftUI builds hosts eagerly (Settings builds every
/// destination on each render), so reads wait for `start()`.
@MainActor
@Observable
final class ControllerHubViewModel {
  let system: ControllerSetupSystem
  private(set) var state: ControllerHubState

  private let reader: any ControllerHubReading
  private let notificationCenter: NotificationCenter
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  /// Keeps each Identify haptic engine alive until its pulse ends.
  @ObservationIgnored private var identifyEngines: [CHHapticEngine] = []

  init(
    system: ControllerSetupSystem,
    reader: any ControllerHubReading = LiveControllerHubReader(),
    notificationCenter: NotificationCenter = .default
  ) {
    self.system = system
    self.reader = reader
    self.notificationCenter = notificationCenter
    self.state = .empty(system: system)
  }

  // MARK: Snapshot

  func reload() {
    let players = ControllerHubState.slots(for: system).map { slot -> PlayerState in
      switch slot.kind {
      case .gameCube:
        return PlayerState(
          kind: .gameCube, port: slot.port, deviceQualifier: reader.boundQualifier(forGCPort: slot.port),
          wiiExtension: 0, isSideways: false)
      case .wiiRemote:
        return PlayerState(
          kind: .wiiRemote, port: slot.port, deviceQualifier: reader.boundQualifier(forWiimote: slot.port),
          wiiExtension: reader.wiiExtension(forWiimote: slot.port), isSideways: reader.isSideways(forWiimote: slot.port))
      }
    }
    state = ControllerHubState(
      system: system,
      players: players,
      showAllPorts: state.showAllPorts,
      pads: reader.connectedPads(),
      isGameRunning: reader.isGameRunning(),
      overlayVisible: reader.overlayVisible(),
      overlayMode: reader.overlayMode(),
      overlayOpacityPercent: ControllerHubState.snappedOpacityPercent(reader.overlayOpacity()),
      continuousScanning: reader.continuousScanning(),
      dsuClientEnabled: reader.dsuClientEnabled(),
      dsuServerCount: reader.dsuServerCount())
  }

  /// Takes a snapshot and follows assignment and device changes until `stop()`. Idempotent.
  /// Observers deliver on the main queue: `TVControllerDevicesChangedNotification` can be posted
  /// off-main by `TVControllerMappingBridge`.
  func start() {
    reload()
    guard observers.isEmpty else { return }
    let names: [Notification.Name] = [
      ControllerManager.assignmentsChanged,
      .GCControllerDidConnect,
      .GCControllerDidDisconnect,
      Notification.Name(TVControllerDevicesChangedNotification),
    ]
    observers = names.map { name in
      notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.reload() }
      }
    }
  }

  func stop() {
    observers.forEach { notificationCenter.removeObserver($0) }
    observers.removeAll()
  }

  // MARK: Actions

  /// Every setter ends by reloading (or by changing `state` directly), because the builder's
  /// bindings read the snapshot: a setter that only wrote a bridge would snap its row back.
  var actions: ControllerHubActions {
    ControllerHubActions(
      playerDestination: { player in
        AnyView(RemapPlayerView(isGC: player.kind == .gameCube, portOneBased: player.port))
      },
      toggleShowAllPorts: { [weak self] in
        self?.state.showAllPorts.toggle()
      },
      setOverlayVisible: { [weak self] visible in
        self?.chooseOnScreenControls { ControllerManager.shared.overlayVisible = visible }
      },
      setOverlayMode: { [weak self] mode in
        self?.chooseOnScreenControls {
          ControllerManager.shared.overlayMode = mode
          // The top bar's rule: picking a specific style also shows the controls.
          if mode != .auto { ControllerManager.shared.overlayVisible = true }
        }
      },
      setOverlayOpacity: { [weak self] opacity in
        DOLConfigBridge.setMainTouchPadOpacity(opacity)
        self?.reload()
      },
      editLayoutDestination: {
        #if os(iOS)
        AnyView(TouchOverlayLayoutEditorView())
        #else
        AnyView(EmptyView())
        #endif
      },
      identifyPad: { [weak self] qualifier in
        self?.identify(qualifier: qualifier)
      },
      setContinuousScanning: { [weak self] enabled in
        DOLConfigBridge.setWiimoteContinuousScanning(enabled)
        self?.reload()
      },
      dsuDestination: { AnyView(DSUSettingsView()) },
      moreSettingsDestination: { AnyView(ControllerMoreSettingsView()) })
  }

  /// Announces the choice BEFORE applying it: `overlayMode = .wii` posts `assignmentsChanged`
  /// synchronously, and the emulation screen re-derives visibility on that notice unless it
  /// already knows the player chose.
  private func chooseOnScreenControls(_ apply: () -> Void) {
    notificationCenter.post(name: .DOLOnScreenControlsChosen, object: nil)
    apply()
    reload()
  }

  // MARK: Identify

  /// Makes one pad visibly and physically react (LED blink, short rumble) so the player can tell
  /// which row is which pad.
  private func identify(qualifier: String) {
    guard let controller = GCController.controllers().first(where: {
      (TVControllerMappingBridge.qualifiedName(for: $0) as String) == qualifier
    }) else { return }
    if let light = controller.light {
      let original = light.color
      for step in 0 ..< 6 {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.15) {
          light.color = step % 2 == 0 ? GCColor(red: 1, green: 1, blue: 1) : original
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { light.color = original }
    }
    if let haptics = controller.haptics {
      playIdentifyPulse(haptics)
    }
  }

  private func playIdentifyPulse(_ haptics: GCDeviceHaptics) {
    guard let engine = haptics.createEngine(withLocality: .default) else { return }
    do {
      try engine.start()
      let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
      let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
      let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [intensity, sharpness], relativeTime: 0, duration: 0.6)
      let pattern = try CHHapticPattern(events: [event], parameters: [])
      let player = try engine.makePlayer(with: pattern)
      try player.start(atTime: 0)
      identifyEngines.append(engine)
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(1))
        try? player.stop(atTime: 0)
        engine.stop(completionHandler: nil)
        self?.identifyEngines.removeAll { $0 === engine }
      }
    } catch {}
  }
}
```

- [ ] **Step 5: Write the host view**

`Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubView.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import SwiftUI

/// The Controllers hub: the same screen from the pause menu, Settings and the top bar. The host
/// supplies the `NavigationStack`: every row below pushes into it.
///
/// Its state lives in a `@State` view model owned by this view, a real node in every host. No
/// presentation is attached inside the list, so nothing waits on a lazily built row (the old
/// "Profiles… only opens after a scroll" lockup).
@MainActor
struct ControllerHubView: View {
  private let onBack: (() -> Void)?
  private let prepare: () -> Void

  @State private var viewModel: ControllerHubViewModel
  @Environment(\.dismiss) private var dismiss

  /// - Parameters:
  ///   - onBack: B (iOS) / Menu (tvOS) at the hub's root. nil pops or dismisses the hub. A host
  ///     that shows the hub as a pane rather than a push or sheet (the tvOS pause menu) must pass it.
  ///     `MenuScreen` handles tvOS Menu itself, so a nil handler would otherwise swallow it.
  ///   - prepare: runs on every appear, before the first read (Settings uses it to turn Player 1 on).
  init(system: ControllerSetupSystem, onBack: (() -> Void)? = nil, prepare: @escaping () -> Void = {}) {
    self.onBack = onBack
    self.prepare = prepare
    _viewModel = State(initialValue: ControllerHubViewModel(system: system))
  }

  var body: some View {
    MenuScreen(
      model: ControllerHubModelBuilder.make(state: viewModel.state, actions: viewModel.actions, platform: .current),
      style: .list,
      onBack: onBack ?? { dismiss() }
    )
    .navigationTitle(L("Controllers"))
    // A pushed player screen covers this one: stop on disappear, reload on the way back.
    .onAppear {
      prepare()
      viewModel.start()
    }
    .onDisappear { viewModel.stop() }
  }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/ControllerHubViewModelTests"`
Expected: `Executed 6 tests, with 0 failures`.

- [ ] **Step 7: Run the full gates**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice.

- [ ] **Step 8: Commit**

```bash
git add Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubViewModel.swift \
  Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubView.swift \
  Source/iOS/App/DolphiniOSTests/ControllerHubViewModelTests.swift \
  Source/iOS/App/Common/UI/Emulation/EmuEventVC.h Source/iOS/App/Common/UI/Emulation/EmuEventVC.m
git commit -m "feat(controllers): ControllerHubViewModel and the hub view"
```

---

### Task 7: The hub in the pause menu and the top bar

**Files:**
- Modify: `Source/iOS/App/Common/Swift/PauseMenuView.swift`: the tvOS `.controllers` pane (~170-178 after Task 4) and the iOS `showControllersSheet` sheet (~272-278 after Task 4)
- Modify: `Source/iOS/App/Common/Swift/EmulationScreen.swift`:
  - the `showControllerSettings` sheet (~1337-1345)
  - the top-bar "gamecontroller" menu's On-Screen Style submenu (~1431-1462)
  - the `.DOLPointerModeDidChange` receiver (~1280)

**Interfaces:**
- Consumes: `ControllerHubView(system:onBack:prepare:)`, `ControllerSetupSystem.forRunningGame` and `.DOLOnScreenControlsChosen` (Task 6).
- Produces: nothing new. After this task, `ControllerSetupView(` is referenced only by `ControllersRootView` (Task 8).

- [ ] **Step 1: tvOS pause pane**

In `PauseMenuView.swift`, replace
```swift
      #if os(tvOS)
      case .controllers:
        NavigationStack {
          ControllerSetupView(system: .forRunningGame)
            .toolbar {
              ToolbarItem(placement: .navigationBarLeading) { Button(L("Back")) { pane = .main } }
            }
        }
        .onExitCommand { pane = .main }
        .onAppear { NSLog("[PAUSE] Controller setup menu appeared") }
```
with
```swift
      #if os(tvOS)
      case .controllers:
        // Menu at the hub's root returns to the pause menu (`onBack`, through MenuScreen's own
        // `.onExitCommand`); Menu on a pushed player screen pops just that screen.
        NavigationStack {
          ControllerHubView(system: .forRunningGame, onBack: { pane = .main })
        }
        .onAppear { NSLog("[PAUSE] Controllers hub appeared") }
```

- [ ] **Step 2: iOS pause sheet**

In `PauseMenuView.swift`, replace
```swift
    .sheet(isPresented: $showControllersSheet) {
      NavigationStack {
        ControllerSetupView(system: .forRunningGame)
          .navigationTitle(L("Controllers"))
          .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Close")) { showControllersSheet = false } } }
      }
      .claimsController()
    }
```
with
```swift
    .sheet(isPresented: $showControllersSheet) {
      NavigationStack {
        ControllerHubView(system: .forRunningGame, onBack: { showControllersSheet = false })
          .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button(L("Close")) { showControllersSheet = false } } }
      }
      .claimsController()
    }
```

- [ ] **Step 3: Top-bar sheet**

In `EmulationScreen.swift`, replace
```swift
    .sheet(isPresented: $showControllerSettings, onDismiss: TVEmulationBridge.resume) {
      NavigationStack {
        ControllerSetupView(system: .forRunningGame)
          .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { showControllerSettings = false } }
          }
      }
      .claimsController()
    }
```
with
```swift
    .sheet(isPresented: $showControllerSettings, onDismiss: TVEmulationBridge.resume) {
      NavigationStack {
        ControllerHubView(system: .forRunningGame, onBack: { showControllerSettings = false })
          .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { showControllerSettings = false } }
          }
      }
      .claimsController()
    }
```

- [ ] **Step 4: Move On-Screen Style out of the top bar**

In the top bar's "gamecontroller" `Menu { … }`, delete the whole On-Screen Style submenu: from the `Menu {` whose first button sets `controllerManager.overlayMode = .auto` through
```swift
              } label: {
                Label(L("On-Screen Style"), systemImage: "rectangle.3.group")
              }
```
inclusive. The hub's On-Screen Controls → On-Screen Style replaces it.

The menu then reads: Pointer ▸ and Recenter Pointer (Wii only), Show/Hide On‑Screen Controller, `Divider()`, Controller Settings….

Check: `git grep -n "On-Screen Style\|overlayMode = \." -- Source/iOS/App/Common/Swift/EmulationScreen.swift` prints nothing.

- [ ] **Step 5: Follow the hub's on-screen choices**

In `EmulationScreen.swift`, directly after
```swift
    .onReceive(NotificationCenter.default.publisher(for: .DOLPointerModeDidChange)) { _ in
      irModeRaw = PointerModeController.shared.mode.rawValue
    }
```
add
```swift
    // The hub chose on-screen visibility or style: treat it as the top bar's own buttons do, so the
    // assignmentsChanged observer stops re-deriving visibility. Posted before the change is applied.
    .onReceive(NotificationCenter.default.publisher(for: .DOLOnScreenControlsChosen)) { _ in
      userOverrideTouchControls = true
      touchPadsRefreshToken = UUID()
    }
```

- [ ] **Step 6: Check the remaining references**

Run: `git grep -n "ControllerSetupView(" -- 'Source/iOS/App/*.swift'`
Expected: only `ControllersRootView.swift` (the `.sections` embed) and `ControllerSetupView.swift` itself.

- [ ] **Step 7: Run the full gates**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice. The tvOS pause pane is compiled only by the tvOS half of the gate.

- [ ] **Step 8: Commit**

```bash
git add Source/iOS/App/Common/Swift/PauseMenuView.swift Source/iOS/App/Common/Swift/EmulationScreen.swift
git commit -m "feat(controllers): the hub from the pause menu and the top bar"
```

---

### Task 8: The hub in Settings → Controllers

**Files:**
- Modify: `Source/iOS/App/Common/UI/Settings/SwiftUI/ControllersRootView.swift`: replace `struct ControllersRootView` (from the `// Convenience initializer for no background` comment, ~100, up to but not including `enum TouchIRMode`)
- Modify: `Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubState.swift` (add `forSettings`)
- Modify: `Source/iOS/App/Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift` (take over `ControllerSetupSections`' General and Wii global rows, and LED colours)
- Modify: `Source/iOS/App/DolphiniOSTests/ControllerHubModelBuilderTests.swift` (one test)
- Modify: `Source/iOS/App/Common/UI/Settings/SwiftUI/SettingsRootView.swift:93-95`, `:371-375` (the DSU deep link lands on the server list)

**Interfaces:**
- Consumes: `ControllerHubView` (Task 6), `ControllerMoreSettingsView` and `DSUSettingsView` (Task 5).
- Produces: `static var ControllerSetupSystem.forSettings: ControllerSetupSystem`. After this task `ControllerSetupView` has no callers; Phase 4 deletes it.

- [ ] **Step 1: Write the failing test**

Append inside `ControllerHubModelBuilderTests`:
```swift
  /// Settings with no game running lists every GameCube port and Wii Remote, GameCube first.
  func test_settingsWithoutAGame_listsBothSystems() {
    XCTAssertEqual(ControllerSetupSystem.forSettings, .both, "the test host runs no game")
  }
```
Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/ControllerHubModelBuilderTests"`
Expected: build failure, `type 'ControllerSetupSystem' has no member 'forSettings'`.

- [ ] **Step 2: Add `forSettings`**

In `ControllerHubState.swift`, inside `extension ControllerSetupSystem`, after `forRunningGame`:
```swift
  /// Settings → Controllers: the running game's ports while one runs (Settings opened from the pause
  /// menu, so it matches the pause menu's hub), otherwise every GameCube port and Wii Remote.
  static var forSettings: ControllerSetupSystem {
    TVEmulationBridge.isRunning() ? forRunningGame : .both
  }
```
Run the same test command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Replace ControllersRootView with the hub host**

In `ControllersRootView.swift`, replace everything from the line `// Convenience initializer for no background` through the closing `}` of `struct ControllersRootView` (the line before `enum TouchIRMode: Int, CaseIterable`) with:
```swift
// MARK: - Controllers (Settings → Controllers)

/// Settings → Controllers is the Controllers hub, the same screen the pause menu and the top bar
/// open (controller hub spec, Phase 2). What the hub does not cover is behind its "More Controller
/// Settings" row (`ControllerMoreSettingsView`) and "Motion Source (DSU)" row (`DSUSettingsView`).
struct ControllersRootView: View {
  var body: some View {
    ControllerHubView(system: .forSettings, prepare: Self.ensureDefaultGCPlayer1)
  }

  /// If every GameCube port is off, turns Player 1 on as a GameCube Controller (raw
  /// `SIDEVICE_GC_CONTROLLER` is 6; the SI_Device.h enum is not sequential), as this screen always
  /// did on appear. Runs before the hub's first read, so the Player 1 row shows at once.
  private static func ensureDefaultGCPlayer1() {
    guard (1 ... 4).allSatisfy({ DOLConfigBridge.gcPortDevice(forPort: $0) == 0 }) else { return }
    DOLConfigBridge.setGCPortDeviceForPort(1, device: 6)
  }
}
```
This removes the old DSU sections, the Add Server sheet, the General / Wii Remotes / Alternate Input Sources sections, `syncFromConfig`, `syncPortTypes`, `testRumble` and the unused `localizedSIDevice`, `localizedWiimoteSource`, `mfiControllerTitle` and `mfiControllerDetail`. Tasks 5 and 6 moved each one or replaced it. Keep `AnalogStickSettingsView`, `TouchIRMode`, `TouchIRModePicker`, `TouchOverlayLayoutEditorView` and `TouchOverlayIRAreaEditorView`.

- [ ] **Step 4: Move ControllerSetupSections' global rows into More**

`ControllerSetupSections` (Settings' old player list) was the only home of these rows, and it has no callers now. In `ControllerMoreSettingsView.swift`:
1. Add these properties after `@State private var touchIRMode …`:
   ```swift
   @AppStorage("virtual_mfi_connect") private var mfiConnect = false
   /// Rumble destination, honored by the core rumble path (`Motor`): 0 device haptics, 1 controller,
   /// 2 both. tvOS has no device to hold, so the option is hidden there.
   @AppStorage("rumble_destination") private var rumbleDestination = 1
   @State private var backgroundInput = false
   @State private var wiimoteSpeaker = false
   #if os(iOS)
   /// Connected pads with a light bar, for the LED colour rows.
   @State private var litControllers: [GCController] = []
   #endif
   ```
2. At the top of the "General" section, before the auto-select `settingsCaption`, add:
   ```swift
        Toggle(L("Connect MFi Controllers"), isOn: $mfiConnect)
        Toggle(L("Background Input"), isOn: $backgroundInput)
          .onChange(of: backgroundInput) { _, enabled in DOLConfigBridge.setMainBackgroundInput(enabled) }
        #if os(iOS)
        Picker(L("Rumble Output"), selection: $rumbleDestination) {
          Text(L("Device Haptics")).tag(0)
          Text(L("Controller")).tag(1)
          Text(L("Both")).tag(2)
        }
        #endif
   ```
3. At the top of the "Wii Remotes" section, add:
   ```swift
        Toggle(L("Enable Speaker"), isOn: $wiimoteSpeaker)
          .onChange(of: wiimoteSpeaker) { _, enabled in DOLConfigBridge.setWiimoteEnableSpeaker(enabled) }
   ```
4. After the "Alternate Input Sources" section, still inside the `List`, add:
   ```swift
      #if os(iOS)
      if !litControllers.isEmpty {
        Section(header: Text(L("Controller Lights"))) {
          ForEach(Array(litControllers.enumerated()), id: \.offset) { _, controller in
            if let light = controller.light {
              ColorPicker(controller.vendorName ?? controller.productCategory, selection: ledBinding(for: light))
            }
          }
        }
      }
      #endif
   ```
5. After `.onAppear { syncFromConfig() }`, add:
   ```swift
    #if os(iOS)
    .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in reloadLitControllers() }
    .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in reloadLitControllers() }
    #endif
   ```
6. At the end of `syncFromConfig()`, add:
   ```swift
    backgroundInput = DOLConfigBridge.mainBackgroundInput()
    wiimoteSpeaker = DOLConfigBridge.wiimoteEnableSpeaker()
    #if os(iOS)
    reloadLitControllers()
    #endif
   ```
7. Inside the existing `#if os(iOS)` block at the bottom of the struct (next to `testRumble`), add:
   ```swift
  private func reloadLitControllers() {
    litControllers = GCController.controllers().filter { $0.light != nil }
  }

  /// Two-way bridge between SwiftUI's `Color` and a controller's `GCDeviceLight`.
  private func ledBinding(for light: GCDeviceLight) -> Binding<Color> {
    Binding(
      get: { Color(red: Double(light.color.red), green: Double(light.color.green), blue: Double(light.color.blue)) },
      set: { newColor in
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(newColor).getRed(&r, green: &g, blue: &b, alpha: &a)
        light.color = GCColor(red: Float(r), green: Float(g), blue: Float(b))
      })
  }
   ```

- [ ] **Step 5: Keep the DSU deep link landing on the server list**

`URLRouterService` (`dolphinios://dsu/add`, legacy `dsu://`) adds a server, then posts `DOLShowSettings` and `DOLSettingsSelectControllers`. `SettingsRootView` answers with `.navigationDestination(isPresented: $jumpToControllersRequested) { ControllersRootView() }`. Until now that page listed the new server. After Step 3 it is the hub, one level above the list. In `SettingsRootView.swift`:
1. Replace
   ```swift
      // DSU-add deep link (dolphinios://dsu/add, legacy dsu://) jumps straight here
      // instead of leaving the user to find Controllers in the flattened list.
      .navigationDestination(isPresented: $jumpToControllersRequested) {
        ControllersRootView()
      }
   ```
   with
   ```swift
      // DSU-add deep link (dolphinios://dsu/add, legacy dsu://) opens the DSU server list, where the
      // server it just added shows. That list used to be part of Settings → Controllers.
      .navigationDestination(isPresented: $jumpToControllersRequested) {
        DSUSettingsView()
      }
   ```
2. In the doc comment on `jumpToControllersRequested` (~93-95), change "so Settings opens straight into Controllers" to "so Settings opens straight into the DSU server list (`DSUSettingsView`)".

- [ ] **Step 6: Check nothing still embeds the old screen**

Run: `git grep -n "ControllerSetupView(\|ControllerSetupSections(" -- 'Source/iOS/App/*.swift'`
Expected: only `Common/Swift/Controllers/ControllerSetupView.swift` (its own `sections` property). Phase 4 deletes the file.

- [ ] **Step 7: Run the full gates**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice.

- [ ] **Step 8: Commit**

```bash
git add Source/iOS/App/Common/UI/Settings/SwiftUI/ControllersRootView.swift \
  Source/iOS/App/Common/UI/Settings/SwiftUI/SettingsRootView.swift \
  Source/iOS/App/Common/Swift/Controllers/Hub/ControllerHubState.swift \
  Source/iOS/App/Common/UI/Settings/SwiftUI/ControllerMoreSettingsView.swift \
  Source/iOS/App/DolphiniOSTests/ControllerHubModelBuilderTests.swift
git commit -m "feat(settings): Settings → Controllers is the Controllers hub"
```

---

### Task 9: Localize the Phase 1 and Phase 2 strings

`L()` reads the `Core` table (`Common/Swift/Localized.swift`). The "Update Core Strings" build pre-script (`Project.swift`, `Project/Scripts/UpdateCoreStrings.py`) merges `Languages/po/<lang>.po` into `<lang>.lproj/Core.strings`, and it preserves keys the `.po` does not have. App-only strings are therefore added as identity entries. `Project/Scripts/check_localized_keys.py` is the audit. Japanese entries stay English until translated.

**Files:**
- Modify: `Source/iOS/App/Common/UI/Localization/en.lproj/Core.strings`
- Modify: `Source/iOS/App/Common/UI/Localization/ja.lproj/Core.strings`

**Interfaces:**
- Consumes: every `L("…")` key added by Phase 1 and Tasks 1–8.
- Produces: `python3 Source/iOS/App/Project/Scripts/check_localized_keys.py --check` exits 0.

- [ ] **Step 1: See what is missing**

Run: `python3 Source/iOS/App/Project/Scripts/check_localized_keys.py`
Expected: a "Missing from en.lproj/Core.strings" list. On develop before this phase it held the 16 Phase 1 keys below. After Tasks 1–8 it also holds the Phase 2 keys below. If it lists a key not in these two blocks, add that key too; if a key below is not listed, skip it.

- [ ] **Step 2: Append the identity entries to both tables**

Append these lines to the end of `en.lproj/Core.strings` AND of `ja.lproj/Core.strings`, with no comments (the pre-script strips comments, so the committed form has none). `…`, `–`, `−`, `≡`, `·` and the arrows are literal UTF-8 characters, as in the Swift source.

Phase 1:
```
"Center the Wii pointer on how you hold the device" = "Center the Wii pointer on how you hold the device";
"Controller Settings…" = "Controller Settings…";
"D-Pad ←" = "D-Pad ←";
"D-Pad ↑" = "D-Pad ↑";
"D-Pad →" = "D-Pad →";
"D-Pad ↓" = "D-Pad ↓";
"Home" = "Home";
"Left Stick Click" = "Left Stick Click";
"On-Screen Style" = "On-Screen Style";
"On-screen %@" = "On-screen %@";
"Pointer" = "Pointer";
"Recenter Pointer" = "Recenter Pointer";
"Right Stick Click" = "Right Stick Click";
"Touch – Drag" = "Touch – Drag";
"Touch – Follow" = "Touch – Follow";
"≡ Menu" = "≡ Menu";
```
Phase 2:
```
"%@ (Disconnected)" = "%@ (Disconnected)";
"%d found" = "%d found";
"Add DSU Server" = "Add DSU Server";
"Battery %d%%" = "Battery %d%%";
"Battery %d%% · Charging" = "Battery %d%% · Charging";
"Connected Devices" = "Connected Devices";
"Continuous Wii Remote Scanning" = "Continuous Wii Remote Scanning";
"Controller Lights" = "Controller Lights";
"Exit to Library" = "Exit to Library";
"Fast-forward" = "Fast-forward";
"Hide Unused Ports" = "Hide Unused Ports";
"Hold all four shoulder buttons" = "Hold all four shoulder buttons";
"Hold all four shoulder buttons, then press Menu" = "Hold all four shoulder buttons, then press Menu";
"Hold Back / Menu for %d s" = "Hold Back / Menu for %d s";
"Menu / Options / + button" = "Menu / Options / + button";
"More Controller Settings" = "More Controller Settings";
"Motion Source (DSU)" = "Motion Source (DSU)";
"No Device" = "No Device";
"On · %d servers" = "On · %d servers";
"On-Screen Controls" = "On-Screen Controls";
"Pause on any pad" = "Pause on any pad";
"Pause with the Siri Remote" = "Pause with the Siri Remote";
"Press Back / Menu" = "Press Back / Menu";
"Show All Ports" = "Show All Ports";
"Show On-Screen Controls" = "Show On-Screen Controls";
"Start / +" = "Start / +";
"View / Share / − button, or Home on Xbox and PlayStation pads" = "View / Share / − button, or Home on Xbox and PlayStation pads";
"Wii Remote + Classic Controller" = "Wii Remote + Classic Controller";
"Wii Remote + Nunchuk" = "Wii Remote + Nunchuk";
```
Before appending a key, check it is not already present, so no key is defined twice: `grep -c '^"<key>" = ' Source/iOS/App/Common/UI/Localization/en.lproj/Core.strings` must print `0`. A `.po` refresh may already have added some of these.

- [ ] **Step 3: Verify**

Run: `python3 Source/iOS/App/Project/Scripts/check_localized_keys.py --check; echo "exit $?"`
Expected: `Missing keys: 0` and `exit 0`.
Run: `plutil -lint Source/iOS/App/Common/UI/Localization/en.lproj/Core.strings Source/iOS/App/Common/UI/Localization/ja.lproj/Core.strings`
Expected: both `OK`.

- [ ] **Step 4: Build once, so the pre-script's merge is what you commit**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice. Then `git diff --stat -- Source/iOS/App/Common/UI/Localization` shows only the appended lines. Re-run Step 3 if the pre-script rewrote either file.

- [ ] **Step 5: Commit**

```bash
git add Source/iOS/App/Common/UI/Localization/en.lproj/Core.strings Source/iOS/App/Common/UI/Localization/ja.lproj/Core.strings
git commit -m "chore(l10n): catalogue the controller hub strings"
```

---

### Task 10: Device checklist and handoff

**Files:**
- Create: `docs/handoff-2026-09-28-controller-hub-phase2.md`

- [ ] **Step 1: Write the handoff**

```markdown
# Controller Hub Phase 2 — handoff (2026-09-28)

Plan: docs/superpowers/plans/2026-09-28-controller-hub-phase2-hub.md
Spec: docs/superpowers/specs/2026-09-28-controller-hub-design.md

## Landed
<one line per task commit: SHA + subject, from `git log --oneline -9`>

## Decisions worth knowing
- `dsu_role` is registered as "sender", what TVLibraryView's "Start DSU Controller" already acted on.
  The DSU client lock is iOS-only. On iOS, a user who enabled the client under the old "receiver"
  display default sees it ON but locked until they pick Receiver.
- Settings-only leftovers live behind the hub's "More Controller Settings" row.
- Show/Hide On-Screen Controls appears only in a game. On-Screen Style lasts for the session.

## Device checklist

iPhone 16 Pro Max, with an Xbox or DualSense pad and a Wii title with the touch overlay:
1. The pause menu's Controllers, the top bar's Controller Settings… and Settings → Controllers all show
   the same hub:
   - Players, On-Screen Controls, Connected Devices, More Controller Settings, Help.
   - Unbound ports are under "Show All Ports".
2. With the pad, move to a player row and press A: RemapPlayerView is pushed. B returns to the hub.
   B again closes the hub. Back from any depth returns one level.
3. Nothing needs a scroll to open: Edit Layout…, a player row near the bottom, More, and
   Motion Source (DSU) → Add Server all push at once from a fresh, unscrolled hub.
4. In game, hub → Show On-Screen Controls off. Disconnect and reconnect the pad. The overlay stays
   hidden, because the hub choice is not re-derived.
5. Hub → On-Screen Style: Wii, then GameCube. The overlay follows each time. D-pad left/right on the
   focused Style and Opacity rows changes them one step per press. This retires Phase 1 checklist
   item 6.
6. The top bar's controller menu has no On-Screen Style. It has Pointer, Recenter Pointer, Show/Hide
   and Controller Settings….
7. A Connected Devices row shows battery % and "P1". Tapping it flashes and rumbles that pad.
8. Per-game pointer mode: set a game profile's Touch IR mode to Gyro, then boot the title. The live pad
   is in Gyro without opening any menu.
9. Settings → Controllers → Motion Source (DSU) → Add Server is a pushed page. Back cancels it; Add
   saves. Opening `dolphinios://dsu/add?...` from Safari lands on the DSU server list, showing the
   new server.

Apple TV, with a Siri Remote and a pad, on a Wii title:
10. The pause menu's Controllers pane shows the hub.
    - Focus reaches every row, down to the last Help line.
    - Menu at the hub root returns to the pause menu.
    - Menu on a pushed player screen pops only it.
11. Settings → Controllers is the same hub. Menu pops back to Settings.
12. Motion Source (DSU): "Enable DSU Client" is focusable and toggles. It is not greyed out.
13. Continuous Wii Remote Scanning toggles and shows its checkmark.

## Next
Phase 3: the player screen (PlayerScreenModelBuilder), which replaces RemapPlayerView behind each
player row. It covers device, profile (Save As… through MenuModal), Wii rows, capture rows, Pointer &
Motion and Advanced.
Phase 4 deletes ControllerSetupView.swift (no callers since Task 8) and the More rows the player
screen replaces.
```
Fill in the "Landed" lines from `git log --oneline -9`.

- [ ] **Step 2: Commit**

```bash
git add docs/handoff-2026-09-28-controller-hub-phase2.md
git commit -m "docs: controller hub phase 2 handoff and device checklist"
```

---

## Self-review against the spec

| Spec requirement (Phase 2 scope) | Where |
|---|---|
| `ControllerHubViewModel`, `@Observable`, the only unit touching `ControllerManager` / `TVControllerMappingBridge` / `DOLConfigBridge` / `GCController`; rebuilds on `assignmentsChanged` and connect/disconnect | Task 6 |
| `ControllerHubState` / `PlayerState` snapshots | Task 4 |
| `ControllerHubModelBuilder`, pure; `.navigation`/`.destination` push, `.picker`, `.toggle` | Task 4 (the hub's pushes are to non-menu screens, so `.destination`) |
| Players: one row per port with port · device · emulated controller; Wii titles list Wii Remotes then GC ports; unbound under "Show all ports" | Task 4 |
| On-Screen Controls (iOS only): show/hide, edit layout (existing editor), opacity | Tasks 4, 5, 6 |
| Connected Devices: battery, continuous Wii Remote scanning, DSU motion source | Tasks 4, 5, 6 |
| Help from the pause routing table | Task 4 (`ControllerHelp`) |
| Presentation: sheet from pause menu and top bar, push from Settings; tvOS pushed from the pause pane and Settings | Tasks 7, 8 |
| Everything below the hub is a push; no sheet inside a List/Section or inside another sheet | Tasks 3, 5, 6 (and the lockup note) |
| Top bar: nothing controller-related beyond pointer, recenter, show/hide, Controller Settings… | Task 7 |
| tvOS: no Touchscreen option / Pointer & Motion / On-Screen Controls; every row one focus target | Task 4 (platform branch), Help rows enabled |
| GameCube title: only GameCube ports, no Wii sections | Task 4 (`slots`, `showsWii` gate) |
| Tests: builder rows per system, collapsing, platform differences; existing tests green; `make test` + `make gate-release` each task | Tasks 4, 6 and every task's gate step |
| Device checklist per phase (iPhone 16 Pro Max + Apple TV) | Task 10 |

Owed items from the Phase 1 handoff, all covered:
1. The hub: Tasks 4–8.
2. Player rows push `RemapPlayerView`: Task 6 (`playerDestination`).
3. Three entry points and the lockup's root cause: Tasks 7–8, and the lockup note under Decisions.
4. On-Screen Style leaves the top bar: Task 7.
5. `GameProfiles` routing: Task 1.
6. `@MainActor` on `PointerModeController`: Task 1.
7. The DSU default: Task 2.
8. Localization: Task 9.

Out of this phase by the spec: the player screen, `PlayerScreenModelBuilder`, capture rows, Pointer & Motion, Advanced and Save Profile As… (Phase 3). Deleting `ControllerSetupView`, `EnhancedMotionControlsView` and the extra pointer pickers is Phase 4.
