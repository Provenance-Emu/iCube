// Copyright 2022 DolphiniOS Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <map>
#include <mutex>
#include <string>

namespace Common
{
// Write/execute toggling for the Legacy iOS JIT (an RX anonymous mapping made RW while a
// ScopedJITPageWriteAndNoExecute is held). Protection is per region, counted across threads: the
// first enter makes the whole region RW, the last exit makes it RX again.
//
// The tracker changes protection itself (mprotect by default). It must not go through
// Common::Un/WriteProtectMemory: those skip mprotect on iOS/tvOS for the TXM and LuckNoTXM
// mappings, and routing the Legacy toggle through them left the region RX forever (iCube#46).
//
// It depends on nothing but the standard library and POSIX so it can be unit-tested on the host,
// and it never alerts: callers report the returned errors after the tracker's lock is released.
class JITMemoryTracker final
{
public:
  // Returns 0 on success or an errno value. `writable` selects RW, otherwise RX.
  using ProtectFn = int (*)(void* ptr, size_t size, bool writable);

  enum class Op : std::uint8_t
  {
    None,
    Register,
    RegisterDuplicate,
    Unregister,
    WriteEnable,
    WriteDisable,
    Underflow,
    Miss,
  };

  // One ring-buffer record. Written for register/unregister, outermost toggles and errors only,
  // never per instruction.
  struct Event
  {
    std::uint64_t timestamp_ns;
    std::uintptr_t ptr;  // the pointer the caller passed
    std::uintptr_t region_start;
    std::size_t region_size;
    std::uint64_t thread_id;
    int nest_before;
    int nest_after;
    int error;  // errno from the protection change, 0 if none
    Op op;
  };

  struct Result
  {
    int error = 0;  // errno from a failed protection change
    bool tracked = false;
    bool underflow = false;
    void* region_start = nullptr;
    std::size_t region_size = 0;
  };

  static constexpr std::size_t RING_SIZE = 64;

  explicit JITMemoryTracker(ProtectFn protect = nullptr);

  // False when `ptr` is null or already registered.
  bool RegisterJITRegion(void* ptr, size_t size);
  void UnregisterJITRegion(void* ptr);

  Result JITRegionWriteEnableExecuteDisable(void* ptr);
  Result JITRegionWriteDisableExecuteEnable(void* ptr);

  bool IsTracked(const void* ptr);
  // -1 when `ptr` is in no tracked region.
  int GetNestCount(const void* ptr);

  // Names the region containing `ptr` (start, size, nest count) and lists up to `max_events` of
  // the most recent ring events, newest last. Uses try_lock: it may run on the Mach exception
  // thread while the faulting thread is suspended, and must never block there. `in_region`, when
  // given, is set to whether `ptr` is in a tracked region (true when the lock was busy: unknown).
  std::string FormatState(const void* ptr, std::size_t max_events = RING_SIZE,
                          bool* in_region = nullptr);

  static const char* OpName(Op op);

private:
  struct JITRegionInfo
  {
    void* start_ptr;
    size_t size;
    int nest_counter;
  };

  JITRegionInfo* FindRegion(const void* ptr);
  void Record(Op op, const void* ptr, const JITRegionInfo* info, int nest_before, int nest_after,
              int error);

  ProtectFn m_protect;
  std::map<std::uintptr_t, JITRegionInfo> m_jit_regions;
  std::array<Event, RING_SIZE> m_ring{};
  std::size_t m_ring_next = 0;
  std::size_t m_ring_count = 0;
  std::mutex m_mutex;
};
}  // namespace Common
