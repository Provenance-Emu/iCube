// Copyright 2025 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Common/MemArena.h"

#include <mach/mach.h>
#include <unistd.h>

#include "Common/Assert.h"
#include "Common/Logging/Log.h"

namespace Common
{
MemArena::MemArena() = default;
MemArena::~MemArena() = default;

void MemArena::GrabSHMSegment(size_t size, std::string_view base_name)
{
  kern_return_t retval = vm_allocate(mach_task_self(), &m_shm_address, size, VM_FLAGS_ANYWHERE);
  if (retval != KERN_SUCCESS)
  {
    ERROR_LOG_FMT(MEMMAP, "GrabSHMSegment failed: vm_allocate returned {0:#x}", retval);

    m_shm_address = 0;

    return;
  }

  // Large anonymous mappings are split into 128 MB chunks. Without MAP_MEM_VM_SHARE,
  // mach_make_memory_entry_64 will only return an entry spanning the first chunk.
  // Attempting to map through that entry will fail if it extends beyond the 128 MB
  // boundary, which can happen when the sizes of MEM1/MEM2 are overridden.
  //
  // iCube: on some iOS devices (seen on an A12 iPad mini 5, iPadOS 26) the entry that comes back
  // with MAP_MEM_VM_SHARE covers only the first 2 MB chunk, and vm_map through it does NOT fail:
  // every view silently wraps modulo that chunk, so MEM2 and the fastmem views alias the start of
  // MEM1. A game's first DCBZ loop over MEM2 then wipes its own code ("IntCPU: Unknown instruction
  // 00000000"). Never trust the entry: prove that a view of the far end of the segment really
  // mirrors the base mapping, and fall back to an entry without the flag if it does not.
  constexpr vm_prot_t prot_shared = VM_PROT_READ | VM_PROT_WRITE | MAP_MEM_VM_SHARE;
  constexpr vm_prot_t prot_plain = VM_PROT_READ | VM_PROT_WRITE;
  for (const vm_prot_t prot : {prot_shared, prot_plain})
  {
    memory_object_size_t entry_size = size;
    mach_port_t entry = MACH_PORT_NULL;
    retval = mach_make_memory_entry_64(mach_task_self(), &entry_size, m_shm_address, prot, &entry,
                                       MACH_PORT_NULL);
    if (retval != KERN_SUCCESS)
    {
      ERROR_LOG_FMT(MEMMAP,
                    "GrabSHMSegment: mach_make_memory_entry_64 (prot {0:#x}) returned {1:#x}", prot,
                    retval);
      continue;
    }
    if (entry_size < size)
    {
      ERROR_LOG_FMT(MEMMAP,
                    "GrabSHMSegment: memory entry (prot {0:#x}) spans only {1:#x} of {2:#x} bytes",
                    prot, static_cast<u64>(entry_size), static_cast<u64>(size));
      mach_port_deallocate(mach_task_self(), entry);
      continue;
    }
    if (!EntryMirrorsSegment(entry, m_shm_address, size))
    {
      ERROR_LOG_FMT(MEMMAP,
                    "GrabSHMSegment: a view through the memory entry (prot {0:#x}) does not mirror "
                    "the segment; views would alias each other",
                    prot);
      mach_port_deallocate(mach_task_self(), entry);
      continue;
    }
    m_shm_entry = entry;
    m_shm_size = size;
    if (prot != prot_shared)
      WARN_LOG_FMT(MEMMAP, "GrabSHMSegment: using a memory entry without MAP_MEM_VM_SHARE");
    return;
  }
  ERROR_LOG_FMT(MEMMAP, "GrabSHMSegment failed: no usable memory entry for {0:#x} bytes",
                static_cast<u64>(size));
  vm_deallocate(mach_task_self(), m_shm_address, size);
  m_shm_address = 0;
  m_shm_entry = MACH_PORT_NULL;
}

// iCube: map the whole segment through `entry` once and check that writes made through the base
// mapping at the start, the middle and the last page are visible at the same offsets in the view, and
// that a write through the view's last page reaches the base. A short or chunk-wrapped entry fails
// the far-end checks. The probe words are restored afterwards; the segment is fresh at this point.
bool MemArena::EntryMirrorsSegment(mach_port_t entry, vm_address_t base, size_t size)
{
  vm_address_t view = 0;
  constexpr vm_prot_t prot = VM_PROT_READ | VM_PROT_WRITE;
  const kern_return_t retval = vm_map(mach_task_self(), &view, size, 0, VM_FLAGS_ANYWHERE, entry, 0,
                                      false, prot, prot, VM_INHERIT_DEFAULT);
  if (retval != KERN_SUCCESS)
  {
    ERROR_LOG_FMT(MEMMAP, "EntryMirrorsSegment: vm_map returned {0:#x}", retval);
    return false;
  }
  const size_t page = static_cast<size_t>(getpagesize());
  const size_t offsets[] = {0, (size / 2) & ~(page - 1), size - page};
  bool ok = true;
  u32 marker = 0x1C0BE000;
  for (const size_t offset : offsets)
  {
    volatile u32* through_base = reinterpret_cast<volatile u32*>(base + offset);
    volatile u32* through_view = reinterpret_cast<volatile u32*>(view + offset);
    const u32 saved = *through_base;
    *through_base = ++marker;
    if (*through_view != marker)
      ok = false;
    *through_view = ++marker;
    if (*through_base != marker)
      ok = false;
    *through_base = saved;
  }
  vm_deallocate(mach_task_self(), view, size);
  if (!ok)
    return false;

  // The real views are mapped at NON-ZERO offsets into the entry and are LARGE (MEM2 is 64 MB at
  // offset 24 MB+). On an A12 iPad mini 5 (iPadOS 26) a MAP_MEM_VM_SHARE entry maps a single page
  // at a non-zero offset correctly, but a large mapping at a non-zero offset silently comes back as
  // a mapping of offset 0: the MEM2 view was a second view of MEM1, and a game's clear of its MEM2
  // arena wiped its own code ("IntCPU: Unknown instruction 00000000"). Probe with mappings of the
  // same shape as the real views: from `offset` to the end of the segment.
  for (const size_t offset : {page, (size / 2) & ~(page - 1)})
  {
    if (offset >= size)
      continue;
    const size_t length = size - offset;
    vm_address_t offset_view = 0;
    const kern_return_t map_result =
        vm_map(mach_task_self(), &offset_view, length, 0, VM_FLAGS_ANYWHERE, entry,
               static_cast<vm_offset_t>(offset), false, prot, prot, VM_INHERIT_DEFAULT);
    if (map_result != KERN_SUCCESS)
    {
      ERROR_LOG_FMT(MEMMAP, "EntryMirrorsSegment: vm_map of {0:#x} bytes at offset {1:#x} returned {2:#x}",
                    length, offset, map_result);
      return false;
    }
    volatile u32* base_at_offset = reinterpret_cast<volatile u32*>(base + offset);
    volatile u32* base_at_end = reinterpret_cast<volatile u32*>(base + size - page);
    volatile u32* base_at_start = reinterpret_cast<volatile u32*>(base);
    volatile u32* view_start = reinterpret_cast<volatile u32*>(offset_view);
    volatile u32* view_end = reinterpret_cast<volatile u32*>(offset_view + length - page);
    const u32 saved_offset = *base_at_offset;
    const u32 saved_end = *base_at_end;
    const u32 saved_start = *base_at_start;
    const u32 expect_offset = ++marker;
    const u32 expect_end = ++marker;
    const u32 decoy_start = ++marker;
    *base_at_offset = expect_offset;
    *base_at_end = expect_end;
    *base_at_start = decoy_start;
    // A wrapped mapping shows the segment START (the decoy) where the offset's bytes should be.
    const bool start_ok = *view_start == expect_offset;
    const bool end_ok = *view_end == expect_end;
    const bool mirrors = start_ok && end_ok;
    *base_at_offset = saved_offset;
    *base_at_end = saved_end;
    *base_at_start = saved_start;
    vm_deallocate(mach_task_self(), offset_view, length);
    if (!mirrors)
    {
      ERROR_LOG_FMT(MEMMAP,
                    "EntryMirrorsSegment: a {0:#x}-byte view at offset {1:#x} does not mirror that "
                    "offset (start ok={2}, end ok={3})",
                    length, offset, start_ok, end_ok);
      return false;
    }
  }
  return true;
}

void MemArena::ReleaseSHMSegment()
{
  if (m_shm_entry != MACH_PORT_NULL)
  {
    mach_port_deallocate(mach_task_self(), m_shm_entry);
  }

  if (m_shm_address != 0)
  {
    vm_deallocate(mach_task_self(), m_shm_address, m_shm_size);
  }

  m_shm_address = 0;
  m_shm_size = 0;
  m_shm_entry = MACH_PORT_NULL;
}

void* MemArena::CreateView(s64 offset, size_t size)
{
  if (m_shm_address == 0)
  {
    ERROR_LOG_FMT(MEMMAP, "CreateView failed: no shared memory segment allocated");
    return nullptr;
  }

  vm_address_t address = 0;
  constexpr vm_prot_t prot = VM_PROT_READ | VM_PROT_WRITE;

  kern_return_t retval = vm_map(mach_task_self(), &address, size, 0, VM_FLAGS_ANYWHERE, m_shm_entry,
                                offset, false, prot, prot, VM_INHERIT_DEFAULT);
  if (retval != KERN_SUCCESS)
  {
    ERROR_LOG_FMT(MEMMAP, "CreateView failed: vm_map returned {0:#x}", retval);
    return nullptr;
  }

  return reinterpret_cast<void*>(address);
}

void MemArena::ReleaseView(void* view, size_t size)
{
  vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(view), size);
}

