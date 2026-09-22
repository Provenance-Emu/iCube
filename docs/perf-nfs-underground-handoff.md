# Jitless perf: why NFS Underground reads 100% and plays at 25fps

Handoff for the performance thread opened 2026-09-22. Everything here was
measured on device (iPhone 16 Pro Max, `Release (AppStore)`, Cached Interpreter,
no JIT), not inferred. Pick it up from **Next steps**.

## The question

Most titles hit 300% with upscaling. Need for Speed: Underground (`GNDE69`)
reports **100% speed** while rendering in the 20s and feeling worse than real
hardware.

## What is actually happening

`vps` and `fps` answer different questions and the UI shows the wrong one.

* **`vps`** is throttle-relative emulated speed — what the "100%" indicator tracks.
* **`fps`** is what the game actually renders.

Measured: **`vps` pinned at ~60 while `fps` sat at 16–29.** Emulation is
comfortably on schedule; the *game* is starving.

It starves because the **adaptive clock underclocks the emulated CPU**. Its
settle criterion is speed-only (`EmulationCoordinator.mm:881`): it descends from
1.0 and stops at the highest clock where emulated speed still holds ~100%. For
most titles f\* ≈ 1.0 and the hack is free. Here f\* settled at **0.60–0.675**,
i.e. a 33–40% underclock, and it was *right to*: forcing 0.80 raised fps to 33.6
but dropped vps to 43–52. The Cached Interpreter genuinely cannot run this game
at full GameCube clock.

So the controller is not malfunctioning. It is choosing "100% speed at 67% clock"
over "67% speed at 100% clock" and reporting success, and those two stop being
equivalent on a CPU-bound title. **The real fix is more host throughput**, which
is the rest of this document. (JIT would also erase the problem, but an App Store
build can never use it — no `get-task-allow`, TXM hard-off. `Release
(Non-Jailbroken)` sideloaded with a broker can.)

Already shipped so this is visible next time: the Speed overlay now prints
`CPU:nn% auto` whenever the emulated clock is below native (`e10e831672`).

## Where the CPU time goes

From `GET /api/debug/hot-blocks` during a real race, 4.42B block runs, with all
specialization flags **on**:

```
int ALU/other   (specialized)      40.0%
int load/store  (specialized)      25.6%
branch/terminal                    15.1%
FP load/store   (GENERIC 2-call)    9.2%
paired-single   (GENERIC 2-call)    5.6%
FP arithmetic   (GENERIC 2-call)    4.6%
→ GENERIC FP+PS paying the 2-call tax: 19.4%

dyn_link_hits 690,518,840  misses 256,186,362   → 73% hit rate
```

### Target A — the write-gather pipe, ~16.5% in one loop

Six of the top-20 blocks are one function, `0x8025e1c8`–`0x8025e2b4`
(ranks 2, 3, 4, 9, 10, 20 summing to 16.5% of cycles). Its body is `lbz`/`stb`
pairs writing **repeatedly to the fixed address `-0x8000(r8)`** with a `dcbt`
prefetch. With `r8 = 0xCC010000` that is **`0xCC008000`, the GX write-gather
pipe**: the game streams display-list/vertex data to the GPU one byte per store.

Each is an MMIO store, so it cannot take the fast path the 25.6% "specialized
load/store" bucket enjoys — it pays full address translation and then
`MMU::WriteToHardware`, which only *then* checks for the gather pipe
(`MMU.cpp:387-405`). 56 million times in one sample.

Prior art to build on, not duplicate: `MMU::IsOptimizableGatherPipeWrite`
(`MMU.cpp:1212`, how the JIT decides this, including its correctness
preconditions) and the existing bulk-`stb` fusion (`CachedInterpreter.cpp:1107`,
reference impl `:4598-4714`) — which matches *incrementing* offsets and so does
**not** match this loop's same-offset shape.

### Target B — FP / paired-single dispatch, 19.4%

