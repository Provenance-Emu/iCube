# Legacy JIT write fault (iCube#46, Sentry ICUBE-AA / ICUBE-A9 / ICUBE-60)

2026-11-03. Code audit, no device repro. Base: `origin/develop` 49b114f18c.

## Symptom

`KERN_PROTECTION_FAILURE` on a write into the JIT region (e.g. `0x151000000`) on `jit: legacy`
boots (iOS 17/18, sideloaded, debugger-enabled JIT, not the iOS 26 TXM path):

- ICUBE-AA: in `Arm64Gen::ARM64XEmitter::EncodeLoadStorePair`, during boot; two iPads crash on
  every boot.
- ICUBE-A9: same fault in `Arm64Gen::ARM64CodeBlock::PoisonMemory`.
- ICUBE-60: pre-dSYM builds, same `KERN_PROTECTION_FAILURE` write inside the core; probably the
  same bug.

## Root cause (proven from code)

**The legacy write-enable toggle has been a no-op on iOS/tvOS since `891d8f4ea2` (2026-06-02,
"rebaseline cluster 7 ... onto 2509"). The legacy region is never made writable, so the first
emitter write into it faults.**

The chain:

1. `EmulationCoordinator.mm:1910` selects `JitType::Legacy` when JIT is available and the TXM /
   Luck paths are not used.
2. `MemoryUtil_iOS_Legacy.cpp:22` maps the region `PROT_READ | PROT_EXEC`, `MAP_ANON |
   MAP_PRIVATE`. There is no `MAP_JIT` and no writable alias (`AllocateWritableRegionAndGetDiff`
   returns 0 for Legacy, `MemoryUtil_iOS.cpp`), so the emitter writes through the RX address.
3. Every JIT write site takes `ScopedJITPageWriteAndNoExecute(region)` →
   `JITPageWriteEnableExecuteDisable` (`MemoryUtil_iOS.cpp:86`) →
   `JITPageWriteEnableExecuteDisable_Legacy` → `JITMemoryTracker::JITRegionWriteEnableExecuteDisable`
   (`JITMemoryTracker.cpp:56`). On the outermost scope the tracker calls
   `UnWriteProtectMemory(start, size, false)` (`JITMemoryTracker.cpp:66`), and on exit
   `WriteProtectMemory(start, size, true)` (`JITMemoryTracker.cpp:91`).
4. `MemoryUtil.cpp:249-265` / `285-298`: under `defined(__APPLE__) && defined(_M_ARM_64)`, both
   functions skip `mprotect` entirely when `TARGET_OS_IOS || TARGET_OS_TV`, and return `true`.
   The comment justifies it with "pthread_jit_write_protect_np for Legacy" and "mprotect()
   returns EPERM on MAP_JIT". Both premises are wrong for Legacy: Legacy never calls
   `pthread_jit_write_protect_np` (it is unavailable on iOS), and its region is not `MAP_JIT`.
5. Before `891d8f4ea2` the guard was `#elif !(defined(_M_ARM_64) && defined(__APPLE__) &&
   !defined(IPHONEOS))`. With `-DIPHONEOS` (`CMakeLists.txt:464`) that is true on iOS, so
   `mprotect` ran. That is the behaviour OatmealDome's `32d0b77a7f` ("Implement Legacy
   executable memory behaviour") was written against.

So the tracker's refcount goes up and down correctly, but the page never leaves RX.

The first writes after boot match both Sentry signatures:

- `JitArm64::Init` → `GenerateAsmAndResetFreeMemoryRanges` → `GenerateAsm`
  (`JitAsm.cpp:33`, scope taken) → the prologue's `ABI_PushRegisters` emits `STP` →
  `EncodeLoadStorePair`. This is **ICUBE-AA**.
- `JitArm64::ClearCache` (`Jit.cpp:201`, scope taken) → `ClearCodeSpace` → `PoisonMemory`.
  This is **ICUBE-A9**.
- `VertexLoaderARM64::VertexLoaderARM64` (`VertexLoaderARM64.cpp:54-59`) → `ClearCodeSpace`
  under its own scope, on the video thread.

Every alpha tag in the repo (`alpha-105` onward) contains `891d8f4ea2`.

### What is assumed, not verified

