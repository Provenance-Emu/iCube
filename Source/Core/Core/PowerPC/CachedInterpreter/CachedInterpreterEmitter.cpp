// Copyright 2024 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/CachedInterpreter/CachedInterpreterEmitter.h"

#include <algorithm>
#include <cstring>
#include <unordered_map>

#include "Common/Assert.h"
#include "Common/MsgHandler.h"

#if defined(__clang__) || defined(__GNUC__)
#if defined(__aarch64__)
#define CI_HOT_FLATTEN [[gnu::hot, gnu::flatten]]
#define CI_HOT_ONLY [[gnu::hot]]
#else
#define CI_HOT_FLATTEN [[gnu::hot]]
#define CI_HOT_ONLY [[gnu::hot]]
#endif
#else
#define CI_HOT_FLATTEN
#define CI_HOT_ONLY
#endif

namespace {
// Mapping from callback pointer to CallbackId for id-dispatch mode.
static std::unordered_map<const void*, CachedInterpreterEmitter::CallbackId> g_cb_to_id;
}

void CachedInterpreterEmitter::RegisterIdForCallback(AnyCallback callback, CallbackId id)
{
  g_cb_to_id.emplace(reinterpret_cast<const void*>(callback), id);
}

CI_HOT_ONLY void CachedInterpreterEmitter::Write(AnyCallback callback, const void* operands, std::size_t size)
{
#if defined(__aarch64__)
  __builtin_prefetch(m_code + 64, 1, 1);
  __builtin_prefetch(m_code + 128, 1, 1);
#endif
  DEBUG_ASSERT(reinterpret_cast<std::uintptr_t>(m_code) % alignof(AnyCallback) == 0);
  if (m_code + sizeof(callback) + size >= m_code_end)
  {
    m_write_failed = true;
    return;
  }
  if (s_use_id_dispatch)
  {
    auto it = g_cb_to_id.find(reinterpret_cast<const void*>(callback));
    if (it != g_cb_to_id.end())
    {
      // Emit 16-bit ID + 16-bit tag + padding to sizeof(AnyCallback)
      const CallbackId id = it->second;
      const u16 id_raw = static_cast<u16>(id);
      std::memcpy(m_code, &id_raw, sizeof(id_raw));
      // Tag to identify ID headers when mixed with pointer headers
      const u16 tag = 0xC1D1; // "CI" + "DI" hint
      std::memcpy(m_code + sizeof(id_raw), &tag, sizeof(tag));
      // Zero padding improves determinism
      std::memset(m_code + 2 * sizeof(u16), 0, sizeof(AnyCallback) - 2 * sizeof(u16));
      m_code += sizeof(AnyCallback);
    }
    else
    {
      std::memcpy(m_code, &callback, sizeof(callback));
      m_code += sizeof(callback);
    }
  }
  else
  {
    std::memcpy(m_code, &callback, sizeof(callback));
    m_code += sizeof(callback);
  }
  if (size == 0)
    return;
  std::memcpy(m_code, operands, size);
  m_code += size;
}

CI_HOT_ONLY u8* CachedInterpreterEmitter::WriteReturningAddress(AnyCallback callback, const void* operands, std::size_t size)
{
#if defined(__aarch64__)
  __builtin_prefetch(m_code + 64, 1, 1);
  __builtin_prefetch(m_code + 128, 1, 1);
#endif
  DEBUG_ASSERT(reinterpret_cast<std::uintptr_t>(m_code) % alignof(AnyCallback) == 0);
  if (m_code + sizeof(callback) + size >= m_code_end)
  {
    m_write_failed = true;
    return nullptr;
  }
  u8* const addr = m_code; // address where the header (ptr or id) will be written
  if (s_use_id_dispatch)
  {
    auto it = g_cb_to_id.find(reinterpret_cast<const void*>(callback));
    if (it != g_cb_to_id.end())
    {
      const CallbackId id = it->second;
      const u16 id_raw = static_cast<u16>(id);
      std::memcpy(m_code, &id_raw, sizeof(id_raw));
      const u16 tag = 0xC1D1;
      std::memcpy(m_code + sizeof(id_raw), &tag, sizeof(tag));
      std::memset(m_code + 2 * sizeof(u16), 0, sizeof(AnyCallback) - 2 * sizeof(u16));
      m_code += sizeof(AnyCallback);
    }
    else
    {
      std::memcpy(m_code, &callback, sizeof(callback));
      m_code += sizeof(callback);
    }
  }
  else
  {
    std::memcpy(m_code, &callback, sizeof(callback));
    m_code += sizeof(callback);
  }
  if (size != 0)
  {
    std::memcpy(m_code, operands, size);
    m_code += size;
  }
  return addr;
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
  if (CachedInterpreterEmitter::IsIdDispatchEnabled())
  {
    // Write Poison ID headers across the region.
    for (u8* p = region; p < region + region_size; p += sizeof(AnyCallback))
    {
      const u16 id_raw = static_cast<u16>(CachedInterpreterEmitter::CallbackId::Poison);
      const u16 tag = 0xC1D1;
      std::memcpy(p, &id_raw, sizeof(id_raw));
      std::memcpy(p + sizeof(id_raw), &tag, sizeof(tag));
      std::memset(p + 2 * sizeof(u16), 0, sizeof(AnyCallback) - 2 * sizeof(u16));
    }
  }
  else
  {
    std::fill(reinterpret_cast<AnyCallback*>(region),
              reinterpret_cast<AnyCallback*>(region + region_size), AnyCallbackCast(PoisonCallback));
  }
}
