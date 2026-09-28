# Controller Hub — Phase 1: Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the shared building blocks the Controller Hub needs, and ship the slim in-game top bar:
- one motion-settings store with launch-registered defaults
- one pointer-mode setter
- friendly binding names
- d-pad left/right on menu picker rows

**Architecture:** Small, pure, unit-tested units, each adopted by the existing screens right away, so this phase is useful on its own and Phases 2–4 (hub, player screen, removal) build on stable APIs. No core (C++) changes.

**Tech Stack:** Swift 5 mode, SwiftUI, XCTest (`@testable import iCube`), Tuist-generated project, iOS 17+ / tvOS 17+.

**Spec:** `docs/superpowers/specs/2026-09-28-controller-hub-design.md` (read it first; this plan implements its "Delivery phases → 1. Foundation").

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

## Decisions made while planning (differences from the spec)

- **No "Off" pointer mode.** `MAIN_TOUCH_PAD_IR_MODE` has only 0 = Gyro, 1 = Touch-Follow, 2 = Touch-Drag, and there is no off value in the core. `PointerMode` has three cases.
- **Scroll-to-focus is already done for `.list`.** `MenuScreen.listBody` uses a `ScrollViewReader` and scrolls on focus change. Only `.grid` lacks it, and the hub uses `.list`, so it is not in this phase.
- **Registered defaults match what the app does today, not what the settings screens displayed:**
  - `motion_enable_full_6dof` and `motion_wiimote_imu_enabled`: the screens showed `true`, the runtime read `false`. Registered as `false`.
  - `motion_enhanced_shake_detection`: `setupEnhancedMotionControls()` forced it to `true` on every setup. Registered as `true`, and the force is removed so a user's "off" finally sticks.
- **DSU defaults stay out of this phase.** `dsu_role` defaults to `"receiver"` in `ControllersRootView` but `"sender"` in `TVLibraryView`. Which is correct is a product decision for the hub's Connected Devices section (Phase 2).
- **The sheet lockup is fixed in Phase 2.** The top bar's new "Controller Settings…" opens the same `ControllerSetupView` the pause menu opens, so it has the Profiles/Customize Buttons lockup until Phase 2 replaces that view.
- **Overlay style stays in the top bar for now.** The Auto / GameCube / Wii overlay-style choice stays in the top bar's controller menu until Phase 2 moves it to the hub's On-Screen Controls section, so nothing disappears mid-migration.

## File Structure

| File | Responsibility |
|---|---|
| Create `Source/iOS/App/Common/Swift/Controllers/MotionSettings.swift` | Motion `UserDefaults` keys, their registered defaults, typed accessors |
| Create `Source/iOS/App/Common/Swift/Controllers/PointerModeController.swift` | `PointerMode` enum + the one setter for `MAIN_TOUCH_PAD_IR_MODE` |
| Create `Source/iOS/App/Common/Swift/Controllers/BindingDisplay.swift` | Dolphin expression + device family → display text |
| Modify `Source/iOS/App/Common/UI/Emulation/EmuEventVC.h` / `.m` | Declare `DOLPointerModeDidChangeNotification` |
| Modify `Source/iOS/App/Common/AppDelegate.swift` | Register motion defaults on every launch |
| Modify `Source/iOS/App/DolphiniOS/UI/Emulation/TouchController/TCDeviceMotion.swift` | Read motion keys through `MotionSettings` |
| Modify `Source/iOS/App/Common/Swift/EmulationScreen+TouchAndMotion.swift` | Drop the forced shake default |
| Modify `Source/iOS/App/Common/Swift/EmulationScreen.swift` | Slim top bar; follow pointer-mode changes |
| Modify the pointer-mode setters (Task 2 lists them) | Call `PointerModeController` |
| Modify `Source/iOS/App/Common/Swift/Controllers/Remap/RemapPlayerView.swift` | Show `BindingDisplay` text |
| Modify `Source/iOS/App/Common/Swift/Menu/MenuControllerNav.swift`, `MenuFocusRouter.swift`, `MenuScreen.swift` | D-pad left/right adjusts pickers |
| Create tests `Source/iOS/App/DolphiniOSTests/{MotionSettingsTests,PointerModeControllerTests,BindingDisplayTests}.swift` | Unit tests |
| Modify `Source/iOS/App/DolphiniOSTests/MenuFocusRouterTests.swift`, `MenuModelTests.swift` | Adjust-event and picker-cycling tests |

---

### Task 1: MotionSettings, one store with launch-registered defaults

**Files:**
- Create: `Source/iOS/App/Common/Swift/Controllers/MotionSettings.swift`
- Create: `Source/iOS/App/DolphiniOSTests/MotionSettingsTests.swift`
- Modify: `Source/iOS/App/Common/AppDelegate.swift` (the `didFinishLaunchingWithOptions` body)
- Modify: `Source/iOS/App/DolphiniOS/UI/Emulation/TouchController/TCDeviceMotion.swift` (every `UserDefaults.standard.bool(forKey: "motion_…")`)
- Modify: `Source/iOS/App/Common/Swift/EmulationScreen+TouchAndMotion.swift:88-99` (`setupEnhancedMotionControls`)
- Modify: `Source/iOS/App/Common/UI/Settings/SwiftUI/EnhancedMotionControlsView.swift:23-29`, `Source/iOS/App/Common/Swift/MotionDebugView.swift:21-27` (`@AppStorage` literals)

**Interfaces:**
- Produces:
  - `enum MotionSettings`
  - `MotionSettings.Key` (static `String` constants)
  - `MotionSettings.defaults: [String: Any]`
  - `static func registerDefaults(in store: UserDefaults = .standard)`
  - Typed read-only accessors `useYawForHorizontal`, `invertRoll`, `invertPitch`, `enhancedShakeDetection`, `full6DOF`, `wiimoteIMU`, `nunchukIMU` (all `Bool`) and `irPointerGain: Double`
  - Each accessor takes `store: UserDefaults = .standard` through a static function form `value(_:in:)`.

- [ ] **Step 1: Write the failing test**

