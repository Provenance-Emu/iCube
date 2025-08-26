// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Common/MemoryUtil.h"

#include <cstddef>
#include <cstdlib>
#include <string>

#include "Common/CommonFuncs.h"
#include "Common/CommonTypes.h"
#include "Common/Logging/Log.h"
#include "Common/MsgHandler.h"

#ifdef _WIN32
#include <windows.h>
#include "Common/StringUtil.h"
#else
#include <pthread.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <errno.h>
#if defined __APPLE__ || defined __FreeBSD__ || defined __OpenBSD__ || defined __NetBSD__
#include <sys/sysctl.h>
#elif defined __HAIKU__
#include <OS.h>
#else
#include <sys/sysinfo.h>
#endif
#endif

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

#ifdef IPHONEOS
#include "Common/JITMemoryTracker.h"
#endif

#if defined(__APPLE__) && defined(_M_ARM_64)
#include <dlfcn.h>
using ToggleFn = void (*)(int);
static inline ToggleFn AppleGetJitToggle()
{
  static ToggleFn fn_cached = (ToggleFn)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
  return fn_cached;
}
static inline bool AppleHasJitToggle()
{
  return AppleGetJitToggle() != nullptr;
}
static inline void AppleToggleJitWriteProtect(bool enable)
{
  if (ToggleFn fn = AppleGetJitToggle())
    fn(enable ? 1 : 0);
}
static inline bool ForceRWXMode()
{
  const char* env = std::getenv("DOL_JIT_FORCE_RWX");
  return env && *env && (*env != '0');
}
#else
static inline void AppleToggleJitWriteProtect(bool) {}
#endif

