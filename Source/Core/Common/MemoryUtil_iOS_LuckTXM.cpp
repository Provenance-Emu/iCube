// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Common/MemoryUtil.h"

#include <algorithm>
#include <csetjmp>
#include <csignal>
#include <cstdlib>

#include <libkern/OSCacheControl.h>
#include <lwmem/lwmem.h>
#include <mach/mach.h>
#include <os/log.h>
#include <stdio.h>
#include <string>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>

#include "Common/CommonFuncs.h"
#include "Common/CommonTypes.h"
#include "Common/Logging/Log.h"
#include "Common/MsgHandler.h"

// Sized to what actually gets allocated out of it, because on an iOS 26 TXM device this
// number is NOT just reserved address space:
//   * JitArm64 takes TOTAL_CODE_SIZE (= NEAR*2 + FAR*2 = 256 MiB, Jit.cpp) in ONE
//     allocation, so the region has to exceed that outright.
//   * VertexLoaderARM64 takes 4 KiB per vertex format; the allocator rounds each up to a
//     16 KiB page, and a game can build a lot of them.
//   * The allocator itself adds pagesize-1 + sizeof(void*) per block on top of lwmem's
//     own headers.
// 32 MiB of slack over the JIT's 256 MiB covers the latter two.
//
// Why not just ask for more: authorizing this region under TXM means a debugger WRITES one
// byte into every 16 KiB page of it, which faults every one of those pages in. The size is
// therefore paid twice over -- once as resident dirty memory for the whole run, and once as
// bless time at boot (a 512 MiB region measured ~12 min unpipelined, ~10 s pipelined, with
// the app frozen throughout). Keep it tight.
// Was 288 MiB while JitArm64's TOTAL_CODE_SIZE was 256 MiB. That budget is now halved to
// 128 MiB on iOS/tvOS (see the note in JitArm64/Jit.cpp) because every page here is made
// RESIDENT by the authorization pass, and 288 MiB resident was killing the app with critical
// memory pressure mid-boot when an on-device broker like StikDebug is resident too. 160 MiB
// keeps the same 32 MiB of slack over the JIT's single allocation for the vertex loaders and
// allocator overhead described above.
constexpr size_t EXECUTABLE_REGION_SIZE = 160 * 1024 * 1024;

static u8* g_rx_region = nullptr;
static ptrdiff_t g_rw_region_diff = 0;

// Xcode/StikDebug detection flag.
// Set to 1 (true) just before the broker handshake brk.  Under StikDebug the
// breakpoint is handled by StikDebug's TXM authorization script and this flag is
// never cleared.  Under Xcode, dolphin_jit_lldb.py skips the brk(s) AND writes 0
// here so that AllocateExecutableMemoryRegion_LuckTXM can detect the Xcode case
// and bail out before attempting vm_remap (which would succeed, but TXM would
// block execution from the region with KERN_CODESIGN_ERROR).
extern "C" {
  volatile int dolphin_txm_auth_status = 0;
}

static sigjmp_buf g_txm_jmp;
static volatile sig_atomic_t g_txm_trapped = 0;

static void TxmSigtrapHandler(int)
{
  g_txm_trapped = 1;
  siglongjmp(g_txm_jmp, 1);
}

// External JIT-broker "prepare region" handshake.
//
// StikDebug authorizes the RX region for execution under iOS 26 TXM by
// intercepting a sentinel breakpoint, reading x0 (address) / x1 (length), and
// calling prepare_memory_region. Two script conventions exist:
//   * Legacy   : brk #0x69            (StikDebug's UTM-Dolphin.js)
//   * Universal: brk #0xf00d, x16=1   (StikDebug's default universal.js)
// Universal additionally supports x16=0 = detach, so the broker stops looping
// once the region is prepared.
//
// We lead with the legacy 0x69 (see AllocateExecutableMemoryRegion_LuckTXM):
// UTM-Dolphin.js handles 0x69 but HANGS on an unrecognized 0xf00d (it never
// advances PC), whereas universal.js cleanly REJECTS 0x69 by writing the
// sentinel 0xE0000069 into x0 without preparing the region. So 0x69-first works
// with both scripts; on the 0xE0000069 rejection we migrate to 0xf00d.
static constexpr u32 TXM_LEGACY_REJECTED = 0xE0000069u;

