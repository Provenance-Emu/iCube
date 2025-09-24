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
  // Fallthrough PC for the currently generated block (for linking)
  u32 m_link_fallthrough_pc = 0;

  // Lightweight instrumentation for linking effectiveness
  struct LinkStats
  {
    u64 rel0_taken = 0;
    u64 rel1_taken = 0;
    u64 match_but_unlinked = 0; // expected_pc matched but rel==0
    u64 npc_mismatch = 0;       // neither expected_pc matched
    u64 zero_downcount = 0;     // link suppressed due to operands.downcount==0
    u64 slice_end = 0;          // link suppressed due to ppc_state.downcount<=0
    u64 dispatcher_roundtrips = 0; // block ended and we returned to dispatcher
    u64 links_patched = 0;         // number of times WriteLinkBlock patched a link
  };

public:
  static void OnLinkPatched();
  static void MaybeLogLinkStats();
  static void ConfigureLinkLogFromEnv();

  // Hot instruction profiling (disabled by default; enable with env DOLPHIN_CI_HOT=1)
  struct HotStats
  {
    // Counts/time by primary opcode (0..63)
    u64 count_by_opcd[64] = {};
    u64 ns_by_opcd[64] = {};
    // Counts/time for SUBOP10 when OPCD==31 (0..1023) to keep it simple
    u64 count_by_subop31[1024] = {};
    u64 ns_by_subop31[1024] = {};
    // Counts/time for SUBOP5 when OPCD==59 (0..31)
    u64 count_by_subop59[32] = {};
    u64 ns_by_subop59[32] = {};
    // Counts/time for SUBOP10 when OPCD==63 (0..1023)
    u64 count_by_subop63[1024] = {};
    u64 ns_by_subop63[1024] = {};
    // Counts/time for SUBOP10 when OPCD==4 (Paired Single) (0..1023)
    u64 count_by_subop4[1024] = {};
    u64 ns_by_subop4[1024] = {};
    // Fast path hit counts
    u64 fast_path_hits = 0;
    u64 slow_path_hits = 0;
  };

public:
  static void ConfigureHotStatsFromEnv();
  static void MaybeLogHotStats();
  static const HotStats& GetHotStats() { return s_hot_stats; }
  static void ConfigureFpFastFromEnv();
private:
  static HotStats s_hot_stats;
  static bool s_hot_enabled;
  static u32 s_hot_sample_every; // measure 1 out of N instructions (N>=1)
  static u64 s_hot_counter;
  static bool s_fp_fast_enabled;
