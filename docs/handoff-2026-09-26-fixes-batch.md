# Handoff 2026-09-26 — planned-fixes batch (develop `d2ece383eb`, 20 commits ahead of origin, NOT pushed)

Follows `docs/handoff-2026-09-25-test-queue.md`. Everything here is compile-gated (iOS + tvOS on
the combined head), unit-tested where noted (`make test`: 213/213 green on the iOS simulator),
and NOT device-verified. The DEV build of this head is installed on the iPhone 16 Pro Max
(launch was denied because the phone was locked; tap the icon).

## Landed

| Item | Commits | Notes |
|---|---|---|
| tvOS TestFlight export fix | `fix(extensions): declare arm64 UIRequiredDeviceCapabilities` | run 36133343680's tvOS job failed validation on the Top Shelf appex; all three extension plists now carry the key |
| ButtonType drift guard in the build | `build: wire ButtonType drift linter` | "Check Button Type Drift" pre-script, first in `preScripts`; fails the build on drift |
| Shader clones ignored in-repo | `chore: track ignore rules` | `Externals/OpenEmu-Shaders`, `Externals/slang-shaders`; nothing in the build consumes them |
| Localization | `fix(l10n): catalog L(...)`, `fix(l10n): bundle the Core strings table` | 913 missing `L()` keys added to en/ja `Core.strings`; `Project/Scripts/check_localized_keys.py --check`. **Core.strings was never bundled by the Tuist project and `L()` read a non-existent Localizable table** — both fixed; ja translations were inert before this |
| `make test` | `build: add make test` | ad-hoc signing flags because vendored MoltenVK is unsigned; test target is iOS-only |
| D16 shader UI | `refactor(shaders)`, `feat(shaders): port iFly's quick-preview picker` | debug controls behind `#if DEBUG` (`ShaderDebugView`), dead keys deleted, "Advanced" section keeps flip/pre-copy; pause menu opens `ShaderQuickPickerView` (cards over the pause frame, NOT live per-shader renders); preset-scoped parameter accessors so editing a non-live preset does not write the wrong key |
| D10 save states | six `feat/fix(save-states)` commits | LazyVGrid, one focus target per card, confirmationDialog actions, delete needs a second alert, tvOS rename via Form sheet, **tvOS pause menu now has a "View All States" entry (it had none)**, "Save Here" gated on the running game, `playTimeSeconds` from `TimePlayed` (only for new saves; lags up to 30 s) |
| IMU axis fix | `fix(input): stop applying DSU deadzone/gain/smoothing/clamp to IMU axes` | see below |
| C9 overlay | five `feat/fix(touch-overlay|dsu)` commits | Edit IR Area mode (mutually exclusive with Edit Layout), `touch_overlay_ir_pointer_gain` (drag mode only), opacity reuses `mainTouchPadOpacity`; DSU double-feed on force-sensitive triggers fixed; held button leaked into edit mode fixed; `TouchOverlayHostContainer` releases state on teardown |

## The IMU behaviour change (read before testing motion)

`TCManagerInterface.setAxisValueFor:` clamped the axis id to 255 for its smoothing tables and
reused the clamped id for the IMU range test, so Wiimote/Nunchuk accel (625-630/900-905) and gyro
(631-636) were treated as sticks since the iCube graft (58a7763cc2): with default knobs the only
effect was the ±1 clamp, which cut gravity from ~9.8 to 1 m/s² and capped rotation at 1 rad/s;
with the sliders moved, deadzone/gain/EMA applied too. Now IMU values reach the core raw (as
upstream DolphiniOS). Expect tilt games to feel like a real Wii Remote for the first time and
shake detection to trigger more easily. The "Advanced Motion Settings" sliders (Gain / Deadzone /
Smoothing) now affect only analog sticks and triggers, so their labels ("Scales motion intensity")
are wrong — decide whether to rename them or make Gain apply to gyro. Regression tests:
`TCManagerInterfaceAxisTests`.

## Phone tests owed for this batch (add to the 2026-09-25 queue)

