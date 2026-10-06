# iCube CIR flag test matrix

On-device A/B protocol for the CachedInterpreter optimization flags that are built,
validated and shipping-disabled.

Originally written on `perf/cir-flag-matrix` (59dae76718, 26ac71dd6a), deliberately without the
TXM change so a regression was attributable to a flag and nothing else. Refreshed against
`develop` at 63fab8ddd4; every file, symbol and default below was re-checked then.

## Flag census (how the numbers are counted)

Counted from `Source/Core/Core/Config/MainSettings.cpp`. **Rule:** `MAIN_CIR_*` boolean flags,
excluding the `*_VALIDATE` twins and the three `MAIN_CIR_IR_*` engine flags (CPUCore 6 only).
`MAIN_CACHED_INTERPRETER_PREFETCH` (not `MAIN_CIR_`-prefixed) and the two integer knobs
(`MAIN_CIR_TAPE_PREFETCH_DIST`, `MAIN_CIR_TAPE_THRASH_STRIDE`, both 0) are listed separately.

That is **23** boolean flags: **9 ON by default**, **14 OFF**.

- ON: `SPECIALIZED_OPS`, `BLOCK_LINKING`, `DYN_LINKING`, `MEM_MICROOPS`, `RECORD_CHAINING`,
  `LONG_BLOCKS`, `MICRO_PAIRS`, `PIC_LOADSTORE`, `MICROOP_FUSION`.
- OFF: `SKIP_PERF_MONITOR`, `SPECIALIZED_FP_LS`, `SPECIALIZED_PSQ`, `SPECIALIZED_FP_ARITH`,
  `DYN_TARGET_CACHE`, `GP_COPY_FUSION`, `TAIL_LINK`, `PROFILE`, `DEAD_FLAG_ELIM`,
  `DEAD_FPRF_ELIM`, `PSQ_FASTPATH`, `CACHE_LOOP_FF`, `STORE_LOOP_FF`, `PS_NEON`.
- Separately OFF: `MAIN_CACHED_INTERPRETER_PREFETCH`.

(The first version of this doc said "twenty flags, four on"; the default-ON set has grown since.)

## Why these flags are worth re-testing

Most of the OFF flags are not experiments that failed — they were authored default-OFF
explicitly "for on-device A/B".

Three carry a stronger claim. `-ffast-math` entered the core build on **2 Jun**
(`58a7763cc2`) and was removed on **8 Jun** (`b48e394994`) as the root cause of the geometry
corruption. `PSQ_FASTPATH` (4 Jun), `PS_NEON` and `SPECIALIZED_FP_LS` (5 Jun) were all
authored inside that window. The 8 Jun diagnostic (`2aa7d7a8e1`) named PS_NEON as "the large
hands suspect" and forced every FP fast-path off — hours before the real culprit turned out
to be a build flag. So everything learned about those three before 8 Jun came from a
miscompiled binary and should be discarded.

They are still OFF by default, and the evidence that keeps them there is thin:

- **First measurement on a correct core: 2026-09-26.** `docs/perf/2026-09-26-default-settings-matrix.md`
  (runs 1, 4-7) ran each flag once through `perf_matrix.py` on Wind Waker and Chibi-Robo.
  Every result sits inside the ±4 % (WW) / ±8 % (Chibi) leg-to-leg scatter; pairs flip sign.
  That is "no measurable gain", not "proven useless".
- **What that run did not do:** no pass-1 correctness runs; 20 s legs with n=2 per factor (the
  40 s re-run covered only FP_ARITH and DYN_TARGET_CACHE, and the phone was in a "serious"
  thermal state the whole time); and only two titles. Chibi-Robo, one of the paired-single-heavy
  titles these flags were written for, was measured (runs 5-7) but with ±8 % scatter; F-Zero GX
  has not been measured at all. See the Result column below.
- **They are the best remaining candidates on FP-dense titles.** If PSQ_FASTPATH, PS_NEON or
  SPECIALIZED_FP_LS pays off, expect it there, and only under the protocol below (long legs, many
  legs, cool phone) — not under a 20 s two-pair sweep.

## Preconditions

Get these right or the numbers mean nothing.

