# WS-6: `SettingsRootView.swift` split map

`Source/iOS/App/Common/UI/Settings/SwiftUI/SettingsRootView.swift` was 5365 lines before this
split. It has been broken into 24 files, all in the same directory
(`Source/iOS/App/Common/UI/Settings/SwiftUI/`). This was landed as a **pure move**: every line of
code kept its exact text and relative order within its new file. The only textual changes are six
`private` → (default `internal`) access-level widenings, listed at the bottom, which were mechanically
required so that helper types used from more than one of the new files stay visible across the
split. No renames, no reformatting, no logic changes.

Old line numbers below refer to `SettingsRootView.swift` **as it existed at develop commit
`f6d94a9f1a`**, immediately before this split.

## Where each symbol went

| Old symbol / section | Old line range | New file |
|---|---|---|
| Header comment + imports | 1-20 | `SettingsRootView.swift` |
| `ConfigSynced` (ViewModifier) + `View.configSynced()` | 21-39 | `SettingsSharedComponents.swift` |
| `SettingsRootView` struct (body, root `List`, pause-menu-style content) | 40-522 | `SettingsRootView.swift` |
| `// MARK: - Motion Settings (DSU)` + `MotionSettingsView` | 523-602 | `ControllersRootView.swift` *(relocated — see below)* |
| `extension SettingsRootView where Background == EmptyView` | 603-611 | `SettingsRootView.swift` |
| `SettingsPage` enum | 612-616 | `SettingsRootView.swift` |
| `SettingsSubMenuView` | 617-780 | `SettingsRootView.swift` |
| `SettingsMenuRow` | 781-830 | `SettingsRootView.swift` |
| `ConfigRootView` | 831-865 | `SettingsCategoryHubs.swift` |
| `GraphicsRootView` | 866-888 | `SettingsCategoryHubs.swift` |
| `// MARK: - Controllers (single page)` + `ControllersRootView` | 889-1347 | `ControllersRootView.swift` |
| `TouchIRMode` enum + `TouchIRModePicker` | 1348-1364 | `ControllersRootView.swift` |
| `DebugRootView` | 1365-1592 | `DebugRootView.swift` |
| `AboutLogoAnimationStyle` + `AboutView` | 1593-1736 | `AboutView.swift` |
| `// MARK: - Config General (wired)` + `ConfigGeneralView` | 1737-1858 | `ConfigGeneralView.swift` |
| `Region` enum + `SpeedLimitPicker` + `FastForwardSpeedPicker` + `FallbackRegionPicker` | 1859-1912 | `ConfigGeneralView.swift` |
| `// MARK: tvOS-friendly selectable row` + `SelectRow` | 1913-1938 | `SettingsSharedComponents.swift` *(widened)* |
| `// MARK: tvOS fallback for sliders` + `TVIntStepper` | 1939-1983 | `SettingsSharedComponents.swift` |
| `// MARK: Tooltip helper` + `HelpButton` + `HelpSheetButton` | 1984-2017 | `SettingsSharedComponents.swift` *(both widened)* |
| `// MARK: - Performance Tuning (wired)` + `PerformanceTuningView` | 2018-2541 | `PerformanceTuningView.swift` |
| `// MARK: - Config Advanced (hardware overrides)` + `ConfigAdvancedView` | 2542-2614 | `ConfigAdvancedView.swift` |
| `RecommendedBadge` + `settingsCaption` + `settingsNavCaption` + `CpuEngine` enum + `CpuEnginePicker` | 2615-2721 | `PerformanceTuningView.swift` |
| `// MARK: - Performance A/B harness` + `PerfSnapshot` + `PerfAB` + `PerformanceABView` | 2722-2903 | `PerformanceABView.swift` |
| `// MARK: - Config placeholders` + `ConfigInterfaceView` | 2904-3006 | `ConfigInterfaceView.swift` |
| `ConfigAudioView` | 3007-3098 | `ConfigAudioView.swift` |
| `BackendPickerView` | 3099-3138 | `ConfigAudioView.swift` |
| `ConfigGameCubeView` | 3139-3205 | `ConfigGameCubeView.swift` |
| `GCLanguagePicker` | 3206-3221 | `ConfigGameCubeView.swift` |
| `ConfigWiiView` | 3222-3373 | `ConfigWiiView.swift` |
| `WiiLanguagePicker` + `WiiAudioModePicker` + `WiiSensorBarPosPicker` | 3374-3412 | `ConfigWiiView.swift` |
| `#if USE_RETRO_ACHIEVEMENTS` + `ConfigAchievementsView` | 3413-3558 | `ConfigAchievementsView.swift` |
| `// MARK: - Graphics General (wired)` + `GraphicsGeneralView` | 3559-3751 | `GraphicsGeneralView.swift` |
| `// MARK: - Graphics enums and pickers` + `GraphicsBackend`/`AspectRatio`/`TargetFPS`/`InternalScale`/`ShaderCompileType` enums + `GraphicsBackendPickerView`...`GraphicsShaderTypeView` | 3752-3874 | `GraphicsGeneralView.swift` |
| `// MARK: - Graphics placeholders` + `GraphicsEnhancementsView` | 3875-4113 | `GraphicsEnhancementsView.swift` |
| `AnisotropyPicker` + `MSAAPicker` + `OutputResamplingPicker` + `EfbScalePicker` | 4114-4186 | `GraphicsEnhancementsView.swift` |
| `GraphicsHacksView` | 4187-4455 | `GraphicsHacksView.swift` |
| `TextureCacheAccuracyPicker` + `ViSkipModePicker` + `BBoxSyncModePicker` + `MetalTriStatePicker` | 4456-4514 | `GraphicsHacksView.swift` *(`MetalTriStatePicker` widened)* |
| `GraphicsAdvancedView` | 4515-4738 | `GraphicsAdvancedView.swift` |
| `#if os(tvOS)` typealias / `#else` + `ControllersMappingView` struct / `#endif` | 4739-4765 | `ControllersMappingView.swift` |
| `// MARK: - Audio FX Chain Editor (iOS)` + `FXChainEditor` | 4766-4948 | `AudioEffectEditors.swift` |
| `CoreAudioDSPEditor` | 4949-5046 | `AudioEffectEditors.swift` |
| `#if os(iOS)` + `SafariView` | 5047-5054 | `SafariView.swift` |
| `extension View { networkURLContextMenu }` | 5055-5078 | `SafariView.swift` |
| `WiiAspectRatioPicker` | 5079-5089 | `ConfigWiiView.swift` *(relocated — see below)* |
| `EnhancedMotionControlsView` | 5090-5243 | `EnhancedMotionControlsView.swift` |
| `HorizontalMotionPicker` | 5244-5272 | `EnhancedMotionControlsView.swift` |
| `#if os(iOS)` + `HideListBackgroundIfAvailable` + `#endif` | 5273-5280 | `SettingsRootView.swift` *(relocated — see below)* |
| `// MARK: - DSU Bonjour Discovery` + `DSUDiscoveredServer` + `DSUDiscoveryBrowser` + its two `NetService*Delegate` extensions | 5281-5365 | `DSUDiscovery.swift` |