1. Motion: a tilt game (NSMBW tilt platforms, Wii Sports) and a shake action (Galaxy spin) — direction and magnitude sane, no jitter; Motion Debug still shows live values.
2. Pause menu → Shaders: tap a card then Resume applies it; gear on a NOT-loaded preset shows that preset's parameters and edits stick; hero card shows the game frame.
3. Pause menu → Save States: each dialog action fires; Delete needs the second confirm; "Save Here" absent from the library entry point; new saves show game time after ~30 s.
4. Overlay (flag on): light press on L/R with a force-capable touch gives no DSU L1 blip; hold a button, long-press into Edit Layout, exit — nothing stuck; edge-swipe mid IR drag continues smoothly; Edit IR Area resize caps on both axes and Edit Layout has no IR handle.
5. Settings > Controllers: pointer sensitivity slider changes drag-mode reach only.
6. Apple TV: pause menu saves pane → "View All States" reachable and the grid focuses; rename sheet brings the keyboard; shader picker gear/star focus independently.
7. Japanese locale: any UI string now renders translated where ja Core.strings has one.

## Still open

- D18 data-driven menus (own session); overlay default flip + xib removal (after device checklist); IR gain decision.
- Motion sliders' labels vs. behaviour (above).
- iOS pause menu's raw GCController d-pad handler ignores `ControllerFocusCoordinator`, so a controller can drive the menu behind Save States / Shaders / Continuity sheets (pre-existing; D18).
- Per-shader live thumbnails need an isolated FilterChain (not built).
- Push develop + bump the Provenance gitlink; the tvOS TestFlight rerun will exercise the arm64 plist fix.

## Round 2 (same day, develop `5882d010c3`, iOS 266 tests green, tvOS green, pushed)

| Item | Notes |
|---|---|
| CI unit tests | `.github/workflows/tests.yml`: ButtonType drift + localized-key checks (both blocking), then `make test` on a simulator picked by SDK version; ~30-50 min estimate, untested on a runner until the next push triggers it |
| Analog stick sliders | the `dsu_*` sliders are now "Analog Stick Gain / Deadzone / Smoothing" under "Analog Stick Settings" (ControllersRootView + DSU widget); keys unchanged |
| Shader live previews | `ShaderPreviewRenderer` renders each preset through its own FilterChain on its own command queue from the pause frame (raw XFB, pre-post-processing), `ShaderPreviewCache` LRU, hero card previews the selection. iFly's generator was NOT ported because it mutates the live singleton's UserDefaults. Cleanup scoped to the decoder's own temp dir (a snapshot/diff version raced live preset reloads) |
| Pause menu vs sheets | raw `GCController` handler now gated on `ControllerFocusCoordinator.isActiveScope`; Shaders/Settings/Controllers/Continuity sheets claim the controller; per-pad A latch with resync (`PauseMenuInputGate`, 10 tests). Exit/Reset alerts and the FF dialog still do NOT claim |
| D18 menu engine | `Common/Swift/Menu/`: `MenuModel`, `MenuFocusRouter`, `MenuControllerNav` (moved `RemapControllerNav`), `MenuScreen` (iOS polls GCController on a timer + coordinator scope; tvOS native List focus, NO consumer yet). Cheats iOS list migrated; Cheats tvOS body untouched. Design doc §9 lists what each remaining screen needs |

### Round-2 phone tests owed
1. Pause menu with a pad: open Save States / Shaders / Continuity / Controllers / Settings, d-pad and A must not move the menu behind; close with B, nothing activates; two pads: hold A on one while moving the other.
2. Cheats (iOS) with a pad: reach every row, toggle repeatedly, B back; touch-only shows no focus tint; the "Enable Cheats?" alert is still not controller-answerable (known).
3. Shader picker: cards show real previews of the pause frame (orientation, colours), heavy CRT presets included; scrolling ~20 presets does not spike memory; tapping a card while previews render still applies the preset.
4. Analog Stick Settings: labels, and that the sliders change on-screen stick feel only.
5. Apple TV regression pass only (no tvOS screen changed behaviour).

