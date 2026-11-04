// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Common/JITMemoryTracker.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cinttypes>
#include <cstdio>
#include <functional>
#include <thread>

#include <sys/mman.h>
#if defined(__APPLE__)
#include <pthread.h>
#endif

namespace Common
{
namespace
{
int MprotectRegion(void* ptr, size_t size, bool writable)
{
  const int prot = writable ? (PROT_READ | PROT_WRITE) : (PROT_READ | PROT_EXEC);
  return mprotect(ptr, size, prot) == 0 ? 0 : errno;
}

std::uint64_t CurrentThreadId()
{
#if defined(__APPLE__)
  std::uint64_t tid = 0;
  pthread_threadid_np(nullptr, &tid);
  return tid;
#else
  return static_cast<std::uint64_t>(std::hash<std::thread::id>{}(std::this_thread::get_id()));
#endif
}

std::uint64_t NowNs()
{
  return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(
                                        std::chrono::steady_clock::now().time_since_epoch())
                                        .count());
}
}  // namespace

JITMemoryTracker::JITMemoryTracker(ProtectFn protect)
    : m_protect(protect ? protect : &MprotectRegion)
{
}

const char* JITMemoryTracker::OpName(Op op)
{
  switch (op)
  {
  case Op::Register:
    return "register";
  case Op::RegisterDuplicate:
    return "register-duplicate";
  case Op::Unregister:
    return "unregister";
  case Op::WriteEnable:
    return "rw";
  case Op::WriteDisable:
    return "rx";
  case Op::Underflow:
    return "underflow";
  case Op::Miss:
    return "miss";
  case Op::None:
    break;
  }
  return "none";
}

void JITMemoryTracker::Record(Op op, const void* ptr, const JITRegionInfo* info, int nest_before,
                              int nest_after, int error)
{
  Event& event = m_ring[m_ring_next];
  event.timestamp_ns = NowNs();
  event.ptr = reinterpret_cast<std::uintptr_t>(ptr);
  event.region_start = info ? reinterpret_cast<std::uintptr_t>(info->start_ptr) : 0;
  event.region_size = info ? info->size : 0;
  event.thread_id = CurrentThreadId();
  event.nest_before = nest_before;
  event.nest_after = nest_after;
  event.error = error;
  event.op = op;

  m_ring_next = (m_ring_next + 1) % RING_SIZE;
  if (m_ring_count < RING_SIZE)
    m_ring_count++;
}

bool JITMemoryTracker::RegisterJITRegion(void* ptr, size_t size)
{
  if (!ptr)
    return false;

  std::scoped_lock lk(m_mutex);

  const auto key = reinterpret_cast<std::uintptr_t>(ptr);
  if (auto it = m_jit_regions.find(key); it != m_jit_regions.end())
  {
    Record(Op::RegisterDuplicate, ptr, &it->second, it->second.nest_counter,
           it->second.nest_counter, 0);
    return false;
  }

  JITRegionInfo& info = m_jit_regions[key] = {ptr, size, 0};
  Record(Op::Register, ptr, &info, 0, 0, 0);
  return true;
}

void JITMemoryTracker::UnregisterJITRegion(void* ptr)
{
  std::scoped_lock lk(m_mutex);

  const auto it = m_jit_regions.find(reinterpret_cast<std::uintptr_t>(ptr));
  if (it == m_jit_regions.end())
    return;

  Record(Op::Unregister, ptr, &it->second, it->second.nest_counter, 0, 0);
  m_jit_regions.erase(it);
}

JITMemoryTracker::JITRegionInfo* JITMemoryTracker::FindRegion(const void* ptr)
{
  const auto addr = reinterpret_cast<std::uintptr_t>(ptr);

  // The last region starting at or before addr is the only candidate (regions never overlap).
  auto it = m_jit_regions.upper_bound(addr);
  if (it == m_jit_regions.begin())
    return nullptr;
  --it;

  if (addr - it->first < it->second.size)
    return &it->second;

  return nullptr;
}

