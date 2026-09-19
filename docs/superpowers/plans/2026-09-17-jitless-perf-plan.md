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

## The finding that changes the plan (Wind Waker, engine 5) — CORRECTED 2026-09-17
~20 % of ALL emulated cycles are one nine-block loop:
0x80244f78 (mr/mr/mtctr/bctrl) → 0x80245640 (stwu/mflr/… lwz r12,0(r5); mtctr; bctrl) →
0x80040068 (`lwz r5,4(r3); lwz r0,0(r4); cmplw r5,r0; beqlr`) → 0x80040078 (`li r3,0; blr`)
→ 0x80245664 epilogue blr → 0x80244f88 (cmplwi r3,0; beq) → 0x80244f94 (mr r3,r31;
cmplwi r31,0; beq) → 0x80244fa0 (`lwz r31,8(r31); b`) → 0x80244fac (cmplwi r3,0; bne).
23.5 M node visits / 20 s. It is NOT an idle wait: r31 walks a linked list (`next` at +8)
and the predicate returns 0 for ~190 nodes per call, ~6000 calls/s. Reconstructed from
the bytes this is the game's process-list search — fpcLnIt_JudgeOnlyHere calling
fpcSch_JudgeByID (proc->id == *key) through fpcLnIt_Judge (data->method(node->subject,
data->arg)) — i.e. fopAcM_SearchByID, which Wind Waker actors call every frame. The
loop terminates on its own; CoreTiming::Idle would not shorten it and an HLE idle hint
would be wrong. (totaldb.dsy has no entry for either function: it only carries SDK
symbols, verified by hashing the bytes with the SignatureDB checksum.) Real hardware
runs it in ~4 % of a Gekko; the interpreter pays 9 block transitions per node, 6 of them
through the dispatcher (2 bctrl, 2 blr, beqlr fallthrough, beq fallthrough). Report at
~/.icube-debug/captures/2026-09-17-ww/hot-blocks.txt. Expect the same class in other
call-heavy titles (Chibi-Robo is branch-heavy the same way).

