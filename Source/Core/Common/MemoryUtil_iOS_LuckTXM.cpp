// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Common/MemoryUtil.h"

#include <csetjmp>
#include <csignal>
#include <cstdlib>

#include <lwmem/lwmem.h>
#include <mach/mach.h>
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

namespace Common
{
void AllocateExecutableMemoryRegion_LuckTXM()
{
  if (g_rx_region)
  {
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