`Source/iOS/App/DolphiniOSTests/MotionSettingsTests.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class MotionSettingsTests: XCTestCase {
  private var store: UserDefaults!
  private let suite = "MotionSettingsTests"

  override func setUp() {
    super.setUp()
    UserDefaults().removePersistentDomain(forName: suite)
    store = UserDefaults(suiteName: suite)
  }

  override func tearDown() {
    UserDefaults().removePersistentDomain(forName: suite)
    super.tearDown()
  }

  func testRegisteredDefaultsMatchWhatTheRuntimeDidBeforeRegistration() {
    MotionSettings.registerDefaults(in: store)
    XCTAssertFalse(MotionSettings.useYawForHorizontal(in: store))
    XCTAssertFalse(MotionSettings.invertRoll(in: store))
    XCTAssertFalse(MotionSettings.invertPitch(in: store))
    XCTAssertTrue(MotionSettings.enhancedShakeDetection(in: store))
    XCTAssertFalse(MotionSettings.full6DOF(in: store))
    XCTAssertFalse(MotionSettings.wiimoteIMU(in: store))
    XCTAssertFalse(MotionSettings.nunchukIMU(in: store))
    XCTAssertEqual(MotionSettings.irPointerGain(in: store), 1.0)
  }

  func testAUserValueBeatsTheRegisteredDefault() {
    MotionSettings.registerDefaults(in: store)
    store.set(false, forKey: MotionSettings.Key.enhancedShakeDetection)
    XCTAssertFalse(MotionSettings.enhancedShakeDetection(in: store))
  }

  func testKeyNamesAreTheExistingOnes() {
    XCTAssertEqual(MotionSettings.Key.useYawForHorizontal, "motion_use_yaw_for_horizontal")
    XCTAssertEqual(MotionSettings.Key.invertRoll, "motion_invert_roll")
    XCTAssertEqual(MotionSettings.Key.invertPitch, "motion_invert_pitch")
    XCTAssertEqual(MotionSettings.Key.enhancedShakeDetection, "motion_enhanced_shake_detection")
    XCTAssertEqual(MotionSettings.Key.full6DOF, "motion_enable_full_6dof")
    XCTAssertEqual(MotionSettings.Key.wiimoteIMU, "motion_wiimote_imu_enabled")
    XCTAssertEqual(MotionSettings.Key.nunchukIMU, "motion_nunchuck_imu_enabled")
    XCTAssertEqual(MotionSettings.Key.irPointerGain, "touch_overlay_ir_pointer_gain")
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/MotionSettingsTests"`
Expected: build failure, `cannot find 'MotionSettings' in scope`.

- [ ] **Step 3: Write the implementation**

`Source/iOS/App/Common/Swift/Controllers/MotionSettings.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// The motion and pointer settings, read by `TCDeviceMotion` and the settings screens. Before this
/// existed each screen declared its own `@AppStorage` default and the runtime read `bool(forKey:)`
/// (false when unset), so two screens showed "on" for features that were off. Defaults are
/// registered on every launch (registered values are not persisted), and they match what the
/// runtime did before registration, so no user sees a behaviour change.
enum MotionSettings {
  enum Key {
    static let useYawForHorizontal = "motion_use_yaw_for_horizontal"
    static let invertRoll = "motion_invert_roll"
    static let invertPitch = "motion_invert_pitch"
    static let enhancedShakeDetection = "motion_enhanced_shake_detection"
    static let full6DOF = "motion_enable_full_6dof"
    static let wiimoteIMU = "motion_wiimote_imu_enabled"
    static let nunchukIMU = "motion_nunchuck_imu_enabled"
    static let irPointerGain = "touch_overlay_ir_pointer_gain"
  }

  static let defaults: [String: Any] = [
    Key.useYawForHorizontal: false,
    Key.invertRoll: false,
    Key.invertPitch: false,
    // `setupEnhancedMotionControls()` used to force this on for every touchscreen Wii boot.
    Key.enhancedShakeDetection: true,
    Key.full6DOF: false,
    Key.wiimoteIMU: false,
    Key.nunchukIMU: false,
    Key.irPointerGain: 1.0,
  ]

  static func registerDefaults(in store: UserDefaults = .standard) {
    store.register(defaults: defaults)
  }

  static func useYawForHorizontal(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.useYawForHorizontal) }
  static func invertRoll(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.invertRoll) }
  static func invertPitch(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.invertPitch) }
  static func enhancedShakeDetection(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.enhancedShakeDetection) }
  static func full6DOF(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.full6DOF) }
  static func wiimoteIMU(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.wiimoteIMU) }
  static func nunchukIMU(in store: UserDefaults = .standard) -> Bool { store.bool(forKey: Key.nunchukIMU) }
  static func irPointerGain(in store: UserDefaults = .standard) -> Double { store.double(forKey: Key.irPointerGain) }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/MotionSettingsTests"`
Expected: `Executed 3 tests, with 0 failures` and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Adopt it**

1. In `Source/iOS/App/Common/AppDelegate.swift`, add the registration as the first line of `didFinishLaunchingWithOptions`, before `SentryTelemetryService.configure()`:
   ```swift
   MotionSettings.registerDefaults()
   ```
2. In `TCDeviceMotion.swift`, replace each literal read with the accessor. Use this mapping; every call site uses one of these forms:

   | Old | New |
   |---|---|
   | `UserDefaults.standard.bool(forKey: "motion_enable_full_6dof")` | `MotionSettings.full6DOF()` |
   | `UserDefaults.standard.bool(forKey: "motion_wiimote_imu_enabled")` | `MotionSettings.wiimoteIMU()` |
   | `UserDefaults.standard.bool(forKey: "motion_nunchuck_imu_enabled")` | `MotionSettings.nunchukIMU()` |
   | `UserDefaults.standard.bool(forKey: "motion_enhanced_shake_detection")` | `MotionSettings.enhancedShakeDetection()` |
   | `UserDefaults.standard.bool(forKey: "motion_use_yaw_for_horizontal")` | `MotionSettings.useYawForHorizontal()` |
   | `UserDefaults.standard.bool(forKey: "motion_invert_roll")` | `MotionSettings.invertRoll()` |
   | `UserDefaults.standard.bool(forKey: "motion_invert_pitch")` | `MotionSettings.invertPitch()` |

   Verify: `grep -n '"motion_' Source/iOS/App/DolphiniOS/UI/Emulation/TouchController/TCDeviceMotion.swift` prints nothing.
