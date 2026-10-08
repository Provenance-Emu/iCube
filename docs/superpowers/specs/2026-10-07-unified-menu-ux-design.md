# Unified menu UX: pause overlay, settings shell, controller hub

Date: 2026-10-07
Status: approved in conversation, awaiting spec review
Scope: iCube (dolphin-ios) iOS and tvOS. Four PR-sized workstreams built on one shared UI kit.

## 1. Problem

- tvOS has no in-game quick access. The iOS top bar (`Swift/TopBar/EmulationTopBar.swift`) is compiled out with a file-level `#if os(iOS)`, so a tvOS player's only in-game surface is the pause menu.
- The pause menu is two implementations in one file (`Swift/PauseMenuView.swift`, 1565 lines). iOS renders a data-driven `MenuScreen` grid; tvOS is a hand-built column of buttons (`tvMainMenu`) that scrolls past the screen with 11 rows and has no quick actions.
- Settings (`UI/Settings/SwiftUI/SettingsRootView.swift` plus 26 hand-built leaf views, ~5800 lines) is a plain `NavigationStack { List }`. On tvOS it is the system list with no icons, colour or descriptions. The 2026-09-24 data-driven menus spec says settings is on the `MenuModel` engine; it is not.
- Controller settings are hard to use: the emulated controller type is read-only subtitle text in the hub row (`Swift/Controllers/Hub/ControllerHubModelBuilder.swift:58-82`), Extension and Sideways are two separate controls a level down (`Swift/Controllers/Player/PlayerScreenModelBuilder.swift:126-135`), and the Auto/GameCube/Wii choice is labelled "Overlay Style", lives in an iOS-only section, and does not exist on tvOS.
- Pause state leaks. Opening a sub-sheet or backing out of one can resume the core underneath the pause menu. There are at least four independent owners (`PauseGestureTracker.requestPauseMenu`, `PauseMenuView` via `PauseOwnership`, the controller-settings sheet in `EmulationScreen.swift:1483-1497`, the top-bar `pausedFromBar` flag) and a global `.onExitCommand` at `EmulationScreen.swift:732` that resumes whenever the pause menu is showing.

## 2. Decisions

Taken with the owner on 2026-10-07:

1. **One surface.** A Menu tap opens one pause tile grid on both platforms. Its top row is the quick bar. No separate quick strip, no radial menu.
2. **Sidebar shell for settings** on tvOS, iPad and Mac; a tab strip on iPhone. Both render the same model.
3. **Visual language.** Port iFly's Theme and focus layer as a small kit; keep iCube's blurred cover-art backdrop and material tiles. One palette, no font change.
4. **Controller hub row carries the common choices inline:** Device, Plays as, and Pointer. "Overlay Style" becomes Touch Controls → Layout.
5. **Siri Remote is navigation only.** Menu opens the overlay; the touch surface moves focus. No remote-specific features.
6. **Assume a real pad** (MFi, Xbox, PlayStation). tvOS never exposes Home/PS/Xbox to apps, so the triggers stay Menu/Options/Share/View and the existing four-shoulders-plus-Menu combo.

## 3. Research summary

Patterns that recur across Steam Deck Quick Access, PS5 Control Center, Xbox Guide, Switch quick settings, RetroArch's Quick Menu, iFly tvOS and Provenance:

- Controller-driven tiles or cards over the still-visible paused frame.
- Tap to cycle a value with a badge on the tile; long-press for the exact picker.
- A one-line description of the focused item in a fixed shelf.
- "This game" actions first, system actions last; destructive actions visually distinct.
- Pause on open, resume only on final close.
- Radial menus suit 4 to 8 unlabeled actions chosen blind; they fail with labels, sliders and submenus, and their hold gesture collides with hold-to-open.

## 4. Architecture

### 4.1 MenuKit (shared, no emulator dependencies)

Folder: `Source/iOS/App/Common/Swift/MenuKit/`. Pure SwiftUI, compiles for iOS and tvOS (macOS and visionOS guarded). Nothing in it imports `TVEmulationBridge`, `ControllerManager` or `DOL*`.