## Ranked opportunities (each one build + one boot to verify)
1. **Dynamic block links (LANDED 2026-09-17, `CIRDynLinking`, iCube 378d06cc33).** Every
   LinkBlock trampoline carries a single-entry inline cache of the last dynamic successor
   (blr/bctr target, bcx fallthrough); a repeat hops without the dispatcher, validated by
   pc + feature_flags + a generation bumped on every DestroyBlock. bcctr got an inline
   terminal too. Hot-blocks report prints dyn_link_hits/misses.
   **Measured (core 5, honest preset = adaptive clock OFF + 100 % clocks, thermal nominal,
   `speed` = fraction of real time, alternating on/off legs with a throttled cool-down
   before each, 30 s same-scene samples):**
   | game | dyn ON | dyn OFF | gain |
   |---|---|---|---|
   | Wind Waker (GZLE01) intro | 0.607, 0.608, 0.591 | 0.578, 0.577, 0.563 | **+5 %** |
   | Chibi-Robo (GGTE01) intro | 0.477, 0.473 | 0.442 | **+8 %** |
   | Chibi-Robo, later scene, drift-controlled | 0.528 | 0.488 | **+8 %** |
   Wind Waker inline-cache hit rate 92 % (67.2 M hits / 5.6 M misses); ~half of all block
   exits are dynamic. The gain is smaller than the 20 % the "idle loop" story promised
   because the search loop is real work: the cache only removes the dispatcher round-trip,
   not the 9 blocks per node. Idle detection for this loop is OFF the table (it terminates
   on its own); a genuine multi-block idle detector must prove the loop is side-effect-free
   AND non-terminating, which this one is not.
   **Measurement method that finally worked (everything else lied):** `~/.icube-debug/ab.py`
   over the debug API (`/api/debug/boot|stop`, `/api/bench/preset`), see memory
   `icube-remote-ab`. Adaptive-clock fps numbers are meaningless (the clock persists across
   boots); 3 consecutive legs drift with heat even at "nominal" (WW .653/.576/.517); the
   phone auto-locks mid-game unless the app disables the idle timer (fixed 40fc5e427b).
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
5. **JIT for iOS/tvOS 26+ (TXM) — NEXT after the jit-less work stops paying.** Engine 4
   (JITARM64) exists and the StikDebug hand-off is wired (`Jit/StikDebugLauncher.swift`,
   `JitManager`, inline `icube.js` via the stikdebug:// scheme; the "Waiting for JIT" prompt
   in EmulationScreen). Two reference implementations to (re)base on:
   - **DolphiniOS method**: debugserver attach (StikDebug/SideStore) + `prepare_memory_region`
     on the JIT buffer; verify the TXM writable-region plumbing still works on iOS 26 and
     that engine 4 boots NSMBW/WW with it.
   - **RetroArch script method**: warmenhoven/RetroArch 79ba6a9a36 ("WIP - PIW") adds
     `RETRO_ENVIRONMENT_EXEC_MEM_ALLOC/FREE` with modes UNRESTRICTED / RWX / WX_TOGGLE /
     DUAL_MAP and Apple `exec_mem_alloc(size, mode, rx, rw)` in `pkg/apple/JITSupport.m`;
     StikDebug/StikDebug cf10cca409 adds `StikJIT/Scripts/retroarch.js`: stays attached,
     `QSetIgnoredExceptions:EXC_BAD_ACCESS|EXC_SOFTWARE` so faults cost nothing, and on a
     `brk #0x69` reads x0/x1 (addr/size) -> `prepare_memory_region`, 16 KB page rounding,
     16 MB granules to avoid debugger deadlock, then advances pc. iCube's `icube.js` should
     adopt the same brk-request protocol so one attached session serves every JIT region
     (Dolphin allocates its code space once, so this may be a single request at boot).
   Applies to tvOS 26 too (same TXM). Keep engine 5 as the default for non-JIT users.
   **Status 2026-09-18 — auto-detection implemented (DolphiniOS method).** Nothing had to be
   ported: develop is a strict superset of OatmealDome master on `Jit/`, `JitArm64/` and
   `MemoryUtil*` (their e271625b TXM refactor is already in 7bbdd9c67a). What was missing
   was activation: the boot path only issued the brk #0x69 handshake behind an env opt-in
   (`DOL_JIT_TXM=1`) nobody could set, and Info.plist baked `DOL_JIT_TXM_NOBRK=1`, an
   unproven brk-free experiment that would have replaced the real handshake. Now:
   `JitManager.debuggerAttached` (live P_TRACED via sysctl, unlike CS_DEBUGGED which
   persists after detach) drives `-shouldAttemptTXMHandshake` = TXM && acquired && attached
   now && not Xcode (`DOL_JIT_TXM` 1/0 still overrides for tests); `txmAuthorized` keeps a
   successful handshake for later boots in the same process; acquisition is re-read on every
   foreground and at boot; the "Waiting for JIT" prompt also fires on TXM devices that have
   CS_DEBUGGED but no broker; Settings > Debug shows Debugger / TXM JIT Region rows;
   `GET /api/debug/jit` and `POST /api/debug/jit/stikdebug` drive it remotely
   (`~/.icube-debug/jit_test.sh`). Why P_TRACED is the right signal: StikDebug's
   `debugApp` launches the app suspended, runs the script (icube.js waits in `c` for the
   brk, calls prepare_memory_region, advances pc) and only detaches afterwards, so the broker
   is attached exactly while a boot can brk; an unanswered brk is caught by the SIGTRAP net
   in `MemoryUtil_iOS_LuckTXM.cpp`. The phone's StikJIT 1.1 had no script support; StikDebug
   3.1.10 was rebuilt under the project team as com.joemattiello.StikJIT (keeps the pairing
   file) and installed. The StikDebug route did not come up on the phone (no device
   tunnel), so the second broker is **Xcode / any lldb** — RetroArch's
   `pkg/apple/lldb_jit_bless.py` insight: on TXM a page mapped R-X becomes executable once
   a *debugger has written to it*; `prepare_memory_region` is nothing more than one
   debugger write per 16 KB page. `Project/Scripts/dolphin_jit_lldb.py` is now that bless
   hook (stop hook on `brk #0x69` / `brk #0xf00d`: bless x0..x0+x1, leave x0 = address,
   pc += 4, stay attached on the universal detach). `SetUpPython.sh` writes
   `Derived/lldbinit` (absolute `command script import`; LLDB resolves relative paths
   against its cwd) and the NJB/JB schemes set it as `customLLDBInitFile` via Tuist. The
   repo-root `.lldbinit` is the same import with a repo-relative path for command-line
   lldb started from the repo root. `JitManager` therefore treats Xcode as a valid broker
   (the old "cannot enable JIT under Xcode" early-return is gone). 512 MiB region = 32768
   one-byte writes over USB, `DOL_BLESS_PAGES_PER_WRITE` trades bytes for round-trips.

