# iCube handoff (2026-10-10)

## Latest play-controls checkpoint — October 20 late evening

Accepted source `a0fbc29b80` is pushed. Final iOS/tvOS SDK builds pass; full iOS suite **2,229 passed, five opt-in skips, zero failures (2,234 total)**; focused layout/cache **38/38**; native simulator phone **7/7**, iPad **7/7**, tvOS **2/2**. Portrait toolbar is 72 points excluding safe area with 44-point targets. Final native screenshots were inspected; compact landscape metadata and selection indicator no longer overlap. Hosted CI `39535150389` passed on `0964b2aba9`; exact-source run `39538314157` also passed on `a0fbc29b80`. [Current evidence](app-store/release-evidence/2026-10-20-play-controls.md).

Signed DEV build `1792552677` built, passed signature/SwiftUI/core guards and is installed on the owner's iPad with its existing data preserved. The initial new-controls physical run stopped before Exit at no-JIT hittability; a narrow landscape/wait harness correction builds. Coordinated physical Exit/Cancel, mute and history save/load acceptance remains pending, followed by fresh matching iOS/tvOS archives and authorized TestFlight uploads. No new upload is claimed. Do not upload superseded `1792538716` archives. Production paused Sonic session must remain untouched. Continue from the ignored plan ledger rather than restarting completed implementation tasks.

## Active release continuation — October 20 evening

Checkpoint `eadbfbb850` is pushed. Both iOS/tvOS App Store archives `1792538716` succeed and pass optimized SwiftUI metadata, signature and retired adaptive-resolution core checks; neither was uploaded. They are superseded by the owner's newly reported mute bug and approved play-toolbar/save-history scope. The full iOS suite at that checkpoint passes **2,132 tests, six opt-in snapshots skipped, zero failures**. The ordinary real-game physical iPad Exit path now passes: all three actions visible/hittable and Cancel/reopen twice; DEV left paused, no quit/save/reset action selected. [Physical evidence](app-store/release-evidence/2026-10-20-ipad-pause-confirmation.md).

The owner reports better performance in the current DEV install; the screenshot counters are a spot observation, not a matched Release benchmark. The saved-Auto mechanism is proven source behavior; the owner's Native1× install still needs a controlled comparison. Telemetry sampling and the older-OS startup metadata defect are fixed/SDK verified; live telemetry delivery and older-device launch acceptance remain open. [Audit](app-store/release-evidence/2026-10-20-performance-source-audit.md).

Owner approved the [labeled toolbar / save history design](superpowers/specs/2026-10-20-play-toolbar-save-history-design.md) and [implementation plan](superpowers/plans/2026-10-20-play-toolbar-save-history.md), explicitly requesting subagents and compact iPhone/iPad portrait. Quick Load chooses latest manual state then automatic resume. New history keeps ten unkept saves; existing slots and kept states are protected. Controls visibility moves under Controller; direct Pause and labeled Shaders replace ambiguous icons/indirection. Mute source diagnosis: settings changed Config without applying live backend gain; app bridge patch and real hardware-free DSP tests are being validated. Use this plan's ignored ledger `.superpowers/sdd/2026-10-20-play-toolbar-save-history/progress.md` to resume, not older task counts. Fresh candidate numbers/archives, portrait renders, physical fixed-build checks and both TestFlight uploads remain required.

## Urgent iPad Exit confirmation — October 20, 2026

Physical screenshot at 6:57 p.m. Eastern confirms current TestFlight's Exit panel has title/warning but no visible Cancel/Quit/Save & Quit controls. [Source fix and pending runtime acceptance](app-store/release-evidence/2026-10-20-ipad-pause-confirmation.md): replace the iOS intrinsic-height GeometryReader grid with eager modal actions and overflow scrolling; preserve tvOS and stop/save handlers. Swift parsing and independent source review pass; SDK build, hosted regression and fixed-build rendered checks remain blocked by severe host load/CoreSimulator stalls and suspended processes. No verified fix or upload is claimed. Owner's physical iPad is available; direct screenshot/config reads work but Device Hub touch control requires iPadOS 27+. Its global resolution is already Native1× and per-game INIs are empty; see [performance source audit](app-store/release-evidence/2026-10-20-performance-source-audit.md).

## Current TestFlight crash blocker — October 20, 2026

