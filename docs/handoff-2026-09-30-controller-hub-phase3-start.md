# Controller Hub — Phase 3 start (handoff, 2026-09-30)

For a fresh session. Phases 1 and 2 are on develop. Phase 3 has not been planned yet.

## Where things stand
- **Spec** (approved, binding): `docs/superpowers/specs/2026-09-28-controller-hub-design.md`.
  - Phase 3 is "Player screen".
  - Phase 4 is "Removal": delete `ControllerSetupView`, the old `ControllersRootView` parts, `EnhancedMotionControlsView` and the extra pointer pickers, and move `MotionDebugView` behind DEBUG.
- **Plans done, use them as the style reference:**
  - `docs/superpowers/plans/2026-09-28-controller-hub-phase1-foundation.md`
  - `docs/superpowers/plans/2026-09-28-controller-hub-phase2-hub.md`
- **Device checklists (all still owed, nothing below is device-verified):**
  - `docs/handoff-2026-09-28-controller-hub-phase1.md`
  - `docs/handoff-2026-09-28-controller-hub-phase2.md` (13 items)
- **Phase 2 landed** on develop on 2026-09-30 as 15 commits cherry-picked on `0b659bdd8b`. The previous session was pushing them and bumping Provenance's iCube pointer. Check with:
  - `git log --oneline origin/develop..develop` in iCube: it must be empty once pushed.
  - `git ls-tree HEAD Cores/Dolphin/dolphin-ios` in Provenance.

## What Phase 3 builds (from the spec)
`PlayerScreenModelBuilder`, a pure builder whose `PlayerState` is filled by the hub's `ControllerHubViewModel`. The hub's player rows push this screen instead of today's `RemapPlayerView`. It has these sections:
1. **Device:** picker listing None / Touchscreen (iOS) / each connected pad.
2. **Profile:** Load, Save As… (via `MenuModal`), Reset to Default.
3. **Wii only:** Extension (None / Nunchuk / Classic) and Sideways.
4. **Buttons:** one row per control, grouped Face / D-Pad / Sticks / Triggers / System / Motion.
   - Rows show `BindingDisplay` text.
   - Tapping a row arms capture using the existing `RemapCaptureMachine`, as `.custom` rows.
5. **Pointer & Motion:** Wii only, on the touchscreen or a motion-capable port.
   - Pointer uses `PointerMode` / `PointerModeController`.
   - Also Recenter (`TCDeviceMotion.requestPointerRecenter`), Sensitivity, Invert X/Y, Shake. These read and write `MotionSettings`.
6. **Advanced** (collapsed): dead zones, stick ranges, IR/IMU values, and each binding's raw expression as editable text.
   - Show the parse error inline and do not save on error, because Dolphin's `ControlReference::SetExpression` accepts broken expressions silently.
   - This needs a bridge to Dolphin's `ciface::ExpressionParser` for validation.

## Reuse, don't rebuild
- **`RemapModel.swift`:**
  - `RemapGroup` carries an `owner` (`.gcPad` / `.wiimote` / `.nunchuk` / `.classic`) and a `key`.
  - `RemapGroup.groups(for:attachment:)` includes the selected extension's groups (fix `760e9e8e19`).
  - `RemapControlRow.id` includes the owner.
  - The capture machine lives here too.
- **`TVControllerMappingBridge`:** the per-owner read/write methods, including `wiimoteExtensionControl*(forIndex:kind:group:)`.
- **Phase 1 units:** `MotionSettings`, `PointerModeController` (`@MainActor` after Phase 2), `BindingDisplay` / `DeviceFamily`, and `MenuItemRole.cycled` plus d-pad `.adjust`.
- **Phase 2 units:** `ControllerHubViewModel`, `ControllerHubState`, `ControllerHubModelBuilder`, `ControllerHubView`, `ControllerMoreSettingsView`, `DSUSettingsView`, and `.destination` activation by a pad's A.

## Open items to fold into the Phase 3 plan (or rule on)
- **iOS gap (Phase 2 handoff):** a pad's A can push More / DSU / Edit Layout, and those screens have no pad Back. Phase 3 player screens must be pad-navigable both ways.
- **Deferred minors:**
  - `RemapPlayerView` computes `DeviceFamily.from` twice per row.
  - A and a d-pad adjust in the same poll can double-step a picker. Guard it once `.picker` items exist in production, which happens in Phase 3.
  - The hub's actions have no writer seam.
  - The snackbar and motion notification-name string literals: about 56 call sites, a separate cleanup.
  - Naming: "On-Screen Style" (hub) vs "Overlay Style" (More) is a UX call; ask the user.
