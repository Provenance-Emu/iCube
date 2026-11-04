// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <atomic>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <thread>
#include <vector>

#include <sys/mman.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach/mach.h>
#include <mach/mach_vm.h>
#endif

#include <gtest/gtest.h>

#include "Common/JITMemoryTracker.h"

using Common::JITMemoryTracker;

namespace
{
struct ProtectCall
{
  void* ptr;
  size_t size;
  bool writable;
};

std::vector<ProtectCall> s_calls;

int RecordingProtect(void* ptr, size_t size, bool writable)
{
  s_calls.push_back({ptr, size, writable});
  return 0;
}

int FailingProtect(void*, size_t, bool)
{
  return EPERM;
}

// What the tracker did on iOS/tvOS from 891d8f4ea2 until iCube#46: UnWriteProtectMemory and
// WriteProtectMemory skipped mprotect there and returned true.
int NoOpProtect(void*, size_t, bool)
{
  return 0;
}

constexpr size_t REGION_SIZE = 64 * 1024;

void* MapRX(size_t size)
{
  void* ptr = mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
  return ptr == MAP_FAILED ? nullptr : ptr;
}

#if defined(__APPLE__)
// Current protection of the page containing ptr, read without touching it.
int QueryProtection(void* ptr)
{
  mach_vm_address_t address = reinterpret_cast<mach_vm_address_t>(ptr);
  mach_vm_size_t size = 0;
  vm_region_basic_info_data_64_t info;
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
  mach_port_t object = MACH_PORT_NULL;
  if (mach_vm_region(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
                     reinterpret_cast<vm_region_info_t>(&info), &count, &object) != KERN_SUCCESS)
  {
    return -1;
  }
  return info.protection;
}
#endif
}  // namespace

TEST(JITMemoryTracker, NestedScopesToggleOnlyAtTheOutermostLevel)
{
  s_calls.clear();
  JITMemoryTracker tracker(&RecordingProtect);
  alignas(16) static std::uint8_t region[REGION_SIZE];

  ASSERT_TRUE(tracker.RegisterJITRegion(region, sizeof(region)));

  auto r = tracker.JITRegionWriteEnableExecuteDisable(region);
  EXPECT_TRUE(r.tracked);
  EXPECT_EQ(0, r.error);
  tracker.JITRegionWriteEnableExecuteDisable(region + 100);  // interior pointer, nested
  EXPECT_EQ(2, tracker.GetNestCount(region));
  ASSERT_EQ(1u, s_calls.size());
  EXPECT_TRUE(s_calls[0].writable);
  EXPECT_EQ(static_cast<void*>(region), s_calls[0].ptr);
  EXPECT_EQ(sizeof(region), s_calls[0].size);

  tracker.JITRegionWriteDisableExecuteEnable(region + 100);
  EXPECT_EQ(1u, s_calls.size()) << "inner exit must keep the region writable";
  tracker.JITRegionWriteDisableExecuteEnable(region);
  ASSERT_EQ(2u, s_calls.size());
  EXPECT_FALSE(s_calls[1].writable);
  EXPECT_EQ(0, tracker.GetNestCount(region));
}

TEST(JITMemoryTracker, RegionBoundsAreHalfOpen)
{
  s_calls.clear();
  JITMemoryTracker tracker(&RecordingProtect);
  alignas(16) static std::uint8_t regions[2 * REGION_SIZE];
  std::uint8_t* first = regions;
  std::uint8_t* second = regions + REGION_SIZE;

  ASSERT_TRUE(tracker.RegisterJITRegion(first, REGION_SIZE));
  EXPECT_TRUE(tracker.IsTracked(first + REGION_SIZE - 1));
  EXPECT_FALSE(tracker.IsTracked(first + REGION_SIZE));
  EXPECT_FALSE(tracker.IsTracked(first - 1));

  // An adjacent region starting exactly at the first one's end gets its own toggle.
  ASSERT_TRUE(tracker.RegisterJITRegion(second, REGION_SIZE));
  tracker.JITRegionWriteEnableExecuteDisable(second);
  ASSERT_EQ(1u, s_calls.size());
  EXPECT_EQ(static_cast<void*>(second), s_calls[0].ptr);
  EXPECT_EQ(0, tracker.GetNestCount(first));
  tracker.JITRegionWriteDisableExecuteEnable(second);
}

TEST(JITMemoryTracker, UntrackedPointerAndUnderflowAreReported)
{
  s_calls.clear();
  JITMemoryTracker tracker(&RecordingProtect);
  alignas(16) static std::uint8_t region[REGION_SIZE];
  alignas(16) static std::uint8_t elsewhere[16];

  ASSERT_TRUE(tracker.RegisterJITRegion(region, sizeof(region)));
  EXPECT_FALSE(tracker.RegisterJITRegion(region, sizeof(region)));
  EXPECT_FALSE(tracker.RegisterJITRegion(nullptr, 16));

  EXPECT_FALSE(tracker.JITRegionWriteEnableExecuteDisable(elsewhere).tracked);

  auto r = tracker.JITRegionWriteDisableExecuteEnable(region);
  EXPECT_TRUE(r.underflow);
  EXPECT_EQ(0, tracker.GetNestCount(region));
  EXPECT_TRUE(s_calls.empty());

  // After the stray exit the next enter still makes the region writable.
  tracker.JITRegionWriteEnableExecuteDisable(region);
  ASSERT_EQ(1u, s_calls.size());
  EXPECT_TRUE(s_calls[0].writable);

  const std::string state = tracker.FormatState(region);
  EXPECT_NE(std::string::npos, state.find("nest=1"));
  EXPECT_NE(std::string::npos, state.find("miss"));
  EXPECT_NE(std::string::npos, state.find("underflow"));
  EXPECT_NE(std::string::npos, state.find("register-duplicate"));
}

