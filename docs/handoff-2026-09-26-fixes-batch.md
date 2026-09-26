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