u8* MemArena::ReserveMemoryRegion(size_t memory_size)
{
  vm_address_t address = 0;

  kern_return_t retval = vm_allocate(mach_task_self(), &address, memory_size, VM_FLAGS_ANYWHERE);
  if (retval != KERN_SUCCESS)
  {
    ERROR_LOG_FMT(MEMMAP, "ReserveMemoryRegion: vm_allocate returned {0:#x}", retval);
    return nullptr;
  }

  retval = vm_protect(mach_task_self(), address, memory_size, true, VM_PROT_NONE);
  if (retval != KERN_SUCCESS)
  {
    ERROR_LOG_FMT(MEMMAP, "ReserveMemoryRegion failed: vm_prot returned {0:#x}", retval);
    return nullptr;
  }

  m_region_address = address;
  m_region_size = memory_size;

  return reinterpret_cast<u8*>(m_region_address);
}

void MemArena::ReleaseMemoryRegion()
{
  if (m_region_address != 0)
  {
    vm_deallocate(mach_task_self(), m_region_address, m_region_size);
  }

  m_region_address = 0;
  m_region_size = 0;
}

void* MemArena::MapInMemoryRegion(s64 offset, size_t size, void* base, bool writeable)
{
  if (m_shm_address == 0)
  {
    ERROR_LOG_FMT(MEMMAP, "MapInMemoryRegion failed: no shared memory segment allocated");
    return nullptr;
  }

  vm_address_t address = reinterpret_cast<vm_address_t>(base);
  vm_prot_t prot = VM_PROT_READ;
  if (writeable)
    prot |= VM_PROT_WRITE;

  kern_return_t retval =
      vm_map(mach_task_self(), &address, size, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, m_shm_entry,
             offset, false, prot, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_DEFAULT);
  if (retval != KERN_SUCCESS)
  {
    ERROR_LOG_FMT(MEMMAP, "MapInMemoryRegion failed: vm_map returned {0:#x}", retval);
    return nullptr;
  }

  return reinterpret_cast<void*>(address);
}