[Sentry audit](app-store/release-evidence/2026-10-20-sentry-crash-audit.md): build `1792472425` has **75 fatal reports / 11 distinct Sentry users**. Four groups share a Swift symbolic-reference / metadata failure (74 reports; inspected on iOS 17/18 near startup), plus one fatal hang. Map the shipped binary's symbolic reference and inspect older-OS availability before promoting another release. The CloudKit startup group is separate: 101 sideload reports / 14 users, not part of that TestFlight count. No fix or Sentry resolution is claimed.

## Library release blockers — October 20, 2026

Latest SDK evidence: [library verification](app-store/release-evidence/2026-10-20-library-sdk-verification.md). Integrated iOS/tvOS Debug builds pass. The full iOS suite reports **2,124 passed, six opt-in snapshots skipped, zero failures**, including eight metadata-service tests, 32 store tests and the now-included Objective-C++ invalid-game regression. Rendered tvOS title/tag Save/Cancel/reopen/relaunch and explicit selection pass. The corrected Back-navigation check, cover set/reopen/clear and oversized-cover checks pass. The card now respects small custom artwork, with a rendered card regression passing; the owner then identified the modal as visually unusable despite behavioral passes. The [fullscreen layout follow-up](app-store/release-evidence/2026-10-20-tvos-editor-presentation.md) replaces the transparent Form with an opaque room, artwork column, readable fields and pinned actions; targeted Back/cover/layout checks pass, and the focused-prompt pixel regression fails before the ink fix and passes after it. Final screenshots are recorded; physical-device review remains open; speculative Back-handler changes were reverted. The new library wave remains unuploaded.

CI checkpoint `d8bcdee056` is pushed. Core CI failed from disk exhaustion; the new 20GiB preflight reports capacity before a long rebuild. Unit CI needs administrator-authorized Xcode first-launch setup (noninteractive sudo requires a password). Provenance's isolated PVUI SDK build now reaches a changed BuildEnvPlugin trust prompt; the Mac must be unlocked for UI review. The counterpart is pushed in draft [Provenance PR #3753](https://github.com/Provenance-Emu/Provenance/pull/3753), with 151 fresh host tests passing; preserve unrelated parent work. These are open verification/distribution gates, not test passes.

Owner-confirmed scope: **custom titles, covers and classification tags**, plus manual nearby browse/import **and automatic ROM mirroring nearby with both apps open**. Source/test checkpoint `9ef37f11e9` is pushed to `develop`. The working tree was clean after that push. Previous TestFlight build `1792472425` is live on both platforms; the new library wave has **not** been uploaded.

Start with [editing integration evidence](app-store/release-evidence/2026-10-20-library-editing-integration.md), [sync audit](app-store/release-evidence/2026-10-20-library-sync-audit.md) and [nearby adapter evidence](app-store/release-evidence/2026-10-20-nearby-mirror-adapters.md). Targeted native regressions pass. Integrated SDK builds, rendered editor/focus acceptance, real-device convergence and complete Provenance receiver acceptance remain pending. The source checkpoint is not a candidate acceptance claim.

The generated workspace resolves PVSyncRules **1.0.2**, commit `692ca3a1a84cb713c42bf775d5558c97d0bf05d3`. No new C++/core work is required for this wave. Provenance counterpart work is in the parent repository and needs separate review/commit/build evidence; preserve unrelated parent edits. ROM copying does **not** establish title/cover/tag convergence: [cross-app metadata proposal](superpowers/specs/2026-10-20-cross-app-library-metadata-proposal.md) records the remaining contract and identity work.

## App Store release planning — 2026-10-19

Latest owner decision: remove adaptive internal-resolution control, including thermal EFB changes; retain manual scales/Auto (Fit Window), Native default, and CPU/VI adaptation. [Removal plan](superpowers/plans/2026-10-19-remove-adaptive-resolution.md). Implemented and locally verified; shipping/device gates remain open.

Post-removal results: all four packaged device/simulator cores and both simulator apps' embedded/installed cores pass the retired-content check. iOS passes 97 targeted settings tests; tvOS passes 25 UI tests (19 captures, six behavioral checks) plus a final three-test fresh-core rerun. Zero failures/skips. [Hashes/counts](app-store/release-evidence/2026-10-19-resolution-verification.json). APPSTORE/device performance and legacy-config thermal/load checks remain open.

