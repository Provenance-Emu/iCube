// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <cstddef>
#include <memory>
#include <unordered_map>
#include <utility>
#include <vector>

#include <rangeset/rangesizeset.h>

#include "Common/CommonTypes.h"
#include "Core/PowerPC/CachedInterpreter/CachedInterpreterEmitter.h"
#include "Core/PowerPC/Interpreter/Interpreter.h"
#include "Core/PowerPC/JitCommon/JitBase.h"
#include "Core/PowerPC/JitCommon/JitCache.h"
#include "Core/PowerPC/PPCAnalyst.h"

namespace CoreTiming
{
class CoreTimingManager;
}
namespace CPU
{
enum class State;
}

// iCube Milestone 0: a THIRD selectable CPU execution engine, parallel to the shipping
// CachedInterpreter (CPUCore 5). For M0 it is byte-for-byte BEHAVIORALLY IDENTICAL to the stock
// data-interpreted CachedInterpreter (no IR lowering yet): it emits the same Interpret<>/
// InterpretAndCheckExceptions<>/Check*/HLE/EndBlock callback stream and dispatches it the same way.
// It exists purely to prove the registration/build/dispatch plumbing end-to-end so the IR engine can
// be developed and A/B-tested alongside CachedInterpreter WITHOUT touching it. It reuses the standalone
// CachedInterpreterEmitter / CachedInterpreterCodeBlock (data callbacks, NO machine code => inherits the
// no-JIT-entitlement App-Store-legal memory model by construction) and the shared JitBase
// (analyzer / code buffer / JitState / fastmem options). It owns a SELF-CONTAINED block cache subclass
// so it has zero source coupling to the shipping CachedInterpreter class. None of the iCube CIR perf
// flags (PIC / fusion / linking / dead-flag / profiler / specialized ops) are present here — those get
// reintroduced as IR passes in later milestones.
class CachedInterpreterIR;

// ============================================================================
// iCube Milestone 1: explicit typed IR node layer.
//
// M0 serialized a function-pointer + POD-operands record per CodeOp into the emitter buffer and
// dispatched by walking that callback tape. M1 introduces an explicit typed IRInst node between
// decode (DoJit) and dispatch (ExecuteOneBlock): every CodeOp is lowered 1:1 into exactly one
// IRInst (same handler, same operands), and dispatch is a switch over IRInst records.
//
// This is a PURE REPRESENTATION CHANGE: no fusion, no flag elimination, no specialization. Behavior
// is byte-identical to M0 / the stock Cached Interpreter. It stays data-interpreted (no machine code
// is emitted), so it inherits the App-Store-legal no-codegen memory model unchanged.
//
// Storage: the per-block IRInst sequence lives in a std::vector<IRInst> owned by the engine in a
// side table keyed by the block's normalEntry. To keep ALL existing JitBlock plumbing intact
// (near_begin/near_end ranges, free-range reclamation, block-cache Dispatch() by normalEntry) the
// engine still writes exactly ONE small "anchor" record into the emitter buffer per block; that
// anchor carries a pointer to the block's IR vector. ExecuteOneBlock recovers the vector from the
// anchor at the block's normalEntry and runs the dispatch loop over it.
// ============================================================================

// One-to-one with the static handler functions M0 emitted. Each IROp value selects exactly one
// handler in ExecuteOneBlock's switch; the lowering in DoJit emits exactly one IRInst per CodeOp
// callback M0 would have written, in the same order.
enum class IROp : u8
{
  StartProfiledBlock,
  EndBlock,           // EndBlock<false>
  EndBlockProfiled,   // EndBlock<true>
  Interpret,          // Interpret<false>
  InterpretPC,        // Interpret<true>
  InterpretChk,       // InterpretAndCheckExceptions<false>
  InterpretChkPC,     // InterpretAndCheckExceptions<true>
  HLEFunction,
  WriteBrokenBlockNPC,
  CheckFPU,
  CheckBreakpoint,
  CheckIdle,
  FastForwardCtrIdle,
  // iCube M2: optimizer-pass validate op (MAIN_CIR_IR_DEAD_FLAG_ELIM_VALIDATE). Only ever lowered into
  // the vector by the dead-flag pass when BOTH M2 flags are on; double-runs ref-vs-eliminated and asserts
  // the live CR fields match. Never present in a shipping (validate-off) block.
  InterpretDeadFlagValidate,
};

// Self-contained block cache for the IR engine. Mirrors CachedInterpreterBlockCache's free-range
// reclamation, but does NOT support block linking (M0 has no LinkBlock trampoline), so WriteLinkBlock
// is a no-op and there is no coupling to any other engine's link-patch helper.
class CachedInterpreterIRBlockCache final : public JitBaseBlockCache
{
public:
  explicit CachedInterpreterIRBlockCache(JitBase& jit);