**Correction to an earlier read: these flags are NOT simply switched off.**
The Config defaults are `MAIN_CIR_SPECIALIZED_OPS=true` and FP_LS / PSQ /
FP_ARITH `false` (`MainSettings.cpp:950,984,1012,1039`), but the device under
test had **all four enabled**, and the 19.4% was measured in that state.

So the GENERIC bucket is not unspecialized for want of a switch — **the
specialization sets do not cover the FP/PS opcodes this game executes**
(`CIR_SPECIALIZED_FP_ARITH_OPS`, `CIR_SPECIALIZED_PS_ARITH_OPS`,
`CIR_SPECIALIZED_PSQ_OPS`, defined around `CachedInterpreter.cpp:426-488`).
Extending them is real work, and it needs opcode-level data we do not have yet.

## Tooling, all of it new today

* **Reaching the bench at all**: see `docs/debugging-the-device-bench.md`. Short
  version — usbmux/`iproxy` does **not** reach a `Release (AppStore)` build on
  iOS 26; use the device's LAN address. The app prints both URLs at startup.
* **LAN access** (`c8cfc2eed3`, `554892a889`): an explicit Perf Test Bench opt-in
  binds all interfaces. First request from a new address prompts on-device
  (Deny / Allow Once / Always Allow); headless tooling can send
  `Authorization: Bearer <token>` from Settings ▸ Debug instead. Undo via
  Settings ▸ Debug ▸ Forget Approved Devices.
* **Keys exposed to the bench**: `cirProfile` (`8ed6f3a28e`), the clock levers
  and `adaptiveClockEnable` (`e10e831672`), and the five specialization flags
  (`f044c96cf4`).
* **Bug fixed in passing** (`3d7e4b8cac`): `/api/settings/all` called a nil
  `layerGetter` and crashed on any UserDefaults-backed key.

## Reproducing the measurement

```bash
B=http://<device-ip>:8723
curl -s $B/api/health                                   # fps vs vps — the whole story
curl -s $B/api/render_state                             # overclock_configured = f*
curl -s -X POST $B/api/settings/cirProfile -d '{"value":true}'
#   cirProfile is BOOT-TIME: reboot the title, then drive a real race (not a menu)
curl -s "$B/api/debug/hot-blocks?top=40"
```

A `GNDE69.s01` save state exists on the device for a repeatable scene.

## In flight as of this handoff

* **Agent on Target A** — fast-path gather-pipe stores in the Cached Interpreter.
  Owns `CachedInterpreter.cpp`. Told not to touch the device.
* **Agent on the bench harness** — `POST /api/bench/sweep` silently mismeasures
  **boot-time** keys: it sets the value and reloads a save state, but
  `CachedInterpreter::Init` reads its flags once per run
  (`CachedInterpreter.cpp:1397-1412`), so nothing changes between samples. Also
  returning `totalSamples: 1, stdevMs: 0` as a `summary`, and snapshotting
  `settings` at read time rather than during sampling — which is how the flag
  confusion above went unnoticed.

## Next steps, in order

1. **Land Target A**, then measure it on the `GNDE69.s01` scene. Ceiling is
   16.5%; do not expect full speed from it alone.
2. **Add a per-opcode census to the hot-blocks report.** It lives in
   `CachedInterpreter.cpp` (`BuildHotBlocksReport`, `:950`), which is why it was
   queued behind Target A rather than run in parallel. Without it, extending the
   specialization sets is guesswork.
3. **Extend the FP/PS specialization sets** using that data. Run at least one
   pass with `cirSpecializedOpsValidate` on before trusting any speedup — a wrong
   FP result that happens to be faster is worse than slow.
4. **Then revisit the 73% `dyn_link` hit rate.** For reference, the CIRDynLinking
   work measured +5–8% at a *92%* hit rate on Wind Waker, so there is headroom.

**Calibration**: f\* is 0.675, so the interpreter needs roughly a third more
throughput before the adaptive clock stops underclocking this title. Targets A
and B together are the realistic shot at that; neither alone is.
