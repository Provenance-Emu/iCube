// Copyright 2026 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include "Core/PowerPC/CachedInterpreter/CachedInterpreterIR.h"

#include <algorithm>
#include <array>
#include <cstdlib>
#include <mutex>
#include <new>
#include <ranges>
#include <span>
#include <sstream>
#include <utility>

#include <fmt/format.h>
#include <fmt/ostream.h>

#include "Common/Assert.h"
#include "Common/CommonTypes.h"
#include "Common/GekkoDisassembler.h"
#include "Common/Logging/Log.h"
#include "Core/Config/MainSettings.h"
#include "Core/ConfigManager.h"
#include "Core/Core.h"
#include "Core/CoreTiming.h"
#include "Core/HLE/HLE.h"
#include "Core/HW/CPU.h"
#include "Core/Host.h"
#include "Core/PowerPC/Gekko.h"
#include "Core/PowerPC/Interpreter/Interpreter.h"
#include "Core/PowerPC/Jit64Common/Jit64Constants.h"  // CODE_SIZE
#include "Core/PowerPC/PPCAnalyst.h"
#include "Core/PowerPC/PowerPC.h"
#include "Core/System.h"

// iCube M2: IR optimizer-pass flags, read once at codegen time (in ClearCache/RefreshConfig, mirroring the
// CIR's Init read). When both are false the optimizer-pass stage makes ZERO edits to the lowered vector, so
// the IR engine's behavior is byte-identical to M1. Config changes require a core restart (the established
// CIR pattern — these are read once, not per-block).
static bool s_ir_dead_flag_elim = false;
static bool s_ir_dead_flag_elim_validate = false;

// iCube IR M4: constant-address fusion flags, read once at Init (mirroring the M2 reads). When both are false
// the pass makes ZERO edits to the lowered vector, so the engine's behavior is byte-identical to M3.
static bool s_ir_const_fusion = false;
static bool s_ir_const_fusion_validate = false;

// iCube IR M5: micro-op fusion flags, read once at Init (mirroring the M2/M4 reads). When both are false the
// pass makes ZERO edits to the lowered vector, so the engine's behavior is byte-identical to M4.
static bool s_ir_microop_fusion = false;
static bool s_ir_microop_fusion_validate = false;

// iCube IR M3: block linking (reuses MAIN_CIR_BLOCK_LINKING, default true => ON for the IR core, since it
// is correctness-preserving by construction). Read once in Init, mirroring the CIR's read-once discipline.
// When false, EndBlockLink ops are never lowered (plain EndBlock instead) and jo.enableBlocklink stays off,
// so the engine's behavior is byte-identical to the pre-M3 (M2) lowering.
static bool s_ir_block_linking = false;

// iCube IR M3: bound on consecutive linked hops inside one ExecuteOneBlock, mirroring the CIR's
// CIR_MAX_LINKED_HOPS. Forces a dispatcher round-trip after this many links regardless of downcount, so a
// wake-race can't spin unbounded. A fresh local per ExecuteOneBlock entry resets it.
static constexpr u32 IR_MAX_LINKED_HOPS = 256;

// ============================================================================
// Self-contained block cache (mirrors CachedInterpreterBlockCache, minus block linking).
// ============================================================================

CachedInterpreterIRBlockCache::CachedInterpreterIRBlockCache(JitBase& jit) : JitBaseBlockCache{jit}
{
}

void CachedInterpreterIRBlockCache::Init()
{
  JitBaseBlockCache::Init();
  ClearRangesToFree();
}

void CachedInterpreterIRBlockCache::DestroyBlock(JitBlock& block)
{
  // Free this block's IR vector from the engine's side table before the block storage goes away.
  static_cast<CachedInterpreterIR&>(m_jit).ReleaseBlockIR(block);

  JitBaseBlockCache::DestroyBlock(block);

  if (block.near_begin != block.near_end)
    m_ranges_to_free_on_next_codegen.emplace_back(block.near_begin, block.near_end);
}

void CachedInterpreterIRBlockCache::ClearRangesToFree()
{
  m_ranges_to_free_on_next_codegen.clear();
}

void CachedInterpreterIRBlockCache::WriteLinkBlock(const JitBlock::LinkData& source,
                                                   const JitBlock* dest)
{
  // iCube IR M3: delegate to the engine, which owns m_block_ir and the IR vector layout. dest != nullptr
  // patches the source block's EndBlockLink op to the target vector; dest == nullptr (unlink/destroy)
  // clears it. Reuses the SAME upstream link/unlink machinery the shipping CIR uses (LinkBlockExits /
  // UnlinkBlock / DestroyBlock all funnel here), so a stale link can never survive a target's destruction:
  // every block-freeing route clears the inbound links via WriteLinkBlock(.., nullptr) before the target's
  // storage is reclaimed.
  static_cast<CachedInterpreterIR&>(m_jit).PatchBlockLink(source, dest);
}

void CachedInterpreterIRBlockCache::WriteDestroyBlock(const JitBlock& block)
{
  CachedInterpreterEmitter emitter(block.normalEntry, block.near_end);
  emitter.Write(CachedInterpreterEmitter::PoisonCallback);
}

// ============================================================================
// CachedInterpreterIR
// ============================================================================

CachedInterpreterIR::CachedInterpreterIR(Core::System& system)
    : JitBase(system), m_block_cache(*this)
{
}

CachedInterpreterIR::~CachedInterpreterIR() = default;

void CachedInterpreterIR::Init()
{
  RefreshConfig();

  // iCube M2: read the optimizer-pass flags once at codegen time. Default OFF => no IR edits.
  s_ir_dead_flag_elim = Config::Get(Config::MAIN_CIR_IR_DEAD_FLAG_ELIM);
  s_ir_dead_flag_elim_validate = Config::Get(Config::MAIN_CIR_IR_DEAD_FLAG_ELIM_VALIDATE);

  // iCube IR M4: read the constant-address fusion flags once. Default OFF => no IR edits.
  s_ir_const_fusion = Config::Get(Config::MAIN_CIR_IR_CONST_FUSION);
  s_ir_const_fusion_validate = Config::Get(Config::MAIN_CIR_IR_CONST_FUSION_VALIDATE);

  // iCube IR M5: read the micro-op fusion flags once. Default OFF => no IR edits.
  s_ir_microop_fusion = Config::Get(Config::MAIN_CIR_IR_MICROOP_FUSION);
  s_ir_microop_fusion_validate = Config::Get(Config::MAIN_CIR_IR_MICROOP_FUSION_VALIDATE);

  // iCube IR M3: read block linking once (reuses MAIN_CIR_BLOCK_LINKING; default true).
  s_ir_block_linking = Config::Get(Config::MAIN_CIR_BLOCK_LINKING);

  AllocCodeSpace(CODE_SIZE);
  ResetFreeMemoryRanges();

  // iCube IR M3: enable the upstream JitBaseBlockCache link/unlink machinery when block linking is on, so
  // FinalizeBlock(block_link) -> LinkBlock -> WriteLinkBlock resolves the EndBlockLink ops and DestroyBlock
  // -> UnlinkBlock -> WriteLinkBlock(.., nullptr) clears them. When off, no LinkData is pushed and this is
  // byte-identical to the prior no-linking path.
  jo.enableBlocklink = s_ir_block_linking;

  m_block_cache.Init();

  code_block.m_stats = &js.st;
  code_block.m_gpa = &js.gpa;
  code_block.m_fpa = &js.fpa;
}

void CachedInterpreterIR::Shutdown()
{
  m_block_cache.Shutdown();
}