3. In `EmulationScreen+TouchAndMotion.swift` `setupEnhancedMotionControls()`, delete the unconditional `UserDefaults.standard.set(true, forKey: "motion_enhanced_shake_detection")` and its comment, and the two `if UserDefaults.standard.object(forKey: "motion_invert_…") == nil { … }` blocks. Registered defaults now cover all three. Leave the rest of the function unchanged.
4. In `EmulationScreen.swift`, replace the two `UserDefaults.standard.bool(forKey: "motion_enhanced_shake_detection")` reads (lines ~1076 and ~1102) with `MotionSettings.enhancedShakeDetection()`.
5. In `EnhancedMotionControlsView.swift:23-29` and `MotionDebugView.swift:21-27`, change each `@AppStorage("<literal>") … = <value>` to use the key constant and the registered default. Example for one line; apply the same to all seven in each file:
   ```swift
   @AppStorage(MotionSettings.Key.full6DOF) private var fullMotionEnabled: Bool = false
   ```
   Values: `useYawForHorizontal` false, `invertRoll` false, `invertPitch` false, `enhancedShakeDetection` true, `full6DOF` false, `wiimoteIMU` false, `nunchukIMU` false. The `@AppStorage` initial value only applies when no value is registered or stored; with registration it is a fallback, and it must agree.
6. In `ControllersRootView.swift:139`, `:418`, `:493` and `TouchOverlayView.swift:182`, replace the `"touch_overlay_ir_pointer_gain"` literal with `MotionSettings.Key.irPointerGain`.

- [ ] **Step 6: Run the full gates**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice.

- [ ] **Step 7: Commit**

```bash
git add Source/iOS/App/Common/Swift/Controllers/MotionSettings.swift Source/iOS/App/DolphiniOSTests/MotionSettingsTests.swift \
  Source/iOS/App/Common/AppDelegate.swift Source/iOS/App/DolphiniOS/UI/Emulation/TouchController/TCDeviceMotion.swift \
  Source/iOS/App/Common/Swift/EmulationScreen+TouchAndMotion.swift Source/iOS/App/Common/Swift/EmulationScreen.swift \
  Source/iOS/App/Common/UI/Settings/SwiftUI/EnhancedMotionControlsView.swift Source/iOS/App/Common/Swift/MotionDebugView.swift \
  Source/iOS/App/Common/UI/Settings/SwiftUI/ControllersRootView.swift Source/iOS/App/DolphiniOS/UI/Emulation/TouchOverlay/TouchOverlayView.swift
git commit -m "refactor(motion): one MotionSettings store with launch-registered defaults"
```

---

### Task 2: PointerModeController, the one pointer-mode setter

**Files:**
- Create: `Source/iOS/App/Common/Swift/Controllers/PointerModeController.swift`
- Create: `Source/iOS/App/DolphiniOSTests/PointerModeControllerTests.swift`
- Modify: `Source/iOS/App/Common/UI/Emulation/EmuEventVC.h`, `EmuEventVC.m` (notification)
- Modify: every `DOLConfigBridge.setMainTouchPadIRMode(` call site:
  - `Common/UI/Settings/SwiftUI/EnhancedMotionControlsView.swift:60,123`
  - `Common/UI/Settings/SwiftUI/ControllersRootView.swift:366,653`
  - `Common/Swift/EmulationScreen.swift:1509,1518,1527`
  - `Common/Swift/MotionDebugView.swift:108`
  - `DolphiniOS/UI/Settings/TVSoftwarePropertiesView.swift:100` (tvOS)
  - `Widgets/DSUControllerView.swift:182,188,194,347`

  Find each with `git grep -n "setMainTouchPadIRMode(" -- 'Source/iOS/App/*.swift'`.
- Modify: `Source/iOS/App/Common/Swift/EmulationScreen.swift` (follow the notification into `irModeRaw`)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `enum PointerMode: Int, CaseIterable, Identifiable { case gyro = 0, touchFollow = 1, touchDrag = 2 }` with `var title: String` ("Gyro", "Touch – Follow", "Touch – Drag") and `var systemImage: String`
  - `final class PointerModeController` with `static let shared`, `var mode: PointerMode { get }`, `func set(_ mode: PointerMode)`, `func set(rawValue: Int)` (falls back to `.touchFollow` for an unknown value)
  - Notification `Notification.Name.DOLPointerModeDidChange`, posted after every `set`

- [ ] **Step 1: Write the failing test**

`Source/iOS/App/DolphiniOSTests/PointerModeControllerTests.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class PointerModeControllerTests: XCTestCase {
  private var stored = 1
  private var center: NotificationCenter!
  private var controller: PointerModeController!

  override func setUp() {
    super.setUp()
    stored = 1
    center = NotificationCenter()
    controller = PointerModeController(
      read: { [unowned self] in self.stored },
      write: { [unowned self] in self.stored = $0 },
      notificationCenter: center)
  }

  func testRawValuesMatchTheCoreConfig() {
    XCTAssertEqual(PointerMode.gyro.rawValue, 0)
    XCTAssertEqual(PointerMode.touchFollow.rawValue, 1)
    XCTAssertEqual(PointerMode.touchDrag.rawValue, 2)
  }

  func testSetWritesTheConfigAndReadsBack() {
    controller.set(.gyro)
    XCTAssertEqual(stored, 0)
    XCTAssertEqual(controller.mode, .gyro)
  }

  func testSetPostsTheChangeNotification() {
    let posted = expectation(forNotification: .DOLPointerModeDidChange, object: nil, notificationCenter: center)
    controller.set(.touchDrag)
    wait(for: [posted], timeout: 1)
  }

  func testUnknownRawValueFallsBackToTouchFollow() {
    controller.set(rawValue: 7)
    XCTAssertEqual(stored, PointerMode.touchFollow.rawValue)
    stored = 9
    XCTAssertEqual(controller.mode, .touchFollow)
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/PointerModeControllerTests"`
Expected: build failure, `cannot find 'PointerModeController' in scope`.

- [ ] **Step 3: Declare the notification**

In `Source/iOS/App/Common/UI/Emulation/EmuEventVC.h`, after the `DOLRecenterPointerNotification` declaration:
```objc
/// Posted by `PointerModeController` after the Wii pointer mode (`MAIN_TOUCH_PAD_IR_MODE`) changes,
/// so the emulation screen can update the live touch IR pad in place.
FOUNDATION_EXPORT NSNotificationName const DOLPointerModeDidChangeNotification;
```
In `EmuEventVC.m`, after the `DOLRecenterPointerNotification` definition:
```objc
NSNotificationName const DOLPointerModeDidChangeNotification = @"DOLPointerModeDidChange";
```

- [ ] **Step 4: Write the implementation**

