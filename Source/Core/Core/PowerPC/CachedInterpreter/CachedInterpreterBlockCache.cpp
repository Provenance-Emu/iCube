// Copyright 2024 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/CachedInterpreter/CachedInterpreterBlockCache.h"

#include "Core/PowerPC/CachedInterpreter/CachedInterpreterEmitter.h"
#include "Core/PowerPC/CachedInterpreter/CachedInterpreter.h"
#include "Core/PowerPC/JitCommon/JitBase.h"
\
#include <cstring>

CachedInterpreterBlockCache::CachedInterpreterBlockCache(JitBase& jit) : JitBaseBlockCache{jit}
{
}

void CachedInterpreterBlockCache::Init()
{
  JitBaseBlockCache::Init();
  ClearRangesToFree();
}

void CachedInterpreterBlockCache::DestroyBlock(JitBlock& block)
{
  JitBaseBlockCache::DestroyBlock(block);

  if (block.near_begin != block.near_end)
    m_ranges_to_free_on_next_codegen.emplace_back(block.near_begin, block.near_end);
}

void CachedInterpreterBlockCache::ClearRangesToFree()
{
  m_ranges_to_free_on_next_codegen.clear();
}

void CachedInterpreterBlockCache::WriteLinkBlock(const JitBlock::LinkData& source,
                                                 const JitBlock* dest)
{
  // Only patch when linking is enabled; otherwise, this remains no-op.
  if (!CachedInterpreter::IsBlockLinkingEnabled())
    return;
  // Enable ID-only linking when both ID-dispatch is on and the flag DOLPHIN_CI_ID_LINK=1 is set.
  static bool s_id_link = []() {
    if (const char* env = std::getenv("DOLPHIN_CI_ID_LINK"))
      return env[0] == '1';
    return false;
  }();
  if (!CachedInterpreterEmitter::IsIdDispatchEnabled() || !s_id_link)
    return; // Do not link unless explicitly enabled for ID mode

  // If dest is null, we should restore EndBlock; however, for now we just skip since
  // our shadow-mode only patches forward. A subsequent DestroyBlock/Poison will make
  // callbacks safe if blocks are invalidated.
  if (!dest)
    return;

  // Compute relative distance from the patched EndBlock site to dest->normalEntry.
  // The callback loop computes new_entry = old_entry + returned_distance.
  const u8* const cb_ptr = source.exitPtrs;              // points at header (ptr or ID)
  constexpr std::size_t kHdrSize = CachedInterpreterEmitter::kHeaderSize;
  const u8* const operands_ptr = cb_ptr + kHdrSize;
  const u8* const dest_entry = dest->normalEntry;
  const s64 distance = static_cast<s64>(dest_entry - cb_ptr);

  // Emit LinkToBlockEndDistance as an ID header with distance operand at the start
  const u16 id_raw = static_cast<u16>(CachedInterpreterEmitter::CallbackId::LinkToBlockEndDistance);
  const u16 tag = 0xC1D1;
  std::memcpy(const_cast<u8*>(cb_ptr), &id_raw, sizeof(id_raw));
  std::memcpy(const_cast<u8*>(cb_ptr) + sizeof(id_raw), &tag, sizeof(tag));
  std::memset(const_cast<u8*>(cb_ptr) + 2 * sizeof(u16), 0,
              CachedInterpreterEmitter::kHeaderSize - 2 * sizeof(u16));

  auto* link_ops = reinterpret_cast<CachedInterpreterEmitter::LinkToBlockDistanceOperands*>(
      const_cast<u8*>(operands_ptr));
  link_ops->distance = static_cast<s32>(distance);
  CachedInterpreter::OnLinkPatched();
}

void CachedInterpreterBlockCache::WriteDestroyBlock(const JitBlock& block)
{
  CachedInterpreterEmitter emitter(block.normalEntry, block.near_end);
  emitter.Write(CachedInterpreterEmitter::PoisonCallback);
}
