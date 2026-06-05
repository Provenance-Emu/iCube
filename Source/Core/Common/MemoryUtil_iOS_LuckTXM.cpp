// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Common/MemoryUtil.h"

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

// 512 MiB... hopefully this is enough, because we can't allocate more if we need it
constexpr size_t EXECUTABLE_REGION_SIZE = 536870912;

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

static void TxmUniversalDetach()
{
  register u64 x16 asm("x16") = 0;  // CMD_DETACH
  asm volatile("brk #0xf00d" : "+r"(x16) : : "memory");
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
  u8* rx_ptr = static_cast<u8*>(mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0));

  if (!rx_ptr)
  {
    PanicAlertFmt("AllocateExecutableMemoryRegion failed! mmap returned {}", LastStrerrorString());
    return;
  }

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
      TxmUniversalPrepare(rx_ptr, size);
      TxmUniversalDetach();
    }
    else
    {
      const u64 legacy_result = TxmLegacyPrepare(rx_ptr, size);
      if (static_cast<u32>(legacy_result) == TXM_LEGACY_REJECTED)
      {
        // universal.js rejected the legacy sentinel without preparing the
        // region; migrate to the universal command it understands.
        TxmUniversalPrepare(rx_ptr, size);
        TxmUniversalDetach();
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
}  // namespace Common