`Source/iOS/App/Common/Swift/Controllers/PointerModeController.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// How the emulated Wii Remote's pointer is driven. Raw values are `MAIN_TOUCH_PAD_IR_MODE`'s.
/// The core has no "off" value: 0 means the gyro drives it and the touch pad is idle.
enum PointerMode: Int, CaseIterable, Identifiable {
  case gyro = 0
  case touchFollow = 1
  case touchDrag = 2

  var id: Int { rawValue }

  var title: String {
    switch self {
    case .gyro: return L("Gyro")
    case .touchFollow: return L("Touch – Follow")
    case .touchDrag: return L("Touch – Drag")
    }
  }

  var systemImage: String {
    switch self {
    case .gyro: return "gyroscope"
    case .touchFollow: return "hand.point.up"
    case .touchDrag: return "hand.draw"
    }
  }
}

/// The one place the pointer mode changes. It used to be set directly from nine call sites
/// across the top bar, Settings, Advanced Motion, Motion Debug, the tvOS game properties and the
/// DSU controller, each with its own labels, and only the top bar updated the live pad.
final class PointerModeController {
  static let shared = PointerModeController(
    read: { Int(DOLConfigBridge.mainTouchPadIRMode()) },
    write: { DOLConfigBridge.setMainTouchPadIRMode($0) },
    notificationCenter: .default)

  private let read: () -> Int
  private let write: (Int) -> Void
  private let notificationCenter: NotificationCenter

  init(read: @escaping () -> Int, write: @escaping (Int) -> Void, notificationCenter: NotificationCenter) {
    self.read = read
    self.write = write
    self.notificationCenter = notificationCenter
  }

  var mode: PointerMode { PointerMode(rawValue: read()) ?? .touchFollow }

  func set(_ mode: PointerMode) {
    write(mode.rawValue)
    notificationCenter.post(name: .DOLPointerModeDidChange, object: nil)
  }

  /// For call sites that hold the config's raw integer.
  func set(rawValue: Int) {
    set(PointerMode(rawValue: rawValue) ?? .touchFollow)
  }
}
```
`L(_:)` is the app's existing localization helper, already used in `PauseMenuView.swift`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/PointerModeControllerTests"`
Expected: `Executed 4 tests, with 0 failures`.

- [ ] **Step 6: Route every setter through it**

1. Replace every `DOLConfigBridge.setMainTouchPadIRMode(<expr>)` in the call sites listed under Files with `PointerModeController.shared.set(rawValue: Int(<expr>))`. At sites where `<expr>` is already `Int`, drop the `Int(...)`, e.g. `TouchIRMode.gyro.rawValue`. Check with `git grep -n "setMainTouchPadIRMode(" -- 'Source/iOS/App/*.swift'`, which must print only `PointerModeController.swift`.
2. In `EmulationScreen.swift`, the three top-bar buttons (lines ~1507-1531) each also set `irModeRaw` by hand. Leave `hasTopBarInteraction`, `isTouchControlsActive` and `userOverrideTouchControls` as they are. Replace the two lines `DOLConfigBridge…`/`irModeRaw = N` with the single call `PointerModeController.shared.set(.gyro)` (or `.touchFollow` / `.touchDrag`). Task 5 rebuilds this menu; this step only keeps it compiling and correct.
3. In `EmulationScreen.swift`, next to the existing `.onReceive` modifiers on the emulation view's body, make every setter update the live pad:
   ```swift
   .onReceive(NotificationCenter.default.publisher(for: .DOLPointerModeDidChange)) { _ in
     irModeRaw = PointerModeController.shared.mode.rawValue
   }
   ```
   `TouchPadsContainer.updateUIView` already applies an `irMode` change in place (`EmulationScreen+TouchAndMotion.swift:308-311`).

- [ ] **Step 7: Run the full gates**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice.

- [ ] **Step 8: Commit**

```bash
git add Source/iOS/App/Common/Swift/Controllers/PointerModeController.swift Source/iOS/App/DolphiniOSTests/PointerModeControllerTests.swift \
  Source/iOS/App/Common/UI/Emulation/EmuEventVC.h Source/iOS/App/Common/UI/Emulation/EmuEventVC.m
git add $(git grep -l "PointerModeController.shared" -- 'Source/iOS/App/*.swift')
git commit -m "refactor(input): one PointerModeController for the Wii pointer mode"
```

---

### Task 3: BindingDisplay, friendly names for bound inputs

**Files:**
- Create: `Source/iOS/App/Common/Swift/Controllers/BindingDisplay.swift`
- Create: `Source/iOS/App/DolphiniOSTests/BindingDisplayTests.swift`
- Modify: `Source/iOS/App/Common/Swift/Controllers/Remap/RemapPlayerView.swift:290` (row text) and `:313` (accessibility label)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum DeviceFamily { case xbox, playStation, nintendo, genericMFi, touchscreen, unknown }` with `static func from(qualifier: String) -> DeviceFamily`
  - `enum BindingDisplay` with `static func text(for expression: String, family: DeviceFamily) -> String`, which returns `RemapModel.unboundDisplay` for an empty expression and the raw expression when it cannot be reduced to one input
  - Used by the Phase 3 player screen's rows.

Input names are the `MFiController.mm` `AddInput` strings: `Button A/B/X/Y`, `D-Pad Up/Down/Left/Right`, `L Shoulder`, `R Shoulder`, `L Trigger`, `R Trigger`, `L Stick X+/X-/Y+/Y-`, `R Stick X+/X-/Y+/Y-`, `L Stick`, `R Stick`, `Menu`, `Options`, `Home`, `Touchpad`, `Paddle 1-4`. A qualifier looks like `MFi/0/Xbox Wireless Controller` (source/index/name, the name is the pad's `vendorName`); the touchscreen is `iOS/0/Touchscreen`.

- [ ] **Step 1: Write the failing test**

`Source/iOS/App/DolphiniOSTests/BindingDisplayTests.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later
import XCTest
@testable import iCube

final class BindingDisplayTests: XCTestCase {
  func testFamilyFromQualifier() {
    XCTAssertEqual(DeviceFamily.from(qualifier: "MFi/0/Xbox Wireless Controller"), .xbox)
    XCTAssertEqual(DeviceFamily.from(qualifier: "MFi/1/DualSense Wireless Controller"), .playStation)
    XCTAssertEqual(DeviceFamily.from(qualifier: "MFi/0/DUALSHOCK 4 Wireless Controller"), .playStation)
    XCTAssertEqual(DeviceFamily.from(qualifier: "MFi/0/Pro Controller"), .nintendo)
    XCTAssertEqual(DeviceFamily.from(qualifier: "MFi/0/Backbone One"), .genericMFi)
    XCTAssertEqual(DeviceFamily.from(qualifier: "iOS/0/Touchscreen"), .touchscreen)
    XCTAssertEqual(DeviceFamily.from(qualifier: ""), .unknown)
  }

