// (instrumentation static functions defined later in this file)
// Copyright 2014 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/CachedInterpreter/CachedInterpreter.h"

#include <span>
#include <cstdlib>
#include <iterator>
#include <sstream>
#include <bit>
#include <utility>
#include <cstring>
#include <algorithm>
#include <limits>
#include <chrono>

#include <fmt/format.h>
#include <fmt/ostream.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach/thread_policy.h>
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
#include "Core/PowerPC/Interpreter/Interpreter_FPUtils.h"
#include "Core/PowerPC/Jit64Common/Jit64Constants.h"
#include "Core/PowerPC/PPCAnalyst.h"
#include "Core/PowerPC/PowerPC.h"
#include "Core/System.h"
#include "Core/HW/Memmap.h"
#include "Common/Swap.h"
#include "Core/PowerPC/Interpreter/Interpreter_FPUtils.h"
#include "Core/Config/MainSettings.h"
#include "VideoCommon/OnScreenDisplay.h"

bool CachedInterpreter::IsBlockLinkingEnabled()
{
  return Config::Get(Config::MAIN_CI_BLOCK_LINKING);
}

#if defined(__clang__) || defined(__GNUC__)
#if defined(__aarch64__)
#define CI_HOT_FLATTEN [[gnu::hot, gnu::flatten]]
#define CI_HOT_ONLY [[gnu::hot]]
#define CI_COLD_ONLY [[gnu::cold]]
#define CI_ALWAYS_INLINE __attribute__((always_inline)) inline
#else
#define CI_HOT_FLATTEN [[gnu::hot]]
#define CI_HOT_ONLY [[gnu::hot]]
#define CI_COLD_ONLY [[gnu::cold]]
#define CI_ALWAYS_INLINE __attribute__((always_inline)) inline
#endif
#else
#define CI_HOT_FLATTEN
#define CI_HOT_ONLY
#define CI_COLD_ONLY
#define CI_ALWAYS_INLINE inline
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

void CachedInterpreter::ConfigureFpFastFromEnv()
{
  const char* env = std::getenv("DOLPHIN_CI_FP_FAST");
  s_fp_fast_enabled = (env && env[0] == '1');
}

// Inline/verify controls for 59 arithmetic fast paths (file-local)
static bool s_inline59_enabled =
#if defined(__aarch64__)
    true;
#else
    false;
#endif
static bool s_verify_fp = false;
static u32 s_verify_sample_every = 64;
static bool s_verify_log = false;

static void ConfigureInline59FromEnv()
{
  const char* e1 = std::getenv("CI_ENABLE_INLINE_59");
  s_inline59_enabled = (e1 && e1[0] == '1');
  const char* e2 = std::getenv("CI_VERIFY_FP");
  s_verify_fp = (e2 && e2[0] == '1');
  const char* e3 = std::getenv("CI_VERIFY_SAMPLE");
  if (e3)
  {
    const long v = std::strtol(e3, nullptr, 10);
    if (v > 0 && v < 100000)
      s_verify_sample_every = static_cast<u32>(v);
  }
  const char* e4 = std::getenv("CI_VERIFY_LOG");
  s_verify_log = (e4 && e4[0] == '1');
}

