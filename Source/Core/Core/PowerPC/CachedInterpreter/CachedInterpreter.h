// Copyright 2014 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <cstddef>

#include <rangeset/rangesizeset.h>

#include "Common/CommonTypes.h"
#include "Core/PowerPC/CachedInterpreter/CachedInterpreterBlockCache.h"
#include "Core/PowerPC/CachedInterpreter/CachedInterpreterEmitter.h"
#include "Core/PowerPC/Interpreter/Interpreter.h"
#include "Core/PowerPC/JitCommon/JitBase.h"
#include "Core/PowerPC/PPCAnalyst.h"

namespace CoreTiming
{
class CoreTimingManager;
}
namespace CPU
{
enum class State;
}

// iCube WIN#2: micro-op fusion engine (MAIN_CIR_MICROOP_FUSION). MicroOpCode is the compact op-id the
// ExecuteMicroOps computed-goto dispatch_table is keyed on; the dispatch_table order in
// CachedInterpreter.cpp MUST match this enum exactly (a static_assert against COUNT enforces it). Ported
// verbatim from the feature/icube-testflight good branch. Only used when the flag is on.
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
  RLWINM_IMM,  // RA = rotl(RS, SH) & mask(MB, ME); optional record via rc flag
  AND_RR,      // RA = RS & RB; optional record via rc flag
  OR_RR,       // RA = RS | RB; optional record via rc flag
  XOR_RR,      // RA = RS ^ RB; optional record via rc flag
  RLWIMI_IMM,  // RA = (RA & ~mask) | (rotl(RS, SH) & mask); optional record via rc flag
  RLWNM_VAR,   // RA = rotl(RS, RB & 31) & mask(MB, ME); optional record via rc flag
  ANDC_RR,     // RA = RS & ~RB; optional record via rc flag
  ORC_RR,      // RA = RS | ~RB; optional record via rc flag
  NAND_RR,     // RA = ~(RS & RB); optional record via rc flag
  NOR_RR,      // RA = ~(RS | RB); optional record via rc flag
  EQV_RR,      // RA = ~(RS ^ RB); optional record via rc flag
  // New integer ops (X-form and variants)
  CNTLZW,      // RA = count leading zeros of RS; optional record via rc flag
  EXTSB,       // RA = sign-extend byte from RS; optional record via rc flag
  EXTSH,       // RA = sign-extend halfword from RS; optional record via rc flag
  SLW_VAR,     // RA = (RB & 0x20) ? 0 : (RS << (RB & 0x1f)); optional record via rc flag
  SRW_VAR,     // RA = (RB & 0x20) ? 0 : (RS >> (RB & 0x1f)); optional record via rc flag
  SRAW_VAR,    // RA = arithmetic right shift by RB; updates CA; optional record via rc flag
  SRAWI_IMM,   // RA = arithmetic right shift by SH; updates CA; optional record via rc flag
  // Integer add/sub with carry/overflow semantics
  ADD_RR,      // RD = RA + RB; optional OV update via imm bit0; optional record via rc
  ADDC_RR,     // RD = RA + RB; set CA; optional OV via imm bit0; optional record via rc
  ADDE_RR,     // RD = RA + RB + CA; set CA; optional OV via imm bit0; optional record via rc
  ADDME,       // RD = RA + 0xFFFFFFFF + CA; set CA; optional OV via imm bit0; optional record via rc
  ADDZE,       // RD = RA + CA; set CA; optional OV via imm bit0; optional record via rc
  SUBF_RR,     // RD = ~RA + RB + 1; optional OV via imm bit0; optional record via rc
  SUBFC_RR,    // RD = ~RA + RB + 1; set CA; optional OV via imm bit0; optional record via rc
  SUBFE_RR,    // RD = ~RA + RB + CA; set CA; optional OV via imm bit0; optional record via rc
  SUBFME,      // RD = ~RA + 0xFFFFFFFF + CA; set CA; optional OV via imm bit0; optional record via rc
  SUBFZE,      // RD = ~RA + CA; set CA; optional OV via imm bit0; optional record via rc
  // Integer compare ops (update CR field only; rd encodes CRFD)
  CMP_S_RR,    // CR[rd] = cmp(s32(RA), s32(RB))
  CMPL_U_RR,   // CR[rd] = cmp(u32(RA), u32(RB))
  CMP_S_IMM,   // CR[rd] = cmp(s32(RA), SIMM16=imm)
  CMPL_U_IMM,  // CR[rd] = cmp(u32(RA), UIMM16=imm)
  NOP,
  COUNT,
};