static u64 TxmLegacyPrepare(void* addr, size_t len)
{
  register u64 x0 asm("x0") = reinterpret_cast<u64>(addr);
  register u64 x1 asm("x1") = static_cast<u64>(len);
  asm volatile("brk #0x69" : "+r"(x0), "+r"(x1) : : "memory");
  return x0;
}

static void TxmUniversalPrepare(void* addr, size_t len)
{
  register u64 x0 asm("x0") = reinterpret_cast<u64>(addr);
  register u64 x1 asm("x1") = static_cast<u64>(len);
  register u64 x16 asm("x16") = 1;  // CMD_PREPARE_REGION
  asm volatile("brk #0xf00d" : "+r"(x0), "+r"(x1), "+r"(x16) : : "memory");
}

// Ask for the region in granules rather than in one call.
//
// TxmUniversalPrepare issues a SINGLE brk for the whole length, which is what shipped, and it is
// not what the universal protocol is built for: the script loops servicing breakpoints until it
// sees CMD_DETACH precisely so a client can prepare repeatedly as its region grows. A broker is
// free to bless less than asked for in one call, and StikDebug's does -- it works in 16 MiB
// granules. Nothing reports the shortfall, so the app runs happily on the blessed prefix and then
// dies the moment execution reaches a page past it.
//
// Observed on an iPhone 16 Pro Max / iOS 26.6.2 with StikDebug as the broker: the handshake
// reports success ("[JitManager] TXM boot: attached=1 authorized=1"), the game runs for ~90 s, and
// then EXC_BAD_ACCESS / SIGBUS at 0x1379b8000, which the crash report places 67,125,248 bytes into
// the 128 MiB JIT code region -- i.e. exactly past the blessed prefix, on the first instruction
// fetch from a page the broker never touched. The tethered lldb broker never showed this because
// it blesses every page it is handed in one pass.
static constexpr size_t TXM_PREPARE_GRANULE = 16 * 1024 * 1024;

static void TxmUniversalPrepareAll(void* addr, size_t len)
{
  u8* cursor = static_cast<u8*>(addr);
  size_t remaining = len;
  while (remaining != 0)
  {
    const size_t chunk = std::min(remaining, TXM_PREPARE_GRANULE);
    TxmUniversalPrepare(cursor, chunk);
    cursor += chunk;
    remaining -= chunk;
  }
}

static void TxmUniversalDetach()
{
  register u64 x16 asm("x16") = 0;  // CMD_DETACH
  asm volatile("brk #0xf00d" : "+r"(x16) : : "memory");
}

// Keep the region where a broker can address it.
//
// StikDebug blesses the region by sending one gdb-remote `$M<addr>,1:69` packet per page, and it
// formats <addr> as exactly nine hex digits (fillAddress in JSDebugSupport.swift masks with
// 0xf00000000). A page at or above 64 GiB is therefore blessed at `addr & 0xFFFFFFFFF` instead, and
// StikDebug drains the replies without checking them, so the handshake reports success. The first
// instruction fetch from the real, unblessed page is then a CODESIGNING "Invalid Page" SIGKILL,
// which no signal handler sees and Sentry files as a watchdog termination. This app has
// extended-virtual-addressing, so mmap(nullptr) is free to put the region up there.
constexpr uintptr_t TXM_BROKER_ADDRESS_LIMIT = uintptr_t{1} << 36;
// Where the search for a low mapping starts: the first address above arm64 iOS's 4 GiB __PAGEZERO.
// Without MAP_FIXED this is a hint, and the kernel takes the first free range at or above it.
constexpr uintptr_t TXM_REGION_HINT = uintptr_t{1} << 32;

// The address the kernel last handed out for the region, kept even when it was rejected so the app
// can report where it landed.
static uintptr_t g_rx_region_mapped_at = 0;

