// Copyright 2014 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/JitArm64/Jit.h"

#include <cstddef>
#include <optional>
#include <string>

#include "Common/Align.h"
#include "Common/BitSet.h"
#include "Common/CommonFuncs.h"
#include "Common/CommonTypes.h"
#include "Common/Logging/Log.h"
#include "Common/MathUtil.h"
#include "Common/StringUtil.h"
#include "Common/Swap.h"

#include "Core/PowerPC/Gekko.h"
#include "Core/PowerPC/JitArm64/Jit_Util.h"
#include "Core/PowerPC/JitArmCommon/BackPatch.h"
#include "Core/PowerPC/MMU.h"
#include "Core/PowerPC/PowerPC.h"

using namespace Arm64Gen;

const u8* JitArm64::GetOrCreateSlowPathThunk(u32 flags, bool memcheck, bool emitting_routine)
{
  SlowThunkKey key{flags, memcheck};
  auto it = m_slow_thunk_cache.find(key);
  if (it != m_slow_thunk_cache.end())
    return it->second;

  // Emit in far code
  const bool was_in_far = IsInFarCode();
  if (!was_in_far)
    SwitchToFarCode();

  const u8* entry = GetCodePtr();

  // Re-emit the slow path body for this shape, minimal wrapper: we rely on the same
  // body that EmitBackpatchRoutine would generate in the slow path section.
  // We simulate the same environment: RS in W1/D0 when needed and addr in W1 already
  // will be set by the caller-side before the branch to thunk.

  // Construct minimal masks for pushes; gprs/fprs sets empty for canonical thunk.
  BitSet32 gprs_to_push{};
  BitSet32 fprs_to_push{};
  EmitBackpatchRoutine(flags, MemAccessMode::AlwaysSlowAccess, ARM64Reg::W1, ARM64Reg::W1,
                       gprs_to_push, fprs_to_push, /*emitting_routine=*/emitting_routine);

  const u8* exit = GetCodePtr();
  if (!was_in_far)
    SwitchToNearCode();

  m_slow_thunk_cache.emplace(key, entry);
  return entry;
}

void JitArm64::DoBacktrace(uintptr_t access_address, SContext* ctx)
{
  for (int i = 0; i < 30; i += 2)
  {
    ERROR_LOG_FMT(DYNA_REC, "R{}: {:#018x}\tR{}: {:#018x}", i, ctx->CTX_REG(i), i + 1,
                  ctx->CTX_REG(i + 1));
  }

  ERROR_LOG_FMT(DYNA_REC, "R30: {:#018x}\tSP: {:#018x}", ctx->CTX_LR, ctx->CTX_SP);

  ERROR_LOG_FMT(DYNA_REC, "Access Address: {:#018x}", access_address);
  ERROR_LOG_FMT(DYNA_REC, "PC: {:#018x}", ctx->CTX_PC);

  ERROR_LOG_FMT(DYNA_REC, "Memory Around PC");

  std::string pc_memory;
  for (u64 pc = (ctx->CTX_PC - 32); pc < (ctx->CTX_PC + 32); pc += 16)
  {
    pc_memory += fmt::format("{:08x}{:08x}{:08x}{:08x}", Common::swap32(*(u32*)pc),
                             Common::swap32(*(u32*)(pc + 4)), Common::swap32(*(u32*)(pc + 8)),
                             Common::swap32(*(u32*)(pc + 12)));

    ERROR_LOG_FMT(DYNA_REC, "{:#018x}: {:08x} {:08x} {:08x} {:08x}", pc, *(u32*)pc, *(u32*)(pc + 4),
                  *(u32*)(pc + 8), *(u32*)(pc + 12));
  }

  ERROR_LOG_FMT(DYNA_REC, "Full block: {}", pc_memory);
}