1. **Disable adaptive clocking.** `adaptive_clock_enable` (NSUserDefault) drives
   `MAIN_OVERCLOCK` at runtime (`EmulationCoordinator.mm`: seeded at ~829-830, then rewritten by
   the controller's `applyCPU` block at ~933-934; the loop is skipped entirely when the default
   is false, ~768). It reacts to performance, so a faster interpreter gets silently downclocked
   and the win disappears into a lower clock instead of a higher frame rate. Turn it off and pin
   the clock for every run, baseline included. Easiest: Settings → Performance Tuning → "Adaptive
   Clock (auto VI/CPU)" off, or the `benchmarkBase` preset (`/api/bench/preset`) that
   `perf_matrix.py` applies for you. On a device with a shell:
   ```
   defaults write <bundle-id> adaptive_clock_enable -bool NO
   ```
   Bundle ids come from `Source/iOS/App/Project.swift` and differ per configuration:
   `com.joemattiello.iCube` (Debug/Release AppStore **and** Release Non-Jailbroken),
   `com.joemattiello.iCube-debug` (Debug Non-Jailbroken), `-debug-jb`, `-jb`, `-ts`,
   `-njb-patreon-beta`, `-patreon-beta-jb`, `-ts-patreon-beta`. Check the installed build.
2. **Confirm the engine.** These flags only affect `CachedInterpreter` (CPUCore 5). The three
   `MAIN_CIR_IR_*` flags are read only by `CachedInterpreterIR.cpp` (CPUCore 6) and do
   nothing unless that engine is selected — they are out of scope here.
3. **Read effective values, not defaults.** Use the Copy State dump
   (`_ICubeBuildPerfSettingsString` in `EmulationCoordinator.mm`), which prints the CIR keys it
   knows about — note it does **not** list every flag (e.g. `CACHE_LOOP_FF`, `STORE_LOOP_FF`,
   `DEAD_FLAG_ELIM`, `DYN_TARGET_CACHE` are absent), so confirm those through the settings API
   (`/api/settings`, keys such as `cirStoreLoopFF`) rather than assuming. Never assume the
   declaration in `MainSettings.cpp` is what the run used.
4. **Same title, same save, same scene, same thermal state.** Let the device cool between
   runs; sustained load throttles and will out-measure any of these flags.
5. **A CPU-bound GameCube title**, not a GPU-bound Wii one. Metroid Prime and the Lego titles
   were used during the original investigation; Wind Waker (Outset) and Chibi-Robo were used for
   the 2026-09-26 runs. For the FP/paired-single flags prefer an FP-dense title.
6. **Use the driver.** `Source/iOS/App/Project/Scripts/perf_matrix.py` runs one-factor-at-a-time
   sweeps in palindrome (ABBA) order over the debug bench, which cancels linear thermal drift.
   Prefer it to hand-timed alternation, and use `--seconds 40` with at least 8 legs per knob for
   anything you intend to believe (20 s / 4 legs did not separate these flags from noise).

## The two-pass protocol

The VALIDATE twins are a **correctness oracle, not a performance one**. They double-run every
op against the generic handler, so a VALIDATE build is meaningfully slower by construction.
Never quote a number from a VALIDATE run.

**Pass 1 — correctness.** One flag on, its `…_VALIDATE` twin on. Play until the hot paths are
well exercised. Any mismatch is reported by the harness. A flag that fails here stops; do not
measure it.

**Pass 2 — speed.** Same flag on, VALIDATE **off**, `MAIN_CIR_PROFILE` on (NSUserDefault
`icube.cirProfile`: Settings → Performance Tuning → Diagnostics → "CIR Hot-Block Profiler", the
`cirProfile` settings-API key, or `defaults write <bundle-id> icube.cirProfile -bool YES`).
Reboot the game, then take the `=== CIR HOT BLOCKS ===` report from Copy State
(or `GET /api/debug/hot-blocks`). The %cyc column is guest cycles: a host-side win leaves it
unchanged, so judge speed from fps/throughput and use the report only to locate hot code.

**Pass 3 — combine.** Only after each flag has passed 1 and 2 alone, enable the winners
together and re-measure. Gains are not additive: several of these touch the same handlers.

## The matrix

All nine have a bridge setter in `DOLConfigBridge.mm` and a labelled toggle in
Settings → Performance Tuning → Engine Optimizations (only shown when the CachedInterpreter or
IR engine is selected). Nothing needs building.

Record: baseline FPS/speed%, flag-on FPS/speed%, delta, and the top three hot blocks.