namespace Common
{
// This is purposely not a full wrapper for virtualalloc/mmap, but it
// provides exactly the primitive operations that Dolphin needs.

#ifdef IPHONEOS
static JITMemoryTracker g_jit_memory_tracker;
#endif

void* AllocateExecutableMemory(size_t size)
{
#if defined(_WIN32)
  void* ptr = VirtualAlloc(nullptr, size, MEM_COMMIT, PAGE_EXECUTE_READWRITE);
#else
  int map_flags = MAP_ANON | MAP_PRIVATE;
#if defined(__APPLE__)
  map_flags |= MAP_JIT;
#endif

#if defined(__APPLE__)
  // On Apple platforms with MAP_JIT, allocate RW and toggle execution with pthread_jit_write_protect_np.
  int map_prot = PROT_READ | PROT_WRITE;
#else
  // Other POSIX: allow RX by default and add W for JIT writes via mprotect.
  int map_prot = PROT_READ | PROT_EXEC | PROT_WRITE;
#endif

  void* ptr = nullptr;
#if defined(__APPLE__) && defined(_M_ARM_64)
  // Prefer RWX if pthread_jit_write_protect_np cannot be resolved at runtime,
  // since MAP_JIT mappings require per-thread toggling to execute.
  const bool have_toggle = AppleHasJitToggle();
#if defined(TARGET_OS_TV) && TARGET_OS_TV
  // tvOS: default to RWX due to MAP_JIT instability; env can still override for testing
  const bool force_rwx = true;
#else
  const bool force_rwx = ForceRWXMode() || !have_toggle;
#endif
  if (!force_rwx)
  {
    // Enter write mode before creating a MAP_JIT mapping to satisfy tightened tvOS/iOS rules.
    AppleToggleJitWriteProtect(false);
    ptr = mmap(nullptr, size, map_prot, map_flags, -1, 0);
    if (ptr == MAP_FAILED)
    {
      int saved_errno = errno;
      fprintf(stderr, "[JIT] MAP_JIT mmap failed: errno=%d\n", saved_errno);
      ptr = nullptr;
      // Retry strategies for tightened tvOS/iOS JIT rules
      if (saved_errno == EPERM || saved_errno == EINVAL)
      {
        // 1) Try RWX without MAP_JIT (dev/debug only). This may still fail on some OS versions.
        int rwx_prot = PROT_READ | PROT_WRITE | PROT_EXEC;
        int no_jit_flags = (MAP_ANON | MAP_PRIVATE);
        void* retry_rwx = mmap(nullptr, size, rwx_prot, no_jit_flags, -1, 0);
        if (retry_rwx != MAP_FAILED)
        {
          fprintf(stderr, "[JIT] Fallback RWX mmap succeeded\n");
          ptr = retry_rwx;
        }
        else
        {
          fprintf(stderr, "[JIT] Fallback RWX mmap failed errno=%d\n", errno);
          // 2) Try RW and elevate to RWX via mprotect (dev/debug only)
          void* retry_rw = mmap(nullptr, size, PROT_READ | PROT_WRITE, no_jit_flags, -1, 0);
          if (retry_rw != MAP_FAILED)
          {
            if (mprotect(retry_rw, size, rwx_prot) == 0)
            {
              fprintf(stderr, "[JIT] RW mmap + mprotect(RWX) succeeded\n");
              ptr = retry_rw;
            }
            else
            {
              fprintf(stderr, "[JIT] mprotect(RWX) failed errno=%d\n", errno);
              munmap(retry_rw, size);
            }
          }
        }
      }
    }
    // Restore execute protection state after mapping.
    AppleToggleJitWriteProtect(true);
  }
  else
  {
    // Forced or required RWX path first (no per-thread toggle available)
    int rwx_prot = PROT_READ | PROT_WRITE | PROT_EXEC;
    int no_jit_flags = (MAP_ANON | MAP_PRIVATE);
    ptr = mmap(nullptr, size, rwx_prot, no_jit_flags, -1, 0);
    if (ptr == MAP_FAILED)
    {
      fprintf(stderr, "[JIT] RWX mmap failed errno=%d, trying RW+mprotect\n", errno);
      void* retry_rw = mmap(nullptr, size, PROT_READ | PROT_WRITE, no_jit_flags, -1, 0);
      if (retry_rw != MAP_FAILED)
      {
        if (mprotect(retry_rw, size, rwx_prot) == 0)
        {
          fprintf(stderr, "[JIT] RW + mprotect(RWX) succeeded\n");
          ptr = retry_rw;
        }
        else
        {
          fprintf(stderr, "[JIT] mprotect(RWX) failed errno=%d\n", errno);
          munmap(retry_rw, size);
        }
      }
    }
  }
#else
  ptr = mmap(nullptr, size, map_prot, map_flags, -1, 0);
  if (ptr == MAP_FAILED)
    ptr = nullptr;
#endif
// Close #if defined(_WIN32)
#endif

  if (ptr == nullptr)
    PanicAlertFmt("Failed to allocate executable memory: {}", LastStrerrorString());

#ifdef IPHONEOS
  g_jit_memory_tracker.RegisterJITRegion(ptr, size);
#endif

  return ptr;
}
#ifndef IPHONEOS
// This function is used to provide a counter for the JITPageWrite*Execute*
// functions to enable nesting. The static variable is wrapped in a a function
// to allow those functions to be called inside of the constructor of a static
// variable portably.
//
// The variable is thread_local as the W^X mode is specific to each running thread.
static int& JITPageWriteNestCounter()
{
  static thread_local int nest_counter = 0;
  return nest_counter;
}

// Certain platforms (Mac OS on ARM) enforce that a single thread can only have write or
// execute permissions to pages at any given point of time. The two below functions
// are used to toggle between having write permissions or execute permissions.
//
// The default state of these allocations in Dolphin is for them to be executable,
// but not writeable. So, functions that are updating these pages should wrap their
// writes like below:

// JITPageWriteEnableExecuteDisable();
// PrepareInstructionStreamForJIT();
// JITPageWriteDisableExecuteEnable();

// These functions can be nested, in which case execution will only be enabled
// after the call to the JITPageWriteDisableExecuteEnable from the top most
// nesting level. Example:

// [JIT page is in execute mode for the thread]
// JITPageWriteEnableExecuteDisable();
//   [JIT page is in write mode for the thread]
//   JITPageWriteEnableExecuteDisable();
//     [JIT page is in write mode for the thread]
//   JITPageWriteDisableExecuteEnable();
//   [JIT page is in write mode for the thread]
// JITPageWriteDisableExecuteEnable();
// [JIT page is in execute mode for the thread]

// Allows a thread to write to executable memory, but not execute the data.
void JITPageWriteEnableExecuteDisable()
{
#if defined(_M_ARM_64) && defined(__APPLE__)
  if (JITPageWriteNestCounter() == 0)
  {
    AppleToggleJitWriteProtect(false);
  }
#endif
  JITPageWriteNestCounter()++;
}
// Allows a thread to execute memory allocated for execution, but not write to it.
void JITPageWriteDisableExecuteEnable()
{
  JITPageWriteNestCounter()--;

  // Sanity check the NestCounter to identify underflow
  // This can indicate the calls to JITPageWriteDisableExecuteEnable()
  // are not matched with previous calls to JITPageWriteEnableExecuteDisable()
  if (JITPageWriteNestCounter() < 0)
    PanicAlertFmt("JITPageWriteNestCounter() underflowed");

#if defined(_M_ARM_64) && defined(__APPLE__)
  if (JITPageWriteNestCounter() == 0)
  {
    AppleToggleJitWriteProtect(true);
  }
#endif
}
#else
void JITPageWriteEnableExecuteDisable(void* ptr)
{
  g_jit_memory_tracker.JITRegionWriteEnableExecuteDisable(ptr);
}

void JITPageWriteDisableExecuteEnable(void* ptr)
{
  g_jit_memory_tracker.JITRegionWriteDisableExecuteEnable(ptr);
}
#endif

void* AllocateMemoryPages(size_t size)
{
#ifdef _WIN32
  void* ptr = VirtualAlloc(nullptr, size, MEM_COMMIT, PAGE_READWRITE);
#else
  void* ptr = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);

