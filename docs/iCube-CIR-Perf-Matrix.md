# iCube CIR flag test matrix

On-device A/B protocol for the CachedInterpreter optimization flags that are built,
validated and shipping-disabled.

Branch: `perf/cir-flag-matrix`, based on `10da1d542a` — deliberately **without** the TXM
change on `feature/upstream-quickwins-2609`, so a regression here is attributable to a
flag and nothing else.

## Why these flags are worth re-testing

Nineteen `MAIN_CIR_*` flags exist; four are on. The rest are not experiments that failed —
most were authored default-OFF explicitly "for on-device A/B" and were never measured.

Three of them carry a stronger claim. `-ffast-math` entered `BuildCore.sh` on **2 Jun**
(`58a7763cc2`) and was removed on **8 Jun** (`b48e394994`) as the root cause of the geometry
corruption. `PSQ_FASTPATH` (4 Jun), `PS_NEON` and `SPECIALIZED_FP_LS` (5 Jun) were all
authored inside that window. The 8 Jun diagnostic (`2aa7d7a8e1`) named PS_NEON as "the large
hands suspect" and forced every FP fast-path off — hours before the real culprit turned out
to be a build flag.

**Those three have never run on a correctly compiled core.** Any impression that they are
slow or wrong came from a miscompiled binary. Test them first.

## Preconditions

Get these right or the numbers mean nothing.

1. **Disable adaptive clocking.** `adaptive_clock_enable` (NSUserDefault) drives
   `MAIN_OVERCLOCK` at runtime (`EmulationCoordinator.mm:666-667`). It reacts to performance, so
   a faster interpreter gets silently downclocked and the win disappears into a lower clock
   instead of a higher frame rate. Turn it off and pin the clock for every run, baseline
   included.
   ```
   defaults write com.joemattiello.iCube adaptive_clock_enable -bool NO
   ```
   (Sideload/JB schemes use `com.joemattiello.iCube`; the AppStore scheme
   uses a different identifier — check the installed build.)
2. **Confirm the engine.** These flags only affect `CachedInterpreter` (CPUCore 5). The three
   `MAIN_CIR_IR_*` flags are read only by `CachedInterpreterIR.cpp` (CPUCore 6) and do
   nothing unless that engine is selected — they are out of scope here.
3. **Read effective values, not defaults.** Use the Copy State dump
   (`_ICubeBuildPerfSettingsString`), which prints every `MAIN_CIR_*` key. Never assume the
   declaration in `MainSettings.cpp` is what the run used.
4. **Same title, same save, same scene, same thermal state.** Let the device cool between
   runs; sustained load throttles and will out-measure any of these flags.
5. **A CPU-bound GameCube title**, not a GPU-bound Wii one. Metroid Prime and the Lego titles
   were used during the original investigation.

## The two-pass protocol

The VALIDATE twins are a **correctness oracle, not a performance one**. They double-run every
op against the generic handler, so a VALIDATE build is meaningfully slower by construction.
Never quote a number from a VALIDATE run.

**Pass 1 — correctness.** One flag on, its `…_VALIDATE` twin on. Play until the hot paths are
well exercised. Any mismatch is reported by the harness. A flag that fails here stops; do not
measure it.

**Pass 2 — speed.** Same flag on, VALIDATE **off**, `MAIN_CIR_PROFILE` on:
```
defaults write com.joemattiello.iCube icube.cirProfile -bool YES
```
Reboot the game, then take the `=== CIR HOT BLOCKS ===` report from Copy State.

**Pass 3 — combine.** Only after each flag has passed 1 and 2 alone, enable the winners
together and re-measure. Gains are not additive: several of these touch the same handlers.

## The matrix

All eight have a bridge setter in `DOLConfigBridge.mm` and a labelled toggle in
Settings → the CIR section. Nothing needs building.

Record: baseline FPS/speed%, flag-on FPS/speed%, delta, and the top three hot blocks.

| # | Flag | Settings label | VALIDATE twin | Priority | Result |
|---|------|----------------|---------------|----------|--------|
| 1 | `PS_NEON` | NEON Paired-Single Math | yes | **First** — miscompile window | |
| 2 | `PSQ_FASTPATH` | Paired-Single Float Fast-Path | yes | **First** — miscompile window | |
| 3 | `SPECIALIZED_FP_LS` | FP Load/Store Specialization | no | **First** — miscompile window | |
| 4 | `SPECIALIZED_PSQ` | Paired-Single Load/Store Specialization | no | Second | |
| 5 | `DEAD_FLAG_ELIM` | Dead Flag Elimination | yes | Second | |
| 6 | `DEAD_FPRF_ELIM` | Dead FPRF Elimination | yes | Second | |
| 7 | `CACHE_LOOP_FF` | Cache-Management Loop Fast-Forward | yes | Third | |
| 8 | `STORE_LOOP_FF` | Store-Loop (memset) Fast-Path | yes | Third | |

### Interaction notes

- `PSQ_FASTPATH` is a *compute* optimization inside the dequant/quant switch;
  `SPECIALIZED_PSQ` is a *dispatch* specialization. The source calls them orthogonal, so
  measure separately before combining.
- `SPECIALIZED_FP_LS` is the FP analogue of the already-on `SPECIALIZED_OPS`. Expect its
  benefit to scale with FP density in the title.
- `DEAD_FLAG_ELIM` emits a byte-identical instruction stream when off, so a null result is a
  real null result, not a measurement artefact.
- `PS_NEON` falls back to running a whole op scalar on any lane failure, to preserve `NI_*`
  FPSCR exception ordering. A title that trips that path often will show little gain.

### Out of scope

- `TAIL_LINK` — **inert**. Zero readers repo-wide; a reserved placeholder with a documented
  musttail ABI blocker. Do not include it.
- `IR_CONST_FUSION`, `IR_MICROOP_FUSION`, `IR_DEAD_FLAG_ELIM` — require CPUCore 6.
- `SKIP_PERF_MONITOR`, `PROFILE`, all `*_VALIDATE` — instrumentation, not optimizations.

## Changing a default

Only after a flag has cleared pass 1, shown a repeatable win in pass 2, and held up in
pass 3. Change the default in `MainSettings.cpp` in its own commit, citing the measured
delta and the title it was measured on. One flag per commit, so a later bisect is clean.
