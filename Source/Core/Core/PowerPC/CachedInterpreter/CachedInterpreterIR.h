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
  // iCube IR M3: linkable block terminal (MAIN_CIR_BLOCK_LINKING). Mirrors EndBlock<false>'s accounting
  // exactly, but additionally carries the STATIC branch target (expected_pc) and a resolved pointer to
  // the target block's IR vector (link_target_ir), patched by the block cache's WriteLinkBlock. When the
  // chain in ExecuteOneBlock reaches this op it does the EndBlock accounting and — IFF the slice still
  // has downcount, npc==expected_pc, the link is resolved, the core is still Running, and the hop cap is
  // not hit — continues straight into the target's IR vector WITHOUT a Dispatch() round-trip. Only ever
  // lowered for STATIC direct-branch terminals (the same gating the CIR's WriteEndBlock uses), so we never
  // link past a terminal that can change MSR/feature_flags or toggle EE (sc/rfi/bclr/bcctr/broken/HLE).
  EndBlockLink,
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
  // iCube IR M4: constant-address fusion result (MAIN_CIR_IR_CONST_FUSION). Replaces an adjacent
  // `lis rX,hi` + `addi/addis/subi/ori rX,rX,lo` pair (two interpreter dispatches) with ONE op that writes a
  // precomputed u32 constant into rX. No flags, no CR/CA, no memory, no exception, no pc write — just
  // `gpr[reg] = value`. Only ever lowered when MAIN_CIR_IR_CONST_FUSION is on. The shipping (validate-off)
  // form of M4; the validate-on form is SetRegConstValidate below.
  SetRegConst,
  // iCube IR M4: const-fusion validate op (MAIN_CIR_IR_CONST_FUSION_VALIDATE). Only ever lowered by the
  // fusion pass when BOTH M4 flags are on; double-runs original-pair-vs-precomputed-constant and asserts the
  // resulting rX matches. Never present in a shipping (validate-off) block.
  SetRegConstValidate,
  // iCube IR M5: micro-op fusion result (MAIN_CIR_IR_MICROOP_FUSION). Coalesces a maximal run of N
  // consecutive plain Interpret<false> integer-ALU ops — the ones the shipping CIR's micro-op fusion deems
  // fusible (no flags-controlled-by-Rc that aren't dead, no exception, no PC write, no load/store, the exact
  // is_simple_mop opcode allowlist) — into ONE dispatched IRInst whose handler runs the run in a tight inner
  // loop, calling each op's interpreter func in order. Collapses N per-op IRInst dispatches (switch + branch)
  // to one. The run's (func,inst) pairs live in a per-block side pool (m_block_fused) that shares the IR
  // vector's exact lifetime + deferred-free path; the operand carries a stable pointer into that pool plus an
  // offset/count. Only ever lowered when MAIN_CIR_IR_MICROOP_FUSION is on. The shipping (validate-off) form;
  // the validate-on form is FusedAluRunValidate below.
  FusedAluRun,
  // iCube IR M5: micro-op fusion validate op (MAIN_CIR_IR_MICROOP_FUSION_VALIDATE). Only ever lowered by the
  // fusion pass when BOTH M5 flags are on; double-runs the same run un-fused (per-op) vs fused on a PPC-state
  // snapshot and asserts bit-identical GPR/CR/XER/PC. Never present in a shipping (validate-off) block.
  FusedAluRunValidate,
};

// iCube IR M5: one entry of a fused ALU run — the (interpreter func, decoded instruction) pair the fused
// handler calls. Trivially copyable POD. These live in a per-block pool (CachedInterpreterIR::m_block_fused),
// NOT inline in the IRInst union, so fusion adds ZERO bytes to IRInst (the union stays sized by the existing
// SetRegConstValidate operand).
struct CachedInterpreterIRFusedOp
{
  void (*func)(Interpreter&, UGeckoInstruction);  // Interpreter::Instruction (plain Interpret<false>)
  UGeckoInstruction inst;
};