private:
  static LinkStats s_link_stats;
  static bool s_log_enabled;

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
  struct CheckCtrIdleOperands;
  // Link to another cached-interpreter block without dispatcher round-trip
  struct LinkToBlockOperands
  {
    // End-of-block accounting (merged EndBlock operands)
    u32 downcount;
    u32 num_load_stores;
    u32 num_fp_inst;
    u32 expected_pc0; // fallthrough or primary expected PC
    u32 expected_pc1; // secondary expected PC (e.g., taken branch target)
    JitBlock::ProfileData* profile_data; // nullptr when profiling disabled
    // Signed distance in bytes from callback start to dest->normalEntry (0 = not linked)
    s32 rel0; // distance for expected_pc0
    s32 rel1; // distance for expected_pc1
    u32 _pad; // pad to keep sizeof(Operands) multiple of pointer size
  };

  static s32 StartProfiledBlock(PowerPC::PowerPCState& ppc_state,
                                const StartProfiledBlockOperands& operands);
  static s32 StartProfiledBlock(std::ostream& stream, const StartProfiledBlockOperands& operands);
  template <bool profiled>
  static s32 EndBlock(PowerPC::PowerPCState& ppc_state, const EndBlockOperands<profiled>& operands);
  template <bool profiled>
  static s32 EndBlock(std::ostream& stream, const EndBlockOperands<profiled>& operands);
  // Link trampoline callback
  static s32 LinkToBlock(PowerPC::PowerPCState& ppc_state, const LinkToBlockOperands& operands);
  static s32 LinkToBlock(std::ostream& stream, const LinkToBlockOperands& operands);
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

  // Fast branch callbacks
  template <bool write_pc>
  DOL_HOT static s32 BxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // OPCD 18
  template <bool write_pc>
  DOL_HOT static s32 BCxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // OPCD 16
  template <bool write_pc>
  DOL_HOT static s32 BclrxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // OPCD 19 SUBOP10=16
  template <bool write_pc>
  DOL_HOT static s32 BcctrxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // OPCD 19 SUBOP10=528

  // Fast SPR access (LR/CTR only)
  DOL_HOT static s32 MfsprFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // OPCD 31 SUBOP10=339
  DOL_HOT static s32 MtsprFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // OPCD 31 SUBOP10=467

  // Fast FP arithmetic (single-precision) - OPCD 59 using SUBOP5
  template <bool write_pc>
  DOL_HOT static s32 FpFsubsxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // SUBOP5=20
  template <bool write_pc>
  DOL_HOT static s32 FpFaddsxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // SUBOP5=21
  template <bool write_pc>
  DOL_HOT static s32 FpFmulsxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // SUBOP5=25
  // Delegate variants (safer) for 59 ops
  template <bool write_pc>
  DOL_HOT static s32 FaddsxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // SUBOP5=21
  template <bool write_pc>
  DOL_HOT static s32 FsubsxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // SUBOP5=20
  template <bool write_pc>
  DOL_HOT static s32 FaddsxVerifyDelegateFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);
  template <bool write_pc>
  DOL_HOT static s32 FsubsxVerifyDelegateFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);
  template <bool write_pc>
  DOL_HOT static s32 FmulsxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // SUBOP5=25
  template <bool write_pc>
  DOL_HOT static s32 FmulsxVerifyDelegateFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // verify inline vs interpreter, then delegate
  template <bool write_pc>
  DOL_HOT static s32 FdivsxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);  // SUBOP5=18
  // FMADD family delegates (safe)
  template <bool write_pc>
  DOL_HOT static s32 FmaddsxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);  // SUBOP5=29
  template <bool write_pc>
  DOL_HOT static s32 FmsubsxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);  // SUBOP5=30
  template <bool write_pc>
  DOL_HOT static s32 FnmaddsxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // SUBOP5=31
  template <bool write_pc>
  DOL_HOT static s32 FnmsubsxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // SUBOP5=28 (if used)
  template <bool write_pc>
  DOL_HOT static s32 FresxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);     // SUBOP5=24
  template <bool write_pc>
  DOL_HOT static s32 FnmaddsxFast2(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // SUBOP5=31
  template <bool write_pc>
  DOL_HOT static s32 FnmsubsxFast2(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // SUBOP5=30

#if defined(__aarch64__)
  // ARM NEON optimized Paired Single operations - OPCD 4
  template <bool write_pc>
  DOL_HOT static s32 PsAddFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);    // SUBOP 21
  template <bool write_pc>
  DOL_HOT static s32 PsSubFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);    // SUBOP 20
  template <bool write_pc>
  DOL_HOT static s32 PsMulFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);    // SUBOP 25
  template <bool write_pc>
  DOL_HOT static s32 PsMaddFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);   // SUBOP 29
  template <bool write_pc>
  DOL_HOT static s32 PsMerge00Fast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // SUBOP 528
  template <bool write_pc>
  DOL_HOT static s32 PsMerge01Fast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // SUBOP 560
  template <bool write_pc>
  DOL_HOT static s32 PsMerge10Fast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // SUBOP 592
  template <bool write_pc>
  DOL_HOT static s32 PsMerge11Fast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // SUBOP 624

  // ARM NEON optimized PS scalar multiply operations
  template <bool write_pc>
  DOL_HOT static s32 PsMuls0Fast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);   // SUBOP 12
  template <bool write_pc>
  DOL_HOT static s32 PsMuls1Fast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);   // SUBOP 13
  template <bool write_pc>
  DOL_HOT static s32 PsMadds0Fast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);  // SUBOP 14
  template <bool write_pc>
  DOL_HOT static s32 PsMadds1Fast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);  // SUBOP 15

  // Newly added Paired Single (OPCD 4) fast paths
  template <bool write_pc>
  DOL_HOT static s32 PsSelFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);     // SUBOP 23
  template <bool write_pc>
  DOL_HOT static s32 PsNegFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);     // SUBOP 40
  template <bool write_pc>
  DOL_HOT static s32 PsAbsFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);     // SUBOP 264
  template <bool write_pc>
  DOL_HOT static s32 PsNabsFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);    // SUBOP 136
  template <bool write_pc>
  DOL_HOT static s32 PsMrFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);      // SUBOP 72

  // ARM NEON optimized integer operations - OPCD 31
  template <bool write_pc>
  DOL_HOT static s32 AddxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);      // SUBOP 266
  template <bool write_pc>
  DOL_HOT static s32 SubfxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);     // SUBOP 40
  template <bool write_pc>
  DOL_HOT static s32 MullwxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);    // SUBOP 235
  template <bool write_pc>
  DOL_HOT static s32 MulhwuxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);   // SUBOP 11
  template <bool write_pc>
  DOL_HOT static s32 NegxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);      // SUBOP 104
  template <bool write_pc>
  DOL_HOT static s32 MfmsrFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);     // SUBOP 83
  template <bool write_pc>
  DOL_HOT static s32 MtmsrFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);     // SUBOP 146
  template <bool write_pc>
  DOL_HOT static s32 MftbFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);      // SUBOP 371

  // ARM NEON optimized Double-precision FP operations - OPCD 63
  template <bool write_pc>
  DOL_HOT static s32 FaddxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);     // SUBOP 21
  template <bool write_pc>
  DOL_HOT static s32 FsubxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);     // SUBOP 20
  template <bool write_pc>
  DOL_HOT static s32 FmulxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);     // SUBOP 25
  template <bool write_pc>
  DOL_HOT static s32 FmaddxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);    // SUBOP 29
  template <bool write_pc>
  DOL_HOT static s32 FnegxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);     // SUBOP 40
  // Newly added scalar double helpers
  template <bool write_pc>
  DOL_HOT static s32 FabsxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);     // SUBOP 264
  template <bool write_pc>
  DOL_HOT static s32 FnabsxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);    // SUBOP 136
