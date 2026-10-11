# iCube handoff (2026-10-10)

This is the current state of the tvOS / iPad UI redo and the pause-lifecycle work, and the next steps. Read `AGENTS.md` first, then this file.

## What the owner wants (priority order)

1. **Fix platform switching in the tvOS library.** In `TVLibraryView.swift` the bottom bar offers All / GameCube / Wii (`LibraryPlatformFilterBar`, around lines 1630-1660). Switching platforms is broken on tvOS. In a screenshot with "Wii 1" selected, one game shows and the rest of the screen looks dimmed. The exact failure is not confirmed: reproduce it on the tvOS simulator first.
   - State lives at `@AppStorage("library_platform_filter") platformFilter`, line ~278.
   - The filter is applied at ~371 and ~2783.
   - The reset logic is at ~598 and ~1212.
   - Remote stepping is around ~2666-2687.
2. **Rebuild the tvOS library. This is what the owner will actually see.** The work so far changed almost nothing visible, and the owner is (rightly) unhappy about that.
   - Replace the top toolbar and the bottom filter bar with an iFly-style collapsible **left rail**: Search, My Library / platforms, Select, Import, View & Sort, Settings.
   - Rebuild the library as **sections**: Recently Played (`LastPlayedStore`), Favorites, All Games, then one section per platform.
   - Use the new design tokens (below).
   - Must keep: the `EmulationScreen` launch path, context-menu actions, long-press select, play/pause, and the GC handlers (`TVLibraryView.swift` ~686-690, ~1134-1169).
   - Reference implementation: iFly at `~/Workspace/Provenance/iFly/iFly`, file `TVLibrarySidebar.swift`.
3. **Then restyle the tvOS menus:** rows, tiles, pause, settings sidebar and controller hub. Spec §5 item 2; the code map is in `docs/superpowers/notes/2026-10-10-step2-surface-map.md`.
4. **Then iPad with a game controller:** the same look, switched on when a pad connects. Spec §5 item 4.

## Design language (approved by the owner)

- **Spec:** `docs/superpowers/specs/2026-10-10-icube-design-language.md`. Read the Decisions and Corrections at the end.
- **Step-1 plan, done:** `docs/superpowers/plans/2026-10-10-icube-design-module.md`, with execution notes at the end.
- **Design module, on develop** in `Source/iOS/App/Common/Swift/MenuKit/`:
  - `ICubeDesign.swift`:
    - type roles via `.icubeText(.title/.section/.nav/.body/.detail/.tag)`
    - `ICubeDesign.Spacing` / `Radius` / `Line` / `Motion`
    - the `@Entry var icube` environment value
    - the legacy menu-kit vars
  - `ICubeDesign+Color.swift`: `ICubeDesign.color(.accent/.rowSurface/.selectedFill/.hairline/.textPrimary/...)`, `roomStops`, `focusGradient`, `titleGradient`.
  - `ICubeDesign+Focus.swift`:
    - `.icubeCardFocus` / `.icubeCardArtFocus`, the library card effect
    - `ICubeRowButtonStyle`, `ICubeTileButtonStyle`, `.icubePanel()`. These are not used by the app yet.
  - `ICubeDesign+Room.swift`: `ICubeRoom(style:)`, the library background.
- **Display face:** M PLUS Rounded 1c (PostScript `RoundedMplus1c-Medium` / `-Bold`), in `Common/Resources/Fonts/`. Registered with `UIAppFonts` in **both** `DolphiniOS/Info.plist` and `DolphiniOS/Info-TV.plist`; tvOS uses the TV one.
- **Lint ratchet:** `Source/iOS/App/Project/Scripts/check_design_tokens.py --check`. It runs in `tests.yml` and fails if any file gains hard-coded fonts, radii, line widths or colours. After you reduce a file's count, lower its baseline with `--update`.

### Decisions already made
- **Scope:** tvOS, and iPad only when a controller is connected. Touch iPhone and iPad must not change. Gate shared views with a runtime environment flag that is on for tvOS and off for iOS, rather than `#if os(tvOS)`, so the iPad pad mode can reuse the same code.
- Cards rest at exactly 2° and tilt to 5° when focused.
- If a body `Menu` does not present on tvOS, View & Sort can be panel sheets of rows.

## Pause / lifecycle (done, on develop)

- `PauseArbiter` owns pausing. Do not call `TVEmulationBridge` pause or resume directly from UI code; `CorePauseCallSitesTests` and `UILayerPauseCallsTests` enforce this.
- The owner still owes a device test checklist for it: lock/unlock, app switcher, Control Center, calls, a Bluetooth pad sleeping, and the tvOS Home button.

## Build, test, ship

All commands run from `Source/iOS/App`.

- **Generate the project:** `PATH=/opt/homebrew/bin:$PATH tuist generate --no-open`. Run it after adding any file, or new tests silently don't run. `/usr/local/bin/tuist` is a broken shim.
- **iOS tests:** `make test TEST_ARGS="-only-testing:iCubeTests/<Class>"`. This uses the iPhone 17 Pro simulator. The first build in a fresh checkout also builds the core simulator slice, which takes ~30 min.
- **tvOS compile:**

  ```sh
  xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" -destination generic/platform=tvOS -derivedDataPath build-Xcode-tvos CODE_SIGNING_ALLOWED=NO
  ```

