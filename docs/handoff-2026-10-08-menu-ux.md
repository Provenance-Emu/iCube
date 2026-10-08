# Handoff: unified menu UX, PR 1 and PR 2

Written 2026-10-08 for a fresh session. Everything you need is in the repo; this page is the map.

## Resume prompt

Paste this into the new session, started in `~/Workspace/icube-menu-ux` (or any iCube checkout on `develop`):

> Execute `docs/superpowers/plans/2026-10-07-pause-arbiter.md` task by task using superpowers:subagent-driven-development, in a worktree on branch `fix/pause-arbiter` from `develop`. The spec is `docs/superpowers/specs/2026-10-07-unified-menu-ux-design.md`. Read `docs/handoff-2026-10-08-menu-ux.md` first for the traps. Open the PR against `develop` when the device gates in Task 6 are done. Do not start `docs/superpowers/plans/2026-10-07-menukit-pause-overlay.md` until PR 1 is merged, nor `docs/superpowers/plans/2026-10-08-settings-on-engine.md` or `docs/superpowers/plans/2026-10-08-controller-hub-reorg.md` until PR 2 is merged (those two are independent of each other).

## What exists

| Thing | Where |
|---|---|
| Spec (approved by the owner) | `docs/superpowers/specs/2026-10-07-unified-menu-ux-design.md` |
| PR 1 plan: PauseArbiter | `docs/superpowers/plans/2026-10-07-pause-arbiter.md` |
| PR 2 plan: MenuKit + pause overlay | `docs/superpowers/plans/2026-10-07-menukit-pause-overlay.md` |
| PR 3 plan: settings on the engine | `docs/superpowers/plans/2026-10-08-settings-on-engine.md` (after PR 2; lists its spec deviations at the top) |
| PR 4 plan: controller hub reorg | `docs/superpowers/plans/2026-10-08-controller-hub-reorg.md` (after PR 2, independent of PR 3; deviations at the top) |
| PR 5 plan: remaining settings leaves | `docs/superpowers/plans/2026-10-08-settings-leaves-batches.md` (after PR 3; three batches, one PR each) |
| Branch holding these docs | `docs/unified-menu-ux` (commits de3cca3cb0, 08cc9d231c), worktree `~/Workspace/icube-menu-ux` |
| Code PRs not yet started | PR 1 (`fix/pause-arbiter`), PR 2 (`feat/menukit-pause-overlay`) |

Merge the docs branch first or cherry-pick the two commits onto the PR branch, so the plan and spec travel with the code.

## Traps, in the order you will hit them

1. **Submodule worktrees resolve to the wrong top level.** iCube is a submodule of Provenance and the shared git config carries `core.worktree`. Right after `git worktree add`, run `git config --worktree core.worktree <absolute worktree path>` inside the new worktree, then confirm `git rev-parse --show-toplevel` prints the worktree path and `git status --short | wc -l` is small. If you skip this, `git add` stages thousands of deletions.
2. **The main checkout may be busy.** Another session was committing on `perf/ps-neon-counters` in `Provenance/Cores/Dolphin/dolphin-ios`. Never switch its branch. Work in your own worktree.
3. **New test files silently do not run** until `cd Source/iOS/App && tuist generate --no-open`. Every plan task that creates a test file says so; do it.
4. **Tests are iOS-simulator only.** `make test DEST="platform=iOS Simulator,name=iPhone 17 Pro" TEST_ARGS="-only-testing:iCubeTests/<Class>"`. A full run is several minutes. tvOS gets a compile check only (`xcodebuild build ... -scheme "iCube-tvOS (NJB)" -destination "generic/platform=tvOS Simulator"`; confirm the scheme name with `xcodebuild -list -workspace iCube.xcworkspace`).
5. **Pause and resume go only through `PauseArbiter`.** `UILayerPauseCallsTests` (PR 1 Task 2) fails the build for any other `TVEmulationBridge.pause()` / `.resume()` in `Source/iOS/App/Common/Swift`. It is committed red on purpose and goes green in Task 5.
6. **SwiftUI fires `onDisappear` on a covered presenter.** That is the original bug. The arbiter's deferred resume absorbs a release-then-claim inside one transition, and `PauseMenuView` keeps its `isPauseMenuChildPresented` guard. Do not remove either.
7. **tvOS focus cannot be verified in a simulator by a model.** PR 2 Task 4's `onMoveCommand` on cycle tiles, the long-press of Select, and the `BackCoalescer` window all need the Apple TV with an Xbox pad. Flag them in the PR as device-gated rather than claiming they work.
8. **No LLM attribution trailers** in commit messages or plan text (owner rule).
9. **Subagent prompts must say** "DO NOT git reset / rebase / push / touch develop". Parallel agents have collided before.

## Review checklist for the owner's expensive-model pass

Before merging each PR, a short review with the stronger model should check:

- PR 1: every presentation that can cover a paused game claims a token (grep `.sheet(` and `.fullScreenCover(` in `PauseMenuView.swift` and `EmulationScreen.swift` against the list in plan Task 3 Step 3 and Task 4 Step 1). The exit-confirm "Continue" no longer resumes. `endLayoutEdit` no longer resumes.
- PR 2: `MenuScreen`'s `.grid` and `.list` behaviour is byte-for-byte unchanged for `CheatsMenuView`, `ControllerHubView`, `PlayerScreenView`. The tvOS tiles body uses eager rows, one outer `.focusSection()`. The pause model's item ids match the Global Constraints list.

## Context the plans assume you know

- `MenuModel` / `MenuScreen` are the D18 data-driven menu engine (`Source/iOS/App/Common/Swift/Menu/`). The iOS pause root already renders through it; the tvOS pause root does not, which PR 2 fixes.
- `PauseGestureTracker.requestPauseMenu` is the single sink for every "open the pause menu" input on both platforms. It pauses first, then posts `DOLShowPauseMenu`.
- iFly's reusable parts are the design language only (theme, focus button style, tile grid). Its settings are not data-driven; do not copy its settings files. Provenance's `PauseMenuTile` model is the clean reference for tiles; its 2574-line view is not.