## New file line counts

```
   27  AboutView.swift
  301  AudioEffectEditors.swift
  166  ConfigAchievementsView.swift
   93  ConfigAdvancedView.swift
  152  ConfigAudioView.swift
  103  ConfigGameCubeView.swift
  196  ConfigGeneralView.swift
  123  ConfigInterfaceView.swift
  222  ConfigWiiView.swift
   47  ControllersMappingView.swift
  576  ControllersRootView.swift
  105  DSUDiscovery.swift
  248  DebugRootView.swift
  203  EnhancedMotionControlsView.swift
  244  GraphicsAdvancedView.swift
  332  GraphicsEnhancementsView.swift
  336  GraphicsGeneralView.swift
  348  GraphicsHacksView.swift
  202  PerformanceABView.swift
  651  PerformanceTuningView.swift
   52  SafariView.swift
   78  SettingsCategoryHubs.swift
  739  SettingsRootView.swift
  144  SettingsSharedComponents.swift
```
(Sum exceeds the original 5365 because 23 of the 24 files carry their own copy of the original
top-of-file import block — see "Known follow-up" below.)

## Relocations (code physically moved to a different neighborhood than its original position)

Three private helpers were used only by code that ended up far away in the original file. Rather
than widen their access, they were moved bodily to sit next to their one caller — this is a real
move, not a rewrite, and is the only case in the diff where a symbol's line-order relative to its
immediate original neighbors changed:

