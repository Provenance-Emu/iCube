# Default-settings evaluation (iOS + tvOS) — 2026-09-26

Goal: decide the shipped defaults for the shader compilation mode and the Apple-Silicon
"engine optimization" knobs from measurements, not folklore. Driver:
`Source/iOS/App/Project/Scripts/perf_matrix.py` (one-factor-at-a-time, palindrome order,
uncapped speed + adaptive clock off via the `benchmarkBase` preset, results as JSON).

## Knobs, where they live, what the code says today

| Bench key | Config | Compiled default | Read | UI text today |
|---|---|---|---|---|
| `gfxShaderCompilationMode` | `GFX_SHADER_COMPILATION_MODE` | 0 Synchronous = "Specialized" | video backend init (boot) | "Specialized (default)…" |
| `mainCachedInterpreterPrefetch` | `MAIN_CACHED_INTERPRETER_PREFETCH` | **false** | `CachedInterpreter::Init` (boot) | said "ON by default and generally a small win" — WRONG. The core comment says the hints measured slower (+33 % by removal). Caption fixed 2026-09-26 |
| `cirPsNeon` | `MAIN_CIR_PS_NEON` | false | `Interpreter::RefreshNeonPairedConfig` (boot) | dev A/B flag (PerformanceABView) |
| `gfxHackNeonTextureDecode` | `GFX_HACK_NEON_TEXTURE_DECODE` | true | `VideoConfig::Refresh` (hot) | "ON by default" — correct; off = byte-identical scalar reference decoder |
| `vertexLoaderMode` | UserDefault `icube_vertex_loader_mode` | 1 NEON | loader creation (boot) | "NEON SIMD (default)" |

Both platforms share these defaults (no `TARGET_OS_TV` branch touches any of them).

## Method

1. DEV build with "Perf Test Bench (HTTP)" on, USB `iproxy 8726 8723 -u <udid>`; boot the title, play
   into a busy 3D scene, save to slot 1. Phone unlocked, auto-lock off.
2. `python3 Source/iOS/App/Project/Scripts/perf_matrix.py --slot 1 --seconds 20`.
   Each factor = one `/api/bench/sweep` in palindrome order; boot-time keys reboot per value.
3. Read `d speed` (raw interpreter throughput, uncapped) for CPU knobs; for the shader mode read
   `p95 ms` and `1% low` (stutter), not speed. Run the shader factor twice: once with the shader
   cache cleared (first-play experience) and once warm.
4. `--pair KEY=v ...` at the end = "all proposed defaults" vs current, ABBA.
5. Titles: one GC (Melee or Wind Waker) and one Wii (Galaxy) minimum; tvOS the same on the Apple TV.

Traps (all hit before): alternate-not-ABBA credits drift to the flag; 100 % throttle saturates
speed at 1.00; long cooldowns auto-lock the phone; `icube.cirProfile` re-enables the profiler.

## Results

### Run 1 — Wind Waker (GZLE01), Outset Island slot 1, iPhone 16 Pro Max, DEV build 2606-2042,
20 s per leg, palindrome order, speed uncapped, adaptive clock off, thermal "fair" throughout

| Factor | A (current) | B | speed A | speed B | Δ | per-pair Δ | verdict |
|---|---|---|---|---|---|---|---|
| gfxShaderCompilationMode | 0 specialized | 2 hybrid uber | 1.298 | 1.357 | **+4.6 %** | +6.7 % / +2.6 % | consistent win; p95 29.1 → 26.6 ms |
| gfxShaderCompilationMode | 0 specialized | 1 exclusive uber | 1.298 | 1.262 | −2.8 % | −1.6 % / −3.9 % | consistently worse (GPU cost every frame) |
| mainCachedInterpreterPrefetch | 0 | 1 | 1.332 | 1.319 | −1.0 % | +0.5 % / −2.5 % | noise; keep OFF |
| cirPsNeon | 0 | 1 | 1.325 | 1.309 | −1.2 % | −2.5 % / 0.0 % | noise-to-negative; 1 % low worse (34 vs 28 ms) |
| gfxHackNeonTextureDecode | 1 | 0 | 1.339 | 1.298 | −3.1 % | −3.6 % / −2.5 % | NEON ON is a consistent win; keep ON |
| vertexLoaderMode | 1 NEON | 0 software | 1.303 | 1.356 | +4.0 % | +7.6 % / +0.7 % | first NEON leg (1.264) looks like an outlier; repeat below |

Capped control (100 % throttle, warm shader cache): every mode holds 30.0 fps, p95 34.3–35.0 ms,
so on a warm cache the shader mode does not change stutter on Outset; the win is throughput/headroom.

Raw: `docs/perf/data/2026-09-26-GZLE01-outset-run{1,2,3-coldcache}.json`.

### Run 2 — same state, reversed value order (confirmation)

| Factor | values (order) | speed | per-pair Δ | verdict |
|---|---|---|---|---|
| vertexLoaderMode | 0 software vs 1 NEON | 1.310 vs 1.308 | +3.1 % / −3.4 % | **no difference**; run 1's +4 % was one slow NEON leg. Keep NEON |
| gfxShaderCompilationMode | 2 hybrid vs 0 specialized | 1.319 vs 1.364 | −1.0 % / +8.1 % | did **not** replicate run 1's +4.6 % |
| gfxShaderCompilationMode | 1 exclusive vs 0 specialized | 1.276 vs 1.364 | −6.7 % / +0.4 % | below specialized again |

### Combined, all legs (uncapped throughput, Outset)