// Self-contained block cache for the IR engine. Mirrors CachedInterpreterBlockCache's free-range
// reclamation. iCube IR M3: WriteLinkBlock is now real — it patches the source block's EndBlockLink IR
// op (recovered from the anchor at source.exitPtrs) to point at the destination block's IR vector (or
// clears it on unlink/destroy), reusing the SAME upstream JitBaseBlockCache link/unlink machinery the
// shipping CIR uses. There is still no machine-code trampoline (the link target is a vector pointer in
// the engine's side table, not a byte rel into a code tape).
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

  // iCube IR M3: block-linking patcher, invoked by the block cache's WriteLinkBlock (reusing the upstream
  // JitBaseBlockCache link/unlink machinery). Recovers the SOURCE block's IR vector from the anchor at
  // source.exitPtrs, finds its terminal EndBlockLink op, and sets that op's link_target_ir to the
  // destination block's IR vector (dest != nullptr) or clears it to nullptr (dest == nullptr = unlink /
  // destroy). The engine owns m_block_ir + the IR layout, so this lives here, not in the cache.
  void PatchBlockLink(const JitBlock::LinkData& source, const JitBlock* dest);

private:
  // iCube IR M3: the run-state pointer is threaded through so the block-linking chain loop can re-check
  // CPU::State::Running per linked hop (a long chain has no downcount<=0 exit of its own), mirroring the
  // CIR's ExecuteOneBlock(state_ptr) guard.
  void ExecuteOneBlock(const CPU::State* state_ptr);

  bool HandleFunctionHooking(u32 address);
  // iCube IR M3: link_target is the STATIC branch target (op.branchTo) for a linkable terminal, or
  // 0xFFFFFFFF for a non-linkable one (sc/rfi/bclr/bcctr/broken-block/HLE-replace/idle terminals). When
  // linking is on and link_target != 0xFFFFFFFF, a linkable EndBlockLink is emitted; otherwise a plain
  // EndBlock, identical to the pre-M3 path. Default arg keeps the HLE/broken-block call sites unchanged.
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
  struct EndBlockLinkOperands;  // iCube IR M3: linkable terminal payload
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
  // iCube IR M4: payload for the fused constant-set op (target GPR index + precomputed u32 value) and its
  // validate twin (additionally carries the interpreter ref + both original (func,inst) pairs to re-derive
  // the reference rX at execution time).
  struct SetRegConstOperands;
  struct SetRegConstValidateOperands;
  // iCube IR M5: payload for the fused ALU run (interpreter ref + a stable pointer into the per-block pool +
  // offset/count) and its validate twin (additionally the count of run ops for the snapshot double-run).
  struct FusedAluRunOperands;
  struct FusedAluRunValidateOperands;

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

  // Retired IR vectors awaiting release. A block can be destroyed WHILE ExecuteOneBlock is iterating
  // its vector (an interpreted dcbf/icbi/dcbst invalidates the running block -> DestroyBlock ->
  // ReleaseBlockIR), so ReleaseBlockIR moves the vector here instead of freeing it inline (which
  // would dangle the in-flight `for (inst : ir)` -> use-after-free). Released at the next dispatch
  // boundary (top of ExecuteOneBlock) and in ClearCache, when no loop is iterating them.
  std::vector<std::unique_ptr<std::vector<IRInst>>> m_ir_pending_free;

  // iCube IR M5: per-block fused-run pool, keyed by normalEntry — a parallel ownership holder that mirrors
  // m_block_ir EXACTLY (same key, same insert/release/clear sites, same deferred-free discipline). Each block
  // that the micro-op fusion pass touched owns one std::vector<FusedOp> here; a FusedAluRun/Validate op's
  // operand carries a raw pointer to that vector (stable across the unique_ptr move — the identical guarantee
  // m_block_ir relies on) plus an offset/count into it. Nothing LOOKS THIS UP at execution time (the operand
  // points straight at the pool), so it is a pure lifetime owner. Freed in lockstep with the IR vector:
  // ReleaseBlockIR retires it to m_fused_pending_free, ExecuteOneBlock/ClearCache free that list at a
  // dispatch boundary. When the M5 flag is off the pass never runs, so no entry is ever inserted here.
  std::unordered_map<const u8*, std::unique_ptr<std::vector<CachedInterpreterIRFusedOp>>> m_block_fused;
  std::vector<std::unique_ptr<std::vector<CachedInterpreterIRFusedOp>>> m_fused_pending_free;

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
  // iCube IR M5: `fused_pool` is the per-block side pool the micro-op fusion pass appends run (func,inst)
  // pairs into; DoJit owns it and, if non-empty after the passes, inserts it into m_block_fused. When the M5
  // flag is off the pass never touches it, so it stays empty and no pool entry is created.
  void RunIROptimizationPasses(std::vector<IRInst>& ir,
                               std::vector<CachedInterpreterIRFusedOp>& fused_pool) const;

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

  // iCube IR M4: constant-address fusion pass. Walks the lowered IR vector and folds each adjacent
  // `lis rX,hi` (addis rX,r0,hi) + `addi/addis/subi/ori rX,rX,lo` pair of plain Interpret<false> ops into one
  // SetRegConst op writing the precomputed u32 into rX. Rebuilds a fresh vector (IRInst is not move-
  // assignable — the operand union holds reference members — so no in-place erase/insert is possible) and
  // swaps it in. Interior arithmetic pairs only: any terminal (EndBlock/EndBlockLink/its expected_pc),
  // control op, or check is copied through untouched, so the M3 linking invariants are preserved. With the
  // flag off this pass never runs and the vector stays byte-identical to the M3 lowering.
  void PassConstAddrFusion(std::vector<IRInst>& ir) const;

  // iCube IR M4: the const-fusion recognizer. Given two adjacent insts, returns true and fills out_reg /
  // out_value with the folded GPR index + precomputed constant IFF first is `lis rX,hi` (addis, OPCD 15,
  // RA==0) and second is `addi/addis (OPCD 14/15) rX,rX,lo` or `ori (OPCD 24) rX,rX,lo` with rX!=0 (so the
  // interpreter's RA-based source path is taken, not the RA==0 li-style constant path). Both must be plain
  // Interpret (write_pc=false). No record/CR/CA/exception forms exist for these opcodes, so opcode-match IS
  // the flag/exception exclusion. Conservative: any mismatch returns false (don't fuse).
  static bool ConstAddrFusionApplies(const IRInst& first, const IRInst& second, u32& out_reg,
                                     u32& out_value);

  // iCube IR M5: micro-op fusion pass. Scans the lowered IR vector and coalesces maximal runs of consecutive
  // plain Interpret<false> ops whose instruction the CIR's fusible predicate (IsFusibleAluOp, copied verbatim
  // from CachedInterpreter::is_simple_mop) admits into ONE FusedAluRun op. The run's (func,inst) pairs are
  // appended to `pool` (the per-block side pool, owned in m_block_fused); the FusedAluRun operand carries a
  // stable pointer to `pool` plus the run's offset/count. Rebuilds a fresh vector (IRInst is not move-
  // assignable) and swaps it in, exactly like M4. A run breaks at the FIRST non-fusible op, so any terminal
  // (EndBlock/EndBlockLink and its expected_pc), control op, check, HLE, idle, InterpretChk, InterpretPC, or
  // non-allowlisted Interpret is copied through untouched — the M3 linking invariants are preserved by
  // construction (a terminal is never inside a run, and PatchBlockLink still finds it by its expected_pc
  // scan). With the flag off the pass never runs and the vector stays byte-identical to the M4 lowering.
  void PassMicroOpFusion(std::vector<IRInst>& ir,
                         std::vector<CachedInterpreterIRFusedOp>& pool) const;

  // iCube IR M5: the fusible-op predicate, COPIED VERBATIM from the shipping CIR's is_simple_mop (see
  // CachedInterpreter::DoJit). Returns true IFF the instruction is one of the no-flag(-unless-dead) /
  // no-exception / no-PC-write / no-load-store integer ALU opcodes the CIR fuses. The caller additionally
  // requires the op be a plain IROp::Interpret (which already encodes write_pc=false, non-terminal,
  // non-exception, non-memcheck-loadstore, non-skip) and re-checks FL_LOADSTORE/FL_USE_FPU for an exact
  // mirror of the CIR's run-build guard. Conservative: any opcode not on the allowlist returns false.
  static bool IsFusibleAluOp(UGeckoInstruction inst);

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
  // iCube IR M3: emit a linkable terminal (records a JitBlock::LinkData so the upstream linker resolves
  // it). exitPtrs is set to the block's anchor slot so PatchBlockLink can recover this block's IR vector.
  void EmitEndBlockLink(const EndBlockLinkOperands& operands, u32 link_target);
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
  // iCube IR M3: linkable terminal handler. Does the EndBlock<false> accounting (pc/downcount/PMC), then
  // returns whether the chain may follow the link: the returned value is the link guard result, NOT a
  // tape distance (the IR engine has no tape rel). ExecuteOneBlock interprets it directly.
  static s32 EndBlockLink(PowerPC::PowerPCState& ppc_state, const EndBlockLinkOperands& operands);
  static s32 EndBlockLink(std::ostream& stream, const EndBlockLinkOperands& operands);
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
  // iCube IR M4: fused constant-set handler. `ppc_state.gpr[reg] = value;` — no flags, no CR/CA, no memory,
  // no pc write. Returns its own size (nonzero => the dispatch loop continues). The folded pair is always
  // mid-block (lis/addi/ori never canEndBlock and aren't FP/loadstore, so both source ops are plain
  // Interpret<false>), so there is no write_pc variant.
  static s32 SetRegConst(PowerPC::PowerPCState& ppc_state, const SetRegConstOperands& operands);
  static s32 SetRegConst(std::ostream& stream, const SetRegConstOperands& operands);
  // iCube IR M4: const-fusion validate handler. Double-runs the original two ops (reference rX) vs the
  // precomputed constant (the SHIPPING form, committed last) and asserts the resulting rX matches.
  static s32 SetRegConstValidate(PowerPC::PowerPCState& ppc_state,
                                 const SetRegConstValidateOperands& operands);
  static s32 SetRegConstValidate(std::ostream& stream, const SetRegConstValidateOperands& operands);
  // iCube IR M5: fused-ALU-run handler. Runs the run's N (func,inst) pairs in a tight inner loop, calling each
  // op's interpreter func in order — one IRInst dispatch instead of N. Each op is a plain Interpret<false>
  // (no pc/npc, no exception check), so the loop is byte-identical to running those N IROp::Interpret ops back
  // to back. The run is always mid-block (fusible ops never canEndBlock and aren't FP/loadstore), so there is
  // no write_pc variant. Returns its own size (nonzero => the dispatch loop continues).
  static s32 FusedAluRun(PowerPC::PowerPCState& ppc_state, const FusedAluRunOperands& operands);
  static s32 FusedAluRun(std::ostream& stream, const FusedAluRunOperands& operands);
  // iCube IR M5: fused-run validate handler. Snapshots the full PPC state set (GPR/CR/XER/PC/NPC/Exceptions),
  // runs the run un-fused (per-op), captures the result, restores, runs the fused form (the SHIPPING path,
  // committed last), and asserts bit-identical state. Since the fused path calls the SAME funcs in the SAME
  // order, the two are structurally equal — this catches pass-CONSTRUCTION bugs (miscopied func/inst, wrong
  // run boundary), not arithmetic divergence (there is none to catch). Mirrors the M2/M4 validate discipline.
  static s32 FusedAluRunValidate(PowerPC::PowerPCState& ppc_state,
                                 const FusedAluRunValidateOperands& operands);
  static s32 FusedAluRunValidate(std::ostream& stream, const FusedAluRunValidateOperands& operands);

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