#endif

  // Optimized integer operations
  template <bool write_pc>
  DOL_HOT static s32 AddicRcFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);   // OPCD 13

  // Fast FP ops (double/misc) - OPCD 63 using SUBOP10
  template <bool write_pc>
  DOL_HOT static s32 FctiwzxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands); // SUBOP10=15
  template <bool write_pc>
  DOL_HOT static s32 FrspxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);   // SUBOP10=12
  template <bool write_pc>
  DOL_HOT static s32 FmrxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);    // SUBOP10=72
  template <bool write_pc>
  DOL_HOT static s32 FcmpoFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);   // SUBOP10=32
  template <bool write_pc>
  DOL_HOT static s32 FcmpuFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);   // SUBOP10=0
  template <bool write_pc>
  DOL_HOT static s32 FselxFast(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);   // SUBOP10=20
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
  static s32 FastForwardCtrIdle(PowerPC::PowerPCState& ppc_state,
                                const CheckCtrIdleOperands& operands);
  static s32 FastForwardCtrIdle(std::ostream& stream, const CheckCtrIdleOperands& operands);

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

struct CachedInterpreter::CheckCtrIdleOperands
{
  CoreTiming::CoreTimingManager& core_timing;
  u32 idle_pc;         // PC of the CTR-branch at loop end
  u32 fallthrough_pc;  // PC after the branch (loop exit)
};
