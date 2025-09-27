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

  // If dest is null, we should restore EndBlock; however, for now we just skip since
  // our shadow-mode only patches forward. A subsequent DestroyBlock/Poison will make
  // callbacks safe if blocks are invalidated.
  if (!dest)
    return;

  // Compute relative distance from the patched EndBlock site to dest->normalEntry.
  // The callback loop computes new_entry = old_entry + returned_distance.
  const u8* const cb_ptr = source.exitPtrs;              // points at callback pointer
  constexpr std::size_t kPtrSize = sizeof(&CachedInterpreter::LinkToBlockEndDistance);
  const u8* const operands_ptr = cb_ptr + kPtrSize;
  const u8* const dest_entry = dest->normalEntry;
  const s64 distance = static_cast<s64>(dest_entry - cb_ptr);

  // Patch callback to LinkToBlockEndDistance and store distance into 4th u32 of operands.
  // Overwrite callback pointer in place.
  auto func = &CachedInterpreter::LinkToBlockEndDistance;
  std::memcpy(const_cast<u8*>(cb_ptr), &func, kPtrSize);
  // Write the distance into the last u32 of the existing operands blob.
  // We must not disturb the first three u32 which were already written.
  u32* const tail = reinterpret_cast<u32*>(const_cast<u8*>(operands_ptr)) + 3;
  *tail = static_cast<u32>(static_cast<s32>(distance));
  CachedInterpreter::OnLinkPatched();
}

void CachedInterpreterBlockCache::WriteDestroyBlock(const JitBlock& block)
{
  CachedInterpreterEmitter emitter(block.normalEntry, block.near_end);
  emitter.Write(CachedInterpreterEmitter::PoisonCallback);
}
