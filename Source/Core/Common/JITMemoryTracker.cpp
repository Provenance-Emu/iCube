// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Common/JITMemoryTracker.h"

#include "Common/CommonTypes.h"
#include "Common/MemoryUtil.h"
#include "Common/MsgHandler.h"
#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <pthread.h>
#endif

#if defined(__APPLE__) && defined(_M_ARM_64)
#include <dlfcn.h>
static inline void AppleToggleJitWriteProtect(bool enable)
{
  using ToggleFn = void (*)(int);
  static ToggleFn fn = (ToggleFn)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
  if (fn)
    fn(enable ? 1 : 0);
}
static inline bool AppleHasJitToggle()
{
  using ToggleFn = void (*)(int);
  static ToggleFn fn = (ToggleFn)dlsym(RTLD_DEFAULT, "pthread_jit_write_protect_np");
  return fn != nullptr;
}
#else
static inline void AppleToggleJitWriteProtect(bool) {}
static inline bool AppleHasJitToggle() { return false; }
#endif

namespace Common
{
JITMemoryTracker::JITMemoryTracker() = default;

static thread_local int s_thread_write_scope_nest = 0;

void JITMemoryTracker::EnterThreadWriteScope()
{
  s_thread_write_scope_nest++;
}

void JITMemoryTracker::ExitThreadWriteScope()
{
  s_thread_write_scope_nest--;
  if (s_thread_write_scope_nest < 0)
    s_thread_write_scope_nest = 0;
}

bool JITMemoryTracker::IsThreadWriteScopeActive()
{
  return s_thread_write_scope_nest > 0;
}

void JITMemoryTracker::RegisterJITRegion(void* ptr, size_t size)
{
  std::scoped_lock lk(m_mutex);

  if (m_jit_regions.find(ptr) != m_jit_regions.end())
  {
    PanicAlertFmt("JITMemoryTracker: region {} already registered", ptr);
    return;
  }

  m_jit_regions[ptr] = {ptr, size, 0};
}

void JITMemoryTracker::UnregisterJITRegion(void* ptr)
{
  std::scoped_lock lk(m_mutex);

  m_jit_regions.erase(ptr);
}

JITMemoryTracker::JITRegionInfo* JITMemoryTracker::FindRegion(void* ptr)
{
  if (m_jit_regions.find(ptr) != m_jit_regions.end())
  {
    return &m_jit_regions[ptr];
  }

  for (auto& info : m_jit_regions)
  {
    void* region_end = static_cast<void*>(static_cast<u8*>(info.first) + info.second.size);
    if (ptr >= info.first && ptr <= region_end)
    {
      return &info.second;
    }
  }

  return nullptr;
}

void JITMemoryTracker::JITRegionWriteEnableExecuteDisable(void* ptr)
{
  std::scoped_lock lk(m_mutex);

  JITRegionInfo* info = FindRegion(ptr);

  if (!info)
  {
    return;
  }

  if (IsThreadWriteScopeActive())
  {
    // Suppress toggles within a higher-level thread scope; rely on outer scope.
    info->nest_counter++;
    return;
  }

  if (info->nest_counter == 0)
  {
#if defined(__APPLE__) && defined(_M_ARM_64)
    if (AppleHasJitToggle())
    {
      // On Apple ARM64 platforms with per-thread toggle, switch to write mode.
      AppleToggleJitWriteProtect(false);
    }
    else
    {
      // Fallback: allow RWX on the whole region during write phase.
      UnWriteProtectMemory(info->start_ptr, info->size, true);
    }
#else
    // Non-Apple platforms fall back to page protection changes.
    UnWriteProtectMemory(info->start_ptr, info->size, true);
#endif
  }

  info->nest_counter++;
}

void JITMemoryTracker::JITRegionWriteDisableExecuteEnable(void* ptr)
{
  std::scoped_lock lk(m_mutex);

  JITRegionInfo* info = FindRegion(ptr);

  if (!info)
  {
    return;
  }

  info->nest_counter--;

  if (info->nest_counter < 0)
  {
    PanicAlertFmt("JITMemoryTracker: Nest counter underflow for region {}", ptr);
  }
  else if (info->nest_counter == 0 && !IsThreadWriteScopeActive())
  {
#if defined(__APPLE__) && defined(_M_ARM_64)
    if (AppleHasJitToggle())
    {
      // Restore execute mode for this thread.
      AppleToggleJitWriteProtect(true);
    }
    else
    {
      WriteProtectMemory(info->start_ptr, info->size, true);
    }
#else
    WriteProtectMemory(info->start_ptr, info->size, true);
#endif
  }
}
}  // namespace Common