Latest settings follow-up: the truncated User Folder path, missing Audio picker context and poor Controllers-title contrast are fixed locally. Three new tvOS regressions pass, including focus/Back and full-path Menu/Done dismissal; screenshots manually inspected. iOS/tvOS NJB Debug builds pass; the full iOS suite passes 1,970 tests with six opt-in snapshot tests skipped and zero failures. [Evidence/counts](app-store/release-evidence/2026-10-19-settings-context-verification.json). User Folder is now a read-only details destination in every diagnostics scope (including store environment-only), with Copy on iOS; unavailable paths remain disabled. APPSTORE runtime, iOS clipboard interaction and device/input gates remain open. Subsequent authorized subagent work implements Default ISO #60, manual Change Disc #61, Confirm on Stop, inert GPU-row removal and reset repairs; native production-model regressions pass, but integrated runtime verification is pending. Independent review also found save-state writer/completion and sync mutation/conflict safety defects now being fixed. Follow the [current blocker fix ledger](superpowers/plans/2026-10-19-release-blocker-fix-ledger.md) for live state. The preceding 1,970-test result predates these changes and is not a new candidate pass.

Current audit evidence: [tvOS UI/settings audit](app-store/release-evidence/2026-10-19-tvos-audit.md) and [recent TestFlight user report](app-store/release-evidence/2026-10-19-testflight-user-report.md). Local Native-resolution, read-only store diagnostics and singleton-stepper fixes pass 80 targeted settings tests; they are not published to TestFlight. Missing Default ISO controls are tracked in [#60](https://github.com/Provenance-Emu/iCube/issues/60). See the audit for the separate tvOS regression results and remaining device/APPSTORE gates.

Start release work at [docs/app-store/RELEASE-PLAN.md](app-store/RELEASE-PLAN.md) and [tracker #51](https://github.com/Provenance-Emu/iCube/issues/51). [Milestone 1](https://github.com/Provenance-Emu/iCube/milestone/1) contains R1–R8 (#52–#59): tvOS UX, settings, production user-data sync, ROM/library interoperability with Provenance, stability, submission. The [execution roadmap](superpowers/plans/2026-10-19-icube-release-readiness.md) starts with baseline and scope review. Owner quality bar: fast/reliable, clean UI with no known unresolved UI/UX defects, working settings/sync/save states/library editing/library sharing. R7 #58 and R8 #59 make save states and editing explicit gates. Detailed transport scope remains open; no submission acceptance or current device-test pass is implied.

Corrections to older notes: CloudKit is enabled in source/entitlements since October 14; Production/device convergence still needs evidence. Existing user-data CloudKit deliberately excludes ROMs. Nearby ROM sharing and same-device share-sheet export are separate paths; Provenance already has an iCube dialect in PVLibrarySharing. Folder access, automatic mirroring and cross-app native-save scope remain owner decisions. Historical unverified checks and old test counts do not establish current candidate readiness.


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

## Audio (2026-10-11, branch `claude/icube-audio-engine-809825`)

Both iOS audio backends were finished: shared filters, 5.1 over HDMI, spatial audio on headphones,
and GameCube / Wii Speak microphones. Read `docs/handoff-2026-10-11-audio-engines.md` before touching
`Source/Core/AudioCommon` or the Audio settings leaf; the device checklist there is still owed.

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

## Update: tvOS redesign completion, plans A–D landed UNCOMPILED (2026-10-11/12)

Spec: `docs/superpowers/specs/2026-10-11-tvos-redesign-completion-design.md`. Plans: `docs/superpowers/plans/2026-10-11-tvos-redesign-plan-{a,b,c,d}.md`. Branch `feat/tvos-redesign-a` (worktree `~/Workspace/icube-redesign-a`), fast-forwarded into develop after each plan.

**Owner ruling (velocity mode):** the Mac was saturated by other sessions' builds, so every task was written by a subagent WITHOUT compiling, testing or per-task review, and committed by the controller. Nothing on this branch has been built. The first thing to do next is one tvOS compile pass and one `make test`, then fix what they find in a single batch (expect: labels/argument order on new `MenuScreen` init calls, `tvHeader:` on hand-built leaves, `#if os(tvOS)` placement, Photos/ReplayKit availability on tvOS, `.fontWeight` after `.icubeText`).

What landed, per plan:
- **A** (settings leaves on the iFly look): `-ICubeSettingsPreview <leafID>` / `-ICubePausePane <pane>` launch args + `Scripts/tvos_screens.sh`; fast-forward tile fixed with `PauseFastForwardState`; floating speedometer button → "Performance HUD" tile; `ICubeLeafHeader`, `IconBadge`, `icubeRowChrome`; `MenuScreen` `tvHeader:`/`tvInset:` + iFly row anatomy; sidebar accent + hairline; About, Web UI, iCloud, Nearby (+Share My Library, grant detail), Shaders and Achievements leaves on `MenuModel` builders with tests.
- **B** (library): in-body "iCube" title + view/count subtitle, shelf headers on every view, token card type, rail accent selection, animated room by default (`LibraryBackgroundStyle.default`), 90 s hue drift with Reduce Motion respected.
- **C** (pause): Upscaling/Audio/Performance tiles (live via `TVEmulationBridge.setInternalResolution:`/`setAudioVolumePercent:`), JIT chip, Save States/Cheats/Shaders/confirm panes on tokens, `SettingsRootView(initialLeafID:)` deep link from pause.
- **D** (quick menu + recording): `QuickMenuView`/`QuickMenuModelBuilder`, `PauseArbiter.Reason.quickMenu`, unbound-Siri-Remote short press and Options-hold triggers, `RecordingManager` (ReplayKit, `<user>/Recordings/`), `RecordingWatermarkView`, Interface → Recording settings; D3 wires them into `EmulationScreen`/pause tiles.

**Not done:** package 0 baseline screenshots (script exists, never run); the shader-preview crash (spec §9, needs the simulator); peer detail / peer library / sync-conflict screens and the Achievements text fields still use stock `List`; `check_design_tokens.py` baseline was refreshed with `--update` after each wave (it only ratchets, it never blocks new literals in new files — audit `GameGridItem.swift`, `CheatsMenuView.swift`, `ShaderQuickPickerView.swift` for leftover literals); no Opus review happened.

**Owner device checks once it compiles:** every settings leaf's focus walk; FF cycle 2x→Unlimited; Performance HUD tile; live resolution/volume tiles; Siri Remote short-press quick menu and Options-hold; a real recording lands in Recordings and shows in the Web UI; the animated room and card tilt.

## Update: first compile-and-fix pass of plans A–D, pushed (2026-10-12 ~02:30)

develop `06407190da` is on origin. What happened, in order:

1. **Compile + test pass** (`0951b585b9`): tvOS compile needed three fixes (ShaderQuickPickerView `#if` around a `VStack`, PauseMenuView debug pane mutating `self`, `isMicrophoneEnabled` off tvOS); the iOS test build needed two main-actor default-argument fixes in the skin store. Five tests were wrong, not the code: pause tile order (Cheats now after Upscaling/Audio/Performance), the tvOS layout test lacked plan D's Record tile, the fast-forward off-ladder test contradicted `MenuModelTests` (unknown value → first option, so Off then 2x; plan A's prose said 2x — owner may want that revisited), and the skin URL test asserted a percent-encoded `lastPathComponent`, which Foundation always decodes. Full iOS suite: 1627 tests, 0 failures. `ICubeCardFocusTests` flaked once under load (37 bytes), passed on rerun.
2. **Merge** of origin (`b5feb47876`): PR #42 had fixed the same shader-picker syntax; upstream's version was kept.
3. **Opus review of `52f2704066..HEAD`** found 10 issues; fixed in `06407190da`: quick menu could never take focus on tvOS (no pause-overlay notification → `EmuEventVC` focus trap stayed up), quick menu reappeared after the pause menu and re-paused, Pause Menu tile let the core resume between the menus, Siri Remote press reached either menu depending on route, stale pause preview, missing Record tile, Options-hold opened the quick menu on iOS (spec §7.2 says tvOS only); recording never stopped on game end/background and double-started; Audio/Upscaling off-ladder values jumped to 0 %/Native (now listed in place).
   - **Verification gap:** the quick-menu files compiled on iOS; the recording and audio changes and the tvOS build of `06407190da` are UNVERIFIED — a targeted `make test` was running when the owner asked to push (another agent needed the Mac). First thing next session: tvOS compile + `make test`.
   - **Still open from the review:** (7) `ICubeTileButtonStyle` call sites without `isFocusedOverride` show no focus on tvOS — ShaderQuickPickerView hero/cards, SaveStateFilmstripView:83, PauseMenuView save-slot tiles; (9b) iOS `openSettingsLeaf` ignores the leaf id (Performance tile and long-presses open the Settings root on iOS); device checks listed by the review: shader-card buttons' system focus, `playerIndex == .indexUnset` as "unbound", ReplayKit on background, Upscaling vs Auto-IR/thermal override.
4. **Screenshots (package 0) still not captured.** `Scripts/tvos_screens.sh` now passes `-ICubeAppearance light|dark` (new DEBUG hook in `MainDisplaySceneDelegate`; the tvOS runtime rejects `simctl ui appearance`). The one capture that ran showed the **pause grid broken**: the pinned Exit tile stretched to half the screen and the options grid showed one row. Fixed by a fixed height on the pinned tile (`MenuScreen.tvTilesBody`), not yet re-captured. Run `Scripts/tvos_screens.sh ../../../docs/superpowers/baselines/2026-10-12-tvos --dark` then `--no-build --light` and check `pause-grid-*.png` first.
5. **Provenance gitlink not bumped** to `06407190da`.

Traps met this session: the simulator test runner dies at bootstrap under heavy Mac load ("Mach error -308" / "signal term before establishing connection") — pre-boot the simulator and rerun, it is not a test failure; another session's `kill` ends a running `xcodebuild` with "BUILD INTERRUPTED".

### Addendum (02:50): the review-fix batch is verified on iOS
`06407190da` shipped a compile error (`Notification.Name(DOLEmulationDidEndNotification)`; the Swift name is `.DOLEmulationDidEnd`), fixed in `49ffbc0974` + `eba82c4f7b`. On `eba82c4f7b` the targeted suites (QuickMenu, PauseArbiter, PauseMenuModelBuilder, CorePauseCallSites, UILayerPauseCalls, RecordingManager, PauseFastForwardState, MenuModel) pass with 0 failures, so the recording and audio-cycle changes compile and behave on iOS. **Still unverified: the tvOS compile of `eba82c4f7b`** (the additions are platform-neutral or inside existing `#if os(tvOS)` blocks, but nobody has built it) and the full iOS suite on this head. Screenshots remain owed.

## Update: review items 7 and 9b, release gate, screenshots (2026-10-12 evening)

**State.** origin develop = `90e854c9ed` (PRs #39–#44: on-demand cheats, sync categories, audio engines, shader picker fix, card focus test fix). Provenance gitlink is bumped to it (`d68fc67b06`). Merged worktrees and branches are deleted; the only worktree left is `~/Workspace/icube-tile-focus` (branch `fix/tile-focus-tvos`).

**Verified:** tvOS Debug (NJB) compile of `90e854c9ed` is clean (`BUILD SUCCEEDED`, no `: error:` lines).

**New on `fix/tile-focus-tvos` (not pushed, not yet compiled):**
- `20d5703cdc` **item 7.** `ICubeTileButtonStyle` read `@Environment(\.isFocused)` on the style struct, which never updates on tvOS. Focus is now read in a nested `ICubeTileButtonChrome` view, the same pattern as the row and rail styles. This fixes the shader picker hero and cards, the save-state grid and the pause save slots in one place. Tiles that pass `isFocusedOverride` (`MenuScreen`) are unchanged.
- `33a43a50eb` **9b.** On iOS the pause sheet built a bare `SettingsRootView()`, and the iPhone list (`phoneList`) never read `jumpToLeafID`; only `SettingsSidebarShell` did. `PauseMenuView` now keeps `settingsSheetLeafID` and passes it as `initialLeafID`. `phoneList` consumes the jump by pushing the matching entry. When the DSU deep link set the jump, it drops the `"controllers"` id, because that link pushes the DSU list itself.

**Queued when this was written** (background jobs in the session that wrote this; check before rerunning anything):
1. The owner's full `make test` on `90e854c9ed` (in a terminal tab).
2. Then: fast-forward develop to `fix/tile-focus-tvos` and run the Release gate (iOS + tvOS, `Release (Non-Jailbroken)`).
3. Then: `Scripts/tvos_screens.sh docs/superpowers/baselines/2026-10-12-tvos --dark`, then `--no-build --light`.

**Then:**
- Check `pause-grid-*` (the pinned Exit tile fix), `library-all-*`, and the save-slot tiles (they show item 7's focus ring).
- Check the iPhone long-press → leaf on the simulator.
- Push develop and dispatch TestFlight: `gh workflow run testflight.yml -R Provenance-Emu/iCube -f platform=all`. The owner asked to hold TestFlight until 7 and 9b were in.
- Bump the Provenance gitlink again.

**Correction: the "stuck on GameCube" library captures were a script bug, not app evidence.** `simctl spawn defaults write` writes the simulator's global preferences, while the app reads its own container (`simctl get_app_container … data`), whose plist held `library_platform_filter = gameCube`, so every capture restored GameCube. `tvos_screens.sh` now passes library state as launch arguments (`-library_platform_filter`, `-onboarding_seen_v1`), which override stored values. On tvOS the rail is the only platform switcher: there are no remote left/right or shoulder-button filter steps (`stepPlatformFilter` is iOS-only), so owner priority 1 needs checking against the rail on a device.

**Also fixed this session:** the tvOS onboarding "Maybe Later" button rendered blank, both focused and unfocused. The system `.bordered` capsule drew the label in its own tint. It now uses `ICubeRowButtonStyle` on tvOS. `tvos_screens.sh` marks onboarding as seen except for `library-empty`.

**Still owed:** owner device checks (list in the previous update); the decision on fast-forward off-ladder (Off then 2x).

### Next project: website screenshots and video

The site is `~/Workspace/Provenance/iCube/icube-emu.github.io` (Next.js, `Provenance-Emu/icube-emu.github.io`). Its screenshots are `public/screenshots/{iphone,ipad,appletv}/*.{jpg,webp}`, indexed by `src/data/screenshots.json`. **They were last updated 2026-09-08**, before the tvOS redesign, the pause tile grid, the quick menu, the controller hub, audio engines, on-demand cheats, sync, skins and JIT. The video section (`src/components/VideoShowcase.tsx`) is a "Gameplay video coming soon" placeholder that turns on when `public/video/gameplay.mp4` exists.

Owner's goals: replace the placeholders and old images, show off the missing features, add gameplay video, and use real game artwork instead of the filler titles.

**Two sources, split by what each can show:**
- **Simulator** for UI stills: library, settings, pause grid, quick menu, controller hub, cheats, shaders picker, sync, and light/dark variants. These are reproducible and scriptable, and `tvos_screens.sh` already covers tvOS. It needs iPhone and iPad equivalents. The simulator cannot run gameplay worth showing.
- **Owner's devices** for everything that needs real emulation: gameplay video, upscaling before/after, the performance HUD, graphics enhancements and shaders in-game, and controller variations (touch layouts/skins, MFi/DualSense, Wii pointer). The devices hold real games. Capture with ReplayKit through the app's own Record tile (`RecordingManager`, lands in `<user>/Recordings/`) or with QuickTime over USB. The debug API `screenshot` route works too (see the phone debug recipe memory).

**Real artwork in simulator stills (owner's direction, 2026-10-12).** The `-SCREENSHOT_MODE 1` catalogue (`TVLibraryBridge.mm`, `DOLScreenshotDemoGames`) currently uses invented titles and IDs, and its comment says so on purpose. The owner wants it to use **known real game IDs instead, and let the normal metadata/artwork path fill in the real title, cover and details**; the IDs are faked, the artwork is not.
- Check that demo `TVGameItem`s (`initWithDemoTitle:`) go through the same GameTDB cover/metadata fetch as imported games (`TVGameItem.mm`). If they short-circuit it, route them through it, and keep a bundled-cover fallback so offline or CI captures stay reproducible.
- Update the catalogue comment; the "no real game" rule no longer holds.
- Keep the store-listing set (App Store/TestFlight) separate from the website set. Apple review is far stricter about third-party game IP in emulator screenshots than a self-hosted site is.

**Suggested shot list:**
- **tvOS:** library sections and rail, pause grid, quick menu, settings sidebar, controller hub.
- **iPhone / iPad:** library, pause grid, touch overlay + skins, controller hub, cheats download, shader picker with live previews, settings search.
- **Device stills:** upscaling native vs 3x, shaders before/after, performance HUD.
- **Device video:** 20–40 s mixed gameplay with a few games, cuts showing touch, pad and TV.

**Steps:**
1. Get the owner's ruling on real artwork.
2. Add iPhone/iPad variants of `tvos_screens.sh`.
3. Owner captures on device (Claude can drive the debug API where useful).
4. Convert to jpg+webp at the site's sizes and update `screenshots.json`.
5. Drop in the video.

Adaptive-resolution removal is tracked in [#62](https://github.com/Provenance-Emu/iCube/issues/62). Use `Tools/release-audit/check_resolution_core.py` on the completed package and embedded app frameworks to reject stale cores.