  func testFaceButtonsUseTheFamilysLabels() {
    XCTAssertEqual(BindingDisplay.text(for: "`Button A`", family: .xbox), "A")
    XCTAssertEqual(BindingDisplay.text(for: "`Button A`", family: .playStation), "✕")
    XCTAssertEqual(BindingDisplay.text(for: "`Button B`", family: .playStation), "○")
    XCTAssertEqual(BindingDisplay.text(for: "`Button X`", family: .playStation), "□")
    XCTAssertEqual(BindingDisplay.text(for: "`Button Y`", family: .playStation), "△")
    // GameController reports the button by POSITION, so Nintendo's "A" position is Apple's B.
    XCTAssertEqual(BindingDisplay.text(for: "`Button A`", family: .nintendo), "B")
  }

  func testSticksShouldersAndSystemButtons() {
    XCTAssertEqual(BindingDisplay.text(for: "`L Stick Y+`", family: .xbox), "Left Stick ↑")
    XCTAssertEqual(BindingDisplay.text(for: "`R Stick X-`", family: .xbox), "Right Stick ←")
    XCTAssertEqual(BindingDisplay.text(for: "`D-Pad Left`", family: .xbox), "D-Pad ←")
    XCTAssertEqual(BindingDisplay.text(for: "`R Shoulder`", family: .xbox), "RB")
    XCTAssertEqual(BindingDisplay.text(for: "`R Shoulder`", family: .playStation), "R1")
    XCTAssertEqual(BindingDisplay.text(for: "`L Trigger`", family: .playStation), "L2")
    XCTAssertEqual(BindingDisplay.text(for: "`Menu`", family: .xbox), "≡ Menu")
    XCTAssertEqual(BindingDisplay.text(for: "`Menu`", family: .playStation), "Options")
    XCTAssertEqual(BindingDisplay.text(for: "`L Stick`", family: .xbox), "Left Stick Click")
  }

  func testUnboundAndUnreducibleExpressions() {
    XCTAssertEqual(BindingDisplay.text(for: "", family: .xbox), RemapModel.unboundDisplay)
    XCTAssertEqual(BindingDisplay.text(for: "  ", family: .xbox), RemapModel.unboundDisplay)
    XCTAssertEqual(BindingDisplay.text(for: "`Button A` | `Button B`", family: .xbox), "`Button A` | `Button B`")
    XCTAssertEqual(BindingDisplay.text(for: "`Paddle 1`", family: .xbox), "Paddle 1")
  }