bool MemArena::ChangeMappingProtection(void* view, size_t size, bool writeable)
{
  vm_address_t address = reinterpret_cast<vm_address_t>(view);
  vm_prot_t prot = VM_PROT_READ;
  if (writeable)
    prot |= VM_PROT_WRITE;

  kern_return_t retval = vm_protect(mach_task_self(), address, size, false, prot);
  if (retval != KERN_SUCCESS)
    ERROR_LOG_FMT(MEMMAP, "ChangeMappingProtection failed: vm_protect returned {0:#x}", retval);

  return retval == KERN_SUCCESS;
}

void MemArena::UnmapFromMemoryRegion(void* view, size_t size)
{
  vm_address_t address = reinterpret_cast<vm_address_t>(view);

  kern_return_t retval =
      vm_allocate(mach_task_self(), &address, size, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE);
  if (retval != KERN_SUCCESS)
  {
    ERROR_LOG_FMT(MEMMAP, "UnmapFromMemoryRegion failed: vm_allocate returned {0:#x}", retval);
    return;
  }

  retval = vm_protect(mach_task_self(), address, size, true, VM_PROT_NONE);
  if (retval != KERN_SUCCESS)
  {
    ERROR_LOG_FMT(MEMMAP, "UnmapFromMemoryRegion failed: vm_prot returned {0:#x}", retval);
  }
}

size_t MemArena::GetPageSize() const
{
  return getpagesize();
}

LazyMemoryRegion::LazyMemoryRegion() = default;

LazyMemoryRegion::~LazyMemoryRegion()
{
  Release();
}

void* LazyMemoryRegion::Create(size_t size)
{
  ASSERT(!m_memory);

  if (size == 0)
    return nullptr;

  vm_address_t memory = 0;

  kern_return_t retval = vm_allocate(mach_task_self(), &memory, size, VM_FLAGS_ANYWHERE);
  if (retval != KERN_SUCCESS)
  {
    ERROR_LOG_FMT(MEMMAP, "Failed to allocate memory space: {0:#x}", retval);
    return nullptr;
  }

  m_memory = reinterpret_cast<void*>(memory);
  m_size = size;

  return m_memory;
}

void LazyMemoryRegion::Clear()
{
  ASSERT(m_memory);

  vm_address_t new_memory = reinterpret_cast<vm_address_t>(m_memory);

  kern_return_t retval =
      vm_allocate(mach_task_self(), &new_memory, m_size, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE);
  if (retval != KERN_SUCCESS)
  {
    ERROR_LOG_FMT(MEMMAP, "Failed to reallocate memory space: {0:#x}", retval);

    m_memory = nullptr;

    return;
  }

  m_memory = reinterpret_cast<void*>(new_memory);
}

void LazyMemoryRegion::Release()
{
  if (m_memory)
  {
    vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(m_memory), m_size);
  }

  m_memory = nullptr;
  m_size = 0;
}
}  // namespace Common