  if (ptr == MAP_FAILED)
    ptr = nullptr;
#endif

  if (ptr == nullptr)
    PanicAlertFmt("Failed to allocate raw memory");

  return ptr;
}

void* AllocateAlignedMemory(size_t size, size_t alignment)
{
#ifdef _WIN32
  void* ptr = _aligned_malloc(size, alignment);
#else
  void* ptr = nullptr;
  if (posix_memalign(&ptr, alignment, size) != 0)
    ERROR_LOG_FMT(MEMMAP, "Failed to allocate aligned memory");
#endif

  if (ptr == nullptr)
    PanicAlertFmt("Failed to allocate aligned memory");

  return ptr;
}

bool FreeMemoryPages(void* ptr, size_t size)
{
  if (ptr)
  {
#ifdef _WIN32
    if (!VirtualFree(ptr, 0, MEM_RELEASE))
    {
      PanicAlertFmt("FreeMemoryPages failed!\nVirtualFree: {}", GetLastErrorString());
      return false;
    }
#else
    if (munmap(ptr, size) != 0)
    {
      PanicAlertFmt("FreeMemoryPages failed!\nmunmap: {}", LastStrerrorString());
      return false;
    }
#endif

#ifdef IPHONEOS
    g_jit_memory_tracker.UnregisterJITRegion(ptr);
#endif
  }
  return true;
}

void FreeAlignedMemory(void* ptr)
{
  if (ptr)
  {
#ifdef _WIN32
    _aligned_free(ptr);
#else
    free(ptr);
#endif
  }
}

bool ReadProtectMemory(void* ptr, size_t size)
{
#ifdef _WIN32
  DWORD oldValue;
  if (!VirtualProtect(ptr, size, PAGE_NOACCESS, &oldValue))
  {
    PanicAlertFmt("ReadProtectMemory failed!\nVirtualProtect: {}", GetLastErrorString());
    return false;
  }
#else
  if (mprotect(ptr, size, PROT_NONE) != 0)
  {
    PanicAlertFmt("ReadProtectMemory failed!\nmprotect: {}", LastStrerrorString());
    return false;
  }
#endif
  return true;
}