- **`MotionSettingsView`** (orig. 523-602, `private struct`) — its only call site is
  `ControllersRootView`'s "Advanced Motion Settings" row (orig. line 1049). Moved into
  `ControllersRootView.swift`, still `private`.
- **`WiiAspectRatioPicker`** (orig. 5079-5089, `private struct`) — its only call site is
  `ConfigWiiView`'s widescreen row (orig. line 3247). Moved into `ConfigWiiView.swift`, still
  `private`.
- **`HideListBackgroundIfAvailable`** (orig. 5273-5280 incl. its `#if os(iOS)`/`#endif` wrapper,
  `private struct`) — its only call site is `SettingsSubMenuView` (orig. line 698). Moved into
  `SettingsRootView.swift`, still `private`.

## Access-level widenings (`private` → default `internal`)

These six declarations are used from more than one of the new files (they were already used from
multiple, distant places inside the single original file — the split just made the file boundary
visible). Each had its leading `private` keyword dropped; nothing else about them changed. All are
still declared exactly once, in `SettingsSharedComponents.swift` except `MetalTriStatePicker`,
which stays with its sibling pickers in `GraphicsHacksView.swift` because it's also used by
`GraphicsAdvancedView.swift`:

1. `ConfigSynced` (+ its `View.configSynced()` extension method) — used by nearly every Config/
   Graphics/Performance page (12 call sites across the original file).
2. `SelectRow` — the shared tvOS-friendly checkmark row, used by 8+ different picker views spread
   across Controllers, Config, Graphics, and Motion.
3. `HelpButton` — used by both the Config General pickers and the Graphics target-FPS picker.
4. `HelpSheetButton` — widened alongside `HelpButton` for consistency (only one call site, so this
   one was not strictly required).
5. `MetalTriStatePicker` — used by `GraphicsAdvancedView`, declared next to `GraphicsHacksView`'s
   other (still-private) pickers.
6. `TouchIRMode` enum + `TouchIRModePicker` — missed in the first pass of this audit. Both are
   declared in `ControllersRootView.swift` (their main consumer) but are also used by
   `EnhancedMotionControlsView.swift`. Caught by the mandatory build gate (see below), not by static
   analysis, and fixed in a follow-up commit on top of the pure-move commit.

## Post-split build-gate fixes (follow-up commit, not part of the pure-move commit)

The mandatory `xcodebuild` gate caught two real problems the line-based audit above missed. Both
are fixed in a small follow-up commit so the pure-move commit stays exactly that:

- **Name collision:** the shared, now-`internal` `SelectRow` collided with an unrelated, pre-existing
  `private struct SelectRow` in `Source/iOS/App/Common/Swift/Shaders/ShaderSettingsView.swift`
  (`invalid redeclaration of 'SelectRow'`). That file is untouched by WS-6 and out of scope, so the
  shared one was renamed to `SettingsSelectRow` across its definition
  (`SettingsSharedComponents.swift`) and all 38 call sites in `ControllersRootView.swift`,
  `ConfigGeneralView.swift`, `PerformanceTuningView.swift`, `ConfigAudioView.swift`,
  `ConfigGameCubeView.swift`, `ConfigWiiView.swift`, `GraphicsGeneralView.swift`,
  `GraphicsEnhancementsView.swift`, and `GraphicsHacksView.swift`. `ShaderSettingsView.swift`'s own
  `SelectRow` is untouched.
- **Missed cross-file dependency:** `TouchIRMode` and `TouchIRModePicker` (see item 6 above) needed
  the same `private` → internal widening as the other shared helpers.