// iCube IR M3: linkable-terminal payload (MAIN_CIR_BLOCK_LINKING). The first three fields mirror
// EndBlockOperands<false> so EndBlockLink's accounting is identical to EndBlock<false>. expected_pc is the
// STATIC branch target (op.branchTo) this exit was compiled for — the chain follows the link only when
// ppc_state.npc == expected_pc (fail-safe deopt to the dispatcher otherwise; the not-taken edge of a bcx
// naturally has npc == fallthrough != expected_pc). link_target_ir is the resolved pointer to the target
// block's IR vector, patched by PatchBlockLink (nullptr == not linked / unlinked == forces a Dispatch()).
// This is the IR analogue of the CIR LinkBlockOperands' `rel`, but a vector pointer (side table) instead
// of a byte offset into a code tape. The cache mutates ONLY link_target_ir after emit; everything else is
// immutable, matching the CIR's single-mutable-field discipline.
struct CachedInterpreterIR::EndBlockLinkOperands
{
  u32 downcount;
  u32 num_load_stores;
  u32 num_fp_inst;
  u32 expected_pc;
  std::vector<IRInst>* link_target_ir;
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

// iCube IR M4: payload for the fused constant-set op (MAIN_CIR_IR_CONST_FUSION). reg is the target GPR
// index, value the precomputed u32. POD — no reference members — so it constructs/copies trivially.
struct CachedInterpreterIR::SetRegConstOperands
{
  u32 reg;
  u32 value;
};

// iCube IR M4: payload for the const-fusion validate op (MAIN_CIR_IR_CONST_FUSION_VALIDATE). Carries the
// folded result (reg/value) PLUS the interpreter reference and BOTH original (func,inst) pairs so the handler
// can recompute the reference rX by re-running the original two ops, then assert it equals the precomputed
// value. Only ever lowered when MAIN_CIR_IR_CONST_FUSION_VALIDATE is on.
struct CachedInterpreterIR::SetRegConstValidateOperands
{
  Interpreter& interpreter;
  u32 reg;
  u32 value;
  void (*func1)(Interpreter&, UGeckoInstruction);  // lis rX,hi
  UGeckoInstruction inst1;
  void (*func2)(Interpreter&, UGeckoInstruction);  // addi/addis/ori rX,rX,lo
  UGeckoInstruction inst2;
};

// iCube IR M5: payload for the fused ALU run (MAIN_CIR_IR_MICROOP_FUSION). interpreter is the engine passed
// to each run op's func; pool points at the per-block side pool (m_block_fused entry, stable across its
// owning unique_ptr's moves); offset/count select this run's contiguous (func,inst) span within the pool.
// 24 bytes (ref 8 + ptr 8 + 2*u32) — smaller than the existing SetRegConstValidateOperands, so it adds ZERO
// bytes to the IRInst union. The fused ops are all plain Interpret<false>, so no pc/current_pc is needed.
struct CachedInterpreterIR::FusedAluRunOperands
{
  Interpreter& interpreter;
  const std::vector<CachedInterpreterIRFusedOp>* pool;
  u32 offset;
  u32 count;
};

// iCube IR M5: payload for the fused-run validate op (MAIN_CIR_IR_MICROOP_FUSION_VALIDATE). Same fields as the
// shipping op — the validate handler re-runs the very same pool span both un-fused and fused on a state
// snapshot and asserts equality, so it needs nothing extra.
struct CachedInterpreterIR::FusedAluRunValidateOperands : CachedInterpreterIR::FusedAluRunOperands
{
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
    EndBlockLinkOperands end_block_link;  // iCube IR M3: linkable terminal
    InterpretOperands interpret;
    InterpretAndCheckExceptionsOperands interpret_chk;
    HLEFunctionOperands hle;
    WriteBrokenBlockNPCOperands broken_npc;
    CheckHaltOperands check_halt;  // shared by CheckFPU + CheckBreakpoint
    CheckIdleOperands check_idle;
    CheckCtrIdleOperands ctr_idle;
    InterpretDeadFlagValidateOperands dead_flag_validate;  // M2 validate op
    SetRegConstOperands set_reg_const;                     // iCube IR M4: fused constant-set
    SetRegConstValidateOperands set_reg_const_validate;    // iCube IR M4: const-fusion validate op
    FusedAluRunOperands fused_alu_run;                      // iCube IR M5: fused ALU run
    FusedAluRunValidateOperands fused_alu_run_validate;     // iCube IR M5: fused-run validate op
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