The Result column holds the only measurements to date (2026-09-26, speed-only, ON vs OFF;
WW = Wind Waker Outset, CR = Chibi-Robo; "noise" = pairs disagree or inside leg scatter). None
has a pass-1 correctness result recorded.

| # | Flag | Settings label | VALIDATE twin | Priority | Result |
|---|------|----------------|---------------|----------|--------|
| 1 | `PS_NEON` | NEON Paired-Single Math | yes | **First** — miscompile window | WW −1.2 % (worse 1 % low), CR +2.7 %; noise |
| 2 | `PSQ_FASTPATH` | Paired-Single Float Fast-Path | yes | **First** — miscompile window | WW −1.9 %, CR −0.5 %; noise |
| 3 | `SPECIALIZED_FP_LS` | FP Load/Store Specialization | no | **First** — miscompile window | WW +2.1 %, CR −0.6 %; noise |
| 4 | `SPECIALIZED_FP_ARITH` | FP / Paired-Single Arithmetic Specialization | shared (see note) | **First** — FP family | WW −2.6 %; CR +3.6 % (20 s), −2.6 % (40 s, throttled); not confirmed |
| 5 | `SPECIALIZED_PSQ` | Paired-Single Load/Store Specialization | no | Second | WW +1.3 %, CR −6.8 %; noise |
| 6 | `DEAD_FLAG_ELIM` | Dead Flag Elimination | yes | Second | WW −0.8 %, CR −6.3 %; noise |
| 7 | `DEAD_FPRF_ELIM` | Dead FPRF Elimination | yes | Second | WW −1.8 %, CR −1.3 %; weakly negative |
| 8 | `CACHE_LOOP_FF` | Cache-Management Loop Fast-Forward | yes | Third | WW +0.3 %, CR −1.2 %; noise |
| 9 | `STORE_LOOP_FF` | Store-Loop (memset) Fast-Path | yes | Third | WW −3.8 % (both pairs), CR +7.3 % (pairs disagree); noise |

### Interaction notes

- `PSQ_FASTPATH` is a *compute* optimization inside the dequant/quant switch;
  `SPECIALIZED_PSQ` is a *dispatch* specialization. The source calls them orthogonal, so
  measure separately before combining.
- `SPECIALIZED_FP_LS` is the FP analogue of the already-on `SPECIALIZED_OPS`. Expect its
  benefit to scale with FP density in the title.
- `DEAD_FLAG_ELIM` emits a byte-identical instruction stream when off, so a null result is a
  real null result, not a measurement artefact.
- `SPECIALIZED_FP_ARITH` declares a `…_VALIDATE` twin for symmetry, but it is **not read**.
  Its double-run check rides `MAIN_CIR_SPECIALIZED_OPS_VALIDATE` instead (the regime is chosen
  by `IsLoadStoreSpecOp`, which is handler-agnostic). Enable that one for its pass-1.
- `PS_NEON` falls back to running a whole op scalar on any lane failure, to preserve `NI_*`
  FPSCR exception ordering. A title that trips that path often will show little gain.
- `PS_NEON` is read at boot (`Interpreter::RefreshNeonPairedConfig`), so toggling it needs a
  game reboot; the same holds for the other CIR flags (read in `CachedInterpreter::Init`).

### Out of scope

- `TAIL_LINK` — **inert**. Zero readers outside its declaration in `MainSettings.cpp/.h`
  (re-verified); a reserved placeholder with a documented musttail ABI blocker. Do not include it.
- `IR_CONST_FUSION`, `IR_MICROOP_FUSION`, `IR_DEAD_FLAG_ELIM` — require CPUCore 6.
- `SKIP_PERF_MONITOR`, `PROFILE`, all `*_VALIDATE` — instrumentation, not optimizations.
- `DYN_TARGET_CACHE`, `GP_COPY_FUSION`, `CachedInterpreterPrefetch` — OFF but not part of this
  matrix; already covered by the 2026-09-26 doc (no effect either way; keep OFF). The two integer
  tape knobs (`CIRTapePrefetchDist`, `CIRTapeThrashStride`, default 0) are likewise not covered here.

## Changing a default

Only after a flag has cleared pass 1, shown a repeatable win in pass 2, and held up in
pass 3. Change the default in `MainSettings.cpp` in its own commit, citing the measured
delta and the title it was measured on. One flag per commit, so a later bisect is clean.