  void Init() override;

  void DestroyBlock(JitBlock& block) override;

  void ClearRangesToFree();

  const std::vector<std::pair<u8*, u8*>>& GetRangesToFree() const
  {
    return m_ranges_to_free_on_next_codegen;
  }

private:
  void WriteLinkBlock(const JitBlock::LinkData& source, const JitBlock* dest) override;
  void WriteDestroyBlock(const JitBlock& block) override;

  std::vector<std::pair<u8*, u8*>> m_ranges_to_free_on_next_codegen;
};

class CachedInterpreterIR : public JitBase, public CachedInterpreterCodeBlock
{
public:
  explicit CachedInterpreterIR(Core::System& system);
  CachedInterpreterIR(const CachedInterpreterIR&) = delete;
  CachedInterpreterIR(CachedInterpreterIR&&) = delete;
  CachedInterpreterIR& operator=(const CachedInterpreterIR&) = delete;
  CachedInterpreterIR& operator=(CachedInterpreterIR&&) = delete;
  ~CachedInterpreterIR() override;

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
  const char* GetName() const override { return "Cached Interpreter (IR, experimental)"; }
  const CommonAsmRoutinesBase* GetAsmRoutines() override { return nullptr; }

  // Called by the block cache when a block is destroyed: frees that block's IR vector from the
  // side table. Keyed by the anchor record at the block's normalEntry.
  void ReleaseBlockIR(const JitBlock& block);

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
  struct HLEFunctionOperands;
  struct WriteBrokenBlockNPCOperands;
  struct CheckHaltOperands;
  struct CheckIdleOperands;
  struct CheckCtrIdleOperands;
  // iCube M2: payload for the dead CR-flag elimination validate op. Carries the eliminated (Rc-cleared)
  // shipping inst (the InterpretOperands base), the original (Rc-set) reference inst, and the crOut mask of
  // fields allowed to differ. Only ever lowered when MAIN_CIR_IR_DEAD_FLAG_ELIM_VALIDATE is on.
  struct InterpretDeadFlagValidateOperands;

public:
  // The explicit typed IR node. A 1:1 lowering does not need compactness, so this is a plain tagged
  // union holding (the active member of) every operand struct the handlers read. Because the operand
  // structs contain reference members, the union has no default constructor; an IRInst is always
  // constructed fully via designated-init of the active member (see DoJit's Emit* helpers).
  struct IRInst;

private:
  // Per-block IR storage. Owned by the engine, keyed by the block's normalEntry (the address of the
  // anchor record the emitter wrote for that block). Looked up O(1) in ExecuteOneBlock via the
  // pointer carried in the anchor; freed in ReleaseBlockIR / ClearCache.
  std::unordered_map<const u8*, std::unique_ptr<std::vector<IRInst>>> m_block_ir;

  // Anchor record placed in the emitter buffer (one per block) so the normal JitBlock plumbing
  // (near_begin/near_end ranges, reclamation, Dispatch-by-normalEntry) keeps working unchanged.
  // It carries a raw pointer to the block's IR vector for O(1) recovery at dispatch time.
  struct IRBlockAnchorOperands
  {
    std::vector<IRInst>* ir;
  };
  static s32 IRBlockAnchor(PowerPC::PowerPCState& ppc_state, const IRBlockAnchorOperands& operands);
  static s32 IRBlockAnchor(std::ostream& stream, const IRBlockAnchorOperands& operands);

  // Runs one lowered IRInst against ppc_state. Returns the handler's value (0 => exit block).
  static s32 DispatchIRInst(PowerPC::PowerPCState& ppc_state, const IRInst& inst);

  // ==========================================================================
  // iCube M2: IR optimizer-pass framework.
  //
  // After DoJit lowers the block 1:1 into the IRInst vector (and AFTER the M1 DOLPHIN_IR_VALIDATE 1:1
  // self-check, which only describes the unoptimized lowering) but BEFORE the anchor is written, this stage
  // runs zero or more linear-IR passes that walk/rewrite the IRInst vector in place. Each pass is gated by
  // its own config flag; registering a future pass is a one-line `if (flag) Pass(ir);` in the .cpp. Passes
  // are LINEAR-IR shaped — they read the per-inst metadata (crOut/crDiscardable/flags/Rc copied in at lower
  // time) and rewrite inst fields; no loop-pattern recognition. With every M2 flag OFF this stage makes ZERO
  // edits, so the vector stays byte-identical to the M1 lowering and behavior is unchanged.
  // ==========================================================================
  void RunIROptimizationPasses(std::vector<IRInst>& ir) const;

