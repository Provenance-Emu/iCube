// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <cstddef>
#include <map>
#include <mutex>

namespace Common
{
class JITMemoryTracker
{
public:
  JITMemoryTracker();

  void RegisterJITRegion(void* ptr, size_t size);
  void UnregisterJITRegion(void* ptr);

  void JITRegionWriteEnableExecuteDisable(void* ptr);
  void JITRegionWriteDisableExecuteEnable(void* ptr);

  // Allows higher level (ObjC) to disable per-thread JIT toggling on platforms
  // where pthread_jit_write_protect_np exists but is not permitted (iPad-on-Mac).
  static void SetThreadToggleAllowed(bool allowed) { s_thread_toggle_allowed = allowed; }
  static bool GetThreadToggleAllowed() { return s_thread_toggle_allowed; }

private:
  struct JITRegionInfo
  {
    void* start_ptr;
    size_t size;
    int nest_counter;
  };

  JITRegionInfo* FindRegion(void* ptr);

  std::map<void*, JITRegionInfo> m_jit_regions;
  std::mutex m_mutex;

  inline static bool s_thread_toggle_allowed = true;
};
}  // namespace Common