| Type | Purpose |
|---|---|
| `MenuTheme` | Protocol with `accent`, `background`, `secondaryBackground`, `cornerRadius`, `focusRingWidth`, `focusScale`. One concrete `ICubeTheme`. Injected as an `@Entry` environment value. |
| `FocusButtonStyle` | `ButtonStyle` that reads `isFocused` inside `makeBody` (the only place it is correct on tvOS), draws the accent ring, scales by `focusScale` with a spring, lifts `zIndex`, and calls `.focusEffectDisabled()`. On iOS it takes an explicit `isFocused` from the polled d-pad focus so both platforms look identical. |
| `TileFace` | Icon, label, optional value badge (top-right capsule), enabled state, tint. Destructive tint for `.destructive`. |
| `TileGrid` | Grid of `TileFace`s. Eager rows on tvOS (the focus engine must see every tile), `LazyVGrid` on iOS. One outer `.focusSection()`; no per-section focus sections. Column count supplied by the caller. |
| `InfoShelf` | Fixed bottom bar: info icon plus the focused item's `description`, up to three lines, plus the current value for cycle items. |
| `ValueStepper` | Generic over `BinaryInteger` and `BinaryFloatingPoint`. Replaces `TVFloatStepper` and `TVIntStepperOverlay`. Left/right adjusts, ring on focus. |
| `SheetScaffold` | Title, subtitle, close control, scroll content with a 44pt inset so the focus ring is never clipped. `.fullScreenCover` on tvOS, `.sheet` on iOS, chosen by the caller. |
| `BackCoalescer` | Drops exit/back commands that arrive within 250 ms of a presentation opening, so the release of the opening press does not close it. |

### 4.2 MenuModel changes (`Swift/Menu/MenuModel.swift`)

- `MenuItem` gains `description: String?` and `longPressOptions: [MenuOption]?`.
- New role `.cycle(options: [MenuOption], selection: Binding<String>)`. Activate advances to the next option and wraps. A long-press of Select/A on the focused item (both platforms) opens the option list via the existing `.picker` renderer.
- `MenuScreen` gains `style: .tiles(columns:)`, rendered with `TileGrid` + `InfoShelf`. `.grid` and `.list` are unchanged so every current caller keeps working.
- Any `MenuScreen` style on tvOS switches from the system `List` to rows built on `FocusButtonStyle`, so icons and tints are no longer dropped.

### 4.3 PauseArbiter (`Swift/Emulation/PauseArbiter.swift`)

```swift
@MainActor final class PauseArbiter {
  static let shared: PauseArbiter
  struct Token: Hashable { let id: UUID; let reason: String }
  func claim(_ reason: String) -> Token   // pauses the core on the first claim
  func release(_ token: Token)            // resumes on the last release
  var isHeld: Bool
  var holders: [String]                   // for the [NO-FRAME] style debug log
}
```

Rules:

- Every presentation that should keep the game paused claims on appear and releases on disappear: pause menu root, each pane (saves, cheats, controllers, shaders, continuity, fast-forward picker, confirm overlays), the Settings cover, and the controller-settings sheet from the top bar.
- A release for a token already released is a no-op. A claim while the core is not running is recorded but does not call the bridge; it is applied if emulation starts while held.
- The top bar's user-initiated Pause is a claim with reason `"user"` that nothing else releases. The PausedPill and the global exit-command handler resume by releasing *that* token only, never by calling `TVEmulationBridge.resume()` directly.
- The disconnect pause (`controllerManager.disconnectPause`) becomes a claim with reason `"disconnect"`.
- The arbiter owns every `TVEmulationBridge.pause()` and `.resume()` call in the UI layer. A lint-style grep test fails if any other Swift file under `Source/iOS/App/Common/Swift` calls them.
- `PauseOwnership` is deleted once all callers are migrated.

## 5. Pause overlay

One `PauseMenuView` for both platforms, built from one `PauseMenuModelBuilder.make(state:actions:)` (existing file, extended) and rendered with `MenuScreen(style: .tiles)`. The hand-built `tvMainMenu`, `tvMenuToggleRow`, `settingsButtonRow` and `tvFastForwardSpeedMenu` are deleted.

### 5.1 Layout

- Backdrop: blurred cover art (24pt, 0.5 opacity) under a black gradient, as today. tvOS: a left column with box art, title and a "Paused" badge; the grid fills the right. iPhone: the art sits behind a compact header. iPad: as tvOS with narrower art.
- Section **Quick** (large tiles): Resume, Quick Save, Quick Load, Fast Forward, Mute, Screenshot.
- Section **Game**: Save States, Cheats, Shaders, Controllers, Continue Elsewhere, Recenter Pointer (iOS, Wii only).
- Section **System**: Settings, Reset, Exit.
- `InfoShelf` at the bottom.
- Columns: 6 on tvOS, 3 on iPhone portrait, 4 on iPhone landscape, 4 to 6 on iPad by width. tvOS never scrolls. iPhone may scroll by at most one row.

