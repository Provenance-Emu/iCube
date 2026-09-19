// Copyright 2024 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/CachedInterpreter/CachedInterpreterEmitter.h"

#include <algorithm>
#include <cstring>

#include "Common/Assert.h"

void CachedInterpreterEmitter::Write(AnyCallback callback, const void* operands, std::size_t size)
{
  DEBUG_ASSERT(reinterpret_cast<std::uintptr_t>(m_code) % alignof(AnyCallback) == 0);
  if (m_code + sizeof(callback) + size >= m_code_end)
  {
    m_write_failed = true;
    return;
  }
  std::memcpy(m_code, &callback, sizeof(callback));
  m_code += sizeof(callback);
  if (size == 0)
    return;
  std::memcpy(m_code, operands, size);
  m_code += size;
}

void CachedInterpreterEmitter::WriteChainable(AnyCallback unchained, const void* operands,
                                              std::size_t size, std::size_t patch_offset,
                                              u64 patch_value, std::size_t patch_size)
{
  u8* const record = m_code;
  const auto tagged = reinterpret_cast<AnyCallback>(reinterpret_cast<std::uintptr_t>(unchained) |
                                                    CHAIN_TAG);
  Write(tagged, operands, size);
  if (m_write_failed)
  {
    ResetChain();
    return;
  }
  // The previous chain-capable record ends exactly where this one starts: nothing else was emitted
  // in between, so it may fall straight into this record.
  if (m_chaining_enabled && m_chain_prev_end == record)
    std::memcpy(m_chain_patch_addr, &m_chain_patch_value, m_chain_patch_size);
  m_chain_prev_end = m_code;
  m_chain_patch_addr = record + patch_offset;
  m_chain_patch_value = patch_value;
  m_chain_patch_size = patch_size;
}

s32 CachedInterpreterEmitter::PoisonCallback(PowerPC::PowerPCState& ppc_state, const void* operands)
{
  ASSERT_MSG(DYNA_REC, false,
             "The Cached Interpreter reached a poisoned callback. This should never happen!");
  return 0;
}

void CachedInterpreterCodeBlock::PoisonMemory()
{
  DEBUG_ASSERT(reinterpret_cast<std::uintptr_t>(region) % alignof(AnyCallback) == 0);
  DEBUG_ASSERT(region_size % sizeof(AnyCallback) == 0);
  std::fill(reinterpret_cast<AnyCallback*>(region),
            reinterpret_cast<AnyCallback*>(region + region_size), AnyCallbackCast(PoisonCallback));
}