- **`mprotect` RX→RW→RX on a plain anonymous mapping works on iOS 17/18 under CS_DEBUGGED.**
  Not verified on a device in this session. The evidence for it: this was DolphiniOS's legacy
  behaviour before the rebaseline, and the legacy allocator was written for it.
- **Legacy boots on the Cached Interpreter (core 5) should crash too.** Prediction, not
  verified. `EmulationCoordinator.mm:1913` still selects `VertexLoaderType::Native` for them, so
  `VertexLoaderARM64`'s constructor runs `ClearCodeSpace` on an RX page, on the video thread.
  To confirm or falsify it, query Sentry for a `PoisonMemory`/`VertexLoaderARM64` fault with
  `jit: legacy`, or for any successful legacy JIT boot on a build after June 2026.
- **ICUBE-60's alpha-13 events.** Not checked. If those builds predate `891d8f4ea2` (there is
  no `alpha-13` tag here to check), they need a separate explanation.

## Other hypotheses from the brief, checked

Ranked by how much they could contribute. None of them is needed to explain the crash.

| # | Hypothesis | Verdict |
|---|---|---|
| 1 | Toggle is a no-op (above) | **Proven.** Sufficient on its own. |
| 2 | `FindRegion` miss for a guard pointer (far code, sub-region) | **Ruled out.** The JitArm64 region is a single allocation of `TOTAL_CODE_SIZE` with all four near/far child spaces carved out of it (`Jit.cpp:95-99`), registered with its full size. Guards pass `GetRegionPtr()` (exact key) or interior pointers (`JitArm64Cache.cpp:86,107`), which the range scan finds. The scan used `ptr <= region_end` (inclusive). That is off by one but harmless, because an exact-key match runs first. Fixed to half-open anyway. |
| 3 | Register/unregister race on address reuse | **Real but narrow.** `FreeExecutableMemory_Legacy` called `munmap` *before* `UnregisterJITRegion`. Another thread (video thread creating a vertex loader vs. CPU thread freeing the JIT region) can be handed the same start address in between. Its `RegisterJITRegion` then PanicAlerts "already registered" and does not register, and the late `Unregister` erases the entry, so the new region is untracked. It is not the boot crash. Fixed by unregistering first. |
| 4 | Nested scopes dropping writability | **Ruled out.** The counter is per region and guarded by the mutex. The page goes back to RX only when the count reaches 0. Cross-thread nesting on one region (A enters, B enters, A leaves) keeps it RW until B leaves. |
| 5 | Backpatch handler on a thread that did not take the scope | **Not a problem for the tracker.** iOS uses the Mach exception thread, not sigaction (`MemTools.cpp:123`; `USE_SIGACTION_ON_APPLE` is not defined anywhere). `HandleFastmemFault` takes the scope on that thread (`JitArm64_BackPatch.cpp:346`) while the faulting CPU thread is suspended outside any scope, so the count is 0 → RW → patch → RX. The tracker is region-wide, not per-thread, so the thread identity does not matter. Note: a region-wide toggle makes the whole JIT region non-executable while any scope is held. That is safe only because the CPU thread is the only thread that executes it. |
| 6 | `VertexLoaderARM64` vs the CPU JIT on an overlapping page | **Ruled out.** Each vertex loader is its own `mmap` (4096 bytes, rounded up to a 16 KiB page) and its own tracker region. Separate mappings never share a page. Its `WriteProtect(true)` inside the scope (`VertexLoaderARM64.cpp:59`) is a no-op on iOS and is left that way. |
| 7 | `ClearCache` / `Reset` paths writing outside a scope | **Ruled out.** `ClearCache` holds the scope across all four `ClearCodeSpace` calls and `GenerateAsm`. `Init`'s writes all happen in `GenerateAsm`, which takes its own scope. |

## Secondary findings (same root change, out of scope, not fixed)

- **`JitBase::UnprotectStack` is a no-op on iOS** (`JitBase.cpp:233`): `ReadProtectMemory`
  still `mprotect`s the BLR stack guard to `PROT_NONE`, but `UnWriteProtectMemory` no longer
  undoes it. `HandleStackFault` therefore "unprotects" and returns true, the retry re-faults,
  and the second fault crashes, on every JIT type including TXM. This only matters when a game
  overflows the BLR guard. The stack-guard path is shared with TXM, so it is listed here and
  left alone.