JITMemoryTracker::Result JITMemoryTracker::JITRegionWriteEnableExecuteDisable(void* ptr)
{
  std::scoped_lock lk(m_mutex);

  Result result;
  JITRegionInfo* info = FindRegion(ptr);
  if (!info)
  {
    Record(Op::Miss, ptr, nullptr, -1, -1, 0);
    return result;
  }

  result.tracked = true;
  result.region_start = info->start_ptr;
  result.region_size = info->size;

  const int before = info->nest_counter;
  if (before == 0)
  {
    result.error = m_protect(info->start_ptr, info->size, true);
    Record(Op::WriteEnable, ptr, info, before, before + 1, result.error);
  }

  info->nest_counter++;
  return result;
}

JITMemoryTracker::Result JITMemoryTracker::JITRegionWriteDisableExecuteEnable(void* ptr)
{
  std::scoped_lock lk(m_mutex);

  Result result;
  JITRegionInfo* info = FindRegion(ptr);
  if (!info)
  {
    Record(Op::Miss, ptr, nullptr, -1, -1, 0);
    return result;
  }

  result.tracked = true;
  result.region_start = info->start_ptr;
  result.region_size = info->size;

  const int before = info->nest_counter;
  if (before <= 0)
  {
    // Leave the counter at 0 rather than going negative, so one stray exit cannot make the
    // next enter skip the RW change.
    result.underflow = true;
    Record(Op::Underflow, ptr, info, before, 0, 0);
    info->nest_counter = 0;
    return result;
  }

  info->nest_counter = before - 1;
  if (info->nest_counter == 0)
  {
    result.error = m_protect(info->start_ptr, info->size, false);
    Record(Op::WriteDisable, ptr, info, before, 0, result.error);
  }

  return result;
}

bool JITMemoryTracker::IsTracked(const void* ptr)
{
  std::scoped_lock lk(m_mutex);
  return FindRegion(ptr) != nullptr;
}

int JITMemoryTracker::GetNestCount(const void* ptr)
{
  std::scoped_lock lk(m_mutex);
  const JITRegionInfo* info = FindRegion(ptr);
  return info ? info->nest_counter : -1;
}

std::string JITMemoryTracker::FormatState(const void* ptr, std::size_t max_events,
                                          bool* in_region)
{
  std::unique_lock lk(m_mutex, std::try_to_lock);
  if (!lk.owns_lock())
  {
    if (in_region)
      *in_region = true;
    return "legacy JIT tracker: busy (lock held), no snapshot";
  }

  char line[256];
  std::string out;

  const JITRegionInfo* info = FindRegion(ptr);
  if (in_region)
    *in_region = info != nullptr;
  if (info)
  {
    std::snprintf(line, sizeof(line),
                  "legacy JIT tracker: addr %p in region %p+0x%zx nest=%d (%s); %zu regions;"
                  " this thread %" PRIu64 "\n",
                  ptr, info->start_ptr, info->size, info->nest_counter,
                  info->nest_counter > 0 ? "should be RW" : "RX", m_jit_regions.size(),
                  CurrentThreadId());
  }
  else
  {
    std::snprintf(line, sizeof(line),
                  "legacy JIT tracker: addr %p in no tracked region; %zu regions;"
                  " this thread %" PRIu64 "\n",
                  ptr, m_jit_regions.size(), CurrentThreadId());
  }
  out += line;

  const std::uint64_t now = NowNs();
  const std::size_t count = std::min(max_events, m_ring_count);
  for (std::size_t i = 0; i < count; i++)
  {
    const std::size_t index = (m_ring_next + RING_SIZE - count + i) % RING_SIZE;
    const Event& e = m_ring[index];
    std::snprintf(line, sizeof(line),
                  "  -%" PRIu64 "us %s ptr=0x%" PRIxPTR " region=0x%" PRIxPTR "+0x%zx nest %d->%d"
                  " err=%d tid=%" PRIu64 "\n",
                  (now - e.timestamp_ns) / 1000, OpName(e.op), e.ptr, e.region_start,
                  e.region_size, e.nest_before, e.nest_after, e.error, e.thread_id);
    out += line;
  }

  return out;
}
}  // namespace Common