// iCube WIN#2: one decoded fusable op in an ExecuteMicroOps run. Trivially copyable POD.
struct MicroOp
{
  MicroOpCode op;
  u8 rd;    // destination (or RA for ORI)
  u8 ra;    // source register (0 means zero for ADDI semantics)
  u8 rb;    // second source register for reg-reg ops (RB). Unused for immediates.
  u8 rc;    // non-zero if this op should update CR0 (record bit)
  u32 imm;  // immediate value (signed/unsigned depends on op)
};

class CachedInterpreter : public JitBase, public CachedInterpreterCodeBlock
{
public:
  explicit CachedInterpreter(Core::System& system);
  CachedInterpreter(const CachedInterpreter&) = delete;
  CachedInterpreter(CachedInterpreter&&) = delete;
  CachedInterpreter& operator=(const CachedInterpreter&) = delete;
  CachedInterpreter& operator=(CachedInterpreter&&) = delete;
  ~CachedInterpreter() override;

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

  // iCube: patch the relative link distance inside a LinkBlock trampoline. Called by
  // CachedInterpreterBlockCache::WriteLinkBlock through the upstream link/unlink machinery.
  // exit_ptrs points at the AnyCallback slot of the LinkBlock callback (== LinkData::exitPtrs).
  // rel is the byte distance from exit_ptrs to the target block's normalEntry, or 0 to unlink. The
  // layout (a single trailing s32 rel field) is owned here so the block cache need not see the
  // private operand struct.
  static void PatchLinkBlockRel(u8* exit_ptrs, s32 rel);

private:
  void ExecuteOneBlock();

  bool HandleFunctionHooking(u32 address);
  // iCube: link_target is the STATIC direct-branch destination (op.branchTo) of the terminal, or
  // UINT32_MAX for any non-static terminal (indirect branch, broken block, HLE replace, fall-through).
  // When block linking is enabled and the terminal is a linkable static branch, emits a LinkBlock
  // trampoline (and records the LinkData for upstream patching) instead of a plain EndBlock. Default
  // UINT32_MAX preserves the stock behavior for all the non-static call sites.
  void WriteEndBlock(u32 link_target = 0xFFFFFFFF);

  // Finds a free memory region and sets the code emitter to point at that region.
  // Returns false if no free memory region can be found.
  bool SetEmitterStateToFreeCodeRegion();

  void FreeRanges();
  void ResetFreeMemoryRanges();

  void LogGeneratedCode() const;

  struct StartProfiledBlockOperands;
  template <bool profiled>
  struct EndBlockOperands;
  // iCube: operands for the block-linking trampoline (MAIN_CIR_BLOCK_LINKING). See LinkBlock.
  struct LinkBlockOperands;
  struct InterpretOperands;
  // iCube: specialized-only payload (MAIN_CIR_SPECIALIZED_OPS). Layout-COMPATIBLE prefix with
  // InterpretOperands plus a trailing compact op-id, so the dispatch switch in ExecuteOneBlock can
  // jump-table on the id instead of comparing the callback pointer N times. Deliberately a SEPARATE
  // struct from InterpretOperands: the generic (flag-off) path must never see a widened payload, so
  // its stream layout/advancement stays byte-identical to stock 2509.
  struct SpecializedInterpretOperands;
  struct InterpretAndCheckExceptionsOperands;
  // iCube WIN#1: payload for the PIC (position-independent-code) direct-pointer load/store fast path
  // (MAIN_CIR_PIC_LOADSTORE). Carries the InterpretOperands prefix (for the cold fallback) plus the
  // fastmem region base/mask pointers captured at emit time. See LoadStoreDFormPIC / LoadStoreXFormPIC.
  struct LoadStoreDFormPICOperands;
  // iCube WIN#2: payload for the micro-op fusion engine (MAIN_CIR_MICROOP_FUSION). Carries a packed
  // run of fusable pure-register integer/immediate MicroOps that ExecuteMicroOps dispatches over via a
  // computed goto. SEPARATE struct, only ever written when the flag is on, so the generic (flag-off)
  // stream layout stays byte-identical to upstream. See ExecuteMicroOps / DoJit fusion emitter.
  struct ExecuteMicroOpsOperands;
  struct HLEFunctionOperands;
  struct WriteBrokenBlockNPCOperands;
  struct CheckHaltOperands;
  struct CheckIdleOperands;
  struct CheckCtrIdleOperands;