### Incident to know about
While round 2 was landing, the parent Provenance checkout received an outside "update dolphin core" commit
(`6b325bb5dd`, pushed) pointing the gitlink at an unpushed local SHA, then a hard reset + pull re-checked
out the submodule detached at that SHA mid-gate. Recovered with `git checkout develop` (nothing lost) and
pushed iCube develop so the gitlink resolves. If you use a GUI git client on Provenance while a session is
working in the submodule, expect this.

## Round 3 (develop `d0bbaf787d`, iOS 277 tests, tvOS Debug + iOS/tvOS Release green, pushed)

| Item | Notes |
|---|---|
| Release build break | `debugChecker` reset outside `#if DEBUG` broke CI + TestFlight iOS archive while every Debug gate passed. Fixed; `make gate-release` (iOS + tvOS Release compile) is now part of the local gate |
| Review fixes (shader picker) | hero preview keyed on discovery readiness (never rendered on first open before), section-scoped focus ids (same preset in Favorites/Recent/All had one `@FocusState` value), `parameters(forPresetPath:)` temp-dir leak |
| Pause menu root → MenuScreen (iOS) | `PauseMenuModelBuilder` + `MenuScreen(.grid)`; raw GCController handler and `PauseMenuInputGate` deleted; Exit/Reset/Fast-Forward are in-place MenuScreen confirm overlays (controller-safe). tvOS grid untouched. Known: d-pad left/right inert in the 2-column grid, no scroll-to-focus in `.grid`, card typography not yet the design tokens |
| Cheats tvOS → MenuScreen | first tvOS consumer; found the tvOS renderer's `.focused` binding was never attached (dead focus) and fixed it; multi-pad polling (per-pad nav, one activation per tick); `MenuModal` hook so "Enable Cheats?" is A/B-answerable on iOS |
| Bench | `gfxShaderCompilationMode`, `mainCachedInterpreterPrefetch`, `cirPsNeon`, `gfxHackNeonTextureDecode`, `vertexLoaderMode` on the settings bridge; `Project/Scripts/perf_matrix.py`; plan `docs/perf/2026-09-26-default-settings-matrix.md`. Prefetch caption corrected (default OFF, hints measured slower) |

### Round-3 phone tests owed
1. Pause menu with a pad: grid navigation up/down, A activates, Exit/Reset/FF overlays answer to A/B and never leak to the rows; portrait: Reset/Exit below the fold reachable (known: no scroll-to-focus).
2. Cheats with two pads connected: either pad drives, no double activation; "Enable Cheats?" answered by A/B.
3. Apple TV: Cheats pane focus lands on "Enable Cheats", every toggle reachable, Menu pops.
4. Shader picker: hero card shows the selected preset's preview immediately on open; gear on a not-loaded preset leaves no `oe_shader_decode*` dirs behind (check tmp via the debug API if needed).

### Bench connection lesson (2026-09-26)
`iproxy 8726 8723 -u <udid> -n` kept accepting TCP and resetting; a fresh `iproxy 8726 8723 -u <udid>` (no `-n`)
answered 200 at once. Restart the tunnel without `-n` after every reinstall; "Connection reset by peer" from
curl means the tunnel, not the app. DEBUG builds bind the bench unconditionally at scene connect.

## Perf-defaults round (same day) — see `docs/perf/2026-09-26-default-settings-matrix.md`
- Shader default flipped to **Hybrid Ubershaders** (`7e68d54562`, xcframework `0d46deaa76`, Provenance `0a5175205b`): equal throughput to Specialized over 8 legs, no first-compile stutter by design; Exclusive −4.5 %. Devices with the key already stored keep it; "Reset Optimizations to Recommended" clears it.
- Prefetch / NEON paired-single / vertex loader: no gain, unchanged. NEON texture decode: +3 %, stays on.
- Ten CIR optimizations that are OFF by default but ON on Joe's phone: all inside ±4 % on Wind Waker Outset (Store-Loop FF and Dead-FPRF weakly negative). Defaults unchanged; captions carry the measured note. Re-run on Chibi-Robo / F-Zero before promoting any.
- Bench: 14 new settings keys, `perf_matrix.py` (palindrome sweeps, `--capped`, `--pre`, per-key restore), `make gate-release`. Stutter is NOT measurable yet (bench settles before sampling; needs a scene transition or input injection).