static u8* MapRXRegionForBroker(size_t size)
{
  void* ptr = mmap(reinterpret_cast<void*>(TXM_REGION_HINT), size, PROT_READ | PROT_EXEC,
                   MAP_ANON | MAP_PRIVATE, -1, 0);
  if (ptr == MAP_FAILED)
  {
    ERROR_LOG_FMT(COMMON, "LuckTXM: mmap of the RX region failed: {}", Common::LastStrerrorString());
    return nullptr;
  }

  const uintptr_t start = reinterpret_cast<uintptr_t>(ptr);
  g_rx_region_mapped_at = start;
  if (start + size > TXM_BROKER_ADDRESS_LIMIT)
  {
    ERROR_LOG_FMT(COMMON,
                  "LuckTXM: RX region mapped at {:#x}, past the broker's 36-bit address limit; "
                  "not attempting the handshake",
                  start);
    munmap(ptr, size);
    return nullptr;
  }
  return static_cast<u8*>(ptr);
}

// --------------------------------------------------------------------------
// EXPERIMENT: brk-free TXM JIT path (env DOL_JIT_TXM_NOBRK=1).
//
// Open question this answers: under iOS 26 TXM, does CS_DEBUGGED (set by
// StikDebug's stock attach) plus the JIT entitlements (allow-jit,
// allow-unsigned-executable-memory, disable-executable-page-protection) ALONE
// permit execution from an RX mapping, WITHOUT the unproven brk #0x69 StikDebug
// "authorize region" handshake?
//
// Strategy: allocate the LuckTXM dual mapping exactly as the brk path does
// (RX mmap + writable vm_remap alias), but SKIP the brk. Then prove the region
// is executable BEFORE trusting it: write a tiny known function into the RW
// alias, invalidate the icache over the RX range, and CALL it through the RX
// mapping inside a fault guard. If TXM rejects RX execution it surfaces as
// EXC_BAD_ACCESS -> SIGBUS/SIGSEGV (or SIGILL/SIGTRAP); the guard catches it,
// we munmap and report failure, and the caller falls back to the Cached
// Interpreter. Worst case is a clean fallback, never a crash.
// --------------------------------------------------------------------------

// AArch64: `mov w0, #0x2A` (movz w0,#42) ; `ret`  -> returns 42.
static const u32 kTxmSelfTestCode[2] = {0x52800540u, 0xD65F03C0u};
typedef int (*TxmSelfTestFn)(void);

// Separate fault net for the NOBRK self-test. Traps the signals a TXM/codesign
// rejection of RX execution can raise so a rejected region longjmps us back to
// the failure path instead of crashing the app.
static sigjmp_buf g_nobrk_jmp;
static volatile sig_atomic_t g_nobrk_faulted = 0;

static void TxmNobrkFaultHandler(int)
{
  g_nobrk_faulted = 1;
  siglongjmp(g_nobrk_jmp, 1);
}

// Returns true if calling the test fn through rx_exec_addr returns 42 (RX
// execution permitted under TXM); false if it faulted (TXM rejected it).
// Caller must already have written kTxmSelfTestCode into the RW alias of
// rx_exec_addr.
static bool TxmNobrkSelfTest(void* rx_exec_addr)
{
  // Invalidate the icache over the RX EXECUTION address range (what the CPU
  // fetches), not the RW alias we wrote through. sys_icache_invalidate is
  // Apple's supported API and links cleanly under LTO (unlike the
  // __builtin___clear_cache libcall, which lowers to an unresolved ___clear_cache
  // in this build's link set).
  sys_icache_invalidate(rx_exec_addr, sizeof(kTxmSelfTestCode));

  struct sigaction old_bus{}, old_segv{}, old_ill{}, old_trap{};
  struct sigaction net{};
  net.sa_handler = TxmNobrkFaultHandler;
  sigemptyset(&net.sa_mask);
  net.sa_flags = 0;
  sigaction(SIGBUS, &net, &old_bus);
  sigaction(SIGSEGV, &net, &old_segv);
  sigaction(SIGILL, &net, &old_ill);
  sigaction(SIGTRAP, &net, &old_trap);

  bool ok = false;
  g_nobrk_faulted = 0;
  if (sigsetjmp(g_nobrk_jmp, 1) == 0)
  {
    TxmSelfTestFn fn = reinterpret_cast<TxmSelfTestFn>(rx_exec_addr);
    ok = (fn() == 42);
  }

  // Restore all four handlers symmetrically.
  sigaction(SIGBUS, &old_bus, nullptr);
  sigaction(SIGSEGV, &old_segv, nullptr);
  sigaction(SIGILL, &old_ill, nullptr);
  sigaction(SIGTRAP, &old_trap, nullptr);

  return ok && !g_nobrk_faulted;
}