## Guest memory access rework (2026-09-18, branch `feature/ci-fastmem-handlers`, NOT yet measured)
Why: across the three engine-5 traces guest memory access is the largest named bucket after the
executor — `LoadStoreDFormPIC` 15.7 % (WW) / 15.7 % (F-Zero) / 18.9 % (Chibi) self, plus
`WriteToHardware` 2–4 %, `ReadFromHardware` ~1 %, `Helper_Dequantize` 1–2 %. Disassembly of the
shipped handler showed a plain `lwz` costing ~40 host instructions: 8 tape loads (six of them
process-wide region constants copied into every 88-byte record), a MEM1/MEM2/fake-VMEM compare
chain, a per-access test of the prefetch debug flag, and a SECOND jump-table `br` on `inst.OPCD`.
Written on the user's call to implement first and instrument afterwards. Compiles clean for the
arm64 iOS slice (all three CachedInterpreter TUs + the IR tier); codegen verified by disassembly;
**no device run yet**.
1. **One handler per (opcode kind, D/X form, update, write_pc)** picked at emit time
   (`LoadStoreFast`, `GetLoadStoreFastCallback`, `CI_ClassifyLoadStore`): no opcode switch, no
   `rA == 0` test (those forms stay generic), no prefetch test. Record = plain `InterpretOperands`
   (24 B, was 80 B). `lwz` is now 24 instructions, no prologue, one `ret`.
2. **Page lookup through upstream's `Memory::m_logical_page_mappings` / `m_physical_page_mappings`**
   (one host pointer per 128 KiB BAT page, null = MMIO, rebuilt by `UpdateDBATMappings` on every
   DBAT change; indexed by MSR.DR). Correct under custom BATs and real mode, covers locked L1 cache
   and fake VMEM, and no longer needs the fastmem arena (the `jo.fastmem` gate is gone). Preserved
   semantics: sub-word stores through a cache-inhibited BAT fall back (data-duplication + PI
   interrupt path), everything is off under `jo.memcheck` and under the accurate d-cache.
3. **New coverage**: X-form FP (`lfsx/lfdx/stfsx/stfdx` + update, `stfiwx`), `dcbz` (HID0.DCE and
   the low-MEM1 hack honoured), `psq_l/psq_st/psq_lx/psq_stx` + update for the FLOAT quantization
   type (checked against the GQR at run time), `lmw/stmw` as a single span check.
4. **Gather-pipe stores served from the cold path** (`CI_TryGatherPipeStore`): BAT-translate, match
   `0x0C008000`, call `GPFifo::WriteN` directly instead of generic handler → `WriteToHardware`.
5. **Integer load/stores are micro-ops** (`MEM_*`), so they no longer end a fused run or cost a tape
   dispatch of their own. Cold accesses leave through a tail call (`MicroOpHandlers::MemCold`).
6. **Fused-run executor is tail-call threaded** (`MicroOpHandlers`, `[[clang::musttail]]`): the
   computed-goto version compiled to ONE shared `br` for all handlers (LLVM will not tail-duplicate
   an indirect branch with > 16 predecessors), now 58 handlers each end in their own `br`, none has
   a prologue, and the duplicate `switch` fallback is gone. Runs end in an `END` sentinel.
