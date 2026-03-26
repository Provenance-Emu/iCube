// Copyright 2008 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Common/MemoryUtil.h"

#include "Common/CommonTypes.h"
#include "Common/MsgHandler.h"

namespace Common
{
static JitType g_jit_type = JitType::LuckTXM;

void SetJitType(JitType type)
{
  g_jit_type = type;
}

void* AllocateExecutableMemory(size_t size)
{
  if (g_jit_type == JitType::LuckTXM)
  {
    return AllocateExecutableMemory_LuckTXM(size);
  }

  if (g_jit_type == JitType::Legacy)
  {
    return AllocateExecutableMemory_Legacy(size);
  }

  if (g_jit_type == JitType::LuckNoTXM)
  {
    return AllocateExecutableMemory_LuckNoTXM(size);
  }

  PanicAlertFmt("AllocateExecutableMemory failed!\nUnknown JIT type set");
  return nullptr;
}

void FreeExecutableMemory(void* ptr, size_t size)
{
  if (g_jit_type == JitType::LuckTXM)
  {
    FreeExecutableMemory_LuckTXM(ptr);
  }
  else if (g_jit_type == JitType::LuckNoTXM)
  {
    FreeExecutableMemory_LuckNoTXM(ptr, size);
  }
  else if (g_jit_type == JitType::Legacy)
  {
    FreeExecutableMemory_Legacy(ptr, size);
  }
}

void AllocateExecutableMemoryRegion()
{
  if (g_jit_type == JitType::LuckTXM)
  {
    AllocateExecutableMemoryRegion_LuckTXM();
  }
}

ptrdiff_t AllocateWritableRegionAndGetDiff(void* rx_ptr, size_t size)
{
  if (g_jit_type == JitType::LuckTXM)
  {
    return AllocateWritableRegionAndGetDiff_LuckTXM();
  }

  if (g_jit_type == JitType::LuckNoTXM)
  {
    return AllocateWritableRegionAndGetDiff_LuckNoTXM(rx_ptr, size);
  }

  return 0;
}

void FreeWritableRegion(void* rx_ptr, size_t size, ptrdiff_t diff)
{
  if (g_jit_type == JitType::LuckNoTXM)
  {
    return FreeWritableRegion_LuckNoTXM(rx_ptr, size, diff);
  }
}

void JITPageWriteEnableExecuteDisable(void* ptr)
{
  if (g_jit_type == JitType::Legacy)
  {
    JITPageWriteEnableExecuteDisable_Legacy(ptr);
  }
}

void JITPageWriteDisableExecuteEnable(void* ptr)
{
  if (g_jit_type == JitType::Legacy)
  {
    JITPageWriteDisableExecuteEnable_Legacy(ptr);
  }
}
}  // namespace Common