bool WriteProtectMemory(void* ptr, size_t size, bool allowExecute)
{
#ifdef _WIN32
  DWORD oldValue;
  if (!VirtualProtect(ptr, size, allowExecute ? PAGE_EXECUTE_READ : PAGE_READONLY, &oldValue))
  {
    PanicAlertFmt("WriteProtectMemory failed!\nVirtualProtect: {}", GetLastErrorString());
    return false;
  }
#elif defined(__APPLE__) && defined(_M_ARM_64)
  // When pthread_jit_write_protect_np is present, W^X is toggled per-thread.
  // Otherwise, fall back to mprotect to set RX.
  if (!AppleHasJitToggle())
  {
    if (mprotect(ptr, size, allowExecute ? (PROT_READ | PROT_EXEC) : PROT_READ) != 0)
    {
      PanicAlertFmt("WriteProtectMemory failed!\nmprotect: {}", LastStrerrorString());
      return false;
    }
  }
#else
  if (mprotect(ptr, size, allowExecute ? (PROT_READ | PROT_EXEC) : PROT_READ) != 0)
  {
    PanicAlertFmt("WriteProtectMemory failed!\nmprotect: {}", LastStrerrorString());
    return false;
  }
#endif
  return true;
}

bool UnWriteProtectMemory(void* ptr, size_t size, bool allowExecute)
{
#ifdef _WIN32
  DWORD oldValue;
  if (!VirtualProtect(ptr, size, allowExecute ? PAGE_EXECUTE_READWRITE : PAGE_READWRITE, &oldValue))
  {
    PanicAlertFmt("UnWriteProtectMemory failed!\nVirtualProtect: {}", GetLastErrorString());
    return false;
  }
#elif defined(__APPLE__) && defined(_M_ARM_64)
  // When pthread_jit_write_protect_np is present, W^X is toggled per-thread.
  // Otherwise, fall back to mprotect to set RW or RWX.
  if (!AppleHasJitToggle())
  {
    if (mprotect(ptr, size,
                 allowExecute ? (PROT_READ | PROT_WRITE | PROT_EXEC) : PROT_WRITE | PROT_READ) != 0)
    {
      PanicAlertFmt("UnWriteProtectMemory failed!\nmprotect: {}", LastStrerrorString());
      return false;
    }
  }
#else
  if (mprotect(ptr, size,
               allowExecute ? (PROT_READ | PROT_WRITE | PROT_EXEC) : PROT_WRITE | PROT_READ) != 0)
  {
    PanicAlertFmt("UnWriteProtectMemory failed!\nmprotect: {}", LastStrerrorString());
    return false;
  }
#endif
  return true;
}

size_t MemPhysical()
{
#ifdef _WIN32
  MEMORYSTATUSEX memInfo;
  memInfo.dwLength = sizeof(MEMORYSTATUSEX);
  GlobalMemoryStatusEx(&memInfo);
  return memInfo.ullTotalPhys;
#elif defined __APPLE__ || defined __FreeBSD__ || defined __OpenBSD__ || defined __NetBSD__
  int mib[2];
  size_t physical_memory;
  mib[0] = CTL_HW;
#ifdef __APPLE__
  mib[1] = HW_MEMSIZE;
#elif defined __FreeBSD__
  mib[1] = HW_REALMEM;
#elif defined __OpenBSD__ || defined __NetBSD__
  mib[1] = HW_PHYSMEM64;
#endif
  size_t length = sizeof(size_t);
  sysctl(mib, 2, &physical_memory, &length, nullptr, 0);
  return physical_memory;
#elif defined __HAIKU__
  system_info sysinfo;
  get_system_info(&sysinfo);
  return static_cast<size_t>(sysinfo.max_pages * B_PAGE_SIZE);
#else
  struct sysinfo memInfo;
  sysinfo(&memInfo);
  return (size_t)memInfo.totalram * memInfo.mem_unit;
#endif
}

}  // namespace Common