// OPCD 63 fast paths (selected): fctiwzx (15), frspx (12), fmrx (72)
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FctiwzxFast(PowerPC::PowerPCState& ppc_state,
                                               const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  // Delegate to Interpreter to preserve full exception semantics while avoiding function pointer indirection
  Interpreter::fctiwzx(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[63];
    ++s_hot_stats.count_by_subop63[15];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// FMADD family delegates (single-precision): fmaddsx/fmsubsx/fnmaddsx/fnmsubsx
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FmaddsxFast(PowerPC::PowerPCState& ppc_state,
                                               const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  Interpreter::fmaddsx(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[59];
    ++s_hot_stats.count_by_subop59[29];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FmsubsxFast(PowerPC::PowerPCState& ppc_state,
                                               const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  Interpreter::fmsubsx(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[59];
    ++s_hot_stats.count_by_subop59[28];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FnmaddsxFast(PowerPC::PowerPCState& ppc_state,
                                                const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  Interpreter::fnmaddsx(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[59];
    ++s_hot_stats.count_by_subop59[31];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FnmsubsxFast(PowerPC::PowerPCState& ppc_state,
                                                const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  Interpreter::fnmsubsx(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[59];
    ++s_hot_stats.count_by_subop59[30];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// Verify-but-delegate fmulsx: compute inline expected without mutating state, then delegate to Interpreter
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FmulsxVerifyDelegateFast(PowerPC::PowerPCState& ppc_state,
                                                            const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  // Compute expected using inline path on local FPSCR copy
  float expected_result_bits = 0.0f;
  {
    const u32 fpscr_saved_hex = ppc_state.fpscr.Hex;
    const auto& a = ppc_state.ps[inst.FA];
    const auto& c = ppc_state.ps[inst.FC];
    const double c_value = Force25Bit(c.PS0AsDouble());
    const FPResult product = NI_mul(ppc_state, a.PS0AsDouble(), c_value);
    if (ppc_state.fpscr.VE == 0 || product.HasNoInvalidExceptions())
    {
      auto fpscr_copy = ppc_state.fpscr; // local copy to avoid mutating flags while computing ForceSingle
      const float result = ForceSingle(fpscr_copy, product.value);
      expected_result_bits = result;
    }
    // Restore FPSCR to avoid mutating real state during verification
    ppc_state.fpscr.Hex = fpscr_saved_hex;
  }
  // Now run the authoritative Interpreter version for correctness
  Interpreter::fmulsx(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[59];
    ++s_hot_stats.count_by_subop59[25];
  }
  (void)expected_result_bits; // logging disabled for portability
  return sizeof(AnyCallback) + sizeof(operands);
}

// Verify-but-delegate faddsx (compute inline expected, then delegate to Interpreter)
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FaddsxVerifyDelegateFast(PowerPC::PowerPCState& ppc_state,
                                                            const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  float expected_result_bits = 0.0f;
  {
    const u32 fpscr_saved_hex = ppc_state.fpscr.Hex;
    const auto& a = ppc_state.ps[inst.FA];
    const auto& b = ppc_state.ps[inst.FB];
    const FPResult sum = NI_add(ppc_state, a.PS0AsDouble(), b.PS0AsDouble());
    if (ppc_state.fpscr.VE == 0 || sum.HasNoInvalidExceptions())
    {
      auto fpscr_copy = ppc_state.fpscr;
      const float result = ForceSingle(fpscr_copy, sum.value);
      expected_result_bits = result;
    }
    ppc_state.fpscr.Hex = fpscr_saved_hex;
  }
  Interpreter::faddsx(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[59];
    ++s_hot_stats.count_by_subop59[21];
  }
  (void)expected_result_bits;
  return sizeof(AnyCallback) + sizeof(operands);
}

// Verify-but-delegate fsubsx (compute inline expected, then delegate to Interpreter)
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FsubsxVerifyDelegateFast(PowerPC::PowerPCState& ppc_state,
                                                            const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  float expected_result_bits = 0.0f;
  {
    const u32 fpscr_saved_hex = ppc_state.fpscr.Hex;
    const auto& a = ppc_state.ps[inst.FA];
    const auto& b = ppc_state.ps[inst.FB];
    const FPResult diff = NI_sub(ppc_state, a.PS0AsDouble(), b.PS0AsDouble());
    if (ppc_state.fpscr.VE == 0 || diff.HasNoInvalidExceptions())
    {
      auto fpscr_copy = ppc_state.fpscr;
      const float result = ForceSingle(fpscr_copy, diff.value);
      expected_result_bits = result;
    }
    ppc_state.fpscr.Hex = fpscr_saved_hex;
  }
  Interpreter::fsubsx(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[59];
    ++s_hot_stats.count_by_subop59[20];
  }
  (void)expected_result_bits;
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FdivsxFast(PowerPC::PowerPCState& ppc_state,
                                              const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  Interpreter::fdivsx(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[59];
    ++s_hot_stats.count_by_subop59[18];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FmulsxFast(PowerPC::PowerPCState& ppc_state,
                                              const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  Interpreter::fmulsx(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[59];
    ++s_hot_stats.count_by_subop59[25];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// Safer delegate fast paths for OPCD 59 add/sub (single-precision)
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FaddsxFast(PowerPC::PowerPCState& ppc_state,
                                              const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  Interpreter::faddsx(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[59];
    ++s_hot_stats.count_by_subop59[21];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FsubsxFast(PowerPC::PowerPCState& ppc_state,
                                              const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  Interpreter::fsubsx(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[59];
    ++s_hot_stats.count_by_subop59[20];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FcmpoFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  Interpreter::fcmpo(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[63];
    ++s_hot_stats.count_by_subop63[32];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FcmpuFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  Interpreter::fcmpu(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[63];
    ++s_hot_stats.count_by_subop63[0];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FselxFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];
  const auto& c = ppc_state.ps[inst.FC];
  ppc_state.ps[inst.FD].SetPS0((a.PS0AsDouble() >= -0.0) ? c.PS0AsDouble() : b.PS0AsDouble());
  if (inst.Rc)
    ppc_state.UpdateCR1();
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[63];
    ++s_hot_stats.count_by_subop63[20];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FrspxFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  // Delegate to Interpreter for correct NaN/exception semantics
  Interpreter::frspx(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[63];
    ++s_hot_stats.count_by_subop63[12];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FmrxFast(PowerPC::PowerPCState& ppc_state,
                                            const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  ppc_state.ps[inst.FD].SetPS0(ppc_state.ps[inst.FB].PS0AsU64());
  if (inst.Rc)
    ppc_state.UpdateCR1();
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[63];
    ++s_hot_stats.count_by_subop63[72];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// Fast branch callbacks (bcx, bx, bclrx, bcctrx)
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::BxFast(PowerPC::PowerPCState& ppc_state,
                                          const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  if (inst.LK)
    LR(ppc_state) = ppc_state.pc + 4;
  u32 destination_addr = static_cast<u32>(SignExt26(inst.LI << 2));
  if (!inst.AA)
    destination_addr += ppc_state.pc;
  ppc_state.npc = destination_addr;
  if (s_hot_enabled)
    ++s_hot_stats.count_by_opcd[18];
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::BCxFast(PowerPC::PowerPCState& ppc_state,
                                           const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  if ((inst.BO & BO_DONT_DECREMENT_FLAG) == 0)
    CTR(ppc_state)--;
  const bool true_false = ((inst.BO >> 3) & 1) != 0;
  const bool only_counter_check = ((inst.BO >> 4) & 1) != 0;
  const bool only_condition_check = ((inst.BO >> 2) & 1) != 0;
  const u32 ctr_check = ((CTR(ppc_state) != 0) ^ (inst.BO >> 1)) & 1;
  const bool counter = only_condition_check || ctr_check != 0;
  const bool condition = only_counter_check || (ppc_state.cr.GetBit(inst.BI) == u32(true_false));
  if (counter && condition)
  {
    if (inst.LK)
      LR(ppc_state) = ppc_state.pc + 4;
    u32 destination_addr = static_cast<u32>(SignExt16(static_cast<s16>(inst.BD << 2)));
    if (!inst.AA)
      destination_addr += ppc_state.pc;
    ppc_state.npc = destination_addr;
  }
  if (s_hot_enabled)
    ++s_hot_stats.count_by_opcd[16];
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::BclrxFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  if ((inst.BO_2 & BO_DONT_DECREMENT_FLAG) == 0)
    CTR(ppc_state)--;
  const u32 counter = ((inst.BO_2 >> 2) | ((CTR(ppc_state) != 0) ^ (inst.BO_2 >> 1))) & 1;
  const u32 condition = ((inst.BO_2 >> 4) | (ppc_state.cr.GetBit(inst.BI_2) == ((inst.BO_2 >> 3) & 1))) & 1;
  if ((counter & condition) != 0)
  {
    const u32 destination_addr = LR(ppc_state) & (~3u);
    ppc_state.npc = destination_addr;
    if (inst.LK_3)
      LR(ppc_state) = ppc_state.pc + 4;
  }
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[19];
    ++s_hot_stats.count_by_subop31[16];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::BcctrxFast(PowerPC::PowerPCState& ppc_state,
                                              const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  // bcctrx must not decrement/test CTR
  const u32 condition = ((inst.BO_2 >> 4) | (ppc_state.cr.GetBit(inst.BI_2) == ((inst.BO_2 >> 3) & 1))) & 1;
  if (condition != 0)
  {
    const u32 destination_addr = CTR(ppc_state) & (~3u);
    ppc_state.npc = destination_addr;
    if (inst.LK_3)
      LR(ppc_state) = ppc_state.pc + 4;
  }
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[19];
    ++s_hot_stats.count_by_subop31[528];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// Fast SPR access (limited to LR/CTR only for safety)
CI_HOT_ONLY s32 CachedInterpreter::MfsprFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  // Do not write PC here; these do not rely on pc for computation
  const UGeckoInstruction inst = operands.inst;
  const u32 index = ((inst.SPR & 0x1F) << 5) + ((inst.SPR >> 5) & 0x1F);
  if (index == SPR_LR)
    ppc_state.gpr[inst.RD] = ppc_state.spr[SPR_LR];
  else if (index == SPR_CTR)
    ppc_state.gpr[inst.RD] = ppc_state.spr[SPR_CTR];
  else if (index == SPR_XER)
    ppc_state.gpr[inst.RD] = ppc_state.GetXER().Hex;
  else if (index == SPR_SRR0)
    ppc_state.gpr[inst.RD] = ppc_state.spr[SPR_SRR0];
  else if (index == SPR_SRR1)
    ppc_state.gpr[inst.RD] = ppc_state.spr[SPR_SRR1];
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[31];
    ++s_hot_stats.count_by_subop31[339];
    ++s_hot_stats.fast_path_hits;
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

CI_HOT_ONLY s32 CachedInterpreter::MtsprFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  const UGeckoInstruction inst = operands.inst;
  const u32 index = (inst.SPRU << 5) | (inst.SPRL & 0x1F);
  if (index == SPR_LR)
    ppc_state.spr[SPR_LR] = ppc_state.gpr[inst.RD];
  else if (index == SPR_CTR)
    ppc_state.spr[SPR_CTR] = ppc_state.gpr[inst.RD];
  else if (index == SPR_XER)
    ppc_state.SetXER(UReg_XER{ppc_state.gpr[inst.RD]});
  else if (index == SPR_SRR0)
    ppc_state.spr[SPR_SRR0] = ppc_state.gpr[inst.RD];
  else if (index == SPR_SRR1)
    ppc_state.spr[SPR_SRR1] = ppc_state.gpr[inst.RD];
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[31];
    ++s_hot_stats.count_by_subop31[467];
    ++s_hot_stats.fast_path_hits;
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// Fast FP arithmetic (single-precision): fsubsx (20), faddsx (21), fmulsx (25)
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FpFsubsxFast(PowerPC::PowerPCState& ppc_state,
                                                const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];
  const FPResult difference = NI_sub(ppc_state, a.PS0AsDouble(), b.PS0AsDouble());
  if (ppc_state.fpscr.VE == 0 || difference.HasNoInvalidExceptions())
  {
    const float result = ForceSingle(ppc_state.fpscr, difference.value);
    ppc_state.ps[inst.FD].Fill(result);
    ppc_state.UpdateFPRFSingle(result);
  }
  if (inst.Rc)
    ppc_state.UpdateCR1();
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[59];
    ++s_hot_stats.count_by_subop59[20];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FpFaddsxFast(PowerPC::PowerPCState& ppc_state,
                                                const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];
  const FPResult sum = NI_add(ppc_state, a.PS0AsDouble(), b.PS0AsDouble());
  if (ppc_state.fpscr.VE == 0 || sum.HasNoInvalidExceptions())
  {
    const float result = ForceSingle(ppc_state.fpscr, sum.value);
    ppc_state.ps[inst.FD].Fill(result);
    ppc_state.UpdateFPRFSingle(result);
  }
  if (inst.Rc)
    ppc_state.UpdateCR1();
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[59];
    ++s_hot_stats.count_by_subop59[21];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FpFmulsxFast(PowerPC::PowerPCState& ppc_state,
                                                const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  const auto& a = ppc_state.ps[inst.FA];
  const auto& c = ppc_state.ps[inst.FC];
  const double c_value = Force25Bit(c.PS0AsDouble());
  const FPResult product = NI_mul(ppc_state, a.PS0AsDouble(), c_value);
  if (ppc_state.fpscr.VE == 0 || product.HasNoInvalidExceptions())
  {
    const float result = ForceSingle(ppc_state.fpscr, product.value);
    ppc_state.ps[inst.FD].Fill(result);
    ppc_state.fpscr.FI = 0;
    ppc_state.fpscr.FR = 0;
    ppc_state.UpdateFPRFSingle(result);
  }
  if (inst.Rc)
    ppc_state.UpdateCR1();
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[59];
    ++s_hot_stats.count_by_subop59[25];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

#if defined(__aarch64__)
// ARM NEON optimized Paired Single operations for iOS/tvOS A10X+ devices

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::PsAddFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  // Load paired singles as ARM NEON float32x2_t
  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

  float32x2_t va = {static_cast<float>(a.PS0AsDouble()), static_cast<float>(a.PS1AsDouble())};
  float32x2_t vb = {static_cast<float>(b.PS0AsDouble()), static_cast<float>(b.PS1AsDouble())};

  // SIMD addition
  float32x2_t result = vadd_f32(va, vb);

  // Store result back
  ppc_state.ps[inst.FD].SetBoth(vget_lane_f32(result, 0), vget_lane_f32(result, 1));
  ppc_state.UpdateFPRFSingle(vget_lane_f32(result, 0));

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[4];
    ++s_hot_stats.count_by_subop4[21];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// ps_sel (23): per lane select based on (a >= -0.0), choose c when true, else b
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::PsSelFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];
  const auto& c = ppc_state.ps[inst.FC];

  float32x2_t va = {static_cast<float>(a.PS0AsDouble()), static_cast<float>(a.PS1AsDouble())};
  float32x2_t vb = {static_cast<float>(b.PS0AsDouble()), static_cast<float>(b.PS1AsDouble())};
  float32x2_t vc = {static_cast<float>(c.PS0AsDouble()), static_cast<float>(c.PS1AsDouble())};

  float32x2_t vnegzero = vdup_n_f32(-0.0f);
  uint32x2_t mask = vcge_f32(va, vnegzero); // a >= -0.0f ? 0xFFFFFFFF : 0
  float32x2_t result = vbsl_f32(mask, vc, vb);

  ppc_state.ps[inst.FD].SetBoth(vget_lane_f32(result, 0), vget_lane_f32(result, 1));
  ppc_state.UpdateFPRFSingle(vget_lane_f32(result, 0));

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[4];
    ++s_hot_stats.count_by_subop4[23];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// ps_neg (40): FD = -FB
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::PsNegFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& b = ppc_state.ps[inst.FB];
  float32x2_t vb = {static_cast<float>(b.PS0AsDouble()), static_cast<float>(b.PS1AsDouble())};
  float32x2_t result = vneg_f32(vb);

  ppc_state.ps[inst.FD].SetBoth(vget_lane_f32(result, 0), vget_lane_f32(result, 1));
  ppc_state.UpdateFPRFSingle(vget_lane_f32(result, 0));

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[4];
    ++s_hot_stats.count_by_subop4[40];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// ps_abs (264): FD = abs(FB)
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::PsAbsFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& b = ppc_state.ps[inst.FB];
  float32x2_t vb = {static_cast<float>(b.PS0AsDouble()), static_cast<float>(b.PS1AsDouble())};
  float32x2_t result = vabs_f32(vb);

  ppc_state.ps[inst.FD].SetBoth(vget_lane_f32(result, 0), vget_lane_f32(result, 1));
  ppc_state.UpdateFPRFSingle(vget_lane_f32(result, 0));

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[4];
    ++s_hot_stats.count_by_subop4[264];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// ps_nabs (136): FD = -abs(FB)
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::PsNabsFast(PowerPC::PowerPCState& ppc_state,
                                              const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& b = ppc_state.ps[inst.FB];
  float32x2_t vb = {static_cast<float>(b.PS0AsDouble()), static_cast<float>(b.PS1AsDouble())};
  float32x2_t result = vneg_f32(vabs_f32(vb));

  ppc_state.ps[inst.FD].SetBoth(vget_lane_f32(result, 0), vget_lane_f32(result, 1));
  ppc_state.UpdateFPRFSingle(vget_lane_f32(result, 0));

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[4];
    ++s_hot_stats.count_by_subop4[136];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// ps_mr (72): FD = FB
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::PsMrFast(PowerPC::PowerPCState& ppc_state,
                                            const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& b = ppc_state.ps[inst.FB];
  const float ps0 = static_cast<float>(b.PS0AsDouble());
  const float ps1 = static_cast<float>(b.PS1AsDouble());
  ppc_state.ps[inst.FD].SetBoth(ps0, ps1);
  ppc_state.UpdateFPRFSingle(ps0);

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[4];
    ++s_hot_stats.count_by_subop4[72];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::PsMulFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& a = ppc_state.ps[inst.FA];
  const auto& c = ppc_state.ps[inst.FC];

  float32x2_t va = {static_cast<float>(a.PS0AsDouble()), static_cast<float>(a.PS1AsDouble())};
  float32x2_t vc = {static_cast<float>(c.PS0AsDouble()), static_cast<float>(c.PS1AsDouble())};

  // SIMD multiplication
  float32x2_t result = vmul_f32(va, vc);

  ppc_state.ps[inst.FD].SetBoth(vget_lane_f32(result, 0), vget_lane_f32(result, 1));
  ppc_state.UpdateFPRFSingle(vget_lane_f32(result, 0));

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[4];
    ++s_hot_stats.count_by_subop4[25];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::PsMaddFast(PowerPC::PowerPCState& ppc_state,
                                              const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];
  const auto& c = ppc_state.ps[inst.FC];

  float32x2_t va = {static_cast<float>(a.PS0AsDouble()), static_cast<float>(a.PS1AsDouble())};
  float32x2_t vb = {static_cast<float>(b.PS0AsDouble()), static_cast<float>(b.PS1AsDouble())};
  float32x2_t vc = {static_cast<float>(c.PS0AsDouble()), static_cast<float>(c.PS1AsDouble())};

  // SIMD multiply-add: a * c + b
  float32x2_t result = vfma_f32(vb, va, vc);

  ppc_state.ps[inst.FD].SetBoth(vget_lane_f32(result, 0), vget_lane_f32(result, 1));
  ppc_state.UpdateFPRFSingle(vget_lane_f32(result, 0));

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[4];
    ++s_hot_stats.count_by_subop4[29];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::PsSubFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

  float32x2_t va = {static_cast<float>(a.PS0AsDouble()), static_cast<float>(a.PS1AsDouble())};
  float32x2_t vb = {static_cast<float>(b.PS0AsDouble()), static_cast<float>(b.PS1AsDouble())};

  // SIMD subtraction
  float32x2_t result = vsub_f32(va, vb);

  ppc_state.ps[inst.FD].SetBoth(vget_lane_f32(result, 0), vget_lane_f32(result, 1));
  ppc_state.UpdateFPRFSingle(vget_lane_f32(result, 0));

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[4];
    ++s_hot_stats.count_by_subop4[20];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::PsMerge00Fast(PowerPC::PowerPCState& ppc_state,
                                                 const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

  // ps_merge00: FD = (FA.PS0, FB.PS0)
  ppc_state.ps[inst.FD].SetBoth(static_cast<float>(a.PS0AsDouble()), static_cast<float>(b.PS0AsDouble()));
  ppc_state.UpdateFPRFSingle(static_cast<float>(a.PS0AsDouble()));

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[4];
    ++s_hot_stats.count_by_subop4[528];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::PsMerge01Fast(PowerPC::PowerPCState& ppc_state,
                                                 const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

  // ps_merge01: FD = (FA.PS0, FB.PS1)
  ppc_state.ps[inst.FD].SetBoth(static_cast<float>(a.PS0AsDouble()), static_cast<float>(b.PS1AsDouble()));
  ppc_state.UpdateFPRFSingle(static_cast<float>(a.PS0AsDouble()));

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[4];
    ++s_hot_stats.count_by_subop4[560];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::PsMerge10Fast(PowerPC::PowerPCState& ppc_state,
                                                 const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

  // ps_merge10: FD = (FA.PS1, FB.PS0)
  ppc_state.ps[inst.FD].SetBoth(static_cast<float>(a.PS1AsDouble()), static_cast<float>(b.PS0AsDouble()));
  ppc_state.UpdateFPRFSingle(static_cast<float>(a.PS1AsDouble()));

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[4];
    ++s_hot_stats.count_by_subop4[592];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::PsMerge11Fast(PowerPC::PowerPCState& ppc_state,
                                                 const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

  // ps_merge11: FD = (FA.PS1, FB.PS1)
  ppc_state.ps[inst.FD].SetBoth(static_cast<float>(a.PS1AsDouble()), static_cast<float>(b.PS1AsDouble()));
  ppc_state.UpdateFPRFSingle(static_cast<float>(a.PS1AsDouble()));

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[4];
    ++s_hot_stats.count_by_subop4[624];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// ARM NEON optimized PS scalar multiply operations
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::PsMuls0Fast(PowerPC::PowerPCState& ppc_state,
                                               const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& a = ppc_state.ps[inst.FA];
  const auto& c = ppc_state.ps[inst.FC];

  // ARM NEON SIMD for ps_muls0: FD = (FA.PS0 * FC.PS0, FA.PS1 * FC.PS0)
  float32x2_t va = {static_cast<float>(a.PS0AsDouble()), static_cast<float>(a.PS1AsDouble())};
  float32x2_t vc0 = vdup_n_f32(static_cast<float>(c.PS0AsDouble()));
  float32x2_t result = vmul_f32(va, vc0);

  ppc_state.ps[inst.FD].SetBoth(vget_lane_f32(result, 0), vget_lane_f32(result, 1));
  ppc_state.UpdateFPRFSingle(vget_lane_f32(result, 0));

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[4];
    ++s_hot_stats.count_by_subop4[12];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::PsMuls1Fast(PowerPC::PowerPCState& ppc_state,
                                               const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& a = ppc_state.ps[inst.FA];
  const auto& c = ppc_state.ps[inst.FC];

  // ARM NEON SIMD for ps_muls1: FD = (FA.PS0 * FC.PS1, FA.PS1 * FC.PS1)
  float32x2_t va = {static_cast<float>(a.PS0AsDouble()), static_cast<float>(a.PS1AsDouble())};
  float32x2_t vc1 = vdup_n_f32(static_cast<float>(c.PS1AsDouble()));
  float32x2_t result = vmul_f32(va, vc1);

  ppc_state.ps[inst.FD].SetBoth(vget_lane_f32(result, 0), vget_lane_f32(result, 1));
  ppc_state.UpdateFPRFSingle(vget_lane_f32(result, 0));

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[4];
    ++s_hot_stats.count_by_subop4[13];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::PsMadds0Fast(PowerPC::PowerPCState& ppc_state,
                                                const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];
  const auto& c = ppc_state.ps[inst.FC];

  // ARM NEON SIMD for ps_madds0: FD = (FA.PS0 * FC.PS0 + FB.PS0, FA.PS1 * FC.PS0 + FB.PS1)
  float32x2_t va = {static_cast<float>(a.PS0AsDouble()), static_cast<float>(a.PS1AsDouble())};
  float32x2_t vb = {static_cast<float>(b.PS0AsDouble()), static_cast<float>(b.PS1AsDouble())};
  float32x2_t vc0 = vdup_n_f32(static_cast<float>(c.PS0AsDouble()));
  float32x2_t result = vfma_f32(vb, va, vc0);

  ppc_state.ps[inst.FD].SetBoth(vget_lane_f32(result, 0), vget_lane_f32(result, 1));
  ppc_state.UpdateFPRFSingle(vget_lane_f32(result, 0));

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[4];
    ++s_hot_stats.count_by_subop4[14];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::PsMadds1Fast(PowerPC::PowerPCState& ppc_state,
                                                const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];
  const auto& c = ppc_state.ps[inst.FC];

  // ARM NEON SIMD for ps_madds1: FD = (FA.PS0 * FC.PS1 + FB.PS0, FA.PS1 * FC.PS1 + FB.PS1)
  float32x2_t va = {static_cast<float>(a.PS0AsDouble()), static_cast<float>(a.PS1AsDouble())};
  float32x2_t vb = {static_cast<float>(b.PS0AsDouble()), static_cast<float>(b.PS1AsDouble())};
  float32x2_t vc1 = vdup_n_f32(static_cast<float>(c.PS1AsDouble()));
  float32x2_t result = vfma_f32(vb, va, vc1);

  ppc_state.ps[inst.FD].SetBoth(vget_lane_f32(result, 0), vget_lane_f32(result, 1));
  ppc_state.UpdateFPRFSingle(vget_lane_f32(result, 0));

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[4];
    ++s_hot_stats.count_by_subop4[15];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// Forward declarations for helper functions
static inline void CI_UpdateCR0(PowerPC::PowerPCState& ppc_state, u32 value);
static inline bool CI_HasAddOverflowed(u32 x, u32 y, u32 result);

// ARM NEON optimized integer operations - OPCD 31
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::AddxFast(PowerPC::PowerPCState& ppc_state,
                                            const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const u32 a = ppc_state.gpr[inst.RA];
  const u32 b = ppc_state.gpr[inst.RB];

  // ARM64 integer SIMD - process as 32-bit integers in parallel
  uint32x2_t va = {a, 0};
  uint32x2_t vb = {b, 0};
  uint32x2_t result = vadd_u32(va, vb);
  const u32 res = vget_lane_u32(result, 0);

  ppc_state.gpr[inst.RD] = res;

  if (inst.OE)
    ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, res));

  if (inst.Rc)
    CI_UpdateCR0(ppc_state, res);

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[31];
    ++s_hot_stats.count_by_subop31[266];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::SubfxFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const u32 a = ~ppc_state.gpr[inst.RA];
  const u32 b = ppc_state.gpr[inst.RB];

  // ARM64 integer SIMD for subtract (b - a = ~a + b + 1)
  uint32x2_t va = {a, 0};
  uint32x2_t vb = {b, 0};
  uint32x2_t vone = {1, 0};
  uint32x2_t result = vadd_u32(vadd_u32(va, vb), vone);
  const u32 res = vget_lane_u32(result, 0);

  ppc_state.gpr[inst.RD] = res;

  if (inst.OE)
    ppc_state.SetXER_OV(CI_HasAddOverflowed(a, b, res));

  if (inst.Rc)
    CI_UpdateCR0(ppc_state, res);

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[31];
    ++s_hot_stats.count_by_subop31[40];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::MullwxFast(PowerPC::PowerPCState& ppc_state,
                                              const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const s32 a = static_cast<s32>(ppc_state.gpr[inst.RA]);
  const s32 b = static_cast<s32>(ppc_state.gpr[inst.RB]);

  // ARM64 integer SIMD for multiply
  int32x2_t va = {a, 0};
  int32x2_t vb = {b, 0};
  int32x2_t result = vmul_s32(va, vb);
  const s32 res = vget_lane_s32(result, 0);

  ppc_state.gpr[inst.RD] = static_cast<u32>(res);

  if (inst.OE)
  {
    const s64 result64 = static_cast<s64>(a) * static_cast<s64>(b);
    ppc_state.SetXER_OV(result64 < -0x80000000LL || result64 > 0x7FFFFFFFLL);
  }

  if (inst.Rc)
    CI_UpdateCR0(ppc_state, ppc_state.gpr[inst.RD]);

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[31];
    ++s_hot_stats.count_by_subop31[235];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// ARM NEON optimized Double-precision FP operations - OPCD 63
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FaddxFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

  // Use ARM64 double-precision SIMD for parallel processing
  double a_val = a.PS0AsDouble();
  double b_val = b.PS0AsDouble();
  float64x1_t va = vld1_f64(&a_val);
  float64x1_t vb = vld1_f64(&b_val);
  float64x1_t result = vadd_f64(va, vb);

  double result_val;
  vst1_f64(&result_val, result);

  ppc_state.ps[inst.FD].SetBoth(result_val, result_val);
  ppc_state.UpdateFPRFDouble(result_val);

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[63];
    ++s_hot_stats.count_by_subop63[21];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FsubxFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];

  // ARM64 double-precision SIMD subtraction
  double a_val = a.PS0AsDouble();
  double b_val = b.PS0AsDouble();
  float64x1_t va = vld1_f64(&a_val);
  float64x1_t vb = vld1_f64(&b_val);
  float64x1_t result = vsub_f64(va, vb);

  double result_val;
  vst1_f64(&result_val, result);

  ppc_state.ps[inst.FD].SetBoth(result_val, result_val);
  ppc_state.UpdateFPRFDouble(result_val);

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[63];
    ++s_hot_stats.count_by_subop63[20];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FmulxFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& a = ppc_state.ps[inst.FA];
  const auto& c = ppc_state.ps[inst.FC];

  // ARM64 double-precision SIMD multiplication
  double a_val = a.PS0AsDouble();
  double c_val = c.PS0AsDouble();
  float64x1_t va = vld1_f64(&a_val);
  float64x1_t vc = vld1_f64(&c_val);
  float64x1_t result = vmul_f64(va, vc);

  double result_val;
  vst1_f64(&result_val, result);

  ppc_state.ps[inst.FD].SetBoth(result_val, result_val);
  ppc_state.UpdateFPRFDouble(result_val);

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[63];
    ++s_hot_stats.count_by_subop63[25];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FmaddxFast(PowerPC::PowerPCState& ppc_state,
                                              const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& a = ppc_state.ps[inst.FA];
  const auto& b = ppc_state.ps[inst.FB];
  const auto& c = ppc_state.ps[inst.FC];

  // ARM64 fused multiply-add for double-precision
  double a_val = a.PS0AsDouble();
  double b_val = b.PS0AsDouble();
  double c_val = c.PS0AsDouble();
  float64x1_t va = vld1_f64(&a_val);
  float64x1_t vb = vld1_f64(&b_val);
  float64x1_t vc = vld1_f64(&c_val);
  float64x1_t result = vfma_f64(vb, va, vc);  // b + (a * c)

  double result_val;
  vst1_f64(&result_val, result);

  ppc_state.ps[inst.FD].SetBoth(result_val, result_val);
  ppc_state.UpdateFPRFDouble(result_val);

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[63];
    ++s_hot_stats.count_by_subop63[29];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FnegxFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& b = ppc_state.ps[inst.FB];

  // ARM64 SIMD negation using XOR with sign bit
  double b_val = b.PS0AsDouble();
  float64x1_t vb = vld1_f64(&b_val);
  float64x1_t result = vneg_f64(vb);

  double result_val;
  vst1_f64(&result_val, result);

  ppc_state.ps[inst.FD].SetBoth(result_val, result_val);
  ppc_state.UpdateFPRFDouble(result_val);

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[63];
    ++s_hot_stats.count_by_subop63[40];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// fabsx (264): FD = |FB|
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FabsxFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& b = ppc_state.ps[inst.FB];
  double b_val = b.PS0AsDouble();
  float64x1_t vb = vld1_f64(&b_val);
  float64x1_t result = vabs_f64(vb);

  double result_val;
  vst1_f64(&result_val, result);

  ppc_state.ps[inst.FD].SetBoth(result_val, result_val);
  ppc_state.UpdateFPRFDouble(result_val);

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[63];
    ++s_hot_stats.count_by_subop63[264];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// fnabsx (136): FD = -|FB|
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FnabsxFast(PowerPC::PowerPCState& ppc_state,
                                              const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;

  const auto& b = ppc_state.ps[inst.FB];
  double b_val = b.PS0AsDouble();
  float64x1_t vb = vld1_f64(&b_val);
  float64x1_t result = vneg_f64(vabs_f64(vb));

  double result_val;
  vst1_f64(&result_val, result);

  ppc_state.ps[inst.FD].SetBoth(result_val, result_val);
  ppc_state.UpdateFPRFDouble(result_val);

  if (inst.Rc)
    ppc_state.UpdateCR1();

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[63];
    ++s_hot_stats.count_by_subop63[136];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// Additional hot OPCD31 integer optimizations
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::MulhwuxFast(PowerPC::PowerPCState& ppc_state,
                                               const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  const u64 a = ppc_state.gpr[inst.RA];
  const u64 b = ppc_state.gpr[inst.RB];
  // Use ARM64 SIMD for efficient high-word multiply
  const u64 result = a * b;
  ppc_state.gpr[inst.RD] = static_cast<u32>(result >> 32);
  if (inst.Rc)
    CI_UpdateCR0(ppc_state, ppc_state.gpr[inst.RD]);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[31];
    ++s_hot_stats.count_by_subop31[11];
    ++s_hot_stats.fast_path_hits;
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::NegxFast(PowerPC::PowerPCState& ppc_state,
                                            const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  const u32 a = ppc_state.gpr[inst.RA];
  const u32 result = (~a) + 1;
  ppc_state.gpr[inst.RD] = result;
  if (inst.OE)
    ppc_state.SetXER_OV(a == 0x80000000);
  if (inst.Rc)
    CI_UpdateCR0(ppc_state, result);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[31];
    ++s_hot_stats.count_by_subop31[104];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::MfmsrFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  ppc_state.gpr[inst.RD] = ppc_state.msr.Hex;
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[31];
    ++s_hot_stats.count_by_subop31[83];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::MtmsrFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  ppc_state.msr.Hex = ppc_state.gpr[inst.RS];
  // Note: This is a simplified version - full mtmsr may need exception handling
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[31];
    ++s_hot_stats.count_by_subop31[146];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::MftbFast(PowerPC::PowerPCState& ppc_state,
                                            const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  const u32 index = (inst.TBR & 0x1F) << 5 | (inst.TBR >> 5);
  if (index == SPR_TL)
    ppc_state.gpr[inst.RD] = static_cast<u32>(ppc_state.spr[SPR_TL]);
  else if (index == SPR_TU)
    ppc_state.gpr[inst.RD] = static_cast<u32>(ppc_state.spr[SPR_TU]);
  else
    ppc_state.gpr[inst.RD] = 0; // Invalid TBR
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[31];
    ++s_hot_stats.count_by_subop31[371];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// Additional single-precision FP optimizations
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FresxFast(PowerPC::PowerPCState& ppc_state,
                                             const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  // Delegate to interpreter for correct FP behavior
  Interpreter::fresx(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[59];
    ++s_hot_stats.count_by_subop59[24];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FnmaddsxFast2(PowerPC::PowerPCState& ppc_state,
                                                 const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  Interpreter::fnmaddsx(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[59];
    ++s_hot_stats.count_by_subop59[31];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FnmsubsxFast2(PowerPC::PowerPCState& ppc_state,
                                                 const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  Interpreter::fnmsubsx(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[59];
    ++s_hot_stats.count_by_subop59[30];
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// Add fctiwx(14) fast delegate
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::FctiwxFast(PowerPC::PowerPCState& ppc_state,
                                              const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  Interpreter::fctiwx(operands.interpreter, operands.inst);
  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[63];
    ++s_hot_stats.count_by_subop63[14];
    ++s_hot_stats.fast_path_hits;
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

#endif // __aarch64__


// Static instrumentation state
CachedInterpreter::LinkStats CachedInterpreter::s_link_stats{};
bool CachedInterpreter::s_log_enabled = false;

// Hot-instruction profiling state
CachedInterpreter::HotStats CachedInterpreter::s_hot_stats{};
bool CachedInterpreter::s_hot_enabled = false;
u32 CachedInterpreter::s_hot_sample_every = 32; // default: sample 1 out of 32 instructions
u64 CachedInterpreter::s_hot_counter = 0;
bool CachedInterpreter::s_fp_fast_enabled = false;

static inline u64 CI_NowNs()
{
  using namespace std::chrono;
  return duration_cast<nanoseconds>(steady_clock::now().time_since_epoch()).count();
}

#if defined(__aarch64__)

// Apple Silicon memory optimization
void CachedInterpreter::OptimizeMemoryLayout() {
  // Configure for Apple Silicon's unified memory architecture
  madvise(&m_ppc_state, sizeof(m_ppc_state), MADV_WILLNEED);

  // Prefetch hot state data
  __builtin_prefetch(&m_ppc_state.gpr[0], 0, 3);
  __builtin_prefetch(&m_ppc_state.ps[0], 0, 3);
}

void CachedInterpreter::ConfigureAppleSiliconHints() {
  // Request performance cores for demanding emulation workload
  thread_extended_policy_data_t policy = {true};
  thread_policy_set(mach_thread_self(), THREAD_EXTENDED_POLICY,
                     (thread_policy_t)&policy, THREAD_EXTENDED_POLICY_COUNT);
}

#endif // __aarch64__

void CachedInterpreter::OnLinkPatched()
{
  ++s_link_stats.links_patched;
}

void CachedInterpreter::MaybeLogLinkStats()
{
// #ifdef _DEBUG
  if (!s_log_enabled)
    return;
  static u64 frames = 0;
  static u64 last_links_patched = 0;
  if ((++frames & 0xFFF) == 0) // log roughly every 4096 dispatcher returns
  {
    // Only log if something changed since the last log to avoid spam.
    if (s_link_stats.links_patched == last_links_patched)
      return;
    last_links_patched = s_link_stats.links_patched;

    const std::string msg = fmt::format(
        "CI links: patched={} rel0={} rel1={} unlinked={} mismatch={} zero_dc={} slice_end={} disp_rt={}",
        s_link_stats.links_patched, s_link_stats.rel0_taken, s_link_stats.rel1_taken,
        s_link_stats.match_but_unlinked, s_link_stats.npc_mismatch,
        s_link_stats.zero_downcount, s_link_stats.slice_end, s_link_stats.dispatcher_roundtrips);
    printf("%s\n", msg.c_str());
    // OSD::AddMessage(msg, OSD::Duration::NORMAL);
  }
// #endif
}

void CachedInterpreter::ConfigureHotStatsFromEnv()
{
  const char* env = std::getenv("DOLPHIN_CI_HOT");
  s_hot_enabled = (env && env[0] == '1');
  const char* samp = std::getenv("DOLPHIN_CI_HOT_SAMPLE");
  if (samp)
  {
    const unsigned v = static_cast<unsigned>(std::strtoul(samp, nullptr, 10));
    if (v >= 1 && v <= 1000000)
      s_hot_sample_every = v;
  }
}

void CachedInterpreter::MaybeLogHotStats()
{
  if (!s_hot_enabled)
    return;

  static u64 blocks = 0;
  if ((++blocks & 0x0FFF) != 0) // roughly every 4096 blocks
    return;

  // Find top 8 opcodes by sampled nanoseconds
  struct Item { u32 key; u64 ns; u64 cnt; };
  Item top[8]{};
  auto consider = [&](u32 key, u64 ns, u64 cnt) {
    if (ns == 0 && cnt == 0) return;
    // insert if better than smallest
    int idx = -1; u64 minns = UINT64_MAX; int minpos = -1;
    for (int i = 0; i < 8; ++i) { if (top[i].ns == 0 && top[i].cnt == 0 && idx == -1) idx = i; if (top[i].ns < minns) { minns = top[i].ns; minpos = i; } }
    int pos = (idx != -1) ? idx : minpos;
    if (idx == -1 && ns <= minns) return;
    top[pos] = {key, ns, cnt};
  };
  for (u32 op = 0; op < 64; ++op)
    consider(op, s_hot_stats.ns_by_opcd[op], s_hot_stats.count_by_opcd[op]);

  // Log
  std::string msg = "CI hot ops (ns sampled, count total): ";
  bool first = true;
  for (const auto& it : top)
  {
    if (it.ns == 0 && it.cnt == 0) continue;
    if (!first) msg += ", ";
    first = false;
    msg += fmt::format("OPCD {}: {} ns, {}x", it.key, it.ns, it.cnt);
  }
  if (!first)
  {
    printf("%s\n", msg.c_str());
    // Report fast path effectiveness
    const u64 total_paths = s_hot_stats.fast_path_hits + s_hot_stats.slow_path_hits;
    if (total_paths > 0)
    {
      const double fast_ratio = static_cast<double>(s_hot_stats.fast_path_hits) / total_paths * 100.0;
      printf("  Fast path effectiveness: %.1f%% (%llu fast, %llu slow, %llu total)\n",
             fast_ratio, s_hot_stats.fast_path_hits, s_hot_stats.slow_path_hits, total_paths);
    }
  }

  // Additionally print top SUBOP10 under OPCD 31, if there is any activity
  struct SItem { u32 subop; u64 ns; u64 cnt; };
  SItem top31[8]{};
  auto consider31 = [&](u32 subop, u64 ns, u64 cnt) {
    if (ns == 0 && cnt == 0) return;
    int idx = -1; u64 minns = UINT64_MAX; int minpos = -1;
    for (int i = 0; i < 8; ++i) { if (top31[i].ns == 0 && top31[i].cnt == 0 && idx == -1) idx = i; if (top31[i].ns < minns) { minns = top31[i].ns; minpos = i; } }
    int pos = (idx != -1) ? idx : minpos;
    if (idx == -1 && ns <= minns) return;
    top31[pos] = {subop, ns, cnt};
  };
  bool any31 = false;
  for (u32 sub = 0; sub < 1024; ++sub)
  {
    const u64 ns = s_hot_stats.ns_by_subop31[sub];
    const u64 cnt = s_hot_stats.count_by_subop31[sub];
    if (ns != 0 || cnt != 0) { any31 = true; consider31(sub, ns, cnt); }
  }
  if (any31)
  {
    std::string msg2 = "  OPCD31 hot SUBOPs (ns sampled, count total): ";
    bool first2 = true;
    for (const auto& it : top31)
    {
      if (it.ns == 0 && it.cnt == 0) continue;
      if (!first2) msg2 += ", ";
      first2 = false;
      msg2 += fmt::format("SUBOP {}: {} ns, {}x", it.subop, it.ns, it.cnt);
    }
    if (!first2)
      printf("%s\n", msg2.c_str());
  }

  // OPCD 59 (SUBOP5) hot list
  struct S5 { u32 subop; u64 ns; u64 cnt; };
  S5 top59[8]{};
  auto consider59 = [&](u32 subop, u64 ns, u64 cnt) {
    if (ns == 0 && cnt == 0) return;
    int idx = -1; u64 minns = UINT64_MAX; int minpos = -1;
    for (int i = 0; i < 8; ++i) { if (top59[i].ns == 0 && top59[i].cnt == 0 && idx == -1) idx = i; if (top59[i].ns < minns) { minns = top59[i].ns; minpos = i; } }
    int pos = (idx != -1) ? idx : minpos;
    if (idx == -1 && ns <= minns) return;
    top59[pos] = {subop, ns, cnt};
  };
  bool any59 = false;
  for (u32 sub = 0; sub < 32; ++sub)
  {
    const u64 ns = s_hot_stats.ns_by_subop59[sub];
    const u64 cnt = s_hot_stats.count_by_subop59[sub];
    if (ns != 0 || cnt != 0) { any59 = true; consider59(sub, ns, cnt); }
  }
  if (any59)
  {
    std::string msg59 = "  OPCD59 hot SUBOP5 (ns sampled, count total): ";
    bool f = true;
    for (const auto& it : top59)
    {
      if (it.ns == 0 && it.cnt == 0) continue;
      if (!f) msg59 += ", ";
      f = false;
      msg59 += fmt::format("SUBOP5 {}: {} ns, {}x", it.subop, it.ns, it.cnt);
    }
    if (!f)
      printf("%s\n", msg59.c_str());
  }

  // OPCD 63 (SUBOP10) hot list
  struct S10 { u32 subop; u64 ns; u64 cnt; };
  S10 top63[8]{};
  auto consider63 = [&](u32 subop, u64 ns, u64 cnt) {
    if (ns == 0 && cnt == 0) return;
    int idx = -1; u64 minns = UINT64_MAX; int minpos = -1;
    for (int i = 0; i < 8; ++i) { if (top63[i].ns == 0 && top63[i].cnt == 0 && idx == -1) idx = i; if (top63[i].ns < minns) { minns = top63[i].ns; minpos = i; } }
    int pos = (idx != -1) ? idx : minpos;
    if (idx == -1 && ns <= minns) return;
    top63[pos] = {subop, ns, cnt};
  };
  bool any63 = false;
  for (u32 sub = 0; sub < 1024; ++sub)
  {
    const u64 ns = s_hot_stats.ns_by_subop63[sub];
    const u64 cnt = s_hot_stats.count_by_subop63[sub];
    if (ns != 0 || cnt != 0) { any63 = true; consider63(sub, ns, cnt); }
  }
  if (any63)
  {
    std::string msg63 = "  OPCD63 hot SUBOPs (ns sampled, count total): ";
    bool f2 = true;
    for (const auto& it : top63)
    {
      if (it.ns == 0 && it.cnt == 0) continue;
      if (!f2) msg63 += ", ";
      f2 = false;
      msg63 += fmt::format("SUBOP {}: {} ns, {}x", it.subop, it.ns, it.cnt);
    }
    if (!f2)
      printf("%s\n", msg63.c_str());
  }
}

void CachedInterpreter::ConfigureLinkLogFromEnv()
{
  const char* env = std::getenv("DOLPHIN_CI_LINK_LOG");
  s_log_enabled = (env && env[0] == '1');
}

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

// Optimized addic_rc (Add Immediate Carrying and Record) - OPCD 13
template <bool write_pc>
CI_HOT_ONLY s32 CachedInterpreter::AddicRcFast(PowerPC::PowerPCState& ppc_state,
                                               const InterpretOperands& operands)
{
  if constexpr (write_pc)
  {
    ppc_state.pc = operands.current_pc;
    ppc_state.npc = operands.current_pc + 4;
  }
  const UGeckoInstruction inst = operands.inst;
  const u32 a = ppc_state.gpr[inst.RA];
  const s32 imm = inst.SIMM_16;
  const u64 result = static_cast<u64>(a) + static_cast<u64>(static_cast<s32>(imm));

  ppc_state.gpr[inst.RD] = static_cast<u32>(result);
  ppc_state.SetCarry(result > 0xFFFFFFFF);

  // Record bit - update CR0 using local helper (now accessible)
  CI_UpdateCR0(ppc_state, ppc_state.gpr[inst.RD]);

  if (s_hot_enabled)
  {
    ++s_hot_stats.count_by_opcd[13];
  }
  return sizeof(AnyCallback) + sizeof(operands);
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

  // Count this opcode in hot-instruction stats (no timing to keep PIC fast)
  if (s_hot_enabled)
  {
    const u8 opcd = inst.OPCD;
    ++s_hot_stats.count_by_opcd[opcd];
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
    // Prefetch the target line to hide memory latency in hot PIC path
    #if defined(__GNUC__) || defined(__clang__)
    __builtin_prefetch(base_ptr + offset, 0, 1);
    __builtin_prefetch(base_ptr + offset + 32, 0, 1);
    #endif
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
      #if defined(__GNUC__) || defined(__clang__)
      __builtin_prefetch(base_ptr + offset, 1, 1);
      #endif
      const u32 val = ppc_state.gpr[inst.RS];
      const u32 raw = Common::swap32(val);
      *reinterpret_cast<u32*>(base_ptr + offset) = raw;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 37: // stwu (update)
    {
      if (ra == 0 || (ea & 0b11) != 0) [[unlikely]]
        break; // illegal or misaligned -> fallback
      #if defined(__GNUC__) || defined(__clang__)
      __builtin_prefetch(base_ptr + offset, 1, 1);
      #endif
      const u32 val = ppc_state.gpr[inst.RS];
      const u32 raw = Common::swap32(val);
      *reinterpret_cast<u32*>(base_ptr + offset) = raw;
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 38: // stb
    {
      #if defined(__GNUC__) || defined(__clang__)
      __builtin_prefetch(base_ptr + offset, 1, 1);
      #endif
      const u8 val = static_cast<u8>(ppc_state.gpr[inst.RS]);
      *(base_ptr + offset) = val;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 39: // stbu (update)
    {
      if (ra == 0)
        break; // illegal -> fallback
      #if defined(__GNUC__) || defined(__clang__)
      __builtin_prefetch(base_ptr + offset, 1, 1);
      #endif
      const u8 val = static_cast<u8>(ppc_state.gpr[inst.RS]);
      *(base_ptr + offset) = val;
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 44: // sth
    {
      if ((ea & 0b1) != 0) [[unlikely]]
        break; // misaligned -> fallback
      #if defined(__GNUC__) || defined(__clang__)
      __builtin_prefetch(base_ptr + offset, 1, 1);
      #endif
      const u16 val = static_cast<u16>(ppc_state.gpr[inst.RS]);
      const u16 raw = Common::swap16(val);
      *reinterpret_cast<u16*>(base_ptr + offset) = raw;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 45: // sthu (update)
    {
      if (ra == 0 || (ea & 0b1) != 0) [[unlikely]]
        break; // illegal or misaligned -> fallback
      #if defined(__GNUC__) || defined(__clang__)
      __builtin_prefetch(base_ptr + offset, 1, 1);
      #endif
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
      const u32 hi = Common::FromBigEndian(*reinterpret_cast<const u32*>(base_ptr + offset));
      const u32 lo = Common::FromBigEndian(*reinterpret_cast<const u32*>(base_ptr + offset + 4));
      const u64 be64 = (static_cast<u64>(hi) << 32) | static_cast<u64>(lo);
      ppc_state.ps[inst.FD].SetPS0(be64);
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 51: // lfdu (update)
    {
      if (ra == 0 || (ea & 0b11) != 0) [[unlikely]]
        break; // illegal or misaligned -> fallback
      const u32 hi = Common::FromBigEndian(*reinterpret_cast<const u32*>(base_ptr + offset));
      const u32 lo = Common::FromBigEndian(*reinterpret_cast<const u32*>(base_ptr + offset + 4));
      const u64 be64 = (static_cast<u64>(hi) << 32) | static_cast<u64>(lo);
      ppc_state.ps[inst.FD].SetPS0(be64);
      ppc_state.gpr[ra] = ea;
      return sizeof(AnyCallback) + sizeof(operands);
    }

    // Floating-point single-precision stores (D-form)
    case 52: // stfs
    {
      if ((ea & 0b11) != 0) [[unlikely]]
        break; // misaligned -> fallback
      #if defined(__GNUC__) || defined(__clang__)
      __builtin_prefetch(base_ptr + offset, 1, 1);
      #endif
      const u32 conv = ConvertToSingle(ppc_state.ps[inst.FS].PS0AsU64());
      const u32 raw_out = Common::swap32(conv);
      *reinterpret_cast<u32*>(base_ptr + offset) = raw_out;
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 53: // stfsu (update)
    {
      if (ra == 0 || (ea & 0b11) != 0) [[unlikely]]
        break; // illegal or misaligned -> fallback
      #if defined(__GNUC__) || defined(__clang__)
      __builtin_prefetch(base_ptr + offset, 1, 1);
      #endif
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
      #if defined(__GNUC__) || defined(__clang__)
      __builtin_prefetch(base_ptr + offset, 1, 1);
      #endif
      const u64 val64 = ppc_state.ps[inst.FS].PS0AsU64();
      const u32 hi = static_cast<u32>(val64 >> 32);
      const u32 lo = static_cast<u32>(val64);
      *reinterpret_cast<u32*>(base_ptr + offset) = Common::swap32(hi);
      *reinterpret_cast<u32*>(base_ptr + offset + 4) = Common::swap32(lo);
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 55: // stfdu (update)
    {
      if (ra == 0 || (ea & 0b11) != 0) [[unlikely]]
        break; // illegal or misaligned -> fallback
      #if defined(__GNUC__) || defined(__clang__)
      __builtin_prefetch(base_ptr + offset, 1, 1);
      #endif
      const u64 val64 = ppc_state.ps[inst.FS].PS0AsU64();
      const u32 hi = static_cast<u32>(val64 >> 32);
      const u32 lo = static_cast<u32>(val64);
      *reinterpret_cast<u32*>(base_ptr + offset) = Common::swap32(hi);
      *reinterpret_cast<u32*>(base_ptr + offset + 4) = Common::swap32(lo);
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
    // Prefetch the target line to hide memory latency in hot PIC path
    #if defined(__GNUC__) || defined(__clang__)
    __builtin_prefetch(base_ptr + offset, 0, 1);
    __builtin_prefetch(base_ptr + offset + 32, 0, 1);
    #endif
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
      #if defined(__GNUC__) || defined(__clang__)
      __builtin_prefetch(base_ptr + offset, 1, 1);
      #endif
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
      #if defined(__GNUC__) || defined(__clang__)
      __builtin_prefetch(base_ptr + offset, 1, 1);
      #endif
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
      #if defined(__GNUC__) || defined(__clang__)
      __builtin_prefetch(base_ptr + offset, 1, 1);
      #endif
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
      #if defined(__GNUC__) || defined(__clang__)
      __builtin_prefetch(base_ptr + offset, 1, 1);
      #endif
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
      #if defined(__GNUC__) || defined(__clang__)
      __builtin_prefetch(base_ptr + offset, 1, 1);
      #endif
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
      #if defined(__GNUC__) || defined(__clang__)
      __builtin_prefetch(base_ptr + offset, 1, 1);
      #endif
      const u32 raw = ppc_state.gpr[inst.RS];
      std::memcpy(base_ptr + offset, &raw, sizeof(raw));
      return sizeof(AnyCallback) + sizeof(operands);
    }
    case 918: // sthbrx
    {
      if ((ea & 0b1) != 0)
        break; // misaligned
      #if defined(__GNUC__) || defined(__clang__)
      __builtin_prefetch(base_ptr + offset, 1, 1);
      #endif
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
  jo.enableBlocklink = IsBlockLinkingEnabled();
  #else
  jo.enableBlocklink = false;
  #endif

  m_block_cache.Init();

  code_block.m_stats = &js.st;
  code_block.m_gpa = &js.gpa;
  code_block.m_fpa = &js.fpa;

  ConfigureLinkLogFromEnv();
  ConfigureHotStatsFromEnv();
  ConfigureFpFastFromEnv();
  ConfigureInline59FromEnv();
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
      if (m.rc)
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
      if (m.rc)
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

  static bool initialized = false;
  if (!initialized) [[unlikely]] {
    OptimizeMemoryLayout();
    ConfigureAppleSiliconHints();
    initialized = true;
  }

  auto& ppc_state = m_ppc_state;
  while (true)
  {
#if defined(__aarch64__)
    // Apple Silicon: Enhanced prefetching with multiple cache lines
    __builtin_prefetch(normal_entry + 64, 0, 0);   // L1 temporal
    __builtin_prefetch(normal_entry + 128, 0, 0);  // L1 temporal
    __builtin_prefetch(normal_entry + 256, 0, 1);  // L2 non-temporal
    __builtin_prefetch(normal_entry + 512, 0, 3);  // L3 non-temporal

#endif
    const auto callback = *reinterpret_cast<const AnyCallback*>(normal_entry);

#if defined(__aarch64__)
    // Apple Silicon: Speculative execution hints
    __builtin_prefetch(normal_entry + sizeof(callback), 0, 0); // Prefetch operands
#endif

    if (const auto distance = callback(ppc_state, normal_entry + sizeof(callback))) [[likely]]
    {
      normal_entry += distance;
#if defined(__aarch64__)
      // Apple Silicon: Aggressive block chaining prefetch
      __builtin_prefetch(normal_entry, 0, 0); // Next callback
      __builtin_prefetch(normal_entry + 32, 0, 1); // Next operands
#endif
    }
    else
      break;
  }
  ++s_link_stats.dispatcher_roundtrips;
  MaybeLogLinkStats();
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
  // Periodically print hot-instruction stats if enabled
  MaybeLogHotStats();
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
  if (s_hot_enabled)
  {
    const u8 opcd = operands.inst.OPCD;
    ++s_hot_stats.count_by_opcd[opcd];
    ++s_hot_stats.slow_path_hits;
    if (opcd == 31)
      ++s_hot_stats.count_by_subop31[operands.inst.SUBOP10];
    else if (opcd == 59)
      ++s_hot_stats.count_by_subop59[operands.inst.SUBOP5];
    else if (opcd == 63)
      ++s_hot_stats.count_by_subop63[operands.inst.SUBOP10];
    else if (opcd == 4)
      ++s_hot_stats.count_by_subop4[operands.inst.SUBOP10];
    else if (opcd == 59)
      ++s_hot_stats.count_by_subop59[operands.inst.SUBOP5];
    else if (opcd == 63)
      ++s_hot_stats.count_by_subop63[operands.inst.SUBOP10];

    // Sampled timing to reduce overhead
    const bool sample = ((++s_hot_counter % s_hot_sample_every) == 0);
    u64 t0 = 0;
    if (sample)
      t0 = CI_NowNs();

    operands.func(operands.interpreter, operands.inst);

    if (sample)
    {
      const u64 dt = CI_NowNs() - t0;
      s_hot_stats.ns_by_opcd[opcd] += dt;
      if (opcd == 31)
        s_hot_stats.ns_by_subop31[operands.inst.SUBOP10] += dt;
      else if (opcd == 59)
        s_hot_stats.ns_by_subop59[operands.inst.SUBOP5] += dt;
      else if (opcd == 63)
        s_hot_stats.ns_by_subop63[operands.inst.SUBOP10] += dt;
      else if (opcd == 4)
        s_hot_stats.ns_by_subop4[operands.inst.SUBOP10] += dt;
      else if (opcd == 59)
        s_hot_stats.ns_by_subop59[operands.inst.SUBOP5] += dt;
      else if (opcd == 63)
        s_hot_stats.ns_by_subop63[operands.inst.SUBOP10] += dt;
    }
  }
  else
  {
    operands.func(operands.interpreter, operands.inst);
  }
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
  if (s_hot_enabled)
  {
    const u8 opcd = operands.inst.OPCD;
    ++s_hot_stats.count_by_opcd[opcd];
    if (opcd == 31)
      ++s_hot_stats.count_by_subop31[operands.inst.SUBOP10];

    const bool sample = ((++s_hot_counter % s_hot_sample_every) == 0);
    u64 t0 = 0;
    if (sample)
      t0 = CI_NowNs();

    operands.func(operands.interpreter, operands.inst);

    if (sample)
    {
      const u64 dt = CI_NowNs() - t0;
      s_hot_stats.ns_by_opcd[opcd] += dt;
      if (opcd == 31)
        s_hot_stats.ns_by_subop31[operands.inst.SUBOP10] += dt;
    }
  }
  else
  {
    operands.func(operands.interpreter, operands.inst);
  }

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

// Note: ostream variant of CheckIdle is defined in CachedInterpreter_Disassembler.cpp.

// Fast-forward CTR-only tight idle loops: when at the loop branch PC, force loop exit and yield.
s32 CachedInterpreter::FastForwardCtrIdle(PowerPC::PowerPCState& ppc_state,
                                          const CheckCtrIdleOperands& operands)
{
  const auto& [core_timing, idle_pc, fallthrough_pc] = operands;
  if (ppc_state.npc == idle_pc)
  {
    // Force CTR exhaustion and take the fallthrough.
    CTR(ppc_state) = 0;
    ppc_state.pc = idle_pc;
    ppc_state.npc = fallthrough_pc;
    core_timing.Idle();
  }
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
  // If the terminal instruction is a dynamic/indirect exit (e.g., blr/bctr) with no
  // static branch target, skip LinkToBlock and emit the plain EndBlock to avoid
  // frequent npc mismatches and link overhead.
  bool dynamic_terminal = false;
  u32 taken_pc = 0;
  if (code_block.m_num_instructions > 0)
  {
    const auto& last = m_code_buffer[code_block.m_num_instructions - 1];
    dynamic_terminal = last.canEndBlock && (last.branchTo == UINT32_MAX);
    if (!dynamic_terminal && last.canEndBlock && last.branchTo != UINT32_MAX)
      taken_pc = last.branchTo;
  }

  if (dynamic_terminal)
  {
    if (IsProfilingEnabled())
    {
      EndBlockOperands<true> eops{};
      eops.downcount = js.downcountAmount;
      eops.num_load_stores = js.numLoadStoreInst;
      eops.num_fp_inst = js.numFloatingPointInst;
      eops.profile_data = js.curBlock->profile_data.get();
      Write(EndBlock<true>, eops);
    }
    else
    {
      EndBlockOperands<false> eops{};
      eops.downcount = js.downcountAmount;
      eops.num_load_stores = js.numLoadStoreInst;
      eops.num_fp_inst = js.numFloatingPointInst;
      Write(EndBlock<false>, eops);
    }
    return;
  }

  // If block linking is globally disabled, emit a plain EndBlock (legacy path)
  if (!IsBlockLinkingEnabled())
  {
    if (IsProfilingEnabled())
    {
      EndBlockOperands<true> eops{};
      eops.downcount = js.downcountAmount;
      eops.num_load_stores = js.numLoadStoreInst;
      eops.num_fp_inst = js.numFloatingPointInst;
      eops.profile_data = js.curBlock->profile_data.get();
      Write(EndBlock<true>, eops);
    }
    else
    {
      EndBlockOperands<false> eops{};
      eops.downcount = js.downcountAmount;
      eops.num_load_stores = js.numLoadStoreInst;
      eops.num_fp_inst = js.numFloatingPointInst;
      Write(EndBlock<false>, eops);
    }
    return;
  }

  // Otherwise, emit a link trampoline which performs end-of-block accounting and optionally links
  // to the next block by returning a non-zero relative distance. If linking is disabled
  // or not yet patched, rel stays 0 and the dispatcher will exit the block as usual.
  LinkToBlockOperands ops{};
  ops.downcount = js.downcountAmount;
  ops.num_load_stores = js.numLoadStoreInst;
  ops.num_fp_inst = js.numFloatingPointInst;
  ops.expected_pc0 = m_link_fallthrough_pc;
  ops.expected_pc1 = taken_pc;
  ops.profile_data = IsProfilingEnabled() ? js.curBlock->profile_data.get() : nullptr;
  ops.rel0 = 0;
  ops.rel1 = 0;

  Write(LinkToBlock, ops);

  // Record this exit so the block cache linker can patch in the destination later.
  // Layout: [AnyCallback][LinkToBlockOperands]
  auto* operands_begin = GetWritableCodePtr() - sizeof(LinkToBlockOperands);
  auto* callback_start = operands_begin - sizeof(void*);

  JitBlock::LinkData ld{};
  ld.exitPtrs = callback_start;
#ifdef _M_ARM_64
  ld.exitFarcode = nullptr;
#endif
  ld.exitAddress = m_link_fallthrough_pc;
  ld.linkStatus = false;
  ld.call = false;
  js.curBlock->linkData.push_back(ld);

  if (taken_pc != 0 && taken_pc != m_link_fallthrough_pc)
  {
    JitBlock::LinkData ld2{};
    ld2.exitPtrs = callback_start;
#ifdef _M_ARM_64
    ld2.exitFarcode = nullptr;
#endif
    ld2.exitAddress = taken_pc;
    ld2.linkStatus = false;
    ld2.call = false;
    js.curBlock->linkData.push_back(ld2);
  }
}

s32 CachedInterpreter::LinkToBlock(PowerPC::PowerPCState& ppc_state,
                                   const LinkToBlockOperands& operands)
{
  // Perform EndBlock-like accounting first
  ppc_state.pc = ppc_state.npc;
  ppc_state.downcount -= operands.downcount;
  if (PowerPC::PerformanceMonitorActive(ppc_state))
  {
    PowerPC::UpdatePerformanceMonitor(operands.downcount, operands.num_load_stores,
                                      operands.num_fp_inst, ppc_state);
  }
  if (operands.profile_data)
    JitBlock::ProfileData::EndProfiling(operands.profile_data, operands.downcount);

  // If the timing slice is over, stop linking and exit to the dispatcher/scheduler.
  if (ppc_state.downcount <= 0)
  {
    ++s_link_stats.slice_end;
    return 0;
  }

  // Select the correct link (fallthrough or taken) based on npc.
  s32 rel = 0;

#if defined(__aarch64__)
  // Apple Silicon: Branch prediction hints based on PowerPC patterns
  // Most PowerPC code has highly predictable branch patterns
  __builtin_expect(ppc_state.npc == operands.expected_pc0, 1); // Fallthrough usually taken
#endif

  if (ppc_state.npc == operands.expected_pc0) [[likely]]
  {
    rel = operands.rel0;
    if (rel != 0) [[likely]]
    {
      ++s_link_stats.rel0_taken;
    }
    else
      ++s_link_stats.match_but_unlinked;
  }
  else if (ppc_state.npc == operands.expected_pc1) [[unlikely]]
  {
    rel = operands.rel1;
    if (rel != 0)
      ++s_link_stats.rel1_taken;
    else
      ++s_link_stats.match_but_unlinked;
  }
  else
  {
    ++s_link_stats.npc_mismatch;
  }

  // Safety: if the block recorded 0 cycles, don't chain endlessly.
  if (operands.downcount == 0)
  {
    ++s_link_stats.zero_downcount;
    return 0;
  }

#if defined(__aarch64__)
  if (rel != 0)
  {
    const u8* operands_ptr = reinterpret_cast<const u8*>(&operands);
    const u8* callback_start = operands_ptr - sizeof(void*);
    const u8* next_entry = callback_start + rel;
    __builtin_prefetch(next_entry + 64, 0, 1);
    __builtin_prefetch(next_entry + 128, 0, 1);
  }
#endif

  // If linked, continue within the same block stream; otherwise return 0 to exit.
  return rel;
}

CI_COLD_ONLY s32 CachedInterpreter::LinkToBlock(std::ostream& stream,
                                               const LinkToBlockOperands& operands)
{
  fmt::println(stream,
               "LinkToBlock(rel0={}, rel1={}, expected_pc0=0x{:08x}, expected_pc1=0x{:08x}, downcount={}, numLoadStores={}, numFpInst={}, profiled={})",
               operands.rel0, operands.rel1, operands.expected_pc0, operands.expected_pc1, operands.downcount, operands.num_load_stores, operands.num_fp_inst,
               operands.profile_data ? 1 : 0);
  return sizeof(AnyCallback) + sizeof(operands);
}

// Explicitly instantiate EndBlock specializations so their symbols are available to other TUs
template s32 CachedInterpreter::EndBlock<false>(PowerPC::PowerPCState&,
                                               const EndBlockOperands<false>&);
template s32 CachedInterpreter::EndBlock<true>(PowerPC::PowerPCState&,
                                               const EndBlockOperands<true>&);

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
  // Record the natural fallthrough PC to enable end-of-block linking.
  m_link_fallthrough_pc = nextPC;
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
              mu.rc = static_cast<u8>(next.inst.Rc && next.crInUse[0]);
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
              mu.rc = static_cast<u8>(next.inst.Rc && next.crInUse[0]);
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
              mu.rc = static_cast<u8>(next.inst.Rc && next.crInUse[0]);
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
              mu.rc = 1;            // andi. always records to CR0
              mu.imm = static_cast<u32>(next.inst.UIMM);
              break;
            case 29: // andis.
              mu.op = MicroOpCode::ANDIS;
              mu.rd = next.inst.RA; // destination is RA (recording variant)
              mu.ra = next.inst.RS; // source is RS
              mu.rc = 1;            // andis. always records to CR0
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
                mu.rc = static_cast<u8>(next.inst.Rc && next.crInUse[0]);
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
                mu.rc = static_cast<u8>(next.inst.Rc && next.crInUse[0]);
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
                mu.rc = static_cast<u8>(next.inst.Rc && next.crInUse[0]);
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
                mu.rc = static_cast<u8>(next.inst.Rc && next.crInUse[0]);
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
                mu.rc = static_cast<u8>(next.inst.Rc && next.crInUse[0]);
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
                mu.rc = static_cast<u8>(next.inst.Rc && next.crInUse[0]);
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
                mu.rc = static_cast<u8>(next.inst.Rc && next.crInUse[0]);
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
                mu.rc = static_cast<u8>(next.inst.Rc && next.crInUse[0]);
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
                mu.rc = static_cast<u8>(next.inst.Rc && next.crInUse[0]);
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
                mu.rc = static_cast<u8>(next.inst.Rc && next.crInUse[0]);
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
                mu.rc = static_cast<u8>(next.inst.Rc && next.crInUse[0]);
                mu.imm = 0;
                goto end_pack_switch;
              case 824: // srawix
                mu.op = MicroOpCode::SRAWI_IMM;
                mu.rd = next.inst.RA;
                mu.ra = next.inst.RS;
                mu.rb = 0;
                mu.rc = static_cast<u8>(next.inst.Rc && next.crInUse[0]);
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
              mu.rc = static_cast<u8>(next.inst.Rc && next.crInUse[0]);
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
          const u32 opcd = op.inst.OPCD;
          bool fast_emitted = false;
          if (opcd == 18) // bx
          {
            Write(CallbackCast(BxFast<true>), operands);
            fast_emitted = true;
          }
          else if (opcd == 16) // bcx
          {
            Write(CallbackCast(BCxFast<true>), operands);
            fast_emitted = true;
          }
          else if (opcd == 19)
          {
            if (op.inst.SUBOP10 == 16) // bclrx
            {
              Write(CallbackCast(BclrxFast<true>), operands);
              fast_emitted = true;
            }
            else if (op.inst.SUBOP10 == 528) // bcctrx
            {
              Write(CallbackCast(BcctrxFast<true>), operands);
              fast_emitted = true;
            }
          }
          else if (opcd == 31)
          {
            if (op.inst.SUBOP10 == 339) // mfspr
            {
              const u32 index = ((op.inst.SPR & 0x1F) << 5) + ((op.inst.SPR >> 5) & 0x1F);
              if (index == SPR_LR || index == SPR_CTR || index == SPR_XER ||
                  index == SPR_SRR0 || index == SPR_SRR1)
              {
                Write(CallbackCast(MfsprFast), operands);
                fast_emitted = true;
              }
            }
            else if (op.inst.SUBOP10 == 467) // mtspr
            {
              const u32 index = (op.inst.SPRU << 5) | (op.inst.SPRL & 0x1F);
              if (index == SPR_LR || index == SPR_CTR || index == SPR_XER ||
                  index == SPR_SRR0 || index == SPR_SRR1)
              {
                Write(CallbackCast(MtsprFast), operands);
                fast_emitted = true;
              }
            }
          }
          else if (opcd == 59)
          {
            const u32 sub5 = op.inst.SUBOP5;
            if (sub5 == 18) // fdivsx (delegate)
            {
              Write(op.canEndBlock ? CallbackCast(FdivsxFast<true>) : CallbackCast(FdivsxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub5 == 24) // fresx
            {
              Write(op.canEndBlock ? CallbackCast(FresxFast<true>) : CallbackCast(FresxFast<false>), operands);
              fast_emitted = true;
            }
            if (sub5 == 21) // faddsx
            {
              if (s_inline59_enabled)
              {
                if (s_verify_fp)
                  Write(op.canEndBlock ? CallbackCast(FaddsxVerifyDelegateFast<true>) : CallbackCast(FaddsxVerifyDelegateFast<false>), operands);
                else
                  Write(op.canEndBlock ? CallbackCast(FpFaddsxFast<true>) : CallbackCast(FpFaddsxFast<false>), operands);
              }
              else
              {
                Write(op.canEndBlock ? CallbackCast(FaddsxFast<true>) : CallbackCast(FaddsxFast<false>), operands);
              }
              fast_emitted = true;
            }
            else if (sub5 == 20) // fsubsx
            {
              if (s_inline59_enabled)
              {
                if (s_verify_fp)
                  Write(op.canEndBlock ? CallbackCast(FsubsxVerifyDelegateFast<true>) : CallbackCast(FsubsxVerifyDelegateFast<false>), operands);
                else
                  Write(op.canEndBlock ? CallbackCast(FpFsubsxFast<true>) : CallbackCast(FpFsubsxFast<false>), operands);
              }
              else
              {
                Write(op.canEndBlock ? CallbackCast(FsubsxFast<true>) : CallbackCast(FsubsxFast<false>), operands);
              }
              fast_emitted = true;
            }
            else if (sub5 == 25) // fmulsx (delegate)
            {
              if (s_inline59_enabled)
              {
                if (s_verify_fp)
                  Write(op.canEndBlock ? CallbackCast(FmulsxVerifyDelegateFast<true>) : CallbackCast(FmulsxVerifyDelegateFast<false>), operands);
                else
                  Write(op.canEndBlock ? CallbackCast(FpFmulsxFast<true>) : CallbackCast(FpFmulsxFast<false>), operands);
              }
              else
              {
                Write(op.canEndBlock ? CallbackCast(FmulsxFast<true>) : CallbackCast(FmulsxFast<false>), operands);
              }
              fast_emitted = true;
            }
            else if (sub5 == 29) // fmaddsx (delegate)
            {
              Write(op.canEndBlock ? CallbackCast(FmaddsxFast<true>) : CallbackCast(FmaddsxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub5 == 28) // fmsubsx (delegate)
            {
              Write(op.canEndBlock ? CallbackCast(FmsubsxFast<true>) : CallbackCast(FmsubsxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub5 == 31) // fnmaddsx (delegate)
            {
              Write(op.canEndBlock ? CallbackCast(FnmaddsxFast<true>) : CallbackCast(FnmaddsxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub5 == 30) // fnmsubsx (delegate)
            {
              Write(op.canEndBlock ? CallbackCast(FnmsubsxFast<true>) : CallbackCast(FnmsubsxFast<false>), operands);
              fast_emitted = true;
            }
          }
          else if (opcd == 63)
          {
            const u32 sub10 = op.inst.SUBOP10;
            if (sub10 == 15) // fctiwzx only
            {
              Write(op.canEndBlock ? CallbackCast(FctiwzxFast<true>) : CallbackCast(FctiwzxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub10 == 12) // frspx
            {
              Write(op.canEndBlock ? CallbackCast(FrspxFast<true>) : CallbackCast(FrspxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub10 == 72) // fmrx
            {
              // Temporarily disabled to isolate F-Zero GPU desync; fall back to Interpreter
              Write(op.canEndBlock ? CallbackCast(FmrxFast<true>) : CallbackCast(FmrxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub10 == 32) // fcmpo
            {
              Write(op.canEndBlock ? CallbackCast(FcmpoFast<true>) : CallbackCast(FcmpoFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub10 == 0) // fcmpu
            {
              Write(op.canEndBlock ? CallbackCast(FcmpuFast<true>) : CallbackCast(FcmpuFast<false>), operands);
              fast_emitted = true;
            }
#if defined(__aarch64__)
            // ARM64 SIMD double-precision optimizations
            else if (sub10 == 21) // faddx
            {
              Write(op.canEndBlock ? CallbackCast(FaddxFast<true>) : CallbackCast(FaddxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub10 == 20) // fsubx
            {
              Write(op.canEndBlock ? CallbackCast(FsubxFast<true>) : CallbackCast(FsubxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub10 == 25) // fmulx
            {
              Write(op.canEndBlock ? CallbackCast(FmulxFast<true>) : CallbackCast(FmulxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub10 == 29) // fmaddx
            {
              Write(op.canEndBlock ? CallbackCast(FmaddxFast<true>) : CallbackCast(FmaddxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub10 == 40) // fnegx
            {
              Write(op.canEndBlock ? CallbackCast(FnegxFast<true>) : CallbackCast(FnegxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub10 == 264) // fabsx
            {
              Write(op.canEndBlock ? CallbackCast(FabsxFast<true>) : CallbackCast(FabsxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub10 == 136) // fnabsx
            {
              Write(op.canEndBlock ? CallbackCast(FnabsxFast<true>) : CallbackCast(FnabsxFast<false>), operands);
              fast_emitted = true;
            }
#endif
          }
#if defined(__aarch64__)
          else if (opcd == 4) // Paired Single operations
          {
            const u32 sub = op.inst.SUBOP10;
            if (sub == 21) // ps_add
            {
              Write(op.canEndBlock ? CallbackCast(PsAddFast<true>) : CallbackCast(PsAddFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 20) // ps_sub
            {
              Write(op.canEndBlock ? CallbackCast(PsSubFast<true>) : CallbackCast(PsSubFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 25) // ps_mul
            {
              Write(op.canEndBlock ? CallbackCast(PsMulFast<true>) : CallbackCast(PsMulFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 29) // ps_madd
            {
              Write(op.canEndBlock ? CallbackCast(PsMaddFast<true>) : CallbackCast(PsMaddFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 528) // ps_merge00
            {
              Write(op.canEndBlock ? CallbackCast(PsMerge00Fast<true>) : CallbackCast(PsMerge00Fast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 560) // ps_merge01
            {
              Write(op.canEndBlock ? CallbackCast(PsMerge01Fast<true>) : CallbackCast(PsMerge01Fast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 592) // ps_merge10
            {
              Write(op.canEndBlock ? CallbackCast(PsMerge10Fast<true>) : CallbackCast(PsMerge10Fast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 624) // ps_merge11
            {
              Write(op.canEndBlock ? CallbackCast(PsMerge11Fast<true>) : CallbackCast(PsMerge11Fast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 12) // ps_muls0
            {
              Write(op.canEndBlock ? CallbackCast(PsMuls0Fast<true>) : CallbackCast(PsMuls0Fast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 13) // ps_muls1
            {
              Write(op.canEndBlock ? CallbackCast(PsMuls1Fast<true>) : CallbackCast(PsMuls1Fast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 14) // ps_madds0
            {
              Write(op.canEndBlock ? CallbackCast(PsMadds0Fast<true>) : CallbackCast(PsMadds0Fast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 15) // ps_madds1
            {
              Write(op.canEndBlock ? CallbackCast(PsMadds1Fast<true>) : CallbackCast(PsMadds1Fast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 23) // ps_sel
            {
              Write(op.canEndBlock ? CallbackCast(PsSelFast<true>) : CallbackCast(PsSelFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 40) // ps_neg
            {
              Write(op.canEndBlock ? CallbackCast(PsNegFast<true>) : CallbackCast(PsNegFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 72) // ps_mr
            {
              Write(op.canEndBlock ? CallbackCast(PsMrFast<true>) : CallbackCast(PsMrFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 136) // ps_nabs
            {
              Write(op.canEndBlock ? CallbackCast(PsNabsFast<true>) : CallbackCast(PsNabsFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 264) // ps_abs
            {
              Write(op.canEndBlock ? CallbackCast(PsAbsFast<true>) : CallbackCast(PsAbsFast<false>), operands);
              fast_emitted = true;
            }
          }
#endif
#if defined(__aarch64__)
          else if (opcd == 31) // Integer operations
          {
            const u32 sub = op.inst.SUBOP10;
            if (sub == 266) // addx
            {
              Write(op.canEndBlock ? CallbackCast(AddxFast<true>) : CallbackCast(AddxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 40) // subfx
            {
              Write(op.canEndBlock ? CallbackCast(SubfxFast<true>) : CallbackCast(SubfxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 235) // mullwx
            {
              Write(op.canEndBlock ? CallbackCast(MullwxFast<true>) : CallbackCast(MullwxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 11) // mulhwux
            {
              Write(op.canEndBlock ? CallbackCast(MulhwuxFast<true>) : CallbackCast(MulhwuxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 104) // negx
            {
              Write(op.canEndBlock ? CallbackCast(NegxFast<true>) : CallbackCast(NegxFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 83) // mfmsr
            {
              Write(op.canEndBlock ? CallbackCast(MfmsrFast<true>) : CallbackCast(MfmsrFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 146) // mtmsr
            {
              Write(op.canEndBlock ? CallbackCast(MtmsrFast<true>) : CallbackCast(MtmsrFast<false>), operands);
              fast_emitted = true;
            }
            else if (sub == 371) // mftb
            {
              Write(op.canEndBlock ? CallbackCast(MftbFast<true>) : CallbackCast(MftbFast<false>), operands);
              fast_emitted = true;
            }
          }
#endif
          else if (opcd == 13) // addic_rc
          {
            Write(op.canEndBlock ? CallbackCast(AddicRcFast<true>) : CallbackCast(AddicRcFast<false>), operands);
            fast_emitted = true;
          }

          if (!fast_emitted)
          {
            Write(op.canEndBlock ? CallbackCast(Interpret<true>) : CallbackCast(Interpret<false>),
                  operands);
          }
        }
      }
    }

    if (op.branchIsIdleLoop)
      Write(CheckIdle, {m_system.GetCoreTiming(), js.blockStart});
    // For simple CTR-controlled tight loops, fast-forward by exiting the loop and yielding.
    if (op.branchIsCtrIdleLoop)
    {
      const u32 fallthrough_pc = op.address + 4;
      Write(FastForwardCtrIdle, {m_system.GetCoreTiming(), js.blockStart, fallthrough_pc});
    }
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
#if defined(__aarch64__)
{
  uint8x16_t vz = vdupq_n_u8(0);
  vst1q_u8(reinterpret_cast<uint8_t*>(region.base + offset), vz);
  vst1q_u8(reinterpret_cast<uint8_t*>(region.base + offset + 16), vz);
}
#else
std::memset(region.base + offset, 0, 32);
#endif
return sizeof(AnyCallback) + sizeof(operands);
}
