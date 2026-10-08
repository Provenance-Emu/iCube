// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

// iCube: runtime-dispatched ARMv8.1 LSE atomics for hot cross-thread counters.
//
// The iOS/tvOS core is built for apple-a10, which predates LSE, so every std::atomic
// read-modify-write compiles to a load-exclusive/store-exclusive retry loop. Under contention
// (two cores bouncing the same cache line) those loops are slow and can retry; a single ldadd is
// executed at the cache and cannot fail. CPReadWriteDistance is the case that matters: the CPU
// thread adds 32 for every gather-pipe burst while the video thread subtracts what it drained,
// and on an iPhone 16 Pro Max that pair was ~2 % of the CPU thread and a top video-thread hot spot.
// Functions carrying target("lse") are never inlined into apple-a10 callers, so each helper costs
// one well-predicted branch plus a call on LSE hardware and nothing changes on A10/A8.

#include <atomic>

#include "Common/CPUDetect.h"
#include "Common/CommonTypes.h"

namespace Common
{
#if defined(__aarch64__) && defined(__clang__)
__attribute__((target("lse"))) inline u32 AtomicFetchAddLSE(std::atomic<u32>& value, u32 operand)
{
  return value.fetch_add(operand, std::memory_order_seq_cst);
}

__attribute__((target("lse"))) inline u32 AtomicFetchSubLSE(std::atomic<u32>& value, u32 operand)
{
  return value.fetch_sub(operand, std::memory_order_seq_cst);
}
#endif

// Sequentially consistent fetch_add / fetch_sub, using LSE when the CPU has it.
inline u32 AtomicFetchAdd(std::atomic<u32>& value, u32 operand)
{
#if defined(__aarch64__) && defined(__clang__)
  if (cpu_info.bLSE)
    return AtomicFetchAddLSE(value, operand);
#endif
  return value.fetch_add(operand, std::memory_order_seq_cst);
}

inline u32 AtomicFetchSub(std::atomic<u32>& value, u32 operand)
{
#if defined(__aarch64__) && defined(__clang__)
  if (cpu_info.bLSE)
    return AtomicFetchSubLSE(value, operand);
#endif
  return value.fetch_sub(operand, std::memory_order_seq_cst);
}
}  // namespace Common