- **DSP IRAM write protection is a no-op on iOS** (`DSPCore.cpp:179,410-412`,
  `DSPHWInterface.cpp:280-282`, `DSPInterpreter.cpp:251-253`). This is harmless: it is a safety
  net against stray writes, not something correctness depends on.

## Fix (this branch)

- `JITMemoryTracker` now changes protection itself, with `mprotect` (RW on enter, RX on the
  outermost exit). It no longer calls the shared `Un/WriteProtectMemory`, which stay no-ops on
  iOS/tvOS, so the TXM and LuckNoTXM regions are untouched. Only the Legacy allocator registers
  regions with the tracker. App Store builds never select Legacy JIT (no JIT at all).
- `mprotect` failures are captured (errno) under the tracker mutex and reported with
  `PanicAlertFmt` only after the mutex is released. A blocking alert must not wedge another
  thread waiting on the tracker. The alert text becomes a Sentry breadcrumb via
  `MsgAlertManager` (`d864b8978b`).
- `FreeExecutableMemory_Legacy` unregisters before `munmap`. `FindRegion` uses a half-open
  range.
- Corrected the misleading comment in `MemoryUtil.cpp`, and added a line to
  `docs/dev/fork-patches.md` so the next rebaseline does not drop it again.

## Diagnostic for the next occurrence

- The tracker keeps a fixed 64-entry ring of POD records: op, region start, size, nest count
  before/after, `mprotect` result/errno, thread id, and a monotonic timestamp. The record is
  written once per *outermost* toggle and per register/unregister, never per instruction. There
  is no allocation and no logging on the hot path.
- `Common::FormatLegacyJITTrackerState(addr)` names the region containing `addr` (start, size,
  nest count, last toggle) and dumps the ring.
- `JitArm64::HandleFault`'s unhandled path calls it when the fault address falls inside a
  tracked Legacy region. It logs at ERROR and passes the text to an optional non-blocking
  reporter, `Common::SetLegacyJITFaultReporter`. The app registers that reporter on Legacy
  boots and turns the text into a Sentry breadcrumb before the crash is forwarded. It never
  raises an alert from the fault path.
- Limit: Dolphin's Mach exception port is installed only on the CPU thread
  (`MemTools.cpp:230-235`). A fault on the video thread (vertex loader) goes straight to the
  crash reporter without this dump. There, the PanicAlert on `mprotect` failure is the signal.

## Verification

- **Host gtest** `Source/UnitTests/Common/JITMemoryTrackerTest.cpp`, built standalone against
  googletest with the Xcode toolchain on macOS arm64. 8/8 pass:
  `clang++ -std=c++20 -I<gtest>/include -ISource/Core Source/Core/Common/JITMemoryTracker.cpp
  Source/UnitTests/Common/JITMemoryTrackerTest.cpp gtest-all.o gtest_main.o`
  - Covered: nesting, half-open bounds, adjacent regions, miss/underflow/duplicate recorded,
    errno returned, ring wrap.
  - Real `mmap` RX region: writable inside the scope and `VM_PROT_READ|VM_PROT_EXECUTE` after
    (checked with `mach_vm_region`).
  - Two threads toggling and writing one region.
  - A death test showing the pre-fix no-op toggle faults on the first write. That test models
    the old behaviour with a no-op protect function. The old tracker itself was not built on
    the host, because it needs MemoryUtil, MsgHandler and fmt.
- **CMake wiring of the test** (`Source/UnitTests/Common/CMakeLists.txt`, under `if(APPLE)`):
  not run through CMake.
- **Syntax check, iOS 17 and tvOS 17 SDKs** (`-fsyntax-only -DIPHONEOS`): `JITMemoryTracker.cpp`,
  `MemoryUtil_iOS_Legacy.cpp`, `MemoryUtil_iOS.cpp`, `MemoryUtil.cpp`,
  `JitArm64/Jit.cpp` (`-std=c++23`). All clean.
- **`EmulationCoordinator.mm` (the reporter registration)**: not compiled in this session.
- **Not verified on a device.** No legacy iOS 17/18 + debugger device is available to this
  session. The owed device test: boot any game on iOS 17/18 with debugger JIT and CPU core 4 or
  5, and confirm it no longer crashes at boot.
