// Copyright 2014 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/CachedInterpreter/CachedInterpreter.h"

#include <span>
#include <iterator>
#include <sstream>
#include <bit>
#include <utility>
#include <cstring>
#include <algorithm>
#include <limits>

#include <fmt/format.h>
#include <fmt/ostream.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

#include "Common/CommonTypes.h"
#include "Common/GekkoDisassembler.h"
#include "Common/Logging/Log.h"
#include "Core/ConfigManager.h"
#include "Core/Core.h"
#include "Core/CoreTiming.h"
#include "Core/HLE/HLE.h"
#include "Core/HW/CPU.h"
#include "Core/Host.h"
#include "Core/PowerPC/Gekko.h"
#include "Core/PowerPC/Interpreter/Interpreter.h"
#include "Core/PowerPC/Jit64Common/Jit64Constants.h"
#include "Core/PowerPC/PPCAnalyst.h"
#include "Core/PowerPC/PowerPC.h"
#include "Core/System.h"
#include "Core/HW/Memmap.h"
#include "Common/Swap.h"
#include "Core/PowerPC/Interpreter/Interpreter_FPUtils.h"
#include "Core/Config/MainSettings.h"

#if defined(__clang__) || defined(__GNUC__)
#if defined(__aarch64__)
#define CI_HOT_FLATTEN [[gnu::hot, gnu::flatten]]
#define CI_HOT_ONLY [[gnu::hot]]
#define CI_COLD_ONLY [[gnu::cold]]
#else
#define CI_HOT_FLATTEN [[gnu::hot]]
#define CI_HOT_ONLY [[gnu::hot]]
#define CI_COLD_ONLY [[gnu::cold]]
#endif
#else
#define CI_HOT_FLATTEN
#define CI_HOT_ONLY
#define CI_COLD_ONLY
#endif

namespace {
struct CI_RegionInfo
{
  u8* base;
  u32 mask;
  u32 sub;
  bool is_fake;
};

static inline CI_RegionInfo CI_GetRegionInfo(u32 ea, bool dr, u8* mem1_base, u32 mem1_mask,
                                             u8* exram_base, u32 exram_mask, u8* fakevmem_base,
                                             u32 fakevmem_mask)
{
  CI_RegionInfo info{nullptr, 0, 0, false};
  if (ea >= Memory::MEM1_BASE_ADDR && ea - Memory::MEM1_BASE_ADDR <= mem1_mask)
  {
    info.base = mem1_base;
    info.mask = mem1_mask;
    info.sub = Memory::MEM1_BASE_ADDR;
    return info;
  }
  if (ea >= Memory::MEM2_BASE_ADDR && ea - Memory::MEM2_BASE_ADDR <= exram_mask)
  {
    info.base = exram_base;
    info.mask = exram_mask;
    info.sub = Memory::MEM2_BASE_ADDR;
    return info;
  }
  if (fakevmem_base && ((ea & 0xFE000000u) == 0x7E000000u))
  {
    info.base = fakevmem_base;
    info.mask = fakevmem_mask;
    info.sub = 0;
    info.is_fake = true;
    return info;
  }
  if (!dr && ea >= 0xC0000000u && ea - 0xC0000000u <= mem1_mask)
  {
    info.base = mem1_base;
    info.mask = mem1_mask;
    info.sub = 0xC0000000u;
    return info;
  }
  if (!dr && ea >= 0xD0000000u && ea - 0xD0000000u <= exram_mask)
  {
    info.base = exram_base;
    info.mask = exram_mask;
    info.sub = 0xD0000000u;
    return info;
  }
  return info;
}

static inline u32 CI_RegionOffset(const CI_RegionInfo& r, u32 ea)
{
  return r.is_fake ? (ea & r.mask) : ((ea - r.sub) & r.mask);
}
} // anonymous namespace

// PSQ fast-path helpers (mirror Interpreter_LoadStorePaired semantics)
static inline float CI_DequantizeFactor(u32 scale)
{
  // scale 0..31 => 1/(1<<scale), 32..63 => 1<<(64-scale)
  if (scale <= 31)
    return 1.0f / static_cast<float>(1u << scale);
  const u32 p = 64u - scale;
  return static_cast<float>(1ull << p);
}

static inline float CI_QuantizeFactor(u32 scale)
{
  // scale 0..31 => 1<<scale, 32..63 => 1/(1<<(64-scale))
  if (scale <= 31)
    return static_cast<float>(1u << scale);
  const u32 p = 64u - scale;
  return 1.0f / static_cast<float>(1ull << p);
}

template <typename SType>
static inline SType CI_ScaleAndClamp(double ps, u32 st_scale)
{
  const float conv = static_cast<float>(ps) * CI_QuantizeFactor(st_scale);
  constexpr float minv = static_cast<float>(std::numeric_limits<SType>::min());
  constexpr float maxv = static_cast<float>(std::numeric_limits<SType>::max());
  return static_cast<SType>(std::clamp(conv, minv, maxv));
}

// Local helper to update CR0, mirroring Interpreter::Helper_UpdateCR0, which is private.
static inline void CI_UpdateCR0(PowerPC::PowerPCState& ppc_state, u32 value)
{
  const s64 sign_extended = s64{s32(value)};
  u64 cr_val = u64(sign_extended);

  if (value == 0)
  {
    // Preserve GT semantics when setting SO on zero -> non-zero transition.
    cr_val |= 1ULL << 63;
  }

  cr_val = (cr_val & ~(1ULL << PowerPC::CR_EMU_SO_BIT)) |
           (u64{ppc_state.GetXER_SO()} << PowerPC::CR_EMU_SO_BIT);

  ppc_state.cr.fields[0] = cr_val;
}

// Local helper to write a CR field (CRFD), mirroring Helper_IntCompare SO behavior.
static inline void CI_WriteCRField(PowerPC::PowerPCState& ppc_state, u32 crfd, u32 cr_field)
{
  if (ppc_state.GetXER_SO())
    cr_field |= PowerPC::CR_SO;
  ppc_state.cr.SetField(crfd, cr_field);
}

// Carry/overflow helpers matching Interpreter semantics
static inline bool CI_Helper_Carry(u32 value1, u32 value2)
{
  return value2 > (~value1);
}

static inline bool CI_HasAddOverflowed(u32 x, u32 y, u32 result)
{
  // If x and y have the same sign, but the result is different then an overflow has occurred.
  return (((x ^ result) & (y ^ result)) >> 31) != 0;
}

CachedInterpreter::CachedInterpreter(Core::System& system) : JitBase(system), m_block_cache(*this)
{
}