  func testTouchscreenInputsKeepTheirName() {
    XCTAssertEqual(BindingDisplay.text(for: "`Button 3`", family: .touchscreen), "On-screen Button 3")
  }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/BindingDisplayTests"`
Expected: build failure, `cannot find 'DeviceFamily' in scope`.

- [ ] **Step 3: Write the implementation**

`Source/iOS/App/Common/Swift/Controllers/BindingDisplay.swift`:
```swift
// Copyright 2026 iCube Project
// SPDX-License-Identifier: GPL-2.0-or-later

import Foundation

/// Which printed labels a pad uses, from its Dolphin device qualifier (`MFi/0/<vendorName>`).
enum DeviceFamily: Equatable {
  case xbox, playStation, nintendo, genericMFi, touchscreen, unknown

  static func from(qualifier: String) -> DeviceFamily {
    if qualifier.isEmpty { return .unknown }
    if qualifier.hasPrefix("iOS/") { return .touchscreen }
    let name = qualifier.split(separator: "/", maxSplits: 2).last.map(String.init)?.lowercased() ?? ""
    if name.contains("xbox") { return .xbox }
    if name.contains("dualsense") || name.contains("dualshock") || name.contains("playstation") { return .playStation }
    if name.contains("pro controller") || name.contains("joy-con") || name.contains("nintendo") { return .nintendo }
    return .genericMFi
  }
}

/// Turns a bound control expression into what a player recognises: `` `Button A` `` on an Xbox pad
/// reads "A", on a DualSense "✕". Only a single backquoted input is reduced; anything else (an
/// OR of two inputs, a hand-written expression) is shown raw, and the raw text stays editable
/// under Advanced.
enum BindingDisplay {
  static func text(for expression: String, family: DeviceFamily) -> String {
    let trimmed = expression.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return RemapModel.unboundDisplay }
    guard let input = singleInput(trimmed) else { return trimmed }
    if family == .touchscreen { return String(format: L("On-screen %@"), input) }
    return label(for: input, family: family) ?? input
  }

  /// The input name when `expression` is exactly one backquoted input, e.g. "`Button A`".
  private static func singleInput(_ expression: String) -> String? {
    guard expression.count > 2, expression.first == "`", expression.last == "`" else { return nil }
    let inner = expression.dropFirst().dropLast()
    return inner.contains("`") ? nil : String(inner)
  }

  private static func label(for input: String, family: DeviceFamily) -> String? {
    if let face = faceButton(input, family: family) { return face }
    if let stick = stickDirection(input) { return stick }
    switch input {
    case "D-Pad Up": return L("D-Pad ↑")
    case "D-Pad Down": return L("D-Pad ↓")
    case "D-Pad Left": return L("D-Pad ←")
    case "D-Pad Right": return L("D-Pad →")
    case "L Shoulder": return family == .xbox ? "LB" : (family == .nintendo ? "L" : "L1")
    case "R Shoulder": return family == .xbox ? "RB" : (family == .nintendo ? "R" : "R1")
    case "L Trigger": return family == .xbox ? "LT" : (family == .nintendo ? "ZL" : "L2")
    case "R Trigger": return family == .xbox ? "RT" : (family == .nintendo ? "ZR" : "R2")
    case "L Stick": return L("Left Stick Click")
    case "R Stick": return L("Right Stick Click")
    case "Menu": return family == .playStation ? L("Options") : (family == .nintendo ? "+" : L("≡ Menu"))
    case "Options": return family == .playStation ? L("Share") : (family == .nintendo ? "−" : L("View"))
    case "Home": return L("Home")
    default: return nil
    }
  }

  /// GameController names face buttons by position (A = bottom, B = right, X = left, Y = top).
  private static func faceButton(_ input: String, family: DeviceFamily) -> String? {
    let position: Int
    switch input {
    case "Button A": position = 0
    case "Button B": position = 1
    case "Button X": position = 2
    case "Button Y": position = 3
    default: return nil
    }
    switch family {
    case .playStation: return ["✕", "○", "□", "△"][position]
    case .nintendo: return ["B", "A", "Y", "X"][position]
    default: return ["A", "B", "X", "Y"][position]
    }
  }

  private static func stickDirection(_ input: String) -> String? {
    let parts = input.split(separator: " ")
    guard parts.count == 3, parts[1] == "Stick" else { return nil }
    let stick = parts[0] == "L" ? L("Left Stick") : (parts[0] == "R" ? L("Right Stick") : nil)
    let arrow: String?
    switch parts[2] {
    case "Y+": arrow = "↑"
    case "Y-": arrow = "↓"
    case "X-": arrow = "←"
    case "X+": arrow = "→"
    default: arrow = nil
    }
    guard let stick, let arrow else { return nil }
    return "\(stick) \(arrow)"
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Source/iOS/App && tuist generate --no-open && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/BindingDisplayTests"`
Expected: `Executed 5 tests, with 0 failures`. If `L(...)` returns a translated string in the simulator's locale, the tests still pass: they run in the development locale (English).

- [ ] **Step 5: Show it in the remap screen**

In `RemapPlayerView.swift`, the control row renders `Text(row.expression)` (~line 290) and uses `row.expression` in its accessibility label (~line 313). `RemapPlayerView` already has `deviceQualifier: String` (the bound device). Replace both uses with:
```swift
BindingDisplay.text(for: row.expression, family: DeviceFamily.from(qualifier: deviceQualifier))
```
Keep the row's font as it is but drop any `.monospaced()`/`.font(.system(.body, design: .monospaced))` applied to that text, since the value is no longer code.

- [ ] **Step 6: Run the full gates**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice.

- [ ] **Step 7: Commit**

```bash
git add Source/iOS/App/Common/Swift/Controllers/BindingDisplay.swift Source/iOS/App/DolphiniOSTests/BindingDisplayTests.swift \
  Source/iOS/App/Common/Swift/Controllers/Remap/RemapPlayerView.swift
git commit -m "feat(remap): show bound inputs by their printed labels"
```

---

### Task 4: Menu engine — d-pad left/right changes a picker in place

**Files:**
- Modify: `Source/iOS/App/Common/Swift/Menu/MenuControllerNav.swift` (`Input`, `Event`, `update`, `resync`)
- Modify: `Source/iOS/App/Common/Swift/Menu/MenuFocusRouter.swift` (`MenuFocusUpdate`, `apply`)
- Modify: `Source/iOS/App/Common/Swift/Menu/MenuModel.swift` (add the pure picker-cycling helper)
- Modify: `Source/iOS/App/Common/Swift/Menu/MenuScreen.swift` (`navInput`, `tick`, `performActivate`)
- Test: `Source/iOS/App/DolphiniOSTests/MenuFocusRouterTests.swift`, `Source/iOS/App/DolphiniOSTests/MenuModelTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `MenuControllerNav.Input.left` / `.right: Bool`
  - `MenuControllerNav.Event.adjust(Int)` (-1 = left, +1 = right)
  - `MenuFocusUpdate.adjust: (id: String, step: Int)?`
  - `static func MenuItemRole.cycled(options: [(String, AnyHashable)], current: AnyHashable, step: Int) -> AnyHashable?`, which the Phase 3 player screen's pickers (Device / Extension / Pointer) rely on

Left/right is edge-triggered with no repeat, like A/B: one step per press. Up/down keeps its hold-to-repeat.

- [ ] **Step 1: Write the failing tests**

Append to `MenuFocusRouterTests.swift`, inside the class:
```swift
  // MARK: Adjust (d-pad left/right)

  func test_adjust_reportsFocusedItemAndDirection_oncePerPress() {
    var router = MenuFocusRouter(config: cfg)
    let model = twoSectionModel()
    var right = MenuControllerNav.Input()
    right.right = true
    let first = router.update(right, at: 0, model: model, focusedID: "b", isActive: true)
    XCTAssertEqual(first.adjust?.id, "b")
    XCTAssertEqual(first.adjust?.step, 1)
    let held = router.update(right, at: 1, model: model, focusedID: "b", isActive: true)
    XCTAssertNil(held.adjust, "a held right must not repeat")
    _ = router.update(MenuControllerNav.Input(), at: 1.1, model: model, focusedID: "b", isActive: true)
    var left = MenuControllerNav.Input()
    left.left = true
    let back = router.update(left, at: 1.2, model: model, focusedID: "b", isActive: true)
    XCTAssertEqual(back.adjust?.step, -1)
  }

  func test_adjust_withNoFocus_reportsNothing() {
    var router = MenuFocusRouter(config: cfg)
    var right = MenuControllerNav.Input()
    right.right = true
    XCTAssertNil(router.update(right, at: 0, model: twoSectionModel(), focusedID: nil, isActive: true).adjust)
  }
```

Append to `MenuModelTests.swift`, inside the class:
```swift
  func test_pickerCycling_wrapsBothWays() {
    let options: [(String, AnyHashable)] = [("A", AnyHashable(0)), ("B", AnyHashable(1)), ("C", AnyHashable(2))]
    XCTAssertEqual(MenuItemRole.cycled(options: options, current: AnyHashable(0), step: 1), AnyHashable(1))
    XCTAssertEqual(MenuItemRole.cycled(options: options, current: AnyHashable(2), step: 1), AnyHashable(0))
    XCTAssertEqual(MenuItemRole.cycled(options: options, current: AnyHashable(0), step: -1), AnyHashable(2))
    XCTAssertEqual(MenuItemRole.cycled(options: options, current: AnyHashable(9), step: 1), AnyHashable(0))
    XCTAssertNil(MenuItemRole.cycled(options: [], current: AnyHashable(0), step: 1))
  }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/MenuFocusRouterTests -only-testing:iCubeTests/MenuModelTests"`
Expected: build failure, `value of type 'MenuControllerNav.Input' has no member 'right'`.

- [ ] **Step 3: Implement the nav event**

In `MenuControllerNav.swift`:
1. Add to `struct Input`, after `rightShoulder`:
   ```swift
   /// D-pad left/right: change the focused picker's value. One step per press, no repeat.
   var left = false
   var right = false
   ```
2. Add to `enum Event`, after `jumpSection`:
   ```swift
   /// -1 = previous option, +1 = next option, on the focused picker row.
   case adjust(Int)
   ```
3. Add two latches next to the shoulder latches:
   ```swift
   private var leftLatched = false
   private var rightLatched = false
   ```
4. In `update(_:at:)`, before `return events`:
   ```swift
   if input.left {
     if !leftLatched {
       leftLatched = true
       events.append(.adjust(-1))
     }
   } else {
     leftLatched = false
   }

   if input.right {
     if !rightLatched {
       rightLatched = true
       events.append(.adjust(1))
     }
   } else {
     rightLatched = false
   }
   ```
5. In `resync(_:at:)`, after `rightShoulderLatched = input.rightShoulder`:
   ```swift
   leftLatched = input.left
   rightLatched = input.right
   ```

- [ ] **Step 4: Carry it through the router**

In `MenuFocusRouter.swift`:
1. Add to `struct MenuFocusUpdate`:
   ```swift
   /// Set when a left/right edge fired on a currently-focused item.
   var adjust: (id: String, step: Int)?
   ```
   A tuple is not `Equatable`, so replace `struct MenuFocusUpdate: Equatable` with `struct MenuFocusUpdate` plus this explicit conformance directly below it:
   ```swift
   extension MenuFocusUpdate: Equatable {
     static func == (lhs: MenuFocusUpdate, rhs: MenuFocusUpdate) -> Bool {
       lhs.focusedID == rhs.focusedID && lhs.activatedID == rhs.activatedID && lhs.didGoBack == rhs.didGoBack
         && lhs.adjust?.id == rhs.adjust?.id && lhs.adjust?.step == rhs.adjust?.step
     }
   }
   ```
2. In `apply(_:model:focusedID:)`, declare `var adjust: (id: String, step: Int)?` next to `var activated`, add the case
   ```swift
   case .adjust(let step):
     if let current { adjust = (current, step) }
   ```
   and return `MenuFocusUpdate(focusedID: current, activatedID: activated, didGoBack: didGoBack, adjust: adjust)`.
3. In the multi-pad `update(padInputs:…)`, declare `var adjust: (id: String, step: Int)?` next to `var activated`, add `if adjust == nil { adjust = padResult.adjust }` next to the `activated` line, and pass `adjust: adjust` into the returned `MenuFocusUpdate`.

- [ ] **Step 5: Add the picker-cycling helper and use it**

In `MenuModel.swift`, after `enum MenuItemRole { … }`:
```swift
extension MenuItemRole {
  /// The option `step` places after `current`, wrapping both ways. An unknown `current` starts
  /// from before the first option, so +1 lands on the first. `nil` when there are no options.
  static func cycled(options: [(String, AnyHashable)], current: AnyHashable, step: Int) -> AnyHashable? {
    guard !options.isEmpty else { return nil }
    let index = options.firstIndex { $0.1 == current } ?? -1
    let count = options.count
    return options[((index + step) % count + count) % count].1
  }
}
```
In `MenuScreen.swift`:
1. In `performActivate`, replace the `.picker` case body with:
   ```swift
   case .picker(let options, let selection):
     if let next = MenuItemRole.cycled(options: options, current: selection.wrappedValue, step: 1) {
       selection.wrappedValue = next
     }
   ```
2. In `navInput(_:)`, add after `rightShoulder:`:
   ```swift
   left: pad.dpad.left.isPressed,
   right: pad.dpad.right.isPressed
   ```
   `Input`'s memberwise init takes the parameters in declaration order, and `left`/`right` come last.
3. In `tick()`, after the `performActivate(item)` block and before `if result.didGoBack`:
   ```swift
   if let adjust = result.adjust, let item = model.item(id: adjust.id), item.isEnabled,
      case .picker(let options, let selection) = item.role,
      let next = MenuItemRole.cycled(options: options, current: selection.wrappedValue, step: adjust.step) {
     selection.wrappedValue = next
   }
   ```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"`
Expected: `** TEST SUCCEEDED **`. The existing `RemapModelTests` still exercise `MenuControllerNav` under its `RemapControllerNav` alias, and they must stay green.

- [ ] **Step 7: Release gate and commit**

Run: `cd Source/iOS/App && make gate-release`. Expected: `** BUILD SUCCEEDED **` twice.
```bash
git add Source/iOS/App/Common/Swift/Menu/MenuControllerNav.swift Source/iOS/App/Common/Swift/Menu/MenuFocusRouter.swift \
  Source/iOS/App/Common/Swift/Menu/MenuModel.swift Source/iOS/App/Common/Swift/Menu/MenuScreen.swift \
  Source/iOS/App/DolphiniOSTests/MenuFocusRouterTests.swift Source/iOS/App/DolphiniOSTests/MenuModelTests.swift
git commit -m "feat(menu): d-pad left/right changes the focused picker"
```

---

### Task 5: Slim in-game top bar

**Files:**
- Modify: `Source/iOS/App/Common/Swift/EmulationScreen.swift`: the "gamecontroller" top-bar menu (~1382-1424), the "square.stack.3d.up" menu's Touch Cursor Mode submenu and Motion Controls item (~1505-1548), and the `showMotionDebug` sheet (~1324)
- Modify: `Source/iOS/App/Common/Swift/PauseMenuView.swift` (make `controllerSetupSystem` reusable)

**Interfaces:**
- Consumes: `PointerMode`, `PointerModeController.shared` (Task 2); `TCDeviceMotion.requestPointerRecenter()` (already on develop, `f24ca8741b`).
- Produces: `static var ControllerSetupSystem.forRunningGame: ControllerSetupSystem` (moved from `PauseMenuView`), used by the top bar now and the hub in Phase 2.

Target top-bar layout: the "gamecontroller" menu becomes the single controller menu:
```
Pointer                ▸  Gyro / Touch – Follow / Touch – Drag   (Wii only)
Recenter Pointer          (Wii only)
Show / Hide On-Screen Controls
On-Screen Style        ▸  Auto / GameCube / Wii   (unchanged; moves to the hub in Phase 2)
Controller Settings…
```
The "square.stack.3d.up" menu keeps Save State / Load State only.

- [ ] **Step 1: Make the running-game system reusable**

In `PauseMenuView.swift`, move the body of `private static var controllerSetupSystem: ControllerSetupSystem` into an extension on `ControllerSetupSystem`, placed directly above `struct PauseMenuView` in the same file:
```swift
extension ControllerSetupSystem {
  /// The ports the running game accepts: Wii titles get Wii Remotes and GameCube ports,
  /// GameCube titles the ports only. Read from the running core, not `ControllerManager.isWiiSystem`.
  static var forRunningGame: ControllerSetupSystem {
    let isWii = TVEmulationBridge.isRunning() ? TVEmulationBridge.isCurrentSystemWii() : ControllerManager.shared.isWiiSystem
    return isWii ? .wiiAndGameCube : .gamecube
  }
}
```
Delete `private static var controllerSetupSystem` from `PauseMenuView`, and replace its uses (`Self.controllerSetupSystem`) with `.forRunningGame`. Check with `git grep -n "controllerSetupSystem" -- 'Source/iOS/App/*.swift'`, which must print nothing.

- [ ] **Step 2: Add the Controller Settings sheet state**

In `EmulationScreen.swift`, next to `@State private var showMotionDebug` in the iOS block (~line 287):
```swift
@State private var showControllerSettings = false
```
Next to the existing `.sheet(isPresented: $showMotionDebug)` (~line 1324), add:
```swift
.sheet(isPresented: $showControllerSettings) {
  NavigationStack {
    ControllerSetupView(system: .forRunningGame)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { showControllerSettings = false } }
      }
  }
}
```
This is the same view the pause menu opens today; Phase 2 swaps both for the hub.

- [ ] **Step 3: Rebuild the controller menu**

In the "gamecontroller" `Menu { … }` (~1382-1424), keep the existing show/hide button and the Auto/GameCube/Wii buttons exactly as they are, and wrap the three style buttons in a submenu:
```swift
Menu {
  // the existing Auto / GameCube / Wii buttons, unchanged
} label: {
  Label(L("On-Screen Style"), systemImage: "rectangle.3.group")
}
```
Then insert this block at the top of the "gamecontroller" menu, before the show/hide button:
```swift
if isWiiSystem {
  Menu {
    ForEach(PointerMode.allCases) { mode in
      Button {
        hasTopBarInteraction = true
        isTouchControlsActive = true
        userOverrideTouchControls = true
        PointerModeController.shared.set(mode)
      } label: {
        Label(mode.title, systemImage: irModeRaw == mode.rawValue ? "checkmark" : mode.systemImage)
      }
    }
  } label: {
    Label(L("Pointer"), systemImage: "cursor.rays")
  }
  Button {
    hasTopBarInteraction = true
    TCDeviceMotion.requestPointerRecenter()
  } label: {
    Label(L("Recenter Pointer"), systemImage: "scope")
  }
}
```
Append at the end of the "gamecontroller" menu:
```swift
Divider()
Button {
  hasTopBarInteraction = true
  showControllerSettings = true
} label: {
  Label(L("Controller Settings…"), systemImage: "gearshape")
}
```
`isWiiSystem` is the existing `EmulationScreen` property that the touch-pad code's `.auto` overlay mode already reads (~line 1007). Gate on the running game, not on the overlay style: the pointer matters for any Wii title.

- [ ] **Step 4: Remove the old items**

In the "square.stack.3d.up" menu (~1505-1548), delete the whole "Touch Cursor Mode" `Menu { … }` (its three buttons now live in the Pointer submenu, and the Recenter button added in `f24ca8741b` moves with it) and the "Motion Controls" button. Then gate the debug view:
1. Wrap `@State private var showMotionDebug` (iOS declaration, ~line 287) and its `.sheet(isPresented: $showMotionDebug) { … }` (~line 1324) in `#if DEBUG … #endif`.
2. `git grep -n "showMotionDebug" -- Source/iOS/App/Common/Swift/EmulationScreen.swift` must show only lines inside `#if DEBUG` blocks, plus the tvOS declaration (~line 244) if it is used by tvOS code. Leave that one alone.

- [ ] **Step 5: Build, test, gate**

Run: `cd Source/iOS/App && make test SIM="iPhone 17 Pro" 2>&1 | grep -E "TEST (SUCCEEDED|FAILED)|with [1-9][0-9]* failures"` then `make gate-release`.
Expected: `** TEST SUCCEEDED **`; `** BUILD SUCCEEDED **` twice. The Release gate matters here: `#if DEBUG` mistakes only fail in Release.

- [ ] **Step 6: Commit**

```bash
git add Source/iOS/App/Common/Swift/EmulationScreen.swift Source/iOS/App/Common/Swift/PauseMenuView.swift
git commit -m "feat(top-bar): one controller menu, motion debug behind DEBUG"
```

---

### Task 6: Device checklist and handoff

**Files:**
- Create: `docs/handoff-2026-09-28-controller-hub-phase1.md`

- [ ] **Step 1: Write the handoff**

```markdown
# Controller Hub Phase 1 — handoff (2026-09-28)

Plan: docs/superpowers/plans/2026-09-28-controller-hub-phase1-foundation.md
Spec: docs/superpowers/specs/2026-09-28-controller-hub-design.md

## Landed
<one line per task commit: SHA + subject>

## Device checklist (iPhone 16 Pro Max, a Wii title with the touch overlay)
1. Top bar controller menu shows Pointer, Recenter Pointer, Show/Hide, On-Screen Style, Controller Settings…
2. Pointer → Gyro: cursor starts centered on how the phone is held; Recenter re-centers it.
3. Pointer → Touch – Drag from the top bar, then from Settings → Controllers: the live pad follows both (no restart).
4. Settings → Advanced Motion: shake detection shows ON; turn it off, boot a Wii game, it stays off.
5. Customize Buttons…: rows read "A", "Left Stick ↑", "RB" (Xbox) / "✕", "R1" (DualSense), not `Button A`.
6. With a pad, in any MenuScreen list with a picker: d-pad right/left changes it one step per press.
7. Top bar no longer has "Motion Controls"; Release build has no Motion Debug anywhere.

## Next
Phase 2 plan: the hub (ControllerHubViewModel + ControllerHubModelBuilder, wired into the pause menu,
Settings and "Controller Settings…"), which also fixes the Profiles / Customize Buttons scroll lockup.
Open product question for Phase 2: `dsu_role` default ("receiver" in ControllersRootView vs "sender" in TVLibraryView).
```
Fill in the "Landed" lines from `git log --oneline -6`.

- [ ] **Step 2: Commit**

```bash
git add docs/handoff-2026-09-28-controller-hub-phase1.md
git commit -m "docs: controller hub phase 1 handoff and device checklist"
```