- **Release gate:** `make gate-release` builds iOS, then tvOS.
- **CI checks:**
  - `python3 Project/Scripts/check_localized_keys.py --check`. Every `L("…")` key needs `"key" = "key";` entries in `Common/UI/Localization/{en,ja}.lproj/Core.strings`.
  - `check_button_types.py`
  - `check_design_tokens.py --check`
- **There is no tvOS test target.** `iCubeTests` is iOS-only. Check tvOS UI on the simulator or a device; focus behaviour is not visible in static renders.

## Traps

- **Tracked xcframework slices.** Local builds rewrite the tracked `build/xcframework/` slices. Run `git checkout -- build/xcframework` before every commit, and never stage them.
- **Core.strings.** Builds add an `"IR Sensitivity" = "IR Sensitivity";` line to Core.strings (en and ja), because that key is missing on develop. Commit it once as its own fix, or leave it unstaged.
- **Builds.** Run one `xcodebuild` at a time, and never `pkill xcodebuild`. Watch for `pgrep -f xcodebuild` matching its own command line.
- **Git worktrees of this repo.** It is a submodule of Provenance, so after `git worktree add`, run `git config --file <gitdir>/worktrees/<name>/config.worktree core.worktree <abs path>`. Then check that `git rev-parse --show-toplevel` is the worktree before committing; otherwise `git add` stages thousands of deletions.
- **tvOS focus in SwiftUI.**
  - A `List` row is one focus target, and `Menu` / `Picker` have no tvOS presentation.
  - Buttons need `.focusEffectDisabled()` and a custom style, or you get the white system capsule.
- **Process.** No PRs: reviewed work lands directly on `develop`. Commit messages have no AI/LLM trailers. The owner tests on device.

## Update: tvOS pause menu redone (develop 0e49340a2b)

This screen is done and done the way the owner wants. Use it as the reference for the look.
- **Layout (iFly's):**
  - Hero column: cover, PAUSED, display-face title, game ID.
  - Primary row: Resume / Save States / Reset / Quit.
  - A 4-column Options grid, then a help bar.
  - Grouping comes from `PauseMenuModelBuilder.tvLayout`.
  - `MenuScreen.tvTilesBody` draws a **headerless section as the tall primary row**.
- **Style:**
  - Monochrome glyphs. Only destructive tiles are red, via `ICubeDesign.color(.destructive)`.
  - Values are inline in accent: "MUTE: OFF".
  - Labels use the `nav` role, uppercase.
  - Single-word labels shrink instead of wrapping mid-word.
- **New pieces you can reuse:**
  - `ICubeDesign.symbolFont(.tilePrimary / .tile / .shelf)` for SF Symbol sizes, which keeps the lint happy.
  - `ICubeTileButtonStyle(isFocusedOverride:minHeight:)`.
  - `InfoShelf(text:value:title:icon:)`.
- **Everything above is tvOS-only.** iPhone and iPad pause are unchanged.

### Fast visual check without a game
Debug builds launched with `-ICubePausePreview` open the pause menu on a stand-in game (`TVRootView.swift`). Copy the pattern for other screens, e.g. a library preview.

```sh
xcodebuild build -workspace iCube.xcworkspace -scheme "iCube (NJB)" -configuration "Debug (Non-Jailbroken)" \
  -destination "platform=tvOS Simulator,id=<udid>" -derivedDataPath build-Xcode-tvsim \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=""
xcrun simctl install <udid> build-Xcode-tvsim/Build/Products/*appletvsimulator/iCube*.app
xcrun simctl launch <udid> com.joemattiello.iCube-debug -ICubePausePreview
xcrun simctl io <udid> screenshot /tmp/shot.png
```

- Use the "Apple TV 4K (3rd generation) (at 1080p)" simulator; it matches the owner's 1920×1080 screenshots.
- `-derivedDataPath build-Xcode-tvsim` is not in `.gitignore` yet. Don't commit it; add it to the ignore file.

### Still on the old look (pause area)
These are the next things to restyle, in this style:
- **Pause → Save States pane:** the tvOS hand-built part of `PauseMenuView.swift` is ~:479-666, with ~28 hard-coded fonts and colours.
- **Pause → Cheats:** `CheatsMenuView.swift`, tvOS layout ~:104-187.
- **Pause → Reset / Exit confirm overlays:** `PauseMenuView.confirmOverlay`. They use a tvOS `MenuScreen(.list)` with a `count*110+40` height that must track the row height.
- **Every tvOS `List` screen** (settings leaves, controller hub) still shows the white system focus capsule. The tvOS row code is `MenuScreen.tvRow` / `tvSteppedRow`. The full map is in `docs/superpowers/notes/2026-10-10-step2-surface-map.md`.
  - **Rule from the map:** keep iPhone and iPad touch pixel-identical. Gate the new look on tvOS, or later on a `controllerDriven` environment flag for iPad with a pad.

### Unverified
- `PauseMenuModelBuilderTests.test_tvLayout_primaryRowThenOptions_keepsEveryTileOnce` (new) and the updated `PauseTileLayoutTests` (tv columns 6 → 4) have not been run. Run:

  ```sh
  make test TEST_ARGS="-only-testing:iCubeTests/PauseMenuModelBuilderTests -only-testing:iCubeTests/PauseTileLayoutTests"
  ```

- The uppercase-title fix in the pause hero is in the last commit. It compiled for iOS but was not screenshotted on tvOS.
- `"IR Sensitivity"` is now in Core.strings (8c440ddc1a), so builds no longer leave that diff behind.
