# HUD and Controller-Navigable Menu Package Survey

This document surveys Swift packages (SPM, iOS 17+/tvOS 17+, permissive licenses) that could replace or improve:
- (a) In-game top-bar HUD with controller/focus navigation
- (b) Data-driven menu screens (sections/items/badges/submenus) with touch and game-controller focus
- (c) Focus-engine helpers for SwiftUI on iOS

## Built-In Options (Consider These First)

**SwiftUI @FocusState + .focusable() (iOS 15+/tvOS 15+)**
- Native, zero-dependency, type-safe focus management
- `@FocusState` holds focusable element ID; `.focusable()` marks views; `.focused(_:equals:)` binds state
- tvOS: full geometry-based focus resolution; iOS 17+ keyboard-driven navigation
- Verdict: **Use this for menus.** Covers data-driven menu navigation on both platforms.

**UIFocusSystem.movement(in:direction:) (iOS 15+/tvOS 15+)**
- Programmatically redirect focus via `UIFocusSystem.request(.redirect(to:, in:))`
- Pair with `GCController.controllers().first?.extendedGamepad?.dpad.upButton.pressedChangedHandler` to map game-controller input to focus movement
- Verdict: **Use for custom focus routing.** Maps dpad/thumbstick to focus shifts.

## Package Candidates

### 1. **GameControllerKit**
- **Repo:** https://github.com/0xWDG/GameControllerKit
- **License:** MIT
- **Platforms:** iOS 13+, macOS 10.15+, tvOS 16+
- **Last Activity:** November 2025 (5 releases)
- **SwiftUI Native:** Partial (mock GCKControllerView for testing)
- **Size/Dependencies:** Zero external dependencies; Swift 5.9+ required
- **tvOS Focus:** No dedicated focus integration; provides controller input only
- **Verdict:** **Lightweight controller wrapper.** Use to read input, pair with @FocusState for focus management.

### 2. **SwiftUIGamepad**
- **Repo:** https://github.com/Appracatappra/SwiftUIGamepad
- **License:** MIT
- **Last Activity:** Stable (~20 commits); no recent release date visible
- **Platforms:** iOS, tvOS (with caveat: disable Micro Gamepad on tvOS to avoid interference)
- **SwiftUI Native:** Yes
- **Features:** Built-in help overlays, "gamepad required" sheet, PS4/PS5/Xbox button images
- **Verdict:** **UI-focused, not focus-engine.** Use for gamepad instruction overlays; pair with @FocusState for navigation.

### 3. **SwiftUIOverlayContainer**
- **Repo:** https://github.com/fatbobman/SwiftUIOverlayContainer
- **License:** MIT
- **Last Activity:** 204 commits; v2.0.0+ stable
- **Platforms:** iOS 14+, tvOS 14+, macOS 11+
- **SwiftUI Native:** Yes (100% SwiftUI, queue management, custom layouts)
- **tvOS Focus:** Explicitly addressed; long-press only on tvOS
- **Verdict:** **HUD container.** Use for top-bar HUD stacking and dismiss animations; data-driven via SwiftUI state.

### 4. **JGProgressHUD-SwiftUI**
- **Repo:** https://github.com/JonasGessner/JGProgressHUD-SwiftUI
- **License:** MIT (© 2020, Jonas Gessner)
- **Platforms:** iOS 14+, tvOS 14+, macCatalyst 14+
- **SwiftUI Native:** Wrapper (UIKit underneath, environment-based presenter)
- **tvOS Focus:** Not addressed; long-press may not work well
- **Verdict:** **HUD overlay only.** Good for loading/status HUDs; not menu-navigation-focused.

### 5. **FloatingPanel**
- **Repo:** https://github.com/scenee/FloatingPanel
- **License:** MIT
- **Platforms:** iOS 15.0+ only (no tvOS)
- **Last Activity:** Version 3.2.4; no explicit recent release date
- **SwiftUI Native:** Yes (SwiftUI API support; examples included)
- **tvOS Focus:** Not supported
- **Size:** Fluid springing, scroll tracking, multiple positions (top/bottom/left/right)
- **Verdict:** **iOS-only panel.** Skip for tvOS target; SwiftUI menus cover this.

### 6. **SwiftySegmentedPicker**
- **Repo:** https://github.com/KazaiMazai/SwiftySegmentedPicker
- **License:** MIT
- **Platforms:** iOS, tvOS (inferred; no explicit version requirements listed)
- **Last Activity:** 22 commits; stable
- **SwiftUI Native:** Yes (custom underline/capsule selection styles)
- **Dependencies:** None
- **Verdict:** **Compact inline selector.** Use for menu sub-sections; not HUD/focus-focused.

## Recommendation Ranked for iCube

1. **@FocusState + .focusable() (built-in)** — Start here. Zero dependencies, native tvOS focus resolution, data-driven menu rows via SwiftUI state. Maps game-controller dpad to focus via `UIFocusSystem.movement(in:direction:)` or `.onMoveCommand`.

2. **SwiftUIOverlayContainer (for HUD)** — Minimal, tvOS-aware, native SwiftUI queue/animation. Layer it behind menu List for status/alerts.

3. **GameControllerKit (optional)** — Only if `GCController` input boilerplate is too verbose. Otherwise, bare `GCController.controllers()` + `.pressedChangedHandler` is simpler.

**Skip:** FloatingPanel (iOS-only), JGProgressHUD-SwiftUI (UIKit wrapper; use SwiftUIOverlayContainer instead), swift-focuser (iOS 13–14 legacy, now @FocusState).