// brk-free allocator. Returns true on success (region installed + self-test
// passed); false on any failure (region cleaned up, caller takes interpreter).
static bool AllocateExecutableMemoryRegion_LuckTXM_NoBrk()
{
  const size_t size = EXECUTABLE_REGION_SIZE;
  u8* rx_ptr = static_cast<u8*>(
      mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0));
  if (rx_ptr == MAP_FAILED || !rx_ptr)
  {
    os_log_error(OS_LOG_DEFAULT,
                 "[LuckTXM] NOBRK: mmap RX failed — falling back to interpreter");
    return false;
  }

  // Writable alias of the RX region (codegen writes here; CPU executes rx_ptr).
  vm_address_t rw_region = 0;
  vm_address_t target = reinterpret_cast<vm_address_t>(rx_ptr);
  vm_prot_t cur_protection = 0;
  vm_prot_t max_protection = 0;
  kern_return_t retval =
      vm_remap(mach_task_self(), &rw_region, size, 0, true, mach_task_self(), target, false,
               &cur_protection, &max_protection, VM_INHERIT_DEFAULT);
  if (retval != KERN_SUCCESS)
  {
    os_log_error(OS_LOG_DEFAULT,
                 "[LuckTXM] NOBRK: vm_remap failed (0x%x) — falling back to interpreter",
                 retval);
    munmap(rx_ptr, size);
    return false;
  }

  u8* rw_ptr = reinterpret_cast<u8*>(rw_region);
  if (mprotect(rw_ptr, size, PROT_READ | PROT_WRITE) != 0)
  {
    os_log_error(OS_LOG_DEFAULT,
                 "[LuckTXM] NOBRK: mprotect RW failed — falling back to interpreter");
    munmap(rw_ptr, size);
    munmap(rx_ptr, size);
    return false;
  }

  // Self-test BEFORE lwmem takes ownership: write the known fn into the RW alias
  // (so it appears at the matching offset in the RX mapping), then call it
  // through the RX mapping under the fault guard.
  *reinterpret_cast<u32*>(rw_ptr + 0) = kTxmSelfTestCode[0];
  *reinterpret_cast<u32*>(rw_ptr + sizeof(u32)) = kTxmSelfTestCode[1];

  if (!TxmNobrkSelfTest(rx_ptr))
  {
    os_log_error(
        OS_LOG_DEFAULT,
        "[LuckTXM] NOBRK self-test faulted (TXM rejected RX exec) — falling back to interpreter");
    munmap(rw_ptr, size);
    munmap(rx_ptr, size);
    return false;
  }

  os_log(OS_LOG_DEFAULT, "[LuckTXM] NOBRK self-test: RX exec OK — JIT enabled");

  // RX execution works under TXM with CS_DEBUGGED alone. Hand the RW alias to
  // lwmem and publish the region, same as the brk success path.
  lwmem_region_t regions[] = {{(void*)rw_ptr, size}, {NULL, 0}};
  if (lwmem_assignmem(regions) == 0)
  {
    PanicAlertFmt("AllocateExecutableMemoryRegion failed!\nlwmem_assignmem failed");
    munmap(rw_ptr, size);
    munmap(rx_ptr, size);
    return false;
  }

  g_rx_region = rx_ptr;
  g_rw_region_diff = rw_ptr - rx_ptr;
  return true;
}