s32 CachedInterpreterIR::StartProfiledBlock(PowerPC::PowerPCState& ppc_state,
                                            const StartProfiledBlockOperands& operands)
{
  JitBlock::ProfileData::BeginProfiling(operands.profile_data);
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool profiled>
s32 CachedInterpreterIR::EndBlock(PowerPC::PowerPCState& ppc_state,
                                  const EndBlockOperands<profiled>& operands)
{
  ppc_state.pc = ppc_state.npc;
  ppc_state.downcount -= operands.downcount;
  if (PowerPC::PerformanceMonitorActive(ppc_state))
    PowerPC::UpdatePerformanceMonitor(operands.downcount, operands.num_load_stores,
                                      operands.num_fp_inst, ppc_state);
  if constexpr (profiled)
    JitBlock::ProfileData::EndProfiling(operands.profile_data, operands.downcount);
  return 0;
}

// iCube IR M3: linkable-terminal handler. The accounting (pc/downcount/PMC) is IDENTICAL to EndBlock<false>
// and runs on EVERY exit (linked or not), so the architectural result is exactly what a plain EndBlock
// would have produced. The RETURN VALUE is the link decision, not a tape distance: 1 == "the chain MAY
// follow link_target_ir", 0 == "exit to the dispatcher". The downcount<=0 and npc!=expected_pc guards
// mirror the CIR LinkBlock exactly; the resolved-link (link_target_ir != nullptr) check is the IR analogue
// of CIR's rel!=0. The Running re-check and hop cap are applied by ExecuteOneBlock (it owns the loop).
s32 CachedInterpreterIR::EndBlockLink(PowerPC::PowerPCState& ppc_state,
                                      const EndBlockLinkOperands& operands)
{
  // (1) End-of-block accounting — IDENTICAL to EndBlock<false>.
  ppc_state.pc = ppc_state.npc;
  ppc_state.downcount -= operands.downcount;
  if (PowerPC::PerformanceMonitorActive(ppc_state))
    PowerPC::UpdatePerformanceMonitor(operands.downcount, operands.num_load_stores,
                                      operands.num_fp_inst, ppc_state);

  // (2) Slice-boundary guard: if the timing slice is exhausted, return to the dispatcher / Run loop so
  // CoreTiming::Advance() services the decrementer + external interrupts. Following a link here would
  // starve timing and miss interrupts.
  if (ppc_state.downcount <= 0) [[unlikely]]
    return 0;

  // (3) Target guard: only follow the link when the architectural next PC equals the STATIC branch target
  // this exit was compiled for. Unconditional bx always matches; a bcx matches only on the taken edge (the
  // not-taken edge has npc == fallthrough != expected_pc and deopts). Any computed/indirect divergence
  // also deopts. Fail-safe: a mismatch never runs the wrong stream, just costs one Dispatch() round-trip.
  if (ppc_state.npc != operands.expected_pc) [[unlikely]]
    return 0;

  // (4) Linkage: null means the target is not (yet) compiled or was unlinked/destroyed.
  if (operands.link_target_ir == nullptr) [[unlikely]]
    return 0;

  return 1;  // chain may follow link_target_ir (ExecuteOneBlock applies the Running + hop-cap guards)
}

template <bool write_pc>
s32 CachedInterpreterIR::Interpret(PowerPC::PowerPCState& ppc_state,
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
s32 CachedInterpreterIR::InterpretAndCheckExceptions(
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

s32 CachedInterpreterIR::HLEFunction(PowerPC::PowerPCState& ppc_state,
                                     const HLEFunctionOperands& operands)
{
  const auto& [system, current_pc, hook_index] = operands;
  ppc_state.pc = current_pc;
  HLE::Execute(Core::CPUThreadGuard{system}, current_pc, hook_index);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::WriteBrokenBlockNPC(PowerPC::PowerPCState& ppc_state,
                                             const WriteBrokenBlockNPCOperands& operands)
{
  const auto& [current_pc] = operands;
  ppc_state.npc = current_pc;
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::CheckFPU(PowerPC::PowerPCState& ppc_state,
                                  const CheckHaltOperands& operands)
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

s32 CachedInterpreterIR::CheckBreakpoint(PowerPC::PowerPCState& ppc_state,
                                         const CheckHaltOperands& operands)
{
  const auto& [power_pc, current_pc, downcount] = operands;
  ppc_state.pc = current_pc;
  if (power_pc.CheckAndHandleBreakPoints())
  {
    power_pc.GetPPCState().downcount -= downcount;
    return 0;
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::CheckIdle(PowerPC::PowerPCState& ppc_state,
                                   const CheckIdleOperands& operands)
{
  const auto& [core_timing, idle_pc] = operands;
  if (ppc_state.npc == idle_pc)
    core_timing.Idle();
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::FastForwardCtrIdle(PowerPC::PowerPCState& ppc_state,
                                            const CheckCtrIdleOperands& operands)
{
  const auto& [core_timing, idle_pc, fallthrough_pc] = operands;
  if (ppc_state.npc == idle_pc)
  {
    CTR(ppc_state) = 0;
    ppc_state.pc = idle_pc;
    ppc_state.npc = fallthrough_pc;
    core_timing.Idle();
  }
  return sizeof(AnyCallback) + sizeof(operands);
}

// The single record M0-style plumbing still writes into the emitter buffer per block. It only marks
// the block's storage (so near_begin/near_end/reclamation/Dispatch-by-normalEntry keep working) and
// carries a pointer to that block's IR vector. It is never executed by ExecuteOneBlock (which
// recovers the vector directly), so it just returns "exit block" if ever reached.
s32 CachedInterpreterIR::IRBlockAnchor(PowerPC::PowerPCState& ppc_state,
                                       const IRBlockAnchorOperands& operands)
{
  return 0;
}

// Dispatches one lowered IRInst to the matching static handler with fields unpacked from the union.
// Each handler keeps its exact M0 logic; only the return value's 0-vs-nonzero meaning is used here
// (0 => exit block), so the dispatch contract is preserved exactly. The handlers' nonzero "distance"
// returns are intentionally ignored — iteration advances over the IR vector instead.
s32 CachedInterpreterIR::DispatchIRInst(PowerPC::PowerPCState& ppc_state, const IRInst& inst)
{
  switch (inst.op)
  {
  case IROp::StartProfiledBlock:
    return StartProfiledBlock(ppc_state, inst.u.start_profiled_block);
  case IROp::EndBlock:
    return EndBlock<false>(ppc_state, inst.u.end_block);
  case IROp::EndBlockProfiled:
    return EndBlock<true>(ppc_state, inst.u.end_block_profiled);
  case IROp::EndBlockLink:
    // iCube IR M3: ExecuteOneBlock handles this op inline (it owns the chain + Running/hop-cap guards). If
    // ever dispatched here, treat it as a block exit: EndBlockLink's accounting runs, and we map any
    // "may-follow" (nonzero) to 0 so a caller using the 0==exit contract still terminates correctly rather
    // than mis-following a link it cannot act on.
    EndBlockLink(ppc_state, inst.u.end_block_link);
    return 0;
  case IROp::Interpret:
    return Interpret<false>(ppc_state, inst.u.interpret);
  case IROp::InterpretPC:
    return Interpret<true>(ppc_state, inst.u.interpret);
  case IROp::InterpretChk:
    return InterpretAndCheckExceptions<false>(ppc_state, inst.u.interpret_chk);
  case IROp::InterpretChkPC:
    return InterpretAndCheckExceptions<true>(ppc_state, inst.u.interpret_chk);
  case IROp::HLEFunction:
    return HLEFunction(ppc_state, inst.u.hle);
  case IROp::WriteBrokenBlockNPC:
    return WriteBrokenBlockNPC(ppc_state, inst.u.broken_npc);
  case IROp::CheckFPU:
    return CheckFPU(ppc_state, inst.u.check_halt);
  case IROp::CheckBreakpoint:
    return CheckBreakpoint(ppc_state, inst.u.check_halt);
  case IROp::CheckIdle:
    return CheckIdle(ppc_state, inst.u.check_idle);
  case IROp::FastForwardCtrIdle:
    return FastForwardCtrIdle(ppc_state, inst.u.ctr_idle);
  case IROp::InterpretDeadFlagValidate:
    return InterpretDeadFlagValidate(ppc_state, inst.u.dead_flag_validate);
  case IROp::SetRegConst:
    // iCube IR M4: fast-pathed inline in ExecuteOneBlock; handled here too as the switch fallback and to
    // satisfy -Wswitch on the new enumerator.
    return SetRegConst(ppc_state, inst.u.set_reg_const);
  case IROp::SetRegConstValidate:
    return SetRegConstValidate(ppc_state, inst.u.set_reg_const_validate);
  case IROp::FusedAluRun:
    // iCube IR M5: fast-pathed inline in ExecuteOneBlock; handled here too as the switch fallback and to
    // satisfy -Wswitch on the new enumerator.
    return FusedAluRun(ppc_state, inst.u.fused_alu_run);
  case IROp::FusedAluRunValidate:
    return FusedAluRunValidate(ppc_state, inst.u.fused_alu_run_validate);
  }
  return 0;
}

void CachedInterpreterIR::ReleaseBlockIR(const JitBlock& block)
{
  // Retire (do NOT free inline) the block's IR vector. DestroyBlock can run while ExecuteOneBlock is
  // iterating this very vector (interpreted dcbf/icbi/dcbst -> InvalidateICache -> DestroyBlock ->
  // here), so an inline free would dangle the in-flight `for (inst : ir)` (use-after-free). Move the
  // vector to the pending list; it keeps its heap address across the move, so any in-flight reference
  // stays valid until the next dispatch boundary frees the list (ExecuteOneBlock / ClearCache).
  auto it = m_block_ir.find(block.normalEntry);
  if (it != m_block_ir.end())
  {
    m_ir_pending_free.push_back(std::move(it->second));
    m_block_ir.erase(it);
  }

  // iCube IR M5: retire this block's fused-run pool the same way (parallel map keyed by the same normalEntry).
  // The pool's heap address is stable across the unique_ptr move, so any in-flight FusedAluRun operand
  // pointing at it stays valid until the next dispatch boundary frees the pending list. Absent unless the M5
  // pass produced a fused run for this block.
  auto fit = m_block_fused.find(block.normalEntry);
  if (fit != m_block_fused.end())
  {
    m_fused_pending_free.push_back(std::move(fit->second));
    m_block_fused.erase(fit);
  }
}

// iCube IR M3: patch (dest != nullptr) or clear (dest == nullptr) the source block's link.
//
// source.exitPtrs was set in EmitEndBlockLink to the source block's anchor slot (the AnyCallback at
// normalEntry). The anchor's IRBlockAnchorOperands carries a raw pointer to the source block's IR vector,
// so we recover the vector WITHOUT a side-table lookup. We then find the terminal EndBlockLink op (the one
// whose expected_pc == source.exitAddress) and set/clear its link_target_ir.
//
// SAFETY / deferred-free interaction: this never frees anything and never runs while a chain is iterating
// (it runs at codegen time on the CPU thread, with no ExecuteOneBlock on the stack). When this clears a
// link because the TARGET is being destroyed (UnlinkBlock path), the source's EndBlockLink.link_target_ir
// goes nullptr, so a subsequent chain reaching that terminal deopts to the dispatcher instead of following
// a pointer to a vector that is about to be (deferred-)freed. The source vector itself may already be in
// m_ir_pending_free (if the SOURCE is the block being destroyed): its heap address is stable across the
// unique_ptr move, so the anchor pointer is still valid and patching it is harmless.
void CachedInterpreterIR::PatchBlockLink(const JitBlock::LinkData& source, const JitBlock* dest)
{
  // Recover the source block's IR vector from its anchor. exitPtrs points at the AnyCallback slot; the
  // anchor operands sit immediately after it. (Guard the callback identity defensively: a poisoned slot
  // should never be reached here, but if it were we must not interpret poison bytes as an anchor.)
  const auto callback = *reinterpret_cast<const AnyCallback*>(source.exitPtrs);
  if (callback != reinterpret_cast<AnyCallback>(AnyCallbackCast(CachedInterpreterIR::IRBlockAnchor)))
    return;
  const auto* anchor =
      reinterpret_cast<const IRBlockAnchorOperands*>(source.exitPtrs + sizeof(AnyCallback));
  std::vector<IRInst>* ir = anchor->ir;
  if (ir == nullptr)
    return;

  // The destination vector (if linking). Looked up by the target's normalEntry; null if not present (it
  // should be, since the upstream linker only calls us with a resolved dest, but stay fail-safe).
  std::vector<IRInst>* target_ir = nullptr;
  if (dest != nullptr)
  {
    const auto it = m_block_ir.find(dest->normalEntry);
    if (it == m_block_ir.end())
      return;  // target has no IR vector (being torn down) — leave the link unset (== deopt)
    target_ir = it->second.get();
  }

  // Find the terminal EndBlockLink op for this exit and patch it. A block has exactly one linkable
  // terminal (one LinkData pushed), matched by expected_pc == source.exitAddress for robustness.
  for (IRInst& inst : *ir)
  {
    if (inst.op == IROp::EndBlockLink && inst.u.end_block_link.expected_pc == source.exitAddress)
    {
      inst.u.end_block_link.link_target_ir = target_ir;
      return;
    }
  }
}

// ============================================================================
// iCube M2: IR optimizer-pass framework + first pass (dead CR-flag elimination).
// ============================================================================

// The pass stage: a flat chain of `if (flag) Pass(ir);`. Registering a future pass (const-fold,
// generalized fusion, dead-FPRF) is one line here plus its own config flag. Passes walk/rewrite the linear
// IRInst vector in place. With every M2 flag off this loop does nothing and the vector is byte-identical to
// the M1 lowering — so behavior with all M2 flags off is unchanged.
void CachedInterpreterIR::RunIROptimizationPasses(std::vector<IRInst>& ir,
                                                  std::vector<CachedInterpreterIRFusedOp>& fused_pool) const
{
  if (s_ir_dead_flag_elim)
    PassDeadFlagElim(ir);
  // iCube IR M4: constant-address fusion (lis+addi/addis/ori -> SetRegConst). Default OFF.
  if (s_ir_const_fusion)
    PassConstAddrFusion(ir);
  // iCube IR M5: micro-op fusion (coalesce runs of plain Interpret<false> integer ALU ops -> FusedAluRun).
  // Registered LAST on purpose: addi/addis (OPCD 14/15) are in the fusible allowlist, so running this before
  // const-fusion would swallow lis+addi pairs into runs and starve M4 (2 ops -> 1 store is strictly better
  // than 2 ops -> 1 fused dispatch for that pair). DeadFlagElim's Rc-cleared ops stay IROp::Interpret and so
  // remain fusible; its validate-mode rewrites (InterpretDeadFlagValidate) are non-Interpret and simply break
  // a run, which is correct. Default OFF.
  if (s_ir_microop_fusion)
    PassMicroOpFusion(ir, fused_pool);
  // Future passes register here, one line each:
  //   if (s_ir_const_fold) PassConstFold(ir);
}

// iCube M2 dead-flag-elim predicate. Byte-identical logic to the shipping CIR's DeadFlagElimApplies, but
// reading the per-inst metadata the lowering copied from PPCAnalyst (crOut/crDiscardable/opinfo flags/Rc)
// instead of a live CodeOp. True IFF this op writes CR fields that are ALL discardable AND the Rc bit is the
// genuine mechanism that controls that CR write — so clearing Rc in the inst word skips the dead CR while
// leaving the GPR/XER result identical. The FL_RC_BIT/FL_RC_BIT_F guard is LOAD-BEARING: only those ops have
// their CR gated on inst bit 0 (the real Rc bit); the always-record ops (andi./andis. -> FL_SET_CR0,
// compares -> FL_SET_CRn) compute CR regardless of bit 0 AND would have an immediate's LSB corrupted if we
// cleared "Rc", so deadCR alone would wrongly fire — the flag check excludes them.
bool CachedInterpreterIR::DeadFlagElimApplies(const IRInst& inst)
{
  // Only plain Interpret ops carry meaningful metadata and are candidates. crDiscardable is reset at every
  // block-exit/exception boundary in PPCAnalyst (canEndBlock/canCauseException ~line 1175, HLE/breakpoint
  // ~1165, gather-pipe ~1127), so InterpretChk (canCauseException) and any write_pc=true (canEndBlock) op
  // has crDiscardable == 0 and could never qualify anyway — but we gate on the op kind explicitly too.
  if (inst.op != IROp::Interpret)
    return false;
  const BitSet8 cr_out{inst.cr_out};
  const BitSet8 cr_discardable{inst.cr_discardable};
  if (cr_out.Count() == 0)
    return false;  // op writes no CR field; nothing to eliminate
  if ((cr_out & ~cr_discardable) != BitSet8{})
    return false;  // some written CR field is LIVE downstream — must keep computing it
  if (inst.u.interpret.inst.Rc == 0)
    return false;  // record bit already clear: CR not being written via Rc anyway
  // Only ops whose CR write is gated on the Rc bit (and whose bit 0 IS the Rc bit) are safe to rewrite.
  return (inst.opinfo_flags & (FL_RC_BIT | FL_RC_BIT_F)) != 0;
}

// First IR optimizer pass: dead CR-flag elimination. Mirrors the CIR's MAIN_CIR_DEAD_FLAG_ELIM transform on
// the linear IR. For each qualifying plain Interpret op: when NOT validating, clear the Rc bit in the
// lowered inst word so the same handler skips the dead CR (op.inst / m_code_buffer are never touched — only
// the lowered copy in the IRInst). When validating (MAIN_CIR_IR_DEAD_FLAG_ELIM_VALIDATE), rewrite the op
// into an InterpretDeadFlagValidate op that double-runs ref-vs-eliminated and asserts the live CR fields
// match. Because crDiscardable is reset at every block/exception boundary, an eliminated field is never
// observed — this is exactly why the transform is safe; the validate harness proves it per-op.
void CachedInterpreterIR::PassDeadFlagElim(std::vector<IRInst>& ir) const
{
  for (IRInst& inst : ir)
  {
    if (!DeadFlagElimApplies(inst))
      continue;

    if (s_ir_dead_flag_elim_validate)
    {
      // Rewrite into the validate op: shipping (Rc-cleared) inst in the base, original (Rc-set) inst as the
      // CR reference, crOut as the mask of fields allowed to differ. The operand structs hold reference
      // members (deleted copy-assignment), so we change the active union member by constructing in place
      // (designated-init of dead_flag_validate), exactly as DoJit's Emit* helpers build the union.
      const InterpretOperands ref_operands = inst.u.interpret;  // original (Rc-set) operands
      InterpretOperands elim_operands = ref_operands;
      elim_operands.inst.Rc = 0;
      inst.op = IROp::InterpretDeadFlagValidate;
      // Construct the new active union member in place over the old InterpretOperands storage. The structs
      // are trivially destructible (PODs + bound references), so no explicit destroy of the old member is
      // needed before re-constructing.
      ::new (&inst.u.dead_flag_validate)
          InterpretDeadFlagValidateOperands{elim_operands, ref_operands.inst, inst.cr_out};
    }
    else
    {
      // Shipping path: clear Rc in the lowered inst word so the same handler skips the dead CR. Assigning
      // the scalar Rc bitfield does not reassign the struct's reference members, so this is well-formed.
      inst.u.interpret.inst.Rc = 0;
    }
  }
}

// ============================================================================
// iCube IR M4: constant-address fusion pass + handlers.
//
// This is the FIRST optimization that the shipping data-interpreted CachedInterpreter cannot easily do: it
// folds two adjacent interpreter dispatches into one, which needs the explicit IRInst layer to rewrite a
// pair in place. The shipping CIR emits a fixed callback per CodeOp at decode time with no second-pass
// rewrite stage, so it can't collapse the pair without restructuring its emitter.
// ============================================================================

// PowerPC primary opcodes for the fused forms (D-form integer/logical immediate ops). None of these have a
// record/Rc form, set no CR/CA, touch no memory, and raise no exception — so matching the exact OPCD is the
// flag/exception exclusion. (subi is a simplified mnemonic for `addi rX,rX,-imm`, i.e. OPCD 14 with a
// negative SIMM_16 — no separate opcode to handle.)
static constexpr u32 PPC_OPCD_ADDI = 14;   // addi / li / subi
static constexpr u32 PPC_OPCD_ADDIS = 15;  // addis / lis
static constexpr u32 PPC_OPCD_ORI = 24;    // ori

// iCube IR M4: const-fusion recognizer. See header. Mirrors the interpreter's own arithmetic EXACTLY so the
// folded constant equals running both ops (see Interpreter::addi/addis/ori).
bool CachedInterpreterIR::ConstAddrFusionApplies(const IRInst& first, const IRInst& second,
                                                 u32& out_reg, u32& out_value)
{
  // Both must be plain Interpret<false> (write_pc=false). lis/addi/ori never canEndBlock and aren't
  // FP/loadstore, so they are always lowered as IROp::Interpret (never InterpretPC/InterpretChk). Matching
  // only Interpret also means the folded op never needs a pc/npc write.
  if (first.op != IROp::Interpret || second.op != IROp::Interpret)
    return false;

  const UGeckoInstruction i1 = first.u.interpret.inst;
  const UGeckoInstruction i2 = second.u.interpret.inst;

  // FIRST op must be `lis rX,hi` == `addis rX, r0, hi`: OPCD 15, RA == 0 (so the result is the pure constant
  // hi<<16, not gpr[RA]+hi<<16). The destination rX is i1.RD.
  if (i1.OPCD != PPC_OPCD_ADDIS || i1.RA != 0)
    return false;
  const u32 rX = i1.RD;
  if (rX == 0)
    return false;  // rX != 0 is load-bearing (see the addi RA==0 path below); also nothing builds into r0

  const u32 hi = u32(i1.SIMM_16 << 16);  // mirror Interpreter::addis RA==0 branch exactly

  // SECOND op must read+write exactly rX and be one of the recognized forms. The interpreter's source field
  // differs by opcode: addi/addis use RA as the source GPR and RD as the destination; ori uses RS as the
  // source and RA as the destination. Require dest == source == rX.
  u32 value;
  switch (i2.OPCD)
  {
  case PPC_OPCD_ADDI:
    // addi rX,rX,lo. Require RD == RA == rX. RA != 0 is guaranteed by rX != 0 above, so the interpreter
    // takes the `gpr[RA] + SIMM_16` path (NOT the RA==0 `gpr[RD]=SIMM` constant path).
    if (i2.RD != rX || i2.RA != rX)
      return false;
    value = hi + u32(i2.SIMM_16);  // mirror Interpreter::addi RA!=0 branch (signed SIMM)
    break;
  case PPC_OPCD_ADDIS:
    // addis rX,rX,lo. Require RD == RA == rX.
    if (i2.RD != rX || i2.RA != rX)
      return false;
    value = hi + u32(i2.SIMM_16 << 16);  // mirror Interpreter::addis RA!=0 branch
    break;
  case PPC_OPCD_ORI:
    // ori rX,rX,lo. Logical D-form: dest is RA, source is RS. Require RA == RS == rX.
    if (i2.RA != rX || i2.RS != rX)
      return false;
    value = hi | i2.UIMM;  // mirror Interpreter::ori exactly
    break;
  default:
    return false;
  }

  out_reg = rX;
  out_value = value;
  return true;
}

// iCube IR M4: constant-address fusion pass. IRInst is NOT move-assignable (the operand union holds
// reference members, so copy/move assignment is deleted — this is why M2's PassDeadFlagElim mutates in place
// rather than erasing/inserting). Collapsing two elements into one therefore cannot use vector erase/insert;
// instead we build a FRESH vector by construction (push_back is fine) and swap it in. Walk by index: a
// matched [i, i+1] pair becomes one SetRegConst (or SetRegConstValidate) and skips both; anything else is
// copied through untouched. Terminals (EndBlock/EndBlockLink and its expected_pc), control ops, and checks
// are never the FIRST op of a recognized pair (the recognizer requires IROp::Interpret addis), so they are
// copied verbatim — the M3 linking invariants are preserved by construction, and PatchBlockLink still finds
// the terminal by its expected_pc scan after fusion.
void CachedInterpreterIR::PassConstAddrFusion(std::vector<IRInst>& ir) const
{
  if (ir.size() < 2)
    return;

  std::vector<IRInst> out;
  out.reserve(ir.size());

  std::size_t i = 0;
  const std::size_t n = ir.size();
  while (i < n)
  {
    u32 reg = 0;
    u32 value = 0;
    if (i + 1 < n && ConstAddrFusionApplies(ir[i], ir[i + 1], reg, value))
    {
      if (s_ir_const_fusion_validate)
      {
        // Validate form: carry the folded result PLUS the original two (func,inst) pairs so the handler can
        // recompute the reference rX. The interpreter ref is shared by both source ops (same engine).
        out.push_back(IRInst{IROp::SetRegConstValidate,
                             {.set_reg_const_validate = {ir[i].u.interpret.interpreter, reg, value,
                                                         ir[i].u.interpret.func, ir[i].u.interpret.inst,
                                                         ir[i + 1].u.interpret.func,
                                                         ir[i + 1].u.interpret.inst}}});
      }
      else
      {
        out.push_back(IRInst{IROp::SetRegConst, {.set_reg_const = {reg, value}}});
      }
      i += 2;  // consumed the pair
    }
    else
    {
      out.push_back(ir[i]);  // copy through untouched (construction-copy is fine; assignment is not)
      i += 1;
    }
  }

  ir.swap(out);
}

// iCube IR M4: fused constant-set handler. The whole point of the pass: one dispatch, one store, instead of
// two interpreter dispatches. No flags, no CR/CA, no memory, no pc write.
s32 CachedInterpreterIR::SetRegConst(PowerPC::PowerPCState& ppc_state,
                                     const SetRegConstOperands& operands)
{
  ppc_state.gpr[operands.reg] = operands.value;
  return sizeof(AnyCallback) + sizeof(operands);
}

// iCube IR M4: const-fusion validate handler. Mirrors the M2 validate discipline: run the REFERENCE (the
// original two ops, via the interpreter) on a snapshot of rX, capture the result, RESTORE rX, then commit the
// SHIPPING form (gpr[rX] = precomputed value, run LAST), and ASSERT the two rX results match. The folded ops
// write ONLY gpr[rX] (addi/addis/ori with RA==dest==source: no CR/CA, no memory, no pc), so the diff is
// scoped to that one register and no other state needs snapshot/restore. (Worth noting: re-running func1, an
// `lis rX,hi` with RA==0, overwrites rX from the immediate alone — it doesn't read the prior rX — so the
// reference run is self-contained regardless of rX's incoming value.)
s32 CachedInterpreterIR::SetRegConstValidate(PowerPC::PowerPCState& ppc_state,
                                             const SetRegConstValidateOperands& operands)
{
  const u32 saved = ppc_state.gpr[operands.reg];

  // REFERENCE RUN: the original two ops, in order, exactly as the unfused block would have executed them.
  operands.func1(operands.interpreter, operands.inst1);
  operands.func2(operands.interpreter, operands.inst2);
  const u32 ref = ppc_state.gpr[operands.reg];

  // Restore rX, then commit the SHIPPING form last so its result stays committed.
  ppc_state.gpr[operands.reg] = saved;
  ppc_state.gpr[operands.reg] = operands.value;

  ASSERT_MSG(DYNA_REC, ref == operands.value,
             "CIR IR const-fusion divergence: rX={} fused={:#010x} vs ref={:#010x} "
             "(inst1={:#010x}, inst2={:#010x})",
             operands.reg, operands.value, ref, operands.inst1.hex, operands.inst2.hex);

  return sizeof(AnyCallback) + sizeof(operands);
}

// ============================================================================
// iCube IR M5: micro-op fusion pass + handlers.
//
// Ports the shipping CachedInterpreter's proven micro-op fusion (MAIN_CIR_MICROOP_FUSION) to the IR engine as
// an optimizer pass. The CIR re-implements each fused ALU op as a hand-rolled MicroOp (CONST32/ADDI/...) run
// by ExecuteMicroOps; the IR engine does NOT need to — its plain Interpret<false> handler is exactly
// `func(interpreter, inst)` with no pc/npc/exception touch (see Interpret<false> above), so a fused run is
// simply a loop that calls each op's interpreter func in order. We therefore mirror only the CIR's FUSIBLE
// PREDICATE (is_simple_mop) and its run-build break conditions; the arithmetic is the interpreter's own.
// ============================================================================

// iCube IR M5: COPIED VERBATIM from CachedInterpreter::DoJit's is_simple_mop lambda — the exact opcode
// allowlist the shipping CIR's micro-op fusion deems fusible. Every opcode here has no record/Rc-controlled
// CR write that the IR path can't already handle, no exception, no PC write, and no load/store, so a run of
// them can be dispatched in one inner loop with no per-op pc/exception bookkeeping. cmp/cmpl/cmpi/cmpli write
// CR unconditionally — that is fine: the fused loop runs the REAL interpreter handler, which computes that CR
// exactly as the unfused path would. Conservative: anything not on this list is not fusible.
bool CachedInterpreterIR::IsFusibleAluOp(UGeckoInstruction inst)
{
  switch (inst.OPCD)
  {
  case 10:  // cmpli
  case 11:  // cmpi
  case 14:  // addi
  case 15:  // addis
  case 20:  // rlwimix
  case 21:  // rlwinm / rlwinm.
  case 23:  // rlwnmx
  case 24:  // ori
  case 25:  // oris
  case 26:  // xori
  case 27:  // xoris
  case 28:  // andi.
  case 29:  // andis.
    return true;
  case 31:  // X-form logical reg-reg and/or/xor + arithmetic
    switch (inst.SUBOP10)
    {
    case 0:    // cmp
    case 32:   // cmpl
    case 28:   // andx
    case 444:  // orx
    case 316:  // xorx
    case 60:   // andcx
    case 412:  // orcx
    case 476:  // nandx
    case 124:  // norx
    case 284:  // eqvx
    case 266:  // addx
    case 778:  // addox
    case 10:   // addcx
    case 522:  // addcox
    case 138:  // addex
    case 650:  // addeox
    case 234:  // addmex
    case 746:  // addmeox
    case 202:  // addzex
    case 714:  // addzeox
    case 40:   // subfx
    case 552:  // subfox
    case 8:    // subfcx
    case 520:  // subfcox
    case 136:  // subfex
    case 648:  // subfeox
    case 232:  // subfmex
    case 744:  // subfmeox
    case 200:  // subfzex
    case 712:  // subfzeox
    case 26:   // cntlzwx
    case 954:  // extsbx
    case 922:  // extshx
    case 24:   // slwx
    case 536:  // srwx
    case 792:  // srawx
    case 824:  // srawix
      return true;
    default:
      return false;
    }
  default:
    return false;
  }
}

// iCube IR M5: micro-op fusion pass. IRInst is NOT move-assignable (operand union holds reference members),
// so — exactly like M4's PassConstAddrFusion — we build a FRESH vector by construction and swap it in rather
// than erasing in place. Walk by index; a maximal run of >= 2 consecutive run-members collapses to one
// FusedAluRun (the run's (func,inst) pairs appended to `pool`, the op carrying pool+offset+count). A lone
// run-member (run length 1) is copied through unchanged — fusing one op would only add overhead. Everything
// non-fusible is copied verbatim, so terminals (EndBlock/EndBlockLink + expected_pc), control ops, and checks
// pass through and the M3 linking invariants hold by construction (PatchBlockLink still finds the terminal by
// its expected_pc scan after fusion). When validating, the run is emitted as FusedAluRunValidate instead.
//
// DEFERRED-FREE / LIFETIME: the pool pointer stored in each op refers to `pool`, which DoJit owns and (when
// non-empty) inserts into m_block_fused keyed by the block's normalEntry — the SAME key and SAME deferred-
// free path as m_block_ir. Appending to `pool` here may reallocate its element buffer, but the op stores the
// POOL OBJECT pointer (whose address is stable once DoJit moves the unique_ptr into m_block_fused) plus an
// OFFSET — never an element pointer — so the run span is resolved at execution time against the final buffer.
void CachedInterpreterIR::PassMicroOpFusion(std::vector<IRInst>& ir,
                                            std::vector<CachedInterpreterIRFusedOp>& pool) const
{
  if (ir.size() < 2)
    return;

  // A lowered inst is a RUN MEMBER iff it is a plain IROp::Interpret (which already encodes write_pc=false,
  // non-terminal, non-exception, non-memcheck-loadstore, non-skip — the CIR's canEndBlock / skip /
  // InterpretChk exclusions, structurally), its instruction passes IsFusibleAluOp, AND it carries no
  // FL_LOADSTORE/FL_USE_FPU (an EXACT mirror of the CIR run-build guard `(flags & (FL_LOADSTORE|FL_USE_FPU))`;
  // the allowlist is all-integer so this is belt-and-suspenders, kept for a verbatim mirror). Any op failing
  // this breaks the run, so terminals/checks/HLE/idle/InterpretPC/InterpretChk and non-allowlisted Interpret
  // ops are never inside a run.
  const auto is_run_member = [](const IRInst& inst) -> bool {
    if (inst.op != IROp::Interpret)
      return false;
    if ((inst.opinfo_flags & (FL_LOADSTORE | FL_USE_FPU)) != 0)
      return false;
    return IsFusibleAluOp(inst.u.interpret.inst);
  };

  std::vector<IRInst> out;
  out.reserve(ir.size());

  // The pool's heap buffer is referenced by the emitted ops via &pool (the OBJECT, stable once moved into
  // m_block_fused) + offset, so reallocation during these appends is harmless. We never store &pool[k].
  const std::vector<CachedInterpreterIRFusedOp>* const pool_ptr = &pool;

  std::size_t i = 0;
  const std::size_t n = ir.size();
  while (i < n)
  {
    if (is_run_member(ir[i]))
    {
      // Extend the run maximally.
      std::size_t j = i;
      while (j < n && is_run_member(ir[j]))
        ++j;
      const std::size_t run_len = j - i;
      if (run_len >= 2)
      {
        const u32 offset = static_cast<u32>(pool.size());
        Interpreter& interpreter = ir[i].u.interpret.interpreter;
        for (std::size_t k = i; k < j; ++k)
          pool.push_back({ir[k].u.interpret.func, ir[k].u.interpret.inst});
        const u32 count = static_cast<u32>(run_len);
        if (s_ir_microop_fusion_validate)
        {
          out.push_back(IRInst{IROp::FusedAluRunValidate,
                               {.fused_alu_run_validate = {{interpreter, pool_ptr, offset, count}}}});
        }
        else
        {
          out.push_back(
              IRInst{IROp::FusedAluRun, {.fused_alu_run = {interpreter, pool_ptr, offset, count}}});
        }
        i = j;
        continue;
      }
      // run_len == 1: not worth fusing; fall through to copy the single op verbatim.
    }
    out.push_back(ir[i]);  // copy through untouched (construction-copy is fine; assignment is not)
    i += 1;
  }

  ir.swap(out);
}

// iCube IR M5: fused-ALU-run handler. The perf win: one IRInst dispatch instead of N. Each op is a plain
// Interpret<false> (func only — no pc/npc, no exception check), so this loop is byte-identical to running
// those N IROp::Interpret ops back to back in ExecuteOneBlock.
s32 CachedInterpreterIR::FusedAluRun(PowerPC::PowerPCState& ppc_state,
                                     const FusedAluRunOperands& operands)
{
  const CachedInterpreterIRFusedOp* const ops = operands.pool->data() + operands.offset;
  for (u32 k = 0; k < operands.count; ++k)
    ops[k].func(operands.interpreter, ops[k].inst);
  return sizeof(AnyCallback) + sizeof(operands);
}

// iCube IR M5: fused-run validate handler. Snapshot -> un-fused per-op REFERENCE run -> capture -> restore ->
// fused run (the SHIPPING path, committed last) -> capture -> assert bit-identical.
//
// SCOPE OF WHAT THIS PROVES — be precise: unlike M2 (Rc-set vs Rc-cleared) and M4 (interpreter-run vs
// precomputed constant), the fused path has NO second implementation; it just calls the interpreter funcs the
// pass stored. So the reference must NOT reuse the stored ops[k].func — that would be a tautology (a mispaired
// func/inst corrupts both sides equally and the assert could never fire). Instead the reference RE-DERIVES the
// canonical handler from the instruction word via GetInterpreterOp(ops[k].inst), exactly as DoJit's lowering
// does; the fused run uses the STORED func. The two diverge iff the pass mispaired a func with the wrong inst
// (a real pass-construction bug class). What this STILL cannot catch is a wrong run SELECTION/BOUNDARY (both
// sides iterate the same pool span) — that is covered STRUCTURALLY instead: a run member is only ever a plain
// IROp::Interpret whose inst passes IsFusibleAluOp, so the fused loop is byte-identical to running those same
// N IROp::Interpret ops back to back. All run ops are pure-register integer ALU (IsFusibleAluOp +
// !FL_LOADSTORE/!FL_USE_FPU), so double-running is side-effect-safe and the diff is scoped to GPR/CR/XER.
// Mirrors the M2/M4 snapshot/restore/commit-last discipline.
s32 CachedInterpreterIR::FusedAluRunValidate(PowerPC::PowerPCState& ppc_state,
                                             const FusedAluRunValidateOperands& operands)
{
  const CachedInterpreterIRFusedOp* const ops = operands.pool->data() + operands.offset;

  // Snapshot the full validated state set (mirrors the M2/M4 + CIR ExecuteMicroOpsValidate snapshot set).
  std::array<u32, 32> saved_gpr;
  std::array<u64, 8> saved_cr;
  std::copy(std::begin(ppc_state.gpr), std::end(ppc_state.gpr), saved_gpr.begin());
  std::copy(std::begin(ppc_state.cr.fields), std::end(ppc_state.cr.fields), saved_cr.begin());
  const u8 saved_xer_ca = ppc_state.xer_ca;
  const u8 saved_xer_so_ov = ppc_state.xer_so_ov;
  const u32 saved_pc = ppc_state.pc;
  const u32 saved_npc = ppc_state.npc;
  const u32 saved_exceptions = ppc_state.Exceptions;

  // REFERENCE RUN: the run ops un-fused, one interpreter call each, in program order. The handler is
  // RE-DERIVED from the inst word (NOT the stored func) so a func/inst mispairing by the pass shows up as a
  // divergence vs the fused run (which uses the stored func). See the header comment for why reusing the
  // stored func would make this a tautology.
  for (u32 k = 0; k < operands.count; ++k)
    Interpreter::GetInterpreterOp(ops[k].inst)(operands.interpreter, ops[k].inst);

  std::array<u32, 32> ref_gpr;
  std::array<u64, 8> ref_cr;
  std::copy(std::begin(ppc_state.gpr), std::end(ppc_state.gpr), ref_gpr.begin());
  std::copy(std::begin(ppc_state.cr.fields), std::end(ppc_state.cr.fields), ref_cr.begin());
  const u8 ref_xer_ca = ppc_state.xer_ca;
  const u8 ref_xer_so_ov = ppc_state.xer_so_ov;
  const u32 ref_pc = ppc_state.pc;
  const u32 ref_npc = ppc_state.npc;
  const u32 ref_exceptions = ppc_state.Exceptions;

  // Restore the pre-run state so the fused run starts from byte-identical inputs.
  std::copy(saved_gpr.begin(), saved_gpr.end(), std::begin(ppc_state.gpr));
  std::copy(saved_cr.begin(), saved_cr.end(), std::begin(ppc_state.cr.fields));
  ppc_state.xer_ca = saved_xer_ca;
  ppc_state.xer_so_ov = saved_xer_so_ov;
  ppc_state.pc = saved_pc;
  ppc_state.npc = saved_npc;
  ppc_state.Exceptions = saved_exceptions;

  // FUSED RUN — the SHIPPING path, run LAST so its result stays committed (mirrors the M2/M4 validate order).
  FusedAluRun(ppc_state, operands);

  std::array<u32, 32> fused_gpr;
  std::array<u64, 8> fused_cr;
  std::copy(std::begin(ppc_state.gpr), std::end(ppc_state.gpr), fused_gpr.begin());
  std::copy(std::begin(ppc_state.cr.fields), std::end(ppc_state.cr.fields), fused_cr.begin());

  ASSERT_MSG(DYNA_REC, fused_gpr == ref_gpr,
             "CIR IR micro-op fusion GPR mismatch (count={}, offset={})", operands.count,
             operands.offset);
  ASSERT_MSG(DYNA_REC, fused_cr == ref_cr,
             "CIR IR micro-op fusion CR mismatch (count={}, offset={})", operands.count,
             operands.offset);
  ASSERT_MSG(DYNA_REC,
             ppc_state.xer_ca == ref_xer_ca && ppc_state.xer_so_ov == ref_xer_so_ov,
             "CIR IR micro-op fusion XER mismatch (count={})", operands.count);
  ASSERT_MSG(DYNA_REC, ppc_state.pc == ref_pc && ppc_state.npc == ref_npc,
             "CIR IR micro-op fusion PC/NPC mismatch (count={})", operands.count);
  ASSERT_MSG(DYNA_REC, ppc_state.Exceptions == ref_exceptions,
             "CIR IR micro-op fusion Exceptions mismatch (count={})", operands.count);

  return sizeof(AnyCallback) + sizeof(operands);
}

// iCube M2: dead CR-flag elimination validate handler. Direct analogue of the CIR's InterpretDeadFlagValidate,
// adapted to the IR dispatch model (returns nonzero => ExecuteOneBlock continues). The transform only ever
// clears Rc on an op whose ENTIRE crOut PPCAnalyst proved discardable; this double-runs the op (reference
// Rc-set CR vs eliminated Rc-cleared) and asserts every CR field OUTSIDE that crOut mask — every LIVE field
// read by the block continuation — is byte-identical. Run order mirrors the CIR: snapshot -> reference on
// live -> capture -> restore -> eliminated (the SHIPPING path, committed last) -> capture -> assert.
// GPR/XER/pc/npc/Exceptions are identical by construction (Rc 0/1 select the same handler and GPR/XER math),
// so the diff is scoped to CR. These ops are always mid-block (write_pc=false) by the discardable-reset
// invariant, so there is no pc write here.
s32 CachedInterpreterIR::InterpretDeadFlagValidate(PowerPC::PowerPCState& ppc_state,
                                                   const InterpretDeadFlagValidateOperands& operands)
{
  // Snapshot every register file the op can write, so the eliminated run starts from byte-identical inputs
  // to the reference run. The FP register file (ps) is LOAD-BEARING: the predicate admits FP record-form ops
  // (FL_RC_BIT_F), and with FP exceptions masked (the default) they reach this plain-Interpret path, so an
  // in-place FP op like `fmul. f1,f1,f0` would have its source clobbered by the reference run and the
  // committed eliminated run would compute a WRONG result if ps were not restored. (The CIR reference twin
  // this mirrors omits ps; that is unsound for FP ops — fixed here. FPSCR is intentionally not snapshotted:
  // its sticky bits OR idempotently and FPRF is overwritten to the correct value by the committed run.)
  std::array<u64, 8> saved_cr;
  std::copy(std::begin(ppc_state.cr.fields), std::end(ppc_state.cr.fields), saved_cr.begin());
  std::array<u32, 32> saved_gpr;
  std::copy(std::begin(ppc_state.gpr), std::end(ppc_state.gpr), saved_gpr.begin());
  std::array<PowerPC::PairedSingle, 32> saved_ps;
  std::copy(std::begin(ppc_state.ps), std::end(ppc_state.ps), saved_ps.begin());
  const u8 saved_xer_ca = ppc_state.xer_ca;
  const u8 saved_xer_so_ov = ppc_state.xer_so_ov;
  const u32 saved_pc = ppc_state.pc;
  const u32 saved_npc = ppc_state.npc;
  const u32 saved_exceptions = ppc_state.Exceptions;

  // REFERENCE RUN: the ORIGINAL (Rc-set) instruction, so the genuine CR result is computed.
  operands.func(operands.interpreter, operands.ref_inst);
  std::array<u64, 8> ref_cr;
  std::copy(std::begin(ppc_state.cr.fields), std::end(ppc_state.cr.fields), ref_cr.begin());

  // Restore to the pre-run state so the eliminated run sees identical inputs.
  std::copy(saved_cr.begin(), saved_cr.end(), std::begin(ppc_state.cr.fields));
  std::copy(saved_gpr.begin(), saved_gpr.end(), std::begin(ppc_state.gpr));
  std::copy(saved_ps.begin(), saved_ps.end(), std::begin(ppc_state.ps));
  ppc_state.xer_ca = saved_xer_ca;
  ppc_state.xer_so_ov = saved_xer_so_ov;
  ppc_state.pc = saved_pc;
  ppc_state.npc = saved_npc;
  ppc_state.Exceptions = saved_exceptions;

  // ELIMINATED RUN — the SHIPPING path, run LAST so its result stays committed. operands.inst already has
  // the Rc bit cleared, so the dead CR field(s) are NOT computed.
  operands.func(operands.interpreter, operands.inst);

  // Assert every CR field OUTSIDE the eliminated mask (the live/continuation-read fields) matches the
  // reference. The masked fields are exactly op.crOut, all proven discardable, so a divergence there is
  // expected and ignored; a divergence ANYWHERE else means a live flag was wrongly eliminated.
  const u8 elim_mask = static_cast<u8>(operands.elim_cr_mask);
  for (u32 k = 0; k < 8; ++k)
  {
    if ((elim_mask >> k) & 1u)
      continue;  // this field was eliminated on purpose (proven dead) — allowed to differ
    ASSERT_MSG(DYNA_REC, ppc_state.cr.fields[k] == ref_cr[k],
               "CIR IR dead-flag-elim LIVE CR{} divergence at pc {:#010x} (elim={:#x} vs ref={:#x}, "
               "elim_mask={:#04x})",
               k, operands.current_pc, ppc_state.cr.fields[k], ref_cr[k], elim_mask);
  }

  return sizeof(AnyCallback) + sizeof(operands);
}

void CachedInterpreterIR::ExecuteOneBlock(const CPU::State* state_ptr)
{
  // Release IR vectors retired during a PREVIOUS dispatch. The free is deferred to this point (see
  // ReleaseBlockIR / m_ir_pending_free) because a block can be destroyed while ExecuteOneBlock is
  // iterating its vector; we are not inside any prior dispatch now, so this is the safe boundary.
  //
  // iCube IR M3 — DEFERRED-FREE SAFETY UNDER LINKING: this release stays at the OUTER entry, BEFORE the
  // chain loop below, NEVER mid-chain. A block destroyed mid-chain (interpreted dcbf/icbi/dcbst ->
  // DestroyBlock -> ReleaseBlockIR) moves its vector to m_ir_pending_free and keeps the heap address, so
  // the in-flight `for (inst : *ir)` and any link_target_ir we already followed stay valid for the whole
  // chain. Because we only clear pending_free here (no ExecuteOneBlock on the stack), no chain can be
  // iterating a vector we free. The UnlinkBlock that runs during such a mid-chain DestroyBlock also clears
  // every inbound link_target_ir to nullptr, so the NEXT terminal we reach deopts to Dispatch() rather than
  // following a link into a vector that is about to be freed at the next outer entry.
  if (!m_ir_pending_free.empty()) [[unlikely]]
    m_ir_pending_free.clear();
  // iCube IR M5: free the fused-run pools retired alongside their IR vectors. Same deferred-free reasoning:
  // a block destroyed mid-chain moves its pool to m_fused_pending_free (heap address stable across the move,
  // so an in-flight FusedAluRun's pool pointer stays valid for the chain), freed here at the dispatch
  // boundary with no ExecuteOneBlock on the stack iterating it. Empty unless the M5 pass ran on some block.
  if (!m_fused_pending_free.empty()) [[unlikely]]
    m_fused_pending_free.clear();

  const u8* normal_entry = m_block_cache.Dispatch();
  if (!normal_entry)
  {
    Jit(m_ppc_state.pc);
    return;
  }

  // A destroyed block's slot is poisoned by WriteDestroyBlock (the callback at normalEntry is no
  // longer an IRBlockAnchor). If the block cache ever hands us such a slot, rebuild rather than
  // dereferencing a stale anchor. (With the deferred free above, the anchor's vector itself can no
  // longer dangle mid-dispatch.)
  const auto callback = *reinterpret_cast<const AnyCallback*>(normal_entry);
  if (callback != reinterpret_cast<AnyCallback>(AnyCallbackCast(CachedInterpreterIR::IRBlockAnchor)))
      [[unlikely]]
  {
    Jit(m_ppc_state.pc);
    return;
  }
  const auto* anchor_ptr =
      reinterpret_cast<const IRBlockAnchorOperands*>(normal_entry + sizeof(AnyCallback));
  if (anchor_ptr->ir == nullptr) [[unlikely]]
  {
    Jit(m_ppc_state.pc);
    return;
  }

  auto& ppc_state = m_ppc_state;

  // iCube IR M3: block-linking chain. `ir` is the vector currently being run; on a followed link we swap
  // it for the target's vector and keep iterating WITHOUT returning to Dispatch(). linked_hops bounds the
  // chain (reset per outer entry by being a fresh local). When linking is off, no EndBlockLink op is ever
  // lowered, so the inner switch never hits the EndBlockLink case and this is a single block run + return —
  // byte-identical to the pre-M3 path.
  const std::vector<IRInst>* ir = anchor_ptr->ir;
  u32 linked_hops = 0;

  while (true)
  {
    bool follow_link = false;
    for (const IRInst& inst : *ir)
    {
      // iCube IR M3: inlined [[likely]] fast path for the hottest ops (plain Interpret<false>/<true>),
      // mirroring the CIR ExecuteOneBlock's direct-dispatch of Interpret<false>/<true>. This cuts the
      // switch + call indirection on the common per-instruction path; everything else falls through to
      // the full switch in DispatchIRInst.
      if (inst.op == IROp::Interpret) [[likely]]
      {
        Interpret<false>(ppc_state, inst.u.interpret);
        continue;
      }
      if (inst.op == IROp::InterpretPC)
      {
        Interpret<true>(ppc_state, inst.u.interpret);
        continue;
      }
      // iCube IR M4: fused constant-set on the inlined fast path — this IS the perf win (one store, no
      // interpreter dispatch, no switch). Only present when MAIN_CIR_IR_CONST_FUSION is on; with the flag off
      // the pass never lowers it, so this branch is never taken and the path is byte-identical to M3.
      if (inst.op == IROp::SetRegConst)
      {
        ppc_state.gpr[inst.u.set_reg_const.reg] = inst.u.set_reg_const.value;
        continue;
      }
      // iCube IR M5: fused ALU run on the inlined fast path — THIS is the M5 dispatch-count win. One IRInst
      // dispatch + one tight inner loop over the run's interpreter funcs, instead of N IROp::Interpret
      // dispatches through this switch. Only present when MAIN_CIR_IR_MICROOP_FUSION is on; with the flag off
      // the pass never lowers it, so this branch is never taken and the path is byte-identical to M4.
      if (inst.op == IROp::FusedAluRun)
      {
        const auto& run = inst.u.fused_alu_run;
        const CachedInterpreterIRFusedOp* const ops = run.pool->data() + run.offset;
        for (u32 k = 0; k < run.count; ++k)
          ops[k].func(run.interpreter, ops[k].inst);
        continue;
      }
      // iCube IR M3: linkable terminal. EndBlockLink does the EndBlock accounting and returns whether the
      // chain may follow the link. We apply the remaining guards (Running + hop cap) here, in the loop
      // that owns them, exactly as the CIR's ExecuteOneBlock does for its LinkBlock callback.
      if (inst.op == IROp::EndBlockLink)
      {
        if (EndBlockLink(ppc_state, inst.u.end_block_link) == 0)
          return;  // accounting done; deopt to the dispatcher (slice end / mispredict / unlinked)
        // Per-hop Running re-check: a stop/pause/state-change would otherwise not be observed until the
        // slice ends (a linked chain has no downcount<=0 exit of its own). Single non-atomic load+compare.
        if (*state_ptr != CPU::State::Running) [[unlikely]]
          return;
        // Bounded hop cap: force a dispatcher round-trip after IR_MAX_LINKED_HOPS consecutive links.
        if (++linked_hops >= IR_MAX_LINKED_HOPS) [[unlikely]]
          return;
        ir = inst.u.end_block_link.link_target_ir;  // resolved non-null by EndBlockLink's guard
        follow_link = true;
        break;  // restart the inner loop on the target vector
      }
      // Everything else (other terminals, checks, HLE, idle, M2 validate) goes through the full switch.
      // A 0 return is a block exit (terminal / exception / halt) -> leave the chain.
      if (DispatchIRInst(ppc_state, inst) == 0)
        return;
    }
    if (!follow_link)
      break;  // fell off the end of a vector without a followed link (shouldn't happen — blocks end in a
              // terminal — but treat as a clean block exit)
  }
}

// DOLPHIN_IR_VALIDATE=1 self-check. The IR vector was lowered 1:1 in DoJit; in parallel, each Emit*
// also wrote the equivalent M0 callback record into m_validate_buffer. Here we walk that independent
// M0 tape and assert, record by record, that the lowered IRInst matches: same count, the IROp maps
// to exactly the callback M0 used (the op<->callback bijection from Disassemble's lookup), and the
// operands are field-wise equal. Any mismatch traps. Default off => zero overhead in normal runs.
void CachedInterpreterIR::ValidateBlockIR(const std::vector<IRInst>& ir) const
{
  const u8* p = m_validate_buffer.data();
  const u8* end = m_validate_emitter.GetCodePtr();

  std::size_t idx = 0;
  for (; p != end; ++idx)
  {
    ASSERT_MSG(DYNA_REC, idx < ir.size(),
               "IR self-check: M0 tape has more records ({}+) than IR vector ({}).", idx + 1,
               ir.size());
    if (idx >= ir.size())
      return;

    const auto callback = *reinterpret_cast<const AnyCallback*>(p);
    const void* m0 = p + sizeof(AnyCallback);
    const IRInst& inst = ir[idx];

    const auto check = [&](IROp expected_op, bool operands_equal, std::size_t operand_size) {
      ASSERT_MSG(DYNA_REC, inst.op == expected_op,
                 "IR self-check: record {} op mismatch (IR={}, M0={}).", idx,
                 static_cast<int>(inst.op), static_cast<int>(expected_op));
      ASSERT_MSG(DYNA_REC, operands_equal, "IR self-check: record {} operand mismatch (op={}).", idx,
                 static_cast<int>(expected_op));
      p += sizeof(AnyCallback) + operand_size;
    };

    // Field-wise operand comparisons (no raw memcmp: EndBlockOperands<false> has an explicit
    // padding bitfield whose bytes are indeterminate and would cause false mismatches).
#define CB(fn) reinterpret_cast<AnyCallback>(AnyCallbackCast(fn))
    if (callback == CB(StartProfiledBlock))
    {
      const auto& o = *reinterpret_cast<const StartProfiledBlockOperands*>(m0);
      const auto& a = inst.u.start_profiled_block;
      check(IROp::StartProfiledBlock, a.profile_data == o.profile_data, sizeof(o));
    }
    else if (callback == CB(EndBlock<false>))
    {
      const auto& o = *reinterpret_cast<const EndBlockOperands<false>*>(m0);
      const auto& a = inst.u.end_block;
      check(IROp::EndBlock,
            a.downcount == o.downcount && a.num_load_stores == o.num_load_stores &&
                a.num_fp_inst == o.num_fp_inst,
            sizeof(o));
    }
    else if (callback == CB(EndBlock<true>))
    {
      const auto& o = *reinterpret_cast<const EndBlockOperands<true>*>(m0);
      const auto& a = inst.u.end_block_profiled;
      check(IROp::EndBlockProfiled,
            a.downcount == o.downcount && a.num_load_stores == o.num_load_stores &&
                a.num_fp_inst == o.num_fp_inst && a.profile_data == o.profile_data,
            sizeof(o));
    }
    else if (callback == CB(Interpret<false>))
    {
      const auto& o = *reinterpret_cast<const InterpretOperands*>(m0);
      const auto& a = inst.u.interpret;
      check(IROp::Interpret,
            &a.interpreter == &o.interpreter && a.func == o.func && a.current_pc == o.current_pc &&
                a.inst.hex == o.inst.hex,
            sizeof(o));
    }
    else if (callback == CB(Interpret<true>))
    {
      const auto& o = *reinterpret_cast<const InterpretOperands*>(m0);
      const auto& a = inst.u.interpret;
      check(IROp::InterpretPC,
            &a.interpreter == &o.interpreter && a.func == o.func && a.current_pc == o.current_pc &&
                a.inst.hex == o.inst.hex,
            sizeof(o));
    }
    else if (callback == CB(InterpretAndCheckExceptions<false>))
    {
      const auto& o = *reinterpret_cast<const InterpretAndCheckExceptionsOperands*>(m0);
      const auto& a = inst.u.interpret_chk;
      check(IROp::InterpretChk,
            &a.interpreter == &o.interpreter && a.func == o.func && a.current_pc == o.current_pc &&
                a.inst.hex == o.inst.hex && &a.power_pc == &o.power_pc && a.downcount == o.downcount,
            sizeof(o));
    }
    else if (callback == CB(InterpretAndCheckExceptions<true>))
    {
      const auto& o = *reinterpret_cast<const InterpretAndCheckExceptionsOperands*>(m0);
      const auto& a = inst.u.interpret_chk;
      check(IROp::InterpretChkPC,
            &a.interpreter == &o.interpreter && a.func == o.func && a.current_pc == o.current_pc &&
                a.inst.hex == o.inst.hex && &a.power_pc == &o.power_pc && a.downcount == o.downcount,
            sizeof(o));
    }
    else if (callback == CB(HLEFunction))
    {
      const auto& o = *reinterpret_cast<const HLEFunctionOperands*>(m0);
      const auto& a = inst.u.hle;
      check(IROp::HLEFunction,
            &a.system == &o.system && a.current_pc == o.current_pc && a.hook_index == o.hook_index,
            sizeof(o));
    }
    else if (callback == CB(WriteBrokenBlockNPC))
    {
      const auto& o = *reinterpret_cast<const WriteBrokenBlockNPCOperands*>(m0);
      const auto& a = inst.u.broken_npc;
      check(IROp::WriteBrokenBlockNPC, a.current_pc == o.current_pc, sizeof(o));
    }
    else if (callback == CB(CheckFPU))
    {
      const auto& o = *reinterpret_cast<const CheckHaltOperands*>(m0);
      const auto& a = inst.u.check_halt;
      check(IROp::CheckFPU,
            &a.power_pc == &o.power_pc && a.current_pc == o.current_pc && a.downcount == o.downcount,
            sizeof(o));
    }
    else if (callback == CB(CheckBreakpoint))
    {
      const auto& o = *reinterpret_cast<const CheckHaltOperands*>(m0);
      const auto& a = inst.u.check_halt;
      check(IROp::CheckBreakpoint,
            &a.power_pc == &o.power_pc && a.current_pc == o.current_pc && a.downcount == o.downcount,
            sizeof(o));
    }
    else if (callback == CB(CheckIdle))
    {
      const auto& o = *reinterpret_cast<const CheckIdleOperands*>(m0);
      const auto& a = inst.u.check_idle;
      check(IROp::CheckIdle, &a.core_timing == &o.core_timing && a.idle_pc == o.idle_pc, sizeof(o));
    }
    else if (callback == CB(FastForwardCtrIdle))
    {
      const auto& o = *reinterpret_cast<const CheckCtrIdleOperands*>(m0);
      const auto& a = inst.u.ctr_idle;
      check(IROp::FastForwardCtrIdle,
            &a.core_timing == &o.core_timing && a.idle_pc == o.idle_pc &&
                a.fallthrough_pc == o.fallthrough_pc,
            sizeof(o));
    }
    else
    {
      ASSERT_MSG(DYNA_REC, false, "IR self-check: unknown M0 callback in record {}.", idx);
      return;
    }
#undef CB
  }

  ASSERT_MSG(DYNA_REC, idx == ir.size(),
             "IR self-check: count mismatch (M0={}, IR={}).", idx, ir.size());
}

void CachedInterpreterIR::Run()
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
      ExecuteOneBlock(state_ptr);
    } while (m_ppc_state.downcount > 0 && *state_ptr == CPU::State::Running);
  }
}

void CachedInterpreterIR::SingleStep()
{
  // Enter new timing slice
  m_system.GetCoreTiming().Advance();
  // iCube IR M3: thread the run-state pointer for the chain's per-hop Running guard (same source Run uses).
  // On a single step a linked chain cannot form across the one block, so the guard is inert here.
  ExecuteOneBlock(m_system.GetCPU().GetStatePtr());
}

bool CachedInterpreterIR::HandleFunctionHooking(u32 address)
{
  // CachedInterpreterIR inherits from JitBase and is considered a JIT by relevant code.
  const auto result = HLE::TryReplaceFunction(m_ppc_symbol_db, address, PowerPC::CoreMode::JIT);
  if (!result)
    return false;

  EmitHLEFunction({m_system, address, result.hook_index});

  if (result.type != HLE::HookType::Replace)
    return false;

  js.downcountAmount += js.st.numCycles;
  WriteEndBlock();
  return true;
}

void CachedInterpreterIR::WriteEndBlock(u32 link_target)
{
  // iCube IR M3: linkable IFF all hold: feature on; not profiling (the link terminal is unprofiled — a
  // chained block would skip EndProfiling); not debugging (breakpoints/stepping must round-trip the
  // dispatcher so a single ExecuteOneBlock never runs a whole chain past a breakpoint); and the terminal is
  // a STATIC direct branch (link_target != UINT32_MAX). The last gate is the EE/MSR-safety invariant: only
  // bx/bcx set a real op.branchTo, so sc/rfi/bclr/bcctr/broken-block/HLE-replace (all UINT32_MAX here) are
  // excluded and keep their plain EndBlock — we NEVER link past a terminal that can change MSR/feature_flags
  // or toggle EE without the dispatcher getting a turn. This mirrors the shipping CIR's WriteEndBlock gating
  // exactly.
  // iCube IR M3: also disabled under the M1 DOLPHIN_IR_VALIDATE self-check (m_validate): that check diffs
  // the lowered vector against an independent M0 callback tape that has no EndBlockLink concept, so emitting
  // a link terminal would trip a spurious count/op mismatch. The validate path is an opt-in debug build
  // aid; suppressing linking there keeps the 1:1 invariant intact without affecting shipping behavior.
  const bool linkable = s_ir_block_linking && !m_validate && !IsProfilingEnabled() &&
                        !IsDebuggingEnabled() && link_target != 0xFFFFFFFF;

  if (linkable)
  {
    EmitEndBlockLink({js.downcountAmount, js.numLoadStoreInst, js.numFloatingPointInst, link_target,
                      nullptr},
                     link_target);
    return;
  }

  if (IsProfilingEnabled())
  {
    EmitEndBlock<true>({{js.downcountAmount, js.numLoadStoreInst, js.numFloatingPointInst},
                        js.curBlock->profile_data.get()});
  }
  else
  {
    EmitEndBlock<false>({js.downcountAmount, js.numLoadStoreInst, js.numFloatingPointInst});
  }
}

// ----------------------------------------------------------------------------
// IR emit helpers. Each appends exactly one IRInst (1:1 with the M0 callback it mirrors). Under
// DOLPHIN_IR_VALIDATE=1 each also writes the equivalent M0 callback record into the scratch buffer
// so ValidateBlockIR can diff the lowered IR against an independent M0 serialization.
// ----------------------------------------------------------------------------
void CachedInterpreterIR::EmitStartProfiledBlock(const StartProfiledBlockOperands& operands)
{
  m_current_ir->push_back(IRInst{IROp::StartProfiledBlock, {.start_profiled_block = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(StartProfiledBlock, operands);
}

template <bool profiled>
void CachedInterpreterIR::EmitEndBlock(const EndBlockOperands<profiled>& operands)
{
  if constexpr (profiled)
    m_current_ir->push_back(IRInst{IROp::EndBlockProfiled, {.end_block_profiled = operands}});
  else
    m_current_ir->push_back(IRInst{IROp::EndBlock, {.end_block = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(EndBlock<profiled>, operands);
}

// iCube IR M3: emit a linkable terminal and record the JitBlock::LinkData the upstream linker resolves.
// The IR-engine specifics: the link target is the target block's IR VECTOR (resolved later by
// PatchBlockLink), not a byte rel into a tape, so link_target_ir starts null. exitPtrs cannot be set here
// (the anchor that carries this block's IR-vector pointer is written AFTER the lowering loop, at the end of
// DoJit); DoJit fixes up every LinkData.exitPtrs to the anchor address once it is written. We push the
// LinkData with exitPtrs == nullptr as a marker for that fixup.
void CachedInterpreterIR::EmitEndBlockLink(const EndBlockLinkOperands& operands, u32 link_target)
{
  m_current_ir->push_back(IRInst{IROp::EndBlockLink, {.end_block_link = operands}});

  JitBlock::LinkData ld{};
  ld.exitPtrs = nullptr;  // fixed up to the anchor address in DoJit after the anchor is written
#ifdef _M_ARM_64
  ld.exitFarcode = nullptr;
#endif
  ld.exitAddress = link_target;
  ld.linkStatus = false;
  ld.call = false;
  js.curBlock->linkData.push_back(ld);
}

template <bool write_pc>
void CachedInterpreterIR::EmitInterpret(const InterpretOperands& operands)
{
  IRInst inst{write_pc ? IROp::InterpretPC : IROp::Interpret, {.interpret = operands}};
  // iCube M2: stamp the PPCAnalyst liveness metadata for this op so the dead-flag optimizer pass can
  // consume it later (it does not re-run/fork the analysis). js.op is the CodeOp being lowered. Reading
  // these out-of-union fields is free; the handlers and the M1 1:1 validate never look at them, so with the
  // M2 flags off this is byte-identical to before.
  const PPCAnalyst::CodeOp& op = *js.op;
  inst.cr_out = static_cast<u8>(op.crOut.m_val);
  inst.cr_discardable = static_cast<u8>(op.crDiscardable.m_val);
  inst.opinfo_flags = op.opinfo->flags;
  m_current_ir->push_back(inst);
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(Interpret<write_pc>, operands);
}

template <bool write_pc>
void CachedInterpreterIR::EmitInterpretChk(const InterpretAndCheckExceptionsOperands& operands)
{
  m_current_ir->push_back(
      IRInst{write_pc ? IROp::InterpretChkPC : IROp::InterpretChk, {.interpret_chk = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(InterpretAndCheckExceptions<write_pc>, operands);
}

void CachedInterpreterIR::EmitHLEFunction(const HLEFunctionOperands& operands)
{
  m_current_ir->push_back(IRInst{IROp::HLEFunction, {.hle = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(HLEFunction, operands);
}

void CachedInterpreterIR::EmitWriteBrokenBlockNPC(const WriteBrokenBlockNPCOperands& operands)
{
  m_current_ir->push_back(IRInst{IROp::WriteBrokenBlockNPC, {.broken_npc = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(WriteBrokenBlockNPC, operands);
}

void CachedInterpreterIR::EmitCheckFPU(const CheckHaltOperands& operands)
{
  m_current_ir->push_back(IRInst{IROp::CheckFPU, {.check_halt = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(CheckFPU, operands);
}

void CachedInterpreterIR::EmitCheckBreakpoint(const CheckHaltOperands& operands)
{
  m_current_ir->push_back(IRInst{IROp::CheckBreakpoint, {.check_halt = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(CheckBreakpoint, operands);
}

void CachedInterpreterIR::EmitCheckIdle(const CheckIdleOperands& operands)
{
  m_current_ir->push_back(IRInst{IROp::CheckIdle, {.check_idle = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(CheckIdle, operands);
}

void CachedInterpreterIR::EmitFastForwardCtrIdle(const CheckCtrIdleOperands& operands)
{
  m_current_ir->push_back(IRInst{IROp::FastForwardCtrIdle, {.ctr_idle = operands}});
  if (m_validate) [[unlikely]]
    m_validate_emitter.Write(FastForwardCtrIdle, operands);
}

bool CachedInterpreterIR::SetEmitterStateToFreeCodeRegion()
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

void CachedInterpreterIR::FreeRanges()
{
  for (const auto& [from, to] : m_block_cache.GetRangesToFree())
    m_free_ranges.insert(from, to);
  m_block_cache.ClearRangesToFree();
}

void CachedInterpreterIR::ResetFreeMemoryRanges()
{
  m_free_ranges.clear();
  m_free_ranges.insert(region, region + region_size);
}

void CachedInterpreterIR::Jit(u32 em_address)
{
  Jit(em_address, true);
}

void CachedInterpreterIR::Jit(u32 em_address, bool clear_cache_and_retry_on_failure)
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

bool CachedInterpreterIR::DoJit(u32 em_address, JitBlock* b, u32 nextPC)
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

  // M1: lower this block into an explicit IRInst vector instead of a callback tape. Build into a
  // fresh vector, then attach it to the block via a single anchor record written to the emitter
  // buffer (preserving near_begin/near_end/reclamation/Dispatch-by-normalEntry).
  auto ir = std::make_unique<std::vector<IRInst>>();
  m_current_ir = ir.get();

  static const bool s_validate = [] {
    const char* v = std::getenv("DOLPHIN_IR_VALIDATE");
    return v && v[0] == '1';
  }();
  m_validate = s_validate;
  if (m_validate)
  {
    // Generous scratch buffer for the parallel M0 emission used only for the 1:1 self-check.
    m_validate_buffer.assign(m_code_buffer.size() * 64 + 256, 0);
    m_validate_emitter.SetCodePtr(m_validate_buffer.data(),
                                  m_validate_buffer.data() + m_validate_buffer.size());
  }

  if (IsProfilingEnabled())
    EmitStartProfiledBlock({js.curBlock->profile_data.get()});

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
        EmitCheckBreakpoint({power_pc, js.compilerPC, js.downcountAmount});
      }
      if (!js.firstFPInstructionFound && (op.opinfo->flags & FL_USE_FPU) != 0)
      {
        EmitCheckFPU({power_pc, js.compilerPC, js.downcountAmount});
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
        if (op.canEndBlock)
          EmitInterpretChk<true>(operands);
        else
          EmitInterpretChk<false>(operands);
      }
      else
      {
        const auto func = Interpreter::GetInterpreterOp(op.inst);
        const InterpretOperands operands = {interpreter, func, js.compilerPC, op.inst};
        if (op.canEndBlock)
          EmitInterpret<true>(operands);
        else
          EmitInterpret<false>(operands);
      }

      if (op.branchIsIdleLoop)
        EmitCheckIdle({m_system.GetCoreTiming(), js.blockStart});
      // For simple CTR-controlled tight loops, fast-forward by exiting the loop and yielding.
      if (op.branchIsCtrIdleLoop)
      {
        const u32 fallthrough_pc = op.address + 4;
        EmitFastForwardCtrIdle({m_system.GetCoreTiming(), js.blockStart, fallthrough_pc});
      }
      if (op.canEndBlock)
      {
        // iCube IR M3: pass the STATIC branch target for linking. Exclude idle-loop terminals: their
        // preceding CheckIdle/FastForwardCtrIdle forces downcount<=0 via CoreTiming::Idle(), so a link
        // would bail anyway — keep them on the plain EndBlock path. Non-static terminals carry
        // branchTo==UINT32_MAX and so are not linkable inside WriteEndBlock. Mirrors the CIR exactly.
        const bool idle_terminal = op.branchIsIdleLoop || op.branchIsCtrIdleLoop;
        WriteEndBlock(idle_terminal ? 0xFFFFFFFF : op.branchTo);
      }
    }
  }
  if (code_block.m_broken)
  {
    EmitWriteBrokenBlockNPC({nextPC});
    WriteEndBlock();  // broken block: npc forced to nextPC, not a static target -> plain EndBlock
  }

  m_current_ir = nullptr;

  // Opt-in 1:1 self-check against an independent M0 callback emission. This describes the UNOPTIMIZED M1
  // lowering only, so it MUST run before the optimizer passes (which intentionally make the IR differ from
  // the M0 tape).
  if (m_validate) [[unlikely]]
    ValidateBlockIR(*ir);

  // iCube M2: run the IR optimizer passes over the lowered vector (in place), after the M1 1:1 check and
  // before the anchor is written. With every M2 flag off this is a no-op and the vector is unchanged.
  // iCube IR M5: the micro-op fusion pass appends fused-run (func,inst) pairs into this per-block pool and
  // makes its FusedAluRun ops point at it. DoJit owns the pool; if the pass produced any runs, it is inserted
  // into m_block_fused below (keyed by normalEntry, freed via the same deferred-free path as the IR vector).
  // With the M5 flag off the micro-op fusion pass never runs, so it never reads/writes the pool; we therefore
  // only heap-allocate the owning pool when the flag is on (avoiding a per-block alloc on the shipping
  // default) and pass a throwaway stack vector otherwise — which the (skipped) pass never touches.
  std::unique_ptr<std::vector<CachedInterpreterIRFusedOp>> fused_pool;
  std::vector<CachedInterpreterIRFusedOp> unused_pool;
  if (s_ir_microop_fusion)
    fused_pool = std::make_unique<std::vector<CachedInterpreterIRFusedOp>>();
  RunIROptimizationPasses(*ir, fused_pool ? *fused_pool : unused_pool);

  // Write the single anchor record. This sets b->normalEntry/near_begin..near_end and is the key
  // the side table is indexed by. If the emitter is out of space, fail exactly like M0.
  u8* const anchor_site = GetWritableCodePtr();
  Write(IRBlockAnchor, {ir.get()});
  if (HasWriteFailed())
  {
    WARN_LOG_FMT(DYNA_REC, "JIT ran out of space in code region during code generation.");
    return false;
  }

  // iCube IR M3: fix up the linkable terminal's LinkData.exitPtrs to the anchor address now that it exists.
  // EmitEndBlockLink pushed it with exitPtrs == nullptr because the anchor (which carries this block's IR-
  // vector pointer) is only written here, after the lowering loop. PatchBlockLink recovers the source IR
  // vector from this anchor, so exitPtrs must equal anchor_site (== b->normalEntry). There is at most one
  // linkable terminal per block. This runs BEFORE FinalizeBlock(jo.enableBlocklink) below, so the upstream
  // linker sees the correct exitPtrs.
  for (JitBlock::LinkData& ld : b->linkData)
  {
    if (ld.exitPtrs == nullptr)
      ld.exitPtrs = anchor_site;
  }

  m_block_ir.insert_or_assign(b->normalEntry, std::move(ir));

  // iCube IR M5: if the micro-op fusion pass produced any fused runs, take ownership of the pool keyed by the
  // same normalEntry. The FusedAluRun operands point at this exact vector object; moving the unique_ptr here
  // does NOT change the vector's heap address, so those pointers stay valid. When there is no pool (M5 off) or
  // it is empty (no fusible runs in this block), erase any stale entry at this normalEntry — a re-jit of the
  // same address must not leave a prior block's pool behind. This keeps m_block_fused in exact parity with
  // m_block_ir's insert_or_assign (which always replaces the key).
  if (fused_pool && !fused_pool->empty())
    m_block_fused.insert_or_assign(b->normalEntry, std::move(fused_pool));
  else
    m_block_fused.erase(b->normalEntry);

  return true;
}

void CachedInterpreterIR::EraseSingleBlock(const JitBlock& block)
{
  m_block_cache.EraseSingleBlock(block);
  FreeRanges();
}

std::vector<JitBase::MemoryStats> CachedInterpreterIR::GetMemoryStats() const
{
  return {{"free", m_free_ranges.get_stats()}};
}

std::size_t CachedInterpreterIR::DisassembleNearCode(const JitBlock& block,
                                                     std::ostream& stream) const
{
  return Disassemble(block, stream);
}

std::size_t CachedInterpreterIR::DisassembleFarCode(const JitBlock& block,
                                                    std::ostream& stream) const
{
  stream << "N/A\n";
  return 0;
}

void CachedInterpreterIR::ClearCache()
{
  // iCube IR M3 — ORDER IS LOAD-BEARING under block linking: Clear() the block cache FIRST. Clearing
  // destroys every block (DestroyBlock -> UnlinkBlock -> WriteLinkBlock -> PatchBlockLink), and
  // PatchBlockLink dereferences each source block's anchor->ir to clear its link. Those anchors (in code
  // space, not yet poisoned) and their IR vectors must still be valid at that moment. DestroyBlock ->
  // ReleaseBlockIR moves each vector to m_ir_pending_free as it goes, so by the time Clear() returns
  // m_block_ir is already drained into pending_free; we then free pending_free and the (now-empty)
  // m_block_ir. (Pre-M3 this could clear m_block_ir first because WriteLinkBlock was a no-op.) This is not
  // a mid-chain free: ClearCache only ever runs at a dispatch boundary, never with ExecuteOneBlock on the
  // stack iterating a vector.
  m_block_cache.Clear();
  m_block_ir.clear();
  m_ir_pending_free.clear();
  // iCube IR M5: free the fused-run pools in lockstep with the IR vectors (same dispatch-boundary safety:
  // ClearCache only runs with no ExecuteOneBlock on the stack). m_block_fused is already drained into
  // m_fused_pending_free by the DestroyBlock -> ReleaseBlockIR walk above; clear both for completeness.
  m_block_fused.clear();
  m_fused_pending_free.clear();
  m_block_cache.ClearRangesToFree();
  ClearCodeSpace();
  ResetFreeMemoryRanges();
  RefreshConfig();
  Host_JitCacheInvalidation();
}

void CachedInterpreterIR::LogGeneratedCode() const
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

  DEBUG_LOG_FMT(DYNA_REC, "{}", std::move(stream).str());
}

// ============================================================================
// Disassembler (debug) — ostream overloads + the callback->disassembler lookup table.
// ============================================================================

s32 CachedInterpreterIR::StartProfiledBlock(std::ostream& stream,
                                            const StartProfiledBlockOperands& operands)
{
  stream << "StartProfiledBlock()\n";
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool profiled>
s32 CachedInterpreterIR::EndBlock(std::ostream& stream, const EndBlockOperands<profiled>& operands)
{
  fmt::println(stream, "EndBlock<profiled={}>(downcount={}, num_load_stores={}, num_fp_inst={})",
               profiled, operands.downcount, operands.num_load_stores, operands.num_fp_inst);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::EndBlockLink(std::ostream& stream, const EndBlockLinkOperands& operands)
{
  fmt::println(stream, "EndBlockLink(downcount={}, expected_pc=0x{:08x}, linked={})",
               operands.downcount, operands.expected_pc, operands.link_target_ir != nullptr);
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
s32 CachedInterpreterIR::Interpret(std::ostream& stream, const InterpretOperands& operands)
{
  fmt::println(stream, "Interpret<write_pc={:5}>(current_pc=0x{:08x}, inst=0x{:08x})", write_pc,
               operands.current_pc, operands.inst.hex);
  return sizeof(AnyCallback) + sizeof(operands);
}

template <bool write_pc>
s32 CachedInterpreterIR::InterpretAndCheckExceptions(
    std::ostream& stream, const InterpretAndCheckExceptionsOperands& operands)
{
  fmt::println(stream,
               "InterpretAndCheckExceptions<write_pc={:5}>(current_pc=0x{:08x}, inst=0x{:08x}, "
               "downcount={})",
               write_pc, operands.current_pc, operands.inst.hex, operands.downcount);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::HLEFunction(std::ostream& stream, const HLEFunctionOperands& operands)
{
  const auto& [system, current_pc, hook_index] = operands;
  fmt::println(stream, "HLEFunction(current_pc=0x{:08x}, hook_index={}) [\"{}\"]", current_pc,
               hook_index, HLE::GetHookNameByIndex(hook_index));
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::WriteBrokenBlockNPC(std::ostream& stream,
                                             const WriteBrokenBlockNPCOperands& operands)
{
  const auto& [current_pc] = operands;
  fmt::println(stream, "WriteBrokenBlockNPC(current_pc=0x{:08x})", current_pc);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::CheckFPU(std::ostream& stream, const CheckHaltOperands& operands)
{
  const auto& [power_pc, current_pc, downcount] = operands;
  fmt::println(stream, "CheckFPU(current_pc=0x{:08x}, downcount={})", current_pc, downcount);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::CheckBreakpoint(std::ostream& stream, const CheckHaltOperands& operands)
{
  const auto& [power_pc, current_pc, downcount] = operands;
  fmt::println(stream, "CheckBreakpoint(current_pc=0x{:08x}, downcount={})", current_pc, downcount);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::CheckIdle(std::ostream& stream, const CheckIdleOperands& operands)
{
  const auto& [core_timing, idle_pc] = operands;
  fmt::println(stream, "CheckIdle(idle_pc=0x{:08x})", idle_pc);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::FastForwardCtrIdle(std::ostream& stream,
                                            const CheckCtrIdleOperands& operands)
{
  const auto& [core_timing, idle_pc, fallthrough_pc] = operands;
  fmt::println(stream, "FastForwardCtrIdle(idle_pc=0x{:08x}, fallthrough_pc=0x{:08x})", idle_pc,
               fallthrough_pc);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::InterpretDeadFlagValidate(std::ostream& stream,
                                                   const InterpretDeadFlagValidateOperands& operands)
{
  fmt::println(stream,
               "InterpretDeadFlagValidate(current_pc=0x{:08x}, inst=0x{:08x}, ref_inst=0x{:08x}, "
               "elim_mask=0x{:02x})",
               operands.current_pc, operands.inst.hex, operands.ref_inst.hex, operands.elim_cr_mask);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::SetRegConst(std::ostream& stream, const SetRegConstOperands& operands)
{
  fmt::println(stream, "SetRegConst(r{} = 0x{:08x})", operands.reg, operands.value);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::SetRegConstValidate(std::ostream& stream,
                                             const SetRegConstValidateOperands& operands)
{
  fmt::println(stream, "SetRegConstValidate(r{} = 0x{:08x}, inst1=0x{:08x}, inst2=0x{:08x})",
               operands.reg, operands.value, operands.inst1.hex, operands.inst2.hex);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::FusedAluRun(std::ostream& stream, const FusedAluRunOperands& operands)
{
  fmt::println(stream, "FusedAluRun(count={}, offset={})", operands.count, operands.offset);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::FusedAluRunValidate(std::ostream& stream,
                                             const FusedAluRunValidateOperands& operands)
{
  fmt::println(stream, "FusedAluRunValidate(count={}, offset={})", operands.count, operands.offset);
  return sizeof(AnyCallback) + sizeof(operands);
}

s32 CachedInterpreterIR::IRBlockAnchor(std::ostream& stream, const IRBlockAnchorOperands& operands)
{
  const std::vector<IRInst>& ir = *operands.ir;
  fmt::println(stream, "IRBlockAnchor(ir_inst_count={})", ir.size());
  return sizeof(AnyCallback) + sizeof(operands);
}

static std::once_flag s_ir_sorted_lookup_flag;

std::size_t CachedInterpreterIR::Disassemble(const JitBlock& block, std::ostream& stream)
{
  using LookupKV = std::pair<AnyCallback, AnyDisassemble>;

  // clang-format off
#define LOOKUP_KV(...) {AnyCallbackCast(__VA_ARGS__), AnyDisassembleCast(__VA_ARGS__)}
  // clang-format on

  // Function addresses aren't known at compile-time, so this array is sorted at run-time.
  static auto sorted_lookup = std::to_array<LookupKV>({
      LOOKUP_KV(CachedInterpreterEmitter::PoisonCallback),
      LOOKUP_KV(CachedInterpreterIR::IRBlockAnchor),
      LOOKUP_KV(CachedInterpreterIR::StartProfiledBlock),
      LOOKUP_KV(CachedInterpreterIR::EndBlock<false>),
      LOOKUP_KV(CachedInterpreterIR::EndBlock<true>),
      // iCube IR M3: linkable terminal. Lives only in the IR vector (never written to the emitter buffer
      // this table walks), so it is never matched here — listed for lookup completeness.
      LOOKUP_KV(CachedInterpreterIR::EndBlockLink),
      LOOKUP_KV(CachedInterpreterIR::Interpret<false>),
      LOOKUP_KV(CachedInterpreterIR::Interpret<true>),
      LOOKUP_KV(CachedInterpreterIR::InterpretAndCheckExceptions<false>),
      LOOKUP_KV(CachedInterpreterIR::InterpretAndCheckExceptions<true>),
      LOOKUP_KV(CachedInterpreterIR::HLEFunction),
      LOOKUP_KV(CachedInterpreterIR::WriteBrokenBlockNPC),
      LOOKUP_KV(CachedInterpreterIR::CheckFPU),
      LOOKUP_KV(CachedInterpreterIR::CheckBreakpoint),
      LOOKUP_KV(CachedInterpreterIR::CheckIdle),
      LOOKUP_KV(CachedInterpreterIR::FastForwardCtrIdle),
      // iCube M2: validate op. Lives only in the IR vector (never written to the emitter buffer this table
      // walks), so it is never matched here — listed for lookup completeness / future IR-vector disassembly.
      LOOKUP_KV(CachedInterpreterIR::InterpretDeadFlagValidate),
      // iCube IR M4: const-fusion ops. Live only in the IR vector (never written to the emitter buffer this
      // table walks), so never matched here — listed for lookup completeness / future IR-vector disassembly.
      LOOKUP_KV(CachedInterpreterIR::SetRegConst),
      LOOKUP_KV(CachedInterpreterIR::SetRegConstValidate),
      // iCube IR M5: micro-op fusion ops. Live only in the IR vector (never written to the emitter buffer this
      // table walks), so never matched here — listed for lookup completeness / future IR-vector disassembly.
      LOOKUP_KV(CachedInterpreterIR::FusedAluRun),
      LOOKUP_KV(CachedInterpreterIR::FusedAluRunValidate),
  });

#undef LOOKUP_KV

  std::call_once(s_ir_sorted_lookup_flag, [] {
    const auto end = std::ranges::sort(sorted_lookup, {}, &LookupKV::first);
    ASSERT_MSG(DYNA_REC, std::ranges::adjacent_find(sorted_lookup, {}, &LookupKV::first) == end,
               "Sorted lookup should not contain duplicate keys.");
  });

  std::size_t instruction_count = 0;
  for (const u8* normal_entry = block.normalEntry; normal_entry != block.near_end;
       ++instruction_count)
  {
    const auto callback = *reinterpret_cast<const AnyCallback*>(normal_entry);
    const auto kv = std::ranges::lower_bound(sorted_lookup, callback, {}, &LookupKV::first);
    if (kv != sorted_lookup.end() && kv->first == callback)
    {
      normal_entry += kv->second(stream, normal_entry + sizeof(AnyCallback));
      continue;
    }
    stream << "UNKNOWN OR ILLEGAL CALLBACK\n";
    break;
  }
  return instruction_count;
}
