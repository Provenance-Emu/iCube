# Upstream Dolphin Merge Plan (2509 → master)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan stage-by-stage. Steps use checkbox (`- [ ]`) syntax for tracking. Never merge into `develop` directly; every stage lands on the integration branch first.

**Goal:** Bring iCube's Dolphin core from its current base, upstream tag `2509` (f0519d4f6c, 2025-09-15), up to upstream `master`, keeping every iOS feature and the Metal/NEON/CachedInterpreter work intact, and leave the fork in a state where upstream can be merged routinely (monthly) instead of once a year.

**Approach:** Merge, not rebase. The fork carries 1,287 commits over the base and the last sync was itself a merge (`620b597b55 Merge tag '2509'`), so we continue tag-by-tag merges on a long-lived integration branch: `2512` → `2603` → `2606` → `master`. Each tag is one merge commit plus follow-up "fix build after 25xx" commits, gated by CI and a device soak before the next tag.

**Measured on 2026-09-14** (`git merge --no-commit` trials in a scratch worktree):

| Target | Upstream commits over base | Conflicted files | Of which `Data/Sys/GameSettings` |
|---|---|---|---|
| `2512` (2025-12-21) | 586 | 14 | 3 |
| `2603` (2026-03-11) | 1,052 | not measured, between the rows above and below | — |
| `2606` (2026-06-24) | 1,496 | 24 | 2 |
| `master` (9611279be5, 2026-09-13) | 1,864 | 55 | 32 |

Textual conflicts are small. The risk is semantic: upstream refactors that compile cleanly but change behaviour under the fork's patches, and the ~1,500 iOS-only files in `Source/iOS` that compile against Core headers upstream reorganised.

## Fork footprint that must survive (from `git diff 2509..HEAD`)

Lines changed in `Source/Core`, largest first. These are the places where "take upstream" is never the answer without reading both sides.

- `Core/PowerPC` (10,754): CachedInterpreter rewrite + CPU core `6` (the M0 callback engine in `PowerPC.h`), `Interpreter_Paired.cpp` NEON paired-single paths, `PPCAnalyst.cpp`. Upstream touched CachedInterpreter in 4 commits only; the conflict is ours to carry.
- `DiscIO/HttpBlobReader.{cpp,h}` (3,020) + `Blob.cpp` (244): HTTP-backed disc images. `Blob.cpp` conflicts at every stage.
- `InputCommon/ControllerInterface` (1,679): iOS touch/GameController backends.
- `VideoBackends/Metal` (930): `MTLGfx.mm` (fork ±526 vs upstream ±9), `MTLStateTracker.mm` (conflicts at 2606).
- `VideoCommon`: `TextureDecoder_arm64.cpp` (812), `VertexLoaderNEON.cpp` (442), `StallMetrics.cpp` (359), `AutoIRController.cpp` (272), `PerformanceMetrics.{cpp,h}` (214, conflicts at every stage).
- `Core/Config` (669): iCube settings in `MainSettings.cpp` (conflicts at 2606).
- `AudioCommon/AVAudioEngineSoundStream.mm` (453), `Common/MemoryUtil_iOS_LuckTXM.cpp` (404), `Common/HttpRequest.cpp` (190), `Common/Thread.cpp`, `Common/ArmCPUDetect.cpp`, `Core/HW/VideoInterface.cpp` (VI skip), `Core/CoreTiming.cpp` (overclock).

Fork-only additions that don't conflict but must keep compiling: `Source/iOS/**` (1,524 new files), `Externals/MoltenVK-iOS`, `Externals/ios-cmake`, `Externals/lwmem`, `Tools/mcp`, `build/xcframework` (tracked prebuilt `PVlibDolphin.xcframework` consumed by Provenance).

## Upstream changes that will bite (read these commits before the stage that contains them)

- **2512:** `Externals/fmt` submodule bump (pointer conflict; take upstream, rebuild). CMake "Unify output directory / sys directories" (`6da4bc38e1`, `fa2a250f01`) changes where `Sys/` lands; `BuildiOSXCFramework.py` and the app's resource copy phase assume the old layout. `AsyncRequests.h`, `FramebufferManager.cpp`, `TextureCacheBase.cpp` (upstream ±357) conflicts.
- **2603:** `f9c3f06f0a` moves `PerformanceMetrics` from a global into `Core::System` — the fork's adaptive-controller sensors and `StallMetrics` hang off `g_perf_metrics`. `2aba231915` System.h forward declarations — every `.mm` under `Source/iOS` that relied on transitive includes breaks. `808a82d5dd` CMake minimum 3.25 (fine: local cmake 4.4, but `cmake_minimum_required(3.13)` in our root conflicts). `03bcd564c5` Metal endEncoding change overlaps `MTLStateTracker.mm`.
- **2606:** `0cab1731d6` "Adjust emulated memory size automatically" overlaps the iOS memory reservation (`MemoryUtil_iOS_LuckTXM.cpp`, `MemTools.cpp` conflict). `Mixer.h`, `State.cpp` (STATE_VERSION bump: existing save states stop loading), `VolumeVerifier.cpp`, `Thread.cpp`, `DualShockUDPProto.h`. New submodules: `glslang`, `pugixml`, `cpp-ipc`, `cpp-optparse`, `bzip2`, `imgui`, `wil` — each needs an entry in the iOS CMake/xcframework build or an explicit "not built for iOS" exclusion.
- **master (post-2606):** toolset minimum enforcement (`24361f49d1`, `13238340ae`; AppleClang ≥ 14.0.3, we have 21), `14e3c61d62` DolphinNoGUI default OFF, `FileUtil.cpp`, 32 GameSettings inis (upstream edited inis the fork already copied; identical hunks resolve with `--theirs`).

