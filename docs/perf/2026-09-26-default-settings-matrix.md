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

_(fill in: per key, per title, per platform — paste the `== key` tables)_

## Decision

_(defaults to flip, with the numbers that justify each)_
