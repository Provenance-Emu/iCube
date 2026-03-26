// Copyright 2025 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Common/MemoryUtil.h"

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

namespace Common
{
void* AllocateExecutableMemory_LuckNoTXM(size_t size)
{
  u8* rx_ptr = static_cast<u8*>(mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0));

  if (!rx_ptr)
  {
    PanicAlertFmt("AllocateExecutableMemory_LuckNoTXM failed! mmap returned {}", LastStrerrorString());
    return nullptr;
  }

  return rx_ptr;
}

void FreeExecutableMemory_LuckNoTXM(void* ptr, size_t size)
{
  if (ptr)
  {
    if (munmap(ptr, size) != 0)
    {
      PanicAlertFmt("FreeExecutableMemory_LuckNoTXM failed!\nmunmap: {}", LastStrerrorString());
    }
  }
}

ptrdiff_t AllocateWritableRegionAndGetDiff_LuckNoTXM(void* rx_ptr, size_t size)
{
  vm_address_t rw_region = 0;
  vm_address_t target = reinterpret_cast<vm_address_t>(rx_ptr);
  vm_prot_t cur_protection = 0;
  vm_prot_t max_protection = 0;

  kern_return_t retval =
      vm_remap(mach_task_self(), &rw_region, size, 0, true, mach_task_self(), target, false,
               &cur_protection, &max_protection, VM_INHERIT_DEFAULT);
  if (retval != KERN_SUCCESS)
  {
    PanicAlertFmt("AllocateWritableRegionAndGetDiff_LuckNoTXM failed!\nvm_map returned {0:#x}", retval);
    return 0;
  }

  u8* rw_ptr = reinterpret_cast<u8*>(rw_region);

  if (mprotect(rw_ptr, size, PROT_READ | PROT_WRITE) != 0)
  {
    PanicAlertFmt("AllocateWritableRegionAndGetDiff_LuckNoTXM failed!\nmprotect returned {}", LastStrerrorString());
    return 0;
  }

  return rw_ptr - static_cast<u8*>(rx_ptr);
}

void FreeWritableRegion_LuckNoTXM(void* rx_ptr, size_t size, ptrdiff_t diff)
{
  u8* rw_ptr = static_cast<u8*>(rx_ptr) + diff;
  vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(rw_ptr), size);
}
}  // namespace Common