  // First pass: dead CR-flag elimination. Mirrors the shipping CIR's MAIN_CIR_DEAD_FLAG_ELIM exactly:
  // for an Rc-form plain Interpret op whose ENTIRE crOut is discardable (proven dead by PPCAnalyst), clear
  // the Rc bit in the lowered inst word so the same handler skips the dead CR. When the validate flag is on,
  // the eliminated inst is instead rewritten into an InterpretDeadFlagValidate op that double-runs and
  // asserts the live CR fields match. Consumes PPCAnalyst liveness via the per-inst metadata; does not
  // re-run or fork the analysis.
  void PassDeadFlagElim(std::vector<IRInst>& ir) const;

  // The dead-flag-elim predicate, byte-identical to the CIR's DeadFlagElimApplies but reading the per-inst
  // metadata the lowering copied from PPCAnalyst's CodeOp (crOut/crDiscardable/opinfo flags/Rc).
  static bool DeadFlagElimApplies(const IRInst& inst);

  // DOLPHIN_IR_VALIDATE=1 opt-in self-check: re-emits the M0 callback tape into a scratch buffer and
  // asserts the lowered IR vector is 1:1 with it (same count, op<->callback, operands). Default off.
  void ValidateBlockIR(const std::vector<IRInst>& ir) const;

  // DoJit lowering state. m_current_ir points at the block's IR vector being built; the Emit*
  // helpers append exactly one IRInst per CodeOp callback M0 would have written. When m_validate is
  // set (DOLPHIN_IR_VALIDATE=1) each Emit* also Write()s the equivalent M0 callback into
  // m_validate_buffer via m_validate_emitter, giving an independent serialization to diff against.
  std::vector<IRInst>* m_current_ir = nullptr;
  bool m_validate = false;
  std::vector<u8> m_validate_buffer;
  CachedInterpreterEmitter m_validate_emitter;

  // Emit one IRInst (and, when validating, the M0 callback). One call == one M0 Write().
  void EmitStartProfiledBlock(const StartProfiledBlockOperands& operands);
  template <bool profiled>
  void EmitEndBlock(const EndBlockOperands<profiled>& operands);
  template <bool write_pc>
  void EmitInterpret(const InterpretOperands& operands);
  template <bool write_pc>
  void EmitInterpretChk(const InterpretAndCheckExceptionsOperands& operands);
  void EmitHLEFunction(const HLEFunctionOperands& operands);
  void EmitWriteBrokenBlockNPC(const WriteBrokenBlockNPCOperands& operands);
  void EmitCheckFPU(const CheckHaltOperands& operands);
  void EmitCheckBreakpoint(const CheckHaltOperands& operands);
  void EmitCheckIdle(const CheckIdleOperands& operands);
  void EmitFastForwardCtrIdle(const CheckCtrIdleOperands& operands);

  static s32 StartProfiledBlock(PowerPC::PowerPCState& ppc_state,
                                const StartProfiledBlockOperands& operands);
  static s32 StartProfiledBlock(std::ostream& stream, const StartProfiledBlockOperands& operands);
  template <bool profiled>
  static s32 EndBlock(PowerPC::PowerPCState& ppc_state, const EndBlockOperands<profiled>& operands);
  template <bool profiled>
  static s32 EndBlock(std::ostream& stream, const EndBlockOperands<profiled>& operands);
  template <bool write_pc>
  static s32 Interpret(PowerPC::PowerPCState& ppc_state, const InterpretOperands& operands);
  template <bool write_pc>
  static s32 Interpret(std::ostream& stream, const InterpretOperands& operands);
  template <bool write_pc>
  static s32 InterpretAndCheckExceptions(PowerPC::PowerPCState& ppc_state,
                                         const InterpretAndCheckExceptionsOperands& operands);
  template <bool write_pc>
  static s32 InterpretAndCheckExceptions(std::ostream& stream,
                                         const InterpretAndCheckExceptionsOperands& operands);
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
  // iCube M2: dead CR-flag elimination validate (MAIN_CIR_IR_DEAD_FLAG_ELIM_VALIDATE). Double-runs the op
  // (reference Rc-set CR vs eliminated Rc-cleared, the eliminated form committed last = shipping behavior)
  // and asserts every CR field OUTSIDE the eliminated crOut mask (the live/continuation-read fields) is
  // byte-identical. Returns its own size (nonzero => continue): the eliminated op is mid-block by
  // construction (crDiscardable is reset at every block-exit/exception boundary, so only plain
  // write_pc=false Interpret ops ever qualify), so there is no write_pc variant.
  static s32 InterpretDeadFlagValidate(PowerPC::PowerPCState& ppc_state,
                                       const InterpretDeadFlagValidateOperands& operands);
  static s32 InterpretDeadFlagValidate(std::ostream& stream,
                                       const InterpretDeadFlagValidateOperands& operands);

