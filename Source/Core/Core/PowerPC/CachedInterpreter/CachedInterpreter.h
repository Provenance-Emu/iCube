// Copyright 2014 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <cstddef>

#include <rangeset/rangesizeset.h>

#include "Common/CommonTypes.h"
#include "Core/PowerPC/CachedInterpreter/CachedInterpreterBlockCache.h"
#include "Core/PowerPC/CachedInterpreter/CachedInterpreterEmitter.h"
#include "Core/PowerPC/JitCommon/JitBase.h"
#include "Core/PowerPC/PPCAnalyst.h"

#if defined(__GNUC__) || defined(__clang__)
#define DOL_HOT __attribute__((hot))
#else
#define DOL_HOT
#endif

namespace CoreTiming
{
class CoreTimingManager;
}
namespace CPU
{
enum class State;
}
class Interpreter;
namespace Memory
{
class MemoryManager;
}
namespace PowerPC
{
class MMU;
}

class CachedInterpreter : public JitBase, public CachedInterpreterCodeBlock
{
public:
  explicit CachedInterpreter(Core::System& system);
  CachedInterpreter(const CachedInterpreter&) = delete;
  CachedInterpreter(CachedInterpreter&&) = delete;
  CachedInterpreter& operator=(const CachedInterpreter&) = delete;
  CachedInterpreter& operator=(CachedInterpreter&&) = delete;
  ~CachedInterpreter();

  void Init() override;
  void Shutdown() override;

  bool HandleFault(uintptr_t access_address, SContext* ctx) override { return false; }
  void ClearCache() override;

  void Run() override;
  void SingleStep() override;

  void Jit(u32 address) override;
  void Jit(u32 address, bool clear_cache_and_retry_on_failure);
  bool DoJit(u32 address, JitBlock* b, u32 nextPC);

  void EraseSingleBlock(const JitBlock& block) override;
  std::vector<MemoryStats> GetMemoryStats() const override;

  static std::size_t Disassemble(const JitBlock& block, std::ostream& stream);

  std::size_t DisassembleNearCode(const JitBlock& block, std::ostream& stream) const override;
  std::size_t DisassembleFarCode(const JitBlock& block, std::ostream& stream) const override;

  JitBaseBlockCache* GetBlockCache() override { return &m_block_cache; }
  const char* GetName() const override { return "Cached Interpreter"; }
  const CommonAsmRoutinesBase* GetAsmRoutines() override { return nullptr; }

private:
  void ExecuteOneBlock();

  bool HandleFunctionHooking(u32 address);
  void WriteEndBlock();

  // Finds a free memory region and sets the code emitter to point at that region.
  // Returns false if no free memory region can be found.
  bool SetEmitterStateToFreeCodeRegion();

  void FreeRanges();
  void ResetFreeMemoryRanges();

  void LogGeneratedCode() const;

  struct StartProfiledBlockOperands;
  template <bool profiled>
  struct EndBlockOperands;
  struct InterpretOperands;
  struct InterpretAndCheckExceptionsOperands;
  struct LoadStoreDFormPICOperands;
  struct ExecuteMicroOpsOperands;
  struct HLEFunctionOperands;
  struct WriteBrokenBlockNPCOperands;
  struct CheckHaltOperands;
  struct CheckIdleOperands;

  static s32 StartProfiledBlock(PowerPC::PowerPCState& ppc_state,
                                const StartProfiledBlockOperands& operands);
  static s32 StartProfiledBlock(std::ostream& stream, const StartProfiledBlockOperands& operands);
  template <bool profiled>
  static s32 EndBlock(PowerPC::PowerPCState& ppc_state, const EndBlockOperands<profiled>& operands);
  template <bool profiled>
  static s32 EndBlock(std::ostream& stream, const EndBlockOperands<profiled>& operands);
  template <bool write_pc>
  DOL_HOT static s32 Interpret(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);
  template <bool write_pc>
  static s32 Interpret(std::ostream& stream, const InterpretOperands& operands);
  template <bool write_pc>
  DOL_HOT static s32 InterpretAndCheckExceptions(PowerPC::PowerPCState& ppc_state,
                                         const InterpretAndCheckExceptionsOperands& operands);
  template <bool write_pc>
  static s32 InterpretAndCheckExceptions(std::ostream& stream,
                                         const InterpretAndCheckExceptionsOperands& operands);
  template <bool write_pc>
  DOL_HOT static s32 LoadStoreDFormPIC(PowerPC::PowerPCState& ppc_state,
                               const LoadStoreDFormPICOperands& operands);
  template <bool write_pc>
  static s32 LoadStoreDFormPIC(std::ostream& stream,
                               const LoadStoreDFormPICOperands& operands);
  // X-form (indexed) Load/Store PIC fast path
  template <bool write_pc>
  DOL_HOT static s32 LoadStoreXFormPIC(PowerPC::PowerPCState& ppc_state,
                               const LoadStoreDFormPICOperands& operands);
  template <bool write_pc>
  static s32 LoadStoreXFormPIC(std::ostream& stream,
                               const LoadStoreDFormPICOperands& operands);

