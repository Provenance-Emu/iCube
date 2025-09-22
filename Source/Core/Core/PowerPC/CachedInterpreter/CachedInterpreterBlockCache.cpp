// Copyright 2024 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/CachedInterpreter/CachedInterpreterBlockCache.h"

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
  // The link trampoline is encoded as [AnyCallback][LinkToBlockOperands].
  // We only patch the trailing 'rel' field inside the operands.
  struct LinkToBlockOperandsView
  {
    u32 downcount;
    u32 num_load_stores;
    u32 num_fp_inst;
    u32 expected_pc;
    void* profile_data; // pointer-sized placeholder; only used by the callback
    s32 rel;
  };

  auto* operands = reinterpret_cast<LinkToBlockOperandsView*>(source.exitPtrs + sizeof(void*));
  if (!dest)
  {
    operands->rel = 0;
    return;
  }

  const s64 rel = static_cast<s64>(reinterpret_cast<const u8*>(dest->normalEntry) - source.exitPtrs);
  // Clamp to s32 range just in case.
  operands->rel = static_cast<s32>(rel);
}

void CachedInterpreterBlockCache::WriteDestroyBlock(const JitBlock& block)
{
  CachedInterpreterEmitter emitter(block.normalEntry, block.near_end);
  emitter.Write(CachedInterpreterEmitter::PoisonCallback);
}
