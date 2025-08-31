// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <cstddef>
#include <map>
#include <mutex>
#include <unordered_map>

namespace Common
{
class JITMemoryTracker final
{
public:
  JITMemoryTracker();

  void RegisterJITRegion(void* ptr, size_t size);
  void UnregisterJITRegion(void* ptr);

  void JITRegionWriteEnableExecuteDisable(void* ptr);
  void JITRegionWriteDisableExecuteEnable(void* ptr);
  // Indicates a high-level JIT write scope is active on this thread; suppress nested toggles.
  static void EnterThreadWriteScope();
  static void ExitThreadWriteScope();
  static bool IsThreadWriteScopeActive();

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
};
}