### 5.2 Item behaviour

| Tile | Role | Badge | Long-press |
|---|---|---|---|
| Resume | action, dismisses | — | — |
| Quick Save / Quick Load | action, stays open, toast | slot number | slot picker 1–10 |
| Fast Forward | cycle: Off, 2x, 4x, 8x, Unlimited | current | full list |
| Mute | toggle | On/Off | — |
| Screenshot | action, toast | — | — |
| Shaders | cycle through the quick picker's recent list | current name | full `ShaderQuickPickerView` |
| Reset / Exit | destructive, confirm in place using the existing confirm overlay | — | — |

Descriptions are localised strings in the builder, one per tile.

### 5.3 Input

- Triggers unchanged: Siri Remote Menu short tap, micro-pad Menu, extended-pad Options/Share/View and Home where delivered, four shoulders plus Menu. The 2 s Menu hold still exits to the library.
- Inside the overlay: A activates, B or Menu goes back one pane (closing at the root), Play/Pause resumes from anywhere. `BackCoalescer` guards the opening press on tvOS.
- The overlay claims the arbiter on appear; each pane claims its own token; closing the root releases the last token and the core resumes.
- `controllerUserInteractionEnabled` on `EmuEventVC` keeps flipping with `DOLPauseOverlayShown/Hidden`.

## 6. Settings

### 6.1 Shells

`SettingsRootView` becomes a thin host that chooses a shell by size class and platform:

- **Sidebar shell** (tvOS, iPad regular width, Mac): a 320pt (tvOS) or 240pt (iPad) sidebar of sections with icon and title in its own `.focusSection()`, a right pane rendering the selected section's `MenuModel` with `MenuScreen(style: .list)`. Moving right from the sidebar focuses the first row of the pane; moving left from the first column of the pane returns to the sidebar.
- **Tab-strip shell** (iPhone): a horizontal capsule strip of the same sections above the rows.

The `TVSettingsPage` wrapper is deleted; the sidebar shell replaces it.

### 6.2 Root sections

General, Graphics, Audio, GameCube & Wii, Controllers, Performance, Sync & Network, About.

- Sync & Network absorbs Web UI, WebDAV, iCloud Sync and Nearby Devices. The web-server polling and the Safari sheet move from the root into the Web UI leaf.
- About absorbs Version, Core, Blog and Help.
- "Reset All" stays as a destructive action at the bottom of General.

### 6.3 Rows

Every row has a title, optional icon, a one-line `description`, and one of: toggle, cycle picker (left/right on tvOS, tap to cycle on iOS, long-press for the list on both), `ValueStepper`, navigation, action, destructive action, or `.destination(AnyView)` for leaves not yet migrated. Per-game override badges from #30 keep rendering through `MenuItem.badge`.

### 6.4 Search

iOS only, as today, but generated: `SettingsSearchIndex` is built by walking the root sections' models (title, description, keywords) at first use. The hand-maintained entries file is deleted.

### 6.5 Leaf migration

Each leaf gets a `<Leaf>ModelBuilder` returning a `MenuModel`; the view becomes `MenuScreen(model:style:)`. Order: Performance Tuning, Graphics Hacks, Graphics General, Graphics Enhancements first (largest and worst on tvOS), then the rest in batches of five to six. Until migrated, a leaf is reached through `.destination(AnyView)` and is visually unchanged, so there is no big-bang cutover.

## 7. Controller hub

The hub (`Swift/Controllers/Hub/`) stays the single controller surface, reached from the pause overlay, the iOS top bar and Settings → Controllers. Its model builder changes.

### 7.1 Players section

One row per active player (GameCube ports 0–3 for GC titles, Wii slots 4–7 plus GC ports for Wii titles, as the hub resolves today). Each row has three inline cycle pickers rendered as compact value pills; left/right on tvOS, tap to cycle on iOS, long-press for the list on both:

- **Device**: Auto, each connected pad by name, Touchscreen (iOS), None.
- **Plays as**: GameCube Controller; and for Wii titles also Wii Remote, Wii Remote + Nunchuk, Wii Classic Controller, Wii Remote Sideways.
- **Pointer** (shown only when Plays as is a Wii Remote variant): Touch (iOS), Gyro, Right Stick, Off.

