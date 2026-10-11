# tvOS redesign completion (design)

**Date:** 2026-10-11
**Status:** approved in chat by the owner (defaults accepted); this document is the written spec.
**Builds on:** `docs/superpowers/specs/2026-10-10-icube-design-language.md` (tokens, approved) and `docs/HANDOFF.md` (pause grid done on iFly's layout, library rail landed).
**Baseline commit:** `52f2704066` on develop.

## 1. Goal

Finish the iCube tvOS user interface so every screen reads as one designed product, with iFly's
consistency and iCube's own look: the display face, the token rows and tiles, the card focus effect,
the animated room. Then fix the owner's bug list and add the requested pause-menu features.

Success criteria, checked on the Apple TV 4K (3rd generation, 1080p) simulator and then on the
owner's device:

1. No screen shows the stock tvOS list, the white system focus capsule (outside system menus and
   context menus) or a stock `.navigationTitle`.
2. Every settings leaf has the iFly game-settings look (§4).
3. The library has an in-body title, shelf headers on every view, token card type, and the animated
   room by default (§5).
4. Pause: Save States, Cheats, Shaders and the confirm overlays match the pause grid (§6); the new
   tiles and the JIT chip are present.
5. The fast-forward tile cycles through every speed (§3).
6. The performance overlay is reachable from a tile and from the quick menu, and the floating
   speedometer button is gone (§3, §7).
7. Recording works on iOS and tvOS with the watermark (§8).
8. The shader picker no longer crashes after scrolling the previews for a while (§9).
9. iPhone and iPad touch screens are pixel-identical to today, except where a bug fix or a new
   pause tile applies to both platforms (the pause tile grid is shared).
10. Light and dark both pass; `check_design_tokens.py --check` passes with no file's count going
    up; `check_localized_keys.py --check` passes.

## 2. Work packages and order

Visible results first. Each package is its own worktree and branch, reviewed, then landed on
develop. No pull requests. No LLM trailers on commits.

| # | Package | Size | Visible result |
|---|---|---|---|
| 0 | Baseline screenshots | S | A screenshot set of every tvOS screen on develop, so later packages can be compared |
| 1 | Bug pass: fast-forward cycle, floating speedometer button | S | Fast forward cycles; no unreachable button |
| 2 | Settings leaves on the iFly look | M | Every leaf: title, section headers, icon rows, values, footers |
| 3 | Library polish | M | Title, shelf headers everywhere, card type, rail hairline, animated default |
| 4 | Pause completion | L | Save States, Cheats, Shaders, confirms restyled; new tiles; JIT chip |
| 5 | Quick menu | M | Siri Remote and pad gesture open a small pause-while-shown panel |
| 6 | Recording | M | Record tile on both platforms, watermark, tvOS files in Documents/Recordings |
| 7 | Shader preview crash | S–M | Root cause found and fixed, regression test |

Package 0 happens first and once. Packages 1 and 2 can run in parallel worktrees. Package 3
after 2 (it reuses the leaf scaffold's title component). Package 4 after 2 and 3. Packages 5, 6, 7
are independent of each other and of 3 and 4 but touch `PauseMenuView.swift`, so they land one at
a time.

## 3. Package 0 and 1: baseline and the two small bugs

### 3.1 Baseline

Build `iCube (NJB)`, `Debug (Non-Jailbroken)`, for the Apple TV 4K (3rd generation) (at 1080p)
simulator exactly as `docs/HANDOFF.md` describes. Capture, with `xcrun simctl io <udid> screenshot`:

- library: My Library, All Games, GameCube, Wii; rail collapsed and expanded; the View, Sort and
  Import menus open; the empty state (a fresh simulator has no games, so the empty state is the
  first capture and the others need a stand-in library; see 3.3)
- settings: the sidebar and every leaf, each scrolled to the top
- pause (`-ICubePausePreview`): the grid, Save States, Cheats, Shaders, Reset and Exit confirms
- light and dark for the library, one settings leaf and the pause grid

Store them under `docs/superpowers/baselines/2026-10-11-tvos/` with the simulator appearance in
the file name. They are committed; they are the before pictures for the whole effort.

A library stand-in for the simulator: the pause preview already fabricates a game. For package 0
the library captures use whatever `-ICubePausePreview`'s stand-in game provides; if the library
cannot show a stand-in, add a DEBUG-only `-ICubeLibraryPreview` launch argument that seeds the
library model with six fake entries (three GameCube, three Wii, two favourites, one recently
played) using the placeholder cover. It must never run outside DEBUG.

### 3.2 Fast-forward cycle (`PauseMenuView.swift`, `MenuScreen.swift`)

Symptom: the Fast Forward tile never goes past 2x. The option list is Off, 2x, 3x, 4x, 8x,
Unlimited (`PauseMenuModelBuilder.fastForwardOptions`). The binding reads
`fastForwardEnabled ? configuredFastForwardPercent : fastForwardOff` and writes through
`selectFastForwardSpeed(_:)`, which calls `TVEmulationBridge.setFastForwardSpeedPercent(_:)`.

Work: reproduce on the pause preview, then find where the chain loses the new value. The likely
places, to be confirmed rather than assumed: the bridge not persisting the percent before
`configuredFastForwardPercent` re-reads it; the tile activation on tvOS not using the `.cycle`
step path; `fastForwardEnabled` being reset by the appear path. Fix at the cause. Add a unit test
in `iCubeTests` that drives the binding through every option and asserts the sequence
Off → 2x → 3x → 4x → 8x → Unlimited → Off.

### 3.3 Floating speedometer button (`EmulationScreen.swift` tvOS pause cover, around line 540)

Remove the `ZStack` overlay button entirely. Its action (`refreshPerfOverlayState()`;
`showPerfOverlay = true`) becomes a pause tile "Performance HUD" (§6.4) and a quick-menu item (§7).
`PauseMenuActions` gains `openPerfOverlay`.

## 4. Package 2: settings leaves on the iFly look

Reference: iFly `GameSettingsView+tvOS.swift`, `TVPauseOptionRow.swift`, `TVPauseSheetScaffold.swift`
and the screenshot `ifly per game settings very nice looking.png`. Copy its structure and
consistency, not its colours or face.

### 4.1 Where the code is

Every migrated leaf renders through `MenuScreen` with `.list`, which on tvOS is `tvListBody`
(`MenuScreen.swift` ~800): a `ScrollView` of `ICubeRowButtonStyle` rows with accent-bar section
headers. The stock `List` is gone from that path as of `b7fdf8aa40`. If package 0's baseline still
shows a white capsule on a migrated leaf, that leaf or that row role bypasses `tvListBody`
(`.custom` rows, `tvSection`, or a hand-built leaf) and is fixed here.

Hand-built leaves to check: About (`AboutView`), Nearby (`NearbyView`), the controller hub and
player screens, and any leaf whose builder emits `.custom` rows. Each gets the same scaffold and
rows; a hand-built control keeps its logic and swaps its chrome.

### 4.2 Leaf scaffold (`ICubeLeafScaffold`, new, `MenuKit/`)

Every leaf pane on tvOS is:

```
title            (title role, display face, uppercase, title gradient)   e.g. "GRAPHICS"
subtitle         (tag role, uppercase, tracking)                          e.g. "SETTINGS" or the game title for per-game leaves
24
section header   (section role, accent bar)                               "VIDEO"
12
row
8
row
…
footer           (detail role, textSecondary)                            help text under the group
24
next section
```

Padding: 80 leading/trailing when the pane sits beside the sidebar, 40 top, 60 bottom. The pane
background is the room (`ICubeRoom(style: .gradient)`, already applied by `SettingsSidebarShell`).
The scaffold is the only thing that draws a title; `.navigationTitle` is removed from every tvOS
leaf. Pushed sub-leaves use the same scaffold with the parent's title as the subtitle.

The scaffold is also what the pause sub-screens use (§6.1), with the pause scrim instead of the
room.

### 4.3 Row anatomy on tvOS (`ICubeRowButtonStyle` label content, `MenuScreen.tvRowLabel`)

```
[ icon 44×44 badge, accent at 15 % fill, accent glyph ]  TITLE (nav role, uppercase)        value ›
                                                         description (detail, textSecondary)
```

- Row surface: `rowSurface`, radius 10, 1 pt `hairline`, min height 72, padding 16 h / 12 v.
- Focus: the existing 4 pt focus-gradient ring, glow, scale 1.04. No change to
  `ICubeRowButtonStyle`'s focus drawing.
- Within one section every row has an icon or none does. Builders that have icons on some rows
  get the missing ones (an SF Symbol per row; no row ships an empty badge).
- Trailing value rules (design language §3, Toggle / value):
  - toggle: `On` in accent, `Off` in textSecondary; no switch, no checkmark
  - cycle and compact picker: `‹ value ›` in accent; left/right step, select cycles
  - exploded picker (one row per option): the chosen option's row shows the value `Selected` in
    accent on a `selectedFill` surface; the other rows show no value. The checkmark glyph goes away.
  - stepper: the value in `tag`, with `‹ ›`
  - destination: a textTertiary chevron
  - action: nothing trailing; destructive actions tint icon and title `destructive`
- Description under the title, one line, truncated; the full text is in the footer or the info
  shelf, not wrapped in the row.

### 4.4 Section header and footer

Unchanged tokens (`tvListSectionHeader`): accent capsule, section role, textPrimary (today it is
textSecondary; switch to textPrimary so headers read as headers, matching the library shelf
headers). Footer: detail role, textSecondary, padded 16 h, 8 above.

### 4.5 Sidebar

Already on tokens. Two changes: the selected row's icon and label become accent (today only the
fill changes), and the sidebar's section headers switch to textPrimary with the same accent bar as
the pane. The sidebar is a `panel` with a hairline on its trailing edge; the `Divider()` goes.

### 4.6 Acceptance

- Screenshot every leaf again; none shows the stock list or capsule.
- `check_design_tokens.py --check` passes; the baseline count for `MenuScreen.swift` and
  `SettingsSidebarShell.swift` goes down, and their entries are lowered with `--update`.
- Existing `MenuScreen` tests (focus ids, picker explosion, compact picker, `settingsPaneBack`,
  `BackCoalescer`) stay green. New test: the scaffold's title and subtitle text for a leaf and for a
  pushed sub-leaf.
- iOS: no diff. The scaffold and row anatomy are behind `#if os(tvOS)` or the `controllerDriven`
  flag that is off on iOS.

## 5. Package 3: library polish

Reference: iFly `TVLibrarySidebar.swift`, `sidebar expanded.png`, and the two iFly library
screenshots. Code: `TVLibraryView.swift` (tvOS paths), `TVLibraryRail.swift`, `ICubeDesign+Room.swift`,
`LibraryAnimatedBackground.swift`.

1. **In-body title.** "iCube" in the title role, top of the content column, above the grid or the
   shelves, with the tag-role subtitle giving the current view and count: "ALL GAMES · 10",
   "GAMECUBE · 7", "MY LIBRARY". Same component as the leaf scaffold's title. Animates its text on
   view change with `easeInOut(0.2)`.
2. **Shelf headers everywhere.** My Library already uses `TVLibrarySectionHeader` per shelf. All
   Games and each platform view get one header above their grid ("ALL GAMES", "GAMECUBE", "WII"),
   so the eye lands on the same structure on every view. The empty and filtered-empty states get the
   title and a Row-styled action instead of `.borderedProminent`.
3. **Card type.** Title in body Semibold, 1 line, minimum scale 0.75, textPrimary; ID in tag inside a
   `rowSurface` capsule. Audit `gameGridItem` for any remaining hard-coded font or colour and move it
   to tokens. The card focus effect is frozen and untouched.
4. **Rail.** `panel` with a 1 pt hairline all round (today the edge is barely visible). Selected
   item: accent icon and label on `selectedFill`. The gap between the navigation group and the
   action group stays. The expanded width is 320 per the design language (today's expanded rail
   looks right; confirm the constant).
5. **Animated room by default.** The stored key is `library_background_style`
   (`ConfigInterfaceDefaultsKey.backgroundStyle`); `DefaultPreferences.plist` does not hold it, so
   the default lives in code in two places that must agree: `LibraryBackgroundStyle.from(stored:)`
   in `SettingsEnums.swift` (falls back to `.gradient`) and `TVLibraryView`'s `@AppStorage` default
   at line 266. Both become `.animated`, through one shared `LibraryBackgroundStyle.default`
   constant. tvOS already forces `.animated`. `EmulationQuiet` still swaps to the static gradient while a
   game runs. The iOS touch library changes only in that its default background is animated; the
   owner accepted this as part of "animated background default".
6. **Room motion.** The orbs drift; add a slow (90 s) hue rotation of the accent orb between the
   accent and the focus-gradient purple so the room is not static at a glance. Respect
   `accessibilityReduceMotion`: no drift, no hue rotation.

Acceptance: screenshots of all four views in light and dark; the card pixel test
(`ICubeDesignTests`, legacy copy versus modifiers) stays green; the design-token baseline for
`TVLibraryView.swift` and `TVLibraryRail.swift` goes down.

## 6. Package 4: pause completion

### 6.1 Sub-screens on the scaffold

- **Save States** (`PauseMenuView.swift` ~479–666, `SaveStatesBrowserView`, `SaveStateCardView`,
  `SaveStateFilmstripView`): the tvOS pane becomes the leaf scaffold (title "SAVE STATES", subtitle
  the game title) over the pause scrim. Slot cards are tiles (radius 16, hairline, `rowSurface`,
  tile focus): thumbnail, slot number as a tag capsule top-right, timestamp in detail. Save / Load /
  Delete become Rows under the selected slot. No hard-coded fonts remain.
- **Cheats** (`CheatsMenuView.swift` tvOS ~104–187): the scaffold; each cheat is a toggle Row
  (`On`/`Off` value); the type badge (Gecko / AR) is a tag capsule in the row; search stays as the
  rail-style inline field at the top.
- **Shaders** (`ShaderQuickPickerView.swift`): the scaffold; the hero becomes a tile with the preview
  as its art, the preset name as title, and two Rows under it: Enabled (toggle value) and
  Parameters (destination). The grid cards are tiles with the preview art, name in body, category
  in tag. The orange `Toggle` and the `.orange` palette go. Favourite and parameters glyphs stay as
  monochrome symbol buttons inside the tile.
- **Confirm overlays** (`confirmOverlay`): the panel keeps `MenuScreen(.list)` but drops the
  `count*110+40` height for an intrinsic-height `VStack`; the title and message use title/detail
  roles; rows are the §4.3 rows. Destructive rows tint `destructive`.

### 6.2 JIT chip

In the pause hero under the game ID: a tag capsule reading `JIT ON` (accent fill at 20 %) or
`INTERPRETER` / `CACHED IR` (rowSurface) from `JitManager.shared().acquiredJit` and the active CPU
engine (`PerformanceTuningState`'s resolution of the stored engine, extracted into a shared
`CpuEngine.resolved(acquiredJit:)` helper so both read the same rule). iOS compact header shows the
same chip after the game ID.

### 6.3 Audio, Performance, Upscaling tiles

Added to the Options section by `PauseMenuModelBuilder.make`, tvOS layout by `tvLayout`:

- **Upscaling**: `.cycle` over internal resolution multipliers Native, 2x, 3x, 4x, 6x (Dolphin
  `Config::GFX_EFB_SCALE`), applied live through a new `TVEmulationBridge.setInternalResolution(_:)`
  / `internalResolution` pair that reads and writes `Config::SetCurrent`. Long-press opens the
  Graphics leaf. Tile badge shows the current value.
- **Audio**: `.cycle` over volume 0, 25, 50, 75, 100 % through the existing audio volume config
  (`Config::MAIN_AUDIO_VOLUME`), with the badge "75 %". Long-press opens the Audio leaf. Mute stays
  a separate tile.
- **Performance**: `.action` opening the Performance Tuning leaf inside the pause settings sheet
  (`onShowSettings` with a jump-to id, the same mechanism `jumpToControllers` uses, generalised to
  `jumpToLeafID`). Badge shows the resolved engine short name ("JIT", "CIR", "INT").
- **Performance HUD**: `.toggle` over `showPerfOverlay` (replaces the floating button).

Settings profiles are out of scope for this pass (§11).

### 6.4 Acceptance

Pause preview screenshots of every pane in light and dark; `PauseMenuModelBuilderTests` and
`PauseTileLayoutTests` updated for the new tiles and run; a test that the JIT chip text follows the
resolved engine; a bridge test is not possible without the core, so the resolution and volume
setters are exercised by the existing debug-API settings route if present, otherwise by a manual
device check on the owner's list.

## 7. Package 5: quick menu

### 7.1 Behaviour

A small panel over the running game, not the full pause menu. Showing it pauses the core through
`PauseArbiter` (a `quickMenu` claim); hiding it releases the claim, so the game resumes unless
something else holds a pause. Items, each a tile: Fast Forward (cycle), Mute (toggle), Quick Save,
Quick Load, Screenshot, Performance HUD (toggle), and "Pause Menu" (opens the full menu, handing the
pause claim over). The panel is a `panel` centred at the bottom of the screen, tiles in one row,
tile focus style, Menu/B closes it.

### 7.2 Triggers

- **Siri Remote not bound to any player slot** (`ControllerManager`'s slot binding reports the
  remote as unbound): a short Menu press opens the quick menu; a long press (today's pause gesture
  in `PauseGestureTracker`) still opens the full pause menu. When the remote *is* bound to a player,
  nothing changes.
- **Any bound controller:** hold Options (the left centre button; `buttonOptions`) for 0.5 s. The
  hold is tracked by `PauseGestureTracker` beside the existing Menu gesture. A plain Options press
  still reaches the game.
- **iOS touch:** no new trigger. The panel is reachable from the top bar's existing quick controls;
  this package does not change iOS.

### 7.3 Code

`QuickMenuView.swift` (new) built on `MenuScreen(.tiles)` with a `QuickMenuModelBuilder` that reuses
the pause builder's Fast Forward, Mute, Quick Save, Quick Load and Screenshot items so the two menus
cannot drift. `EmulationScreen` presents it as an overlay, never as a `fullScreenCover`, so the game
stays visible dimmed behind the scrim. `CorePauseCallSitesTests` continues to enforce that no new
code pauses the bridge directly.

Acceptance: `PauseArbiter` tests for the claim handover (quick menu → pause menu → resume);
`PauseGestureTracker` tests for the Options hold and for the unbound-remote short press; simulator
screenshot; the owner's device check for the Siri Remote path, which the simulator cannot drive.

## 8. Package 6: recording

Reference: Provenance `PVRecordingManager.swift`, `PVCameraOverlayView.swift`,
`PVEmulatorViewController+Recording.swift`. iCube already has `ReplayKitManager.swift` (clip
buffering only).

- **Start/stop** through `RPScreenRecorder` on iOS and tvOS. The pause menu gets a "Record" tile
  (toggle; badge "REC" while recording, tinted `destructive`) in the Options section, and the quick
  menu gets the same item. The tvOS top-right status while recording is a small `REC ●` tag capsule
  in the game view's top trailing corner, in the design-language tokens.
- **Camera overlay** iOS only, front camera picture-in-picture in a corner, size and corner from
  settings as Provenance does. Off by default. tvOS has no camera.
- **Watermark**: a corner badge shown only while recording, bottom trailing: the iCube mark, a
  40×40 QR code for `https://icube-emu.com`, and "iCube" in the tag role, on a `panel` capsule. It is
  a normal view in the game container, so ReplayKit captures it. Setting "Recording watermark"
  (on by default) in the Interface leaf turns it off.
- **Output**: iOS, the ReplayKit preview sheet and then Photos, as Provenance does. tvOS,
  `stopRecording(withOutput:)` writes `Documents/Recordings/<GameID>-<timestamp>.mp4`, which the
  web UI and WebDAV already expose. A toast confirms the file name.
- **Settings**: Interface leaf gains a "Recording" group: camera overlay (iOS), corner, size,
  watermark.

Acceptance: `RecordingManager` tests with a fake recorder for start/stop/error paths and file
naming; a simulator screenshot of the watermark; the owner's device check for an actual recording
(ReplayKit does not record on the simulator).

## 9. Package 7: shader preview crash

Symptom: the Shaders picker crashes after browsing for a while. No Sentry issue matches a preview
crash (the open shader issues are core shader-cache crashes: ICUBE-EN, CW, C0, B1).

Method: `superpowers:systematic-debugging`. Reproduce on the simulator with the pause preview, with
the Metal validation and address sanitizer diagnostics on, scrolling the grid and opening
parameters repeatedly. Candidate causes to test, not to assume: each `renderPreviewSync` creating
its own `MTLCommandQueue` and device resources without release; `ShaderPreviewCache`'s slot
semaphore leaking on the timeout path (`asyncAfter` resume racing the render's resume); `CGImage`s
retained by both the cache and the view model; a `FilterChain` compiled per preview and never freed.
The fix lands with a test in `ShaderPreviewCacheTests` that pins the behaviour (slot count after
N timeouts, cache size after N previews).

## 10. Testing, gates and process

- Every package: tvOS compile (`xcodebuild … -destination generic/platform=tvOS`), the iOS test
  target for the touched classes (`make test TEST_ARGS=…`), `check_design_tokens.py --check`,
  `check_localized_keys.py --check`, `check_button_types.py`, screenshots on the Apple TV 4K
  (3rd generation) 1080p simulator in light and dark, compared with the package 0 baseline.
- One `xcodebuild` at a time; never `pkill xcodebuild`; `git checkout -- build/xcframework` before
  every commit; `tuist generate` after adding files.
- Review: Sonnet per task, Opus for the package, then land on develop. The owner tests on device
  after each package; the device-only checks are the Siri Remote quick menu, real recording, the
  fast-forward feel, and live resolution/volume changes.
- Memory and handoff: `docs/HANDOFF.md` gains a section per landed package.

## 11. Out of scope

- Settings profiles (named presets): separate spec.
- iPad with a controller (design language §5 item 4): after this effort.
- The iOS touch pause and library beyond the shared tile additions and the animated default.
- Dolphin core changes.