- `GameProfiles` per-game pointer mode is already routed (Phase 2 Task 1).

## Process that worked (Phases 1–2)
1. **Plan:** writing-plans. An Opus agent drafted Phase 2's plan from the spec plus research; then a Sonnet reviewer checked it against the spec before execution. Ask the user to sign off on decisions beyond the spec.
2. **Execute:** subagent-driven development, run by ONE background Opus controller agent in its own worktree. It dispatches Sonnet implementers and reviewers, uses Haiku for docs tasks, Opus for the final review, and stops before merging.
3. **Merge:**
   - In the main checkout, on `develop`, cherry-pick the branch commits oldest first.
   - Reword any commit whose trailer is not `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` using `git cherry-pick -n` plus `git commit`.
   - Then run `tuist generate --no-open`, `make test SIM="iPhone 17 Pro"` and `make gate-release` on the merged tree.
   - Push only when the user says so.
4. **Bump Provenance:**
   - `cd Provenance && git fetch && git -c submodule.recurse=false pull --rebase --autostash origin develop`.
   - `git update-index --cacheinfo 160000,<full sha>,Cores/Dolphin/dolphin-ios`, then `git commit` with NO pathspec. `git commit -- <path>` records the submodule's checked-out commit instead.
   - Push only when the user says so.

## Environment traps
- **Detached checkout:** a Provenance-side `git submodule update` detaches the shared iCube checkout to the gitlink. It has happened twice.
  - Before any commit, check `git branch --show-current` in `Cores/Dolphin/dolphin-ios`.
  - If it is detached and clean, run `git checkout develop`.
- **`core.worktree` leak:** the same command wrote `core.worktree` back into the SHARED `.git/modules/Cores/Dolphin/dolphin-ios/config`. New linked worktrees then resolve their top level to the gitdir (thousands of "changed" files).
  - Auto mode blocks fixing shared config. The user can run:
    `G=<Provenance>/.git/modules/Cores/Dolphin/dolphin-ios; cp "$G/config" "$G/config.bak-$(date +%s)" && git config --file "$G/config" --unset core.worktree`
  - Per-worktree workaround: `git config --worktree core.worktree <wt>`, or pass `--git-dir="$(sed 's/^gitdir: //' <wt>/.git)" --work-tree=<wt>`.
- **Worktree setup:**
  1. `git worktree add <wt> -b feature/controller-hub-phase3 develop`
  2. Verify with `git -C <wt> rev-parse --show-toplevel`.
  3. `rsync -a --exclude='.git' <main>/Externals/ <wt>/Externals/`
  4. `/bin/cp -Rc <main>/Source/iOS/App/venv <wt>/Source/iOS/App/venv`
  5. `tuist generate --no-open`
  6. Run a baseline `make test`. The first run compiles the core and is slow.
  7. Removing the worktree later needs `--force` (the copies are untracked). Ask the user.
- **Tracked prebuilts:** local builds rewrite `build/xcframework`; run `git checkout -- build/xcframework` before committing.
  - A core (C++) change needs a prebuilt refresh for Provenance's prebuilt consumers: `python3 BuildiOSXCFramework.py --platforms OS64 SIMULATORARM64 TVOS SIMULATOR_TVOS` in a worktree, check the four slices, commit, then bump Provenance.
  - Last refreshed at `519ee560ff`.
- **Shell:** `rm`/`cp` are aliased interactive, so use `/bin/rm -f` and `/bin/cp -f`. zsh does not word-split a variable holding a command.

## Resume prompt (paste into the new session)
> Continue the iCube Controller Hub. Read docs/handoff-2026-09-30-controller-hub-phase3-start.md and the memory note icube-controller-hub first. Confirm Phase 2 is pushed and Provenance is bumped, as that doc explains. Then use superpowers:writing-plans to write the Phase 3 (player screen) plan from the approved spec, reusing the Phase 2 approach: an Opus drafter, then a Sonnet plan review against the spec. Bring me any decisions beyond the spec before execution.