Toolchain is not a blocker: local CMake 4.4.3 and Apple clang 21 clear every new minimum. CI pins `macos-26` + Xcode 26.3.

## Global constraints

- Integration branch `feature/upstream-merge`, cut from `develop`, with a `pre-upstream-merge` tag on `develop` for rollback. `develop` and TestFlight untouched until the whole ladder passes.
- One merge commit per upstream tag; conflict resolutions go in that merge commit; compile/behaviour fixes go in separate `fix(merge-25xx): …` commits so they can be reviewed and bisected.
- Resolution policy: `Data/Sys/**` and `Externals/**` submodule pointers → take upstream, then re-add the fork's own `Data/Sys/GameSettings` overrides (118 fork-added inis) and fork submodules. `Source/Core/**` → read both sides; never blanket `--ours`/`--theirs`.
- The fork's settings keys and their serialised ints (CPU core `6`, VI skip modes, overclock defaults) never change. New upstream keys default to upstream's default.
- Every stage must pass: `Tools/lint.sh`, `BuildiOSXCFramework.py` (xcframework), `build.yml` (NJB, JB, TrollStore archives via Tuist), `mcp-tests.yml`, and the device soak below. No stage is "done" on a green compile alone.
- Save-state compatibility breaks whenever upstream bumps `STATE_VERSION`. Document it in the release notes; do not add a load shim as part of the merge.

## Device soak (run after every stage, before starting the next)

Uses the debug MCP (`docs/dev/debug-api.md`, `Tools/mcp`) over USB. Same iPhone, same settings snapshot (`/api/settings/snapshots` "merge-baseline" taken on `develop` first).

- Boot set: NSMBW (SMNE01), Melee, F-Zero GX, Luigi's Mansion, Star Fox Assault, Chibi-Robo, one Wii Skylanders title (deReeperJosh portal path). Each: `/api/health` reaches `running`, 60 s without crash, screenshot at a fixed point.
- Perf: `/api/bench/start` sweep on the same set; fps/vps within 5 % of the `develop` baseline. Regressions are stage blockers, not follow-ups.
- Known-bug baseline: NSMBW intro cutscene screenshot (skinned meshes, see `icube-known-broken-games`). Record whether the merge changes it; a fix or a change in symptom is a finding worth its own issue.
- Save states: create at each stage, confirm the new build loads its own; note the STATE_VERSION break points.
- Settings: `snapshot_diff` against "merge-baseline" shows only keys upstream added.

## Stage 0 — Preparation (no upstream code yet)

- [x] Tag `develop` as `pre-upstream-merge` (→ 6a86139de1); cut `feature/upstream-merge` (pushed 2026-09-15).
- [x] (2026-09-15, 273 lines) Write `docs/dev/fork-patches.md`: one section per subsystem in the footprint list above, each with the reason the patch exists, the files, and the owner test (which soak item proves it still works). Generated from `git diff 2509..HEAD --stat -- Source/Core`, then curated. This is the checklist every stage is reviewed against.
- [x] (2026-09-15) Take the "merge-baseline" settings snapshot and the perf/screenshot baselines on the current `develop` TestFlight build. Captured on iPhone17,2 against `Dolphin [develop] 2509-1286` (release), NSMBW, into `~/.icube-debug/baselines/2026-09-15-merge-baseline/` (health, build-info, render-state, settings-all, 43 running screenshots, `bench-slot1-20s.json`); device snapshot `merge-baseline` and save-state slot 1 hold the bench start point. Headline: meanFps 40.35, p95 26.6 ms, 1 % low 75.1 ms, meanSpeed 0.98, thermal nominal; settings in effect: CPU core 5 (CachedInterpreter), dual core on, 1× EFB, fast math on, VI skip mode 2. Later stages compare against these with the same slot and snapshot.
- [x] Add the 7 new upstream submodules to the iOS build plan (decided 2026-09-15, see table) so Stage 3 does not discover them cold.

  | Submodule (upstream path) | Fork today | Decision |
  |---|---|---|
  | `Externals/glslang/glslang` | vendored at `Externals/glslang` | follow upstream: vendored tree deletes, gitlink replaces it; built through upstream's `Externals/glslang/CMakeLists.txt` wrapper. Needed (MoltenVK/Vulkan shader path). |
  | `Externals/pugixml/pugixml` | vendored | follow upstream. Keep `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` in `BuildiOSXCFramework.py` until the new wrapper proves it unnecessary. |
  | `Externals/bzip2/bzip2` | vendored | follow upstream. Needed (compressed blob readers). |
  | `Externals/imgui/imgui` | vendored | follow upstream. Needed (OSD). Heavy-TU note in `BuildiOSXCFramework.py` still applies. |
  | `Externals/cpp-optparse/cpp-optparse` | vendored | follow upstream; only DolphinNoGUI/DolphinTool link it, iOS builds neither. |
  | `Externals/wil` | vendored (82 files) | follow upstream; Windows-only, upstream CMake excludes it off-Windows. |
  | `Externals/cpp-ipc/cpp-ipc` | absent | genuinely new. Build it only if `Source/Core` links it on Apple platforms after 2606; otherwise gate it off in the iOS CMake invocation. Check at Stage 3 with `git grep cpp-ipc -- 'Source/Core/**/CMakeLists.txt'`. |

  Consequences: `.gitmodules` will conflict at 2606 (fork adds `MoltenVK-iOS`, `ios-cmake`, `lwmem`; upstream adds the seven above) — union both. CI and `BuildiOSXCFramework.py` must run `git submodule update --init --recursive` before configuring, and the xcframework cache key must include the new submodule SHAs.