  [[gnu::noinline]] [[gnu::cold]]
  static s32 Cold_LoadStoreFallback(PowerPC::PowerPCState& ppc_state,
                                    const LoadStoreDFormPICOperands& operands);

  // Minimal dcbz fast path (safe): only when MSR.DR == 0, HID0.DCE set, and within MEM1/MEM2
  template <bool write_pc>
  DOL_HOT static s32 DcbzPIC(PowerPC::PowerPCState& ppc_state,
                     const LoadStoreDFormPICOperands& operands);
  template <bool write_pc>
  DOL_HOT static s32 ExecuteMicroOps(PowerPC::PowerPCState& ppc_state,
                             const ExecuteMicroOpsOperands& operands);
  template <bool write_pc>
  static s32 ExecuteMicroOps(std::ostream& stream, const ExecuteMicroOpsOperands& operands);
  static s32 HLEFunction(PowerPC::PowerPCState& ppc_state, const HLEFunctionOperands& operands);
  static s32 HLEFunction(std::ostream& stream, const HLEFunctionOperands& operands);
  static s32 WriteBrokenBlockNPC(PowerPC::PowerPCState& ppc_state,
                                 const WriteBrokenBlockNPCOperands& operands);
  static s32 WriteBrokenBlockNPC(std::ostream& stream, const WriteBrokenBlockNPCOperands& operands);
  static s32 CheckFPU(PowerPC::PowerPCState& ppc_state, const CheckHaltOperands& operands);
  static s32 CheckFPU(std::ostream& stream, const CheckHaltOperands& operands);
  static s32 CheckBreakpoint(PowerPC::PowerPCState& ppc_state, const CheckHaltOperands& operands);
  static s32 CheckBreakpoint(std::ostream& stream, const CheckHaltOperands& operands);
  static s32 CheckIdle(PowerPC::PowerPCState& ppc_state, const CheckIdleOperands& operands);
  static s32 CheckIdle(std::ostream& stream, const CheckIdleOperands& operands);

  HyoutaUtilities::RangeSizeSet<u8*> m_free_ranges;
  CachedInterpreterBlockCache m_block_cache;
};

struct CachedInterpreter::StartProfiledBlockOperands
{
  JitBlock::ProfileData* profile_data;
};

template <>
struct CachedInterpreter::EndBlockOperands<false>
{
  u32 downcount;
  u32 num_load_stores;
  u32 num_fp_inst;
  u32 : 32;
};

template <>
struct CachedInterpreter::EndBlockOperands<true> : CachedInterpreter::EndBlockOperands<false>
{
  JitBlock::ProfileData* profile_data;
};

struct CachedInterpreter::InterpretOperands
{
  Interpreter& interpreter;
  void (*func)(Interpreter&, UGeckoInstruction);  // Interpreter::Instruction
  u32 current_pc;
  UGeckoInstruction inst;
};

struct CachedInterpreter::InterpretAndCheckExceptionsOperands : InterpretOperands
{
  PowerPC::PowerPCManager& power_pc;
  u32 downcount;
};

struct CachedInterpreter::LoadStoreDFormPICOperands
{
  Interpreter& interpreter;
  void (*func)(Interpreter&, UGeckoInstruction);  // Interpreter::Instruction
  u32 current_pc;
  UGeckoInstruction inst;

  PowerPC::PowerPCManager& power_pc;