| Mode | legs | mean speed |
|---|---|---|
| 0 specialized | 1.247 1.349 1.337 1.391 | 1.331 |
| 2 hybrid uber | 1.331 1.384 1.351 1.287 | 1.338 |
| 1 exclusive uber | 1.227 1.296 1.260 1.292 | 1.269 |

Read: with a warm shader cache the scene is CPU-bound and specialized vs hybrid is a wash (+0.5 %,
inside the ±4 % leg-to-leg scatter); exclusive ubershaders cost a consistent ~4.5 % (every exclusive
leg is below every specialized leg but one). The perceived "hybrid/exclusive feel faster" is therefore
not throughput — it has to be first-compile stutter, which the warm-cache capped control cannot show
(all modes 30.0 fps, p95 within 0.7 ms). Run 3 disables the disk shader cache to force cold compiles.

### Run 3 — cold shader cache (`--pre gfxShaderCache=false --capped`), same state

| Mode | fps | p95 ms | 1 % low ms | max ms |
|---|---|---|---|---|
| 0 specialized | 29.8 | 34.8 / 34.7 | 42.8 / 41.2 | 44 |
| 2 hybrid uber | 29.9 | 34.9 / 35.3 | 43.0 / 43.6 | 44 |
| 1 exclusive uber | 29.9 / 30.0 | 34.9 / 35.0 | 39.4 / 42.7 | 44 |

No difference: the bench settles after the state load, so Outset's shaders are compiled before
sampling starts and nothing new appears while standing still. **Measuring compile stutter needs a
scene that introduces shaders during the window** (a scripted camera pan / area transition, or
input injection the debug API does not have yet). Until then the stutter claim rests on Dolphin's
design (hybrid = ubershader while the specialized one compiles), not on a number from this phone.

### Run 4 — the ten Cached Interpreter optimizations that are OFF in the compiled defaults but ON on this phone
(same state, DEV build 2606-2057, 20 s legs, palindrome 1,0,0,1, thermal nominal→fair)

| Knob | ON (your phone) | OFF (compiled default) | OFF vs ON | per-pair | legs |
|---|---|---|---|---|---|
| `cirSpecializedFpLs` | 1.459 | 1.429 | -2.1 % | -5.9 % / +2.1 % | 1.519 1.43 1.428 1.399 |
| `cirSpecializedPsq` | 1.334 | 1.317 | -1.3 % | +1.5 % / -4.0 % | 1.331 1.351 1.283 1.337 |
| `cirSpecializedFpArith` | 1.294 | 1.328 | +2.6 % | -0.3 % / +5.7 % | 1.336 1.332 1.324 1.253 |
| `cirDynTargetCache` | 1.327 | 1.333 | +0.5 % | -1.2 % / +2.2 % | 1.324 1.308 1.359 1.33 |
| `cirGatherPipeCopyFusion` | 1.314 | 1.288 | -1.9 % | -2.5 % / -1.4 % | 1.313 1.28 1.297 1.315 |
| `cirDeadFlagElim` | 1.286 | 1.297 | +0.8 % | -0.3 % / +2.0 % | 1.301 1.297 1.297 1.272 |
| `cirDeadFprfElim` | 1.303 | 1.327 | +1.8 % | +3.2 % / +0.5 % | 1.294 1.335 1.319 1.312 |
| `cirPsqFastPath` | 1.285 | 1.310 | +1.9 % | -3.4 % / +7.7 % | 1.33 1.285 1.335 1.24 |
| `cirStoreLoopFF` | 1.274 | 1.323 | +3.8 % | +6.5 % / +1.1 % | 1.244 1.325 1.32 1.305 |
| `cirCacheLoopFF` | 1.312 | 1.308 | -0.3 % | +0.0 % / -0.5 % | 1.308 1.308 1.309 1.316 |

Read: nothing here clears the ±4 % leg scatter with n=2. Store-Loop fast-path OFF read +3.8 % with both
pairs agreeing and Dead-FPRF OFF +1.8 % with both agreeing — weakly negative for those two on Wind
Waker; every other knob is a wash on this scene. Chibi-Robo / F-Zero (paired-single-heavy) are the
titles these were written for and are the right place to re-run before promoting any of them.
Raw: `docs/perf/data/2026-09-26-GZLE01-outset-run4-cir-optimizations.json`.

## Decision

| Knob | Today | Data | Recommendation |
|---|---|---|---|
| Shader compilation | Specialized | hybrid = specialized on throughput (+0.5 %, noise); exclusive −4.5 % consistently; stutter unmeasured | **Flip to Hybrid Ubershaders on iOS + tvOS**: zero measured cost, removes first-compile stutter by construction. Never Exclusive |
| CachedInterpreter Prefetch | OFF | ON −1.0 %, mixed sign | keep OFF (matches the core comment) |
| Paired-single NEON (`cirPsNeon`) | OFF (this phone had it ON) | ON −1.2 %, worse 1 % low | keep OFF; do not promote |
| NEON texture decode | ON | OFF −3.1 %, both pairs | keep ON (confirmed win) |
| Vertex loader | NEON | software ±0 after repeat | keep NEON |

**Done 2026-09-26:** shader default flipped to Hybrid Ubershaders (`7e68d54562`), xcframework
refreshed (`0d46deaa76`), Provenance gitlink bumped. A device whose config already stores
`ShaderCompilationMode` keeps its value; "Reset Optimizations to Recommended" clears it.
The ten CIR optimizations (run 4) stay at their compiled defaults (off): no measured gain on
Wind Waker; captions now carry the measured note. Next measurement
worth doing: the same five factors on Galaxy (Wii, GPU-heavier) and on the Apple TV.