No other symbol needed a scope change; every other `private` type's use sites all landed inside its
own new file. A repo-wide grep for `SelectRow`/`HelpButton`/`HelpSheetButton`/`ConfigSynced`/
`configSynced`/`MetalTriStatePicker`/`TouchIRMode`/`TouchIRModePicker` declarations outside this
directory turned up no other collisions.

## Known follow-up (not done in this split, intentionally out of scope for a pure move)

- **Import trimming.** Every new file was given the exact same import block as the original
  (`SwiftUI`, `UIKit`, `CoreHaptics`, `QuartzCore`, `PVWebServer`, `PVHelp`, conditionally
  `SafariServices`/`AudioToolbox`/`GameController`, `Foundation`). Most files only need a subset.
  Trimming this per-file is safe, mechanical, and deliberately deferred to a later commit so the
  pure-move commit's diff is reviewable as "code moved, nothing else changed."
- `SettingsCategoryHubs.swift` holds the two-line-item `ConfigRootView` / `GraphicsRootView` hub
  pages, which the later "flatten the root into ~20 sections" commit is expected to fold away or
  replace.

## Root restructure + search (follow-up commit, after the fix commit)

`SettingsRootView.swift`'s `settingsContent` (the root `List` shown from the Library, not the
separate `pauseMenuStyleContent`/`SettingsSubMenuView` surface used by `SettingsPage`, which is
untouched) was flattened from 5 broad hubs (Config/Graphics/Controllers/Debug + a version/about
section) into ~14 specific destinations under 6 headers — General, Audio, GameCube & Wii, Graphics,
Input, System — plus the unchanged About/Blog/Help/Network section. This matches Provenance's
long-scroll-with-many-sections shape rather than iFly's tabbed sidebar (see the WS-6 report for the
reasoning). `ConfigRootView`/`GraphicsRootView` still exist, still used by the pause-menu-style
surface; they're just no longer how the main Settings screen is entered.

The row list is now data-driven (`SettingsEntry`/`SettingsListSection`, both in
`SettingsRootView.swift`) instead of a static tree of `NavigationLink`s, specifically so it can be
filtered. `SettingsEntry.destination` is `AnyView` — a deliberate, scoped use of type erasure to
hold ~14 unrelated destination view types in one filterable array; not a pattern to copy elsewhere
in the app.

`.searchable` is applied to the root list on iOS/iPadOS only, gated behind `#if os(iOS)`, filtering
`settingsSections` by title substring, plus a small `keywords: [String]` list on the pages with the
least discoverable settings (Performance Tuning, Graphics Enhancements/Hacks/Advanced, Debug — terms
like "anisotropic", "vsync", "fastmem", "jit"). This is scoped, not full-page content indexing: it
surfaces the ~5 pages most likely to hide what someone actually typed, not every control on every
page. tvOS deliberately gets no search — remote text entry is slower than flipping through a dozen
rows with the D-pad, the same call iFly's `SettingsView+Search.swift` makes for the same reason.

## Pause menu (PauseMenuView.swift, shared with WS-4 — structural changes only)

Two changes, both additive:

- **Quick actions.** Mute (`DOLConfigBridge.audioVolume`/`setAudioVolume:`, remembering the
  pre-mute level in `UserDefaults` so unmute restores it) and Fast Forward
  (`TVEmulationBridge.toggleFastForward`/`isFastForwardEnabled`, the same bridge calls
  `EmulationScreen.swift`'s top-bar button already uses) — the two things people actually reach for
  mid-game without wanting to leave the pause menu. On iOS they're two more `IOSMenuItem` entries
  (no new type needed, already in a `ScrollView`d `LazyVGrid`). On tvOS they're two new rows via a
  new `tvMenuToggleRow` helper, added only for these two rows — the other rows are untouched,
  deliberately not refactored to share it.
- **tvOS overflow fix.** `tvMainMenu`'s row list was a bare `VStack` in a fixed-width column with no
  scroll container — exactly the shape that silently goes unreachable once enough rows land (my two
  quick actions, WS-4's continuity card, whatever comes after). Wrapped it in a `ScrollView`; no
  other structural change.
- Added `FocusField.mute` / `.fastForward` cases (additive; WS-4's own case can sit alongside
  without conflict).