7. **Variable-length run records** (`WriteTruncated`, `ExecuteMicroOpsOperands::TapeSize`): a fused
   run used to occupy 784 B of tape whatever its length; a two-op run is now 56 B.
8. **Record chaining** (commit 8aa8c0331a, `CachedInterpreterEmitter::WriteChainable`,
   `CI_CHAIN_EXIT`): every non-terminal record used to return to `ExecuteOneBlock`, which walked up
   to eight pointer compares before an indirect call to the next one. Chain-capable records (fused
   runs, direct-pointer load/stores, generic `InterpretChained`, `InterpretSpecializedChained`) carry
   a tag bit in their callback slot and the erased `(ppc_state, payload)` signature; the emitter
   back-patches a record to its chaining variant when the next record is chain-capable and
   contiguous (a fused run swaps its `END` sentinel for `END_CHAIN`), and the executor tests the tag
   first, publishes the chain head in `s_chain_base` and adds the distance the last record returns.
   A chained `lwz` is 26 instructions ending in one `br`. Load/stores that can end a block stay
   generic, so the `write_pc` handler variants are gone; `Interpret<false>` is no longer emitted.
   A/B switches (default ON, settings-API keys in parentheses): `CIRRecordChaining`
   (`cirRecordChaining`), `CIRMemMicroOps` (`cirMemMicroOps`), plus the existing `CIRPICLoadStore`.
   Caveat: the Phase-0 per-record tape probes (`s_tape_prefetch_dist` / thrash stride) only see chain
   heads now.
9. **Terminals and `LinkBlock` join the chain** (d047348418): the inline bcx/bx/bclr/bcctr terminals
   are chain-capable, and a followed link (static or dynamic) tail-calls the successor block's first
   record, so one chain can span many linked blocks (`s_chain_base` keeps naming the head the
   executor entered). The running-state check and the 256-hop cap moved from `ExecuteOneBlock` into
   `LinkBlock`; a trip returns 0 and the dispatcher re-resolves pc. `LinkBlock<false>` (on the tape)
   is a 73-instruction leaf; PMC update, hot-block profiler and link validation live in
   `LinkBlock<true>`, reached by a tail call. The executor treats a 0 distance from a chain as block
   end. This is the block-transition item (2) above, done through chaining.
10. **MMU-mode titles** (220a1b218a): `checked` handler variants on an
    `InterpretAndCheckExceptionsOperands` record; the cold path delivers DSI / program exceptions
    and ends the block like the generic record. Off with watchpoints, pause-on-panic, accurate
    d-cache. Memory micro-ops stay off in MMU mode.
Deliberately NOT done: FP load/stores and FP arithmetic inside fused runs. With chaining a hop
between records costs about what a hop inside a run does (4 vs 3 instructions), so the remaining
gain is record size only, against a real ordering risk with the block-level `CheckFPU`. Revisit only
if a profile shows FP-heavy blocks dominated by record hops.
To instrument: honest preset A/B against develop on WW / Chibi / F-Zero (`ab.py`); Time Profiler for
`LoadStoreFast*`, `MicroOpHandlers::*`, `WriteToHardware`; correctness via
`MAIN_CIR_MICROOP_FUSION_VALIDATE` (ALU ops only — memory micro-ops are not packed under validate
because the reference double-run cannot repeat an MMIO access), FIFO recordings and savestate
compares. Not done: gather-pipe `psq_st`.

## Method (non-negotiable, it found everything above)
Same-session A/B on the phone: check `cpu_core_configured` before AND after
(the phone silently sat on engine 6 for a day); thermal state must match; profile
with `profile.sh` + `tpsum.py`; instruction histogram against the trace-UUID-matched
dylib; hot-blocks report for the guest side; commit with numbers. Xcode's embed
step can keep a stale core in the app bundle — verify the embedded UUID.
