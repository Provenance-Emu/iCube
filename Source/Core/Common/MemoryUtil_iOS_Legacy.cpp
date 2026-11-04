// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Common/MemoryUtil.h"

#include <atomic>
#include <cstring>
#include <stdio.h>
#include <string>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>

#include "Common/CommonFuncs.h"
#include "Common/CommonTypes.h"
#include "Common/JITMemoryTracker.h"
#include "Common/Logging/Log.h"
#include "Common/MsgHandler.h"

namespace Common
{
// The Legacy region is a plain RX anonymous mapping (no MAP_JIT, no writable alias). The tracker
// makes it RW with mprotect while a ScopedJITPageWriteAndNoExecute is held; this needs the
// process to be CS_DEBUGGED, which is what selects Legacy in the first place.
static JITMemoryTracker g_jit_memory_tracker;
static std::atomic<LegacyJITFaultReporter> g_fault_reporter{nullptr};
// One alert per process: after a failed toggle every block compile would raise another.
static std::atomic<bool> g_toggle_failure_alerted{false};

// Ring events included in the fault reporter's text (Sentry breadcrumbs are size-limited).
static constexpr std::size_t FAULT_REPORT_EVENTS = 16;

void* AllocateExecutableMemory_Legacy(size_t size)
{
  void* ptr = mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
  if (ptr == MAP_FAILED)
  {
    ptr = nullptr;
  }

  if (ptr == nullptr)
  {
    PanicAlertFmt("Failed to allocate executable memory: {}", LastStrerrorString());
    return nullptr;
  }

  if (!g_jit_memory_tracker.RegisterJITRegion(ptr, size))
  {
    PanicAlertFmt("JITMemoryTracker: region {} already registered\n{}", ptr,
                  g_jit_memory_tracker.FormatState(ptr, FAULT_REPORT_EVENTS));
  }

  return ptr;
}

void FreeExecutableMemory_Legacy(void* ptr, size_t size)
{
  if (ptr)
  {
    // Unregister first: once munmap returns, another thread can be handed the same address, and
    // a late unregister would then erase that new region's entry.
    g_jit_memory_tracker.UnregisterJITRegion(ptr);

    if (munmap(ptr, size) != 0)
    {
      PanicAlertFmt("FreeExecutableMemory failed!\nmunmap: {}", LastStrerrorString());
    }
  }
}

static void ReportToggleResult(const JITMemoryTracker::Result& result, void* ptr, bool writable)
{
  if (!result.tracked)
  {
    // Every Legacy JIT write site passes a pointer into a registered region; a miss means the
    // write that follows hits an RX page. Logged, not alerted: the fault path dumps the ring.
    ERROR_LOG_FMT(COMMON, "Legacy JIT: {} toggle for untracked pointer {}",
                  writable ? "RW" : "RX", ptr);
    return;
  }

  if (result.underflow)
  {
    ERROR_LOG_FMT(COMMON, "Legacy JIT: nest counter underflow for region {}",
                  result.region_start);
    return;
  }

  if (result.error == 0)
    return;

  const std::string state = g_jit_memory_tracker.FormatState(ptr, FAULT_REPORT_EVENTS);
  ERROR_LOG_FMT(COMMON, "Legacy JIT: mprotect({}) failed for region {}+{:#x}: {} ({})\n{}",
                writable ? "RW" : "RX", result.region_start, result.region_size,
                std::strerror(result.error), result.error, state);

  if (!g_toggle_failure_alerted.exchange(true))
  {
    PanicAlertFmt("Legacy JIT: mprotect({}) failed for region {}+{:#x}: {} ({})\n{}",
                  writable ? "RW" : "RX", result.region_start, result.region_size,
                  std::strerror(result.error), result.error, state);
  }
}

void JITPageWriteEnableExecuteDisable_Legacy(void* ptr)
{
  // The tracker's lock is released before anything is reported.
  const auto result = g_jit_memory_tracker.JITRegionWriteEnableExecuteDisable(ptr);
  if (!result.tracked || result.error != 0)
    ReportToggleResult(result, ptr, true);
}

void JITPageWriteDisableExecuteEnable_Legacy(void* ptr)
{
  const auto result = g_jit_memory_tracker.JITRegionWriteDisableExecuteEnable(ptr);
  if (!result.tracked || result.underflow || result.error != 0)
    ReportToggleResult(result, ptr, false);
}

void SetLegacyJITFaultReporter(LegacyJITFaultReporter reporter)
{
  g_fault_reporter.store(reporter);
}

void ReportJITFault_Legacy(uintptr_t fault_address)
{
  // Runs on the Mach exception thread with the faulting thread suspended: never block here.
  const void* ptr = reinterpret_cast<const void*>(fault_address);
  bool in_region = false;
  const std::string state = g_jit_memory_tracker.FormatState(ptr, FAULT_REPORT_EVENTS, &in_region);
  if (!in_region)
    return;

  ERROR_LOG_FMT(COMMON, "Legacy JIT: unhandled fault at {:#x}\n{}", fault_address, state);

  if (const LegacyJITFaultReporter reporter = g_fault_reporter.load())
    reporter(state.c_str());
}
}  // namespace Common