  static s32 StartProfiledBlock(PowerPC::PowerPCState& ppc_state,
                                const StartProfiledBlockOperands& operands);
  static s32 StartProfiledBlock(std::ostream& stream, const StartProfiledBlockOperands& operands);
  template <bool profiled>
  static s32 EndBlock(PowerPC::PowerPCState& ppc_state, const EndBlockOperands<profiled>& operands);
  template <bool profiled>
  static s32 EndBlock(std::ostream& stream, const EndBlockOperands<profiled>& operands);
  // iCube: block-linking trampoline. Does the same end-of-block accounting as EndBlock<false>, then,
  // IFF the slice has budget left (downcount > 0) AND the architectural npc equals the static branch
  // target this exit was compiled for (expected_pc) AND the link has been patched (rel != 0),
  // returns the relative byte distance to the target block's callback stream so ExecuteOneBlock
  // continues into it WITHOUT a dispatcher round-trip. In every other case returns 0 (exit to the
  // dispatcher / Run loop) — fail-safe. rel is patched by CachedInterpreterBlockCache::WriteLinkBlock
  // through the upstream JitBaseBlockCache link/unlink machinery and is cleared (back to 0) whenever
  // the target block is destroyed/recompiled, so a stale link can never be followed.
  static s32 LinkBlock(PowerPC::PowerPCState& ppc_state, const LinkBlockOperands& operands);
  static s32 LinkBlock(std::ostream& stream, const LinkBlockOperands& operands);
  template <bool write_pc>
  static s32 Interpret(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);
  template <bool write_pc>
  static s32 Interpret(std::ostream& stream, const InterpretOperands& operands);
  // iCube: specialized dispatch (MAIN_CIR_SPECIALIZED_OPS). There are exactly TWO instantiations
  // (write_pc false/true), each a single marker callback whose value ExecuteOneBlock recognizes to
  // enter the inline jump-table; the actual per-op handler is selected by a switch on the compact
  // op-id carried in SpecializedInterpretOperands and called by its compile-time-constant pointer
  // Interpreter::name(...) (direct/inlinable, ZERO indirect calls — same property as the prior
  // per-op compare-chain). The body is also a correct standalone callback (same switch), so it is
  // safe if ever reached through the generic indirect tail. Reproduces the Interpret<write_pc>
  // bookkeeping contract EXACTLY: write_pc => pc=current_pc, npc=current_pc+4; run handler; return
  // sizeof(AnyCallback)+sizeof(SpecializedInterpretOperands). The dispatch switch is shared with
  // ExecuteOneBlock via the CIR_SPEC_SWITCH macro so the two can never diverge.
  template <bool write_pc>
  static s32 InterpretSpecialized(PowerPC::PowerPCState& ppc_state,
                                  const SpecializedInterpretOperands& operands);
  template <bool write_pc>
  static s32 InterpretAndCheckExceptions(PowerPC::PowerPCState& ppc_state,
                                         const InterpretAndCheckExceptionsOperands& operands);
  template <bool write_pc>
  static s32 InterpretAndCheckExceptions(std::ostream& stream,
                                         const InterpretAndCheckExceptionsOperands& operands);
  // iCube WIN#1: PIC direct-pointer load/store (MAIN_CIR_PIC_LOADSTORE). Computes the effective
  // address, resolves the host RAM region directly (bypassing the per-access MMU/region lookup), and
  // does the load/store with the correct endian swap. INTEGER D-form / X-form only (FP excluded at
  // emission via FL_USE_FPU); any opcode/alignment/region the fast path does not handle delegates to
  // Cold_LoadStoreFallback, which runs the exact generic interpreter handler (operands.func), so
  // semantics are identical to the generic path for everything PIC does not specialize. ALWAYS
  // memcheck-gated at the emission site (MMU-mode / watchpoints take the generic exception path).
  template <bool write_pc>
  static s32 LoadStoreDFormPIC(PowerPC::PowerPCState& ppc_state,
                               const LoadStoreDFormPICOperands& operands);
  template <bool write_pc>
  static s32 LoadStoreDFormPIC(std::ostream& stream, const LoadStoreDFormPICOperands& operands);
  template <bool write_pc>
  static s32 LoadStoreXFormPIC(PowerPC::PowerPCState& ppc_state,
                               const LoadStoreDFormPICOperands& operands);
  template <bool write_pc>
  static s32 LoadStoreXFormPIC(std::ostream& stream, const LoadStoreDFormPICOperands& operands);
  // Cold fallback: runs the exact generic interpreter handler. Preserves DSI/alignment/MMIO semantics.
  static s32 Cold_LoadStoreFallback(PowerPC::PowerPCState& ppc_state,
                                    const LoadStoreDFormPICOperands& operands);
  // iCube WIN#2: execute a fused run of pure-register integer/immediate micro-ops via a computed-goto
  // dispatch over the packed MicroOp array (MAIN_CIR_MICROOP_FUSION). Each handler reproduces the
  // corresponding interpreter op's GPR/CR0/XER side-effects byte-exactly (CR/XER via the same
  // CI_UpdateCR0/CI_WriteCRField/CI_Helper_Carry/CI_HasAddOverflowed helpers the generic compare/
  // arithmetic ops use). write_pc mirrors Interpret<write_pc>. ONLY emitted when the flag is on;
  // dispatched through the existing generic indirect tail in ExecuteOneBlock (no hot-path branch).
  template <bool write_pc>
  static s32 ExecuteMicroOps(PowerPC::PowerPCState& ppc_state,
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

// iCube: payload for the block-linking trampoline (MAIN_CIR_BLOCK_LINKING). The first three fields
// mirror EndBlockOperands<false> so the accounting in LinkBlock is identical to EndBlock<false>.
// expected_pc is the STATIC branch target (op.branchTo) this exit was compiled for — LinkBlock only
// follows the link when ppc_state.npc == expected_pc (fail-safe deopt otherwise). rel is the patched
// relative distance (bytes) from the start of THIS callback (the AnyCallback slot) to the target
// block's normalEntry; 0 means "not linked / unlinked" and forces a dispatcher exit. rel is the ONLY
// field WriteLinkBlock mutates after emit. Layout is 24 bytes = 3*alignof(AnyCallback) (8 on arm64),
// trivially copyable, satisfying CachedInterpreterEmitter::Write's size/alignment static_assert.
struct CachedInterpreter::LinkBlockOperands
{
  u32 downcount;
  u32 num_load_stores;
  u32 num_fp_inst;
  u32 expected_pc;
  // Reserved: the feature_flags the source block was compiled under. Recorded at emit for parity with
  // the JitBlock and possible future cross-flag checks; validate-mode instead compares the LIVE
  // ppc_state.feature_flags against the resolved target block, which is the authoritative check.
  u32 feature_flags;
  s32 rel;
};

struct CachedInterpreter::InterpretOperands
{
  Interpreter& interpreter;
  void (*func)(Interpreter&, UGeckoInstruction);  // Interpreter::Instruction
  u32 current_pc;
  UGeckoInstruction inst;
};

// iCube: specialized-op payload (MAIN_CIR_SPECIALIZED_OPS). Inherits the full InterpretOperands so
// the handler-invocation fields (interpreter, func, current_pc, inst) are reused verbatim, then adds
// the compact op-id the ExecuteOneBlock jump-table dispatches on. This is a DISTINCT type from
// InterpretOperands on purpose: the generic flag-off path keeps the unmodified 24-byte
// InterpretOperands, so its stream layout and advancement are byte-identical to stock 2509. The id
// makes this struct larger (id + padding to alignof(AnyCallback)); the specialized branch in
// ExecuteOneBlock advances by sizeof(SpecializedInterpretOperands) accordingly. Trivially copyable;
// the trailing padding keeps sizeof % alignof(AnyCallback) == 0 for the emitter's static_assert.
struct CachedInterpreter::SpecializedInterpretOperands : InterpretOperands
{
  u16 op_id;  // CirSpecOp value; index into the dispatch jump-table
};

struct CachedInterpreter::InterpretAndCheckExceptionsOperands : InterpretOperands
{
  PowerPC::PowerPCManager& power_pc;
  u32 downcount;
};

// iCube WIN#1: PIC load/store payload. Mirrors the InterpretOperands prefix (so Cold_LoadStoreFallback
// can run the exact generic handler), carries the PowerPCManager (parity with the good branch; unused
// on the fast path), and the six fastmem region base/mask pointers captured at emit time. Trivially
// copyable; alignof == alignof(AnyCallback) (8 on arm64) and sizeof is a multiple of 8, satisfying
// CachedInterpreterEmitter::Write's static_assert.
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

// iCube WIN#2: payload for one fused micro-op run (MAIN_CIR_MICROOP_FUSION). The embedded fixed array
// keeps lifetime simple and avoids heap allocs in codegen; kMaxOps bounds a run. Trivially copyable;
// only written into the callback stream when the flag is on, so the generic path never sees it.
struct CachedInterpreter::ExecuteMicroOpsOperands
{
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