TEST(JITMemoryTracker, ProtectionErrorIsReturnedAndRecorded)
{
  JITMemoryTracker tracker(&FailingProtect);
  alignas(16) static std::uint8_t region[REGION_SIZE];
  ASSERT_TRUE(tracker.RegisterJITRegion(region, sizeof(region)));

  auto r = tracker.JITRegionWriteEnableExecuteDisable(region);
  EXPECT_EQ(EPERM, r.error);
  EXPECT_EQ(static_cast<void*>(region), r.region_start);
  EXPECT_NE(std::string::npos, tracker.FormatState(region).find("err=" + std::to_string(EPERM)));
}

TEST(JITMemoryTracker, RingKeepsOnlyTheNewestEvents)
{
  JITMemoryTracker tracker(&NoOpProtect);
  alignas(16) static std::uint8_t region[REGION_SIZE];
  ASSERT_TRUE(tracker.RegisterJITRegion(region, sizeof(region)));
  for (size_t i = 0; i < 3 * JITMemoryTracker::RING_SIZE; i++)
  {
    tracker.JITRegionWriteEnableExecuteDisable(region);
    tracker.JITRegionWriteDisableExecuteEnable(region);
  }

  const std::string state = tracker.FormatState(region, 4);
  size_t lines = 0;
  for (char c : state)
    lines += c == '\n';
  EXPECT_EQ(5u, lines);  // header + 4 events
  EXPECT_EQ(std::string::npos, state.find("register"));
}

TEST(JITMemoryTracker, RealMappingIsWritableInsideScopeAndRXAfter)
{
  void* ptr = MapRX(REGION_SIZE);
  ASSERT_NE(nullptr, ptr);
  JITMemoryTracker tracker;  // default: mprotect
  ASSERT_TRUE(tracker.RegisterJITRegion(ptr, REGION_SIZE));

  auto* bytes = static_cast<std::uint8_t*>(ptr);
  ASSERT_EQ(0, tracker.JITRegionWriteEnableExecuteDisable(bytes + 64).error);
  ASSERT_EQ(0, tracker.JITRegionWriteEnableExecuteDisable(bytes).error);  // nested
  std::memset(bytes, 0xAB, REGION_SIZE);
  ASSERT_EQ(0, tracker.JITRegionWriteDisableExecuteEnable(bytes).error);
  bytes[REGION_SIZE - 1] = 0xCD;  // still inside the outer scope
  ASSERT_EQ(0, tracker.JITRegionWriteDisableExecuteEnable(bytes + 64).error);

  EXPECT_EQ(0xAB, bytes[0]);
  EXPECT_EQ(0xCD, bytes[REGION_SIZE - 1]);
#if defined(__APPLE__)
  EXPECT_EQ(VM_PROT_READ | VM_PROT_EXECUTE, QueryProtection(ptr));
#endif

  tracker.UnregisterJITRegion(ptr);
  munmap(ptr, REGION_SIZE);
}

TEST(JITMemoryTracker, TwoThreadsOnOneRegion)
{
  void* ptr = MapRX(REGION_SIZE);
  ASSERT_NE(nullptr, ptr);
  JITMemoryTracker tracker;
  ASSERT_TRUE(tracker.RegisterJITRegion(ptr, REGION_SIZE));

  std::atomic<int> errors{0};
  auto worker = [&](size_t offset) {
    auto* bytes = static_cast<std::uint8_t*>(ptr) + offset;
    for (int i = 0; i < 2000; i++)
    {
      if (tracker.JITRegionWriteEnableExecuteDisable(bytes).error != 0)
        errors++;
      // Faults (SIGBUS) if the other thread's exit made the region RX while this one writes.
      bytes[i % 1024] = static_cast<std::uint8_t>(i);
      if (tracker.JITRegionWriteDisableExecuteEnable(bytes).error != 0)
        errors++;
    }
  };

  std::thread a(worker, 0);
  std::thread b(worker, REGION_SIZE / 2);
  a.join();
  b.join();

  EXPECT_EQ(0, errors.load());
  EXPECT_EQ(0, tracker.GetNestCount(ptr));
#if defined(__APPLE__)
  EXPECT_EQ(VM_PROT_READ | VM_PROT_EXECUTE, QueryProtection(ptr));
#endif

  tracker.UnregisterJITRegion(ptr);
  munmap(ptr, REGION_SIZE);
}

// The pre-fix behaviour on iOS: the toggle "succeeds" without changing protection, and the first
// emitter write into the RX region faults (ICUBE-AA / ICUBE-A9).
TEST(JITMemoryTrackerDeathTest, NoOpToggleLeavesRegionRX)
{
  GTEST_FLAG_SET(death_test_style, "threadsafe");
  void* ptr = MapRX(REGION_SIZE);
  ASSERT_NE(nullptr, ptr);
  // Darwin reports a write to a mapped page without write permission as SIGBUS.
  EXPECT_EXIT(
      {
        JITMemoryTracker tracker(&NoOpProtect);
        tracker.RegisterJITRegion(ptr, REGION_SIZE);
        tracker.JITRegionWriteEnableExecuteDisable(ptr);
        *static_cast<volatile std::uint32_t*>(ptr) = 0xD503201F;  // NOP
      },
      testing::KilledBySignal(SIGBUS), "");
  munmap(ptr, REGION_SIZE);
}
