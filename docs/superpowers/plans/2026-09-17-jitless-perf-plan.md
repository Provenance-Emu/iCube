# Jitless performance plan (handoff, 2026-09-17)

Goal: the best emulation on non-jailbroken iOS (no executable memory). Engine 5
(CachedInterpreter, "core 5") is the shipping engine; engine 6 (IR tier) is ~1.7x
slower by design and relabelled "usually slower" — do not invest there.

## State on develop (31c2bf3da0)
Landed and device-verified this week: video-thread idle nap (heat), hidden CIR
classes (no dyld stubs), 64-byte IR nodes, inlined Memcheck, threaded IR dispatch,
prologue-free PIC load/store handlers, branchless inline PMC update, FP D-form
loads/stores on the direct-pointer path, inline bcx/bx/bclr terminals, iPad UI-hang
fix (async host-queue hops), CI fixes (vendored TestFlight action, PEP 668 venv).
Tooling: `GET /api/debug/hot-blocks?top=N` (guest hot blocks; needs
Main.Core.CIRProfile=true at boot; the profiler costs ~85 % of the CPU thread —
capture then turn it off), `/api/debug/fifo-record`, `/api/debug/fpu-selftest`,
on-device Time Profiler workflow (see memory: icube-perf-phase).

## The finding that changes the plan (Wind Waker, engine 5)
~20 % of ALL emulated cycles are one six-block spin loop:
0x80245640 (stwu/mflr/… lwz r12; mtctr; bctrl) → 0x80244f78 (mr/mr/mtctr/bctrl) →
0x80040068 (`lwz r5,4(r3); lwz r0,0(r4); cmplw r5,r0; beqlr`) → epilogue blr →
0x80244f94 (cmplwi r31,0; beq) → 0x80244fac. 11.27 M iterations / 20 s, 2–10
emulated cycles per block, no work: a wait-until-two-words-are-equal poll through
a virtual call. Dolphin's idle detection only sees single-block `b .`/load-compare
loops, so this burns the interpreter (and the phone's thermal budget) and, worse,
the adaptive clock counts it as game work and lowers the clock. Report saved at
~/.icube-debug/captures/2026-09-17-ww/hot-blocks.txt. Expect the same class of loop
in other "simple-looking but slow" titles (Chibi-Robo is branch-heavy the same way).

## Ranked opportunities (each one build + one boot to verify)
1. **Call-chain idle detection (biggest, generic).** Runtime detector in the block
   profiler path: a block whose run count explodes with no memory/register side
   effects besides stack/LR, whose successors form a cycle of ≤ 8 tiny blocks, gets
   marked idle → treat like CheckIdle (CoreTiming::Idle / advance to next event).
   Start static: identify 0x80040068 via the WW symbol map (`Data/Sys/totaldb.dsy`,
   `PPCSymbolDB`), then HLE-hook that SDK function (Core/HLE) as an idle hint — a
   per-game proof in one boot. Then generalise. Upside: ~20 % of guest cycles in WW
   plus less heat plus a truer adaptive clock.
2. **Block transitions (call-heavy games).** `bclr` returns can't be linked →
   Dispatch + GetBlockFromStartAddress + LinkBlock ≈ 8–11 % on WW/Chibi. Ideas: a
   return-address cache (predict LR → block pointer) checked before Dispatch;
   inline the fast block-map lookup in the terminal; two-way linking for bcx
   fallthrough (IR tier deopts on not-taken today).
3. **Pre-translated "tape" persisted to storage** (the flycast-style IR idea).
   The CI already translates blocks to a callback tape in RAM; what's missing is
   (a) richer superinstructions (the micro-op fusion whitelist — extend to the
   load/store + ALU + compare + branch idioms the hot-block report shows), (b)
   register-allocation-like precomputation (constant EAs, known base registers),
   (c) persistence: save the tape/IR per game to disk keyed by block hash so warm
   boots skip PPCAnalyst + emission. Data, not code — allowed on iOS. Biggest
   engineering item; measure emission cost first (`Jit`/`PPCAnalyst` symbols were
   NOT hot in WW/F-Zero, so (c) is a startup/hitch win, not a throughput win).
4. **Executor micro-costs** (~2 points each): the tape executor's callback compare
   chain (compare→jump table), LoadStore*PIC entry stalls (fp/lr pair remains),
   psq_l/psq_st quantized loads via Helper_Dequantize (flag PSQ_FASTPATH exists),
   X-form FP loads/stores (only D-form is on the direct path).
5. **JIT for sideloaders**: engine 4 (JITARM64) exists; verify it still works with
   the TXM writable-region plumbing on iOS 26 for users who can get JIT.

## Method (non-negotiable, it found everything above)
Same-session A/B on the phone: check `cpu_core_configured` before AND after
(the phone silently sat on engine 6 for a day); thermal state must match; profile
with `profile.sh` + `tpsum.py`; instruction histogram against the trace-UUID-matched
dylib; hot-blocks report for the guest side; commit with numbers. Xcode's embed
step can keep a stale core in the app bundle — verify the embedded UUID.