  HyoutaUtilities::RangeSizeSet<u8*> m_free_ranges;
  CachedInterpreterIRBlockCache m_block_cache;
};

struct CachedInterpreterIR::StartProfiledBlockOperands
{
  JitBlock::ProfileData* profile_data;
};

template <>
struct CachedInterpreterIR::EndBlockOperands<false>
{
  u32 downcount;
  u32 num_load_stores;
  u32 num_fp_inst;
  u32 : 32;
};

template <>
struct CachedInterpreterIR::EndBlockOperands<true> : CachedInterpreterIR::EndBlockOperands<false>
{
  JitBlock::ProfileData* profile_data;
};

struct CachedInterpreterIR::InterpretOperands
{
  Interpreter& interpreter;
  void (*func)(Interpreter&, UGeckoInstruction);  // Interpreter::Instruction
  u32 current_pc;
  UGeckoInstruction inst;
};

struct CachedInterpreterIR::InterpretAndCheckExceptionsOperands : InterpretOperands
{
  PowerPC::PowerPCManager& power_pc;
  u32 downcount;
};

// iCube M2: payload for the dead CR-flag elimination validate op (MAIN_CIR_IR_DEAD_FLAG_ELIM_VALIDATE).
// The InterpretOperands base carries the ELIMINATED (Rc-cleared) inst the shipping path runs; ref_inst is
// the ORIGINAL (Rc-set) inst used as the CR reference; elim_cr_mask is the op's crOut — the CR fields proven
// discardable and therefore allowed to differ. func is the SAME opcode-keyed handler for both (Rc 0/1
// select the same GetInterpreterOp entry). Mirrors the CIR's InterpretDeadFlagValidateOperands.
struct CachedInterpreterIR::InterpretDeadFlagValidateOperands : InterpretOperands
{
  UGeckoInstruction ref_inst;  // original (Rc set) — computes the reference CR
  u32 elim_cr_mask;            // op.crOut: the fields allowed to differ (all discardable)
};

struct CachedInterpreterIR::HLEFunctionOperands
{
  Core::System& system;
  u32 current_pc;
  u32 hook_index;
};

struct CachedInterpreterIR::WriteBrokenBlockNPCOperands
{
  u32 current_pc;
  u32 : 32;
};

struct CachedInterpreterIR::CheckHaltOperands
{
  PowerPC::PowerPCManager& power_pc;
  u32 current_pc;
  u32 downcount;
};

struct CachedInterpreterIR::CheckIdleOperands
{
  CoreTiming::CoreTimingManager& core_timing;
  u32 idle_pc;
};

struct CachedInterpreterIR::CheckCtrIdleOperands
{
  CoreTiming::CoreTimingManager& core_timing;
  u32 idle_pc;         // PC of the CTR-branch at loop end
  u32 fallthrough_pc;  // PC after the branch (loop exit)
};

// The explicit typed IR node: an op tag plus a union of every operand struct the handlers read.
// Exactly one operand member is active per inst, selected by `op`. The operand structs hold
// reference members, so the union is constructed via designated-init of the active member only.
struct CachedInterpreterIR::IRInst
{
  IROp op;
  union Operands
  {
    StartProfiledBlockOperands start_profiled_block;
    EndBlockOperands<false> end_block;
    EndBlockOperands<true> end_block_profiled;
    InterpretOperands interpret;
    InterpretAndCheckExceptionsOperands interpret_chk;
    HLEFunctionOperands hle;
    WriteBrokenBlockNPCOperands broken_npc;
    CheckHaltOperands check_halt;  // shared by CheckFPU + CheckBreakpoint
    CheckIdleOperands check_idle;
    CheckCtrIdleOperands ctr_idle;
    InterpretDeadFlagValidateOperands dead_flag_validate;  // M2 validate op
  } u;

  // iCube M2: per-inst PPCAnalyst liveness metadata, copied from the source CodeOp at lower time (only
  // meaningful for Interpret/InterpretPC ops; left zero for control ops). The dead-flag optimizer pass
  // CONSUMES this — it does not re-run or fork the analysis. Sits OUTSIDE the operand union (AFTER it so the
  // existing positional `IRInst{op, {.member = ...}}` aggregate-inits keep working) so the handlers never
  // read it and the M1 DOLPHIN_IR_VALIDATE (which compares only the operand fields) stays unaffected; with
  // the M2 flags off these bytes are never read, so behavior is byte-identical to the M1 lowering.
  u8 cr_out = 0;          // BitSet8 op.crOut — CR fields this op writes
  u8 cr_discardable = 0;  // BitSet8 op.crDiscardable — CR fields proven dead (overwritten before any read)
  u64 opinfo_flags = 0;   // op.opinfo->flags — for the FL_RC_BIT / FL_RC_BIT_F guard
};