- [x] Confirm `BuildiOSXCFramework.py` runs locally end to end on `develop` (2026-09-15: `-p OS64` incremental run, rc=0, xcframework re-created; a clean `-c` build is left to Stage 1 since CI compiles the core daily).

## Stage 1 — Merge `2512`

- [ ] `git merge 2512`; resolve the 14 conflicts (`Externals/fmt` pointer, `ApprovedInis.json`, `Core.cpp`, `CoreTiming.cpp`, `CachedInterpreter.cpp`, `Blob.cpp`, `AsyncRequests.h`, `FramebufferManager.cpp`, `PerformanceMetrics.{cpp,h}`, `TextureCacheBase.cpp`, 3 inis).
- [ ] Fix the CMake output/sys directory changes in the xcframework script and the app's resource copy phase.
- [ ] Build xcframework, build the app (all three schemes), run lint + mcp tests.
- [ ] Device soak. Record results in the PR description.

## Stage 2 — Merge `2603`

- [ ] `git merge 2603`; expect conflicts around `PerformanceMetrics`→`System`, `System.h` forward declarations, root `CMakeLists.txt`, `MTLStateTracker.mm`.
- [ ] Port the fork's perf sensors (`StallMetrics`, adaptive controller, `/api/perf/live`, bench server) onto `system.GetPerformanceMetrics()`; remove `g_perf_metrics` uses.
- [ ] Sweep `Source/iOS/**/*.mm` for missing includes exposed by the forward-declaration change (build once, fix by the compiler's list; do not add `#include "Core/System.h"` blindly).
- [ ] Build, lint, tests, device soak.

## Stage 3 — Merge `2606`

- [ ] `git merge 2606`; resolve the 24 conflicts (memory sizing vs `MemoryUtil_iOS_LuckTXM`, `MemTools.cpp`, `Mixer.h`, `State.cpp`, `MainSettings.cpp`, `Interpreter_Paired.cpp`, `VolumeVerifier.cpp`, `Thread.cpp`, `DualShockUDPProto.h`, `.gitignore`, and the recurring set).
- [ ] Wire the new submodules per the Stage 0 decision; `git submodule update --init` in CI must stay green.
- [ ] Reconcile "Adjust emulated memory size automatically" with the iOS reservation strategy: the iOS path must win on device, upstream's path must still compile.
- [ ] Note the STATE_VERSION break in `CHANGELOG`/release notes.
- [ ] Build, lint, tests, device soak.

## Stage 4 — Merge `upstream/master`, then keep current

- [ ] `git merge upstream/master`; the 32 GameSettings conflicts resolve with upstream's side; `FileUtil.cpp` by hand.
- [ ] Set `DOLPHIN_VERSION_MAJOR` / scmrev so `build_sha` in `/api/health` reports the new base.
- [ ] Full CI + device soak, then one week of nightly TestFlight from `feature/upstream-merge` (the distribute action pushes it to the public groups automatically) with the soak set re-run mid-week.
- [ ] Merge to `develop`, bump the Provenance gitlink, rebuild the tracked `PVlibDolphin.xcframework`, confirm Provenance's `build.yml` passes against it.
- [ ] Afterwards: a `chore(upstream): merge dolphin master` task on a monthly cadence while conflicts stay in the tens of files. If a month's merge exceeds ~30 non-ini conflicts, split by tag again.

## Out of scope for this plan

- The NSMBW/Star Wars skinned-mesh bug. The soak only records whether the merge moves it.
- Cross-version save-state loading (STATE_VERSION shim) — separate follow-up if users ask.
- Rebasing the fork onto upstream, or upstreaming iOS patches. Both are worth doing later and are easier once the fork is current.