The row badge mirrors Plays as. Activating the row title opens the existing player detail screen for Remap, Motion, Stick Feel and the remaining per-player options. Extension and Sideways are removed from the detail screen since Plays as covers them.

### 7.2 Plays-as setter

`ControllerHubViewModel.setPlaysAs(player:, value:)` composes existing writers, no new bridge code:

- GameCube Controller: bind the player's device to the GC port; clear the Wii slot.
- Wii Remote variants: bind the device to the Wii slot; set extension (None / Nunchuk / Classic) and sideways through `WiimoteSlotOptions`; for Touchscreen keep core IMU pointer off per the 2026-10-06 root-cause fix.

A pure function `PlaysAs.decompose(_:) -> (slotKind, extension, sideways)` and its inverse are unit-tested.

### 7.3 Touch Controls section (iOS only)

Renamed from "On-Screen Controls". The picker formerly "Overlay Style" is **Layout**: Auto, GameCube, Wii Remote. Description: "Which on-screen controller is drawn. Auto follows Player 1's Plays as." The section also holds Show Controls and Edit Layout. The underlying `ControllerManager.OverlayMode` and its UserDefaults key are unchanged.

### 7.4 Setup section

Background Input, Rumble, Motion Source (DSU), Controller Guide. The "More Controller Settings" level is removed; its remaining items (Advanced Motion, On-Screen Stick Feel) move to the player detail screen.

## 8. Error handling

- Arbiter claims when the core is not running are deferred, never dropped; a claim with no matching release is logged with its reason after 60 s in DEBUG builds.
- A `.cycle` item whose current value is not in its options renders the badge as "—" and the next activate selects the first option.
- Plays-as changes that fail at the bridge (slot busy, device vanished) revert the pill and show the in-game toast; nothing is left half-applied because the setter runs the inverse of the steps already taken.
- Leaf builders that throw (missing config key) render an empty section with a description row saying the setting is unavailable, rather than crashing settings.

## 9. Testing

Unit (PVUI-style XCTest in the app test target; new test files need `tuist generate` or they silently skip):

- `PauseArbiterTests`: first claim pauses, nested claims do not re-pause, out-of-order release, double release no-op, user claim survives menu close, deferred claim applies on start.
- `PauseMenuModelBuilderTests`: section and tile sets per platform and per system (GC vs Wii), cycle options, destructive flags, every tile has a description.
- `ControllerHubModelBuilderTests`: row pickers per title type, Pointer visibility, `PlaysAs` decompose/compose round trip.
- `SettingsSearchIndexTests`: generated index covers every root row title.
- `UILayerPauseCallsTest`: greps the Swift tree and fails if `TVEmulationBridge.pause()` or `.resume()` is called outside `PauseArbiter`.

Snapshots via the DEBUG gallery (`export TEST_RUNNER_` recipe in memory): pause grid iPhone portrait, iPad, tvOS; sidebar shell tvOS; hub row with three pills.

Device gates (Apple TV with Xbox pad; iPhone):

1. Open pause, enter Save States, back out, enter Settings, back out: the game never resumes until Resume.
2. Fast Forward tile cycles with a correct badge; a long-press of A opens the full list on both platforms.
3. Change Player 1 to Wii Remote + Nunchuk from the hub row without entering the detail screen; the game sees the nunchuk.
4. tvOS: opening press never immediately closes the overlay; Siri Remote Menu opens it; Xbox View opens it.

## 10. Rollout

PRs in order, each independently shippable:

1. `fix(pause): PauseArbiter` — arbiter, migrate all owners, delete `PauseOwnership`, tests.
2. `feat(ui): MenuKit + unified pause overlay` — kit, `MenuModel` changes, `.tiles` style, new `PauseMenuView`, delete tvOS hand-built menu.
3. `feat(settings): sidebar/tab-strip shell + four largest leaves on the engine`.
4. `feat(controllers): hub row with Device / Plays as / Pointer, Touch Controls rename`.
5. `refactor(settings): remaining leaves in batches` (several PRs).

## 11. Out of scope

- Siri Remote gyro or extra-button support.
- A native macOS target.
- Changes to the thin libretro wrapper or Provenance's own menus.
- Localisation of the new strings beyond English and the existing Japanese file.