template <bool write_pc>
CI_HOT_FLATTEN s32 CachedInterpreter::LoadStoreDFormPIC(PowerPC::PowerPCState& ppc_state,
                                                        const LoadStoreDFormPICOperands& operands)
{
  const auto& [interpreter, func, current_pc, inst, power_pc, mem1_base, mem1_mask, exram_base,
               exram_mask, fakevmem_base, fakevmem_mask] = operands;

  // Always set PC/NPC like other callbacks: write_pc variant is selected at emission time.
  // We mirror Interpret<write_pc> behavior by writing both; NPC will be updated by branch logic.
  if constexpr (write_pc)
  {
    ppc_state.pc = current_pc;
    ppc_state.npc = current_pc + 4;
  }

  // Decode effective address for D-form: ea = (RA ? GPR[RA] : 0) + SIMM_16
  const u32 ra = inst.RA;
  const u32 ea = ra ? (ppc_state.gpr[ra] + static_cast<u32>(inst.SIMM_16))
                    : static_cast<u32>(inst.SIMM_16);

  // Compute direct pointer if EA lies in MEM1 or EXRAM logical regions
  u8* __restrict base_ptr = nullptr;
  u32 offset = 0;
  const auto region = CI_GetRegionInfo(ea, ppc_state.msr.DR, mem1_base, mem1_mask, exram_base,
                                       exram_mask, fakevmem_base, fakevmem_mask);
  if (region.base)
  {
    base_ptr = region.base;
    offset = CI_RegionOffset(region, ea);
  }

  if (base_ptr) [[likely]]
  {
    // offset already computed as (ea - base) & mask above; do not recompute with (ea & mask)
    // which would be incorrect for EXRAM and MEM1 logical addresses.
    // Handle D-form by primary opcode, X-form by SUBOP10 under OPCD=31
    switch (inst.OPCD)
    {
    case 32: // lwz
    {
      if ((ea & 0b11) != 0) [[unlikely]]
        break; // misaligned -> fallback
      const u32 raw = *reinterpret_cast<const u32*>(base_ptr + offset);
      const u32 val = Common::FromBigEndian(raw);
      ppc_state.gpr[inst.RD] = val;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 33: // lwzu (update)
    {
      if (ra == 0 || (ea & 0b11) != 0) [[unlikely]]
        break; // illegal or misaligned -> fallback
      const u32 raw = *reinterpret_cast<const u32*>(base_ptr + offset);
      const u32 val = Common::FromBigEndian(raw);
      ppc_state.gpr[inst.RD] = val;
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 34: // lbz
    {
      const u8 val = *(base_ptr + offset);
      ppc_state.gpr[inst.RD] = static_cast<u32>(val);
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 35: // lbzu (update)
    {
      if (ra == 0)
        break; // illegal -> fallback
      const u8 val = *(base_ptr + offset);
      ppc_state.gpr[inst.RD] = static_cast<u32>(val);
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 40: // lhz
    {
      if ((ea & 0b1) != 0) [[unlikely]]
        break; // misaligned -> fallback
      const u16 raw = *reinterpret_cast<const u16*>(base_ptr + offset);
      const u16 val = Common::FromBigEndian(raw);
      ppc_state.gpr[inst.RD] = static_cast<u32>(val);
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 41: // lhzu (update)
    {
      if (ra == 0 || (ea & 0b1) != 0) [[unlikely]]
        break; // illegal or misaligned -> fallback
      const u16 raw = *reinterpret_cast<const u16*>(base_ptr + offset);
      const u16 val = Common::FromBigEndian(raw);
      ppc_state.gpr[inst.RD] = static_cast<u32>(val);
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 42: // lha
    {
      if ((ea & 0b1) != 0) [[unlikely]]
        break; // misaligned -> fallback
      const u16 raw = *reinterpret_cast<const u16*>(base_ptr + offset);
      const u16 be = Common::FromBigEndian(raw);
      ppc_state.gpr[inst.RD] = static_cast<u32>(static_cast<s16>(be));
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 43: // lhau (update)
    {
      if (ra == 0 || (ea & 0b1) != 0) [[unlikely]]
        break; // illegal or misaligned -> fallback
      const u16 raw = *reinterpret_cast<const u16*>(base_ptr + offset);
      const u16 be = Common::FromBigEndian(raw);
      ppc_state.gpr[inst.RD] = static_cast<u32>(static_cast<s16>(be));
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 36: // stw
    {
      if ((ea & 0b11) != 0) [[unlikely]]
        break; // misaligned -> fallback
      const u32 val = ppc_state.gpr[inst.RS];
      const u32 raw = Common::swap32(val);
      *reinterpret_cast<u32*>(base_ptr + offset) = raw;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 37: // stwu (update)
    {
      if (ra == 0 || (ea & 0b11) != 0) [[unlikely]]
        break; // illegal or misaligned -> fallback
      const u32 val = ppc_state.gpr[inst.RS];
      const u32 raw = Common::swap32(val);
      *reinterpret_cast<u32*>(base_ptr + offset) = raw;
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 38: // stb
    {
      const u8 val = static_cast<u8>(ppc_state.gpr[inst.RS]);
      *(base_ptr + offset) = val;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 39: // stbu (update)
    {
      if (ra == 0)
        break; // illegal -> fallback
      const u8 val = static_cast<u8>(ppc_state.gpr[inst.RS]);
      *(base_ptr + offset) = val;
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 44: // sth
    {
      if ((ea & 0b1) != 0) [[unlikely]]
        break; // misaligned -> fallback
      const u16 val = static_cast<u16>(ppc_state.gpr[inst.RS]);
      const u16 raw = Common::swap16(val);
      *reinterpret_cast<u16*>(base_ptr + offset) = raw;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 45: // sthu (update)
    {
      if (ra == 0 || (ea & 0b1) != 0) [[unlikely]]
        break; // illegal or misaligned -> fallback
      const u16 val = static_cast<u16>(ppc_state.gpr[inst.RS]);
      const u16 raw = Common::swap16(val);
      *reinterpret_cast<u16*>(base_ptr + offset) = raw;
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }

    // Floating-point single-precision loads/stores (D-form)
    case 48: // lfs
    {
      if ((ea & 0b11) != 0) [[unlikely]]
        break; // misaligned -> fallback
      const u32 raw = *reinterpret_cast<const u32*>(base_ptr + offset);
      const u32 be = Common::FromBigEndian(raw);
      const u64 value = ConvertToDouble(be);
      ppc_state.ps[inst.FD].Fill(value);
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 49: // lfsu (update)
    {
      if (ra == 0 || (ea & 0b11) != 0) [[unlikely]]
        break; // illegal or misaligned -> fallback
      const u32 raw = *reinterpret_cast<const u32*>(base_ptr + offset);
      const u32 be = Common::FromBigEndian(raw);
      const u64 value = ConvertToDouble(be);
      ppc_state.ps[inst.FD].Fill(value);
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }

    // Floating-point double-precision loads (D-form)
    case 50: // lfd
    {
      if ((ea & 0b11) != 0) [[unlikely]]
        break; // misaligned -> fallback
      u64 raw64;
      std::memcpy(&raw64, base_ptr + offset, sizeof(raw64));
      const u64 be64 = Common::FromBigEndian(raw64);
      ppc_state.ps[inst.FD].SetPS0(be64);
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 51: // lfdu (update)
    {
      if (ra == 0 || (ea & 0b11) != 0) [[unlikely]]
        break; // illegal or misaligned -> fallback
      u64 raw64;
      std::memcpy(&raw64, base_ptr + offset, sizeof(raw64));
      const u64 be64 = Common::FromBigEndian(raw64);
      ppc_state.ps[inst.FD].SetPS0(be64);
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }

    // Floating-point single-precision stores (D-form)
    case 52: // stfs
    {
      if ((ea & 0b11) != 0) [[unlikely]]
        break; // misaligned -> fallback
      const u32 conv = ConvertToSingle(ppc_state.ps[inst.FS].PS0AsU64());
      const u32 raw_out = Common::swap32(conv);
      *reinterpret_cast<u32*>(base_ptr + offset) = raw_out;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 53: // stfsu (update)
    {
      if (ra == 0 || (ea & 0b11) != 0) [[unlikely]]
        break; // illegal or misaligned -> fallback
      const u32 conv = ConvertToSingle(ppc_state.ps[inst.FS].PS0AsU64());
      const u32 raw_out = Common::swap32(conv);
      *reinterpret_cast<u32*>(base_ptr + offset) = raw_out;
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }

    // Floating-point double-precision stores (D-form)
    case 54: // stfd
    {
      if ((ea & 0b11) != 0) [[unlikely]]
        break; // misaligned -> fallback
      const u64 val64 = ppc_state.ps[inst.FS].PS0AsU64();
      const u64 raw64 = Common::swap64(val64);
      std::memcpy(base_ptr + offset, &raw64, sizeof(raw64));
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 55: // stfdu (update)
    {
      if (ra == 0 || (ea & 0b11) != 0) [[unlikely]]
        break; // illegal or misaligned -> fallback
      const u64 val64 = ppc_state.ps[inst.FS].PS0AsU64();
      const u64 raw64 = Common::swap64(val64);
      std::memcpy(base_ptr + offset, &raw64, sizeof(raw64));
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 46: // lmw
    {
      if ((ea & 0b11) != 0 || ppc_state.msr.LE) [[unlikely]]
        break; // misaligned or LE -> fallback
      const u32 count = 32u - static_cast<u32>(inst.RD);
      // Pre-scan to ensure the entire range lies in a single fast region
      u8* region_base = nullptr;
      u32 region_mask = 0;
      u32 region_sub = 0;
      bool region_is_fake = false;
      bool ok = true;
      u32 addr = ea;
      for (u32 k = 0; k < count; ++k, addr += 4)
      {
        const auto r = CI_GetRegionInfo(addr, ppc_state.msr.DR, mem1_base, mem1_mask, exram_base,
                                        exram_mask, fakevmem_base, fakevmem_mask);
        if (!r.base) { ok = false; break; }
        if (!region_base)
        {
          region_base = r.base;
          region_mask = r.mask;
          region_sub = r.sub;
          region_is_fake = r.is_fake;
        }
        else if (region_base != r.base || region_mask != r.mask || region_sub != r.sub ||
                 region_is_fake != r.is_fake)
        {
          ok = false; break;
        }
      }
      if (!ok || !region_base)
        break; // fallback
      // Load all words
      addr = ea;

#if defined(__aarch64__)
      // Vectorized load of up to 4 regs per iteration with endian swap
      for (u32 r = static_cast<u32>(inst.RD); r <= 31u; )
      {
        const u32 remaining = 32u - r;
        if (remaining >= 4)
        {
          const u32 roff0 = region_is_fake ? (addr & region_mask)
                                           : ((addr - region_sub) & region_mask);
          const u8* p0 = region_base + roff0;
          uint8x16_t vb = vld1q_u8(reinterpret_cast<const uint8_t*>(p0));
          vb = vrev32q_u8(vb);
          uint32x4_t v = vreinterpretq_u32_u8(vb);
          vst1q_u32(reinterpret_cast<uint32_t*>(&ppc_state.gpr[r]), v);
          r += 4;
          addr += 16;
          continue;
        }
        const u32 roff = region_is_fake ? (addr & region_mask)
                                        : ((addr - region_sub) & region_mask);
        const u32 raw = *reinterpret_cast<const u32*>(region_base + roff);
        ppc_state.gpr[r++] = Common::FromBigEndian(raw);
        addr += 4;
      }
#else
      for (u32 r = static_cast<u32>(inst.RD); r <= 31u; ++r, addr += 4)
      {
        const u32 roff = region_is_fake ? (addr & region_mask)
                                        : ((addr - region_sub) & region_mask);
        const u32 raw = *reinterpret_cast<const u32*>(region_base + roff);
        ppc_state.gpr[r] = Common::FromBigEndian(raw);
      }
#endif
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 47: // stmw
    {
      if ((ea & 0b11) != 0 || ppc_state.msr.LE) [[unlikely]]
        break; // misaligned or LE -> fallback
      const u32 count = 32u - static_cast<u32>(inst.RS);
      // Pre-scan to ensure the entire range lies in a single fast region
      u8* region_base = nullptr;
      u32 region_mask = 0;
      u32 region_sub = 0;
      bool region_is_fake = false;
      bool ok = true;
      u32 addr = ea;
      for (u32 k = 0; k < count; ++k, addr += 4)
      {
        const auto r = CI_GetRegionInfo(addr, ppc_state.msr.DR, mem1_base, mem1_mask, exram_base,
                                        exram_mask, fakevmem_base, fakevmem_mask);
        if (!r.base) { ok = false; break; }
        if (!region_base)
        {
          region_base = r.base;
          region_mask = r.mask;
          region_sub = r.sub;
          region_is_fake = r.is_fake;
        }
        else if (region_base != r.base || region_mask != r.mask || region_sub != r.sub ||
                 region_is_fake != r.is_fake)
        {
          ok = false; break;
        }
      }
      if (!ok || !region_base)
        break; // fallback
      // Store all words
      addr = ea;
#if defined(__aarch64__)
      {
        const u32 roff_prefetch = region_is_fake ? (addr & region_mask)
                                                 : ((addr - region_sub) & region_mask);
        __builtin_prefetch(region_base + roff_prefetch + 64, 1, 1);
      }
#endif
#if defined(__aarch64__)
      // Vectorized store of up to 4 regs per iteration with endian swap
      for (u32 r = static_cast<u32>(inst.RS); r <= 31u; )
      {
        const u32 remaining = 32u - r;
        if (remaining >= 4)
        {
          const u32 roff0 = region_is_fake ? (addr & region_mask)
                                           : ((addr - region_sub) & region_mask);
          u8* p0 = region_base + roff0;
          uint32x4_t v = vld1q_u32(reinterpret_cast<const uint32_t*>(&ppc_state.gpr[r]));
          uint8x16_t vb = vreinterpretq_u8_u32(v);
          vb = vrev32q_u8(vb);
          vst1q_u8(reinterpret_cast<uint8_t*>(p0), vb);
          r += 4;
          addr += 16;
          continue;
        }
        const u32 roff = region_is_fake ? (addr & region_mask)
                                        : ((addr - region_sub) & region_mask);
        const u32 raw = Common::swap32(ppc_state.gpr[r++]);
        *reinterpret_cast<u32*>(region_base + roff) = raw;
        addr += 4;
      }
#else
      for (u32 r = static_cast<u32>(inst.RS); r <= 31u; ++r, addr += 4)
      {
        const u32 roff = region_is_fake ? (addr & region_mask)
                                        : ((addr - region_sub) & region_mask);
        const u32 raw = Common::swap32(ppc_state.gpr[r]);
        *reinterpret_cast<u32*>(region_base + roff) = raw;
      }
#endif
      return sizeof(AnyCallback) + sizeof(operands);
    }
    }
  }
  // Slow path or unsupported opcodes: delegate to interpreter implementation.
  return Cold_LoadStoreFallback(ppc_state, operands);
}

template <bool write_pc>
CI_HOT_FLATTEN s32 CachedInterpreter::LoadStoreXFormPIC(PowerPC::PowerPCState& ppc_state,
                                                        const LoadStoreDFormPICOperands& operands)
{
  const auto& [interpreter, func, current_pc, inst, power_pc, mem1_base, mem1_mask, exram_base,
               exram_mask, fakevmem_base, fakevmem_mask] = operands;

  if constexpr (write_pc)
  {
    ppc_state.pc = current_pc;
    ppc_state.npc = current_pc + 4;
  }

  // X-form EA: ea = (RA ? GPR[RA] : 0) + GPR[RB]
  const u32 ra = inst.RA;
  const u32 rb = inst.RB;
  const u32 ea = (ra ? ppc_state.gpr[ra] : 0) + ppc_state.gpr[rb];

  // Region decode
  u8* __restrict base_ptr = nullptr;
  u32 offset = 0;
  const auto region = CI_GetRegionInfo(ea, ppc_state.msr.DR, mem1_base, mem1_mask, exram_base,
                                       exram_mask, fakevmem_base, fakevmem_mask);
  if (region.base)
  {
    base_ptr = region.base;
    offset = CI_RegionOffset(region, ea);
  }

  if (base_ptr) [[likely]]
  {
    switch (inst.SUBOP10)
    {
    // Loads (indexed)
    case 23: // lwzx
    case 55: // lwzux (update)
    {
      const bool update = (inst.SUBOP10 == 55);
      if ((ea & 0b11) != 0 || (update && ra == 0)) [[unlikely]]
        break; // misaligned or illegal
      const u32 raw = *reinterpret_cast<const u32*>(base_ptr + offset);
      const u32 val = Common::FromBigEndian(raw);
      ppc_state.gpr[inst.RD] = val;
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 87:  // lbzx
    case 119: // lbzux (update)
    {
      const bool update = (inst.SUBOP10 == 119);
      if (update && ra == 0)
        break; // illegal
      const u8 val = *(base_ptr + offset);
      ppc_state.gpr[inst.RD] = static_cast<u32>(val);
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 279: // lhzx
    case 311: // lhzux (update)
    {
      const bool update = (inst.SUBOP10 == 311);
      if ((ea & 0b1) != 0 || (update && ra == 0)) [[unlikely]]
        break; // misaligned or illegal
      const u16 raw = *reinterpret_cast<const u16*>(base_ptr + offset);
      const u16 val = Common::FromBigEndian(raw);
      ppc_state.gpr[inst.RD] = static_cast<u32>(val);
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 343: // lhax
    case 375: // lhaux (update)
    {
      const bool update = (inst.SUBOP10 == 375);
      if ((ea & 0b1) != 0 || (update && ra == 0)) [[unlikely]]
        break; // misaligned or illegal
      const u16 raw = *reinterpret_cast<const u16*>(base_ptr + offset);
      const u16 be = Common::FromBigEndian(raw);
      ppc_state.gpr[inst.RD] = static_cast<u32>(static_cast<s16>(be));
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }

    // Floating-point single-precision loads/stores (indexed)
    case 535: // lfsx
    case 567: // lfsux (update)
    {
      const bool update = (inst.SUBOP10 == 567);
      if ((ea & 0b11) != 0 || (update && ra == 0)) [[unlikely]]
        break; // misaligned or illegal
      const u32 raw = *reinterpret_cast<const u32*>(base_ptr + offset);
      const u32 be = Common::FromBigEndian(raw);
      const u64 value = ConvertToDouble(be);
      ppc_state.ps[inst.FD].Fill(value);
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }

    // Double-precision floating-point loads (indexed)
    case 599: // lfdx
    case 631: // lfdux (update)
    {
      const bool update = (inst.SUBOP10 == 631);
      if ((ea & 0b11) != 0 || (update && ra == 0)) [[unlikely]]
        break; // misaligned or illegal
      u64 raw64;
      std::memcpy(&raw64, base_ptr + offset, sizeof(raw64));
      const u64 be64 = Common::FromBigEndian(raw64);
      ppc_state.ps[inst.FD].SetPS0(be64);
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }

    case 663: // stfsx
    case 695: // stfsux (update)
    {
      const bool update = (inst.SUBOP10 == 695);
      if ((ea & 0b11) != 0 || (update && ra == 0)) [[unlikely]]
        break; // misaligned or illegal
      const u32 conv = ConvertToSingle(ppc_state.ps[inst.FS].PS0AsU64());
      const u32 raw = Common::swap32(conv);
      *reinterpret_cast<u32*>(base_ptr + offset) = raw;
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }

    // Double-precision floating-point stores (indexed)
    case 727: // stfdx
    case 759: // stfdux (update)
    {
      const bool update = (inst.SUBOP10 == 759);
      if ((ea & 0b11) != 0 || (update && ra == 0)) [[unlikely]]
        break; // misaligned or illegal
      const u64 val = ppc_state.ps[inst.FS].PS0AsU64();
      const u64 raw = Common::swap64(val);
      std::memcpy(base_ptr + offset, &raw, sizeof(raw));
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 983: // stfiwx
    {
      if ((ea & 0b11) != 0) [[unlikely]]
        break; // misaligned
      const u32 val = ppc_state.ps[inst.FS].PS0AsU32();
      const u32 raw = Common::swap32(val);
      *reinterpret_cast<u32*>(base_ptr + offset) = raw;
      return sizeof(AnyCallback) + sizeof(operands);
    }

    // Stores (indexed)
    case 151: // stwx
    case 183: // stwux (update)
    {
      const bool update = (inst.SUBOP10 == 183);
      if ((ea & 0b11) != 0 || (update && ra == 0)) [[unlikely]]
        break; // misaligned or illegal
      const u32 val = ppc_state.gpr[inst.RS];
      const u32 raw = Common::swap32(val);
      *reinterpret_cast<u32*>(base_ptr + offset) = raw;
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 215: // stbx
    case 247: // stbux (update)
    {
      const bool update = (inst.SUBOP10 == 247);
      if (update && ra == 0)
        break; // illegal
      const u8 val = static_cast<u8>(ppc_state.gpr[inst.RS]);
      *(base_ptr + offset) = val;
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 407: // sthx
    case 439: // sthux (update)
    {
      const bool update = (inst.SUBOP10 == 439);
      if ((ea & 0b1) != 0 || (update && ra == 0)) [[unlikely]]
        break; // misaligned or illegal
      const u16 val = static_cast<u16>(ppc_state.gpr[inst.RS]);
      const u16 raw = Common::swap16(val);
      *reinterpret_cast<u16*>(base_ptr + offset) = raw;
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }

    // Byte-reverse indexed variants
    case 534: // lwbrx
    {
      if ((ea & 0b11) != 0) [[unlikely]]
        break; // misaligned
      const u32 raw = *reinterpret_cast<const u32*>(base_ptr + offset);
      const u32 val = Common::swap32(Common::FromBigEndian(raw));
      ppc_state.gpr[inst.RD] = val;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 790: // lhbrx
    {
      if ((ea & 0b1) != 0) [[unlikely]]
        break; // misaligned
      const u16 raw = *reinterpret_cast<const u16*>(base_ptr + offset);
      const u16 val = Common::swap16(Common::FromBigEndian(raw));
      ppc_state.gpr[inst.RD] = static_cast<u32>(val);
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 662: // stwbrx
    {
      if ((ea & 0b11) != 0)
        break; // misaligned
      const u32 raw = ppc_state.gpr[inst.RS];
      std::memcpy(base_ptr + offset, &raw, sizeof(raw));
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 918: // sthbrx
    {
      if ((ea & 0b1) != 0)
        break; // misaligned
      const u16 raw = static_cast<u16>(ppc_state.gpr[inst.RS]);
      std::memcpy(base_ptr + offset, &raw, sizeof(raw));
      return sizeof(AnyCallback) + sizeof(operands);
    }

    // Paired-single quantized loads/stores (indexed)
    case 6:   // psq_lx
    case 38:  // psq_lux (update)
    {
      const bool update = (inst.SUBOP10 == 38);
      const u32 idx = inst.Ix;
      const u32 w = inst.Wx; // 1 = single element, 0 = pair
      if ((update && ra == 0))
        break; // illegal update form
      const UGQR gqr(ppc_state.spr[SPR_GQR0 + idx]);
      const EQuantizeType ld_type = gqr.ld_type;
      const u32 ld_scale = gqr.ld_scale;

      double ps0 = 0.0;
      double ps1 = 0.0;

      switch (ld_type)
      {
      case QUANTIZE_FLOAT:
        if (w != 0)
        {
          u32 raw;
          std::memcpy(&raw, base_ptr + offset, sizeof(raw));
          const u32 be = Common::FromBigEndian(raw);
          ps0 = std::bit_cast<double>(ConvertToDouble(be));
          ps1 = 1.0;
        }
        else
        {
          u64 raw;
          std::memcpy(&raw, base_ptr + offset, sizeof(raw));
          const u64 be64 = Common::FromBigEndian(raw);
          const u32 first = static_cast<u32>(be64 >> 32);
          const u32 second = static_cast<u32>(be64);
          ps0 = std::bit_cast<double>(ConvertToDouble(first));
          ps1 = std::bit_cast<double>(ConvertToDouble(second));
        }
        break;

      case QUANTIZE_U8:
      case QUANTIZE_S8:
      case QUANTIZE_U16:
      case QUANTIZE_S16:
      {
        const float factor = CI_DequantizeFactor(ld_scale);
        if (w != 0)
        {
          if (ld_type == QUANTIZE_U8 || ld_type == QUANTIZE_S8)
          {
            const u8 val = *(base_ptr + offset);
            ps0 = static_cast<double>(ld_type == QUANTIZE_S8 ? static_cast<s8>(val)
                                                              : static_cast<u8>(val)) *
                  factor;
          }
          else
          {
            u16 raw16;
            std::memcpy(&raw16, base_ptr + offset, sizeof(raw16));
            const u16 be16 = Common::FromBigEndian(raw16);
            ps0 = static_cast<double>(ld_type == QUANTIZE_S16 ? static_cast<s16>(be16)
                                                              : static_cast<u16>(be16)) *
                  factor;
          }
          ps1 = 1.0;
        }
        else
        {
          if (ld_type == QUANTIZE_U8 || ld_type == QUANTIZE_S8)
          {
            u16 raw16;
            std::memcpy(&raw16, base_ptr + offset, sizeof(raw16));
            const u16 be16 = Common::FromBigEndian(raw16);
            const u8 first = static_cast<u8>(be16 >> 8);
            const u8 second = static_cast<u8>(be16);
            ps0 = static_cast<double>(ld_type == QUANTIZE_S8 ? static_cast<s8>(first)
                                                              : static_cast<u8>(first)) *
                  factor;
            ps1 = static_cast<double>(ld_type == QUANTIZE_S8 ? static_cast<s8>(second)
                                                              : static_cast<u8>(second)) *
                  factor;
          }
          else
          {
            u32 raw32;
            std::memcpy(&raw32, base_ptr + offset, sizeof(raw32));
            const u32 be32 = Common::FromBigEndian(raw32);
            const u16 first = static_cast<u16>(be32 >> 16);
            const u16 second = static_cast<u16>(be32);
            ps0 = static_cast<double>(ld_type == QUANTIZE_S16 ? static_cast<s16>(first)
                                                              : static_cast<u16>(first)) *
                  factor;
            ps1 = static_cast<double>(ld_type == QUANTIZE_S16 ? static_cast<s16>(second)
                                                              : static_cast<u16>(second)) *
                  factor;
          }
        }
        break;
      }

      default:
        // Invalid types fall back
        break;
      }

      if (ld_type != QUANTIZE_FLOAT && ld_type != QUANTIZE_U8 && ld_type != QUANTIZE_S8 &&
          ld_type != QUANTIZE_U16 && ld_type != QUANTIZE_S16)
      {
        break; // fallback to cold path
      }

      ppc_state.ps[inst.RD].SetBoth(ps0, ps1);
      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }

    case 7:   // psq_stx
    case 39:  // psq_stux (update)
    {
      const bool update = (inst.SUBOP10 == 39);
      const u32 idx = inst.Ix;
      const u32 w = inst.Wx;
      if ((update && ra == 0))
        break; // illegal update form
      const UGQR gqr(ppc_state.spr[SPR_GQR0 + idx]);
      const EQuantizeType st_type = gqr.st_type;
      const u32 st_scale = gqr.st_scale;

      const double ps0 = ppc_state.ps[inst.RS].PS0AsDouble();
      const double ps1 = ppc_state.ps[inst.RS].PS1AsDouble();

      switch (st_type)
      {
      case QUANTIZE_FLOAT:
      {
        const u64 q0 = std::bit_cast<u64>(ps0);
        const u32 s0 = ConvertToSingleFTZ(q0);
        if (w != 0)
        {
          const u32 raw = Common::swap32(s0);
          std::memcpy(base_ptr + offset, &raw, sizeof(raw));
        }
        else
        {
          const u32 s1 = ConvertToSingleFTZ(std::bit_cast<u64>(ps1));
          const u64 be64 = (static_cast<u64>(s0) << 32) | static_cast<u64>(s1);
          const u64 raw = Common::swap64(be64);
          std::memcpy(base_ptr + offset, &raw, sizeof(raw));
        }
        break;
      }

      case QUANTIZE_U8:
      case QUANTIZE_S8:
      case QUANTIZE_U16:
      case QUANTIZE_S16:
      {
        if (w != 0)
        {
          if (st_type == QUANTIZE_U8 || st_type == QUANTIZE_S8)
          {
            u8 v0;
            if (st_type == QUANTIZE_S8)
              v0 = static_cast<u8>(CI_ScaleAndClamp<s8>(ps0, st_scale));
            else
              v0 = CI_ScaleAndClamp<u8>(ps0, st_scale);
            *(base_ptr + offset) = v0;
          }
          else
          {
            u16 v0;
            if (st_type == QUANTIZE_S16)
              v0 = static_cast<u16>(CI_ScaleAndClamp<s16>(ps0, st_scale));
            else
              v0 = CI_ScaleAndClamp<u16>(ps0, st_scale);
            const u16 raw16 = Common::swap16(v0);
            std::memcpy(base_ptr + offset, &raw16, sizeof(raw16));
          }
        }
        else
        {
          if (st_type == QUANTIZE_U8 || st_type == QUANTIZE_S8)
          {
            u8 v0;
            u8 v1;
            if (st_type == QUANTIZE_S8)
            {
              v0 = static_cast<u8>(CI_ScaleAndClamp<s8>(ps0, st_scale));
              v1 = static_cast<u8>(CI_ScaleAndClamp<s8>(ps1, st_scale));
            }
            else
            {
              v0 = CI_ScaleAndClamp<u8>(ps0, st_scale);
              v1 = CI_ScaleAndClamp<u8>(ps1, st_scale);
            }
            const u16 be16 = static_cast<u16>((u16(v0) << 8) | u16(v1));
            const u16 raw16 = Common::swap16(be16);
            std::memcpy(base_ptr + offset, &raw16, sizeof(raw16));
          }
          else
          {
            u16 v0;
            u16 v1;
            if (st_type == QUANTIZE_S16)
            {
              v0 = static_cast<u16>(CI_ScaleAndClamp<s16>(ps0, st_scale));
              v1 = static_cast<u16>(CI_ScaleAndClamp<s16>(ps1, st_scale));
            }
            else
            {
              v0 = CI_ScaleAndClamp<u16>(ps0, st_scale);
              v1 = CI_ScaleAndClamp<u16>(ps1, st_scale);
            }
            const u32 be32 = (static_cast<u32>(v0) << 16) | static_cast<u32>(v1);
            const u32 raw32 = Common::swap32(be32);
            std::memcpy(base_ptr + offset, &raw32, sizeof(raw32));
          }
        }
        break;
      }

      default:
        break;
      }

      if (st_type != QUANTIZE_FLOAT && st_type != QUANTIZE_U8 && st_type != QUANTIZE_S8 &&
          st_type != QUANTIZE_U16 && st_type != QUANTIZE_S16)
      {
        break; // fallback
      }

      if (update)
        ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }

    default:
      break; // unsupported X-form in PIC
    }
  }

  return Cold_LoadStoreFallback(ppc_state, operands);
}

template <bool write_pc>
s32 CachedInterpreter::LoadStoreXFormPIC(std::ostream& stream,
                                         const LoadStoreDFormPICOperands& operands)
{
  fmt::print(stream, "PIC X-Form LS at PC={:#010x}, SUBOP10={}\n", operands.current_pc,
             operands.inst.SUBOP10);
  return sizeof(AnyCallback) + sizeof(operands);
}

[[gnu::noinline]] CI_COLD_ONLY
s32 CachedInterpreter::Cold_LoadStoreFallback(PowerPC::PowerPCState& /*ppc_state*/,
                                              const LoadStoreDFormPICOperands& operands)
{
  const auto& [interpreter, func, current_pc, inst, power_pc, mem1_base, mem1_mask, exram_base,
               exram_mask, fakevmem_base, fakevmem_mask] = operands;
  (void)current_pc;
  (void)power_pc;
  (void)mem1_base;
  (void)mem1_mask;
  (void)exram_base;
  (void)exram_mask;
  (void)fakevmem_base;
  (void)fakevmem_mask;
  func(interpreter, inst);
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
s32 CachedInterpreter::LoadStoreDFormPIC(std::ostream& stream,
                                         const LoadStoreDFormPICOperands& operands)
{
  fmt::print(stream, "PIC D-Form LS at PC={:#010x}, OPCD={}\n", operands.current_pc,
             operands.inst.OPCD);
  return sizeof(AnyCallback) + sizeof(operands);
}

CachedInterpreter::~CachedInterpreter() = default;

void CachedInterpreter::Init()
{
  RefreshConfig();

  AllocCodeSpace(CODE_SIZE);
  ResetFreeMemoryRanges();

  // Enable block linking on ARM64 to reduce dispatch overhead.
  // Safe on iOS/tvOS and provides measurable speedups.
  #if defined(__aarch64__)
  jo.enableBlocklink = true;
  #else
  jo.enableBlocklink = false;
  #endif

  m_block_cache.Init();

  code_block.m_stats = &js.st;
  code_block.m_gpa = &js.gpa;
  code_block.m_fpa = &js.fpa;
}

template <bool write_pc>
CI_HOT_ONLY static inline void CI_SetPCForMicroOps(PowerPC::PowerPCState& ppc_state, u32 pc)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = pc;
    ppc_state.npc = pc + 4;
  }
}

template <bool write_pc>
CI_HOT_FLATTEN s32 CachedInterpreter::ExecuteMicroOps(PowerPC::PowerPCState& ppc_state,
                                                       const ExecuteMicroOpsOperands& operands)
{
  CI_SetPCForMicroOps<write_pc>(ppc_state, operands.current_pc);

  const u32 count = operands.count;
  const MicroOp* ops = operands.ops;
#if defined(__GNUC__) || defined(__clang__)
  {
    u32 i = 0;
    if (i >= count)
      goto micro_done;

    // The order here MUST match enum class MicroOpCode in CachedInterpreter.h
    static const void* dispatch_table[] = {
        &&op_CONST32,       // 0 MicroOpCode::CONST32
        &&op_CONST32_ADDRA, // 1 MicroOpCode::CONST32_ADDRA
        &&op_ADDI,          // 2 MicroOpCode::ADDI
        &&op_ADDIS,         // 3 MicroOpCode::ADDIS
        &&op_ORI,           // 4 MicroOpCode::ORI
        &&op_ORIS,          // 5 MicroOpCode::ORIS
        &&op_XORI,          // 6 MicroOpCode::XORI
        &&op_XORIS,         // 7 MicroOpCode::XORIS
        &&op_ANDI,          // 8 MicroOpCode::ANDI
        &&op_ANDIS,         // 9 MicroOpCode::ANDIS
        &&op_RLWINM_IMM,    // 10 MicroOpCode::RLWINM_IMM
        &&op_AND_RR,        // 11 MicroOpCode::AND_RR
        &&op_OR_RR,         // 12 MicroOpCode::OR_RR
        &&op_XOR_RR,        // 13 MicroOpCode::XOR_RR
        &&op_RLWIMI_IMM,    // 14 MicroOpCode::RLWIMI_IMM
        &&op_RLWNM_VAR,     // 15 MicroOpCode::RLWNM_VAR
        &&op_ANDC_RR,       // 16 MicroOpCode::ANDC_RR
        &&op_ORC_RR,        // 17 MicroOpCode::ORC_RR
        &&op_NAND_RR,       // 18 MicroOpCode::NAND_RR
        &&op_NOR_RR,        // 19 MicroOpCode::NOR_RR
        &&op_EQV_RR,        // 20 MicroOpCode::EQV_RR
        &&op_CNTLZW,        // 21 MicroOpCode::CNTLZW
        &&op_EXTSB,         // 22 MicroOpCode::EXTSB
        &&op_EXTSH,         // 23 MicroOpCode::EXTSH
        &&op_SLW_VAR,       // 24 MicroOpCode::SLW_VAR
        &&op_SRW_VAR,       // 25 MicroOpCode::SRW_VAR
        &&op_SRAW_VAR,      // 26 MicroOpCode::SRAW_VAR
        &&op_SRAWI_IMM,     // 27 MicroOpCode::SRAWI_IMM
        // Integer add/sub with carry/overflow semantics
        &&op_ADD_RR,        // 28 MicroOpCode::ADD_RR
        &&op_ADDC_RR,       // 29 MicroOpCode::ADDC_RR
        &&op_ADDE_RR,       // 30 MicroOpCode::ADDE_RR
        &&op_ADDME,         // 31 MicroOpCode::ADDME
        &&op_ADDZE,         // 32 MicroOpCode::ADDZE
        &&op_SUBF_RR,       // 33 MicroOpCode::SUBF_RR
        &&op_SUBFC_RR,      // 34 MicroOpCode::SUBFC_RR
        &&op_SUBFE_RR,      // 35 MicroOpCode::SUBFE_RR
        &&op_SUBFME,        // 36 MicroOpCode::SUBFME
        &&op_SUBFZE,        // 37 MicroOpCode::SUBFZE
        // Integer compare ops
        &&op_CMP_S_RR,      // 38 MicroOpCode::CMP_S_RR
        &&op_CMPL_U_RR,     // 39 MicroOpCode::CMPL_U_RR
        &&op_CMP_S_IMM,     // 40 MicroOpCode::CMP_S_IMM
        &&op_CMPL_U_IMM,    // 41 MicroOpCode::CMPL_U_IMM
        &&op_NOP            // 42 MicroOpCode::NOP
    };
    static_assert(std::size(dispatch_table) == static_cast<size_t>(MicroOpCode::COUNT),
                  "dispatch_table must cover all MicroOpCode entries and match enum order");

  micro_dispatch:
    {
      const MicroOp& m = ops[i];
      const unsigned op_index = static_cast<unsigned>(m.op);
      if (__builtin_expect(op_index >= static_cast<unsigned>(MicroOpCode::COUNT), 0))
        goto micro_done; // fail fast; invalid op emitted
      goto *dispatch_table[op_index];
    }

  op_CONST32:
    {
      const MicroOp& m = ops[i];
      ppc_state.gpr[m.rd] = m.imm;
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  // Compare handlers: update CR[rd] only, no GPR writes
  op_CMP_S_RR:
    {
      const MicroOp& m = ops[i];
      const s32 a = s32(ppc_state.gpr[m.ra]);
      const s32 b = s32(ppc_state.gpr[m.rb]);
      u32 crf = 0;
      crf |= (a < b) ? PowerPC::CR_LT : 0;
      crf |= (a > b) ? PowerPC::CR_GT : 0;
      crf |= (a == b) ? PowerPC::CR_EQ : 0;
      CI_WriteCRField(ppc_state, m.rd, crf);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_CMPL_U_RR:
    {
      const MicroOp& m = ops[i];
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      u32 crf = 0;
      crf |= (a < b) ? PowerPC::CR_LT : 0;
      crf |= (a > b) ? PowerPC::CR_GT : 0;
      crf |= (a == b) ? PowerPC::CR_EQ : 0;
      CI_WriteCRField(ppc_state, m.rd, crf);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_CMP_S_IMM:
    {
      const MicroOp& m = ops[i];
      const s32 a = s32(ppc_state.gpr[m.ra]);
      const s32 b = s32(s16(m.imm & 0xFFFF));
      u32 crf = 0;
      crf |= (a < b) ? PowerPC::CR_LT : 0;
      crf |= (a > b) ? PowerPC::CR_GT : 0;
      crf |= (a == b) ? PowerPC::CR_EQ : 0;
      CI_WriteCRField(ppc_state, m.rd, crf);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_CMPL_U_IMM:
    {
      const MicroOp& m = ops[i];
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = m.imm & 0xFFFFu;
      u32 crf = 0;
      crf |= (a < b) ? PowerPC::CR_LT : 0;
      crf |= (a > b) ? PowerPC::CR_GT : 0;
      crf |= (a == b) ? PowerPC::CR_EQ : 0;
      CI_WriteCRField(ppc_state, m.rd, crf);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_CONST32_ADDRA:
    {
      const MicroOp& m = ops[i];
      const u32 ra_val = ppc_state.gpr[m.ra];
      const s32 hi = static_cast<s16>(static_cast<u32>(m.imm) >> 16);
      const u32 lo = m.imm & 0xFFFFu;
      const u32 upper_add = ra_val + (static_cast<u32>(hi) << 16);
      ppc_state.gpr[m.rd] = upper_add | lo;
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ADDI:
    {
      const MicroOp& m = ops[i];
      const u32 ra_val = (m.ra == 0) ? 0u : ppc_state.gpr[m.ra];
      const s32 simm = static_cast<s32>(static_cast<s16>(m.imm & 0xFFFF));
      ppc_state.gpr[m.rd] = ra_val + static_cast<u32>(simm);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ADDIS:
    {
      const MicroOp& m = ops[i];
      const u32 ra_val = (m.ra == 0) ? 0u : ppc_state.gpr[m.ra];
      const s32 simm = static_cast<s32>(static_cast<s16>(m.imm & 0xFFFF));
      ppc_state.gpr[m.rd] = ra_val + (static_cast<u32>(simm) << 16);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ORI:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = m.imm & 0xFFFFu;
      ppc_state.gpr[m.rd] = rs_val | ui;
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ORIS:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = (m.imm & 0xFFFFu) << 16;
      ppc_state.gpr[m.rd] = rs_val | ui;
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_XORI:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = m.imm & 0xFFFFu;
      ppc_state.gpr[m.rd] = rs_val ^ ui;
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_XORIS:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = (m.imm & 0xFFFFu) << 16;
      ppc_state.gpr[m.rd] = rs_val ^ ui;
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ANDI:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = m.imm & 0xFFFFu;
      ppc_state.gpr[m.rd] = rs_val & ui;
      CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ANDIS:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = (m.imm & 0xFFFFu) << 16;
      ppc_state.gpr[m.rd] = rs_val & ui;
      CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_RLWINM_IMM:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 sh = (m.imm >> 0) & 31u;
      const u32 mb = (m.imm >> 5) & 31u;
      const u32 me = (m.imm >> 10) & 31u;
      const u32 mask = MakeRotationMask(mb, me);
      ppc_state.gpr[m.rd] = std::rotl(rs_val, sh) & mask;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_AND_RR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val & rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_OR_RR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val | rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_XOR_RR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val ^ rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_RLWIMI_IMM:
    {
      const MicroOp& m = ops[i];
      const u32 ra_old = ppc_state.gpr[m.rd];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 sh = (m.imm >> 0) & 31u;
      const u32 mb = (m.imm >> 5) & 31u;
      const u32 me = (m.imm >> 10) & 31u;
      const u32 mask = MakeRotationMask(mb, me);
      const u32 rot = std::rotl(rs_val, sh) & mask;
      ppc_state.gpr[m.rd] = (ra_old & ~mask) | rot;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_RLWNM_VAR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb] & 31u; // shift is low 5 bits of RB
      const u32 mb = (m.imm >> 5) & 31u;
      const u32 me = (m.imm >> 10) & 31u;
      const u32 mask = MakeRotationMask(mb, me);
      ppc_state.gpr[m.rd] = std::rotl(rs_val, rb_val) & mask;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ANDC_RR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val & ~rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ORC_RR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val | ~rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_NAND_RR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = ~(rs_val & rb_val);
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_NOR_RR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = ~(rs_val | rb_val);
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_EQV_RR:
    {
      const MicroOp& m = ops[i];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = ~(rs_val ^ rb_val);
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_CNTLZW:
    {
      const MicroOp& m = ops[i];
      ppc_state.gpr[m.rd] = static_cast<u32>(std::countl_zero(ppc_state.gpr[m.ra]));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_EXTSB:
    {
      const MicroOp& m = ops[i];
      ppc_state.gpr[m.rd] = static_cast<u32>(static_cast<s32>(static_cast<s8>(ppc_state.gpr[m.ra])));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_EXTSH:
    {
      const MicroOp& m = ops[i];
      ppc_state.gpr[m.rd] = static_cast<u32>(static_cast<s32>(static_cast<s16>(ppc_state.gpr[m.ra])));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SLW_VAR:
    {
      const MicroOp& m = ops[i];
      const u32 amount = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = (amount & 0x20u) ? 0u : (ppc_state.gpr[m.ra] << (amount & 0x1fu));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SRW_VAR:
    {
      const MicroOp& m = ops[i];
      const u32 amount = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = (amount & 0x20u) ? 0u : (ppc_state.gpr[m.ra] >> (amount & 0x1fu));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SRAW_VAR:
    {
      const MicroOp& m = ops[i];
      const u32 rb_val = ppc_state.gpr[m.rb];
      if (rb_val & 0x20u)
      {
        if (ppc_state.gpr[m.ra] & 0x80000000u)
        {
          ppc_state.gpr[m.rd] = 0xFFFFFFFFu;
          ppc_state.SetCarry(1);
        }
        else
        {
          ppc_state.gpr[m.rd] = 0x00000000u;
          ppc_state.SetCarry(0);
        }
      }
      else
      {
        const u32 amount = rb_val & 0x1fu;
        const s32 rrs = static_cast<s32>(ppc_state.gpr[m.ra]);
        ppc_state.gpr[m.rd] = static_cast<u32>(rrs >> amount);
        ppc_state.SetCarry(rrs < 0 && amount > 0 && (static_cast<u32>(rrs) << (32 - amount)) != 0);
      }
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SRAWI_IMM:
    {
      const MicroOp& m = ops[i];
      const u32 amount = m.imm & 31u;
      const s32 rrs = static_cast<s32>(ppc_state.gpr[m.ra]);
      ppc_state.gpr[m.rd] = static_cast<u32>(rrs >> amount);
      ppc_state.SetCarry(rrs < 0 && amount > 0 && (static_cast<u32>(rrs) << (32 - amount)) != 0);
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  // Integer add/sub with carry/overflow semantics
  op_ADD_RR:
    {
      const MicroOp& m = ops[i];
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b;
      ppc_state.gpr[m.rd] = result;
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ADDC_RR:
    {
      const MicroOp& m = ops[i];
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, b));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ADDE_RR:
    {
      const MicroOp& m = ops[i];
      const u32 carry = ppc_state.GetCarry();
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, b) || (carry != 0 && CI_Helper_Carry(a + b, carry)));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ADDME:
    {
      const MicroOp& m = ops[i];
      const u32 carry = ppc_state.GetCarry();
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = 0xFFFFFFFFu;
      const u32 result = a + b + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, carry - 1));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_ADDZE:
    {
      const MicroOp& m = ops[i];
      const u32 carry = ppc_state.GetCarry();
      const u32 a = ppc_state.gpr[m.ra];
      const u32 result = a + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, carry));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, 0, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SUBF_RR:
    {
      const MicroOp& m = ops[i];
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b + 1u;
      ppc_state.gpr[m.rd] = result;
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SUBFC_RR:
    {
      const MicroOp& m = ops[i];
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b + 1u;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(a == 0xFFFFFFFFu || CI_Helper_Carry(b, a + 1u));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SUBFE_RR:
    {
      const MicroOp& m = ops[i];
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 carry = ppc_state.GetCarry();
      const u32 result = a + b + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, b) || CI_Helper_Carry(a + b, carry));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SUBFME:
    {
      const MicroOp& m = ops[i];
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 b = 0xFFFFFFFFu;
      const u32 carry = ppc_state.GetCarry();
      const u32 result = a + b + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, carry - 1));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_SUBFZE:
    {
      const MicroOp& m = ops[i];
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 carry = ppc_state.GetCarry();
      const u32 result = a + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, carry));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, 0, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      ++i;
      if (i < count) goto micro_dispatch; else goto micro_done;
    }

  op_NOP:
    {
      ++i;
      if (i < count) goto micro_dispatch;
    }

  micro_done:
    ;
  }
#else
  for (u32 i = 0; i < count; ++i)
  {
    const MicroOp& m = ops[i];
    switch (m.op)
    {
    case MicroOpCode::CONST32:
      ppc_state.gpr[m.rd] = m.imm;
      break;
    case MicroOpCode::CONST32_ADDRA:
    {
      const u32 ra_val = ppc_state.gpr[m.ra];
      const s32 hi = static_cast<s16>(static_cast<u32>(m.imm) >> 16);
      const u32 lo = m.imm & 0xFFFFu;
      const u32 upper_add = ra_val + (static_cast<u32>(hi) << 16);
      ppc_state.gpr[m.rd] = upper_add | lo;
      break;
    }
    case MicroOpCode::ADDI:
    {
      const u32 ra_val = (m.ra == 0) ? 0u : ppc_state.gpr[m.ra];
      const s32 simm = static_cast<s32>(static_cast<s16>(m.imm & 0xFFFF));
      ppc_state.gpr[m.rd] = ra_val + static_cast<u32>(simm);
      break;
    }
    case MicroOpCode::ADDIS:
    {
      const u32 ra_val = (m.ra == 0) ? 0u : ppc_state.gpr[m.ra];
      const s32 simm = static_cast<s32>(static_cast<s16>(m.imm & 0xFFFF));
      ppc_state.gpr[m.rd] = ra_val + (static_cast<u32>(simm) << 16);
      break;
    }
    case MicroOpCode::ORI:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = m.imm & 0xFFFFu;
      ppc_state.gpr[m.rd] = rs_val | ui;
      break;
    }
    case MicroOpCode::ORIS:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = (m.imm & 0xFFFFu) << 16;
      ppc_state.gpr[m.rd] = rs_val | ui;
      break;
    }
    case MicroOpCode::XORI:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = m.imm & 0xFFFFu;
      ppc_state.gpr[m.rd] = rs_val ^ ui;
      break;
    }
    case MicroOpCode::XORIS:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = (m.imm & 0xFFFFu) << 16;
      ppc_state.gpr[m.rd] = rs_val ^ ui;
      break;
    }
    case MicroOpCode::ANDI:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = m.imm & 0xFFFFu;
      ppc_state.gpr[m.rd] = rs_val & ui;
      CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::ANDIS:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 ui = (m.imm & 0xFFFFu) << 16;
      ppc_state.gpr[m.rd] = rs_val & ui;
      CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::RLWINM_IMM:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 sh = (m.imm >> 0) & 31u;
      const u32 mb = (m.imm >> 5) & 31u;
      const u32 me = (m.imm >> 10) & 31u;
      const u32 mask = MakeRotationMask(mb, me);
      ppc_state.gpr[m.rd] = std::rotl(rs_val, sh) & mask;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::AND_RR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val & rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::OR_RR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val | rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::XOR_RR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val ^ rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::RLWIMI_IMM:
    {
      const u32 ra_old = ppc_state.gpr[m.rd];
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 sh = (m.imm >> 0) & 31u;
      const u32 mb = (m.imm >> 5) & 31u;
      const u32 me = (m.imm >> 10) & 31u;
      const u32 mask = MakeRotationMask(mb, me);
      const u32 rot = std::rotl(rs_val, sh) & mask;
      ppc_state.gpr[m.rd] = (ra_old & ~mask) | rot;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::RLWNM_VAR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb] & 31u;
      const u32 mb = (m.imm >> 5) & 31u;
      const u32 me = (m.imm >> 10) & 31u;
      const u32 mask = MakeRotationMask(mb, me);
      ppc_state.gpr[m.rd] = std::rotl(rs_val, rb_val) & mask;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::ANDC_RR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val & ~rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::ORC_RR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = rs_val | ~rb_val;
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::NAND_RR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = ~(rs_val & rb_val);
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::NOR_RR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = ~(rs_val | rb_val);
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::EQV_RR:
    {
      const u32 rs_val = ppc_state.gpr[m.ra];
      const u32 rb_val = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = ~(rs_val ^ rb_val);
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::CNTLZW:
    {
      ppc_state.gpr[m.rd] = static_cast<u32>(std::countl_zero(ppc_state.gpr[m.ra]));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::EXTSB:
    {
      ppc_state.gpr[m.rd] = static_cast<u32>(static_cast<s32>(static_cast<s8>(ppc_state.gpr[m.ra])));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::EXTSH:
    {
      ppc_state.gpr[m.rd] = static_cast<u32>(static_cast<s32>(static_cast<s16>(ppc_state.gpr[m.ra])));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::SLW_VAR:
    {
      const u32 amount = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = (amount & 0x20u) ? 0u : (ppc_state.gpr[m.ra] << (amount & 0x1fu));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::SRW_VAR:
    {
      const u32 amount = ppc_state.gpr[m.rb];
      ppc_state.gpr[m.rd] = (amount & 0x20u) ? 0u : (ppc_state.gpr[m.ra] >> (amount & 0x1fu));
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::SRAW_VAR:
    {
      const u32 rb_val = ppc_state.gpr[m.rb];
      if (rb_val & 0x20u)
      {
        if (ppc_state.gpr[m.ra] & 0x80000000u)
        {
          ppc_state.gpr[m.rd] = 0xFFFFFFFFu;
          ppc_state.SetCarry(1);
        }
        else
        {
          ppc_state.gpr[m.rd] = 0x00000000u;
          ppc_state.SetCarry(0);
        }
      }
      else
      {
        const u32 amount = rb_val & 0x1fu;
        const s32 rrs = static_cast<s32>(ppc_state.gpr[m.ra]);
        ppc_state.gpr[m.rd] = static_cast<u32>(rrs >> amount);
        ppc_state.SetCarry(rrs < 0 && amount > 0 && (static_cast<u32>(rrs) << (32 - amount)) != 0);
      }
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    case MicroOpCode::SRAWI_IMM:
    {
      const u32 amount = m.imm & 31u;
      const s32 rrs = static_cast<s32>(ppc_state.gpr[m.ra]);
      ppc_state.gpr[m.rd] = static_cast<u32>(rrs >> amount);
      ppc_state.SetCarry(rrs < 0 && amount > 0 && (static_cast<u32>(rrs) << (32 - amount)) != 0);
      if (m.rc)
        CI_UpdateCR0(ppc_state, ppc_state.gpr[m.rd]);
      break;
    }
    // Integer add/sub with carry/overflow semantics
    case MicroOpCode::ADD_RR:
    {
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b;
      ppc_state.gpr[m.rd] = result;
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::ADDC_RR:
    {
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, b));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::ADDE_RR:
    {
      const u32 carry = ppc_state.GetCarry();
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, b) || (carry != 0 && CI_Helper_Carry(a + b, carry)));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::ADDME:
    {
      const u32 carry = ppc_state.GetCarry();
      const u32 a = ppc_state.gpr[m.ra];
      const u32 b = 0xFFFFFFFFu;
      const u32 result = a + b + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, carry - 1));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::ADDZE:
    {
      const u32 carry = ppc_state.GetCarry();
      const u32 a = ppc_state.gpr[m.ra];
      const u32 result = a + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, carry));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, 0, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::SUBF_RR:
    {
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b + 1u;
      ppc_state.gpr[m.rd] = result;
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::SUBFC_RR:
    {
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 result = a + b + 1u;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(a == 0xFFFFFFFFu || CI_Helper_Carry(b, a + 1u));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::SUBFE_RR:
    {
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 b = ppc_state.gpr[m.rb];
      const u32 carry = ppc_state.GetCarry();
      const u32 result = a + b + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, b) || CI_Helper_Carry(a + b, carry));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::SUBFME:
    {
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 b = 0xFFFFFFFFu;
      const u32 carry = ppc_state.GetCarry();
      const u32 result = a + b + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, carry - 1));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::SUBFZE:
    {
      const u32 a = ~ppc_state.gpr[m.ra];
      const u32 carry = ppc_state.GetCarry();
      const u32 result = a + carry;
      ppc_state.gpr[m.rd] = result;
      ppc_state.SetCarry(CI_Helper_Carry(a, carry));
      if ((m.imm & 1u) != 0)
        ppc_state.SetXER_OV(CI_HasAddOverflowed(a, 0, result));
      if (m.rc)
        CI_UpdateCR0(ppc_state, result);
      break;
    }
    case MicroOpCode::NOP:
    default:
      break;
    }
  }
#endif

  // No exceptions/CR updates are modeled here; decoder must only emit safe ops.
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
s32 CachedInterpreter::ExecuteMicroOps(std::ostream& stream,
                                       const ExecuteMicroOpsOperands& operands)
{
  fmt::print(stream, "MicroOps (count={}) at PC={:#010x}\n", operands.count,
             operands.current_pc);
  return sizeof(AnyCallback) + sizeof(operands);
}

void CachedInterpreter::Shutdown()
{
  m_block_cache.Shutdown();
}

CI_HOT_ONLY void CachedInterpreter::ExecuteOneBlock()
{
  const u8* normal_entry = m_block_cache.Dispatch();
  if (!normal_entry)
  {
    Jit(m_ppc_state.pc);
    return;
  }

  auto& ppc_state = m_ppc_state;
  while (true)
  {
#if defined(__aarch64__)
    __builtin_prefetch(normal_entry + 64, 0, 1);
    __builtin_prefetch(normal_entry + 128, 0, 1);
#endif
    const auto callback = *reinterpret_cast<const AnyCallback*>(normal_entry);
    if (const auto distance = callback(ppc_state, normal_entry + sizeof(callback))) [[likely]]
      normal_entry += distance;
    else
      break;
  }
}

CI_HOT_ONLY void CachedInterpreter::Run()
{
  auto& core_timing = m_system.GetCoreTiming();

  const CPU::State* state_ptr = m_system.GetCPU().GetStatePtr();
  while (*state_ptr == CPU::State::Running)
  {
    // Start new timing slice
    // NOTE: Exceptions may change PC
    core_timing.Advance();

    do
    {
      ExecuteOneBlock();
    } while (m_ppc_state.downcount > 0 && *state_ptr == CPU::State::Running);
  }
}

CI_HOT_ONLY void CachedInterpreter::SingleStep()
{
  // Enter new timing slice
  m_system.GetCoreTiming().Advance();
  ExecuteOneBlock();
}

s32 CachedInterpreter::StartProfiledBlock(PowerPC::PowerPCState& ppc_state,
                                          const StartProfiledBlockOperands& operands)
{
  JitBlock::ProfileData::BeginProfiling(operands.profile_data);
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool profiled>
s32 CachedInterpreter::EndBlock(PowerPC::PowerPCState& ppc_state,
                                const EndBlockOperands<profiled>& operands)
{
  ppc_state.pc = ppc_state.npc;
  ppc_state.downcount -= operands.downcount;
  if (PowerPC::PerformanceMonitorActive(ppc_state))
  {
    PowerPC::UpdatePerformanceMonitor(operands.downcount, operands.num_load_stores,
                                      operands.num_fp_inst, ppc_state);
  }
  if constexpr (profiled)
    JitBlock::ProfileData::EndProfiling(operands.profile_data, operands.downcount);
  return 0;
}

template <bool write_pc>
s32 CachedInterpreter::Interpret(PowerPC::PowerPCState& ppc_state,
                                 const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  operands.func(operands.interpreter, operands.inst);
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
s32 CachedInterpreter::InterpretAndCheckExceptions(
    PowerPC::PowerPCState& ppc_state, const InterpretAndCheckExceptionsOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  operands.func(operands.interpreter, operands.inst);

  if ((ppc_state.Exceptions & (EXCEPTION_DSI | EXCEPTION_PROGRAM)) != 0)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.downcount -= operands.downcount;
    operands.power_pc.CheckExceptions();
    return 0;
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreter::HLEFunction(PowerPC::PowerPCState& ppc_state,
                                    const HLEFunctionOperands& operands)
{
  const auto& [system, current_pc, hook_index] = operands;
  ppc_state.pc = current_pc;
  HLE::Execute(Core::CPUThreadGuard{system}, current_pc, hook_index);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreter::WriteBrokenBlockNPC(PowerPC::PowerPCState& ppc_state,
                                           const WriteBrokenBlockNPCOperands& operands)
{
  const auto& [current_pc] = operands;
  ppc_state.npc = current_pc;
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreter::CheckFPU(PowerPC::PowerPCState& ppc_state, const CheckHaltOperands& operands)
{
  const auto& [power_pc, current_pc, downcount] = operands;
  if (!ppc_state.msr.FP)
  {
    ppc_state.pc = current_pc;
    ppc_state.downcount -= downcount;
    ppc_state.Exceptions |= EXCEPTION_FPU_UNAVAILABLE;
    power_pc.CheckExceptions();
    return 0;
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreter::CheckBreakpoint(PowerPC::PowerPCState& ppc_state,
                                       const CheckHaltOperands& operands)
{
  const auto& [power_pc, current_pc, downcount] = operands;
  ppc_state.pc = current_pc;
  if (power_pc.CheckAndHandleBreakPoints())
  {
    // Accessing PowerPCState through power_pc instead of ppc_state produces better assembly.
    power_pc.GetPPCState().downcount -= downcount;
    return 0;
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreter::CheckIdle(PowerPC::PowerPCState& ppc_state,
                                 const CheckIdleOperands& operands)
{
  const auto& [core_timing, idle_pc] = operands;
  if (ppc_state.npc == idle_pc)
    core_timing.Idle();
  return sizeof(AnyCallback) + sizeof(operands);
}

bool CachedInterpreter::HandleFunctionHooking(u32 address)
{
  // CachedInterpreter inherits from JitBase and is considered a JIT by relevant code.
  // (see JitInterface and how m_mode is set within PowerPC.cpp)
  const auto result = HLE::TryReplaceFunction(m_ppc_symbol_db, address, PowerPC::CoreMode::JIT);
  if (!result)
    return false;

  Write(HLEFunction, {m_system, address, result.hook_index});

  if (result.type != HLE::HookType::Replace)
    return false;

  js.downcountAmount += js.st.numCycles;
  WriteEndBlock();
  return true;
}

void CachedInterpreter::WriteEndBlock()
{
  if (IsProfilingEnabled())
  {
    Write(EndBlock<true>, {{js.downcountAmount, js.numLoadStoreInst, js.numFloatingPointInst},
                           js.curBlock->profile_data.get()});
  }
  else
  {
    Write(EndBlock<false>, {js.downcountAmount, js.numLoadStoreInst, js.numFloatingPointInst});
  }
}

bool CachedInterpreter::SetEmitterStateToFreeCodeRegion()
{
  const auto free = m_free_ranges.by_size_begin();
  if (free == m_free_ranges.by_size_end())
  {
    WARN_LOG_FMT(DYNA_REC, "Failed to find free memory region in code region.");
    return false;
  }
  SetCodePtr(free.from(), free.to());
  return true;
}

void CachedInterpreter::FreeRanges()
{
  for (const auto& [from, to] : m_block_cache.GetRangesToFree())
    m_free_ranges.insert(from, to);
  m_block_cache.ClearRangesToFree();
}

void CachedInterpreter::ResetFreeMemoryRanges()
{
  m_free_ranges.clear();
  m_free_ranges.insert(region, region + region_size);
}

void CachedInterpreter::Jit(u32 em_address)
{
  Jit(em_address, true);
}

void CachedInterpreter::Jit(u32 em_address, bool clear_cache_and_retry_on_failure)
{
  if (IsAlmostFull() || SConfig::GetInstance().bJITNoBlockCache)
  {
    ClearCache();
  }
  FreeRanges();

  const u32 nextPC =
      analyzer.Analyze(em_address, &code_block, &m_code_buffer, m_code_buffer.size());
  if (code_block.m_memory_exception)
  {
    // Address of instruction could not be translated
    m_ppc_state.npc = nextPC;
    m_ppc_state.Exceptions |= EXCEPTION_ISI;
    m_system.GetPowerPC().CheckExceptions();
    WARN_LOG_FMT(POWERPC, "ISI exception at {:#010x}", nextPC);
    return;
  }

  if (SetEmitterStateToFreeCodeRegion())
  {
    JitBlock* b = m_block_cache.AllocateBlock(em_address);
    b->normalEntry = b->near_begin = GetWritableCodePtr();

    if (DoJit(em_address, b, nextPC))
    {
      // Record what memory region was used so we know what to free if this block gets invalidated.
      b->near_end = GetWritableCodePtr();
      b->far_begin = b->far_end = nullptr;

      // Mark the memory region that this code block uses in the RangeSizeSet.
      if (b->near_begin != b->near_end)
        m_free_ranges.erase(b->near_begin, b->near_end);

      m_block_cache.FinalizeBlock(*b, jo.enableBlocklink, code_block, m_code_buffer);

#ifdef JIT_LOG_GENERATED_CODE
      LogGeneratedCode();
#endif

      return;
    }
  }

  if (clear_cache_and_retry_on_failure)
  {
    WARN_LOG_FMT(DYNA_REC, "flushing code caches, please report if this happens a lot");
    ClearCache();
    Jit(em_address, false);
    return;
  }

  PanicAlertFmtT("JIT failed to find code space after a cache clear. This should never happen. "
                 "Please report this incident on the bug tracker. Dolphin will now exit.");
  std::exit(-1);
}

bool CachedInterpreter::DoJit(u32 em_address, JitBlock* b, u32 nextPC)
{
  js.blockStart = em_address;
  js.firstFPInstructionFound = false;
  js.fifoBytesSinceCheck = 0;
  js.downcountAmount = 0;
  js.numLoadStoreInst = 0;
  js.numFloatingPointInst = 0;
  js.curBlock = b;

  auto& interpreter = m_system.GetInterpreter();
  auto& power_pc = m_system.GetPowerPC();
  auto& cpu = m_system.GetCPU();
  auto& breakpoints = power_pc.GetBreakPoints();

  if (IsProfilingEnabled())
    Write(StartProfiledBlock, {js.curBlock->profile_data.get()});

  for (u32 i = 0; i < code_block.m_num_instructions; i++)
  {
    PPCAnalyst::CodeOp& op = m_code_buffer[i];
    js.op = &op;

    js.compilerPC = op.address;
    js.instructionsLeft = (code_block.m_num_instructions - 1) - i;
    js.downcountAmount += op.opinfo->num_cycles;
    if (op.opinfo->flags & FL_LOADSTORE)
      ++js.numLoadStoreInst;
    if (op.opinfo->flags & FL_USE_FPU)
      ++js.numFloatingPointInst;

    if (HandleFunctionHooking(js.compilerPC))
      break;

    if (!op.skip)
    {
      if (IsDebuggingEnabled() && !cpu.IsStepping() &&
          breakpoints.IsAddressBreakPoint(js.compilerPC))
      {
        Write(CheckBreakpoint, {power_pc, js.compilerPC, js.downcountAmount});
      }
      if (!js.firstFPInstructionFound && (op.opinfo->flags & FL_USE_FPU) != 0)
      {
        Write(CheckFPU, {power_pc, js.compilerPC, js.downcountAmount});
        js.firstFPInstructionFound = true;
      }

      // Instruction may cause a DSI Exception or Program Exception.
      if ((jo.memcheck && (op.opinfo->flags & FL_LOADSTORE) != 0) ||
          (!op.canEndBlock && ShouldHandleFPExceptionForInstruction(&op)))
      {
        const InterpretAndCheckExceptionsOperands operands = {
            {interpreter, Interpreter::GetInterpreterOp(op.inst), js.compilerPC, op.inst},
            power_pc,
            js.downcountAmount};
        Write(op.canEndBlock ? CallbackCast(InterpretAndCheckExceptions<true>) :
                               CallbackCast(InterpretAndCheckExceptions<false>),
              operands);
      }
      else
      {
        // First, try to collapse a CONST32 pattern:
        // addis rt, r0, simm16; ori rt, rt, uimm16  => rt = (simm16 << 16) | uimm16
        bool emitted_const32 = false;
        if (op.inst.OPCD == 15 /*addis*/ && op.inst.RA == 0 && (i + 1) < code_block.m_num_instructions)
        {
          PPCAnalyst::CodeOp& op2 = m_code_buffer[i + 1];
          if (!op2.skip && (op2.opinfo->flags & (FL_LOADSTORE | FL_USE_FPU)) == 0 &&
              op2.inst.OPCD == 24 /*ori*/)
          {
            const u8 rt = op.inst.RD;
            if (op2.inst.RA == rt && op2.inst.RS == rt)
            {
              ExecuteMicroOpsOperands mop{};
              mop.count = 1;
              mop.current_pc = js.compilerPC;
              MicroOp& mu = mop.ops[0];
              mu.op = MicroOpCode::CONST32;
              mu.rd = rt;
              const u32 hi = static_cast<u32>(static_cast<s16>(op.inst.SIMM_16));
              const u32 lo = static_cast<u32>(op2.inst.UIMM & 0xFFFFu);
              mu.imm = (hi << 16) | lo;

              js.downcountAmount += op2.opinfo->num_cycles;
              const bool end_block = op2.canEndBlock;
              ++i; // consume op2

              emitted_const32 = true;
              Write(end_block ? CallbackCast(ExecuteMicroOps<true>) :
                               CallbackCast(ExecuteMicroOps<false>),
                    mop);
            }
          }
        }

        // If we did not match CONST32, try to collapse an AddRA CONST32 pattern:
        // addis rt, ra, simm16; ori rt, rt, uimm16  => rt = GPR[ra] + ((simm16 << 16) | uimm16)
        if (!emitted_const32 && op.inst.OPCD == 15 /*addis*/ && op.inst.RA != 0 &&
            (i + 1) < code_block.m_num_instructions)
        {
          PPCAnalyst::CodeOp& op2 = m_code_buffer[i + 1];
          if (!op2.skip && (op2.opinfo->flags & (FL_LOADSTORE | FL_USE_FPU)) == 0 &&
              op2.inst.OPCD == 24 /*ori*/)
          {
            const u8 rt = op.inst.RD;
            const u8 ra = op.inst.RA;
            if (op2.inst.RA == rt && op2.inst.RS == rt)
            {
              ExecuteMicroOpsOperands mop{};
              mop.count = 1;
              mop.current_pc = js.compilerPC;
              MicroOp& mu = mop.ops[0];
              mu.op = MicroOpCode::CONST32_ADDRA;
              mu.rd = rt;
              mu.ra = ra;
              const u32 hi = static_cast<u32>(static_cast<s16>(op.inst.SIMM_16));
              const u32 lo = static_cast<u32>(op2.inst.UIMM & 0xFFFFu);
              mu.imm = (hi << 16) | lo;

              js.downcountAmount += op2.opinfo->num_cycles;
              const bool end_block = op2.canEndBlock;
              ++i; // consume op2

              emitted_const32 = true;
              Write(end_block ? CallbackCast(ExecuteMicroOps<true>) :
                               CallbackCast(ExecuteMicroOps<false>),
                    mop);
            }
          }
        }

        // If we did not match any CONST32 pattern, try to pack a small run of simple ALU ops
        bool used_micro_ops = false;
        if (!emitted_const32)
        {
          auto is_simple_mop = [](const UGeckoInstruction& ins) -> bool {
            switch (ins.OPCD)
            {
            case 10: // cmpli
            case 11: // cmpi
            case 14: // addi
            case 15: // addis
            case 20: // rlwimix
            case 21: // rlwinm / rlwinm.
            case 23: // rlwnmx
            case 24: // ori
            case 25: // oris
            case 26: // xori
            case 27: // xoris
            case 28: // andi.
            case 29: // andis.
              return true;
            case 31: // X-form logical reg-reg and/or/xor
              switch (ins.SUBOP10)
              {
              case 0:   // cmp
              case 32:  // cmpl
              case 28:  // andx
              case 444: // orx
              case 316: // xorx
              case 60:  // andcx
              case 412: // orcx
              case 476: // nandx
              case 124: // norx
              case 284: // eqvx
              // arithmetic add/sub family
              case 266: // addx
              case 778: // addox
              case 10:  // addcx
              case 522: // addcox
              case 138: // addex
              case 650: // addeox
              case 234: // addmex
              case 746: // addmeox
              case 202: // addzex
              case 714: // addzeox
              case 40:  // subfx
              case 552: // subfox
              case 8:   // subfcx
              case 520: // subfcox
              case 136: // subfex
              case 648: // subfeox
              case 232: // subfmex
              case 744: // subfmeox
              case 200: // subfzex
              case 712: // subfzeox
              case 26:  // cntlzwx
              case 954: // extsbx
              case 922: // extshx
              case 24:  // slwx
              case 536: // srwx
              case 792: // srawx
              case 824: // srawix
                return true;
              default:
                return false;
              }
            default:
              return false;
            }
          };

          if (is_simple_mop(op.inst))
          {
            ExecuteMicroOpsOperands mop{};
            mop.count = 0;
            mop.current_pc = js.compilerPC;

            // Pack up to kMaxOps or until encountering a non-simple op
            for (u32 j = i; j < code_block.m_num_instructions &&
                            mop.count < ExecuteMicroOpsOperands::kMaxOps;
                 ++j)
            {
              PPCAnalyst::CodeOp& next = m_code_buffer[j];
              if (next.skip || (next.opinfo->flags & (FL_LOADSTORE | FL_USE_FPU)) != 0 ||
                  !is_simple_mop(next.inst))
              {
                break;
              }

              MicroOp& mu = mop.ops[mop.count++];
              switch (next.inst.OPCD)
              {
              case 10: // cmpli
              {
                mu.op = MicroOpCode::CMPL_U_IMM;
                mu.rd = next.inst.CRFD;
                mu.ra = next.inst.RA;
                mu.rb = 0;
                mu.rc = 0;
                mu.imm = next.inst.UIMM;
                goto end_pack_switch;
              }
              case 11: // cmpi
              {
                mu.op = MicroOpCode::CMP_S_IMM;
                mu.rd = next.inst.CRFD;
                mu.ra = next.inst.RA;
                mu.rb = 0;
                mu.rc = 0;
                mu.imm = static_cast<u16>(next.inst.SIMM_16); // keep 16-bit immediate
                goto end_pack_switch;
              }
              case 14: // addi
                mu.op = MicroOpCode::ADDI;
                mu.rd = next.inst.RD; // RT
                mu.ra = next.inst.RA; // RA (0 allowed)
                mu.imm = static_cast<u32>(next.inst.SIMM_16);
                break;
              case 15: // addis
                mu.op = MicroOpCode::ADDIS;
                mu.rd = next.inst.RD;
                mu.ra = next.inst.RA;
                mu.imm = static_cast<u32>(next.inst.SIMM_16);
                break;
              case 20: // rlwimix
                mu.op = MicroOpCode::RLWIMI_IMM;
                mu.rd = next.inst.RA; // destination RA
                mu.ra = next.inst.RS; // source RS
                mu.rb = 0;
                mu.rc = static_cast<u8>(next.inst.Rc);
                // Pack SH/MB/ME into imm: [0..4]=SH, [5..9]=MB, [10..14]=ME
                mu.imm = (static_cast<u32>(next.inst.SH) & 31u) |
                         ((static_cast<u32>(next.inst.MB) & 31u) << 5) |
                         ((static_cast<u32>(next.inst.ME) & 31u) << 10);
                break;
              case 21: // rlwinm/rlwinm.
                mu.op = MicroOpCode::RLWINM_IMM;
                mu.rd = next.inst.RA; // destination RA
                mu.ra = next.inst.RS; // source RS
                mu.rb = 0;
                mu.rc = static_cast<u8>(next.inst.Rc);
                // Pack SH/MB/ME into imm: [0..4]=SH, [5..9]=MB, [10..14]=ME
                mu.imm = (static_cast<u32>(next.inst.SH) & 31u) |
                         ((static_cast<u32>(next.inst.MB) & 31u) << 5) |
                         ((static_cast<u32>(next.inst.ME) & 31u) << 10);
                {
                  // NOP elimination: rlwinm rA,rA,0,0,31 with Rc==0
                  const bool is_identity = (next.inst.SH & 31u) == 0 && (next.inst.MB & 31u) == 0 &&
                                          (next.inst.ME & 31u) == 31 && next.inst.RA == next.inst.RS &&
                                          next.inst.Rc == 0;
                  if (is_identity)
                  {
                    // Drop this op from the micro-op batch
                    --mop.count;
                    goto end_pack_switch;
                  }
                }
                break;
              case 23: // rlwnmx
                mu.op = MicroOpCode::RLWNM_VAR;
                mu.rd = next.inst.RA; // destination RA
                mu.ra = next.inst.RS; // source RS
                mu.rb = next.inst.RB; // variable shift from RB
                mu.rc = static_cast<u8>(next.inst.Rc);
                // Pack MB/ME into imm: [5..9]=MB, [10..14]=ME (SH is variable from RB)
                mu.imm = ((static_cast<u32>(next.inst.MB) & 31u) << 5) |
                         ((static_cast<u32>(next.inst.ME) & 31u) << 10);
                break;
              case 24: // ori
                mu.op = MicroOpCode::ORI;
                mu.rd = next.inst.RA; // destination is RA
                mu.ra = next.inst.RS; // source is RS
                mu.imm = static_cast<u32>(next.inst.UIMM);
                {
                  // NOP elimination: ori rA,rA,0
                  if (next.inst.RA == next.inst.RS && (next.inst.UIMM & 0xFFFFu) == 0)
                  {
                    --mop.count;
                    goto end_pack_switch;
                  }
                  // Fold consecutive ori RA, RA, uimm
                  const u8 rt = next.inst.RA;
                  const u8 rs = next.inst.RS;
                  u32 combined = mu.imm & 0xFFFFu;
                  u32 jj = j + 1;
                  while (jj < code_block.m_num_instructions)
                  {
                    PPCAnalyst::CodeOp& n2 = m_code_buffer[jj];
                    if (n2.skip || (n2.opinfo->flags & (FL_LOADSTORE | FL_USE_FPU)) != 0 || !is_simple_mop(n2.inst))
                      break;
                    if (n2.inst.OPCD != 24 /*ori*/ || n2.inst.RA != rt || n2.inst.RS != rs)
                      break;
                    combined |= static_cast<u32>(n2.inst.UIMM & 0xFFFFu);
                    js.downcountAmount += n2.opinfo->num_cycles;
                    j = jj; // consume
                    ++jj;
                  }
                  mu.imm = combined;
                }
                break;
              case 25: // oris
                mu.op = MicroOpCode::ORIS;
                mu.rd = next.inst.RA; // destination is RA
                mu.ra = next.inst.RS; // source is RS
                mu.imm = static_cast<u32>(next.inst.UIMM);
                {
                  // NOP elimination: oris rA,rA,0
                  if (next.inst.RA == next.inst.RS && (next.inst.UIMM & 0xFFFFu) == 0)
                  {
                    --mop.count;
                    goto end_pack_switch;
                  }
                  // Fold consecutive oris RA, RA, uimm
                  const u8 rt = next.inst.RA;
                  const u8 rs = next.inst.RS;
                  u32 combined = mu.imm & 0xFFFFu;
                  u32 jj = j + 1;
                  while (jj < code_block.m_num_instructions)
                  {
                    PPCAnalyst::CodeOp& n2 = m_code_buffer[jj];
                    if (n2.skip || (n2.opinfo->flags & (FL_LOADSTORE | FL_USE_FPU)) != 0 || !is_simple_mop(n2.inst))
                      break;
                    if (n2.inst.OPCD != 25 /*oris*/ || n2.inst.RA != rt || n2.inst.RS != rs)
                      break;
                    combined |= static_cast<u32>(n2.inst.UIMM & 0xFFFFu);
                    js.downcountAmount += n2.opinfo->num_cycles;
                    j = jj; // consume
                    ++jj;
                  }
                  mu.imm = combined;
                }
                break;
              case 26: // xori
                mu.op = MicroOpCode::XORI;
                mu.rd = next.inst.RA; // destination is RA
                mu.ra = next.inst.RS; // source is RS
                mu.imm = static_cast<u32>(next.inst.UIMM);
                {
                  // NOP elimination: xori rA,rA,0
                  if (next.inst.RA == next.inst.RS && (next.inst.UIMM & 0xFFFFu) == 0)
                  {
                    --mop.count;
                    goto end_pack_switch;
                  }
                  // Fold consecutive xori RA, RA, uimm
                  const u8 rt = next.inst.RA;
                  const u8 rs = next.inst.RS;
                  u32 combined = mu.imm & 0xFFFFu;
                  u32 jj = j + 1;
                  while (jj < code_block.m_num_instructions)
                  {
                    PPCAnalyst::CodeOp& n2 = m_code_buffer[jj];
                    if (n2.skip || (n2.opinfo->flags & (FL_LOADSTORE | FL_USE_FPU)) != 0 || !is_simple_mop(n2.inst))
                      break;
                    if (n2.inst.OPCD != 26 /*xori*/ || n2.inst.RA != rt || n2.inst.RS != rs)
                      break;
                    combined ^= static_cast<u32>(n2.inst.UIMM & 0xFFFFu);
                    js.downcountAmount += n2.opinfo->num_cycles;
                    j = jj; // consume
                    ++jj;
                  }
                  mu.imm = combined;
                }
                break;
              case 27: // xoris
                mu.op = MicroOpCode::XORIS;
                mu.rd = next.inst.RA; // destination is RA
                mu.ra = next.inst.RS; // source is RS
                mu.imm = static_cast<u32>(next.inst.UIMM);
                {
                  // NOP elimination: xoris rA,rA,0
                  if (next.inst.RA == next.inst.RS && (next.inst.UIMM & 0xFFFFu) == 0)
                  {
                    --mop.count;
                    goto end_pack_switch;
                  }
                  // Fold consecutive xoris RA, RA, uimm
                  const u8 rt = next.inst.RA;
                  const u8 rs = next.inst.RS;
                  u32 combined = mu.imm & 0xFFFFu;
                  u32 jj = j + 1;
                  while (jj < code_block.m_num_instructions)
                  {
                    PPCAnalyst::CodeOp& n2 = m_code_buffer[jj];
                    if (n2.skip || (n2.opinfo->flags & (FL_LOADSTORE | FL_USE_FPU)) != 0 || !is_simple_mop(n2.inst))
                      break;
                    if (n2.inst.OPCD != 27 /*xoris*/ || n2.inst.RA != rt || n2.inst.RS != rs)
                      break;
                    combined ^= static_cast<u32>(n2.inst.UIMM & 0xFFFFu);
                    js.downcountAmount += n2.opinfo->num_cycles;
                    j = jj; // consume
                    ++jj;
                  }
                  mu.imm = combined;
                }
                break;
              case 28: // andi.
                mu.op = MicroOpCode::ANDI;
                mu.rd = next.inst.RA; // destination is RA (recording variant)
                mu.ra = next.inst.RS; // source is RS
                mu.imm = static_cast<u32>(next.inst.UIMM);
                break;
              case 29: // andis.
                mu.op = MicroOpCode::ANDIS;
                mu.rd = next.inst.RA; // destination is RA (recording variant)
                mu.ra = next.inst.RS; // source is RS
                mu.imm = static_cast<u32>(next.inst.UIMM);
                break;
              case 31: // X-form logicals/shifts/misc
              {
                switch (next.inst.SUBOP10)
                {
                case 0: // cmp
                {
                  mu.op = MicroOpCode::CMP_S_RR;
                  mu.rd = next.inst.CRFD;
                  mu.ra = next.inst.RA;
                  mu.rb = next.inst.RB;
                  mu.rc = 0;
                  mu.imm = 0;
                  goto end_pack_switch;
                }
                case 32: // cmpl
                {
                  mu.op = MicroOpCode::CMPL_U_RR;
                  mu.rd = next.inst.CRFD;
                  mu.ra = next.inst.RA;
                  mu.rb = next.inst.RB;
                  mu.rc = 0;
                  mu.imm = 0;
                  goto end_pack_switch;
                }
                case 28: // andx
                  mu.op = MicroOpCode::AND_RR;
                  break;
                case 444: // orx
                  mu.op = MicroOpCode::OR_RR;
                  break;
                case 316: // xorx
                  mu.op = MicroOpCode::XOR_RR;
                  break;
                case 60: // andcx
                  mu.op = MicroOpCode::ANDC_RR;
                  break;
                case 412: // orcx
                  mu.op = MicroOpCode::ORC_RR;
                  break;
                case 476: // nandx
                  mu.op = MicroOpCode::NAND_RR;
                  break;
                case 124: // norx
                  mu.op = MicroOpCode::NOR_RR;
                  break;
                case 284: // eqvx
                  mu.op = MicroOpCode::EQV_RR;
                  break;
                // arithmetic add/sub family
                case 266: // addx
                case 778: // addox (OE)
                {
                  mu.op = MicroOpCode::ADD_RR;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 778) ? 1u : 0u; // imm bit0 -> OE
                  goto end_pack_switch;
                }
                case 10: // addcx
                case 522: // addcox (OE)
                {
                  mu.op = MicroOpCode::ADDC_RR;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 522) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 138: // addex
                case 650: // addeox (OE)
                {
                  mu.op = MicroOpCode::ADDE_RR;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 650) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 234: // addmex
                case 746: // addmeox (OE)
                {
                  mu.op = MicroOpCode::ADDME;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = 0;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 746) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 202: // addzex
                case 714: // addzeox (OE)
                {
                  mu.op = MicroOpCode::ADDZE;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = 0;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 714) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 40: // subfx
                case 552: // subfox (OE)
                {
                  mu.op = MicroOpCode::SUBF_RR;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 552) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 8: // subfcx
                case 520: // subfcox (OE)
                {
                  mu.op = MicroOpCode::SUBFC_RR;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 520) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 136: // subfex
                case 648: // subfeox (OE)
                {
                  mu.op = MicroOpCode::SUBFE_RR;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 648) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 232: // subfmex
                case 744: // subfmeox (OE)
                {
                  mu.op = MicroOpCode::SUBFME;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = 0;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 744) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 200: // subfzex
                case 712: // subfzeox (OE)
                {
                  mu.op = MicroOpCode::SUBFZE;
                  mu.rd = next.inst.RD;
                  mu.ra = next.inst.RA;
                  mu.rb = 0;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = (next.inst.SUBOP10 == 712) ? 1u : 0u;
                  goto end_pack_switch;
                }
                case 26: // cntlzwx
                  mu.op = MicroOpCode::CNTLZW;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = 0;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 954: // extsbx
                  mu.op = MicroOpCode::EXTSB;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = 0;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 922: // extshx
                  mu.op = MicroOpCode::EXTSH;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = 0;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 24: // slwx
                  mu.op = MicroOpCode::SLW_VAR;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 536: // srwx
                  mu.op = MicroOpCode::SRW_VAR;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 792: // srawx
                  mu.op = MicroOpCode::SRAW_VAR;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = next.inst.RB;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = 0;
                  goto end_pack_switch;
                case 824: // srawix
                  mu.op = MicroOpCode::SRAWI_IMM;
                  mu.rd = next.inst.RA;
                  mu.ra = next.inst.RS;
                  mu.rb = 0;
                  mu.rc = static_cast<u8>(next.inst.Rc);
                  mu.imm = static_cast<u32>(next.inst.SH & 31u);
                  goto end_pack_switch;
                default:
                  // Not supported; undo reservation and stop packing
                  mop.count--;
                  j = code_block.m_num_instructions; // force stop
                  goto end_pack_switch;
                }
                // Common reg-reg logicals fallthrough: set standard fields
                mu.rd = next.inst.RA;
                mu.ra = next.inst.RS;
                mu.rb = next.inst.RB;
                mu.rc = static_cast<u8>(next.inst.Rc);
                mu.imm = 0;
                break;
              }
              default:
                mop.count--;
                j = code_block.m_num_instructions; // force stop
                break;
              }
            end_pack_switch:

              // Advance i when packing
              if (j != i)
                js.downcountAmount += next.opinfo->num_cycles;

              // Stop packing if this instruction ends the block
              if (next.canEndBlock)
              {
                // Emit what we have and ensure end block is handled after the loop
                i = j; // The for-loop will ++i; we want to stop at j
                break;
              }

              // Prepare to consume this op; the outer loop will ++i
              i = j;
            }

            if (mop.count > 0)
            {
              used_micro_ops = true;
              Write(op.canEndBlock ? CallbackCast(ExecuteMicroOps<true>) :
                                     CallbackCast(ExecuteMicroOps<false>),
                    mop);
            }
          }
        }

        if (!emitted_const32 && !used_micro_ops)
        {
          // Use PIC fast path for load/store instructions when possible
          if ((op.opinfo->flags & FL_LOADSTORE) != 0)
          {
            auto& mm = m_system.GetMemory();
            const LoadStoreDFormPICOperands operands = {interpreter,
                                                        Interpreter::GetInterpreterOp(op.inst),
                                                        js.compilerPC,
                                                        op.inst,
                                                        power_pc,
                                                        mm.GetRAM(),
                                                        mm.GetRamMask(),
                                                        mm.GetEXRAM(),
                                                        mm.GetExRamMask(),
                                                        mm.GetFakeVMEM(),
                                                        mm.GetFakeVMemMask()};
            if (op.inst.OPCD == 31)
            {
              if (op.inst.SUBOP10 == 1014) // dcbz
              {
                Write(op.canEndBlock ? CallbackCast(DcbzPIC<true>) : CallbackCast(DcbzPIC<false>),
                      operands);
              }
              else
              {
                Write(op.canEndBlock ? CallbackCast(LoadStoreXFormPIC<true>) :
                                       CallbackCast(LoadStoreXFormPIC<false>),
                      operands);
              }
            }
            else
            {
              Write(op.canEndBlock ? CallbackCast(LoadStoreDFormPIC<true>) :
                                     CallbackCast(LoadStoreDFormPIC<false>),
                    operands);
            }
            ++js.numLoadStoreInst;
          }
          else
          {
            const InterpretOperands operands = {interpreter, Interpreter::GetInterpreterOp(op.inst),
                                                js.compilerPC, op.inst};
            Write(op.canEndBlock ? CallbackCast(Interpret<true>) : CallbackCast(Interpret<false>),
                  operands);
          }
        }
      }

      if (op.branchIsIdleLoop)
        Write(CheckIdle, {m_system.GetCoreTiming(), js.blockStart});
      if (op.canEndBlock)
        WriteEndBlock();
    }
  }
  if (code_block.m_broken)
  {
    Write(WriteBrokenBlockNPC, {nextPC});
    WriteEndBlock();
  }

  if (HasWriteFailed())
  {
    WARN_LOG_FMT(DYNA_REC, "JIT ran out of space in code region during code generation.");
    return false;
  }
  return true;
}

void CachedInterpreter::EraseSingleBlock(const JitBlock& block)
{
  m_block_cache.EraseSingleBlock(block);
  FreeRanges();
}

std::vector<JitBase::MemoryStats> CachedInterpreter::GetMemoryStats() const
{
  return {{"free", m_free_ranges.get_stats()}};
}

std::size_t CachedInterpreter::DisassembleNearCode(const JitBlock& block,
                                                   std::ostream& stream) const
{
  return Disassemble(block, stream);
}

std::size_t CachedInterpreter::DisassembleFarCode(const JitBlock& block, std::ostream& stream) const
{
  stream << "N/A\n";
  return 0;
}

void CachedInterpreter::ClearCache()
{
  m_block_cache.Clear();
  m_block_cache.ClearRangesToFree();
  ClearCodeSpace();
  ResetFreeMemoryRanges();
  RefreshConfig();
  Host_JitCacheInvalidation();
}

void CachedInterpreter::LogGeneratedCode() const
{
  std::ostringstream stream;

  stream << "\nPPC Code Buffer:\n";
  for (const PPCAnalyst::CodeOp& op :
       std::span{m_code_buffer.data(), code_block.m_num_instructions})
  {
    fmt::print(stream, "0x{:08x}\t\t{}\n", op.address,
               Common::GekkoDisassembler::Disassemble(op.inst.hex, op.address));
  }

  stream << "\nHost Code:\n";
  Disassemble(*js.curBlock, stream);

  // TODO C++20: std::ostringstream::view()
  DEBUG_LOG_FMT(DYNA_REC, "{}", std::move(stream).str());
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::DcbzPIC(PowerPC::PowerPCState& ppc_state,
                                           const LoadStoreDFormPICOperands& operands)
{
  const auto& [interpreter, func, current_pc, inst, power_pc, mem1_base, mem1_mask, exram_base,
               exram_mask, fakevmem_base, fakevmem_mask] = operands;

  if constexpr (write_pc)
  {
    ppc_state.pc = current_pc;
    ppc_state.npc = current_pc + 4;
  }

  // Require data cache enabled and no address translation
  if (!HID0(ppc_state).DCE || ppc_state.msr.DR)
  {
    func(interpreter, inst);
    return sizeof(AnyCallback) + sizeof(operands);
  }

  // EA for X-form
  const u32 ea = inst.RA ? (ppc_state.gpr[inst.RA] + ppc_state.gpr[inst.RB]) : ppc_state.gpr[inst.RB];
  const u32 line_addr = ea & ~31u;

  const auto region = CI_GetRegionInfo(line_addr, ppc_state.msr.DR, mem1_base, mem1_mask,
                                       exram_base, exram_mask, fakevmem_base, fakevmem_mask);
  if (!region.base)
  {
    func(interpreter, inst);
    return sizeof(AnyCallback) + sizeof(operands);
  }
  const u32 offset = CI_RegionOffset(region, line_addr);
  std::memset(region.base + offset, 0, 32);
  return sizeof(AnyCallback) + sizeof(operands);
}
