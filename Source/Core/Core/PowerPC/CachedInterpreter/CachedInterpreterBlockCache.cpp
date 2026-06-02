// Copyright 2024 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/CachedInterpreter/CachedInterpreterBlockCache.h"

#include "Core/PowerPC/CachedInterpreter/CachedInterpreter.h"
#include "Core/PowerPC/CachedInterpreter/CachedInterpreterEmitter.h"
#include "Core/PowerPC/JitCommon/JitBase.h"

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
  // iCube: block-linking patcher. source.exitPtrs points at a LinkBlock trampoline emitted by
  // CachedInterpreter::WriteEndBlock (it is only ever populated for static-branch terminals; plain
  // EndBlock exits push no LinkData, so we are never called for them).
  //
  // Called by the upstream JitBaseBlockCache machinery:
  //   - LinkBlockExits (via FinalizeBlock(block_link) / LinkBlock) with dest != nullptr to PATCH a
  //     resolved link. The destination is matched on effectiveAddress + feature_flags upstream
  //     (GetBlockFromStartAddress), so dest already has the right context — no extra filtering here.
  //   - UnlinkBlock / DestroyBlock with dest == nullptr to CLEAR the link (rel = 0) before the target
  //     block's code memory is freed/poisoned. This is the path that prevents a stale rel from ever
  //     pointing into reclaimed code: every block-freeing route (Clear, ErasePhysicalRange,
  //     EraseSingleBlock) funnels through DestroyBlock -> UnlinkBlock -> WriteLinkBlock(.., nullptr).
  if (!dest)
  {
    CachedInterpreter::PatchLinkBlockRel(source.exitPtrs, 0);
    return;
  }

  // rel = distance (bytes) from the trampoline's AnyCallback slot to the target's callback stream.
  // LinkBlock recovers the same callback_site (&operands - sizeof(AnyCallback) == source.exitPtrs).
  const std::ptrdiff_t rel = dest->normalEntry - source.exitPtrs;
  CachedInterpreter::PatchLinkBlockRel(source.exitPtrs, static_cast<s32>(rel));
}

void CachedInterpreterBlockCache::WriteDestroyBlock(const JitBlock& block)
{
  CachedInterpreterEmitter emitter(block.normalEntry, block.near_end);
  emitter.Write(CachedInterpreterEmitter::PoisonCallback);
}