  u8* mem1_base;
  u32 mem1_mask;
  u8* exram_base;
  u32 exram_mask;
  u8* fakevmem_base;
  u32 fakevmem_mask;
};

  // Minimal micro-op engine scaffolding for Phase 3
  enum class MicroOpCode : u8
  {
    CONST32,
    CONST32_ADDRA,
    ADDI,
    ADDIS,
    ORI,
    ORIS,
    XORI,
    XORIS,
    ANDI,
    ANDIS,
    // New ops for jitless optimization
    RLWINM_IMM, // RA = rotl(RS, SH) & mask(MB, ME); optional record via rc flag
    AND_RR,     // RA = RS & RB; optional record via rc flag
    OR_RR,      // RA = RS | RB; optional record via rc flag
    XOR_RR,     // RA = RS ^ RB; optional record via rc flag
    RLWIMI_IMM, // RA = (RA & ~mask) | (rotl(RS, SH) & mask); optional record via rc flag
    RLWNM_VAR,  // RA = rotl(RS, RB & 31) & mask(MB, ME); optional record via rc flag
    ANDC_RR,    // RA = RS & ~RB; optional record via rc flag
    ORC_RR,     // RA = RS | ~RB; optional record via rc flag
    NAND_RR,    // RA = ~(RS & RB); optional record via rc flag
    NOR_RR,     // RA = ~(RS | RB); optional record via rc flag
    EQV_RR,     // RA = ~(RS ^ RB); optional record via rc flag
    // New integer ops (X-form and variants)
    CNTLZW,     // RA = count leading zeros of RS; optional record via rc flag
    EXTSB,      // RA = sign-extend byte from RS; optional record via rc flag
    EXTSH,      // RA = sign-extend halfword from RS; optional record via rc flag
    SLW_VAR,    // RA = (RB & 0x20) ? 0 : (RS << (RB & 0x1f)); optional record via rc flag
    SRW_VAR,    // RA = (RB & 0x20) ? 0 : (RS >> (RB & 0x1f)); optional record via rc flag
    SRAW_VAR,   // RA = arithmetic right shift by RB; updates CA; optional record via rc flag
    SRAWI_IMM,  // RA = arithmetic right shift by SH; updates CA; optional record via rc flag
    // Integer add/sub with carry/overflow semantics
    ADD_RR,     // RD = RA + RB; optional OV update via imm bit0; optional record via rc
    ADDC_RR,    // RD = RA + RB; set CA; optional OV via imm bit0; optional record via rc
    ADDE_RR,    // RD = RA + RB + CA; set CA; optional OV via imm bit0; optional record via rc
    ADDME,      // RD = RA + 0xFFFFFFFF + CA; set CA; optional OV via imm bit0; optional record via rc
    ADDZE,      // RD = RA + CA; set CA; optional OV via imm bit0; optional record via rc
    SUBF_RR,    // RD = ~RA + RB + 1; optional OV via imm bit0; optional record via rc
    SUBFC_RR,   // RD = ~RA + RB + 1; set CA; optional OV via imm bit0; optional record via rc
    SUBFE_RR,   // RD = ~RA + RB + CA; set CA; optional OV via imm bit0; optional record via rc
    SUBFME,     // RD = ~RA + 0xFFFFFFFF + CA; set CA; optional OV via imm bit0; optional record via rc
    SUBFZE,     // RD = ~RA + CA; set CA; optional OV via imm bit0; optional record via rc
    // Integer compare ops (update CR field only; rd encodes CRFD)
    CMP_S_RR,   // CR[rd] = cmp(s32(RA), s32(RB))
    CMPL_U_RR,  // CR[rd] = cmp(u32(RA), u32(RB))
    CMP_S_IMM,  // CR[rd] = cmp(s32(RA), SIMM16=imm)
    CMPL_U_IMM, // CR[rd] = cmp(u32(RA), UIMM16=imm)
    NOP,
    COUNT,
  };

struct MicroOp
{
  MicroOpCode op;
  u8 rd;   // destination (or RA for ORI)
  u8 ra;   // source register (0 means zero for ADDI semantics)
  u8 rb;   // second source register for reg-reg ops (RB). Unused for immediates.
  u8 rc;   // non-zero if this op should update CR0 (record bit)
  u32 imm; // immediate value (signed/unsigned depends on op)
};

struct CachedInterpreter::ExecuteMicroOpsOperands
{
  // Embedded small array keeps lifetime simple and avoids heap allocs
  static constexpr u32 kMaxOps = 64;
  u32 count;
  MicroOp ops[kMaxOps];
  u32 current_pc;
};

struct CachedInterpreter::HLEFunctionOperands
{
  Core::System& system;
  u32 current_pc;
  u32 hook_index;
};

struct CachedInterpreter::WriteBrokenBlockNPCOperands
{
  u32 current_pc;
  u32 : 32;
};

struct CachedInterpreter::CheckHaltOperands
{
  PowerPC::PowerPCManager& power_pc;
  u32 current_pc;
  u32 downcount;
};

struct CachedInterpreter::CheckIdleOperands
{
  CoreTiming::CoreTimingManager& core_timing;
  u32 idle_pc;
};