void JitArm64::EmitBackpatchRoutine(u32 flags, MemAccessMode mode, ARM64Reg RS, ARM64Reg addr,
                                    BitSet32 gprs_to_push, BitSet32 fprs_to_push,
                                    bool emitting_routine)
{
  const u32 access_size = BackPatchInfo::GetFlagSize(flags);

  if (m_accurate_cpu_cache_enabled)
    mode = MemAccessMode::AlwaysSlowAccess;

  const bool emit_fast_access = mode != MemAccessMode::AlwaysSlowAccess;
  const bool emit_slow_access = mode != MemAccessMode::AlwaysFastAccess;

  bool in_far_code = false;
  const u8* fast_access_start = GetCodePtr();
  std::optional<FixupBranch> slow_access_fixup;

  if (emit_fast_access)
  {
    ARM64Reg memory_base = MEM_REG;
    ARM64Reg memory_offset = addr;

    if (!jo.fastmem)
    {
      const ARM64Reg temp = emitting_routine ? ARM64Reg::W3 : ARM64Reg::W30;

      memory_base = EncodeRegTo64(temp);
      memory_offset = ARM64Reg::W0;

      LSR(temp, addr, PowerPC::BAT_INDEX_SHIFT);
      LDR(memory_base, MEM_REG, ArithOption(temp, true));

      if (emit_slow_access)
      {
        FixupBranch pass = CBNZ(memory_base);
        slow_access_fixup = B();
        SetJumpTarget(pass);
      }

      AND(memory_offset, addr, LogicalImm(PowerPC::BAT_PAGE_SIZE - 1, GPRSize::B64));
    }
    else if (emit_slow_access && emitting_routine)
    {
      const ARM64Reg temp1 = flags & BackPatchInfo::FLAG_STORE ? ARM64Reg::W1 : ARM64Reg::W3;
      const ARM64Reg temp2 = ARM64Reg::W0;

      slow_access_fixup = CheckIfSafeAddress(addr, temp1, temp2);
    }

    if ((flags & BackPatchInfo::FLAG_STORE) && (flags & BackPatchInfo::FLAG_FLOAT))
    {
      ARM64Reg temp = ARM64Reg::D0;
      temp = ByteswapBeforeStore(this, &m_float_emit, temp, EncodeRegToDouble(RS), flags, true);

      m_float_emit.STR(access_size, temp, memory_base, memory_offset);
    }
    else if ((flags & BackPatchInfo::FLAG_LOAD) && (flags & BackPatchInfo::FLAG_FLOAT))
    {
      m_float_emit.LDR(access_size, EncodeRegToDouble(RS), memory_base, memory_offset);

      ByteswapAfterLoad(this, &m_float_emit, EncodeRegToDouble(RS), EncodeRegToDouble(RS), flags,
                        true, false);
    }
    else if (flags & BackPatchInfo::FLAG_STORE)
    {
      ARM64Reg temp = ARM64Reg::W1;
      temp = ByteswapBeforeStore(this, &m_float_emit, temp, RS, flags, true);

      if (flags & BackPatchInfo::FLAG_SIZE_32)
        STR(temp, memory_base, memory_offset);
      else if (flags & BackPatchInfo::FLAG_SIZE_16)
        STRH(temp, memory_base, memory_offset);
      else
        STRB(temp, memory_base, memory_offset);
    }
    else if (flags & BackPatchInfo::FLAG_ZERO_256)
    {
      // This literally only stores 32bytes of zeros to the target address
      ARM64Reg temp = ARM64Reg::X30;
      ADD(temp, memory_base, memory_offset);
      STP(IndexType::Signed, ARM64Reg::ZR, ARM64Reg::ZR, temp, 0);
      STP(IndexType::Signed, ARM64Reg::ZR, ARM64Reg::ZR, temp, 16);
    }
    else
    {
      if (flags & BackPatchInfo::FLAG_SIZE_32)
        LDR(RS, memory_base, memory_offset);
      else if (flags & BackPatchInfo::FLAG_SIZE_16)
        LDRH(RS, memory_base, memory_offset);
      else if (flags & BackPatchInfo::FLAG_SIZE_8)
        LDRB(RS, memory_base, memory_offset);

      ByteswapAfterLoad(this, &m_float_emit, RS, RS, flags, true, false);
    }
  }
  const u8* fast_access_end = GetCodePtr();

  if (emit_slow_access)
  {
    const bool memcheck = jo.memcheck && !emitting_routine;

    if (emit_fast_access)
    {
      in_far_code = true;
      SwitchToFarCode();

      if (jo.fastmem && !emitting_routine)
      {
        FastmemArea* fastmem_area = &m_fault_to_handler[fast_access_end];
        fastmem_area->fast_access_code = fast_access_start;
        // Instead of inlining a fresh slow path, branch to an interned thunk for this shape.
        const u8* thunk = GetOrCreateSlowPathThunk(flags, memcheck, /*emitting_routine=*/false);
        fastmem_area->slow_access_code = thunk;
      }
    }

    if (slow_access_fixup)
      SetJumpTarget(*slow_access_fixup);

    // Call the canonical slow-path thunk and then return to near code.
    const u8* thunk_call = GetOrCreateSlowPathThunk(flags, memcheck, /*emitting_routine=*/false);
    BL(thunk_call);
  }

  if (in_far_code)
  {
    if (slow_access_fixup)
    {
      FixupBranch done = B();
      SwitchToNearCode();
      SetJumpTarget(done);
    }
    else
    {
      RET(ARM64Reg::X30);
      SwitchToNearCode();
    }
  }
}

bool JitArm64::HandleFastmemFault(SContext* ctx)
{
  const u8* pc = reinterpret_cast<const u8*>(ctx->CTX_PC);
  auto slow_handler_iter = m_fault_to_handler.upper_bound(pc);

  // no fastmem area found
  if (slow_handler_iter == m_fault_to_handler.end())
    return false;

  const u8* fastmem_area_start = slow_handler_iter->second.fast_access_code;
  const u8* fastmem_area_end = slow_handler_iter->first;

  // no overlapping fastmem area found
  if (pc < fastmem_area_start)
    return false;

  const Common::ScopedJITPageWriteAndNoExecute enable_jit_page_writes(GetRegionPtr());
  ARM64XEmitter emitter(const_cast<u8*>(fastmem_area_start), const_cast<u8*>(fastmem_area_end));

  emitter.BL(slow_handler_iter->second.slow_access_code);

  while (emitter.GetCodePtr() < fastmem_area_end)
    emitter.NOP();

  m_fault_to_handler.erase(slow_handler_iter);

  emitter.FlushIcache();

  ctx->CTX_PC = reinterpret_cast<std::uintptr_t>(fastmem_area_start);
  return true;
}