namespace Common
{
void AllocateExecutableMemoryRegion_LuckTXM()
{
  if (g_rx_region)
  {
    return;
  }

  // EXPERIMENT (env-gated, default OFF): brk-free path. When DOL_JIT_TXM_NOBRK=1
  // we skip the brk #0x69 handshake entirely and instead prove RX execution with
  // a guarded self-test. Default (unset/!= "1") leaves the brk path below
  // completely unchanged.
  const char* nobrk = getenv("DOL_JIT_TXM_NOBRK");
  if (nobrk && nobrk[0] == '1')
  {
    os_log(OS_LOG_DEFAULT,
           "[LuckTXM] NOBRK path selected (DOL_JIT_TXM_NOBRK=1) — skipping brk handshake");
    AllocateExecutableMemoryRegion_LuckTXM_NoBrk();
    return;
  }

  const size_t size = EXECUTABLE_REGION_SIZE;
  // A failure here is not fatal: without g_rx_region, IsTXMAvailable() is false and the caller
  // falls back to the Cached Interpreter. No brk is issued, so nothing is left for a broker to hang on.
  u8* rx_ptr = MapRXRegionForBroker(size);
  if (!rx_ptr)
    return;

  // Install a SIGTRAP net so an unhandled handshake brk (no broker attached)
  // longjmps us out to the interpreter fallback instead of crashing. When a
  // broker IS attached it intercepts EXC_BREAKPOINT before it becomes SIGTRAP,
  // so this handler never fires in the success path.
  struct sigaction old_action{};
  struct sigaction new_action{};
  new_action.sa_handler = TxmSigtrapHandler;
  sigemptyset(&new_action.sa_mask);
  new_action.sa_flags = 0;
  sigaction(SIGTRAP, &new_action, &old_action);

  g_txm_trapped = 0;
  if (sigsetjmp(g_txm_jmp, 1) == 0)
  {
    // dolphin_jit_lldb.py writes 0 here when it skips the brk under Xcode so the
    // post-brk check can detect Xcode mode (where TXM is never authorized).
    dolphin_txm_auth_status = 1;

    // DOL_JIT_TXM_UNIVERSAL=1 skips the legacy probe and issues brk #0xf00d
    // directly (for setups known to use universal.js, avoiding the benign
    // "legacy 0x69 rejected" log line that script prints).
    const char* force_universal = getenv("DOL_JIT_TXM_UNIVERSAL");
    if (force_universal && force_universal[0] == '1')
    {
      TxmUniversalPrepareAll(rx_ptr, size);
      TxmUniversalDetach();
      os_log(OS_LOG_DEFAULT, "[LuckTXM] prepared %zu MiB via universal (forced)", size >> 20);
    }
    else
    {
      // Probe with ONE granule, not the whole region.
      //
      // This used to ask for `size` in a single legacy brk and, if the broker did not reject it,
      // assume the entire region was blessed. It is not: a broker may bless less than asked and
      // report nothing. StikDebug blesses 64 MiB here, so execution died with EXC_BAD_ACCESS /
      // SIGBUS the moment the JIT emitted past that -- twice, at byte 67,125,248 of the region
      // both times, which is 64 MiB plus exactly one page. An identical fault offset across two
      // runs is what gives it away; a memory-pressure kill would not land on the same byte.
      //
      // So probe with the first granule to find out which protocol the broker speaks, then keep
      // asking, a granule at a time, until the whole region is covered.
      const size_t probe = std::min(size, TXM_PREPARE_GRANULE);
      const u64 legacy_result = TxmLegacyPrepare(rx_ptr, probe);
      if (static_cast<u32>(legacy_result) == TXM_LEGACY_REJECTED)
      {
        // universal.js rejected the legacy sentinel without preparing anything; migrate to the
        // universal command it understands, for the WHOLE region including the probed granule.
        TxmUniversalPrepareAll(rx_ptr, size);
        TxmUniversalDetach();
        os_log(OS_LOG_DEFAULT, "[LuckTXM] prepared %zu MiB via universal after legacy reject",
               size >> 20);
      }
      else
      {
        // Legacy broker answered. Continue with it for the remainder.
        size_t done = probe;
        while (done < size)
        {
          const size_t chunk = std::min(size - done, TXM_PREPARE_GRANULE);
          TxmLegacyPrepare(static_cast<u8*>(rx_ptr) + done, chunk);
          done += chunk;
        }
        os_log(OS_LOG_DEFAULT, "[LuckTXM] prepared %zu MiB via legacy in %zu granules", size >> 20,
               (size + TXM_PREPARE_GRANULE - 1) / TXM_PREPARE_GRANULE);
      }
    }
  }

  sigaction(SIGTRAP, &old_action, nullptr);

  // Under Xcode, dolphin_jit_lldb.py sets dolphin_txm_auth_status = 0 when it
  // skips the brk.  Without a broker the brk raises SIGTRAP and g_txm_trapped
  // is set.  In either case TXM has NOT been authorized: vm_remap would succeed
  // (CS_DEBUGGED) but execution from the rx region would be blocked by TXM with
  // KERN_CODESIGN_ERROR.  Bail out early so IsTXMAvailable() returns false and
  // EmulationCoordinator falls back to interpreter.
  if (g_txm_trapped || !dolphin_txm_auth_status)
  {
    munmap(rx_ptr, size);
    return;
  }

  vm_address_t rw_region = 0;
  vm_address_t target = reinterpret_cast<vm_address_t>(rx_ptr);
  vm_prot_t cur_protection = 0;
  vm_prot_t max_protection = 0;

  kern_return_t retval =
      vm_remap(mach_task_self(), &rw_region, size, 0, true, mach_task_self(), target, false,
               &cur_protection, &max_protection, VM_INHERIT_DEFAULT);
  if (retval != KERN_SUCCESS)
  {
    PanicAlertFmt("AllocateExecutableMemoryRegion failed! vm_map returned {0:#x}", retval);
    return;
  }

  u8* rw_ptr = reinterpret_cast<u8*>(rw_region);

  if (mprotect(rw_ptr, size, PROT_READ | PROT_WRITE) != 0)
  {
    PanicAlertFmt("AllocateExecutableMemoryRegion failed! mprotect returned {}", LastStrerrorString());
    return;
  }

  lwmem_region_t regions[] =
  {
    { (void*)rw_ptr, size },
    { NULL, 0 }
  };

  size_t lwret = lwmem_assignmem(regions);
  if (lwret == 0)
  {
    PanicAlertFmt("AllocateExecutableMemoryRegion failed!\nlwmem_assignmem failed");
    return;
  }

  g_rx_region = rx_ptr;
  g_rw_region_diff = rw_ptr - rx_ptr;
}

ptrdiff_t AllocateWritableRegionAndGetDiff_LuckTXM()
{
  return g_rw_region_diff;
}

void* AllocateExecutableMemory_LuckTXM(size_t size)
{
  if (g_rx_region == nullptr)
  {
    PanicAlertFmt("AllocateExecutableMemory failed!\ng_rx_region is nullptr");
    return nullptr;
  }

  const size_t pagesize = sysconf(_SC_PAGESIZE);

  void* raw = lwmem_malloc(size + pagesize - 1 + sizeof(void*));

  if (!raw)
  {
    PanicAlertFmt("AllocateExecutableMemory failed!\nlwmem_malloc returned nullptr");
    return nullptr;
  }

  uintptr_t raw_addr = (uintptr_t)raw + sizeof(void*);
  uintptr_t aligned = (raw_addr + pagesize - 1) & ~(pagesize - 1);

  ((void**)aligned)[-1] = raw;

  return (u8*)aligned - g_rw_region_diff;
}

void FreeExecutableMemory_LuckTXM(void* ptr)
{
  lwmem_free(((void**)ptr)[-1]);
}

bool IsTXMJITAvailable_LuckTXM()
{
  return g_rx_region != nullptr;
}

uintptr_t GetTXMRegionMappedAddress_LuckTXM()
{
  return g_rx_region_mapped_at;
}
}  // namespace Common