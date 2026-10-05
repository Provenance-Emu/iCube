# Post phase 5: state, open items and how to resume (2026-10-05)

Read this first, then `docs/handoff-2026-10-04-controllers-phase5.md` for the phase 5 detail and
its device checklist.

## Where `develop` is

| PR | What landed |
|---|---|
| #18 (`3d421a66f7`) | Controllers phase 5: Wii touch pointer, layout editor on the game canvas, `BootCore` guard, mapping overhaul, PR-scoped lint. |
| #19 (`6606d4f125`) | Phase 5 follow-ups: motion clamp fix, edge-anchored layout (v2 file), `DolphiniOS.xcodeproj` deleted and `release.yml` on Tuist, `.none` → `.gyro`, one Recommended Motion Settings, dead DSU switch and bridge methods removed, per-device profile names, lint blocking on PRs, skipped-test report, overlay-mode persistence test. |
| #20 (`b93fa7f33e`) | Fix for #19's profile-name purge (session keys carry the `player_profile_name.` prefix); `tests.yml` "Report test results" prints failed tests, crash lines and skips to the log and job summary. |

CI on #20's head: Unit Tests, build, Swift lint and clang-format all green. TestFlight run 48
(Oct 4, from `5621c3c`) carries #18 and #19 but not #20.

## Open items

1. **xcframework refresh** (Mac, housekeeping only): `python3 BuildiOSXCFramework.py --platforms
   OS64 SIMULATORARM64 TVOS SIMULATOR_TVOS`, commit as `build: refresh the prebuilt core …`. The
   committed `build/xcframework` (last refreshed `5343a78f39`, Oct 2) predates #18, but nothing
   ships it: the app target's "Build Dolphin Core" pre-script (`Project.swift`) rebuilds the slice
   being built from source on every Xcode build, and `testflight.yml` / `build.yml` run
   `BuildiOSXCFramework.py` before `tuist generate`. So TestFlight run 48 already carries the
   `BootCore` guard. The prebuilt only has to exist for `tuist generate` to resolve the binary
   target.
2. **Device checks** (none of #18–#20 has run on a phone):
   - Gyro pointer reaches all four edges; 6DOF tilt/turn register both ways (Wii Sports).
   - An existing custom layout is unchanged after updating and after moving one control; a layout
     made on a smaller iPhone keeps controls the same distance from the edges on a bigger one.
   - The phase 5 checklist in `handoff-2026-10-04-controllers-phase5.md`.
3. **User report, "pointer stuck at the top, set Vertical Offset to -10 cm":** the symptom matches
   the gyro clamp bug fixed in #19 (the pointer lost every negative value, so it could not move
   down) and the core motion pointer #18 forces off on touchscreen slots. Vertical Offset is not a
   plain shift: `Dynamics.cpp:242-244` applies it negatively when SYSCONF's sensor bar is at the
   bottom. Tell users to update to TestFlight ≥ run 48 and set Vertical Offset back to 10 cm (the
   bundled default). If it still sticks, ask which Pointer mode (Gyro, Touch Follow, Touch Drag)
   and the Settings → Wii → Sensor Bar Position.
4. **`release.yml`** has never run since it moved to Tuist; check the first published release.
5. **Policy changes to confirm on device** (from phase 5): a Wii title no longer auto-binds a pad
   to a GameCube port; Recommended Motion Settings no longer sets the pointer to Gyro.
6. **Remote branch** `claude/jolly-planck-43gyz5` carries this doc's PR; delete it after merge
   (the session git proxy refuses branch deletes).

## Environment notes

- No Xcode in a cloud session: CI is the compiler. `iCubeTests` (simulator) and `build` (device
  archive) each take 20–35 min; lint ~30 s.
- Job logs and artifacts live on `productionresultsNN.blob.core.windows.net` (several NN). The
  session's network policy blocks them; allow `*.blob.core.windows.net` in the environment's
  Network access settings, or read logs through the GitHub MCP `get_job_logs` with `tail_lines`
  (a subagent keeps the volume out of the main context). A failing test run now names its
  failures in the "Report test results" step, near the end of the log.
- `git clang-format` locally is too old for `Source/.clang-format`; trust CI's patch output.
- No swiftformat/swiftlint locally: changed lines must follow `.swiftformat` (2-space indent,
  continuation lines aligned to the opening parenthesis, blank line after `// MARK:`, no
  redundant `self.`) or the PR lint job fails.

## Conventions

- Branch `claude/jolly-planck-43gyz5`; when its PR has merged, restart it from `develop`
  (`git checkout -B … origin/develop`, `--force-with-lease` push) and open a new PR.
- Conventional commits, no AI attribution trailers; PRs as drafts, then driven to green.
- New strings: identity entries appended to both `en.lproj` and `ja.lproj` `Core.strings`.
- `git checkout -- build/xcframework` before committing an app-only change.
- Test helpers model the core faithfully: Touchscreen.mm's `m_neg` and `ControlExpression`'s clamp
  at 0 (`TCDeviceMotionMappingTests.half`). Write motion/IR values to both halves of a pair.
